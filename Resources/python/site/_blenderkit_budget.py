"""The vertex budget: the one place a change that can multiply geometry is
priced, before Blender makes it (round 4's fix round, October 20).

Round 4's reviews found a new way round the budget after every repair, each
time the same kind of hole: a path that set a value with no price (the Bevel
row's Segments, the curve Data tab, a text's Size and Offset, the Mirror
row's axes, the Data API row on anything but a modifier or a text), or a
model that did not know what a value did (`_through` counted a Bevel, a
Remesh and an Array fitted to a length as making nothing new). The old price
listed the settings it priced (`_LEVEL_KEYS`, `PRICED`); anything not on a
list went through.

So now:

  * Every path prices through `price` / `price_all` (one property or
    several, on any RNA struct: a modifier, a curve's, surface's or text's
    data, a spline, an object), `price_add` (Add Modifier, and the Operator
    Search's `object.modifier_add`), `price_copy` (the search's Copy) and
    `price_order` (Move Up and Down, Move to Index). Each only says what
    would change (a `Prices`) and hands it to the one judgement, `_judge`,
    which counts every object the change reaches with the one model. The
    modifier rows send `price_modifier` in front of every edit
    (`Bpy.modifierEdit`), the curve Data tab `price` in front of its line
    (`PointsBpy.set`), the text Data tab and Body Text go through
    `_blenderkit_text`, the Data API row through
    `_blenderkit_sync.set_property`, and the search through
    `_blenderkit_sync.run_operator`. Add ▸ Mesh's primitives, whose own
    settings make the mesh, are priced from them as `bpy.ops` hands them out
    (`price_primitive`, from `_blenderkit_context`), wherever they are
    called from.
  * The price does not choose which settings matter. A change is laid over
    Blender's own values (`Prices.get`) and the whole stack is counted again,
    so any setting the model reads is priced on every path, and a setting it
    does not read cannot change its count.
  * The model (`_GROWTH`) has an entry for every modifier type in Blender's
    RNA enum: a count, exact or an upper bound, from what each is given —
    or, for the four that make what a count cannot hold (`_UNMODELLED`), a
    reason. The completeness check (tests/budget/blender/verify.py) raises
    every int, float, enum and bool of every type Add Modifier offers, and of
    the curve, surface and text data, on small fixtures, and fails when
    Blender's evaluated count grows past the budget's.
  * Some counts need what a modifier is given, not just how many vertices:
    Remesh's from the surface's area (`_blenderkit_sculpt`'s estimate, which
    the Sculpt header's Remesh keeps), an Array fitted to a length from the
    mesh's size. Those are read from Blender's own evaluation of the stack up
    to that modifier (`Prices.measure`), made only while the count up to it
    is inside the budget, so the reading cannot itself be what runs out.
  * An upper bound that passes the budget is enough. One that does not is
    made exact where Blender can be asked safely (`_final`): the stack up to
    the last bound inside the budget is evaluated and counted from there. So
    a Bevel's bound, which is loose on a smooth mesh, refuses nothing an
    exact count would let through.

Round 4's fix-round review (October 21) found the price still blind in
places, and each is now inside it: the viewport is always judged (a render's
settings as well, apart); a change reaches whatever reads the object through
a parent, an empty or a constraint (`affected`), and Blender is asked for its
measures with every changed object as it would be (`_stand_in`,
`_materialize`), a vertex's position, a Delta Scale and Dimensions too; caps
of caps are counted in full, once (`_object_final`); metaballs, Fluid
domains, Volume to Mesh and a Boolean's crossings have counts of their own;
a Subdivision Surface's limit surface is priced for its time as well as its
count (`SUBDIVISION_SECONDS`), a Fluid domain's grids for their memory and a
volume's for its voxels; the operators that rebuild a base, move an object
or give it another's data are priced as `bpy.ops` hands them out
(`price_operator`, `_blenderkit_context.PRICED_OPERATORS`), a render too;
and a number past `HUGE` is evaluated before it is let through.

Everything below was measured in desktop Blender 5.2.1 with the app's
context (its modules, `_blenderkit_context.install`, `gpu.init()` and its
undo push), unless it says otherwise.
"""

import ast as _ast
import math
import os
import sys

import bpy


# What Blender takes as an object's data, by the object's type: its own kind
# of datablock and no other (measured in 5.2.1: a mesh object any Mesh; a curve,
# a surface or a text any Curve, its subtypes included; a light any Light; an
# empty an Image or None; anything else refused with "Object.data expected a
# Mesh type, not Image", and None on any but an empty ignored). The Data API's
# menu for Data offers these too (`_blenderkit_sync.property_info`).
OBJECT_DATA = {
    'MESH': 'Mesh', 'CURVE': 'Curve', 'SURFACE': 'Curve', 'FONT': 'Curve',
    'META': 'MetaBall', 'LATTICE': 'Lattice', 'ARMATURE': 'Armature',
    'CAMERA': 'Camera', 'LIGHT': 'Light', 'LIGHT_PROBE': 'LightProbe',
    'SPEAKER': 'Speaker', 'CURVES': 'Curves', 'POINTCLOUD': 'PointCloud',
    'VOLUME': 'Volume', 'GREASEPENCIL': 'GreasePencil', 'EMPTY': 'Image',
}


def data_fits(obj, value):
    """Whether Blender makes `value` `obj`'s data when it is assigned."""
    if not isinstance(obj, bpy.types.Object) or isinstance(value, Virtual):
        return True
    if value is None:
        return obj.type == 'EMPTY'
    kind = getattr(bpy.types, OBJECT_DATA.get(obj.type, ''), None)
    return kind is None or isinstance(value, kind)


def _sibling(name):
    """Another of the app's modules: imported, or — where the site folder is
    not on the path, as in the desktop checks, which load each module from
    its file — loaded from beside this one."""
    module = sys.modules.get(name)
    if module is not None:
        return module
    try:
        return __import__(name)
    except ImportError:
        import importlib.util
        spec = importlib.util.spec_from_file_location(name, os.path.join(os.path.dirname(__file__), name + '.py'))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            # A half-run module left in sys.modules would answer every later
            # price with an AttributeError (the modkinds check: Remesh on a
            # text then said '_blenderkit_sculpt' had no '_remesh_count',
            # after its first load had failed on an import).
            sys.modules.pop(name, None)
            raise
        return module

# The most vertices an object's evaluated mesh may have, on any device: above a
# UV sphere's Multires level 6 (2,031,618) and a cube's level 9 (1,572,866),
# below the cube's level 10 (6,291,458), and a quarter of the mirror's limit
# (`_MAX_VERTS` in _blenderkit_sync.py). _blenderkit_multires has the
# measurements.
BUDGET = 2_500_000
# Memory a change needs at its peak, per vertex it leaves: Multires Subdivide's
# measured 560 to 730 bytes in the app, rounded up.
PEAK_BYTES_PER_VERTEX = 800
# Skin is refused on more independent loops of edges than this, for time:
# a 30 x 30 grid (900 loops) took 18.3 s, Suzanne (499) 7.8 s, on the main
# thread with the app frozen (round 4, group 8).
SKIN_MAX_LOOPS = 600
# Skin's vertices, edges, faces and corners per vertex it is given, at most
# (measured on a cube, a UV sphere, a grid, a cylinder, chains and Suzanne,
# the most: 42.3, 72.9, 35.9 and 145 per vertex; rounded up).
_SKIN_PER_VERTEX = (48, 80, 40, 160)
# The ocean simulation's memory per sample at its resolution r ((r²)² samples
# in either Geometry mode): measured 91 bytes, 171 with Normals, Foam and
# Spray; rounded up.
OCEAN_BYTES_PER_SAMPLE = 180
# Blender's own limit on what an Array makes: past 2^26 vertices it makes one
# copy and reports "The offset is too small, we cannot generate the amount of
# geometry it would require" (MOD_array.cc `max_verts_num`; measured, a cube
# fitted to 2,000 m at an offset of 0.00001 made 8 vertices).
ARRAY_LIMIT = 1 << 26
# The object types that make a mesh the app draws: a text, a curve and a
# surface are turned into one first, and their modifiers act on that; a
# metaball family's polygonization is its basis's mesh (`_meta_base`).
GEOMETRY_TYPES = ('MESH', 'CURVE', 'SURFACE', 'FONT', 'META')
# And what the budget judges: a volume too, for the voxels of its grid.
# Hair curves (`bpy.data.hair_curves`, objects of type CURVES) are counted by
# their points, the unit Blender's own count of them reads. Fix round 3
# (October 29), desktop 5.2.1 with the app's context, the budget lowered to
# 100,000: a script line's `hair_curves.new` with `add_curves([1000] * 200)`
# linked to the scene, and `add_curves` on one already there, each made
# 200,000 points with no refusal — no price counted the type.
COUNTED_TYPES = GEOMETRY_TYPES + ('VOLUME', 'GREASEPENCIL', 'CURVES')


def _is_real_blender():
    # The simulator's stand-in has no RNA behind its operators, and no budget
    # to keep: its Swift engine draws at most level 3 (ModifierStack).
    try:
        return hasattr(bpy.ops.object.mode_set, 'get_rna_type')
    except AttributeError:
        return False


def _gate():
    """The gate every write goes through (_blenderkit_gate.py), or None where
    it is not loaded (the simulator's stand-in)."""
    module = sys.modules.get('_blenderkit_gate')
    if module is not None:
        return module
    try:
        return _sibling('_blenderkit_gate')
    except ImportError:
        return None


def _depsgraph():
    """Blender's evaluated depsgraph, asked for by the price itself: the gate
    lets the price's own evaluations through (its copies and stand-ins are
    not a change to price), which it can only do once every write before it
    has been priced (`settle`)."""
    gate = sys.modules.get('_blenderkit_gate')
    if gate is None:
        return bpy.context.evaluated_depsgraph_get()
    with gate._Busy():
        return bpy.context.evaluated_depsgraph_get()


def settle():
    """Every write Blender has not evaluated yet priced by the gate (refused
    in words when it is past the budget), then evaluated, so the price that
    follows reads where everything is. Each price's entry point starts here:
    a script line's write followed by one of the app's rows was otherwise
    evaluated by that row's own price, unpriced."""
    gate = _gate()
    if gate is not None:
        gate.settle()
    if _plan is not None and _pending():
        # Waiting still (what the gate does not price, an F-curve's or an
        # action's change among it): the price's own evaluations will take it,
        # and the frame plan (`frame_plan`) cannot hear of it there.
        drop_plan()


class Unpriceable(RuntimeError):
    """A count the model cannot make without asking Blender for more than the
    budget: what a Remesh or a fitted Array is given is past it already."""


class NonFinite(RuntimeError):
    """A change that would give Blender infinite or undefined vertex positions."""


def _finite(mesh):
    """Whether every vertex of `mesh` is at a finite position. Round 4's
    review: the text Data tab's Offset and Depth take ±FLT_MAX, as Blender's
    RNA does, and at 3.4e38 Blender made 297 and 2,795 vertices at infinite or
    undefined positions (1e6 and 1e20 stayed finite)."""
    import numpy as np
    n = len(mesh.vertices) if mesh is not None else 0
    if not n:
        return True
    co = np.empty(3 * n, dtype=np.float32)
    mesh.vertices.foreach_get('co', co)
    return bool(np.isfinite(co).all())


# --------------------------------------------------------------------------
# Counts


class Counts:
    """Vertices, edges, faces and corners; `exact` when Blender would make
    exactly these, else they bound what it makes."""
    __slots__ = ('v', 'e', 'f', 'c', 'exact')

    def __init__(self, v, e, f, c, exact=True):
        self.v, self.e, self.f, self.c = int(v), int(e), int(f), int(c)
        self.exact = bool(exact)

    def tuple(self):
        return (self.v, self.e, self.f, self.c)

    def times(self, k, exact=None):
        k = max(0, int(k))
        return Counts(self.v * k, self.e * k, self.f * k, self.c * k,
                      self.exact if exact is None else exact)

    def plus(self, other, exact=False):
        return Counts(self.v + other.v, self.e + other.e, self.f + other.f, self.c + other.c,
                      exact and self.exact and other.exact)

    def bound(self):
        return Counts(self.v, self.e, self.f, self.c, False)

    def __repr__(self):
        return "Counts(%d, %d, %d, %d%s)" % (self.v, self.e, self.f, self.c, "" if self.exact else ", bound")


def _counts_of(mesh, exact=True):
    if mesh is None:
        return Counts(0, 0, 0, 0, exact)
    edges = getattr(mesh, 'edges', None)
    corners = len(mesh.loops)
    return Counts(len(mesh.vertices), len(edges) if edges is not None else corners // 2,
                  len(mesh.polygons), corners, exact)


def _subdivided(counts, levels):
    """Counts after `levels` Catmull-Clark levels: one level puts a vertex on
    every face and edge, splits each edge in two and adds one from each face's
    centre to each of its sides, and turns every corner into a quad. Exact
    against `to_mesh()` at levels 0 to 9 on a cube (8, 26, 98 … 1,572,866), 0
    to 6 on a 32 x 16 UV sphere and 0 to 7 on an open 10 x 10 grid; a Multires
    level follows the same rule."""
    if not isinstance(counts, Counts):
        counts = Counts(*counts)
    v, e, f, c = counts.tuple()
    for _ in range(max(0, int(levels))):
        v, e, f, c = v + e + f, 2 * e + c, c, 4 * c
    return Counts(v, e, f, c, counts.exact)


def level_vertices(mesh, level):
    """The vertices a Multires at `level` evaluates to on `mesh` alone:
    C·s² + (2E + C)·s + (V + E + F) with s = 2^(level-1) - 1, the closed form
    of `_subdivided`."""
    v, f, c = len(mesh.vertices), len(mesh.polygons), len(mesh.loops)
    edges = getattr(mesh, 'edges', None)
    e = len(edges) if edges is not None else c // 2
    if level <= 0:
        return v
    s = (1 << (level - 1)) - 1
    return c * s * s + (2 * e + c) * s + (v + e + f)


# --------------------------------------------------------------------------
# Changes laid over Blender's values


def _pointer(owner):
    try:
        return owner.as_pointer()
    except (AttributeError, ReferenceError):
        return id(owner)


_DEFAULTS = {}
# Kinds whose `modifiers.new` makes data of its own (a particle system, a
# fluid, a cloth): their defaults are read from RNA, never by making one.
_MAKES_DATA = ('PARTICLE_SYSTEM', 'FLUID', 'DYNAMIC_PAINT', 'CLOTH', 'SOFT_BODY', 'COLLISION',
               'SURFACE')


def _defaults(kind):
    """Blender's settings for a new modifier of `kind`, as `modifiers.new`
    makes it (the DNA defaults its init copies): read once from a modifier
    made on a mesh outside the scene, which Blender never evaluates."""
    if kind in _DEFAULTS:
        return _DEFAULTS[kind]
    values = {}
    if kind not in _MAKES_DATA:
        mesh = bpy.data.meshes.new("Blender Local defaults")
        probe = bpy.data.objects.new("Blender Local defaults", mesh)
        try:
            try:
                modifier = probe.modifiers.new("defaults", kind)
            except (TypeError, RuntimeError):
                modifier = None
            if modifier is not None:
                for prop in modifier.bl_rna.properties:
                    if prop.identifier == 'rna_type':
                        continue
                    try:
                        value = getattr(modifier, prop.identifier)
                    except AttributeError:
                        continue
                    if prop.type in ('INT', 'FLOAT', 'BOOLEAN') and getattr(prop, 'is_array', False):
                        value = tuple(value)
                    elif prop.type == 'ENUM' and prop.is_enum_flag:
                        value = set(value)
                    elif prop.type in ('POINTER', 'COLLECTION'):
                        value = None
                    values[prop.identifier] = value
        finally:
            bpy.data.objects.remove(probe)
            bpy.data.meshes.remove(mesh)
    _DEFAULTS[kind] = values
    return values


def _new_name(kind):
    """The name Blender gives a new modifier of `kind`: its type's name
    ("Subdivision", "Array"), as `modifiers.new` from Add Modifier names it."""
    words = _KIND_WORDS.get(kind)
    if words:
        return words
    try:
        return bpy.types.Modifier.bl_rna.properties['type'].enum_items[kind].name
    except (KeyError, AttributeError):
        return kind.replace('_', ' ').title()


class Virtual:
    """A modifier Blender has not made yet — Add Modifier's new one, or the
    search's Copy — read as Blender would make it: `settings` first, then the
    modifier it copies (`like`), then Blender's defaults for its kind."""

    def __init__(self, kind, name=None, settings=None, like=None):
        self.type = kind
        self.name = name or _new_name(kind)
        self.settings = dict(settings or {})
        self.like = like

    def get(self, key):
        if key in self.settings:
            return self.settings[key]
        if key in ('show_viewport', 'show_render'):
            return True
        if self.like is not None:
            return getattr(self.like, key)
        return _defaults(self.type).get(key)

    def __getattr__(self, key):
        if key.startswith('__'):
            raise AttributeError(key)
        return self.get(key)


class Prices:
    """One pricing: the changes laid over Blender's values, and the copies and
    stand-in objects made to count them, all removed by `close`.

    `values` maps (an RNA struct's pointer, a property) to the value it would
    have. `orders` gives an object's modifiers in a new order, `added` the
    modifiers that would be added (`Virtual`, with where), `bases` counts that
    stand in for an object's own mesh (an edit that adds geometry, priced
    before it runs: `_blenderkit_loopcut.priced`), `shown` modifiers counted
    as shown whatever their switch (the one being priced: a level set on a
    hidden Subdivision is priced as if shown, as before). `render` counts what
    a render evaluates: render levels, render steps, render resolutions."""

    def __init__(self, render=False):
        self.values = {}
        self.owners = {}
        self.orders = {}
        self.added = {}
        self.bases = {}
        self.shown = set()
        self.render = render
        self._copies = {}
        self._objects = []
        self._curves = []
        self._meshes = []
        self._keys = []
        self._lattices = []
        self._collections = []
        self._textures = []
        self._measures = {}
        # Blender's evaluations made for this pricing (`_evaluate`) and the
        # walks counted from them (`_walk`), each made once: round 4's
        # fix-round review measured a Boolean's price evaluating nine times,
        # the same stacks twice and three times over. `_version` changes
        # with every change laid over, which keys both.
        self._evals = {}
        self._walks = {}
        self._version = 0
        self.depth = 0
        # Whether a curve's or text's data built to count it is held to
        # finite positions (the change's own pricing, not the count of now).
        self.finite = False
        # Per pricing, so one object reached many ways is counted once: what
        # another object evaluates to (`_object_final`), where an object is
        # (`_matrix`), whether it moves or reads anything changed (`_moves`,
        # `_dirty`), and its stand-in in the scene (`_stand_in`).
        self._finals = {}
        self._visiting = []
        self._placing = set()
        self._worlds = {}
        self._moving = {}
        self._dirt = {}
        self._stand_ins = {}
        # Objects whose base is made here, not Blender's (a Join's), which a
        # refinement must not take as Blender's own mesh.
        self.synthetic = set()
        # Metaball elements Add ▸ Metaball would add to a family's basis
        # (their share of `_meta_base`), by the basis's pointer, and how many
        # elements each basis polygonizes (`meta_seconds`).
        self.added_elements = {}
        self.meta_elements = {}
        # A change with a number past HUGE: the result is evaluated and held
        # to finite positions (`_finite_after`); and the largest number in the
        # changes, which can call for that below HUGE (`_could_overflow`).
        self.huge = False
        self.big = 0.0
        # The changes are values Blender holds already (the gate's), not ones
        # about to be set through RNA: taken as they are, not clamped to RNA's
        # range. An operator writes past it — measured in desktop 5.2.1, the
        # search's Resize of 30 in a metaball's Edit Mode left an element's
        # Size X at 81 where RNA stops at 20, 700,312 vertices — and clamped,
        # the gate priced 81 as 20 (145,207).
        self.exact = False
        # What Blender holds for an object whose change could not be put back
        # for the price (the gate's: a mesh given more vertices by a script),
        # by its pointer: 'now' for the judgement, which the model, reading
        # the change, cannot count.
        self.was = {}
        # And its limit surface's seconds then (`_EditGuard`'s 'now').
        self.was_seconds = {}
        # Constraints an operator would add to an object, by its pointer: the
        # constraints whose copies it would have (Copy Constraints to
        # Selected), or (type, target) for a new one.
        self.constraints_added = {}

    # -- the changes

    def change(self, owner, key, value):
        if key == 'dimensions' and isinstance(owner, bpy.types.Object):
            # Blender's Dimensions setter is a Scale (BKE_object_dimensions_set:
            # each axis's scale times the new size over the old, an axis with
            # no size left alone), and the scale is what everything reads.
            scale = list(self.get(owner, 'scale'))
            now = owner.dimensions
            for i in range(3):
                if now[i] > 0:
                    try:
                        scale[i] = scale[i] * float(value[i]) / now[i]
                    except (TypeError, ValueError, IndexError):
                        pass
            key, value = 'scale', tuple(scale)
        elif key in ('matrix_world', 'matrix_local', 'matrix_basis') and isinstance(owner, bpy.types.Object):
            # Set as the channels Blender would set (BKE_object_apply_mat4).
            for channel, number in _channels_of(owner, key, value, self).items():
                self.change(owner, channel, number)
            return
        elif key == 'data' and not data_fits(owner, value):
            # Blender refuses it at the assignment ("Object.data expected a
            # Mesh type, not Image"), or ignores it (None on a mesh object):
            # the object keeps its data, and that is what is counted. Staged,
            # the Image reached the mesh counts as one (`_counts_of`:
            # 'Image' object has no attribute 'loops' — the user, November 4,
            # picking an Image as a sphere's Data in the Data API).
            return
        if not self.exact:
            value = _clamped(owner, key, value)
        p = _pointer(owner)
        self.values[(p, key)] = value
        self.owners[p] = owner
        self._version += 1

    def get(self, owner, key):
        if isinstance(owner, Virtual):
            return owner.get(key)
        if self.values:
            p = _pointer(owner)
            if (p, key) in self.values:
                return self.values[(p, key)]
        if key.startswith('["'):
            # A custom property: a Geometry Nodes modifier's inputs are these.
            try:
                return owner.get(key[2:-2])
            except (AttributeError, TypeError):
                return None
        return getattr(owner, key)

    def changes_on(self, block):
        """(owner, key, value) of each change to `block` or a struct in it."""
        found = []
        target = _pointer(block)
        for (p, key), value in self.values.items():
            owner = self.owners[p]
            try:
                id_block = owner.id_data
            except (AttributeError, ReferenceError):
                continue
            if id_block is not None and _pointer(id_block) == target:
                found.append((owner, key, value))
        return found

    def touches(self, obj):
        """Whether anything here changes how `obj` evaluates by itself: its
        own settings, its data's, or its data's shape keys' (round 4's
        fix-round review: a key's Value under an Array fitted to a length,
        168 → 3,199,472, unpriced)."""
        p = _pointer(obj)
        if p in self.orders or p in self.added or p in self.bases or p in self.constraints_added:
            return True
        if self.changes_on(obj):
            return True
        if self.values and any(self.changes_on(t) for t in _textures_of(obj)):
            return True
        data = self.get(obj, 'data')
        if data is None:
            return False
        if self.changes_on(data):
            return True
        keys = getattr(data, 'shape_keys', None)
        return keys is not None and bool(self.changes_on(keys))

    # -- what is counted

    def data_of(self, obj):
        """`obj`'s data as it would be: a copy with the changes made when there
        are any (always for a text, whose count lays it out in place), the
        render resolutions in place of the viewport's for a render. A mesh's
        is a copy only when a change reaches its elements (round 4's fix-round
        review: a vertex's position set through the Data API row,
        `meshes['Cube.001'].vertices[0].co = (2400, 2400, 2400)`, under a
        Remesh at 0.1, was counted at 6,225 from the mesh as it was, and
        Blender made 2,883,788)."""
        data = self.get(obj, 'data')
        if data is None:
            return data
        key = _pointer(data)
        if key in self._copies:
            return self._copies[key]
        if obj.type == 'MESH':
            changes = self.changes_on(data)
            keys = getattr(data, 'shape_keys', None)
            key_changes = self.changes_on(keys) if keys is not None else []
            if not changes and not key_changes:
                return data
            # A mesh's copy carries a copy of its shape keys (BKE_mesh_copy_data),
            # where a key's change is made.
            copy = data.copy()
            self._meshes.append(copy)
            _still(copy)
            _apply(copy, data, changes)
            if key_changes and copy.shape_keys is not None:
                self._keys.append(copy.shape_keys)
                _apply(copy.shape_keys, keys, key_changes)
            self._copies[key] = copy
            return copy
        if obj.type == 'LATTICE':
            # A lattice's points as they would be, for what it deforms (round
            # 4's fix round 2, desktop 5.2.1, budget lowered to 100,000: a
            # cube under a Lattice and an Array fitted to 100, the lattice's
            # points written by a script line to a thousandth of their width,
            # passed — counted on the lattice as it was, 408 — and Blender
            # made 399,944; the stand-in had kept the lattice's own data).
            changes = self.changes_on(data)
            if not changes:
                return data
            if obj.mode == 'EDIT':
                # Edit Mode's points are Blender's edit lattice, which a copy of
                # the data does not take: written into it first.
                obj.update_from_editmode()
            copy = data.copy()
            self._lattices.append(copy)
            _still(copy)
            _apply(copy, data, changes)
            self._copies[key] = copy
            return copy
        if obj.type not in ('CURVE', 'SURFACE', 'FONT'):
            return data
        changes = self.changes_on(data)
        references = []
        for ref in ('bevel_object', 'taper_object'):
            other = getattr(data, ref, None)
            if other is not None and other.data is not None and _dirty(other, self):
                references.append((ref, other))
        if not changes and not references and obj.type != 'FONT' and not self.render:
            return data
        copy = data.copy()
        self._curves.append(copy)
        _still(copy)
        _apply(copy, data, changes)
        if self.render:
            render_u = getattr(copy, 'render_resolution_u', 0)
            if render_u:
                copy.resolution_u = render_u
            render_v = getattr(copy, 'render_resolution_v', 0)
            if render_v and hasattr(copy, 'resolution_v'):
                copy.resolution_v = render_v
        for ref, other in references:
            setattr(copy, ref, self.object_like(other))
        self._copies[key] = copy
        return copy

    def object_like(self, obj):
        """A stand-in for `obj` in the scene, as the changes would make it
        (`_stand_in`)."""
        return _stand_in(obj, self)

    def texture_like(self, texture):
        """A copy of the legacy texture `texture` with the changes made, or
        `texture` itself when none is on it (see `_textures_of`)."""
        changes = self.changes_on(texture) if texture is not None else []
        if not changes:
            return texture
        key = _pointer(texture)
        if key in self._copies:
            return self._copies[key]
        copy = texture.copy()
        self._textures.append(copy)
        _still(copy)
        _apply(copy, texture, changes)
        self._copies[key] = copy
        return copy

    def close(self):
        for obj in self._objects:
            try:
                bpy.data.objects.remove(obj)
            except (ReferenceError, RuntimeError):
                pass
        for data in self._curves:
            try:
                bpy.data.curves.remove(data)
            except (ReferenceError, RuntimeError):
                pass
        for mesh in self._meshes:
            try:
                bpy.data.meshes.remove(mesh)
            except (ReferenceError, RuntimeError):
                pass
        for data in self._lattices:
            try:
                bpy.data.lattices.remove(data)
            except (ReferenceError, RuntimeError):
                pass
        for keys in self._keys:
            # A copied mesh's, curve's or lattice's shape keys outlive it as a
            # Key of no one's.
            try:
                if keys.users == 0:
                    bpy.data.shape_keys.remove(keys)
            except (ReferenceError, RuntimeError, AttributeError):
                pass
        for collection in self._collections:
            try:
                bpy.data.collections.remove(collection)
            except (ReferenceError, RuntimeError):
                pass
        for texture in self._textures:
            try:
                bpy.data.textures.remove(texture)
            except (ReferenceError, RuntimeError):
                pass
        self._objects, self._curves, self._meshes, self._keys, self._lattices = [], [], [], [], []
        self._collections = []
        self._textures = []
        self._copies.clear()
        self._measures.clear()
        self._evals.clear()
        self._walks.clear()
        for memo in (self._finals, self._worlds, self._moving, self._dirt, self._stand_ins):
            memo.clear()


def _still(copy):
    """A copy the price evaluates, with its own animation and its shape
    keys' cleared. A data-block's copy keeps the original's action and
    drivers (measured in desktop 5.2.1: a mesh's copy's Key held the
    action, an object's copy its driver), and Blender would work them out
    again at the frame it is on, over the values the price lays. Found by
    part 13.5: a shape key's Value driven by an empty's keyed X, priced at
    frame 10, was evaluated at frame 1's 0 on the copy, and the frame
    passed while Blender built 159,976 against a budget of 100,000. What the
    animation sets is a change of its own (`price_frame`, the gate's
    `animation_pairs`), laid over the copy with the rest."""
    for block in (copy, getattr(copy, 'shape_keys', None)):
        try:
            if block is not None and block.animation_data is not None:
                block.animation_data_clear()
        except (AttributeError, ReferenceError, RuntimeError):
            continue


def _clamped(owner, key, value):
    """`value` as RNA would store it: Blender clamps a number to its hard
    range when it is set, so a price of more than RNA keeps refuses what
    Blender would never make (Bevel Segments 100,000 is 1,000)."""
    try:
        prop = owner.bl_rna.properties[key]
    except (AttributeError, KeyError, TypeError):
        return value
    if prop.type in ('INT', 'FLOAT') and not getattr(prop, 'is_array', False):
        try:
            number = float(value)
        except (TypeError, ValueError):
            return value
        if math.isnan(number):
            return value
        number = min(max(number, prop.hard_min), prop.hard_max)
        return int(number) if prop.type == 'INT' else number
    return value


def _apply(copy, original, changes):
    """Makes `changes` (to `original` or structs in it) on `copy`. A key
    starting with '#' is a whole collection's attribute, set at once
    (`#vertices.co`, a key's `#data.co`, a spline's `#bezier_points.co`):
    the gate's change of a mesh's or a curve's elements."""
    base = _pointer(original)
    for owner, key, value in changes:
        if isinstance(owner, bpy.types.AnimData):
            # The copies a price evaluates have no animation (`_still`): what
            # an animation sets is priced as a change of its own. Fix round 3:
            # a texture keyed for the first time is a change of its AnimData's
            # action, and laid on the texture's copy it raised ('NoneType'
            # object has no attribute 'action').
            continue
        if _pointer(owner) == base:
            target = copy
        else:
            target = copy.path_resolve(owner.path_from_id())
            if target is None:
                continue
        if key.startswith('#'):
            path, _, attribute = key[1:].rpartition('.')
            collection = target.path_resolve(path) if path else target
            collection.foreach_set(attribute, value)
            continue
        if key.startswith('["'):
            target[key[2:-2]] = value
            continue
        setattr(target, key, value)


# --------------------------------------------------------------------------
# What a modifier stack is given: an object's own mesh


def curve_counts(data):
    """Counts Blender makes of the curve, surface or text data `data` before
    any modifier: an object of its own that uses the same data and has no
    modifiers, built by Blender. Measured equal to the object's own
    `to_mesh()` for a text, a Bézier curve, a Bézier circle and a NURBS sphere
    under an Array and a Subdivision Surface. Built outside the scene Blender
    leaves out a Bevel Object (a text bevelled by a circle: 4 vertices where
    it evaluates 192), so then the stand-in is evaluated in the scene."""
    with _built(data) as mesh:
        return _counts_of(mesh).tuple()


class _built:
    """The mesh Blender makes of curve data `data` alone (see curve_counts)."""

    def __init__(self, data):
        self.data = data

    def __enter__(self):
        data = self.data
        link = getattr(data, 'bevel_mode', 'ROUND') == 'OBJECT' and getattr(data, 'bevel_object', None) is not None
        self.probe = bpy.data.objects.new("Blender Local count", data)
        if link:
            bpy.context.scene.collection.objects.link(self.probe)
            self.source = self.probe.evaluated_get(_depsgraph())
        else:
            self.source = self.probe
        return self.source.to_mesh()

    def __exit__(self, *exc):
        try:
            self.source.to_mesh_clear()
        finally:
            bpy.data.objects.remove(self.probe)
        return False


def _ring(data, depth=0):
    """Vertices a curve's cross-section has at most, per point along it: one
    for a wire, 2 with Extrude, 4b + 6 with a round Bevel of resolution b
    (measured: 2b + 4 without Extrude, 4b + 6 with it, on Bézier, NURBS, poly
    and circle splines), a Profile's points the same way, and an Object
    bevel's own outline twice."""
    mode = getattr(data, 'bevel_mode', 'ROUND')
    bevelled = getattr(data, 'bevel_depth', 0) != 0
    extruded = getattr(data, 'extrude', 0) != 0
    b = max(0, int(getattr(data, 'bevel_resolution', 0)))
    if mode == 'OBJECT' and getattr(data, 'bevel_object', None) is not None:
        other = data.bevel_object
        if other.type != 'CURVE' or depth > 2:
            return 1
        return 2 * _curve_points(other.data, depth + 1) + 2
    if mode == 'PROFILE' and (bevelled or extruded):
        profile = getattr(data, 'bevel_profile', None)
        points = len(profile.points) if profile is not None else 0
        return 4 * max(b, points) + 6
    if bevelled:
        return 4 * b + 6
    return 2 if extruded else 1


def _resolutions(data):
    """The resolutions a curve's or surface's splines are built at: the
    data's own (which Blender copies to every spline) or a spline's own set
    above it (the Data API row reaches `Spline.resolution_u`)."""
    u = max([int(getattr(data, 'resolution_u', 1))]
            + [int(s.resolution_u) for s in data.splines]) if hasattr(data, 'splines') else 1
    v = 1
    if isinstance(data, getattr(bpy.types, 'SurfaceCurve', ())):
        v = max([int(getattr(data, 'resolution_v', 1))] + [int(s.resolution_v) for s in data.splines])
    return max(1, u), max(1, v)


def _curve_points(data, depth=0):
    """An upper bound of the points Blender lays a curve's splines out at:
    every control point Resolution U times (a Bézier segment between two
    Vector handles is one, a poly spline ignores Resolution; measured, the
    count at Resolution U r never passed the count at 1 times r, on Bézier,
    NURBS, poly, circle and path splines and six NURBS surfaces at U and V)."""
    u, v = _resolutions(data)
    points = sum(len(s.points) + len(s.bezier_points) for s in data.splines)
    return points * u * v


def _built_counts(data, finite=False):
    """Counts of the mesh Blender builds of `data`, refusing (`NonFinite`)
    one with a vertex at an infinite or undefined position when asked."""
    with _built(data) as mesh:
        if finite and not _finite(mesh):
            raise NonFinite(getattr(data, 'name', 'the curve'))
        return _counts_of(mesh)


def _curve_base(data, finite=False):
    """Counts of what Blender makes of curve or surface data `data`: built when
    a bound says the build stays within the budget, else that bound."""
    u, v = _resolutions(data)
    ring = _ring(data)
    estimate = _curve_points(data) * ring
    if estimate <= BUDGET:
        return _built_counts(data, finite)
    points = sum(len(s.points) + len(s.bezier_points) for s in data.splines)
    if points * ring > BUDGET:
        # Too many to build even at the lowest resolution: what a quad mesh of
        # that many vertices has.
        return Counts(estimate, 2 * estimate, estimate, 4 * estimate, False)
    low = data.copy()
    try:
        low.resolution_u = 1
        for spline in low.splines:
            spline.resolution_u = 1
            if v > 1:
                spline.resolution_v = 1
        if v > 1:
            low.resolution_v = 1
        if hasattr(low, 'render_resolution_u'):
            low.render_resolution_u = 0
        coarse = Counts(*curve_counts(low))
    finally:
        bpy.data.curves.remove(low)
    bound = coarse.times(u * v, exact=False)
    if bound.v <= BUDGET:
        return _built_counts(data, finite)
    return bound


def _text_base(data, finite=False):
    """Counts of a text's data, laid out by `_blenderkit_text.vertices` (its
    letters' outline points, exact in 3,960 cases) and built only when that
    is within the budget, so never more than the budget's worth."""
    count = _sibling('_blenderkit_text')._vertices(data)
    if count > BUDGET:
        return Counts(count, 2 * count, count, 4 * count, False)
    return _built_counts(data, finite)


def _base(obj, s):
    p = _pointer(obj)
    if p in s.bases:
        return Counts(*s.bases[p], exact=False)
    if obj.type == 'MESH':
        return _counts_of(s.get(obj, 'data'))
    finite = s.finite and bool(s.changes_on(s.get(obj, 'data')))
    if obj.type == 'FONT':
        return _text_base(s.data_of(obj), finite)
    if obj.type in ('CURVE', 'SURFACE'):
        data = s.data_of(obj)
        return _curve_base(data, finite) if data is not None else Counts(0, 0, 0, 0)
    if obj.type == 'META':
        return _meta_base(obj, s)
    if obj.type == 'GREASEPENCIL':
        points, strokes, length = _gp_measures(obj, s)
        return Counts(points, points, 0, 0, False)
    if obj.type == 'CURVES':
        data = s.get(obj, 'data')
        points = len(data.points) if data is not None else 0
        return Counts(points, points, 0, 0)
    return Counts(0, 0, 0, 0)


# --------------------------------------------------------------------------
# Grease Pencil: its points, and what its modifiers make of them. Round 4's
# fix round 2 review, desktop 5.2.1: `object.grease_pencil_add(type='MONKEY')`
# (1,216 points), then a Grease Pencil Array of Count 4,111, made 4,998,976
# points in 0.18 s with no refusal — its modifiers were counted as keeping
# what they are given; RNA allows Count 32,767 (about 39.8 M points) and
# Subdivide Level 16.

def _gp_measures(obj, s):
    """(points, strokes, the strokes' length) of a Grease Pencil object, each
    layer counted at its heaviest drawing — a frame change, or a Time
    modifier, shows another one — so a frame cannot bring more in."""
    key = ('gp', _pointer(obj))
    if key in s._measures:
        return s._measures[key]
    import numpy as np
    data = s.get(obj, 'data')
    points = strokes = 0
    length = 0.0
    for layer in getattr(data, 'layers', ()):
        most = (0, 0, 0.0)
        for frame in layer.frames:
            drawing = frame.drawing
            if drawing is None:
                continue
            position = drawing.attributes.get('position')
            n = len(position.data) if position is not None else 0
            k = len(drawing.strokes)
            total = 0.0
            if n > 1:
                co = np.empty(3 * n, dtype=np.float32)
                position.data.foreach_get('vector', co)
                co = co.reshape(-1, 3).astype(np.float64)
                steps = np.linalg.norm(np.diff(co, axis=0), axis=1)
                total = float(steps.sum())    # every step, those between strokes too: a bound
            if n > most[0] or total > most[2]:
                most = (max(n, most[0]), max(k, most[1]), max(total, most[2]))
        points += most[0]
        strokes += most[1]
        length += most[2]
    found = (points, strokes, length)
    s._measures[key] = found
    return found


def _gp(c, points):
    points = int(min(points, 1 << 62))
    return Counts(points, points, 0, 0, False)


def _g_gp_array(x, c):
    return _gp(c, c.v * max(1, int(x.get('count'))))


def _g_gp_multiply(x, c):
    return _gp(c, c.v * (1 + max(0, int(x.get('duplicates')))))


def _g_gp_mirror(x, c):
    axes = sum(bool(x.get(k)) for k in ('use_axis_x', 'use_axis_y', 'use_axis_z'))
    return _gp(c, c.v * 2 ** axes)


def _g_gp_subdiv(x, c):
    # Each segment cut into 2^Level (measured on the Monkey: Level 2, 4,822
    # points from 1,216 = 4 × 1,216 − 3 × its 42 strokes).
    return _gp(c, c.v * 2 ** max(0, int(x.get('level'))))


def _g_gp_envelope(x, c):
    # Deform keeps the strokes; Segments and Fills add a stroke of two or
    # four points for every point.
    if x.get('mode') == 'DEFORM':
        return c
    return _gp(c, c.v * 5)


def _g_gp_dash(x, c):
    points, strokes, length = _gp_measures(x.walk.obj, x.s)
    return _gp(c, 2 * c.v + strokes)


def _gp_resampled(x, c, spacing):
    """Points every `spacing` along the strokes (a bound: their whole
    length), and their ends."""
    points, strokes, length = _gp_measures(x.walk.obj, x.s)
    factor = c.v / points if points else 1.0
    if spacing <= 0:
        raise Unpriceable("%s's %s resamples its strokes at no distance at all, so it cannot be "
                          "counted" % (x.walk.obj.name, getattr(x.modifier, 'name', 'modifier')))
    return int(math.ceil(factor * (length / spacing))) + 2 * max(strokes, 1)


def _g_gp_outline(x, c):
    points, strokes, length = _gp_measures(x.walk.obj, x.s)
    subdivision = max(0, int(x.get('subdivision')))
    made = 2 * c.v * (subdivision + 2) + 4 * strokes * (subdivision + 2)
    spacing = float(x.get('sample_length'))
    if spacing > 0:
        made = max(made, 2 * _gp_resampled(x, c, spacing))
    return _gp(c, made)


def _g_gp_simplify(x, c):
    if x.get('mode') == 'SAMPLE':
        return _gp(c, max(c.v, _gp_resampled(x, c, float(x.get('length')))))
    return c


def _lineart_sources(x):
    """The objects a Line Art modifier draws: its object, its collection's,
    or the scene's."""
    kind = x.get('source_type')
    if kind == 'OBJECT':
        return [x.get('source_object')]
    if kind == 'COLLECTION':
        group = x.get('source_collection')
        return list(group.all_objects) if group is not None else []
    return list(bpy.context.scene.objects)


def _g_gp_lineart(x, c):
    """Line Art: the strokes Blender finds on what it draws, as points. A
    bound of two points an edge of every source (and two a triangle for its
    intersection lines), from each source's own count. Measured in desktop
    5.2.1 (fix round 3, October 29), Crease at 180° so every edge is a
    feature line: one icosphere of 7,680 edges, 3,459 points; of 122,880,
    54,908 (0.45 a point an edge); two crossing with Intersection on, 0.31 to
    0.33 a point an edge; every edge of a 100 × 100 grid marked, behind a
    comb of up to 60 thin bars cutting its edges, 1.01 to 1.02; in 0.01 to
    0.11 s. Until then Line Art was counted
    as keeping what it is given (the empty drawing it writes into): a Line
    Art of 3,321 points under a Grease Pencil Array of Count 40 built 132,840
    points with no refusal at a budget lowered to 100,000. An edge cut into
    several pieces by what stands in front of it can make more than two
    points: none measured past this bound, not proven."""
    made = 0
    intersections = bool(x.get('use_intersection'))
    for other in _lineart_sources(x):
        if other is None or other.type not in GEOMETRY_TYPES:
            continue
        counts = _object_final(other, x)
        made += 2 * counts.e
        if intersections:
            made += 2 * max(0, counts.c - 2 * counts.f)
    return _gp(c, c.v + made)


def _g_gp_length(x, c):
    # Without Curvature the ends are moved; with it, points are added along
    # the extension, Point Density a unit of length.
    if not x.get('use_curvature'):
        return c
    points, strokes, length = _gp_measures(x.walk.obj, x.s)
    if x.get('mode') == 'ABSOLUTE':
        extension = strokes * (abs(float(x.get('start_length'))) + abs(float(x.get('end_length'))))
    else:
        extension = length * (abs(float(x.get('start_factor'))) + abs(float(x.get('end_factor'))))
    return _gp(c, c.v + int(math.ceil(float(x.get('point_density')) * extension)) + 2 * strokes)


# --------------------------------------------------------------------------
# Metaballs: the app draws them (the mirror walks META objects), and Blender
# polygonizes every metaball object of a family into its basis (the one whose
# name ends in no digit: BKE_mball_is_basis), the others making nothing.
# Round 4's fix-round review: they were outside the budget — the Operator
# Search's Add ▸ Metaball, then the Data API row's element Radius 8 and
# Resolution 0.01, counted 0 and Blender made 3,987,960 in 111.9 s.

def _family_base(name):
    head, dot, tail = name.rpartition('.')
    return head if dot and tail.isdigit() else name


def _is_basis(obj):
    return not obj.name[-1:].isdigit()


def meta_family(obj):
    """(the basis that polygonizes `obj`'s family, every META object of it)."""
    base = _family_base(obj.name)
    family = [o for o in bpy.data.objects if o.type == 'META' and _family_base(o.name) == base]
    basis = next((o for o in family if _is_basis(o)), None)
    return basis, family


def _meta_element_bound(element, s, scale):
    """An element's share of the bound: the surface of a box around where its
    field is above zero (its radius past its sizes), in the basis's units."""
    radius = abs(float(s.get(element, 'radius')))
    size = 0.0
    if s.get(element, 'type') != 'BALL':
        size = max(abs(float(s.get(element, k))) for k in ('size_x', 'size_y', 'size_z'))
    extent = scale * (radius + size)
    return 24.0 * extent * extent


def _meta_base(obj, s):
    """An upper bound of the vertices Blender's polygonization makes of `obj`'s
    family at its resolution: twice the surface of a box around each element's
    field, over the resolution squared. Measured (desktop 5.2.1) on Ball,
    Capsule, Plane, Ellipsoid and Cube elements at radius 2 and 4, resolution
    0.4 to 0.05 and threshold 0.01 to 1.9: at most 0.80 of the box's surface
    over the resolution squared (a Cube at threshold 0.01). The field of an
    element is zero past its radius (`densfunc`), so the surface is inside
    the boxes whatever the threshold. Nothing for a family member that is not
    its basis. Its time does not follow the count alone (`meta_seconds`):
    the count of elements polygonized is kept in `s.meta_elements`."""
    basis, family = meta_family(obj)
    if basis is not None and basis != obj:
        return Counts(0, 0, 0, 0)
    data = s.get(obj, 'data')
    if data is None:
        return Counts(0, 0, 0, 0)
    resolution = float(s.get(data, 'render_resolution' if s.render else 'resolution'))
    if resolution <= 0:
        return Counts(BUDGET * 1000, 0, 0, 0, False)
    inverse = _matrix(obj, s).inverted_safe()
    area = 0.0
    elements = 0
    for member in family:
        member_data = s.get(member, 'data')
        if member_data is None:
            continue
        relative = inverse @ _matrix(member, s)
        scale = max(relative.col[i].xyz.length for i in range(3))
        for element in member_data.elements:
            area += _meta_element_bound(element, s, scale)
            elements += 1
    for element in s.added_elements.get(_pointer(obj), ()):
        area += element
        elements += 1
    s.meta_elements[_pointer(obj)] = elements
    v = 2.0 * area / (resolution * resolution)
    v = int(min(v, 1e15)) + 8 if math.isfinite(v) else BUDGET * 1000
    return Counts(v, 3 * v, 2 * v, 6 * v, False)


# How long a metaball family's polygonization may take, in seconds on a
# desktop Mac, as Subdivision Surface's limit surface may (SUBDIVISION_SECONDS).
METABALL_SECONDS = 5.0
# Its time: Blender evaluates every element's field at every point it tracks
# the surface through (`metaball`, mball_tessellate.cc, a BVH of the elements'
# boxes that measured no faster than that), so the time goes with the
# vertices times the elements. Measured in desktop 5.2.1, Radius 2 balls at
# Resolution 0.05 and 0.1: 2.0 to 3.5 × 10⁻⁸ s per vertex and element — 64
# apart, 638,976 vertices in 1.27 s; 128 apart, 1,277,952 in 5.79 s; 16, 64,
# 128 and 256 in one place, 6,552 to 26,064 vertices in 0.013 to 0.066 s.
# Rounded up, against the count's bound (`_meta_base`), which the time is
# then a bound of too. Round 4's second fix-round review: a family Duplicated
# to 128 elements, 1,996,800 vertices by the count and inside the budget,
# took 16.4 s, and 256 took 62.9 s (this says 10.2 and 40.9).
METABALL_SECONDS_PER_VERTEX_ELEMENT = 4e-8


def meta_seconds(obj, s, count):
    """The seconds a metaball family's basis `obj` takes to polygonize at
    most, from the count's bound (`count`) and the elements it polygonizes."""
    elements = s.meta_elements.get(_pointer(obj), 0)
    return METABALL_SECONDS_PER_VERTEX_ELEMENT * float(count) * float(elements)


def base_counts(obj, s=None):
    """(vertices, edges, faces, corners) of what `obj`'s modifiers are given:
    a mesh's own, or what Blender makes of a text, curve or surface."""
    own = s is None
    s = s or Prices()
    try:
        return _base(obj, s).tuple()
    finally:
        if own:
            s.close()


# --------------------------------------------------------------------------
# Measuring a mesh Blender made


def _bulk(mesh, name, field, out, fallback, fallback_field):
    """Fills `out` with the attribute `name`'s `field`, or — where the mesh
    has no such attribute of that size — with `fallback`'s `fallback_field`
    (the same numbers, read element by element)."""
    attribute = mesh.attributes.get(name) if hasattr(mesh, 'attributes') else None
    if attribute is not None:
        data = attribute.data
        width = len(out) // max(1, len(data)) if len(data) else 0
        if len(data) and width * len(data) == len(out):
            try:
                data.foreach_get(field, out)
                return
            except (TypeError, RuntimeError, AttributeError):
                pass
    fallback.foreach_get(fallback_field, out)


class Measures:
    """What a count needs from a mesh beyond its size: its bounds, and the
    area, mean curvature and pieces Remesh's estimate reads."""

    def __init__(self, mesh):
        import numpy as np
        self.counts = _counts_of(mesh)
        n = self.counts.v
        # Read through the mesh's attributes where it has them: Blender hands
        # an attribute's array over whole, where `vertices`, `loops` and
        # `polygons` go element by element through RNA. Measured in desktop
        # 5.2.1 on a 400 × 400 grid under a Solidify (321,602 vertices,
        # 1,286,400 corners), under a load average of 160: corners' vertices
        # 0.16 ms against 74 through `loops`, positions 0.25 against 6.8, face
        # normals 0.26 against 22.7, the triangles' faces 0.05 against 35.7 —
        # and the same numbers each time. The whole of this took 440 ms there,
        # once for each mesh a price evaluates.
        co = np.empty(3 * n, dtype=np.float32)
        if n:
            _bulk(mesh, 'position', 'vector', co, mesh.vertices, 'co')
        self.co = co.reshape(-1, 3).astype(np.float64)
        if n:
            self.lo, self.hi = self.co.min(axis=0), self.co.max(axis=0)
        else:
            self.lo = self.hi = np.zeros(3)
        self.size = self.hi - self.lo
        f, c, e = self.counts.f, self.counts.c, self.counts.e
        self.areas = np.empty(f, dtype=np.float32)
        self.normals = np.empty(3 * f, dtype=np.float32)
        self.totals = np.empty(f, dtype=np.int32)
        self.corner_edges = np.empty(c, dtype=np.int32)
        self.corner_verts = np.empty(c, dtype=np.int32)
        self.ends = np.empty(2 * e, dtype=np.int32)
        if f:
            normals = getattr(mesh, 'polygon_normals', None)
            if normals is not None and len(normals) == f:
                normals.foreach_get('vector', self.normals)
            else:
                mesh.polygons.foreach_get('normal', self.normals)
            # A face's area as its triangles have it, which is what OpenVDB is
            # given: a polygon's own `area` is its outline's projection, and a
            # twisted quad's is far less. Found by the completeness check: a
            # Bézier ribbon extruded 64 with Twist Tangent has faces of 260 m²
            # by `area` and 17,732 m² as triangles, and a Remesh at 0.2 made
            # 201,518 vertices where the polygon areas said 65,590.
            mesh.calc_loop_triangles()
            t = len(mesh.loop_triangles)
            triangle_areas = np.empty(t, dtype=np.float32)
            faces = np.empty(t, dtype=np.int32)
            if t:
                mesh.loop_triangles.foreach_get('area', triangle_areas)
                polygons = getattr(mesh, 'loop_triangle_polygons', None)
                if polygons is not None and len(polygons) == t:
                    polygons.foreach_get('value', faces)
                else:
                    mesh.loop_triangles.foreach_get('polygon_index', faces)
            self.areas = np.bincount(faces, weights=triangle_areas.astype(np.float64), minlength=f)
            # Every face of n corners is n - 2 of Blender's triangles, so the
            # triangles' faces give each face's size (held equal to
            # `loop_total` by tests/budget/blender/frames.py).
            if t == c - 2 * f:
                self.totals = (np.bincount(faces, minlength=f) + 2).astype(np.int32)
            else:
                mesh.polygons.foreach_get('loop_total', self.totals)
        if c:
            _bulk(mesh, '.corner_edge', 'value', self.corner_edges, mesh.loops, 'edge_index')
            _bulk(mesh, '.corner_vert', 'value', self.corner_verts, mesh.loops, 'vertex_index')
        if e:
            _bulk(mesh, '.edge_verts', 'value', self.ends, mesh.edges, 'vertices')
        self.ends = self.ends.reshape(-1, 2)
        self.normals = self.normals.reshape(-1, 3).astype(np.float64)
        self.weights = None
        attribute = mesh.attributes.get('bevel_weight_edge') if hasattr(mesh, 'attributes') else None
        if attribute is not None and attribute.domain == 'EDGE' and e:
            weights = np.empty(e, dtype=np.float32)
            if getattr(mesh, 'is_editmode', False):
                # In Edit Mode a mesh's attributes are its edit mesh's layers,
                # which RNA hands over element by element only: measured in
                # desktop 5.2.1, `foreach_get` raised "sequence length
                # mismatch, needed 0" after `update_from_editmode` too (round
                # 4's fix round 2, pricing the Item tab's Bevel Weight). Read
                # from a copy, a mesh of its own (its arrays are shared, not
                # copied: one copy cost 2 ms on a 90,601-vertex grid).
                copy = mesh.copy()
                try:
                    copy.attributes['bevel_weight_edge'].data.foreach_get('value', weights)
                finally:
                    bpy.data.meshes.remove(copy)
            else:
                attribute.data.foreach_get('value', weights)
            self.weights = weights
        self._remesh = None
        self._angles = None

    def edge_angles(self):
        """(faces using each edge, the angle between its two faces' normals, or
        90° where it has not two — Blender's `BM_edge_calc_face_angle`
        fallback, which its Bevel's angle limit uses)."""
        if self._angles is None:
            import numpy as np
            e = self.counts.e
            uses = np.bincount(self.corner_edges, minlength=e) if e else np.zeros(0, int)
            angles = np.full(e, math.pi / 2)
            if self.counts.f and e:
                corner_face = np.repeat(np.arange(self.counts.f), self.totals)
                order = np.argsort(self.corner_edges, kind='stable')
                first = np.searchsorted(self.corner_edges[order], np.arange(e))
                two = np.nonzero(uses == 2)[0]
                f1 = corner_face[order[first[two]]]
                f2 = corner_face[order[first[two] + 1]]
                dots = np.clip(np.einsum('ij,ij->i', self.normals[f1], self.normals[f2]), -1.0, 1.0)
                angles[two] = np.arccos(dots)
            self._angles = (uses, angles)
        return self._angles

    def remesh(self):
        """(area, mean curvature, pieces) as `_blenderkit_sculpt.remesh_measures`
        reads them — an open loose piece's area twice, the total mean
        curvature with an open or non-manifold edge a fold of 180°, the loose
        pieces with faces — with numpy, in a few passes (the Python walk
        took seconds at a million faces)."""
        if self._remesh is None:
            import numpy as np
            if not self.counts.f:
                self._remesh = (0.0, 0.0, 0)
                return self._remesh
            uses, angles = self.edge_angles()
            a, b = self.ends[:, 0], self.ends[:, 1]
            lengths = np.linalg.norm(self.co[a] - self.co[b], axis=1)
            two = uses == 2
            other = (uses != 2) & (uses != 0)
            curvature = float((lengths[two] * angles[two] / 2.0).sum() + (lengths[other] * math.pi / 2.0).sum())
            root = _components(self.counts.v, a, b)
            corner_face = np.repeat(np.arange(self.counts.f), self.totals)
            starts = np.concatenate(([0], np.cumsum(self.totals)[:-1]))
            face_root = root[self.corner_verts[starts]]
            opened = np.zeros(self.counts.v, dtype=bool)
            open_edges = np.nonzero(uses == 1)[0]
            opened[root[a[open_edges]]] = True
            weights = np.where(opened[face_root], 2.0, 1.0)
            area = float((self.areas.astype(np.float64) * weights).sum())
            pieces = int(len(np.unique(face_root)))
            del corner_face
            self._remesh = (area, curvature, pieces)
        return self._remesh


def _components(n, a, b):
    """Each vertex's component (the smallest index in it), over edges a-b:
    hooking each root to the smaller one and halving paths, which a mesh's
    edges settle in a few dozen passes."""
    import numpy as np
    parent = np.arange(n)
    if not len(a):
        return parent
    for _ in range(256):
        pa, pb = parent[a], parent[b]
        if np.array_equal(pa, pb):
            break
        lo, hi = np.minimum(pa, pb), np.maximum(pa, pb)
        np.minimum.at(parent, hi, lo)
        for _ in range(64):
            grand = parent[parent]
            if np.array_equal(grand, parent):
                break
            parent = grand
    return parent


# --------------------------------------------------------------------------
# The stack


# The kinds Blender's Add Modifier puts before the first modifier that is not
# a pure deform, because they need the original mesh (`ED_object_modifier_add`
# with eModifierTypeFlag_RequiresOriginalData): Multires.
_ONLY_DEFORM = {'ARMATURE', 'CAST', 'CURVE', 'DISPLACE', 'HOOK', 'LAPLACIANDEFORM', 'LATTICE',
                'MESH_DEFORM', 'SHRINKWRAP', 'SIMPLE_DEFORM', 'SMOOTH', 'CORRECTIVE_SMOOTH',
                'LAPLACIANSMOOTH', 'SURFACE_DEFORM', 'WARP', 'WAVE', 'MESH_CACHE', 'CLOTH',
                'COLLISION', 'SOFT_BODY', 'SURFACE', 'PARTICLE_SYSTEM'}


def _insert_new(modifiers, virtual):
    """Where Blender's Add Modifier puts a new modifier: a Multires before the
    first that is not a pure deform, anything else last but ahead of the
    modifiers pinned to last (measured: the new Remesh is `modifiers.active`
    and sits above a pinned one)."""
    if virtual.type == 'MULTIRES':
        for i, m in enumerate(modifiers):
            if getattr(m, 'type', None) not in _ONLY_DEFORM:
                return i
        return len(modifiers)
    i = len(modifiers)
    while i > 0 and getattr(modifiers[i - 1], 'use_pin_to_last', False):
        i -= 1
    return i


def _stack(obj, s):
    p = _pointer(obj)
    order = s.orders.get(p)
    modifiers = [obj.modifiers[n] for n in order] if order is not None else list(obj.modifiers)
    for where, virtual in s.added.get(p, ()):
        if where == 'new':
            modifiers.insert(_insert_new(modifiers, virtual), virtual)
        elif where == 'last':
            modifiers.insert(_insert_new(modifiers, Virtual('ARRAY')), virtual)
        else:  # right after the named modifier: the search's Copy
            index = next((i for i, m in enumerate(modifiers) if getattr(m, 'name', None) == where),
                         len(modifiers) - 1)
            modifiers.insert(index + 1, virtual)
    return modifiers


def _shown(m, s):
    if isinstance(m, Virtual) or _pointer(m) in s.shown:
        return True
    return bool(s.get(m, 'show_render' if s.render else 'show_viewport'))


class _Step:
    """One modifier being counted: what it is given and where, with access to
    the changes (`get`) and to Blender's evaluation of what it is given
    (`measures`)."""

    def __init__(self, walk, index, modifier, counts):
        self.walk, self.index, self.modifier, self.counts = walk, index, modifier, counts
        self.s = walk.s
        self.position = len(walk.steps) - 1  # its place among the shown steps

    def get(self, key, owner=None):
        return self.s.get(self.modifier if owner is None else owner, key)

    def measures(self):
        """Blender's own mesh of the stack up to this modifier, measured — only
        while the count up to here is inside the budget (`Unpriceable`
        otherwise)."""
        return self.walk.measures(self.index, self.counts)

    def limit_seconds(self):
        """How long Blender's Subdivision Surface takes to build its limit
        surface for what this modifier is given (`_limit_seconds`), read from
        the object's own mesh when only deforms come before it, else from
        Blender's evaluation up to here (`measures`)."""
        earlier = self.walk.steps[:self.position]
        obj = self.walk.obj
        if (obj.type == 'MESH' and _pointer(obj) not in self.s.bases
                and all(m.type in _KEEPS_TOPOLOGY for m, _ in earlier)):
            mesh = self.s.data_of(obj)
            import numpy as np
            ends = np.empty(2 * len(mesh.edges), dtype=np.int32)
            totals = np.empty(len(mesh.polygons), dtype=np.int32)
            if len(ends):
                mesh.edges.foreach_get('vertices', ends)
            if len(totals):
                mesh.polygons.foreach_get('loop_total', totals)
            return _limit_seconds(ends, totals, len(mesh.vertices))
        m = self.measures()
        return _limit_seconds(m.ends.ravel(), m.totals, m.counts.v)

    def loose(self):
        """The vertices no face uses in what this modifier is given, or None
        when that would take an evaluation Blender is slow on or one past the
        budget. Read from the object's own mesh when this is the first
        modifier shown (a numpy pass over its corners), else from Blender's
        evaluation up to here."""
        earlier = self.walk.steps[:-1]
        obj = self.walk.obj
        if not earlier and obj.type == 'MESH' and _pointer(obj) not in self.s.bases:
            return _loose_vertices(self.s.get(obj, 'data'))
        if any(m.type in _SLOW for m, _ in earlier) or self.counts.v > BUDGET:
            return None
        m = self.measures()
        return max(0, m.counts.v - _used_vertices(m.corner_verts, m.counts.v))


def _fill(counts, v, exact=False):
    """Counts with `v` vertices, the rest at most what Blender's generators
    make per vertex: measured on Bevel's results over eight meshes, every
    affect, miter and vertex mesh method and 1 to 12 segments, at most 2.07
    edges, 1.08 faces and 4.14 corners a vertex; rounded up."""
    return Counts(v, math.ceil(2.25 * v), math.ceil(1.25 * v), math.ceil(4.5 * v), exact)


def _triangulated(c):
    """Every face split into triangles: n - 2 per n-gon, a new edge for each
    but one of them; vertices kept."""
    tris = max(0, c.c - 2 * c.f)
    return Counts(c.v, c.e + max(0, c.c - 3 * c.f), tris, 3 * tris, c.exact)


# -- one function per modifier type that makes or changes geometry --------

def _simplified(x, level):
    """`level` as the scene's Simplify holds it: Blender takes the lower of a
    Subdivision Surface's or Multires's level and Simplify's Max Subdivision
    when Simplify is on (`get_render_subsurf_level`, `multires_get_level`).
    The setting is the scene's, so turning Simplify off is a change the gate
    prices, as any other setting."""
    scene = bpy.context.scene
    render = getattr(scene, 'render', None) if scene is not None else None
    if render is None or not x.s.get(render, 'use_simplify'):
        return level
    cap = x.s.get(render, 'simplify_subdivision_render' if x.s.render else 'simplify_subdivision')
    return min(int(level), int(cap))


def _g_subsurf(x, c):
    return _subdivided(c, _simplified(x, x.get('render_levels' if x.s.render else 'levels')))


# How long Blender's Subdivision Surface may take to build its limit surface,
# in seconds on a desktop Mac (the time's model below). Round 4's fix-round
# review: the time grows far faster than the count on a high-valence vertex
# or a large N-Gon — Add ▸ Circle as an N-Gon of 250 sides (which the
# primitives' NGON_SIDES lets through), then Add Modifier ▸ Subdivision
# Surface, took 8.7 s in desktop 5.2.1; 500 sides 119 s; 1,000 not done in
# 170 s. Measured here (desktop 5.2.1, level 1, Quality 3, the limit surface
# on): an N-Gon's time in a cylinder's cap 3, 17, 154 and 1,735 ms at 16,
# 32, 64 and 128 sides (alone 1, 5, 50 and 648 ms; a vertex of that many
# quads 1, 9, 99 and 1,247), and on meshes of triangles about 0.1 ms per
# vertex and face that is not regular — a 40,962-vertex icosphere took 12.2 s,
# a 200 × 200 grid in triangles 11.4 s, a quad cube of 24,578 0.08 s. The
# level does not matter (a 100-gon: 0.13 s at levels 1 and 3) and Blender
# keeps what it built (level 1 → 2 afterwards: 0.01 s; at level 0 it builds
# nothing, 0.00 s). With Use Limit Surface off, 0.00 s at 200 sides.
SUBDIVISION_SECONDS = 5.0
# The kinds that leave the vertices and faces a Subdivision is given as they
# are (pure deforms and attribute writers), so its time can be read from the
# object's own mesh.
_KEEPS_TOPOLOGY = {'ARMATURE', 'CAST', 'CURVE', 'DISPLACE', 'HOOK', 'LAPLACIANDEFORM', 'LATTICE',
                   'MESH_DEFORM', 'SHRINKWRAP', 'SIMPLE_DEFORM', 'SMOOTH', 'CORRECTIVE_SMOOTH',
                   'LAPLACIANSMOOTH', 'SURFACE_DEFORM', 'WARP', 'WAVE', 'MESH_CACHE', 'DATA_TRANSFER',
                   'UV_PROJECT', 'UV_WARP', 'VERTEX_WEIGHT_EDIT', 'VERTEX_WEIGHT_MIX',
                   'VERTEX_WEIGHT_PROXIMITY', 'NORMAL_EDIT', 'WEIGHTED_NORMAL'}


def _limit_seconds(ends, totals, n):
    """The seconds the limit surface's build takes at Quality 3, an upper
    bound fitted to the measurements above: 0.1 ms for each vertex that does
    not have four edges and each face that does not have four sides, and for
    one with k > 8 of them 0.154 s × (k / 64)^3.5 (a cylinder cap's N-Gon,
    the slowest context measured; at 250 sides it says 18 s against the
    review's 8.7, at 500 205 s against 119)."""
    import numpy as np
    valence = np.bincount(ends, minlength=n) if len(ends) else np.zeros(0, dtype=np.int64)
    valence = valence[valence > 0]
    totals = np.asarray(totals)
    seconds = 1e-4 * (int((valence != 4).sum()) + int((totals != 4).sum()))
    high = np.concatenate([valence[valence > 8], totals[totals > 8]]).astype(np.float64)
    if len(high):
        seconds += float((0.154 * (high / 64.0) ** 3.5).sum())
    return seconds


def _quality_factor(quality):
    """How the build's time goes with Quality: measured on an icosphere and a
    grid of triangles, Quality 1 took 0.18 to 0.23 of Quality 3's time and
    Quality 6 2.2 to 3.1 times it."""
    q = max(1, int(quality))
    return q / 3.0 if q <= 3 else (q / 3.0) ** 1.7


def _subdivision_seconds(w):
    """(the most seconds any Subdivision Surface in the walk takes to build
    its limit surface, its name)."""
    worst = (0.0, None)
    for step in w.subdivisions:
        x = step
        if x.modifier.type == 'MULTIRES':
            if x.s.render:
                level = x.get('render_levels')
            else:
                level = x.get('sculpt_levels') if x.walk.sculpt else _simplified(x, x.get('levels'))
            if int(level) < 1:
                continue
            seconds = x.limit_seconds() * MULTIRES_TIME
        else:
            level = _simplified(x, int(x.get('render_levels' if x.s.render else 'levels')))
            if level < 1 or not x.get('use_limit_surface'):
                continue
            seconds = x.limit_seconds() * _quality_factor(x.get('quality'))
        if seconds > worst[0]:
            worst = (seconds, x.modifier.name)
    return worst


def _g_multires(x, c):
    if x.s.render:
        level = x.get('render_levels')
    else:
        level = x.get('sculpt_levels') if x.walk.sculpt else x.get('levels')
    total = x.get('total_levels')
    level = min(int(level), int(total)) if total is not None else level
    if not x.walk.sculpt:
        level = _simplified(x, level)
    return _subdivided(c, level)


# An object's own channels that place it (what `matrix_basis` is made of),
# and what puts it under its parent.
_TRANSFORM_KEYS = ('location', 'rotation_euler', 'rotation_quaternion', 'rotation_axis_angle',
                   'rotation_mode', 'scale', 'delta_location', 'delta_rotation_euler',
                   'delta_rotation_quaternion', 'delta_scale', 'matrix_parent_inverse', 'parent',
                   'parent_type', 'parent_bone', 'parent_vertices', 'track_axis', 'up_axis')


def _channels_of(obj, key, value, s):
    """The channels Blender sets for a matrix written to `obj.key`
    (`matrix_world`, `matrix_local` or `matrix_basis`), as changes."""
    from mathutils import Matrix, Vector
    try:
        m = Matrix(value)
    except (TypeError, ValueError):
        flat = list(value)
        m = Matrix([flat[i:i + 4] for i in range(0, 16, 4)])
    parent = s.get(obj, 'parent')
    inverse = Matrix(s.get(obj, 'matrix_parent_inverse'))
    if key == 'matrix_world' and parent is not None:
        m = (_matrix(parent, s) @ inverse).inverted_safe() @ m
    elif key == 'matrix_local' and parent is not None:
        m = inverse.inverted_safe() @ m
    location, rotation, scale = m.decompose()
    dscale = Vector(obj.delta_scale)
    found = {'location': tuple(location - Vector(obj.delta_location)),
             'scale': tuple(scale[i] / dscale[i] if dscale[i] else scale[i] for i in range(3))}
    mode = obj.rotation_mode
    if mode == 'QUATERNION':
        found['rotation_quaternion'] = tuple(rotation)
    elif mode == 'AXIS_ANGLE':
        axis, angle = rotation.to_axis_angle()
        found['rotation_axis_angle'] = (angle,) + tuple(axis)
    else:
        found['rotation_euler'] = tuple(rotation.to_euler(mode))
    return found


def _own_moves(obj, s):
    """(key, value) of each change to `obj`'s own channels."""
    if not s.values:
        return []
    p = _pointer(obj)
    return [(key, value) for (q, key), value in s.values.items() if q == p and key in _TRANSFORM_KEYS]


def _flag(s, owner, key, default):
    try:
        return s.get(owner, key) if s is not None else getattr(owner, key)
    except AttributeError:
        return default


def _acting(obj, s=None):
    """`obj`'s constraints that act, as the changes leave them: on (Enabled,
    as the gate's price reads a new one it has turned off for the price)."""
    # Not `mute`: Blender keeps it as the inverse of Enabled (measured, a
    # constraint turned off reads mute True), so it says nothing more and
    # would read the switch as it is, not as the change leaves it.
    return [c for c in getattr(obj, 'constraints', ()) if _flag(s, c, 'enabled', True)]


# A constraint's settings that name another object whose place it reads.
_TARGET_KEYS = ('target', 'pole_target', 'space_object', 'camera', 'depth_object')


def _constraint_targets(obj, s=None):
    """The objects `obj`'s constraints that are on read for where it is —
    and those of the constraints an operator would add (`constraints_added`)."""
    found = []
    acting = _acting(obj, s)
    if s is not None:
        for added in s.constraints_added.get(_pointer(obj), ()):
            if isinstance(added, tuple):
                if added[1] is not None:
                    found.append(added[1])
            else:
                acting.append(added)
    for c in acting:
        for key in _TARGET_KEYS:
            target = _flag(s, c, key, None)
            if isinstance(target, bpy.types.Object):
                found.append(target)
        for t in getattr(c, 'targets', ()) or ():
            if getattr(t, 'target', None) is not None:
                found.append(t.target)
    return found


def _constraint_of(owner):
    """(the constraint `owner` is or is in, the path inside it: '' for the
    constraint itself, `targets[0]` for an Armature constraint's target), or
    (None, None). Round 4's fix round 2 review: an Armature constraint's
    target weight, 0 to 1, moved an Array's offset object unpriced — a
    change to a constraint's item read as no constraint change."""
    if isinstance(owner, bpy.types.Constraint):
        return owner, ''
    try:
        path = owner.path_from_id()
        block = owner.id_data
    except (AttributeError, ReferenceError, ValueError, RuntimeError):
        return None, None
    import re
    match = re.match(r'^((?:pose\.bones\[".*?"\]\.)?constraints\[".*?"\])\.(.+)$', path)
    if match is None:
        return None, None
    try:
        return block.path_resolve(match.group(1)), match.group(2)
    except (ValueError, AttributeError):
        return None, None


def _pose_changed(obj, s):
    """Whether a change reaches `obj`'s pose (a pose bone's channels or
    constraints): what an Armature modifier, a bone parent or a bone target
    reads."""
    if obj is None or getattr(obj, 'type', None) != 'ARMATURE' or not s.values:
        return False
    return any((isinstance(owner, (bpy.types.PoseBone, bpy.types.Constraint))
                or _constraint_of(owner)[0] is not None) and owner != obj
               for owner, key, value in s.changes_on(obj))


def _constraints_changed(obj, s):
    if _pointer(obj) in s.constraints_added:
        return True
    return any(_constraint_of(owner)[0] is not None for owner, key, value in s.changes_on(obj))


def _moves(obj, s):
    """Whether the changes put `obj` somewhere else: its own channels, its
    constraints' settings, its parent's place — a bone parent's pose, a
    vertex parent's mesh — or a constraint's target's (round 4's fix-round
    review: an Array's offset object under an empty, the empty moved through
    the Data API row, was counted where it was — 88 vertices — and Blender
    made 3,994,576; its second review: an object parented to a vertex of a
    mesh whose vertex the row moved, 328 → 3,199,472, and a Copy Location
    added through the Constraints tab, 328 → 3,200,008)."""
    if obj is None or not (s.values or s.constraints_added):
        return False
    p = _pointer(obj)
    if p in s._moving:
        return s._moving[p]
    s._moving[p] = False  # a constraint cycle reads as not moving, once
    moving = bool(_own_moves(obj, s)) or _constraints_changed(obj, s)
    if not moving:
        parent = s.get(obj, 'parent')
        if parent is not None:
            kind = s.get(obj, 'parent_type')
            moving = _moves(parent, s)
            if not moving and kind in ('VERTEX', 'VERTEX_3'):
                moving = _dirty(parent, s)
            elif not moving and kind == 'BONE':
                moving = _pose_changed(parent, s)
    if not moving:
        # A target that moves, or whose mesh, curve or pose changes (Shrinkwrap,
        # Follow Path, a vertex group or a bone of it): Blender is asked.
        moving = any(_moves(t, s) or _pose_changed(t, s) or _dirty(t, s) for t in _constraint_targets(obj, s))
    s._moving[p] = moving
    return moving


def _basis(obj, s, own):
    """`obj`'s `matrix_basis` with its own channel changes made, by Blender's
    arithmetic (BKE_object_to_mat4): the location plus its delta, then the
    delta rotation times the rotation (each in the rotation mode, a
    quaternion normalized first), then the scale times its delta. Held equal
    to `matrix_basis` by the budget's check over every rotation mode."""
    if not own:
        return obj.matrix_basis.copy()
    from mathutils import Matrix, Vector, Euler, Quaternion
    mode = s.get(obj, 'rotation_mode')
    if mode == 'QUATERNION':
        rotation = (Quaternion(s.get(obj, 'delta_rotation_quaternion')).normalized().to_matrix()
                    @ Quaternion(s.get(obj, 'rotation_quaternion')).normalized().to_matrix())
    elif mode == 'AXIS_ANGLE':
        angle, *axis = s.get(obj, 'rotation_axis_angle')
        axis = Vector(axis)
        rotation = (Quaternion(axis.normalized(), angle).to_matrix() if axis.length > 0
                    else Matrix.Identity(3))
    else:
        rotation = (Euler(s.get(obj, 'delta_rotation_euler'), mode).to_matrix()
                    @ Euler(s.get(obj, 'rotation_euler'), mode).to_matrix())
    scale = Vector(s.get(obj, 'scale'))
    dscale = Vector(s.get(obj, 'delta_scale'))
    m = (rotation @ Matrix.Diagonal(Vector((scale.x * dscale.x, scale.y * dscale.y, scale.z * dscale.z)))).to_4x4()
    m.translation = Vector(s.get(obj, 'location')) + Vector(s.get(obj, 'delta_location'))
    return m


def _matrix(obj, s):
    """`obj`'s world matrix once the changes are made: its own channels
    (location, rotation, scale and their deltas, Dimensions as the scale they
    set, a matrix as the channels it sets), its parent's place and its
    constraints' targets' — each as Blender has it now when nothing it reads
    changes. A constraint's own arithmetic is not redone: what it adds is
    kept as it is now, and a target's move carried over to what follows it."""
    if obj is None:
        from mathutils import Matrix
        return Matrix.Identity(4)
    if not _moves(obj, s):
        return obj.matrix_world.copy()
    p = _pointer(obj)
    if p in s._worlds:
        return s._worlds[p].copy()
    from mathutils import Matrix
    own = _own_moves(obj, s)
    parent = s.get(obj, 'parent')
    basis = _basis(obj, s, own)
    inverse = Matrix(s.get(obj, 'matrix_parent_inverse'))
    constrained = bool(_acting(obj, s)) or bool(s.constraints_added.get(p))
    plain = (not constrained and (parent is None or s.get(obj, 'parent_type') == 'OBJECT'))
    if plain:
        world = (_matrix(parent, s) @ inverse if parent is not None else Matrix.Identity(4)) @ basis
    else:
        # A constraint's arithmetic, a bone's pose or a vertex's place: Blender
        # evaluates them, on a stand-in (round 4's fix-round review: the
        # constraint's arithmetic kept as it was missed a Copy Location added
        # through the Constraints tab, 328 → 3,200,008).
        world = _world_by_blender(obj, s)
    s._worlds[p] = world
    return world.copy()


def _place_of(other, s, needs=None):
    """What stands in for `other` as a parent or a constraint's target while
    a stand-in is evaluated: `other` itself when nothing it is or reads
    changes; else a copy with the changes made (`_stand_in`) where its pose
    or its mesh is read (a bone, a vertex, a vertex group, a surface, a
    path), or an empty where it would be."""
    if other is None:
        return None
    if not (_moves(other, s) or _pose_changed(other, s) or _dirty(other, s)):
        return other
    if needs == 'shape' or other.type == 'ARMATURE' or (needs == 'vertex' and other.type in GEOMETRY_TYPES):
        return _stand_in(other, s)
    place = bpy.data.objects.new("Blender Local place", None)
    s._objects.append(place)
    place.matrix_world = _matrix(other, s)
    bpy.context.scene.collection.objects.link(place)
    return place


# The constraint types whose target is read for more than where it is: its
# pose, its mesh or its curve.
_SHAPE_TARGETS = ('SHRINKWRAP', 'FOLLOW_PATH', 'CLAMP_TO', 'SPLINE_IK', 'GEOMETRY_ATTRIBUTE', 'ARMATURE')


def _retarget(c, s):
    """Each object a stand-in's constraint `c` reads, replaced by what stands
    in for it (`_place_of`)."""
    needs = 'shape' if c.type in _SHAPE_TARGETS or getattr(c, 'subtarget', '') else None
    for key in _TARGET_KEYS:
        target = getattr(c, key, None)
        if isinstance(target, bpy.types.Object):
            place = _place_of(target, s, needs)
            if place is not target:
                try:
                    setattr(c, key, place)
                except (TypeError, ValueError, AttributeError):
                    pass
    for t in getattr(c, 'targets', ()) or ():
        target = getattr(t, 'target', None)
        if target is not None:
            place = _place_of(target, s, 'shape')
            if place is not target:
                t.target = place


def _world_by_blender(obj, s):
    """`obj`'s world matrix with the changes made, evaluated by Blender: an
    empty with `obj`'s channels as they would be, under what stands in for
    its parent (`_place_of`: a bone parent's pose and a vertex parent's mesh
    as they would be), with copies of its constraints — their settings as
    they would be, the ones an operator would add, every object they read
    standing in for itself — linked in the scene and evaluated. Measured in
    desktop 5.2.1: a Copy Location to an empty at 0.0001 m and a Limit
    Rotation copied onto an empty put it at 0.0001, as on the object."""
    from mathutils import Matrix
    p = _pointer(obj)
    if p in s._placing:
        # Two objects whose constraints read each other: Blender breaks the
        # cycle somewhere; where it is now stands in.
        return obj.matrix_world.copy()
    s._placing.add(p)
    try:
        e = bpy.data.objects.new("Blender Local place", None)
        s._objects.append(e)
        e.rotation_mode = s.get(obj, 'rotation_mode')
        for key in ('location', 'rotation_euler', 'rotation_quaternion', 'rotation_axis_angle', 'scale',
                    'delta_location', 'delta_rotation_euler', 'delta_rotation_quaternion', 'delta_scale'):
            setattr(e, key, s.get(obj, key))
        parent = s.get(obj, 'parent')
        if parent is not None:
            kind = s.get(obj, 'parent_type')
            stand = _place_of(parent, s, 'vertex' if kind in ('VERTEX', 'VERTEX_3') else None)
            if kind == 'BONE' and stand is not None and stand.type != 'ARMATURE':
                stand = parent
            e.parent = stand
            try:
                e.parent_type = kind
            except (TypeError, ValueError):
                pass
            if kind == 'BONE':
                e.parent_bone = s.get(obj, 'parent_bone')
            elif kind in ('VERTEX', 'VERTEX_3'):
                e.parent_vertices = s.get(obj, 'parent_vertices')
            e.matrix_parent_inverse = Matrix(s.get(obj, 'matrix_parent_inverse'))
        changed = {}
        for owner, key, value in s.changes_on(obj):
            constraint, inner = _constraint_of(owner)
            if constraint is not None:
                changed.setdefault(_pointer(constraint), []).append((inner, key, value))
        for c in obj.constraints:
            made = e.constraints.copy(c)
            for inner, key, value in changed.get(_pointer(c), ()):
                try:
                    setattr(made.path_resolve(inner) if inner else made, key, value)
                except (TypeError, ValueError, AttributeError):
                    pass
            _retarget(made, s)
        for added in s.constraints_added.get(p, ()):
            if isinstance(added, tuple):
                kind, target = added
                made = e.constraints.new(kind)
                if target is not None and hasattr(made, 'target'):
                    try:
                        made.target = target
                    except (TypeError, ValueError):
                        pass
            else:
                made = e.constraints.copy(added)
            _retarget(made, s)
        bpy.context.scene.collection.objects.link(e)
        _depsgraph()
        return e.matrix_world.copy()
    finally:
        s._placing.discard(p)


# How deep a chain of objects read through one another (an Array's caps that
# are themselves arrays with caps, a Boolean's operands) is counted. Past it,
# the count is refused rather than guessed: each level of caps can double
# what the one above it makes, and 2^64 copies is past any budget.
CHAIN_DEPTH = 64


def _object_final(other, x):
    """Counts of another object's evaluated mesh, as a cap or an operand: its
    own model, nothing for an object that makes no mesh or for the object
    itself (Blender skips a cap that is its own object). Counted once per
    pricing, however many ways it is reached: round 4's fix-round review
    chained 19 cubes, each an Array whose Start and End Cap are the next, and
    the old cut-off at depth 3 counted the first at 248 where Blender made
    4,194,296 — counted in full, each level would be counted twice per level
    above it, so 2^19 times, without the memo."""
    if other is None or other == x.walk.obj or other.type not in GEOMETRY_TYPES:
        return Counts(0, 0, 0, 0)
    s = x.s
    key = (_pointer(other), s.render, x.walk.sculpt)
    if key in s._finals:
        return s._finals[key]
    if other in s._visiting:
        raise Unpriceable(
            "%s and %s each read the other's mesh (as a cap or an operand), and Blender would build "
            "one from the other's last result every time it evaluates them, so it cannot be counted; "
            "clear one of them first" % (x.walk.obj.name, other.name))
    if len(s._visiting) >= CHAIN_DEPTH:
        raise Unpriceable(
            "%s reads a chain of more than %d objects (caps or operands of caps), each of which can "
            "double what the one before it makes, so it cannot be counted" % (x.walk.obj.name, CHAIN_DEPTH))
    s._visiting.append(other)
    try:
        made = _walk(other, s).final.bound()
    finally:
        s._visiting.pop()
    s._finals[key] = made
    return made


def _curve_length(curve, s):
    """An upper bound of the path length Blender fits an Array to: every
    spline's length (Blender takes the first spline's) times the curve
    object's largest scale (measured: a 2.08 m Bézier fitted 16 copies of a
    2 m cube; scaled by 10, 88)."""
    if curve is None or curve.type != 'CURVE':
        return 0.0
    data = s.data_of(curve)
    length = 0.0
    for spline in data.splines:
        try:
            length += spline.calc_length()
        except (AttributeError, RuntimeError):
            length += 0.0
    scale = max(abs(k) for k in _matrix(curve, s).to_scale())
    return length * scale


def _g_array(x, c):
    """Copies of the mesh plus its caps. Fixed Count is the count. Fit Length
    and Fit Curve are Blender's own arithmetic (MOD_array.cc): the offset is
    the Constant offset plus the Relative offset times the mesh's size plus,
    with an Object offset, where that object is from this one; the copies
    are (length + 1e-6) / |offset| + 1, or one when the offset is under
    1e-6. Measured exact: a 2 m cube fitted to 0.5, 2, 2.0001, 10, 100 and
    2,000 m made 8, 16, 16, 48, 408 and 8,008 vertices (round 4's review:
    2,000 was counted as one copy). Past Blender's 2^26 vertices it makes
    one copy. Merge only joins vertices, so the count bounds it."""
    caps = _object_final(x.get('start_cap'), x).plus(_object_final(x.get('end_cap'), x))
    fit = x.get('fit_type')
    if fit == 'FIXED_COUNT':
        copies = max(1, int(x.get('count')))
    else:
        from mathutils import Vector
        curve = x.get('curve')
        if fit == 'FIT_CURVE' and curve is not None:
            length = _curve_length(curve, x.s)
        else:
            # Fit Curve with no curve fits the Length (MOD_array.cc starts from
            # it; measured, Fit Curve with none at Length 16 made 9 cubes).
            length = float(x.get('fit_length'))
        offset = Vector((0.0, 0.0, 0.0))
        if x.get('use_constant_offset'):
            offset += Vector(x.get('constant_offset_displace'))
        if x.get('use_relative_offset'):
            scale = Vector(x.get('relative_offset_displace'))
            if scale.length > 0:
                size = x.measures().size
                offset += Vector((scale[0] * size[0], scale[1] * size[1], scale[2] * size[2]))
        other = x.get('offset_object')
        if x.get('use_object_offset') and other is not None:
            here = _matrix(x.walk.obj, x.s)
            try:
                relative = here.inverted() @ _matrix(other, x.s)
            except ValueError:
                relative = here.inverted_safe() @ _matrix(other, x.s)
            offset += relative.translation
        distance = offset.length
        if distance > 1e-6 and math.isfinite(distance) and math.isfinite(length):
            copies = int((length + 1e-6) / distance * (1.0 + 1e-6)) + 1
        else:
            copies = 1
    if copies * c.v + caps.v > ARRAY_LIMIT:
        copies = 1
    merged = x.get('use_merge_vertices')
    made = c.times(copies).plus(caps)
    # Exact where nothing is merged and there are no caps (which were always
    # left a bound) — but for Fit Curve, whose length is a bound.
    made.exact = bool(c.exact and caps.v == 0 and not merged and fit != 'FIT_CURVE')
    return made


def _g_mirror(x, c):
    """One copy per combination of the axes (2, 4 or 8 times): the Mirror
    row's axes went to XYZ unpriced (round 4's review, a Skin then given 793
    loops). Bisect and Merge only remove vertices."""
    axes = x.get('use_axis')
    copies = 2 ** sum(1 for a in axes if a)
    merged = x.get('use_mirror_merge') or any(x.get('use_bisect_axis'))
    return c.times(copies, exact=c.exact and not merged)


def _g_solidify(x, c):
    """Simple: two shells; with Rim Fill a face per boundary edge, which adds
    edges and corners but no vertex (measured on a cube (16), a grid (242
    vertices, 480 edges with the rim) and Suzanne (1,014)). Complex: the same
    on a manifold mesh, but a vertex on a non-manifold edge or point is split
    into one per wedge of faces around it, on each side — at most two per
    corner, and a vertex no face uses kept once. Round 4's fix-round review:
    50 quads sharing one edge (102 vertices) made 300, counted 2V = 204;
    measured here 18, 60, 300 and 1,200 for 3, 10, 50 and 200 such quads, and
    on a bow tie, a grid with fins, a merged triangle soup (202 against
    2C + V = 323) and wires; E′ at most 0.75 of 2E + 2C, F′ at most 2F + E."""
    if x.get('solidify_mode') == 'NON_MANIFOLD':
        return Counts(2 * c.c + c.v, 2 * c.e + 2 * c.c, 2 * c.f + 2 * c.e, 2 * c.c + 8 * c.e, False)
    if x.get('use_rim'):
        return Counts(2 * c.v, 3 * c.e, 2 * c.f + c.e, 2 * c.c + 4 * c.e, False)
    return c.times(2)


def _g_screw(x, c):
    """Each vertex swept steps × iterations times, one ring more when the turn
    is not closed; each edge a strip of faces. Measured exact: the cube at 16
    steps, 128 vertices; Iterations multiplies as Steps does."""
    steps = x.get('render_steps' if x.s.render else 'steps')
    iterations = x.get('iterations')
    turns = max(1, int(steps)) * max(1, int(iterations))
    closed = abs(abs(x.get('angle')) - 2 * math.pi) < 1e-4 and int(iterations) == 1
    rings = turns if closed else turns + 1
    return Counts(rings * c.v, rings * c.e + turns * c.v, turns * c.e, 4 * turns * c.e, c.exact)


def _g_wireframe(x, c):
    """Two vertices per vertex and edge, eight edges, four faces and sixteen
    corners per edge (exact on a cube, a UV sphere, a grid with Boundary,
    Suzanne), and the mesh kept as well with Replace Original off; a mesh
    with no faces makes nothing."""
    made = Counts(2 * (c.v + c.e), 8 * c.e, 4 * c.e, 16 * c.e, c.exact) if c.f else Counts(0, 0, 0, 0)
    if not x.get('use_replace'):
        made = made.plus(c, exact=c.exact)
    return made


def _g_skin(x, c):
    return Counts(*(c.v * k for k in _SKIN_PER_VERTEX), exact=False)


def _g_ocean(x, c):
    """Generate replaces the mesh with a grid of (Repeat X·r² + 1) × (Repeat
    Y·r² + 1) vertices (exact at r 1 to 12, repeat 3 × 2); Displace keeps the
    mesh. Its simulation is priced apart (`ocean_samples`)."""
    if x.get('geometry_mode') != 'GENERATE':
        return c
    r = int(x.get('resolution' if x.s.render else 'viewport_resolution'))
    side = r * r
    nx, ny = max(1, int(x.get('repeat_x'))) * side, max(1, int(x.get('repeat_y'))) * side
    return Counts((nx + 1) * (ny + 1), nx * (ny + 1) + ny * (nx + 1), nx * ny, 4 * nx * ny)


def _used_vertices(corner_verts, n):
    import numpy as np
    if not n or not len(corner_verts):
        return 0
    used = np.zeros(n, dtype=bool)
    used[corner_verts] = True
    return int(used.sum())


def _loose_vertices(mesh):
    """How many of `mesh`'s vertices no face uses."""
    import numpy as np
    if mesh is None:
        return 0
    n, c = len(mesh.vertices), len(mesh.loops)
    if not c:
        return n
    corner_verts = np.empty(c, dtype=np.int32)
    mesh.loops.foreach_get('vertex_index', corner_verts)
    return n - _used_vertices(corner_verts, n)


def _g_edge_split(x, c):
    """At most every face corner a vertex of its own, beside every vertex no
    face uses (a vertex is split into at most as many as its corners, and one
    no face uses is kept): C + the loose vertices, exact at Split Angle 0 on a
    cube, an icosphere, a UV sphere and Suzanne. Round 4's review: a cube with
    30 loose vertices made 54 where max(V, C) said 38. Where the loose ones
    cannot be read cheaply, V + C bounds it — but loosely: a 640,000-face grid
    would count 3,201,601 against Blender's 2,560,000, so it is read whenever
    it can be."""
    loose = x.loose()
    if loose is None:
        return Counts(c.v + c.c, c.e + c.c, c.f, c.c, False)
    return Counts(c.c + loose, c.e + c.c, c.f, c.c, False)


def _bevel_patch(n, cutoff):
    """Vertices a beveled vertex gets per beveled edge at `n` segments: the
    corner patch's (n+1)²/4 per side (measured exact on a cube, a UV sphere,
    an icosphere and a cylinder, where an even count adds the centre), and
    Cut Off's (n+1)²/4 + n + 1 (an open grid at 3 and 5 segments made 2,092
    and 4,432 against 1,881 and 4,081)."""
    g = math.ceil((n + 1) ** 2 / 4.0)
    return g + n + 1 if cutoff else g


def _g_bevel(x, c):
    """An upper bound, from what the corners and edges become. Measured over
    a cube, a UV sphere, an icosphere, a grid, Suzanne and a cylinder, Edges
    and Vertices, every miter and vertex mesh method, 1 to 64 segments:
    V + max(C, 2E)·(n+1)²/4, twice that with an Arc or Patch miter (Arc
    doubles the cube's 24 to 48). Round 4's review: an existing Bevel counted
    as making nothing, so 64 cubes at 12 segments were counted 512 where
    Blender made 65,024, and a Subdivision Surface below it then passed at
    level 2 (Blender: 1,038,464). With an angle or weight limit, the edges it
    bevels are counted from what it is given once that is asked for
    (`_g_bevel_measured`); the bound alone keeps all of them."""
    n = max(1, int(x.get('segments')))
    miter = 2 if (x.get('miter_outer') != 'MITER_SHARP' or x.get('miter_inner') != 'MITER_SHARP') else 1
    g = _bevel_patch(n, x.get('vmesh_method') == 'CUTOFF') * miter
    v = c.v + max(c.c, 2 * c.e) * g
    return _fill(c, math.ceil(v * 1.02) + 8)


def _g_bevel_measured(x, c, m):
    """Bevel's bound from the edges it bevels in `m`, Blender's mesh of what
    it is given: per vertex with j beveled edges, j·patch + 1 for j ≥ 3 and
    (n+1)·j below (measured: a cylinder's cap rings, two per vertex, made
    n + 1 a vertex). Angle: edges whose faces meet at more than the limit, or
    with other than two faces (Blender's 90° fallback). Weight: edges with a
    Bevel Weight. Vertices, or a Vertex Group: every edge."""
    import numpy as np
    n = max(1, int(x.get('segments')))
    miter = 2 if (x.get('miter_outer') != 'MITER_SHARP' or x.get('miter_inner') != 'MITER_SHARP') else 1
    g = _bevel_patch(n, x.get('vmesh_method') == 'CUTOFF') * miter
    e = m.counts.e
    limit = x.get('limit_method')
    if x.get('affect') == 'EDGES' and limit == 'ANGLE':
        uses, angles = m.edge_angles()
        beveled = angles > float(x.get('angle_limit')) - 1e-6
    elif x.get('affect') == 'EDGES' and limit == 'WEIGHT':
        beveled = (m.weights > 0) if m.weights is not None else np.zeros(e, dtype=bool)
    else:
        beveled = np.ones(e, dtype=bool)
    ends = m.ends[beveled]
    j = np.bincount(ends.ravel(), minlength=m.counts.v) if len(ends) else np.zeros(m.counts.v, int)
    made = np.where(j >= 3, j * g + 1, (n + 1) * j * miter)
    v = int((m.counts.v - int((j > 0).sum())) + int(made.sum()))
    return _fill(c, math.ceil(v * 1.02) + 8)


def _g_remesh(x, c):
    """Voxel: `_blenderkit_sculpt`'s Voxel Remesh estimate (the same
    `BKE_mesh_remesh_voxel` the operator runs) from the area, mean curvature
    and pieces of what the modifier is given, an upper bound over 46 remeshes.
    Blocks, Smooth and Sharp: the same estimate at the octree's cell, the
    largest side over Scale over 2^depth (measured 0.46 to 1.5 vertices per
    cell-sized square of area on a cube, a UV sphere and Suzanne at depths 2
    to 7, under the estimate's 1.87), and never more than the octree's cells.
    Round 4's review: a Remesh was counted as making nothing, and a text's
    Size took one from 510 to 31,810 vertices with a count of 860."""
    _blenderkit_sculpt = _sibling('_blenderkit_sculpt')
    m = x.measures()
    measures = m.remesh()
    if not measures[0] and not measures[2]:
        return Counts(0, 0, 0, 0)
    if x.get('mode') == 'VOXEL':
        size = float(x.get('voxel_size'))
        if size <= 0:
            return c  # Blender returns the mesh as it is (MOD_remesh.cc)
        count = _blenderkit_sculpt._remesh_count(measures, size)
    else:
        depth = int(x.get('octree_depth'))
        scale = max(1e-6, float(x.get('scale')))
        cell = float(max(m.size)) / scale / (1 << depth) if max(m.size) > 0 else 0.0
        if cell <= 0:
            return Counts(0, 0, 0, 0)
        cells = (1 << depth) + 1
        count = min(_blenderkit_sculpt._remesh_count(measures, cell), float(cells) ** 3)
    if not math.isfinite(count):
        count = float(BUDGET) * 1000
    return _fill(c, int(math.ceil(count * REMESH_MARGIN)))


def _bvh(m, world):
    """A BVH of the faces of `m` (a `Measures`) placed by `world`, and the
    face of `m` each of its polygons is (None when they are in `m`'s order).
    Faces of one size are handed over as one array's rows: measured in
    desktop 5.2.1 on a 400 × 400 grid under a Solidify (321,600 quads) at a
    load average of 160, the BVH from a list sliced per face took 1.17 s with
    its Measures, and from the rows 0.55 s."""
    import numpy as np
    from mathutils.bvhtree import BVHTree
    w = np.array(world, dtype=np.float64)
    co = (m.co @ w[:3, :3].T + w[:3, 3]).tolist()
    totals = m.totals
    if not len(totals):
        return BVHTree.FromPolygons(co, [], epsilon=0.0), None
    sizes = np.unique(totals)
    if len(sizes) == 1:
        k = int(sizes[0])
        rows = m.corner_verts.reshape(-1, k).tolist()
        return BVHTree.FromPolygons(co, rows, all_triangles=(k == 3), epsilon=0.0), None
    starts = np.concatenate(([0], np.cumsum(totals)[:-1]))
    polygons, order = [], []
    for k in sizes.tolist():
        faces = np.nonzero(totals == k)[0]
        corners = starts[faces][:, None] + np.arange(k)
        polygons.extend(m.corner_verts[corners].tolist())
        order.append(faces)
    return BVHTree.FromPolygons(co, polygons, epsilon=0.0), np.concatenate(order)


# Faces of two meshes in one plane (`_coplanar`): two planes are taken as one
# where their offsets are within this much of the scene's size (1 plus the
# largest coordinate), and the Fast solver's Overlap Threshold more. Exactly
# coplanar faces measured in desktop 5.2.1 differ by about 1e-7 of it.
COPLANAR_DISTANCE = 1e-5
# Normals are compared in cells of this size, four times over with the cells
# shifted by an eighth, three eighths, five and seven: two normals within a
# small part of a cell share one in at least one of the four (a component
# lies near the edge of a cell in at most one of them), and a component of 0
# or 1 is never near an edge.
COPLANAR_CELL = 1e-3
# More candidate faces than this in one Boolean are not looked at face by
# face (their fins, `_fins`, would cost seconds and hundreds of MB): the
# change is refused in words.
COPLANAR_MOST = 400_000


class _Surface:
    """A mesh where a Boolean reads it (`Measures`, its world matrix), with
    its BVH (`_bvh`), its faces' planes and its positions in the world, each
    made when first asked for."""

    def __init__(self, m, world):
        self.m, self.world = m, world
        self._tree = None
        self._planes = None
        self._co = None
        self._starts = None

    def tree(self):
        if self._tree is None:
            self._tree = _bvh(self.m, self.world)
        return self._tree

    def co(self):
        if self._co is None:
            import numpy as np
            w = np.array(self.world, dtype=np.float64)
            self._co = self.m.co @ w[:3, :3].T + w[:3, 3]
        return self._co

    def extent(self):
        """Its largest coordinate in the world."""
        co = self.co()
        return float(abs(co).max()) if len(co) else 0.0

    def starts(self):
        if self._starts is None:
            import numpy as np
            totals = self.m.totals
            self._starts = (np.concatenate(([0], np.cumsum(totals)[:-1])) if len(totals)
                            else np.zeros(0, dtype=np.int64))
        return self._starts

    def planes(self):
        """(unit normals in the world, offsets, whether the face has one)."""
        if self._planes is None:
            import numpy as np
            w = np.array(self.world, dtype=np.float64)
            # A normal goes to the world by the inverse of the matrix (as
            # rows, n @ M⁻¹), here its cofactors' (det × M⁻¹ᵀ), which only
            # scales it: no LAPACK call, which nothing else in the app makes
            # (an inverse here was the one new native call in the price
            # that ran just before the app's one crash in this work, see
            # docs/blender-local.md), and nothing to fail for a flat matrix.
            m = w[:3, :3]
            cofactors = np.array((np.cross(m[1], m[2]), np.cross(m[2], m[0]), np.cross(m[0], m[1])))
            n = self.m.normals @ cofactors.T
            lengths = np.sqrt((n * n).sum(axis=1))
            valid = lengths > 1e-30
            n[valid] /= lengths[valid][:, None]
            first = self.co()[self.m.corner_verts[self.starts()]] if len(self.m.totals) else np.zeros((0, 3))
            d = (n * first).sum(axis=1)
            self._planes = (n, d, valid & np.isfinite(d))
        return self._planes

    def faces(self, polygons):
        """The faces of `m` the BVH's polygons `polygons` are."""
        import numpy as np
        a = np.asarray(polygons, dtype=np.int64)
        order = self.tree()[1]
        return order[a] if order is not None else a


def _pair_crossings(a, b, same=False, labels=None):
    """Two for each pair of faces of `a` and `b` that meet, and an N-Gon's
    sides past four more (see `_crossings`); `same`: a mesh with itself
    (pairs sharing an edge are not crossings, Blender's own self overlap).
    `labels` (with `same`): a mesh of several (`_Joined`), each face's own,
    and only pairs of faces of two of them count."""
    import numpy as np
    ta = a.tree()[0]
    pairs = ta.overlap(ta if same else b.tree()[0])
    if not pairs:
        return 0
    if labels is not None:
        fa = a.faces([p[0] for p in pairs])
        fb = a.faces([p[1] for p in pairs])
        apart = labels[fa] != labels[fb]
        fa, fb = fa[apart], fb[apart]
        total = 2 * len(fa)
        if len(fa) and a.m.totals.max() > 4:
            total += int(np.maximum(a.m.totals[fa] - 4, 0).sum() + np.maximum(a.m.totals[fb] - 4, 0).sum())
        return total
    total = 2 * len(pairs)
    if a.m.totals.max() > 4 or b.m.totals.max() > 4:
        fa = a.faces([p[0] for p in pairs])
        fb = b.faces([p[1] for p in pairs])
        total += int(np.maximum(a.m.totals[fa] - 4, 0).sum() + np.maximum(b.m.totals[fb] - 4, 0).sum())
    return total


class _Joined:
    """Several of a Boolean's surfaces (`_Surface`) as one mesh in the world,
    as `Measures` holds one, with each face's surface (`labels`): the
    operands of a collection, crossed with each other in one BVH instead of
    pair by pair. Fix round 2's re-check measured the pairs (desktop 5.2.1,
    unit cubes in one plane under a Union with a collection operand, one
    moved 0.1 through the Data API row's price): 100 operands priced in
    0.70 s and 400 in 11.09 s (Manifold) and 11.56 s (Exact), against
    Blender's own 0.01 and 0.29 s; fix round 3 measured 21.4 and 22.3 s at
    400 on 6d31b90's code."""

    def __init__(self, surfaces):
        import numpy as np
        co, normals, totals, verts, edges, labels = [], [], [], [], [], []
        v = e = 0
        for i, surface in enumerate(surfaces):
            m = surface.m
            co.append(surface.co())
            normals.append(surface.planes()[0])
            totals.append(m.totals)
            verts.append(m.corner_verts.astype(np.int64) + v)
            edges.append(m.corner_edges.astype(np.int64) + e)
            labels.append(np.full(len(m.totals), i, dtype=np.int64))
            v += len(m.co)
            e += int(m.corner_edges.max()) + 1 if len(m.corner_edges) else 0
        self.co = np.concatenate(co) if co else np.zeros((0, 3))
        self.normals = np.concatenate(normals) if normals else np.zeros((0, 3))
        self.totals = np.concatenate(totals) if totals else np.zeros(0, dtype=np.int32)
        self.corner_verts = np.concatenate(verts) if verts else np.zeros(0, dtype=np.int64)
        self.corner_edges = np.concatenate(edges) if edges else np.zeros(0, dtype=np.int64)
        self.labels = np.concatenate(labels) if labels else np.zeros(0, dtype=np.int64)

    def surface(self):
        from mathutils import Matrix
        return _Surface(self, Matrix.Identity(4))


def _chain_ids(values, tolerance):
    """Each value's cluster: sorted, a new cluster wherever two neighbours are
    more than `tolerance` apart. Two values within it share one, always."""
    import numpy as np
    order = np.argsort(values, kind='stable')
    ids = np.empty(len(values), dtype=np.int64)
    if len(values):
        ids[order] = np.concatenate(([0], np.cumsum(np.diff(values[order]) > tolerance)))
    return ids


def _coplanar_faces(a, b, tolerance, near=0.0):
    """(faces of `a`, faces of `b`) that may lie in one plane with a face of
    the other: offsets within `tolerance` (a chain of sorted offsets, which
    misses no pair), normals in one cell (`COPLANAR_CELL`) in one of four
    shifted grids. Either way round: a face of `b` facing the other way is
    in the same plane too. `near` (the Fast solver's Overlap Threshold and
    `tolerance`): also every face with a corner that close to the other
    mesh's surface (`_near_faces`)."""
    import numpy as np
    fa, fb = _plane_faces(a, b, tolerance)
    if near > 0.0:
        fa = np.union1d(fa, _near_faces(a, b, near))
        fb = np.union1d(fb, _near_faces(b, a, near))
    return fa, fb


def _near_faces(a, b, distance):
    """The faces of `a` with a corner within `distance` of `b`'s surface.
    The Fast solver takes what lies within its Overlap Threshold as
    touching (BMesh's intersect snaps a vertex within it of a face, an edge
    or a vertex onto it), tilted or not, so faces that meet that way are not
    found by their planes. Fix round 2's re-check of the Boolean pricing
    measured it, desktop 5.2.1: two 40 × 40 grids under a Solidify, B half a
    cell over in X and Y and tilted 0.002 rad about X, lowered onto A's
    plane, Union, Fast at an Overlap Threshold of 0.01 — the light count
    7,774, taken as sure, against Blender's 26,628; and the Data API row's
    Location passed at a budget of 17,201. Fix round 3 measured the same at
    Overlap Thresholds of 0.0001 (7,774 against 11,063) and 0.001 (25,824),
    and none at Blender's default of 1e-6. Each corner inside `b`'s bounds,
    grown by `distance`, is asked of `b`'s BVH (`find_nearest`)."""
    import numpy as np
    co = a.co()
    other = b.co()
    if not len(co) or not len(other) or not len(a.m.totals):
        return np.zeros(0, dtype=np.int64)
    lo, hi = other.min(axis=0) - distance, other.max(axis=0) + distance
    inside = np.nonzero(((co >= lo) & (co <= hi)).all(axis=1))[0]
    if not len(inside):
        return np.zeros(0, dtype=np.int64)
    tree = b.tree()[0]
    close = np.zeros(len(co), dtype=bool)
    find = tree.find_nearest
    for i, point in zip(inside.tolist(), co[inside].tolist()):
        if find(point, distance)[0] is not None:
            close[i] = True
    if not close.any():
        return np.zeros(0, dtype=np.int64)
    return np.nonzero(np.logical_or.reduceat(close[a.m.corner_verts], a.starts()))[0]


def _plane_faces(a, b, tolerance):
    """`_coplanar_faces` by the faces' planes alone."""
    import numpy as np
    na, da, va = a.planes()
    nb, db, vb = b.planes()
    ia, ib = np.nonzero(va)[0], np.nonzero(vb)[0]
    empty = (np.zeros(0, dtype=np.int64), np.zeros(0, dtype=np.int64))
    if not len(ia) or not len(ib):
        return empty
    offsets = np.concatenate((da[ia], db[ib], -db[ib]))
    side = np.concatenate((np.zeros(len(ia), dtype=np.int8), np.ones(2 * len(ib), dtype=np.int8)))
    face = np.concatenate((ia, ib, ib))
    clusters = _chain_ids(offsets, tolerance)
    count = int(clusters.max()) + 1
    here = np.zeros(count, dtype=bool)
    there = np.zeros(count, dtype=bool)
    here[clusters[side == 0]] = True
    there[clusters[side == 1]] = True
    keep = (here & there)[clusters]
    if not keep.any():
        return empty
    normals = np.concatenate((na[ia], nb[ib], -nb[ib]))[keep]
    clusters, side, face = clusters[keep], side[keep], face[keep]
    chosen = np.zeros(len(face), dtype=bool)
    for shift in (0.125, 0.375, 0.625, 0.875):
        cells = np.floor(normals / COPLANAR_CELL + shift).astype(np.int64)
        # One number for (offset cluster, cell): a collision only makes a
        # false candidate, which the fins then find touches nothing.
        key = ((clusters * 1000003 + cells[:, 0]) * 1000033 + cells[:, 1]) * 1000037 + cells[:, 2]
        both = np.intersect1d(key[side == 0], key[side == 1], assume_unique=False)
        if len(both):
            chosen |= np.isin(key, both)
    return np.unique(face[chosen & (side == 0)]), np.unique(face[chosen & (side == 1)])


def _fins(surface, faces, height, edges=False):
    """A BVH of a quad standing on each edge of `faces` (once an edge, on the
    normal of one face it bounds), `height` above and below it. A face of
    another mesh in the same plane is crossed by the fin of every edge that
    runs over it or along its outline, where a BVH of the faces themselves
    finds nothing: Blender's triangle test takes coplanar triangles as not
    meeting. `edges`: (the BVH, each fin's face, and its edge's two
    vertices), for a mesh's fins against itself (`_coplanar_self`)."""
    import numpy as np
    from mathutils.bvhtree import BVHTree
    m = surface.m
    totals = m.totals[faces]
    starts = surface.starts()[faces]
    k = int(totals.sum())
    if not k:
        return None
    owner = np.repeat(faces, totals)
    first = np.repeat(starts, totals)
    position = np.arange(k) - np.repeat(np.cumsum(totals) - totals, totals)
    corner = first + position
    following = first + (position + 1) % np.repeat(totals, totals)
    _, once = np.unique(m.corner_edges[corner], return_index=True)
    corner, following, owner = corner[once], following[once], owner[once]
    co = surface.co()
    p, q = co[m.corner_verts[corner]], co[m.corner_verts[following]]
    up = surface.planes()[0][owner] * height
    quads = np.stack((p - up, q - up, q + up, p + up), axis=1).reshape(-1, 3)
    tree = BVHTree.FromPolygons(quads.tolist(), np.arange(len(quads)).reshape(-1, 4).tolist(), epsilon=0.0)
    if edges:
        return tree, owner, m.corner_verts[corner], m.corner_verts[following]
    return tree


def _convex(surface, faces):
    """Whether each face of `faces` is convex: every corner turns the same
    way about the face's normal."""
    import numpy as np
    m = surface.m
    totals = m.totals[faces]
    k = int(totals.sum())
    if not k:
        return np.ones(len(faces), dtype=bool)
    first = np.repeat(surface.starts()[faces], totals)
    position = np.arange(k) - np.repeat(np.cumsum(totals) - totals, totals)
    size = np.repeat(totals, totals)
    co = surface.co()
    a = co[m.corner_verts[first + position]]
    b = co[m.corner_verts[first + (position + 1) % size]]
    c = co[m.corner_verts[first + (position + 2) % size]]
    turn = (np.cross(b - a, c - b) * np.repeat(surface.planes()[0][faces], totals, axis=0)).sum(axis=1)
    scale = np.sqrt(((b - a) ** 2).sum(axis=1) * ((c - b) ** 2).sum(axis=1)) + 1e-300
    bad = turn < -1e-9 * scale
    return ~np.logical_or.reduceat(bad, np.concatenate(([0], np.cumsum(totals)[:-1])))


def _coplanar(a, b, tolerance, near=0.0):
    """At most how many vertices a Boolean makes where faces of `a` and `b`
    lie in one plane and overlap, which the crossing pairs miss (the BVH's
    triangle test takes coplanar triangles as not meeting): one for each fin
    of a candidate face's edge (`_fins`) and face of the other mesh it meets,
    both ways round, half its sides for a face that is not convex. Each new
    vertex is where an edge of one crosses an edge of the other (Exact,
    Fast), which each of the edges' faces meets the other's fin at, or where
    an edge meets a face (Manifold, which takes faces in one plane as
    slightly apart), and an edge's segment crosses a convex outline at most
    twice. Measured in desktop 5.2.1 on the review's grids (below, Union,
    each solver, B also turned 30°, N = 40 and 150): at least Blender's
    count every time. Round 4's fix round 2 review: two N × N grids under a
    Solidify, B half a cell over and lowered onto A's plane, Manifold at
    N = 150: the crossing pairs counted 92,328 and Blender made 208,628.
    Returns (vertices, whether faces in one plane meet). `near`: see
    `_coplanar_faces`."""
    fa, fb = _coplanar_faces(a, b, tolerance, near)
    if not len(fa) and not len(fb):
        return 0, False
    _refuse_many_coplanar(len(fa) + len(fb))
    total = 0
    met = False
    for mine, faces, other in ((b, fb, a), (a, fa, b)):
        if not len(faces):
            continue
        # Fins as tall as what may touch: a face within `near` of the other
        # mesh reaches it.
        tree = _fins(mine, faces, 4.0 * tolerance + near)
        if tree is None:
            continue
        pairs = tree.overlap(other.tree()[0])
        if not pairs:
            continue
        met = True
        total += _fin_weights(other, other.faces([p[1] for p in pairs]))
    return total, met


def _refuse_many_coplanar(n):
    if n > COPLANAR_MOST:
        raise Unpriceable(
            "%s faces of the Boolean's meshes lie in one plane with faces of the other, more than the app "
            "looks at one by one before Blender builds them (%s); move one mesh off the other's plane a little"
            % (format(n, ','), format(COPLANAR_MOST, ',')))


def _fin_weights(surface, touched):
    """What the faces of `surface` a fin meets add (`_coplanar`): one each,
    half its sides for a face that is not convex."""
    import numpy as np
    if not len(touched):
        return 0
    weights = np.ones(len(touched), dtype=np.int64)
    kinds, where = np.unique(touched, return_inverse=True)
    wide = surface.m.totals[kinds] > 3
    if wide.any():
        flat = ~_convex(surface, kinds)
        half = np.where(flat, (surface.m.totals[kinds] + 1) // 2, 1)
        weights = half[where]
    return int(weights.sum())


def _self_plane_faces(a, tolerance, labels=None):
    """The faces of `a` that may lie in one plane with another of its faces
    (`labels`: with a face of another of the meshes `a` joins, `_Joined`),
    found as `_plane_faces` finds two meshes' (a key shared by two)."""
    import numpy as np
    n, d, v = a.planes()
    ia = np.nonzero(v)[0]
    if len(ia) < 2:
        return np.zeros(0, dtype=np.int64)
    offsets = np.concatenate((d[ia], -d[ia]))
    normals = np.concatenate((n[ia], -n[ia]))
    face = np.concatenate((ia, ia))
    tag = face if labels is None else labels[face]
    clusters = _chain_ids(offsets, tolerance)
    chosen = np.zeros(len(face), dtype=bool)
    for shift in (0.125, 0.375, 0.625, 0.875):
        cells = np.floor(normals / COPLANAR_CELL + shift).astype(np.int64)
        key = ((clusters * 1000003 + cells[:, 0]) * 1000033 + cells[:, 1]) * 1000037 + cells[:, 2]
        order = np.lexsort((tag, key))
        k, t = key[order], tag[order]
        start = np.concatenate(([True], k[1:] != k[:-1]))
        group = np.cumsum(start) - 1
        firsts = np.nonzero(start)[0]
        shared = np.minimum.reduceat(t, firsts) != np.maximum.reduceat(t, firsts)
        chosen[order] |= shared[group]
    return np.unique(face[chosen])


def _coplanar_self(a, tolerance, labels=None):
    """`_coplanar` of a mesh with itself: under Self Intersection (Exact),
    where Blender also cuts a mesh's own faces that lie in one plane and
    overlap, or of a collection's operands joined (`_Joined`, `labels`),
    which a Boolean of a collection cuts with each other. A fin is not
    counted on a face it stands on or that shares a vertex with its edge
    (the next face along the mesh), and with `labels` only on a face of
    another operand. Fix round 2's re-check measured the miss, desktop
    5.2.1: a 40 × 40 grid under a Solidify and an Array offset half a cell
    in X and Y, Exact Union with Self Intersection against a far cube,
    Count 1 → 2 — the light count 8,244 against Blender's 15,556, which
    stood as the count where the walk cannot ask Blender (a Geometry Nodes
    or Mesh Deform modifier before the Boolean: the row passed at a budget
    of 11,900). Returns (vertices, whether such faces meet)."""
    import numpy as np
    faces = _self_plane_faces(a, tolerance, labels)
    if not len(faces):
        return 0, False
    _refuse_many_coplanar(len(faces))
    made = _fins(a, faces, 4.0 * tolerance, edges=True)
    if made is None:
        return 0, False
    tree, owner, p, q = made
    pairs = tree.overlap(a.tree()[0])
    if not pairs:
        return 0, False
    fin = np.asarray([x[0] for x in pairs], dtype=np.int64)
    touched = a.faces([x[1] for x in pairs])
    if labels is not None:
        keep = labels[owner[fin]] != labels[touched]
    else:
        # Whether the touched face holds one of the fin edge's vertices: each
        # corner as (its face, its vertex), sorted, looked up.
        m = a.m
        n = int(len(a.co())) + 1
        corner_face = np.repeat(np.arange(len(m.totals), dtype=np.int64), m.totals)
        held = np.sort(corner_face * n + m.corner_verts.astype(np.int64))

        def holds(f, v):
            wanted = f * n + v.astype(np.int64)
            at = np.searchsorted(held, wanted)
            at = np.minimum(at, len(held) - 1)
            return held[at] == wanted

        keep = (touched != owner[fin]) & ~holds(touched, p[fin]) & ~holds(touched, q[fin])
    touched = touched[keep]
    if not len(touched):
        return 0, False
    return _fin_weights(a, touched), True


def _boolean_operands(x):
    operands = []
    if x.get('operand_type') == 'COLLECTION':
        collection = x.get('collection')
        if collection is not None:
            operands = [o for o in collection.all_objects if o.type in GEOMETRY_TYPES]
    else:
        operands = [x.get('object')]
    return [o for o in operands if o is not None and o != x.walk.obj and o.type in GEOMETRY_TYPES]


def _crossings(x, operands):
    """At most how many vertices a Boolean adds where the surfaces cross, and
    whether that bound holds without asking Blender: (vertices, sure).

    Two for each pair of faces that meet (a planar convex pair meets along
    one segment, whose ends are the new vertices), and an N-Gon's sides past
    four more, from a BVH of what the Boolean is given and of each operand,
    where the changes put them — and of a collection's operands with each
    other, which a Boolean of a collection joins too: all of them in one BVH
    (`_Joined`), so the work grows with their faces, not with the pairs of
    operands. Measured (desktop 5.2.1, Manifold and Exact): two combs of 10,
    30 and 50 thin plates, 800, 7,200 and 20,000 pairs against 800, 7,200
    and 20,000 vertices added; a sphere and a cube, Suzanne at level 2
    twice, two crossed 200 × 200 slabs (1,923 pairs, 155,111 against
    165,450).

    Not sure, so a light count is not taken for the count (`_final`):
    - where faces lie in one plane and overlap (`_coplanar`, whose bound is
      added), and under the Fast solver where faces come within its Overlap
      Threshold of each other (`_near_faces`);
    - with Self Intersection (Exact), where Blender also cuts each mesh where
      it crosses itself: its own crossing pairs and its own faces in one
      plane (`_coplanar_self`) are added. Round 4's fix round 2 review: a
      comb of 10 plates under an Array turned 90°, Exact Union with Self
      Intersection, Count 1 → 2 counted 4,848 against Blender's 10,043."""
    s = x.s
    solver = x.get('solver')
    self_cut = solver == 'EXACT' and bool(x.get('use_self'))
    given = x.measures()
    mesh = None
    if given.counts.f:
        mesh = _Surface(given, _matrix(x.walk.obj, s))
    elif not self_cut and len(operands) < 2:
        return 0, True
    theirs = []
    for other in operands:
        made = _object_final(other, x)
        if not made.f:
            continue
        if made.v > BUDGET:
            raise Unpriceable("%s's Boolean operand %s is past the budget already, %s vertices, so "
                              "where they cross cannot be counted" % (x.walk.obj.name, other.name,
                                                                      format(made.v, ',')))
        inner = _walk(other, s)
        if inner.fast_seconds > FAST_SECONDS:
            raise Unpriceable(_fast_words(other, inner.fast_name, inner.fast_seconds))
        stack = _stack(other, s)
        evaluated = _evaluate(other, s, stack, len(stack), other.mode == 'SCULPT')
        if evaluated.counts.f:
            theirs.append(_Surface(evaluated, _matrix(other, s)))
    surfaces = ([mesh] if mesh is not None else []) + theirs
    if not surfaces:
        return 0, True
    tolerance = COPLANAR_DISTANCE * (1.0 + max(surface.extent() for surface in surfaces))
    near = 0.0
    if solver == 'FLOAT':
        threshold = float(x.get('double_threshold') or 0.0)
        tolerance += threshold
        if threshold > COPLANAR_DISTANCE:
            # Blender's default Overlap Threshold (1e-6) is within the planes'
            # own tolerance; a larger one makes Fast pair every two triangles
            # within 20 times it (bmesh_intersect.cc: its BVH's margin is
            # `eps2x * 10`) and snap what lies within it, so what lies that
            # close may be cut.
            near = tolerance + 20.0 * threshold
    total = 0
    sure = True
    labels = None
    if len(theirs) > 1:
        joined = _Joined(theirs)
        labels = joined.labels
        operand = joined.surface()
    else:
        operand = theirs[0] if theirs else None
    # Under Fast's raised Overlap Threshold the fins' count of what lies close
    # is taken twice: fix round 3 measured it under Blender's own count once
    # in 72 cases (desktop 5.2.1: two 40 × 40 grids under a Solidify, B
    # tilted 0.0005 to 0.01 rad and laid on A at four offsets, Union and
    # Difference at Overlap Thresholds of 0.0001 to 0.01 — B at (0.3, 0.7) of
    # a cell, tilted 0.002, Difference at 0.0001: 33,596 against 37,227).
    # Twice, the least was 1.59 times Blender's. The count is still made
    # exact by Blender wherever the walk can ask it (`_final`).
    near_weight = 2 if near else 1
    if mesh is not None and operand is not None:
        total += _pair_crossings(mesh, operand)
        flat, looked = _coplanar(mesh, operand, tolerance, near)
        total += near_weight * flat
        if looked and flat:
            sure = False
    if labels is not None and not self_cut:
        # The operands with each other, each pair of faces of two of them.
        total += _pair_crossings(operand, operand, same=True, labels=labels)
        flat, looked = _coplanar_self(operand, tolerance, labels)
        total += flat
        if near:
            close = _near_faces_apart(operand, labels, near)
            if len(close):
                flat, looked = _fins_on(operand, close, tolerance + near / 4.0, labels)
                total += near_weight * flat
                looked = looked or bool(flat)
        if looked and flat:
            sure = False
    if self_cut:
        # Each mesh with itself, a collection's operands with each other and
        # each with itself among them (pairs that share a vertex are not
        # crossings).
        for surface in ([mesh] if mesh is not None else []) + ([operand] if operand is not None else []):
            total += _pair_crossings(surface, surface, same=True)
            total += _coplanar_self(surface, tolerance)[0]
        sure = False
    return total, sure


def _near_faces_apart(a, labels, distance):
    """`_near_faces` of a `_Joined` mesh with itself: the faces with a corner
    within `distance` of a face of another of the meshes it joins."""
    import numpy as np
    co = a.co()
    if not len(co) or not len(a.m.totals):
        return np.zeros(0, dtype=np.int64)
    corner_face = np.repeat(np.arange(len(a.m.totals), dtype=np.int64), a.m.totals)
    vertex_label = np.full(len(co), -1, dtype=np.int64)
    vertex_label[a.m.corner_verts] = labels[corner_face]
    tree, order = a.tree()
    close = np.zeros(len(co), dtype=bool)
    find = tree.find_nearest_range
    for i, point in enumerate(co.tolist()):
        for hit in find(point, distance):
            face = int(order[hit[2]]) if order is not None else int(hit[2])
            if labels[face] != vertex_label[i]:
                close[i] = True
                break
    if not close.any():
        return np.zeros(0, dtype=np.int64)
    return np.nonzero(np.logical_or.reduceat(close[a.m.corner_verts], a.starts()))[0]


def _fins_on(a, faces, tolerance, labels):
    """`_coplanar_self`'s count for the faces `faces` of a `_Joined` mesh."""
    import numpy as np
    _refuse_many_coplanar(len(faces))
    made = _fins(a, faces, 4.0 * tolerance, edges=True)
    if made is None:
        return 0, False
    tree, owner, p, q = made
    pairs = tree.overlap(a.tree()[0])
    if not pairs:
        return 0, False
    fin = np.asarray([x[0] for x in pairs], dtype=np.int64)
    touched = a.faces([x[1] for x in pairs])
    touched = touched[labels[owner[fin]] != labels[touched]]
    if not len(touched):
        return 0, False
    return _fin_weights(a, touched), True


# Blender's Fast solver pairs every two triangles of the mesh and an operand
# whose bounding boxes come within 40 times its Overlap Threshold of each
# other (bmesh_intersect.cc: each of its two BVHs' boxes grown by
# `eps_margin`, 20 times the threshold) and tests each pair, and its time
# follows those pairs. Measured in desktop 5.2.1 (fix round 3, October 29, a
# load average of about 10): two N × N grids under a Solidify, B half a cell
# over, tilted 0.002 rad or turned 0.3, Union, at Overlap Thresholds of 0.001
# to 0.2, N of 20 to 80 — 10,192 to 97,170,920 pairs, 0.01 to 72.6 s, 0.31
# to 1.29 µs a pair (40 × 40 at 0.05, 45,145,600 pairs, 27.3 s; 80 × 80 at
# 0.01, 97,170,920 pairs, 72.6 s). Fix round 3's review measured the Data
# API row's Overlap Threshold 0.05 on two 40 × 40 grids at 29.4 s, Blender's
# own Fast 18.3 s, and 248.7 s for Blender alone on 80 × 80 grids. A
# microsecond a pair is above every case measured past 500,000 pairs (0.31 to
# 0.80 µs; under that, 13,424 to 212,232 pairs took 1.05 to 1.29 µs each and
# 0.22 s at most).
FAST_PAIR_SECONDS = 1.0e-6
# The most seconds Blender's Fast Boolean may take, as Subdivision Surface's
# limit surface may (SUBDIVISION_SECONDS): past it a change is refused when
# it is slower than now, and the price never asks Blender through it.
FAST_SECONDS = 5.0
# Face pairs compared one by one; past it, FAST_SAMPLE of the mesh's faces
# (a fixed draw) stand for the rest.
FAST_EXACT_PAIRS = 4_000_000
FAST_SAMPLE = 1024


def _face_boxes(m, world):
    """(lows, highs, triangles) of each face of `m` (a `Measures`) placed by
    `world`, or None for a mesh with no face."""
    import numpy as np
    if not len(m.totals) or not len(m.corner_verts):
        return None
    w = np.array(world, dtype=np.float64)
    co = m.co @ w[:3, :3].T + w[:3, 3]
    p = co[m.corner_verts]
    starts = np.concatenate(([0], np.cumsum(m.totals)[:-1])).astype(np.int64)
    lo = np.minimum.reduceat(p, starts, axis=0)
    hi = np.maximum.reduceat(p, starts, axis=0)
    tris = np.maximum(m.totals.astype(np.float64) - 2.0, 1.0)
    return lo, hi, tris


def _joined_boxes(a, b):
    import numpy as np
    return tuple(np.concatenate((x, y)) for x, y in zip(a, b))


def _box_pairs(a, b, gap):
    """The pairs of triangles, one of `a` and one of `b` (`_face_boxes`),
    whose faces' boxes come within `gap` of each other: each such pair of
    faces counted as the product of their triangles."""
    import numpy as np
    lo_a, hi_a, ta = a
    lo_b, hi_b, tb = b
    near_a = ((hi_a >= lo_b.min(axis=0) - gap) & (lo_a <= hi_b.max(axis=0) + gap)).all(axis=1)
    near_b = ((hi_b >= lo_a.min(axis=0) - gap) & (lo_b <= hi_a.max(axis=0) + gap)).all(axis=1)
    lo_a, hi_a, ta = lo_a[near_a], hi_a[near_a], ta[near_a]
    lo_b, hi_b, tb = lo_b[near_b] - gap, hi_b[near_b] + gap, tb[near_b]
    na, nb = len(ta), len(tb)
    if not na or not nb:
        return 0.0
    rows = np.arange(na)
    scale = 1.0
    if na * nb > FAST_EXACT_PAIRS and na > FAST_SAMPLE:
        rows = np.sort(np.random.default_rng(0).choice(na, size=FAST_SAMPLE, replace=False))
        scale = na / float(FAST_SAMPLE)
    total = 0.0
    step = max(1, FAST_EXACT_PAIRS // nb)
    for i in range(0, len(rows), step):
        r = rows[i:i + step]
        hit = ((lo_a[r, None, :] <= hi_b[None]) & (hi_a[r, None, :] >= lo_b[None])).all(axis=2)
        total += float((hit @ tb) @ ta[r])
    return total * scale


def _fast_seconds(x, operands, c, corners):
    """At most about how many seconds Blender's Fast solver takes on this
    Boolean: FAST_PAIR_SECONDS for each pair of triangles it tests (see the
    note above FAST_PAIR_SECONDS) — at most every corner of the mesh with
    every corner of an operand, and where that could pass FAST_SECONDS, the
    pairs of faces whose boxes come within its reach, read from the mesh it
    is given and its operands where the changes put them. A collection's
    operands are cut in one at a time, each with what the cuts before it
    left."""
    collection = x.get('operand_type') == 'COLLECTION'
    spread = float(sum(corners))
    most = (float(c.c) + spread) * spread if collection else float(c.c) * spread
    if most * FAST_PAIR_SECONDS <= FAST_SECONDS:
        return most * FAST_PAIR_SECONDS
    s = x.s
    threshold = max(0.0, float(x.get('double_threshold') or 0.0))
    gap = 40.0 * threshold
    given = _face_boxes(x.measures(), _matrix(x.walk.obj, s))
    if given is None:
        return 0.0
    boxes = []
    for other in operands:
        if collection and other.type != 'MESH':
            continue
        inner = _walk(other, s)
        if inner.fast_seconds > FAST_SECONDS:
            raise Unpriceable(_fast_words(other, inner.fast_name, inner.fast_seconds))
        stack = _stack(other, s)
        evaluated = _evaluate(other, s, stack, len(stack), other.mode == 'SCULPT')
        made = _face_boxes(evaluated, _matrix(other, s))
        if made is not None:
            boxes.append(made)
    pairs = 0.0
    so_far = given
    for made in boxes:
        pairs += _box_pairs(so_far, made, gap)
        if collection:
            so_far = _joined_boxes(so_far, made)
    return pairs * FAST_PAIR_SECONDS


def _fast_words(obj, name, seconds):
    return ("%s's %s would take Blender's Fast solver about %d s, with the app frozen meanwhile: Fast "
            "tests every two faces that come within 40 times its Overlap Threshold of each other (measured "
            "on a desktop Mac: two 40 × 40 grids at a threshold of 0.05, 27 s; 80 × 80 at 0.01, 73 s). "
            "Lower the Overlap Threshold, or use the Exact or Manifold solver"
            % (obj.name, name or "Boolean", max(1, round(seconds))))


def _g_boolean(x, c):
    """The mesh and its operands', which a Boolean joins, and the vertices it
    adds where their surfaces cross (`_crossings`), with an edge and a half,
    a face and three corners for each (measured at most 1.0, 0.38 and 2.0).
    Round 4's fix-round review: the crossings were left out, and two combs of
    50 plates made 20,800 vertices against a count of 800. A first count
    takes every pair of faces as crossing at each pair of their corners —
    faces in one plane cross outline to outline, at most a corner's edge
    each — between the mesh and each operand, a collection's operands with
    each other, and each with itself under Self Intersection; a refinement
    asks the BVH, and then Blender (`_walk`)."""
    operands = _boolean_operands(x)
    total = c.bound()
    corners = []
    for other in operands:
        made = _object_final(other, x)
        total = total.plus(made)
        corners.append(made.c)
    if x.get('solver') == 'FLOAT' and c.v <= BUDGET:
        # Blender's own time on it (fix round 3's review: the Data API row's
        # Overlap Threshold froze Blender for 29.4 s, and this price asked
        # Blender for a Fast evaluation of its own besides): read before
        # anything here asks Blender through it.
        seconds = _fast_seconds(x, operands, c, corners)
        if seconds > x.walk.fast_seconds:
            x.walk.fast_seconds, x.walk.fast_name = seconds, getattr(x.modifier, 'name', 'Boolean')
    if x.walk.refined:
        crossings, sure = _crossings(x, operands)
        if not sure:
            x.walk.unsure = True
    else:
        crossings = c.c * sum(corners)
        if x.get('operand_type') == 'COLLECTION':
            spread = sum(corners)
            crossings += (spread * spread - sum(k * k for k in corners)) // 2
        if x.get('solver') == 'EXACT' and x.get('use_self'):
            crossings += (c.c * c.c + sum(k * k for k in corners)) // 2
    return Counts(total.v + crossings, total.e + math.ceil(1.5 * crossings), total.f + crossings,
                  total.c + 3 * crossings, False)


def _g_triangulate(x, c):
    made = _triangulated(c)
    if int(x.get('min_vertices')) > 4:
        made = made.bound()  # quads are left as they are
    return made


def _g_decimate(x, c):
    """Collapse leaves triangles, which a Subdivision Surface below it counts
    more of than quads; Un-Subdivide and Planar only remove."""
    if x.get('decimate_type') == 'COLLAPSE':
        return _triangulated(c).bound()
    return c.bound()


def _particles(other, index, s, children):
    """The particles a Particle Instance takes from `other`'s particle system
    `index` (1-based). Measured on a plane with 50 particles: Number, or with
    a Grid distribution Resolution² on a surface (4, 25, 100 and 400 at 2, 5,
    10 and 20) — Resolution³ bounds it in a volume too; and with the
    modifier's Children on and a child type, Number times Display Amount more
    (10 a particle: 4,400 vertices of cubes against 400)."""
    if other is None:
        return 0
    systems = getattr(other, 'particle_systems', None)
    if not systems or not 1 <= index <= len(systems):
        return 0
    settings = systems[index - 1].settings
    if s.get(settings, 'distribution') == 'GRID' and s.get(settings, 'emit_from') != 'VERT':
        count = int(s.get(settings, 'grid_resolution')) ** 3
    else:
        count = int(s.get(settings, 'count'))
    if children and s.get(settings, 'child_type') != 'NONE':
        amount = s.get(settings, 'rendered_child_count' if s.render else 'child_percent')
        count += count * int(amount)
    return count


def _g_particle_instance(x, c):
    """A copy of the mesh per particle of the other object's system
    (`_particles`; Number goes to 10,000,000 in RNA)."""
    count = _particles(x.get('object'), int(x.get('particle_system_index')), x.s, x.get('use_children'))
    if count <= 0:
        return Counts(0, 0, 0, 0) if x.get('object') is not None else c
    return c.times(count, exact=False)


def _g_explode(x, c):
    """Every face a piece of its own (a vertex per corner), and with Cut
    Edges each edge between pieces cut once more."""
    v = c.c + (2 * c.e if x.get('use_edge_cut') else 0) + c.v
    return Counts(v, c.e + 2 * c.c, 2 * c.f + c.c, 4 * c.c + 4 * c.f, False)


# Volumes. The app adds them through the Operator Search and a script
# (`object.volume_add`), and Mesh to Volume on one gives it grids that Volume
# to Mesh, which Add Modifier offers on a mesh, meshes again. Round 4's
# fix-round review: Volume to Mesh was counted as keeping its 4 vertices,
# 'the app adds no volume with grids', and at a Voxel Amount of 32, 256 and
# 1,200 Blender made 2,168, 126,152 and 2,766,248 (9.9 s).
# The most voxels a volume's grid may have: measured, a 2 m cube's at a
# Voxel Amount of 512 (an interior band 0.2 m deep: 80,000,000 voxels by the
# estimate below) took 229 MB and 0.53 s, about 2.9 bytes a voxel.
VOLUME_VOXELS = 250_000_000
VOLUME_BYTES_PER_VOXEL = 4
# The most memory a Fluid domain's simulation may hold: the vertex budget's
# own peak (BUDGET vertices at PEAK_BYTES_PER_VERTEX).
FLUID_BYTES = 2_000_000_000


def _volume_grid(volume, s):
    """(area, voxel size, largest side) of the grid `volume`'s last Mesh to
    Volume makes, in the volume's own units; () for a volume with no grid;
    None for one whose grid the budget cannot count (read from a file)."""
    if volume is None or volume.type != 'VOLUME':
        return ()
    stack = [m for m in _stack(volume, s) if _shown(m, s) and getattr(m, 'type', '') == 'MESH_TO_VOLUME']
    if not stack:
        data = s.get(volume, 'data')
        if data is not None and getattr(data, 'filepath', '') and len(getattr(data, 'grids', ())):
            return None
        return ()
    m = stack[-1]
    source = s.get(m, 'object')
    if source is None or source.type not in GEOMETRY_TYPES or source == volume:
        return ()
    made = _walk(source, s).final
    if made.v > BUDGET:
        raise Unpriceable("%s's Mesh to Volume reads %s, past the budget already" % (volume.name, source.name))
    stack_source = _stack(source, s)
    measured = _evaluate(source, s, stack_source, len(stack_source), source.mode == 'SCULPT')
    relative = _matrix(volume, s).inverted_safe() @ _matrix(source, s)
    scale = max(relative.col[i].xyz.length for i in range(3))
    area = float(measured.areas.sum()) * scale * scale
    side = float(max(measured.size)) * scale if measured.counts.v else 0.0
    if s.get(m, 'resolution_mode') == 'VOXEL_SIZE':
        size = float(s.get(m, 'voxel_size'))
    else:
        amount = max(1, int(s.get(m, 'voxel_amount')))
        size = side / amount if side > 0 else 0.0
    if size <= 0 or not area:
        return ()
    return (area, size, side, float(s.get(m, 'interior_band_width')))


def volume_voxels(volume, s=None):
    """An estimate of the voxels `volume`'s grid has: its surface times the
    band inside it (at least two voxels deep) over the voxel's volume — the
    2 m cube's 80,000,000 at 512 above."""
    own = s is None
    s = s or Prices()
    try:
        grid = _volume_grid(volume, s)
        if not grid:
            return 0 if grid == () else None
        area, size, side, band = grid
        return int(area * (max(band, 0.0) + 2.0 * size) / size ** 3)
    finally:
        if own:
            s.close()


def _g_volume_to_mesh(x, c):
    """The surface of the volume it reads at the voxel size it meshes at
    (its Grid's own, or its Voxel Size, or the volume's largest side over its
    Voxel Amount), which replaces the mesh: measured on a cube, Suzanne and an
    open grid from a Mesh to Volume at Voxel Amounts of 32 to 512, at most
    1.13 vertices per voxel-sized square of the source's area (a sheet, met
    on both sides); 2.5 is counted. Nothing with no volume (measured: the mesh
    is left empty)."""
    volume = x.get('object')
    grid = _volume_grid(volume, x.s)
    if grid is None:
        raise Unpriceable("%s's Volume to Mesh reads %s, whose grids come from a file, and how many "
                          "vertices they make cannot be counted" % (x.walk.obj.name, volume.name))
    if not grid:
        return Counts(0, 0, 0, 0)
    area, size, side, band = grid
    mode = x.get('resolution_mode')
    if mode == 'VOXEL_SIZE':
        size = max(size, float(x.get('voxel_size'))) if float(x.get('voxel_size')) > 0 else size
    elif mode == 'VOXEL_AMOUNT':
        size = side / max(1, int(x.get('voxel_amount'))) if side > 0 else size
    v = 2.5 * area / (size * size) + 64
    v = int(min(v, 1e15)) if math.isfinite(v) else BUDGET * 1000
    return Counts(v, 3 * v, 2 * v, 6 * v, False)


# Fluid. A domain simulates on a grid whose largest side has its Resolution
# Divisions of cells (the others in proportion), and a Liquid domain with
# Mesh on is replaced by the liquid's surface, meshed on a grid Mesh Upres
# times finer. Round 4's fix-round review: Fluid was counted as keeping its
# mesh, and a Liquid domain at Resolution 32 and 96 made 3,424 and 28,886
# vertices at its first frame, counted 8; Subdivision 3 on top passed and
# made 2,772,866; the grid itself was not priced. Measured here (desktop
# 5.2.1, a 4 m cube domain, a sphere flowing in, Replay): resident memory up
# by 25, 185 and 609 MB at Resolution 32, 64 and 96 for a Liquid (about 700
# bytes a cell, 40 MB more a frame at 96 as particles came in), 91 and 267 MB
# for a Gas (about 350), Noise at a scale of 2 and 4 about 107 and 67 bytes a
# noise cell, and the mesh's grid about 45 bytes a cell (Mesh Upres 8 at
# Resolution 64: 6 GB); a flattened domain a quarter as deep took a quarter.
FLUID_BYTES_PER_CELL = {'LIQUID': 1200, 'GAS': 400}   # rounded up, room for particles
FLUID_MESH_BYTES_PER_CELL = 64
FLUID_NOISE_BYTES_PER_CELL = 128


def _fluid_cells(x, settings):
    """(the cells of the domain's grid along X, Y and Z)."""
    s = x.s
    resolution = max(1, int(s.get(settings, 'resolution_max')))
    obj = x.walk.obj
    mesh = s.data_of(obj) if obj.type == 'MESH' else None
    if mesh is not None and len(mesh.vertices):
        import numpy as np
        co = np.empty(3 * len(mesh.vertices), dtype=np.float32)
        mesh.vertices.foreach_get('co', co)
        co = co.reshape(-1, 3)
        local = co.max(axis=0) - co.min(axis=0)
    else:
        local = (1.0, 1.0, 1.0)
    world = _matrix(obj, s)
    sides = [abs(float(local[i])) * world.col[i].xyz.length for i in range(3)]
    largest = max(sides) or 1.0
    return [max(1, int(math.ceil(resolution * side / largest))) for side in sides]


def fluid_bytes(x):
    """An upper bound of the memory a Fluid domain's simulation holds, from
    its grids (`FLUID_BYTES_PER_CELL` and the rest above); 0 for a modifier
    that is not a domain."""
    if x.get('fluid_type') != 'DOMAIN':
        return 0
    settings = x.get('domain_settings')
    if settings is None:
        return 0
    s = x.s
    nx, ny, nz = _fluid_cells(x, settings)
    cells = nx * ny * nz
    kind = s.get(settings, 'domain_type')
    total = cells * FLUID_BYTES_PER_CELL.get(kind, 1200)
    if kind == 'LIQUID' and s.get(settings, 'use_mesh'):
        total += cells * int(s.get(settings, 'mesh_scale')) ** 3 * FLUID_MESH_BYTES_PER_CELL
    if kind == 'GAS' and s.get(settings, 'use_noise'):
        total += cells * int(s.get(settings, 'noise_scale')) ** 3 * FLUID_NOISE_BYTES_PER_CELL
    return total


# A Liquid domain's mesh, per cell of the domain's surface on the mesh's grid
# (Resolution Divisions × Mesh Upres): measured in desktop 5.2.1 at Blender's
# default Resolution 64 and Mesh Upres 2 in a cube domain (a 128-cell grid,
# 98,304 surface cells), 60 frames each, the peak of the liquid's mesh — an
# inflow filling it 123,880 (1.3 a cell), a dam break against a block 266,302
# (2.7), four jets into three pillars 404,750 (4.1). Taken three times the
# splashiest. A liquid broken into one-cell droplets everywhere could make up
# to three a cell of the whole grid, which is what the count was before
# (round 4's second fix-round review: it refused Resolution 48 and 64 at the
# default Upres, 2,654,208 and 6,291,456, where the measured mesh was 28 times
# under it); this is a measured bound, not that one, and says so.
FLUID_MESH_VERTICES_PER_SURFACE_CELL = 12


def _g_fluid(x, c):
    """A Liquid domain with Mesh on: the liquid's surface, meshed on a grid
    Mesh Upres times the domain's, bounded by the domain's surface on that
    grid (FLUID_MESH_VERTICES_PER_SURFACE_CELL), at any frame. Anything else
    keeps its mesh (a Gas domain draws its box: 8 vertices measured at
    Resolution 64 and 96)."""
    if x.get('fluid_type') != 'DOMAIN':
        return c
    settings = x.get('domain_settings')
    s = x.s
    if settings is None or s.get(settings, 'domain_type') != 'LIQUID' or not s.get(settings, 'use_mesh'):
        return c
    upres = max(1, int(s.get(settings, 'mesh_scale')))
    nx, ny, nz = (n * upres for n in _fluid_cells(x, settings))
    surface = 2 * (nx * ny + ny * nz + nx * nz)
    v = FLUID_MESH_VERTICES_PER_SURFACE_CELL * surface
    return Counts(v, 3 * v, 2 * v, 6 * v, False)


def _keep(x, c):
    return c


def _g_particle_system(x, c):
    """The mesh as it is given, and the particle system's own points beside
    it (`Walk.extra`, judged with the object's count, not passed on to the
    modifiers after it). Round 4's fix round 2 review, desktop 5.2.1: a plane
    with hair Count 10,000 and Interpolated children at Display Amount 100,
    Display Steps 3, made 1,000,000 child strands and 594 MB of peak memory
    with no refusal (Particle System was counted as keeping its mesh); RNA
    allows Count to 2^31 and children to 100,000."""
    x.walk.extra += particle_points(x.walk.obj, x.modifier, x.s)
    return c


def particle_points(obj, modifier, s):
    """The points a particle system keeps for the viewport (or a render):
    its particles shown — Display Amount of Count, Resolution³ for a grid —
    times one for the parent and Display Amount (Render Amount) more for
    children, by the scene's Simplify; a hair strand 2^Display Steps (Render
    Steps) + 1 points."""
    system = getattr(modifier, 'particle_system', None)
    settings = s.get(system, 'settings') if system is not None else None
    if settings is None:
        return 0
    if s.get(settings, 'distribution') == 'GRID' and s.get(settings, 'emit_from') != 'VERT':
        count = int(s.get(settings, 'grid_resolution')) ** 3
    else:
        count = int(s.get(settings, 'count'))
    if not s.render:
        count = int(math.ceil(count * int(s.get(settings, 'display_percentage')) / 100.0))
    scale = 1
    if s.get(settings, 'child_type') != 'NONE':
        amount = int(s.get(settings, 'rendered_child_count' if s.render else 'child_percent'))
        scene = bpy.context.scene
        render = getattr(scene, 'render', None) if scene is not None else None
        if render is not None and s.get(render, 'use_simplify'):
            amount = int(math.ceil(amount * float(s.get(
                render, 'simplify_child_particles_render' if s.render else 'simplify_child_particles'))))
        scale += amount
    per = 1
    if s.get(settings, 'type') == 'HAIR':
        step = int(s.get(settings, 'render_step' if s.render else 'display_step'))
        per = 2 ** max(0, step) + 1
    return count * scale * per


def _collection_instance(other, counting, object_counts, seen):
    """What an empty that instances a collection gives Object Info and
    Collection Info: an instance of that collection, every object of it
    counted (`object_counts`, at every level), whatever its Instancing is
    set to (`object_get_evaluated_geometry_set`, geometry_set_instances.cc);
    None for any other object. Fix round 3's review (October 29), sandboxed
    desktop 5.2.1 at the real budget: one script line made a Collection Info
    of C -> Realize Instances, C holding three empties each instancing D, a
    1000 x 1000 grid; Blender built G at 3,000,000 with no refusal, the
    empties counted 0."""
    if other is None or other.type != 'EMPTY' or other.instance_collection is None:
        return None
    collection = other.instance_collection
    p = _pointer(collection)
    if p in seen or len(seen) >= CHAIN_DEPTH:
        raise counting.Unknown("the collection %s, instanced inside itself" % collection.name)
    held = counting.Geo()
    for inner in collection.all_objects:
        held = held.plus(object_counts(inner, seen + (p,)))
    return counting.Geo(instances=1, held=held)


def _g_nodes(x, c):
    """Geometry Nodes: an upper bound of what its group makes, read node by
    node (`_blenderkit_nodecount`), every setting as the changes leave it. A
    group whose count only Blender running it could say is refused in words
    (Unpriceable), not counted as keeping what it is given — as it was until
    round 4's fix round 2 review measured a Grid of 1,900 × 1,900 built
    unpriced at 3,610,000 vertices."""
    counting = _sibling('_blenderkit_nodecount')

    def object_counts(other, seen=()):
        instanced = _collection_instance(other, counting, object_counts, seen)
        if instanced is not None:
            return instanced
        made = _object_final(other, x)
        # A curve's or a text's own geometry is curves, which a node that
        # reads points (Curve to Mesh, Resample Curve) counts by its points.
        points = made.v if getattr(other, 'type', None) in ('CURVE', 'FONT') else 0
        return counting.Geo(made.v, made.e, made.f, made.c, points=points)

    counter = counting.Counter(object_counts, x.s.get)
    # What the group is given. A curve object's Geometry Nodes take its
    # curves, not the mesh its bevel builds, and a node that reads curves
    # (Curve to Mesh, Resample Curve, Curve to Points) counts their points.
    # Fix round 2's re-check, sandboxed desktop 5.2.1: a Bézier curve at
    # Resolution U 1,024 under Group Input -> Curve to Mesh (a Curve Circle
    # profile of Resolution 3,000) built 3,075,000 vertices from a script
    # line, and the Data API row's Circle Resolution 30 -> 3,000 built 30,750
    # -> 3,075,000, neither refused: the input was handed over as a mesh,
    # whose curve points read 0. So the points are bounded too: by the
    # curve's control points times its resolutions (`_curve_points`) and by
    # what is given as a mesh (each evaluated point is at least one vertex of
    # it), for a curve's or a text's first modifiers and for what an earlier
    # Geometry Nodes modifier made (its curves are in the count it hands on).
    points = 0
    obj = x.walk.obj
    earlier = [m for m, _ in x.walk.steps[:-1]]
    if obj.type in ('CURVE', 'FONT', 'CURVES') or any(getattr(m, 'type', None) == 'NODES' for m in earlier):
        points = c.v
        if obj.type == 'CURVE':
            data = x.s.data_of(obj)
            if data is not None and hasattr(data, 'splines'):
                points = max(points, _curve_points(data))
    try:
        made = counter.count(x.modifier, counting.Geo(c.v, c.e, c.f, c.c, points=points))
    except counting.Unknown as why:
        raise Unpriceable(
            "%s's %s makes what only Blender running its node group can count (%s), and the app "
            "counts every modifier before Blender builds it; give that a constant value, or use a "
            "modifier of Blender's own" % (x.walk.obj.name, getattr(x.modifier, 'name', 'Geometry Nodes'),
                                          why)) from None
    return Counts(made.total(), made.e, made.f, made.l, False)


def _reduce(x, c):
    return c.bound()


# Every modifier type's growth. A type missing here (and from _UNMODELLED)
# keeps its count, and the completeness check fails on it.
_GROWTH = {
    'SUBSURF': _g_subsurf, 'MULTIRES': _g_multires, 'ARRAY': _g_array, 'MIRROR': _g_mirror,
    'SOLIDIFY': _g_solidify, 'SCREW': _g_screw, 'WIREFRAME': _g_wireframe, 'SKIN': _g_skin,
    'OCEAN': _g_ocean, 'EDGE_SPLIT': _g_edge_split, 'BEVEL': _g_bevel, 'REMESH': _g_remesh,
    'BOOLEAN': _g_boolean, 'TRIANGULATE': _g_triangulate, 'DECIMATE': _g_decimate,
    'PARTICLE_INSTANCE': _g_particle_instance, 'EXPLODE': _g_explode,
    'VOLUME_TO_MESH': _g_volume_to_mesh, 'FLUID': _g_fluid, 'NODES': _g_nodes,
    'PARTICLE_SYSTEM': _g_particle_system,
    # Grease Pencil's (see `_gp_measures`): what makes more points, and what
    # only moves, colours or takes them away.
    'GREASE_PENCIL_ARRAY': _g_gp_array, 'GREASE_PENCIL_MULTIPLY': _g_gp_multiply,
    'GREASE_PENCIL_MIRROR': _g_gp_mirror, 'GREASE_PENCIL_SUBDIV': _g_gp_subdiv,
    'GREASE_PENCIL_ENVELOPE': _g_gp_envelope, 'GREASE_PENCIL_DASH': _g_gp_dash,
    'GREASE_PENCIL_OUTLINE': _g_gp_outline, 'GREASE_PENCIL_SIMPLIFY': _g_gp_simplify,
    'GREASE_PENCIL_LENGTH': _g_gp_length, 'LINEART': _g_gp_lineart,
    'GREASE_PENCIL_VERTEX_WEIGHT_PROXIMITY': _keep, 'GREASE_PENCIL_COLOR': _keep, 'GREASE_PENCIL_TINT': _keep,
    'GREASE_PENCIL_OPACITY': _keep, 'GREASE_PENCIL_VERTEX_WEIGHT_ANGLE': _keep, 'GREASE_PENCIL_TIME': _keep,
    'GREASE_PENCIL_TEXTURE': _keep, 'GREASE_PENCIL_BUILD': _reduce, 'GREASE_PENCIL_HOOK': _keep,
    'GREASE_PENCIL_NOISE': _keep, 'GREASE_PENCIL_OFFSET': _keep, 'GREASE_PENCIL_SMOOTH': _keep,
    'GREASE_PENCIL_THICKNESS': _keep, 'GREASE_PENCIL_LATTICE': _keep, 'GREASE_PENCIL_ARMATURE': _keep,
    'GREASE_PENCIL_SHRINKWRAP': _keep,
    # Pure deforms and the modifiers that only write attributes, normals or
    # UVs, or simulate on the mesh as it is: the same vertices, edges and
    # faces (the completeness check raises each of their settings).
    'ARMATURE': _keep, 'CAST': _keep, 'CURVE': _keep, 'DISPLACE': _keep, 'HOOK': _keep,
    'LAPLACIANDEFORM': _keep, 'LATTICE': _keep, 'MESH_DEFORM': _keep, 'SHRINKWRAP': _keep,
    'SIMPLE_DEFORM': _keep, 'SMOOTH': _keep, 'CORRECTIVE_SMOOTH': _keep, 'LAPLACIANSMOOTH': _keep,
    'SURFACE_DEFORM': _keep, 'WARP': _keep, 'WAVE': _keep, 'DATA_TRANSFER': _keep,
    'MESH_CACHE': _keep, 'UV_PROJECT': _keep, 'UV_WARP': _keep, 'VERTEX_WEIGHT_EDIT': _keep,
    'VERTEX_WEIGHT_MIX': _keep, 'VERTEX_WEIGHT_PROXIMITY': _keep, 'NORMAL_EDIT': _keep,
    'WEIGHTED_NORMAL': _keep, 'CLOTH': _keep, 'COLLISION': _keep, 'DYNAMIC_PAINT': _keep,
    'SOFT_BODY': _keep, 'SURFACE': _keep,
    # On a Volume object it makes voxels, which `volume_voxels` counts.
    'MESH_TO_VOLUME': _keep,
    # Only ever remove what they are given.
    'MASK': _reduce, 'BUILD': _reduce, 'WELD': _reduce,
}
# The types a count cannot hold, and why. Each still counts as keeping what
# it is given; nothing in the app's own rows makes them make more.
_UNMODELLED = {
    'MESH_SEQUENCE_CACHE': "it reads its mesh from an Alembic or USD file Blender has opened "
                           "(a Cache File), which nothing in the app opens",
    'VOLUME_DISPLACE': "it moves a Volume object's voxels, and makes no mesh",
}
# Parts of a count that are left out, with why.
_UNMODELLED_PARTS = {
}


def growth_kinds():
    """The modifier types the model knows (for the completeness check)."""
    return set(_GROWTH) | set(_UNMODELLED)


# The Sculpt header's Voxel Remesh estimate bounds the 46 remeshes it was
# fitted on by a quarter or more, but the completeness check found a shape it
# does not: a Bézier curve bevelled 0.1 and extruded 16 (a ribbon a voxel
# thick) under a Remesh at 0.2 made 13,562 vertices against an estimate of
# 12,635, 7% over it. The modifier's count takes this margin on top.
REMESH_MARGIN = 1.3
# The kinds whose count, when not exact, is still close to Blender's: an
# Array fitted to a curve (the curve's length), a Mirror or an Array that
# merges (merging only removes), and the deforms. A count made only of these
# that says an object is past the budget while Blender holds it inside is a
# change Blender has not evaluated yet (`_judge`), not a loose bound.
_TIGHT = {'SUBSURF', 'MULTIRES', 'ARRAY', 'MIRROR', 'SCREW', 'OCEAN', 'TRIANGULATE', 'WIREFRAME',
          'MASK', 'BUILD', 'WELD'}


# The kinds a refinement does not evaluate through, because Blender takes
# long per vertex there (Skin: 7.8 s at 499 loops) — their bound stands.
# Not Boolean: its bound counts where the surfaces cross (`_crossings`), and
# Blender then takes what it would take after the change anyway (the combs of
# 50 plates: 0.06 s Manifold, 1.95 s Exact). Not Remesh: its bound is only
# evaluated once it is inside the budget, and OpenVDB is quick there
# (desktop 5.2.1, Suzanne at 0.03, 0.015, 0.01 and 0.007: 19,006, 77,482,
# 175,276 and 359,294 vertices in 0.01 to 0.09 s). Round 4's fix-round review:
# with Remesh here its 1.3 margin was never refined, Suzanne under a Remesh at
# 0.01 counted 618,196 against Blender's 175,276, and Add Modifier ▸
# Subdivision Surface was refused at 2,781,882 where Blender makes 701,098.
_SLOW = ('SKIN', 'OCEAN', 'FLUID', 'CLOTH', 'SOFT_BODY', 'DYNAMIC_PAINT',
         'PARTICLE_INSTANCE', 'EXPLODE', 'NODES', 'MESH_DEFORM', 'SURFACE_DEFORM',
         'LAPLACIANDEFORM', 'PARTICLE_SYSTEM') + tuple(
    k for k in ('GREASE_PENCIL_ARRAY', 'GREASE_PENCIL_MULTIPLY', 'GREASE_PENCIL_MIRROR', 'GREASE_PENCIL_SUBDIV',
                'GREASE_PENCIL_ENVELOPE', 'GREASE_PENCIL_DASH', 'GREASE_PENCIL_OUTLINE', 'GREASE_PENCIL_SIMPLIFY',
                'GREASE_PENCIL_LENGTH'))


class _Walk:
    """`obj`'s stack counted, modifier by modifier (see `_walk`)."""

    def __init__(self, obj, s, sculpt=None):
        self.obj, self.s = obj, s
        self.sculpt = (obj.mode == 'SCULPT') if sculpt is None else sculpt
        self.stack = _stack(obj, s)
        self.steps = []          # (modifier, counts given) for each shown one
        self.subdivisions = []   # the Subdivision Surfaces' steps, for their time
        self.fluids = []         # the Fluid modifiers' steps, for their simulation's memory
        self.final = None
        # What the object keeps beside its mesh, counted with it but not
        # given to the modifiers after: a particle system's points.
        self.extra = 0
        self.refined = False
        # A light count's bound that does not hold without asking Blender
        # (`_crossings`: faces in one plane, Self Intersection): `_final`
        # makes the count exact instead.
        self.unsure = False
        # Whether the count is near what Blender makes: from an exact base,
        # through kinds whose count is exact or a close bound (`_TIGHT`).
        self.tight = True
        # The most seconds a Fast Boolean in the stack takes Blender, and its
        # name (`_fast_seconds`): past FAST_SECONDS nothing is evaluated
        # through it.
        self.fast_seconds = 0.0
        self.fast_name = None

    def measures(self, index, counts):
        key = (_pointer(self.obj), index, self.s.render, self.sculpt)
        if key in self.s._measures:
            return self.s._measures[key]
        if self.fast_seconds > FAST_SECONDS:
            # Through a Fast Boolean that takes Blender longer than that.
            raise Unpriceable(_fast_words(self.obj, self.fast_name, self.fast_seconds))
        if counts.v > BUDGET:
            raise Unpriceable(
                "what %s's %s is given, %s vertices, is past the budget already, so it cannot "
                "be counted" % (self.obj.name, _modifier_word(self.stack[index]), format(counts.v, ',')))
        measured = _evaluate(self.obj, self.s, self.stack, index, self.sculpt)
        self.s._measures[key] = measured
        return measured


def _walk(obj, s, sculpt=None, refine=False):
    """Counts `obj`'s stack. With `refine`, a bound is replaced by Blender's
    own count wherever that can be asked for inside the budget (see the
    module's note), but never through a kind Blender is slow on (`_SLOW`).
    With `refine='light'` the bounds are made from what Blender is asked for
    the modifiers that need it (a Boolean's crossings, a Bevel's angles,
    what a Remesh or a fitted Array is given), and no bound is replaced by a
    count of its own: what passes the budget that way passes it exactly too,
    and the evaluation that would make it exact is the one Blender makes
    after the change anyway (`_final`). Where a bound holds only from what
    Blender would make (a Boolean's faces in one plane, Self Intersection:
    `_crossings`), the walk is `unsure` and `_final` makes it exact."""
    resolved = (obj.mode == 'SCULPT') if sculpt is None else sculpt
    key = (_pointer(obj), bool(resolved), refine, s.render, s._version)
    cached = s._walks.get(key)
    if cached is not None:
        return cached
    w = _walk_once(obj, s, sculpt, refine)
    s._walks[key] = w
    return w


def _walk_once(obj, s, sculpt, refine):
    w = _Walk(obj, s, sculpt)
    w.refined = refine
    counts = _base(obj, s)
    w.tight = counts.exact
    hypothetical = s.bases.get(_pointer(obj)) is not None or _pointer(obj) in s.synthetic
    slow = False
    for i, m in enumerate(w.stack):
        if not _shown(m, s):
            continue
        w.steps.append((m, counts))
        step = _Step(w, i, m, counts)
        if m.type in ('SUBSURF', 'MULTIRES'):
            # Multires builds the same limit surface of what it is given
            # (round 4's second fix-round review: Multires Subdivide on a
            # 250-gon, 9.00 s).
            w.subdivisions.append(step)
        elif m.type == 'FLUID':
            w.fluids.append(step)
        grow = _GROWTH.get(m.type, _keep)
        made = grow(step, counts)
        if refine and m.type == 'BEVEL' and made.v > BUDGET and counts.v <= BUDGET and not hypothetical:
            made = _g_bevel_measured(step, counts, step.measures())
        slow = slow or m.type in _SLOW or w.fast_seconds > FAST_SECONDS
        if refine is True and not made.exact and made.v <= BUDGET and not slow and not hypothetical \
                and obj.type in GEOMETRY_TYPES:
            # Blender is asked for a mesh: never for a Grease Pencil's or hair
            # curves' points (fix round 3: a Line Art's bound refined this way
            # raised "Object does not have geometry data").
            made = Counts(*_evaluate(obj, s, w.stack, i + 1, w.sculpt).counts.tuple())
        if not made.exact and m.type not in _TIGHT:
            w.tight = False
        counts = made
    w.final = counts
    return w


def _final(obj, s, sculpt=None, light=False):
    """The count of `obj`, made exact as far as the budget allows when the
    first, cheap count passes it. With `light`, a bound made from what
    Blender is asked for (`_walk`'s `refine='light'`) stands when it is inside
    the budget: measured in desktop 5.2.1 on two 400 × 400 grids under a
    Solidify with a Boolean Union (399,254 vertices), the exact count asked
    Blender for the Boolean once more on a copy, which is the time the
    change's own evaluation takes after it; `_judge` asks for it whenever the
    bound is past the budget or the memory left, or not sure (`_Walk.unsure`:
    round 4's fix round 2 review measured a light count of 92,328 where
    Blender made 208,628, two grids' faces in one plane, and 4,848 against
    10,043 under Self Intersection). Not through a Skin, whose loops are read
    from what it is given."""
    w = _walk(obj, s, sculpt)
    if w.final.v > BUDGET and not w.final.exact:
        if light and not any(m.type == 'SKIN' for m, _ in w.steps):
            w = _walk(obj, s, sculpt, refine='light')
            if w.final.v <= BUDGET and not w.unsure:
                return w
        if w.fast_seconds > FAST_SECONDS:
            # Asking Blender would run its Fast Boolean for longer than that
            # (fix round 3's review): the light walk's bound stands, and
            # `_judge` refuses the change for its time where it is slower
            # than now. The light walk, not the first count: that one reads
            # no place (every corner against every corner), so 'now' and
            # the change counted the same and a Location onto A's plane at a
            # budget of 17,201 passed (part 12i.5 on this round's first try).
            if w.refined != 'light' and not any(m.type == 'SKIN' for m, _ in w.steps):
                w = _walk(obj, s, sculpt, refine='light')
            return w
        w = _walk(obj, s, sculpt, refine=True)
    return w


def _dirty(obj, s):
    """Whether Blender's evaluation of `obj` as it is now is not what the
    changes would make: anything of its own changes, it moves, or an object
    it reads (`_references`) is dirty itself."""
    if obj is None:
        return False
    p = _pointer(obj)
    if p in s._dirt:
        return s._dirt[p]
    s._dirt[p] = False  # a cycle of references reads as clean, once
    dirty = (s.touches(obj) or _moves(obj, s) or p in s.synthetic
             or any(_dirty(other, s) for other in _references(obj, s)))
    s._dirt[p] = dirty
    return dirty


def _stand_in(obj, s):
    """A copy of `obj` in the scene with the changes made, which the copies
    the budget evaluates read in its place: where it would be, its data and
    its modifiers as they would be (round 4's fix-round review: a Hook's
    empty scaled 36 times through the Data API row was read where it was, and
    a Remesh after the Hook was counted at 6,225 where Blender made
    3,119,048). `obj` itself when nothing it is or reads changes."""
    if obj is None or not _dirty(obj, s):
        return obj
    p = _pointer(obj)
    if p in s._stand_ins:
        return s._stand_ins[p]
    if obj in s._visiting or len(s._visiting) >= CHAIN_DEPTH:
        return obj
    s._visiting.append(obj)
    try:
        stack = _stack(obj, s) if obj.type in GEOMETRY_TYPES else []
        copy = _materialize(obj, s, stack, len(stack), obj.mode == 'SCULPT', link=True)
    finally:
        s._visiting.pop()
    s._stand_ins[p] = copy
    return copy


def _materialize(obj, s, stack, upto, sculpt, link=True):
    """A copy of `obj` with the changes made and only the modifiers of
    `stack` before `upto` that are shown, set to evaluate as the pricing
    does (sculpt levels in Sculpt Mode, render settings for a render),
    linked in the scene so Blender evaluates it; what Blender holds is not
    touched. Every object it reads that the changes reach is a stand-in
    (`_stand_in`), and where it is is where it would be (`_matrix`)."""
    entries = [m for m in stack[:upto] if _shown(m, s)]
    copy = obj.copy()
    s._objects.append(copy)
    _still(copy)
    # Data of its own, always: a copy linked with the object's own data makes
    # Blender evaluate every user of that data again (a new user of a mesh is
    # a geometry update of the mesh). Measured in desktop 5.2.1, two 400 × 400
    # grids under a Solidify, Boolean Union: linking a copy of A that kept
    # only the Solidify took 0.70 s, because A's Boolean ran again; with a
    # copy of the mesh, 0.019 s. A mesh's copy shares its arrays until one is
    # written (0.017 ms for that mesh). Every evaluation of a Boolean's price
    # paid it (Add Modifier ▸ Weld: 9.7 to 10.2 s against Blender's own
    # 0.49 to 0.51). Another object sharing a mesh in Edit Mode would also be
    # evaluated from Blender's edit copy of it, as Edit Mode evaluates.
    if obj.type == 'MESH':
        mesh = s.data_of(obj).copy()
        s._meshes.append(mesh)
        _still(mesh)
        if mesh.shape_keys is not None:
            s._keys.append(mesh.shape_keys)
        copy.data = mesh
    elif obj.type in ('CURVE', 'SURFACE', 'FONT', 'LATTICE'):
        data = s.data_of(obj).copy()
        _still(data)
        (s._lattices if obj.type == 'LATTICE' else s._curves).append(data)
        if getattr(data, 'shape_keys', None) is not None:
            s._keys.append(data.shape_keys)
        copy.data = data
    keep = {m.name for m in entries if not isinstance(m, Virtual)}
    for m in list(copy.modifiers):
        if m.name not in keep:
            copy.modifiers.remove(m)
    for m in entries:
        if isinstance(m, Virtual):
            made = copy.modifiers.new(m.name, m.type)
            source = m.like
            if source is not None:
                for prop in source.bl_rna.properties:
                    if prop.is_readonly or prop.identifier in ('name', 'rna_type'):
                        continue
                    try:
                        setattr(made, prop.identifier, getattr(source, prop.identifier))
                    except (AttributeError, TypeError, ValueError, RuntimeError):
                        pass
            for key, value in m.settings.items():
                try:
                    setattr(made, key, value)
                except (AttributeError, TypeError, ValueError):
                    pass
    for index, m in enumerate(entries):
        current = next(i for i, c in enumerate(copy.modifiers) if c.name == m.name)
        if current != index:
            copy.modifiers.move(current, index)
    for owner, key, value in s.changes_on(obj):
        if owner == obj:
            # Its own settings other than where it is (`_matrix` places it):
            # Shape Key Lock and the active key among them (round 4's
            # fix-round review: Solo of a key x × 0.00005 under an Array fitted
            # to a length, 168 → 3,200,008, unpriced).
            if key in _TRANSFORM_KEYS or key in ('data', 'dimensions') or key.startswith('matrix_'):
                continue
            try:
                setattr(copy, key, value)
            except (AttributeError, TypeError, ValueError):
                pass
            continue
        if isinstance(owner, bpy.types.Modifier) and owner.name not in keep:
            continue
        if isinstance(owner, bpy.types.Constraint) and _moves(obj, s):
            continue  # the copy is placed where they would put it, without them
        # A modifier's, a pose bone's, a particle system's setting (round 4's
        # fix-round review: a pose bone's Scale 40 under a Remesh after an
        # Armature, priced on the armature as it was, 2,648 → 3,849,608).
        try:
            _apply(copy, obj, [(owner, key, value)])
        except (AttributeError, TypeError, ValueError, KeyError):
            pass
    for m in copy.modifiers:
        # A legacy texture it reads, as the changes would make it.
        for identifier in _texture_props(m):
            texture = getattr(m, identifier, None)
            like = s.texture_like(texture) if texture is not None else None
            if like is not None and like is not texture:
                try:
                    setattr(m, identifier, like)
                except (TypeError, ValueError, AttributeError):
                    pass
        m.show_viewport = True
        m.show_render = True
        if sculpt and m.type == 'MULTIRES':
            m.levels = m.sculpt_levels
        if s.render and m.type in ('SUBSURF', 'MULTIRES'):
            m.levels = m.render_levels
        if s.render and m.type == 'SCREW':
            m.steps = m.render_steps
        if s.render and m.type == 'OCEAN':
            m.viewport_resolution = m.resolution
        for identifier, target in _pointer_props(m):
            if target == 'Collection':
                _collection_stand_in(m, identifier, obj, s)
                continue
            if target != 'Object':
                continue
            other = getattr(m, identifier, None)
            if other is not None and other != obj:
                stand_in = _stand_in(other, s)
                if stand_in is not other:
                    # A Hook's object setter resets its inverse to the new
                    # object's (rna_HookModifier_object_set → hook reset), which
                    # would undo exactly the move being priced: measured, the
                    # stand-in of an empty scaled 36 left the cube 2 m wide.
                    kept = ((m.matrix_inverse.copy(), tuple(m.center)) if m.type == 'HOOK' else None)
                    try:
                        setattr(m, identifier, stand_in)
                    except (TypeError, ValueError, AttributeError):
                        pass
                    if kept is not None:
                        m.matrix_inverse, m.center = kept
    if _moves(obj, s):
        # Placed where the changes put it, with nothing left to move it again.
        world = _matrix(obj, s)
        copy.parent = None
        copy.constraints.clear()
        copy.delta_location = (0.0, 0.0, 0.0)
        copy.delta_scale = (1.0, 1.0, 1.0)
        copy.delta_rotation_euler = (0.0, 0.0, 0.0)
        copy.delta_rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        copy.matrix_world = world
    if link:
        bpy.context.scene.collection.objects.link(copy)
    return copy


def _collection_stand_in(m, identifier, obj, s):
    """A copy's modifier reading a collection whose objects the changes reach
    (a Boolean's operands) reads a collection of their stand-ins instead
    (`_stand_in`), kept out of every scene and removed with the pricing.
    Round 4's fix round 2 review, desktop 5.2.1: B2, a comb, lowered through
    B1, both in a Boolean's collection, was evaluated where it had been, and
    the exact count of 4,848 passed a budget of 7,248 where Blender made
    9,648 — only an Object pointer was given its stand-in. The object itself
    is left out, as Blender's Boolean leaves it out of its own operands."""
    collection = getattr(m, identifier, None)
    if collection is None:
        return
    members = [o for o in collection.all_objects if o != obj]
    if not any(_dirty(o, s) for o in members):
        return
    stand = bpy.data.collections.new("Budget operands")
    s._collections.append(stand)
    for o in members:
        try:
            stand.objects.link(_stand_in(o, s))
        except RuntimeError:
            pass                       # linked once already (the same stand-in)
    try:
        setattr(m, identifier, stand)
    except (TypeError, ValueError, AttributeError):
        pass


def _evaluate(obj, s, stack, upto, sculpt):
    """Blender's own mesh of `obj`'s stack up to (not including) `stack[upto]`,
    the changes made, measured. Made on a copy of the object in the scene
    with only those modifiers (`_materialize`), so what Blender holds is not
    touched — or, when nothing the changes make reaches those modifiers and
    they are the whole stack Blender shows now, read from Blender's
    evaluation as it is. Once per pricing for each stack (`Prices._evals`):
    the count after a modifier is what the next one is given."""
    entries = [m for m in stack[:upto] if _shown(m, s)]
    key = (_pointer(obj), tuple(id(m) if isinstance(m, Virtual) else _pointer(m) for m in entries),
           s.render, bool(sculpt), s._version)
    measured = s._evals.get(key)
    if measured is None:
        measured = _evaluate_once(obj, s, stack, upto, sculpt, entries)
        s._evals[key] = measured
    return measured


def _clean_through(obj, s, entries):
    """Whether Blender's evaluation of `obj` through `entries` (the whole
    stack it shows) is what the changes would make: nothing they make
    reaches `obj` but settings of modifiers outside `entries` — the new
    modifier of Add Modifier, a setting of one after them that is hidden.
    Round 4's fix-round review: Add Modifier ▸ Weld after a Boolean of two
    400 × 400 grids evaluated the Boolean on a copy twice (11.0–12.3 s
    against Blender's 0.68), because a modifier to be added made the whole
    object read as changed."""
    p = _pointer(obj)
    if (s.render or p in s.orders or p in s.bases or p in s.synthetic or p in s.constraints_added
            or p in s.added_elements):
        return False
    inside = {_pointer(m) for m in entries if not isinstance(m, Virtual)}
    for owner, key, value in s.changes_on(obj):
        if not isinstance(owner, bpy.types.Modifier) or _pointer(owner) in inside:
            return False
    if any(s.changes_on(t) for t in _textures_of(obj)):
        return False
    data = s.get(obj, 'data')
    if data is not None and s.changes_on(data):
        return False
    keys = getattr(data, 'shape_keys', None) if data is not None else None
    if keys is not None and s.changes_on(keys):
        return False
    if _moves(obj, s):
        return False
    return not any(_dirty(other, s) for other in _references(obj, s))


def _evaluate_once(obj, s, stack, upto, sculpt, entries):
    # Shape keys move the vertices before any modifier, so a keyed mesh is
    # measured as Blender evaluates it (round 4's fix-round review: a key's
    # Value × 50 under a Remesh at 0.1 was measured on the basis, counted
    # 6,225, and Blender made 6,012,008).
    keyed = obj.type == 'MESH' and getattr(s.get(obj, 'data'), 'shape_keys', None) is not None
    if not entries and obj.type == 'MESH' and not keyed:
        return Measures(s.data_of(obj))
    if not entries and obj.type != 'MESH':
        with _built(s.data_of(obj)) as mesh:
            return Measures(mesh)
    real_now = [m for m in obj.modifiers if _shown(m, Prices(render=s.render))]
    if (not s.render and len(entries) == len(real_now)
            and all(not isinstance(a, Virtual) and a == b for a, b in zip(entries, real_now))
            and sculpt == (obj.mode == 'SCULPT')
            and (not _dirty(obj, s) or _clean_through(obj, s, entries))):
        evaluated = obj.evaluated_get(_depsgraph())
        mesh = evaluated.to_mesh()
        try:
            return Measures(mesh)
        finally:
            evaluated.to_mesh_clear()
    copy = _materialize(obj, s, stack, upto, sculpt)
    evaluated = copy.evaluated_get(_depsgraph())
    mesh = evaluated.to_mesh()
    try:
        return Measures(mesh)
    finally:
        evaluated.to_mesh_clear()


# --------------------------------------------------------------------------
# What a change reaches


_POINTERS = {}


def _pointer_props(m):
    """The Object and Collection pointers of a modifier's kind."""
    kind = m.type
    if kind not in _POINTERS:
        found = []
        for prop in m.bl_rna.properties:
            if prop.type == 'POINTER':
                target = getattr(prop.fixed_type, 'identifier', '')
                if target in ('Object', 'Collection'):
                    found.append((prop.identifier, target))
        _POINTERS[kind] = found
    return _POINTERS[kind]


_TEXTURE_POINTERS = {}


def _texture_props(m):
    """The legacy Texture pointers of a modifier's kind (a Displace's, a
    Warp's and a Wave's Texture, the Vertex Weight modifiers' Mask
    Texture)."""
    kind = getattr(m, 'type', None)
    if kind not in _TEXTURE_POINTERS:
        found = []
        try:
            for prop in m.bl_rna.properties:
                if prop.type == 'POINTER' and getattr(prop.fixed_type, 'identifier', '') == 'Texture':
                    found.append(prop.identifier)
        except AttributeError:
            pass
        _TEXTURE_POINTERS[kind] = tuple(found)
    return _TEXTURE_POINTERS[kind]


def _textures_of(obj):
    """The legacy textures `obj`'s modifiers read."""
    found = []
    for m in getattr(obj, 'modifiers', ()):
        for identifier in _texture_props(m):
            texture = getattr(m, identifier, None)
            if texture is not None:
                found.append(texture)
    return found


def _references(obj, s):
    """The objects whose own state can change what `obj` evaluates to: its
    modifiers' other objects (an Array's caps, curve and offset object, a
    Boolean's operands, a Particle Instance's emitter, and every other object
    a modifier reads, since where it is moves what a Remesh or a fitted Array
    is given) and its curve data's Bevel and Taper objects."""
    found = set()
    for m in _stack(obj, s):
        if isinstance(m, Virtual):
            source = m.like
            if source is None:
                continue
            m = source
        for identifier, target in _pointer_props(m):
            value = s.get(m, identifier)
            if value is None:
                continue
            if target == 'Object':
                found.add(value)
            else:
                found.update(value.all_objects)
        if getattr(m, 'type', None) == 'NODES':
            # Its inputs and its group's Object Info and Collection Info read
            # other objects too, and what an empty among them instances.
            read = set()
            for holder in _sibling('_blenderkit_nodecount').inputs_of(m):
                value = s.get(holder, 'value') if hasattr(holder, 'value') else None
                if isinstance(value, bpy.types.Object):
                    read.add(value)
                elif isinstance(value, bpy.types.Collection):
                    read.update(value.all_objects)
            gate = _gate()
            if gate is not None and hasattr(gate, '_tree_objects'):
                read.update(gate._tree_objects(s.get(m, 'node_group')))
            found.update(_with_instanced(read))
        if getattr(m, 'type', None) == 'LINEART' and s.get(m, 'source_type') == 'SCENE':
            # Line Art drawing the whole scene reads every object of it.
            found.update(o for o in bpy.context.scene.objects if o.type in GEOMETRY_TYPES and o != obj)
    data = s.get(obj, 'data')
    for ref in ('bevel_object', 'taper_object', 'follow_curve'):
        other = getattr(data, ref, None) if data is not None else None
        if other is not None:
            found.add(other)
    return found


def _with_instanced(objects):
    """`objects` and, for each empty among them that instances a collection,
    every object of that collection, at every level: what a Geometry Nodes
    Object Info or Collection Info realizes (see `_g_nodes`)."""
    found = set()
    stack = list(objects)
    seen = set()
    while stack:
        obj = stack.pop()
        if obj is None or obj in found:
            continue
        found.add(obj)
        collection = getattr(obj, 'instance_collection', None) if obj.type == 'EMPTY' else None
        if collection is not None and _pointer(collection) not in seen:
            seen.add(_pointer(collection))
            stack.extend(collection.all_objects)
    return found


def _uses_tree(tree, wanted, seen):
    if tree is None:
        return False
    p = _pointer(tree)
    if p == wanted:
        return True
    if p in seen:
        return False
    seen.add(p)
    for node in tree.nodes:
        inner = getattr(node, 'node_tree', None)
        if inner is not None and _uses_tree(inner, wanted, seen):
            return True
    return False


def tree_users(tree):
    """The objects whose Geometry Nodes modifiers run `tree`."""
    wanted = _pointer(tree)
    found = []
    for o in bpy.data.objects:
        for m in getattr(o, 'modifiers', ()):
            if m.type == 'NODES' and _uses_tree(m.node_group, wanted, set()):
                found.append(o)
                break
    return found


def affected(owners, s):
    """The objects whose evaluated mesh a change to `owners` reaches: an
    object, or each that uses changed data (a mesh, a curve, a text, a
    particle system's settings), and then each object that reads one of
    those."""
    seeds = set()
    for owner in owners:
        try:
            block = owner.id_data
        except (AttributeError, ReferenceError):
            continue
        if isinstance(block, bpy.types.Object):
            seeds.add(block)
        elif isinstance(block, bpy.types.ParticleSettings):
            seeds.update(o for o in bpy.data.objects
                         if any(p.settings == block for p in getattr(o, 'particle_systems', ())))
        elif isinstance(block, bpy.types.Key):
            # A mesh's (or a curve's, a lattice's) shape keys: its objects.
            seeds.update(o for o in bpy.data.objects
                         if o.data is not None and getattr(o.data, 'shape_keys', None) == block)
        elif isinstance(block, bpy.types.NodeTree):
            # A node group: every object whose Geometry Nodes run it, in
            # itself or in a group it uses.
            seeds.update(tree_users(block))
        elif isinstance(block, bpy.types.Scene):
            # The scene's Simplify: every object a subdivision level is read from.
            seeds.update(o for o in block.objects
                         if any(m.type in ('SUBSURF', 'MULTIRES') for m in getattr(o, 'modifiers', ())))
        elif isinstance(block, bpy.types.Texture):
            # A legacy texture: every object whose modifiers read it.
            target = _pointer(block)
            seeds.update(o for o in bpy.data.objects if any(_pointer(t) == target for t in _textures_of(o)))
        elif block is not None:
            seeds.update(o for o in bpy.data.objects if o.data == block)
    found = set(seeds)
    grew = True
    while grew:
        grew = False
        for other in bpy.data.objects:
            if other in found:
                continue
            # Every object, whatever its type: an empty or a parent passes a
            # move on to what reads it (round 4's fix-round review: an
            # Array's offset object under an empty P, P moved through the Data
            # API row, 88 vertices counted and 3,994,576 made — the walk had
            # skipped everything that is not a mesh, a curve or a text).
            parent = s.get(other, 'parent')
            reached = (parent in found
                       or any(t in found for t in _constraint_targets(other, s)))
            if not reached and (other.modifiers or other.type != 'MESH' or _pointer(other) in s.added):
                reached = bool(_references(other, s) & found)
            if not reached and other.type == 'META' and _is_basis(other):
                # A metaball family's basis polygonizes every member.
                base = _family_base(other.name)
                reached = any(o.type == 'META' and _family_base(o.name) == base for o in found)
            if reached:
                found.add(other)
                grew = True
    return [o for o in found if o.type in COUNTED_TYPES]


# --------------------------------------------------------------------------
# Refusing


def available_memory():
    """What this process may still allocate before the system ends it
    (`os_proc_available_memory`), or None where that cannot be read."""
    try:
        import ctypes
        function = ctypes.CDLL(None).os_proc_available_memory
    except (ImportError, OSError, AttributeError):
        return None
    function.restype = ctypes.c_size_t
    function.argtypes = []
    return function() or None


def refuse_count(obj, count, change, instead, note=""):
    """Raises, in words, when `count` vertices would pass `BUDGET` or need
    more memory than this process has left. `change` says what would make
    them ("Level 4", "Subdivision level 5"), `instead` what to do, and `note`
    follows the count."""
    if count > BUDGET:
        raise RuntimeError(
            "%s would give %s %s vertices%s, and this app stops at %s so it does not run "
            "out of memory. %s" % (change, obj.name, format(count, ','), note, format(BUDGET, ','),
                                   instead))
    free = available_memory()
    need = count * PEAK_BYTES_PER_VERTEX
    if free is not None and need > free:
        raise RuntimeError(
            "%s would give %s %s vertices%s, which needs about %.1f GB of memory, and %.1f GB "
            "is free. Close other apps, or %s" % (change, obj.name, format(count, ','), note, need / 1e9,
                                                  free / 1e9, instead[0].lower() + instead[1:]))
    return count


def _over(count):
    if count > BUDGET:
        return True
    free = available_memory()
    return free is not None and count * PEAK_BYTES_PER_VERTEX > free


def _skin_refusal(obj, loops):
    return ("Skin would get %s with %s closed loops of edges, and Blender's Skin takes minutes "
            "on that many (measured on a desktop Mac: 900 loops, 18 s; 499, 7.8 s), with "
            "the app frozen meanwhile. Skin is made for a skeleton of edges, which builds "
            "in a moment: 20,000 edges with no loop took 0.04 s." % (obj.name, format(loops, ',')))


def _subdivision_refusal(obj, name, seconds):
    return ("%s's %s would take Blender about %d s to build its limit surface, with the app "
            "frozen meanwhile: a vertex with many edges, a face with many sides, or a mesh of "
            "triangles takes Subdivision Surface far longer than its size (measured on a desktop "
            "Mac: a 250-sided N-Gon 8.7 s, a 40,962-vertex icosphere 12 s). Turn off its Use Limit "
            "Surface or lower its Quality (Blender's Advanced settings, in the Data API), or start "
            "from quads." % (obj.name, name, max(1, round(seconds))))


def _skin_loops(w):
    """(the most loops of edges, E - V + 1, any Skin in the walk is given, its
    name)."""
    worst = (0, None)
    for m, counts in w.steps:
        if m.type == 'SKIN':
            loops = counts.e - counts.v + 1
            if loops > worst[0]:
                worst = (loops, m.name)
    return worst


def ocean_samples(resolution):
    """The samples an Ocean simulates at `resolution`: (r²)², in Displace
    mode as in Generate (round 4's review: Resolution 40 was refused in
    Generate and let through in Displace, and RNA goes to 1024)."""
    side = int(resolution) ** 2
    return side * side


def _ocean_samples(w):
    worst = 0
    for m, counts in w.steps:
        if m.type == 'OCEAN':
            r = w.s.get(m, 'resolution' if w.s.render else 'viewport_resolution')
            worst = max(worst, ocean_samples(r))
    return worst


def refuse_ocean(obj, resolution, change):
    """Raises, in words, when an Ocean at `resolution` would simulate more
    samples than `BUDGET`, or need more memory than is left for them."""
    samples = ocean_samples(resolution)
    if samples > BUDGET:
        raise RuntimeError(
            "%s would have %s's Ocean simulate %s points (Resolution² × Resolution², whichever "
            "Geometry it builds), and this app stops at %s so it does not run out of memory. Use "
            "a lower Resolution." % (change, obj.name, format(samples, ','), format(BUDGET, ',')))
    free = available_memory()
    need = samples * OCEAN_BYTES_PER_SAMPLE
    if free is not None and need > free:
        raise RuntimeError(
            "%s would have %s's Ocean simulate %s points, which needs about %.1f GB of memory, "
            "and %.1f GB is free. Close other apps, or use a lower Resolution."
            % (change, obj.name, format(samples, ','), need / 1e9, free / 1e9))


def _held_count(obj):
    """The vertices Blender's viewport evaluated `obj` to last, read from the
    depsgraph as it is, without evaluating anything (0 for an object it has
    not evaluated)."""
    try:
        layer = bpy.context.view_layer
        dg = layer.depsgraph if layer is not None else None
        if dg is None:
            return 0
        evaluated = obj.evaluated_get(dg)
        if evaluated == obj:
            return 0
        if obj.type == 'MESH':
            return len(evaluated.data.vertices)
        if obj.type == 'CURVES':
            return len(evaluated.data.points)
        mesh = evaluated.to_mesh()
        try:
            return len(mesh.vertices) if mesh is not None else 0
        finally:
            evaluated.to_mesh_clear()
    except (RuntimeError, ReferenceError, AttributeError):
        return 0


def _blender_now(obj):
    """The vertices Blender's viewport holds for `obj` as it is evaluated now,
    or None where that cannot be read."""
    try:
        evaluated = obj.evaluated_get(_depsgraph())
        if obj.type == 'MESH':
            return len(evaluated.data.vertices)
        if obj.type == 'CURVES':
            return len(evaluated.data.points)
        mesh = evaluated.to_mesh()
        try:
            return len(mesh.vertices) if mesh is not None else 0
        finally:
            evaluated.to_mesh_clear()
    except (RuntimeError, ReferenceError, AttributeError):
        return None


def _judge(objects, s, change, instead, sculpt=None):
    """Refuses, in words, when the changes in `s` would leave any of `objects`
    past the budget or the memory left and heavier than it is now; give a
    Skin more loops than its cap and than now; have an Ocean simulate past
    the budget and more than now; make a Subdivision Surface's limit surface
    take longer than SUBDIVISION_SECONDS and than now; have a Fluid domain's
    grids or a volume's voxels pass theirs; or (a change past HUGE) put a
    vertex past float's reach. An object already past the budget (opened from
    a file) can still be changed in ways that do not make it heavier — 'now'
    being what Blender holds when the count of now is close (`_TIGHT`)."""
    for obj in objects:
        try:
            after = _final(obj, s, sculpt, light=True)
            if after.refined == 'light' and (_over(after.final.v) or (
                    obj.type == 'META' and meta_seconds(obj, s, after.final.v) > METABALL_SECONDS)):
                # The bound is past a limit: the count is made exact before it
                # is judged (`_final`), and everything below reads that.
                after = _final(obj, s, sculpt)
            if (s.huge or _could_overflow(obj, s)) and not _over(after.final.v) \
                    and obj.type not in ('VOLUME', 'GREASEPENCIL'):
                _finite_after(obj, s)
        except Unpriceable as why:
            raise RuntimeError("%s: %s." % (change, str(why))) from None
        except NonFinite:
            raise RuntimeError(
                "%s would put %s's vertices at infinite or undefined positions: Blender's arithmetic "
                "overflows past 3.4e38 (measured on a text's Offset and Depth, an Array's Constant "
                "Offset and a Displace's Strength), and the app cannot draw or pick them. Use a smaller "
                "value." % (change, obj.name)) from None
        loops, skin = _skin_loops(after)
        if loops > SKIN_MAX_LOOPS and not after.refined:
            # What the Skin is given may be a bound; Blender is asked.
            try:
                after = _walk(obj, s, sculpt, refine=True)
            except Unpriceable as why:
                raise RuntimeError("%s: %s." % (change, str(why))) from None
            loops, skin = _skin_loops(after)
        samples = _ocean_samples(after)
        count = after.final.v + after.extra
        heavy = _over(count)
        try:
            seconds, subdivision = _subdivision_seconds(after)
        except Unpriceable as why:
            raise RuntimeError("%s: %s." % (change, str(why))) from None
        slow = seconds > SUBDIVISION_SECONDS
        fast = after.fast_seconds
        slow_fast = fast > FAST_SECONDS
        polygonizing = meta_seconds(obj, s, count) if obj.type == 'META' else 0.0
        slow_meta = polygonizing > METABALL_SECONDS
        try:
            fluid = max([fluid_bytes(x) for x in after.fluids] or [0])
            voxels = volume_voxels(obj, s) if obj.type == 'VOLUME' else 0
        except Unpriceable as why:
            raise RuntimeError("%s: %s." % (change, str(why))) from None
        voxels = voxels or 0
        free = available_memory()
        simulated = fluid > FLUID_BYTES or (free is not None and fluid > free)
        gridded = voxels > VOLUME_VOXELS or (free is not None and voxels * VOLUME_BYTES_PER_VOXEL > free)
        if heavy or loops > SKIN_MAX_LOOPS or samples > BUDGET or slow or simulated or gridded or slow_meta \
                or slow_fast:
            now = Prices(render=s.render)
            try:
                strict = _pointer(obj) in s.was
                try:
                    # A change the gate could not put back for the price leaves
                    # nothing to count 'now' from but what Blender holds.
                    before = None if strict else _final(obj, now, sculpt)
                except Unpriceable:
                    before = None
                was = before.final.v if before is not None else s.was.get(_pointer(obj), 0)
                if heavy and before is not None and before.tight and not s.render:
                    # 'Now' counted closely yet heavier than what Blender holds:
                    # something reached it that Blender has not evaluated yet
                    # (round 4's fix-round review: a Fit Curve's curve scaled
                    # 5e5 left the Array at 16 vertices in Blender, which adds
                    # no transform relation for it, MOD_array.cc; the next
                    # edit then passed as 'not heavier than now' and Blender
                    # made 4,162,632). What Blender holds is 'now'.
                    current = _blender_now(obj)
                    if current is not None and current < was:
                        was = current
                if heavy and count > was:
                    note = ""
                    if obj.type == 'FONT':
                        base = _base(obj, s)
                        note = (" (counted from its letters' outlines)" if base.v == count or not after.steps
                                else " once its modifiers are counted")
                    elif obj.type == 'GREASEPENCIL':
                        note = " (the points of its strokes, as its modifiers make them)"
                    elif after.extra:
                        note = " (%s of them its particle systems' points)" % format(after.extra, ',')
                    refuse_count(obj, count, change, instead, note)
                if loops > SKIN_MAX_LOOPS and (before is None or loops > _skin_loops(before)[0]):
                    raise RuntimeError("%s: %s" % (change, _skin_refusal(obj, loops)))
                if slow:
                    try:
                        was_seconds = (_subdivision_seconds(before)[0] if before is not None
                                       else s.was_seconds.get(_pointer(obj), 0.0))
                    except Unpriceable:
                        was_seconds = 0.0
                    if seconds > was_seconds * 1.05 + 0.05:
                        raise RuntimeError("%s: %s" % (change, _subdivision_refusal(obj, subdivision, seconds)))
                if slow_fast:
                    was_fast = before.fast_seconds if before is not None else 0.0
                    if fast > was_fast * 1.05 + 0.05:
                        raise RuntimeError("%s: %s." % (change, _fast_words(obj, after.fast_name, fast)))
                if slow_meta:
                    was_meta = 0.0
                    if before is not None:
                        was_meta = meta_seconds(obj, now, before.final.v)
                    if polygonizing > was_meta * 1.05 + 0.05:
                        raise RuntimeError(
                            "%s would have Blender polygonize %s's metaball family of %d elements for about %d s "
                            "(%s vertices at most, each element's field read at each), with the app frozen "
                            "meanwhile (measured on a desktop Mac: 128 elements, 1,277,952 vertices, 5.8 s). Use "
                            "fewer elements or a larger Resolution." % (
                                change, obj.name, s.meta_elements.get(_pointer(obj), 0), max(1, round(polygonizing)),
                                format(count, ',')))
                if simulated:
                    try:
                        was_fluid = max([fluid_bytes(x) for x in before.fluids] or [0]) if before else 0
                    except Unpriceable:
                        was_fluid = 0
                    if fluid > was_fluid:
                        raise RuntimeError(
                            "%s would have %s's Fluid domain hold about %.1f GB for its simulation's grids "
                            "(Resolution Divisions cubed, the liquid's mesh at its Upres, a gas's noise), "
                            "and this app stops at %.1f GB%s so it does not run out of memory. Use lower "
                            "Resolution Divisions or Upres."
                            % (change, obj.name, fluid / 1e9, FLUID_BYTES / 1e9,
                               "" if free is None else " (%.1f GB is free)" % (free / 1e9)))
                if gridded:
                    try:
                        was_voxels = (volume_voxels(obj, now) or 0) if obj.type == 'VOLUME' else 0
                    except Unpriceable:
                        was_voxels = 0
                    if voxels > was_voxels:
                        raise RuntimeError(
                            "%s would give %s about %s voxels (its Mesh to Volume's surface times its "
                            "band, at its voxel size), and this app stops at %s so it does not run out of "
                            "memory. Use a lower Voxel Amount or a larger Voxel Size."
                            % (change, obj.name, format(voxels, ','), format(VOLUME_VOXELS, ',')))
                if samples > BUDGET and (before is None or samples > _ocean_samples(before)):
                    raise RuntimeError(
                        "%s would have %s's Ocean simulate %s points (Resolution² × Resolution², "
                        "whichever Geometry it builds), and this app stops at %s so it does not run "
                        "out of memory. Use a lower Resolution."
                        % (change, obj.name, format(samples, ','), format(BUDGET, ',')))
            finally:
                now.close()
        if samples:
            free = available_memory()
            if free is not None and samples * OCEAN_BYTES_PER_SAMPLE > free:
                raise RuntimeError(
                    "%s would have %s's Ocean simulate %s points, which needs about %.1f GB of "
                    "memory, and %.1f GB is free. Close other apps, or use a lower Resolution."
                    % (change, obj.name, format(samples, ','), samples * OCEAN_BYTES_PER_SAMPLE / 1e9,
                       free / 1e9))


# --------------------------------------------------------------------------
# Words


_KIND_WORDS = {'SUBSURF': 'Subdivision', 'MULTIRES': 'Multires', 'ARRAY': 'Array', 'SCREW': 'Screw',
               'OCEAN': 'Ocean', 'WIREFRAME': 'Wireframe', 'BEVEL': 'Bevel', 'REMESH': 'Remesh',
               'MIRROR': 'Mirror', 'SOLIDIFY': 'Solidify', 'SKIN': 'Skin', 'EDGE_SPLIT': 'Edge Split'}
_ADD_LABELS = {'SUBSURF': 'Subdivision Surface', 'ARRAY': 'Array', 'MIRROR': 'Mirror',
               'SOLIDIFY': 'Solidify', 'WIREFRAME': 'Wireframe', 'SKIN': 'Skin', 'SCREW': 'Screw',
               'BEVEL': 'Bevel', 'OCEAN': 'Ocean', 'EDGE_SPLIT': 'Edge Split', 'MULTIRES': 'Multires',
               'REMESH': 'Remesh', 'PARTICLE_INSTANCE': 'Particle Instance'}
_OCEAN_WORDS = {'viewport_resolution': 'Viewport Resolution', 'resolution': 'Render Resolution',
                'repeat_x': 'Repeat X', 'repeat_y': 'Repeat Y'}


def _modifier_word(m):
    return _KIND_WORDS.get(getattr(m, 'type', ''), getattr(m, 'name', 'modifier'))


def _value_words(value):
    if isinstance(value, bool):
        return "on" if value else "off"
    if isinstance(value, float):
        if math.isfinite(value) and abs(value) >= 1e4 and value == int(value) and abs(value) < 1e15:
            return format(int(value), ',')
        return "%g" % value
    if isinstance(value, str):
        return value.replace('_', ' ').title()
    if isinstance(value, (tuple, list)) and value and all(isinstance(v, bool) for v in value):
        on = [axis for axis, v in zip("XYZ", value) if v]
        return " ".join(on) if on else "none"
    if isinstance(value, (set, frozenset)):
        return ", ".join(sorted(value)) or "none"
    if hasattr(value, 'name'):
        return value.name
    if isinstance(value, (tuple, list)) and len(value) > 8:
        # A long custom-property array (fix round 3): its first values and
        # its length, not all of them on the banner.
        return "(%s, … %s values)" % (", ".join(_value_words(v) for v in value[:3]), format(len(value), ','))
    return str(value)


def _label(owner, key, value):
    """Words for a change, as the banner shows them: the old ones for the
    settings the rows had always priced, Blender's property names for the
    rest ("Bevel Segments 12", "Resolution Preview U 64")."""
    if isinstance(owner, bpy.types.Modifier):
        kind, name = owner.type, owner.name
        if key == 'show_viewport' and value:
            return "Showing %s in the viewport" % name
        if key in ('levels', 'render_levels', 'sculpt_levels') and kind in ('SUBSURF', 'MULTIRES'):
            return "%s level %s" % (_KIND_WORDS[kind], value)
        if kind == 'ARRAY' and key == 'count':
            return "Array count %s" % value
        if kind == 'SCREW' and key in ('steps', 'render_steps', 'iterations'):
            return "Screw %s %s" % ('Iterations' if key == 'iterations' else 'Steps', value)
        if kind == 'OCEAN' and key == 'geometry_mode':
            return "Ocean Geometry %s" % str(value).title()
        if kind == 'OCEAN' and key in _OCEAN_WORDS:
            return "Ocean %s %s" % (_OCEAN_WORDS[key], value)
        if kind == 'WIREFRAME' and key == 'use_replace' and not value:
            return "Wireframe with Replace Original off"
        word = name
    elif isinstance(owner, bpy.types.Curve):
        # The Data tab's words for a curve's, a surface's and a text's rows.
        text = _sibling('_blenderkit_text')
        if key in text._LABELS:
            return text._label(key, value)
        word = ""
    else:
        word = "" if isinstance(owner, bpy.types.ID) else getattr(owner, 'name', '') or ""
    try:
        prop = owner.bl_rna.properties[key].name or key
    except (AttributeError, KeyError):
        prop = key
    if word and prop.lower().startswith(word.lower()):
        word = ""  # "Mirror Axis", not "Mirror Mirror Axis"
    return ("%s %s %s" % (word, prop, _value_words(value))).strip()


def _instead(owner, key, value):
    if isinstance(owner, bpy.types.Modifier):
        if key == 'show_viewport':
            return "Lower what it makes before showing it."
        if owner.type == 'WIREFRAME' and key == 'use_replace':
            return "Keep Replace Original on, or start from a lighter mesh."
        if owner.type == 'OCEAN' and key == 'geometry_mode':
            return "Lower its Repeat and Resolution first, or start from a lighter mesh."
        return "Use a lower value, or start from a lighter mesh."
    if isinstance(owner, getattr(bpy.types, 'TextCurve', ())):
        return "Use less text, lower the resolutions or what its modifiers make."
    if isinstance(owner, (bpy.types.Curve, bpy.types.Spline)):
        return "Use a lower value, or lower what the curve's modifiers make."
    return "Use a lower value, or lower what the modifiers make."


# --------------------------------------------------------------------------
# The entry points


def _geometry_object(obj):
    """`obj` when its modifiers make a mesh the budget counts, else None. In
    Edit Mode a mesh, curve or surface is written back first: the counts are
    its data's, which Edit Mode holds apart until then. A text is not: its
    Edit Mode buffer is not in its data, and the app keeps texts out of it."""
    if obj is None or obj.type not in COUNTED_TYPES:
        return None
    if obj.mode == 'EDIT' and obj.type not in ('FONT', 'META', 'VOLUME', 'CURVES'):
        obj.update_from_editmode()
    return obj


# Settings a render evaluates in place of the viewport's: priced as rendered.
_RENDER_KEYS = ('render_levels', 'render_steps', 'render_resolution_u', 'render_resolution_v',
                'show_render', 'rendered_child_count')
# The switches that say whether a modifier is shown: their own values decide,
# so they never count their modifier as shown regardless.
_SHOWN_KEYS = ('show_viewport', 'show_render', 'show_in_editmode', 'show_on_cage')


def _renders(changes):
    return any(k in _RENDER_KEYS or (k == 'resolution' and isinstance(o, bpy.types.Modifier)
                                     and o.type == 'OCEAN') for o, k, v in changes)


# A number this large, or not finite, in a change is evaluated before it is
# let through, and refused if Blender's arithmetic would then overflow: round 4's
# fix-round review measured an Array at Count 5 with a Constant Offset of
# (1e38, 0, 0), and Displace at a Strength of 3.4e38, both passed and both
# left vertices at infinite or undefined positions (8 of the Array's).
HUGE = 1e15
# The farthest a vertex may end up from the world's origin, in metres. The
# app squares and sums coordinates in Float (its picking, its bounds), which
# overflows past √(3.4e38 / 3) ≈ 1.06e19 (round 4's second fix-round review);
# REACH is that with a margin of ten.
REACH = 1e18
# Below HUGE a change is evaluated before it is let through when its number
# times the object's reach squared passes this: the modifiers that multiply
# coordinates do so at most by a number times the reach (an Array's copies,
# a Cast's factor) or by a number times the reach squared (a Simple Deform's
# Taper and Stretch, x · (1 + factor · z)), so a change under it cannot take
# a vertex past REACH from within it. Round 4's second fix-round review: an
# Array at Count 1000 with a Constant Offset of 1e14, then three Simple
# Deforms on Taper at 1e14, each passing, left 14,880 coordinates not
# finite; an object's scale of 1e14 on vertices at 2e14 passed with nothing
# checked.
OVERFLOW_CHECK = 1e12


def _huge(value):
    if isinstance(value, (bool, str)) or value is None:
        return False
    if hasattr(value, 'dtype'):
        # A whole collection's values (the gate's change of a mesh's vertices).
        import numpy as np
        return bool(len(value)) and (not bool(np.isfinite(value).all()) or float(np.abs(value).max()) >= HUGE)
    try:
        numbers = [float(v) for v in value] if hasattr(value, '__len__') else [float(value)]
    except (TypeError, ValueError):
        return False
    return any(not math.isfinite(n) or abs(n) >= HUGE for n in numbers)


def _finite_after(obj, s):
    """Raises NonFinite when Blender, with the changes made, would put any of
    `obj`'s vertices at an infinite or undefined position — or where its
    world matrix takes them past float's range."""
    import numpy as np
    stack = _stack(obj, s)
    copy = _materialize(obj, s, stack, len(stack), obj.mode == 'SCULPT')
    evaluated = copy.evaluated_get(_depsgraph())
    mesh = evaluated.to_mesh()
    try:
        n = len(mesh.vertices) if mesh is not None else 0
        if not n:
            return
        co = np.empty(3 * n, dtype=np.float32)
        mesh.vertices.foreach_get('co', co)
        if not np.isfinite(co).all():
            raise NonFinite(obj.name)
        # And within reach of the app's own float arithmetic, which squares
        # and sums coordinates: measured, a Displace at 3.4e38 on a finite
        # cube left its vertices at 1.7e38, finite in Blender and infinite
        # once squared.
        reach = float(np.abs(co).max()) * max(1.0, max(abs(v) for row in _matrix(obj, s) for v in row))
        if not math.isfinite(reach) or reach > REACH:
            raise NonFinite(obj.name)
    finally:
        evaluated.to_mesh_clear()


def _magnitude(value):
    """The largest number in `value` (a number, a vector, a matrix, an
    array), 0 for anything else."""
    if isinstance(value, (bool, str)) or value is None:
        return 0.0
    if hasattr(value, 'dtype'):
        import numpy as np
        return float(np.abs(value).max()) if len(value) else 0.0
    try:
        if hasattr(value, '__len__'):
            return max((_magnitude(v) for v in value), default=0.0)
        number = abs(float(value))
    except (TypeError, ValueError):
        return 0.0
    return number if math.isfinite(number) else float('inf')


def _reach(obj):
    """How far from the world's origin `obj`'s evaluated mesh reaches now:
    its bounds' corners, placed."""
    from mathutils import Vector
    try:
        m = obj.matrix_world
        return max((abs(c) for corner in obj.bound_box for c in (m @ Vector(corner))), default=0.0)
    except (AttributeError, TypeError, ValueError):
        return 0.0


def _could_overflow(obj, s):
    """Whether the changes could carry one of `obj`'s vertices past REACH
    (see OVERFLOW_CHECK)."""
    reach = max(1.0, _reach(obj))
    return s.big * reach * reach >= OVERFLOW_CHECK


def _pricing(changes, render, exact=False):
    """The changes laid over Blender's values for one evaluation, the
    viewport's or a render's (`Prices`); `exact`: values Blender holds
    already, not clamped (`Prices.exact`)."""
    s = Prices(render=render)
    s.exact = exact
    s.finite = True
    s.huge = any(_huge(v) for o, k, v in changes)
    s.big = max((_magnitude(v) for o, k, v in changes), default=0.0)
    for owner, key, value in changes:
        s.change(owner, key, value)
        if isinstance(owner, bpy.types.Modifier) and key not in _SHOWN_KEYS:
            # The setting being priced counts its modifier as shown: a level
            # set on a hidden Subdivision is what showing it will make.
            s.shown.add(_pointer(owner))
    return s


def price_all(changes, change=None, instead=None):
    """THE price: refuses, in words, setting each (owner, key, value) of
    `changes` — any RNA struct, any property — when what Blender would then
    evaluate passes the budget (see `_judge`). Every path the app has for a
    setting comes here, and nothing here lists which settings matter: the
    model reads what it reads, through the changes.

    The viewport's evaluation is always judged, and a change that sets a
    render's own setting is judged as rendered too. Round 4's fix-round
    review: the Subdivision row sends Levels Viewport and Render together,
    and the whole change was priced as a render only — whose 'now' already
    has a new Subdivision's Render level of 2 — so Levels Viewport 1 → 2
    passed at any count (a 500 × 500 grid: 1,002,001 → 4,004,001 in desktop
    5.2.1), and modifiers hidden from renders were not counted at all (two
    Arrays with the camera off, then the row's 1 → 4: 53,248 → 3,149,824)."""
    if not _is_real_blender():
        return
    changes = [(o, k, v) for o, k, v in changes if o is not None]
    if not changes:
        return
    settle()
    for owner, key, value in changes:
        if isinstance(owner, bpy.types.Scene) and key in ('frame_current', 'frame_float') \
                and owner == bpy.context.scene:
            # The frame: what its animation sets there (`price_frame`).
            try:
                price_frame(int(value), float(value) - int(value) if key == 'frame_float' else 0.0)
            except (TypeError, ValueError):
                pass
    # Time Stretching: the frame Blender holds, at its new time.
    _price_stretch(changes)
    # What the drivers that read these values would set once they are
    # written, judged with them (`_readers_of`).
    driven, unread = _readers_of(changes)
    _judge_changes(changes + driven, change, instead)
    # Passed: the gate lets exactly these values through until Blender has
    # evaluated them, so the write that follows is not priced twice — unless a
    # driver reads them that only Blender can work out (`unread`): then the
    # gate prices the write itself, where Blender's own evaluation of it can
    # be read (`probe_values`).
    gate = _gate()
    if gate is not None and not unread:
        gate.approve(changes)


def _readers_of(changes):
    """(owner, property, value) that the drivers reading `changes` would set
    once the changes are written — worked out with the changes' own values
    laid over what the drivers read (`animation_pairs`' `laid`) — and
    whether a driver reads one that only Blender can work out. Fix round 2's
    re-check, sandboxed desktop 5.2.1 with the app's context, budget
    100,000: through the Data API row (`_blenderkit_sync.set_property`) an
    Array's Relative Offset Y read by its own Count driver (x × 2,000 + 1),
    and an empty's Location read by a cube's Count driver, each passed and
    Blender built 160,008; a Wave's Narrowness read by a shape key's Value
    under a fitted Array passed at 159,976. The same writes as a script
    line were refused: the gate works out the drivers that read a change,
    and this price let the write through approved."""
    laid = {}
    inputs = {}
    # As the channels they set: a matrix (an Object Mode move's own price,
    # `price_object_moves`) and Dimensions (`Prices.change`). Fix round 3: a
    # Move of an empty whose X a Count driver reads (x × 40,000 + 2) passed
    # and Blender built 3,200,016 — the move's matrix laid nothing a driver
    # reads.
    normal = Prices()
    normal.exact = True
    try:
        for owner, key, value in changes:
            try:
                normal.change(owner, key, value)
            except (AttributeError, TypeError, ValueError, ReferenceError):
                continue
        changes = [(normal.owners[p], key, value) for (p, key), value in normal.values.items()]
    finally:
        normal.close()
    for owner, key, value in changes:
        try:
            block = owner.id_data if not isinstance(owner, bpy.types.ID) else owner
        except (AttributeError, ReferenceError):
            continue
        if block is None:
            continue
        inputs[_pointer(block)] = block
        try:
            base = owner.path_from_id() if owner != block else ''
        except (ValueError, AttributeError, TypeError, RuntimeError):
            continue
        path = (base + key if key.startswith('[') else base + '.' + key) if base else key
        if hasattr(value, '__len__') and not isinstance(value, str):
            try:
                items = list(value)
            except TypeError:
                continue
            for i, item in enumerate(items):
                if isinstance(item, (int, float)):
                    laid[(_pointer(block), path, i)] = float(item)
        elif isinstance(value, (int, float)):
            laid[(_pointer(block), path, 0)] = float(value)
    if not inputs:
        return [], False
    # What follows a moved object moves too: a driver reading one of its
    # children in World Space reads a change (only Blender can say what).
    stack = [b for b in list(inputs.values()) if isinstance(b, bpy.types.Object)]
    while stack:
        for child in stack.pop().children:
            if _pointer(child) not in inputs:
                inputs[_pointer(child)] = child
                stack.append(child)
    animated = animation_pairs(None, (), list(inputs.values()), laid=laid, probe=False)
    return list(animated.pairs), bool(animated.unknown)


def _judge_changes(changes, change=None, instead=None, s_setup=None, seeds=(), exact=False, reached=None):
    """`price_all`'s judgement, the gate's too: the viewport's evaluation,
    and a render's when a change sets a render's own setting. `s_setup`
    prepares each pricing further (the gate's hidden modifiers and
    constraints, its 'now' for what it could not put back), and `seeds` are
    objects the change reaches besides the owners'. `reached`: the objects
    the changes reach, where the caller knows them already (a frame's plan,
    whose map of who reads whom holds every reader `affected` would find)."""
    for render in ((False, True) if _renders(changes) else (False,)):
        s = _pricing(changes, render, exact)
        try:
            if s_setup is not None:
                s_setup(s)
            if not render:
                _sculpt_levels(changes, s)
            if reached is None:
                reached_now = affected([o for o, k, v in changes] + list(seeds), s)
            else:
                reached_now = reached
            objects = [_geometry_object(o) for o in reached_now]
            objects = [o for o in objects if o is not None]
            if not objects:
                return
            if changes:
                owner, key, value = changes[0]
                # The value as RNA would hold it (clamped), or as typed where the
                # change is carried by others (Dimensions as a Scale).
                label = change or _label(owner, key, s.values.get((_pointer(owner), key), value))
                words = instead or _instead(owner, key, value)
            else:
                label, words = change or "This change", instead or "Use a lower value, or lower what the modifiers make."
            _judge(objects, s, label, words)
        finally:
            s.close()


def _item_readers(struct):
    """For items added to or taken from a struct of a data-block that is not
    an object — a texture's colour ramp given a stop — which no value puts
    back: what reads that data-block, priced as it is (`price_state`). Fix
    round 3 (October 29), sandboxed desktop 5.2.1: a stop of grey 0.25 added
    by a script line to the colour ramp of a Blend texture a cube's Displace
    reads, under an Array fitted to 40, passed and Blender built 168 ->
    3,199,472; nothing reached the cube."""
    reader = Prices()
    try:
        return affected([struct.item], reader)
    except (AttributeError, ReferenceError):
        return []
    finally:
        reader.close()


def price_state(changes, stuck, structs, hidden, disabled, title=None, animated=None):
    """The gate's price (_blenderkit_gate): the state Blender would evaluate
    next, laid over what it evaluated last. `changes` are the gate's
    `Change`s it has put back (each priced at its new value), `stuck` those
    that would not go back, `structs` what no value can put back (a modifier
    or constraint added — hidden or turned off for the price, `hidden` and
    `disabled` — or removed, the modifiers' order, a new object, a mesh, a
    curve or a metaball given other elements). Returns the refusal's words,
    or None when it passes. Whatever the price hides for its own evaluations
    is shown again, except, refused, what would otherwise evaluate past the
    budget, which the words name. `animated` (`animation_pairs`): what the
    animation sets once Blender evaluates the state, priced with it."""
    if not _is_real_blender():
        return None
    pairs = []
    for c in changes:
        if isinstance(c.owner, bpy.types.Scene) and c.key in ('frame_current', 'frame_subframe'):
            # The frame itself is no setting the model reads: what the
            # animation sets there is (`animated`).
            continue
        pairs.append((c.owner, c.key, c.new))
    reached = None
    if animated is not None and animated.pairs:
        if not pairs and not structs and not stuck:
            reached = animated.reached
        pairs.extend(animated.pairs)
        if title is None and animated.label and len(pairs) == len(animated.pairs):
            title = animated.label
    if not pairs and not structs and not stuck:
        return None
    seeds = []
    shown_again = []       # (modifier, value) hidden by this price, to show again
    strict = set()         # objects 'now' is Blender's count for
    stand_over = []        # objects whose own new state is past the budget
    notes = []

    evaluated = []

    def users_of(block):
        found = [o for o in bpy.data.objects if o.data == block]
        if not found or not structs:
            return found
        # Only those Blender will evaluate: an object this price took out of
        # the scene (below) still holds its grown data, which the depsgraph
        # lists as changed until it next rebuilds, and the mirror's pass
        # priced it again, refused it again, and said so without saying it
        # was taken out (fix round 3, October 29).
        try:
            layer = {o.as_pointer() for o in bpy.context.view_layer.objects}
        except (AttributeError, ReferenceError):
            return found
        if all(o.as_pointer() in layer for o in found):
            return found
        if not evaluated:
            gate = _gate()
            reads = gate._dependencies(list(bpy.context.view_layer.objects)) if gate is not None else []
            evaluated.append({o.as_pointer() for o in reads} | layer)
        return [o for o in found if o.as_pointer() in evaluated[0]]

    for s in structs:
        if s.kind == 'new':
            seeds.append(s.obj)
            strict.add(s.obj)
        elif s.kind in ('grown', 'edited'):
            # Given other elements by a script (`grown`), or an edited mesh a
            # script changed in Edit Mode (`edited`, `_blenderkit_gate`):
            # priced as it is, against what Blender holds.
            for o in users_of(s.data):
                seeds.append(o)
                strict.add(o)
        elif s.kind == 'image':
            # An image its modifiers read, changed by a script or an operator
            # with nothing tagged (the gate's `_images_touched`): priced as
            # it is, against what Blender holds.
            seeds.append(s.obj)
            strict.add(s.obj)
        elif s.kind == 'nodes':
            # A node group given other nodes or links: what runs it, priced
            # as it is.
            for o in tree_users(s.data):
                seeds.append(o)
                strict.add(o)
        elif s.kind == 'items' and s.obj is None and s.item is not None:
            for o in _item_readers(s):
                seeds.append(o)
                strict.add(o)
        elif s.obj is not None:
            seeds.append(s.obj)
            if s.kind.endswith('_removed') or s.kind.endswith('_order'):
                strict.add(s.obj)
    for c in stuck:
        try:
            block = c.owner.id_data
        except (AttributeError, ReferenceError):
            continue
        if isinstance(block, bpy.types.Object):
            seeds.append(block)
            strict.add(block)
        else:
            for o in users_of(block):
                seeds.append(o)
                strict.add(o)
    # 'Now' for what could not be put back: what Blender evaluated last, read
    # before anything evaluates again.
    now = {_pointer(o): _held_count(o) for o in strict}
    # What could not be put back, and everything that reads it, is priced
    # with its modifiers hidden, so the price's own evaluations stay within
    # what Blender holds; the price counts them as shown.
    probe = Prices()
    try:
        reach = affected(list(strict), probe) if strict else []
    finally:
        probe.close()
    for o in set(reach) | strict:
        for m in getattr(o, 'modifiers', ()):
            if m.show_viewport:
                shown_again.append((m, True))
                m.show_viewport = False

    def setup(s):
        for m, _ in hidden:
            s.change(m, 'show_viewport', True)
        for m, _ in shown_again:
            s.change(m, 'show_viewport', True)
        for c, _ in disabled:
            s.change(c, 'enabled', True)
        s.was.update(now)

    # A new object's or a grown one's own data first, by the bound alone,
    # before anything of it is evaluated (a curve built, a family polygonized).
    for o in strict:
        if o.type in ('CURVE', 'SURFACE', 'FONT', 'META'):
            bound = Prices()
            try:
                base = _base(o, bound) if o.type != 'META' else _meta_base(o, bound)
            except Unpriceable:
                base = Counts(BUDGET * 1000, 0, 0, 0, False)
            finally:
                bound.close()
            if _over(base.v):
                stand_over.append(o)
    label = title
    if label is None and changes:
        label = _gate_label(changes[0])
    elif label is None and structs:
        label = _struct_label(structs[0])
    refusal = None
    if stand_over:
        o = stand_over[0]
        refusal = ("%s would give %s more vertices than this app's %s before its modifiers are counted, so "
                   "it does not run out of memory." % (label or "This change", o.name, format(BUDGET, ',')))
    else:
        try:
            # The values as Blender holds them, which an operator can have
            # written past RNA's range (`Prices.exact`).
            _judge_changes(pairs, label, None, setup, seeds, exact=True, reached=reached)
        except RuntimeError as error:
            refusal = str(error)
    if refusal is None:
        for m, value in shown_again:
            m.show_viewport = value
        return None
    # Refused. What the gate put back is as Blender evaluated it. What it
    # could not put back stays hidden or out of the scene.
    kept = []
    for m, value in shown_again:
        o = m.id_data
        if o in strict or o in reach:
            kept.append(m)
            continue
        m.show_viewport = value
    stand_over.extend(_left_over(strict, stand_over, now, label))
    for o in stand_over:
        for collection in list(o.users_collection):
            if o.name in collection.objects:
                collection.objects.unlink(o)
        notes.append("%s was taken out of the scene (it is still in bpy.data.objects)" % o.name)
    names = sorted({m.id_data.name for m in kept})
    if names:
        notes.append("the modifiers of %s are hidden in the viewport until it is lighter"
                     % ", ".join(names))
    for s in structs:
        if s.kind == 'modifier_added':
            notes.append("the new %s stays hidden" % s.item.name)
        elif s.kind in ('constraint_added', 'bone_constraint_added'):
            notes.append("the new %s stays off" % s.item.name)
        elif s.kind == 'items':
            holder = s.item if isinstance(s.item, (bpy.types.Constraint, bpy.types.Modifier)) \
                else _constraint_of(s.item)[0]
            if isinstance(holder, bpy.types.Constraint):
                notes.append("%s stays off" % holder.name)
            elif isinstance(holder, bpy.types.Modifier):
                notes.append("%s stays hidden" % holder.name)
        elif s.kind == 'keys':
            notes.append("the animation it came from is muted")
    if notes:
        refusal = refusal.rstrip() + " Blender kept the change it could not take back, so " + "; ".join(notes) + "."
    return refusal


def _left_over(strict, stand_over, now, label):
    """What a refusal leaves, priced as Blender will evaluate it next: each of
    `strict` (the objects whose own state could not be put back), with its
    modifiers hidden as they now are, against what Blender holds (`now`).
    Returns those still past the budget, or too slow, to take out of the
    scene. Fix round 3 (October 29), desktop 5.2.1 with the app's context,
    the budget lowered to 100,000: a script line's `vertices.add(160000)` and
    `update()` on a cube with no modifier was refused in words, but nothing
    could be hidden, the cube stayed in the scene at 160,008 vertices, and a
    later move passed (an object already past the budget can be changed in
    ways that do not make it heavier). A metaball family refused for its
    polygonizing time alone stayed the same way (round 4's fix round 2
    check: a later move built 201,816 vertices in 1.88 s). Such an object is
    taken out of the scene, as a curve or a text over the budget before its
    modifiers already was (`stand_over`)."""
    out = []
    for o in strict:
        try:
            if o in stand_over or o.name not in bpy.context.scene.objects or o.mode != 'OBJECT':
                continue          # another mode's own transaction holds it
        except (AttributeError, ReferenceError):
            continue
        left = Prices()
        try:
            left.was.update(now)
            _judge([o], left, label or "This change", "Use fewer elements.")
        except RuntimeError:
            out.append(o)
        finally:
            left.close()
    return out


def _gate_label(c):
    """Words for a change the gate prices, as the banner shows them."""
    if c.key.startswith('#'):
        what = getattr(c.owner, 'name', '') or getattr(c.owner.id_data, 'name', '')
        path = c.key[1:].split('.')[0]
        try:
            # Blender's own name for the collection ("Bézier Points", "Vertices").
            words = c.owner.bl_rna.properties[path].name or path.replace('_', ' ')
        except (AttributeError, KeyError, TypeError):
            words = path.replace('_', ' ')
        return "Moving %s's %s" % (what, words)
    value = c.new
    try:
        return _label(c.owner, c.key, value)
    except Exception:                                    # noqa: BLE001 - words only
        return "Setting %s" % c.key


def _struct_label(s):
    if s.kind == 'new':
        return "Adding %s to the scene" % s.obj.name
    if s.kind == 'edited':
        users = [o.name for o in bpy.data.objects if o.data == s.data]
        return "Editing %s's mesh in Edit Mode" % (", ".join(users) or s.data.name)
    if s.kind == 'grown':
        users = [o.name for o in bpy.data.objects if o.data == s.data]
        return "%s's %s, now with %s," % (", ".join(users) or s.data.name,
                                         'mesh' if isinstance(s.data, bpy.types.Mesh) else 'data', s.note)
    if s.kind == 'modifier_added':
        return "Adding the %s modifier to %s" % (s.item.name, s.obj.name)
    if s.kind in ('constraint_added', 'bone_constraint_added'):
        return "Adding the %s constraint to %s" % (s.item.name, s.obj.name)
    if s.kind.endswith('_removed'):
        return "Removing %s from %s" % (getattr(s.data, 'name', 'a modifier'), s.obj.name)
    if s.kind.endswith('_order'):
        return "The new order of %s's %s" % (s.obj.name, s.kind.split('_')[0] + 's')
    if s.kind == 'items':
        return "Changing %s's %s" % (getattr(s.item, 'name', '') or getattr(s.obj, 'name', 'a setting'), s.note[4:])
    if s.kind == 'keys':
        return "Changing %s's animation" % getattr(s.data, 'name', 'an action')
    if s.kind == 'nodes':
        return "The node group %s, now with %s," % (getattr(s.data, 'name', ''), s.note)
    if s.kind == 'image':
        return "The image %s, which %s's %s reads, as it is now," % (s.note, s.obj.name,
                                                                    getattr(s.item, 'name', 'modifier'))
    return "This change"


def price(owner, key, value, change=None, instead=None):
    """`price_all` for one property: the line every row sends in front of its
    assignment (`PointsBpy.set`), and the Data API row's
    (`_blenderkit_sync.set_property`)."""
    price_all([(owner, key, value)], change, instead)


def price_modifier(name, settings, obj=None):
    """A modifier row's edit (`Bpy.modifierEdit`): every setting it sends,
    priced together, on the active object's modifier `name`."""
    if not _is_real_blender():
        return
    obj = obj if obj is not None else bpy.context.object
    if obj is None:
        return
    modifier = obj.modifiers.get(name)
    if modifier is None:
        return
    price_all([(modifier, key, value) for key, value in settings.items()])


def _sculpt_levels(changes, s):
    """In Sculpt Mode a Multires change that leaves a level sculpted is also
    held to Sculpt Mode's base-mesh budget (`refuse_heavy_level`): the Sculpt
    level stepper (round 3's review), and the eye switch and Sculpt Base Mesh
    off, which round 4's review found going round it (an 8,066-vertex base,
    Multires 1/1/1, entered hidden and then shown)."""
    for owner, key, value in changes:
        if not isinstance(owner, bpy.types.Modifier) or owner.type != 'MULTIRES':
            continue
        if key not in ('sculpt_levels', 'show_viewport', 'use_sculpt_base_mesh'):
            continue
        obj = owner.id_data
        if obj.mode != 'SCULPT':
            continue
        level = min(int(s.get(owner, 'sculpt_levels')), owner.total_levels)
        if not s.get(owner, 'show_viewport') or s.get(owner, 'use_sculpt_base_mesh'):
            continue
        _sibling('_blenderkit_sculpt').refuse_heavy_level(obj, level, "Multires Sculpt level %d" % level)


def price_add(kind, obj=None, settings=None, objects=None):
    """Add Modifier ▸ `kind` (the panel's rows, and the search's
    `object.modifier_add`), priced on each object it would be added to before
    anything is added, at Blender's defaults for the kind — or `settings`,
    which the row sets in the same evaluation (Remesh's voxel floor). Skin on
    more loops of edges than it finishes in reasonable time is refused too."""
    if not _is_real_blender():
        return
    targets = objects if objects is not None else [obj if obj is not None else bpy.context.object]
    for target in targets:
        target = _geometry_object(target)
        if target is None:
            continue
        s = Prices()
        try:
            virtual = Virtual(kind, settings=settings)
            s.added[_pointer(target)] = [('new', virtual)]
            label = "Add Modifier ▸ " + _ADD_LABELS.get(kind, kind.replace('_', ' ').title())
            if kind == 'SKIN':
                w = _final(target, s)
                loops = next((c.e - c.v + 1 for m, c in w.steps if m is virtual), 0)
                if loops > SKIN_MAX_LOOPS:
                    raise RuntimeError(_skin_refusal(target, loops))
            _judge([target] + [o for o in affected([target], s) if o != target], s, label,
                   "Add it to a lighter mesh, or lower what the modifiers above it make.")
        finally:
            s.close()


# Add ▸ Mesh's primitives: the vertices each makes from its own settings,
# measured in desktop 5.2.1 (a UV sphere of 5 segments and 4 rings, 17; an
# Ico Sphere at 1, 2 and 5, 12, 42 and 2,562; a grid of 3 x 5 subdivisions, 24;
# a cylinder of 9 with Triangle Fan caps, 20; a cone of 9 to a point, 10, with
# a Triangle Fan base 11, and with a top radius 18 and 20, the cylinder's).
# RNA lets a typed value take them far past the budget — Segments and Rings
# to 100,000 (10^10 vertices), a grid's subdivisions to 10,000,000, a
# circle's, cylinder's and cone's Vertices to 10,000,000, an Ico Sphere's
# Subdivisions to 10 (2,621,442) — through the Adjust Last Operation panel,
# the Operator Search and a script line alike.
_PRIMITIVES = {
    'primitive_plane_add': lambda p: 4,
    'primitive_cube_add': lambda p: 8,
    'primitive_cube_add_gizmo': lambda p: 8,
    'primitive_monkey_add': lambda p: 507,
    'primitive_circle_add': lambda p: p('vertices') + (1 if p('fill_type') == 'TRIFAN' else 0),
    'primitive_uv_sphere_add': lambda p: p('segments') * (p('ring_count') - 1) + 2,
    'primitive_ico_sphere_add': lambda p: 10 * 4 ** (p('subdivisions') - 1) + 2,
    'primitive_cylinder_add': lambda p: 2 * p('vertices') + (2 if p('end_fill_type') == 'TRIFAN' else 0),
    'primitive_cone_add': lambda p: 2 * p('vertices') + 2,
    'primitive_torus_add': lambda p: p('major_segments') * p('minor_segments'),
    'primitive_grid_add': lambda p: (p('x_subdivisions') + 1) * (p('y_subdivisions') + 1),
}
# The settings each one's count reads, for the refusal's words.
_PRIMITIVE_KEYS = {
    'primitive_circle_add': ('vertices',), 'primitive_uv_sphere_add': ('segments', 'ring_count'),
    'primitive_ico_sphere_add': ('subdivisions',), 'primitive_cylinder_add': ('vertices',),
    'primitive_cone_add': ('vertices',), 'primitive_torus_add': ('major_segments', 'minor_segments'),
    'primitive_grid_add': ('x_subdivisions', 'y_subdivisions'),
}


# The most sides an N-Gon fill of Add ▸ Circle, Cylinder or Cone may have, for
# time: Blender's fill grows far faster than its sides (desktop 5.2.1, a Mac:
# a circle's 2,000-gon 0.08 s, 4,000 0.33 s, 8,000 1.8 s, 16,000 4.6 s; a
# cylinder's two caps 0.25 s at 2,000, 0.67 s at 3,000, 4.5 s at 4,000; a
# cone's 0.14 s at 2,000, 2.3 s at 4,000), and a cylinder of 1,000,000 had
# not finished after 30 minutes — found by this fix round's own check, the
# budget's 2,000,000 vertices letting it through. Triangle Fan and Nothing
# stay linear (a cylinder of 1,000,000 with no caps in 0.95 s).
NGON_SIDES = 2000
_NGON_FILL = {'primitive_circle_add': 'fill_type', 'primitive_cylinder_add': 'end_fill_type',
              'primitive_cone_add': 'end_fill_type'}


def primitive_vertices(operator, name, keywords):
    """The vertices `bpy.ops.mesh.<name>(**keywords)` would make, each setting
    left out at its RNA default and a number held to its hard range as RNA
    holds it; None for a value Blender itself will refuse (a float for an
    int), or a name the model has no count for."""
    count = _PRIMITIVES.get(name)
    if count is None:
        return None
    properties = operator.get_rna_type().properties

    def p(key):
        prop = properties[key]
        value = keywords.get(key, prop.default)
        if prop.type == 'INT':
            # Whatever RNA takes as an int (anything with __index__: a numpy
            # integer too); a float raises TypeError there, and here.
            import operator as _operator
            return min(max(_operator.index(value), prop.hard_min), prop.hard_max)
        return value

    try:
        return int(count(p))
    except (TypeError, KeyError, ValueError):
        return None


def price_primitive(operator, name, keywords):
    """Add ▸ Mesh ▸ `name` priced before Blender makes it: refused, in words,
    when the primitive alone would pass the budget or the memory left — or, in
    a mesh's Edit Mode, where Blender adds it into the edited mesh, when that
    mesh's whole stack would then (counted with the primitive's vertices on
    top of the mesh's, and edges, faces and corners at most 2.25, 1.5 and 4.5
    per vertex, the most the primitives measured make: a Triangle Fan
    cylinder's 2.25, 1.35 and 4.5). `_blenderkit_context` calls it from every
    `bpy.ops.mesh.primitive_*` it hands out."""
    if not _is_real_blender():
        return
    made = primitive_vertices(operator, name, keywords)
    if made is None:
        return
    try:
        label = operator.get_rna_type().name or name
        properties = operator.get_rna_type().properties
        settings = ", ".join("%s %s" % (properties[k].name, format(int(keywords.get(k, properties[k].default)), ','))
                             for k in _PRIMITIVE_KEYS.get(name, ()))
    except (KeyError, TypeError, ValueError, AttributeError):
        label, settings = name, ""
    change = label + (" with " + settings if settings else "")
    fill = _NGON_FILL.get(name)
    if fill is not None:
        try:
            properties = operator.get_rna_type().properties
            sides = int(keywords.get('vertices', properties['vertices'].default))
            ngon = keywords.get(fill, properties[fill].default) == 'NGON'
        except (KeyError, TypeError, ValueError):
            sides, ngon = 0, False
        if ngon and sides > NGON_SIDES:
            raise RuntimeError(
                "%s would fill with an N-Gon of %s sides, and Blender's N-Gon fill takes minutes on that "
                "many, with the app frozen meanwhile (measured on a desktop Mac: 2,000 sides 0.2 s, "
                "4,000 up to 4.5 s, 1,000,000 not done in 30 minutes). Use Triangle Fan or Nothing, or "
                "at most %s vertices." % (change, format(sides, ','), format(NGON_SIDES, ',')))
    instead = "Use fewer segments, rings, vertices or subdivisions."
    if made > BUDGET:
        raise RuntimeError(
            "%s would make %s vertices, and this app stops at %s so it does not run out of memory. %s"
            % (change, format(made, ','), format(BUDGET, ','), instead))
    free = available_memory()
    if free is not None and made * PEAK_BYTES_PER_VERTEX > free:
        raise RuntimeError(
            "%s would make %s vertices, which needs about %.1f GB of memory, and %.1f GB is free. "
            "Close other apps, or %s" % (change, format(made, ','), made * PEAK_BYTES_PER_VERTEX / 1e9,
                                         free / 1e9, instead[0].lower() + instead[1:]))
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if obj is None or obj.type != 'MESH' or obj.mode != 'EDIT':
        return
    obj = _geometry_object(obj)
    mesh = obj.data
    edges = len(mesh.edges)
    base = (len(mesh.vertices) + made, edges + math.ceil(2.25 * made), len(mesh.polygons) + math.ceil(1.5 * made),
            len(mesh.loops) + math.ceil(4.5 * made))
    count = stack_vertices(obj, base=base)
    refuse_count(obj, count, change + " in Edit Mode", instead,
                 " once its modifiers are counted" if obj.modifiers else "")


def price_copy(name, objects):
    """The search's Copy (`object.modifier_copy`): a copy of `name` right after
    it, on each of `objects` that has one."""
    if not _is_real_blender():
        return
    for obj in objects:
        obj = _geometry_object(obj)
        if obj is None or obj.modifiers.get(name) is None:
            continue
        s = Prices()
        try:
            original = obj.modifiers[name]
            s.added[_pointer(obj)] = [(name, Virtual(original.type, name=name + ".copy", like=original))]
            _judge([obj] + [o for o in affected([obj], s) if o != obj], s, "Copying " + name,
                   "Lower what it makes first.")
        finally:
            s.close()


def price_copy_to_selected(source, name, objects):
    """The search's Copy to Selected: `source`'s modifier `name` added last on
    each of the other `objects`."""
    if not _is_real_blender():
        return
    original = source.modifiers.get(name) if source is not None else None
    if original is None:
        return
    for obj in objects:
        obj = _geometry_object(obj)
        if obj is None or obj == source:
            continue
        s = Prices()
        try:
            s.added[_pointer(obj)] = [('last', Virtual(original.type, name=name, like=original))]
            _judge([obj] + [o for o in affected([obj], s) if o != obj], s,
                   "Copying %s to %s" % (name, obj.name), "Lower what it makes first.")
        finally:
            s.close()


# --------------------------------------------------------------------------
# Operators that rebuild an object's base, or give it another's data or
# modifiers, priced through its whole stack before Blender runs them.
# `_blenderkit_context` hands each one in PRICED_OPERATORS out wrapped, so the
# Object menu's rows, the Edit Mode panels, the Operator Search and a script
# line all reach the price (`price_operator`). Round 4's fix-round review
# measured each with the app's own strings in desktop 5.2.1, and none had a
# price: Copy Modifiers to Selected Objects, Copy Modifiers and Link Object
# Data from a cube under Subdivision 4 to a 120 × 120 grid gave 3,690,241, a
# Join 3,691,779; Edit Mode Subdivide at 10 cuts on a cube under Subdivision 6
# 2,973,698; the curve Edit Mode's Subdivide twice under two Arrays of 64
# 9,863,168; Apply ▸ Scale of an Array fitted to 100 m at a scale of 0.0001,
# 408 → 4,000,008; QuadriFlow at 40,000 faces under Subdivision 3 2,553,282;
# Voxel Remesh priced on its base alone under Subdivision 3, 3,917,186.


def price_base(obj, base, change, instead):
    """Refuses, in words, a change that leaves `obj`'s own mesh with `base`
    (vertices, edges, faces, corners — exact or an upper bound) when its whole
    stack would then pass the budget (`_judge`)."""
    if not _is_real_blender():
        return
    obj = _geometry_object(obj)
    if obj is None:
        return
    s = Prices()
    try:
        s.bases[_pointer(obj)] = tuple(int(n) for n in base)
        _judge([obj] + [o for o in affected([obj], s) if o != obj], s, change, instead)
    finally:
        s.close()


def _selected_others(active, types=None):
    others = []
    for o in getattr(bpy.context, 'selected_editable_objects', None) or ():
        if o == active or (types is not None and o.type not in types):
            continue
        others.append(o)
    return others


def _mesh_arrays(mesh, matrix=None):
    import numpy as np
    v, e, c, f = len(mesh.vertices), len(mesh.edges), len(mesh.loops), len(mesh.polygons)
    co = np.empty(3 * v, dtype=np.float32)
    ends = np.empty(2 * e, dtype=np.int32)
    corner_verts = np.empty(c, dtype=np.int32)
    corner_edges = np.empty(c, dtype=np.int32)
    starts = np.empty(f, dtype=np.int32)
    for array, (collection, name) in ((co, (mesh.vertices, 'co')), (ends, (mesh.edges, 'vertices')),
                                      (corner_verts, (mesh.loops, 'vertex_index')),
                                      (corner_edges, (mesh.loops, 'edge_index')),
                                      (starts, (mesh.polygons, 'loop_start'))):
        if len(array):
            collection.foreach_get(name, array)
    co = co.reshape(-1, 3).astype(np.float64)
    if matrix is not None and v:
        m = np.array(matrix, dtype=np.float64)
        co = co @ m[:3, :3].T + m[:3, 3]
    return co, ends, corner_verts, corner_edges, starts


def _joined_mesh(active, others):
    """The mesh Join makes of `others` into `active`: their meshes in
    `active`'s space, after its own (ED_mesh_join; attributes left out)."""
    import numpy as np
    inverse = active.matrix_world.inverted_safe()
    parts = [_mesh_arrays(active.data)] + [_mesh_arrays(o.data, inverse @ o.matrix_world) for o in others]
    cos, ends, verts, edges, starts = [], [], [], [], []
    v = e = c = 0
    for co, end, cv, ce, st in parts:
        cos.append(co)
        ends.append(end + v)
        verts.append(cv + v)
        edges.append(ce + e)
        starts.append(st + c)
        v += len(co)
        e += len(end) // 2
        c += len(cv)
    mesh = bpy.data.meshes.new("Blender Local join")
    mesh.vertices.add(v)
    mesh.edges.add(e)
    mesh.loops.add(c)
    f = sum(len(st) for st in starts)
    mesh.polygons.add(f)
    if v:
        mesh.vertices.foreach_set('co', np.concatenate(cos).astype(np.float32).ravel())
    if e:
        mesh.edges.foreach_set('vertices', np.concatenate(ends).astype(np.int32))
    if c:
        mesh.loops.foreach_set('vertex_index', np.concatenate(verts).astype(np.int32))
        mesh.loops.foreach_set('edge_index', np.concatenate(edges).astype(np.int32))
    if f:
        mesh.polygons.foreach_set('loop_start', np.concatenate(starts).astype(np.int32))
    mesh.update()
    return mesh


def price_join():
    """Object ▸ Join: the selected meshes (or curves, or surfaces) joined into
    the active one, under the active one's modifiers, the others' left out
    as Join leaves them (ED_mesh_join, ED_curve_join_objects_exec)."""
    if not _is_real_blender():
        return
    active = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if active is None or active.type not in ('MESH', 'CURVE', 'SURFACE'):
        return
    others = [_geometry_object(o) for o in _selected_others(active, (active.type,))]
    others = [o for o in others if o is not None and o.data is not None]
    if not others:
        return
    active = _geometry_object(active)
    instead = "Join fewer objects, or lower what %s's modifiers make." % active.name
    s = Prices()
    try:
        if active.type == 'MESH':
            total = len(active.data.vertices) + sum(len(o.data.vertices) for o in others)
            refuse_count(active, total, "Join", instead, " before its modifiers")
            joined = _joined_mesh(active, others)
            s._meshes.append(joined)
            s.change(active, 'data', joined)
            s.synthetic.add(_pointer(active))
        elif active.type == 'SURFACE':
            # A surface has no Bevel or Extrude for a patch to take: each makes
            # what it made.
            base = Counts(0, 0, 0, 0)
            for o in [active] + others:
                base = base.plus(_base(o, s))
            s.bases[_pointer(active)] = base.tuple()
        else:
            # Join moves every spline into the active curve's data, where they
            # take its Bevel, Extrude, Profile and Fill (ED_curve_join_objects_exec):
            # round 4's second fix-round review joined a wire Bézier of 257
            # points (3,073 vertices of its own) into a curve with Bevel Depth
            # 0.05 under an Array of 40 (18,720) and Blender made 4,443,840,
            # where each curve's own base summed had passed. So the join is
            # built: the active curve's data with every spline in its space.
            joined = _joined_curve(active, others)
            s._curves.append(joined)
            s.change(active, 'data', joined)
            s.synthetic.add(_pointer(active))
        _judge([active] + [o for o in affected([active], s) if o != active], s, "Join", instead)
    finally:
        s.close()


# A spline's own settings Join keeps, and a point's.
_SPLINE_KEYS = ('resolution_u', 'resolution_v', 'order_u', 'order_v', 'use_cyclic_u', 'use_cyclic_v',
                'use_endpoint_u', 'use_endpoint_v', 'use_bezier_u', 'use_bezier_v', 'use_smooth', 'tilt_interpolation',
                'radius_interpolation', 'material_index')


def _joined_curve(active, others):
    """A copy of `active`'s curve data with every spline of `others` added,
    in `active`'s space, as Join leaves it — points, handles, radii, tilts
    and each spline's own settings."""
    joined = active.data.copy()
    inverse = active.matrix_world.inverted_safe()
    for other in others:
        m = inverse @ other.matrix_world
        for spline in other.data.splines:
            made = joined.splines.new(spline.type)
            for key in _SPLINE_KEYS:
                try:
                    setattr(made, key, getattr(spline, key))
                except (AttributeError, TypeError, ValueError):
                    pass
            if spline.type == 'BEZIER':
                points = spline.bezier_points
                made.bezier_points.add(len(points) - 1)
                for a, b in zip(points, made.bezier_points):
                    b.co = m @ a.co
                    b.handle_left_type, b.handle_right_type = a.handle_left_type, a.handle_right_type
                    b.handle_left = m @ a.handle_left
                    b.handle_right = m @ a.handle_right
                    b.radius, b.tilt = a.radius, a.tilt
            else:
                points = spline.points
                made.points.add(len(points) - 1)
                for a, b in zip(points, made.points):
                    xyz = m @ a.co.xyz
                    b.co = (xyz.x, xyz.y, xyz.z, a.co.w)
                    b.radius, b.tilt = a.radius, a.tilt
    return joined


def price_link_data(kind):
    """Object ▸ Link/Transfer Data ▸ `kind` from the active object to the
    other selected ones: Link Object Data gives each the active one's data
    under its own modifiers, Copy Modifiers replaces each one's modifiers with
    the active one's (BKE_object_link_modifiers, measured: a Mirror replaced
    by the active one's Subdivision and Array), Link Fonts a text's fonts.
    The rest (materials, animation, collections, instancing, effects) change
    no mesh."""
    if not _is_real_blender():
        return
    active = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if active is None:
        return
    if kind == 'OBDATA':
        targets = [o for o in _selected_others(active) if o.type == active.type and o.type in GEOMETRY_TYPES]
        changes = [(o, 'data', active.data) for o in targets]
        label = "Link Object Data"
    elif kind == 'MODIFIERS':
        targets = [o for o in _selected_others(active) if o.type in GEOMETRY_TYPES]
        label = "Copy Modifiers"
        for o in targets:
            o = _geometry_object(o)
            s = Prices()
            try:
                s.orders[_pointer(o)] = []
                s.added[_pointer(o)] = [('last', Virtual(m.type, name=m.name, like=m)) for m in active.modifiers]
                _judge([o] + [x for x in affected([o], s) if x != o], s, "%s to %s" % (label, o.name),
                       "Lower what %s's modifiers make first." % active.name)
            finally:
                s.close()
        return
    elif kind == 'FONTS' and active.type == 'FONT':
        changes = []
        for o in _selected_others(active, ('FONT',)):
            for key in ('font', 'font_bold', 'font_italic', 'font_bold_italic'):
                changes.append((o.data, key, getattr(active.data, key)))
        label = "Link Fonts to Text"
    else:
        return
    if changes:
        price_all(changes, label, "Lower what the other objects' modifiers make first, or link fewer objects.")


def price_modifiers_copy_to_selected():
    """Object ▸ Modifiers ▸ Copy Modifiers to Selected Objects: every modifier
    of the active object added after each other selected one's own, ahead of
    any pinned to last (measured: a Mirror kept, the Subdivision and Array
    after it, a pinned Weld still last)."""
    if not _is_real_blender():
        return
    active = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if active is None or not active.modifiers:
        return
    for o in _selected_others(active):
        o = _geometry_object(o)
        if o is None:
            continue
        s = Prices()
        try:
            s.added[_pointer(o)] = [('last', Virtual(m.type, name=m.name, like=m)) for m in active.modifiers]
            _judge([o] + [x for x in affected([o], s) if x != o], s,
                   "Copy Modifiers to Selected Objects, on %s" % o.name,
                   "Lower what %s's modifiers make first." % active.name)
        finally:
            s.close()


def _apply_matrix(obj, location, rotation, scale):
    """The part of `obj`'s own channels Apply moves into its data: the basis
    with what is not applied left out (deltas included, as Apply resets them:
    measured, a scale of 2 with a delta of 3 applied to a 6 m cube)."""
    from mathutils import Matrix
    loc, rot, sca = obj.matrix_basis.decompose()
    m = Matrix.Identity(4)
    if location:
        m = Matrix.Translation(loc) @ m
    r = rot.to_matrix().to_4x4() if rotation else Matrix.Identity(4)
    sc = Matrix.Diagonal(tuple(sca) + (1.0,)) if scale else Matrix.Identity(4)
    return m @ r @ sc


def price_transform_apply(location=True, rotation=True, scale=True, properties=True, **_):
    """Object ▸ Apply ▸ Location, Rotation, Scale and their mixes, on each
    selected object: its data moved by what is applied, its channels reset,
    and every object parented to it left where it is. An Array fitted to a
    length counts from the mesh's own size, which an applied scale changes
    (round 4's fix-round review: 408 → 4,000,008 at a scale of 0.0001)."""
    if not _is_real_blender() or not (location or rotation or scale):
        return
    for obj in list(getattr(bpy.context, 'selected_editable_objects', None) or ()):
        if obj.type not in ('MESH', 'CURVE', 'SURFACE', 'FONT'):
            continue
        obj = _geometry_object(obj)
        matrix = _apply_matrix(obj, location, rotation, scale)
        s = Prices()
        try:
            data = obj.data
            if obj.type == 'FONT':
                # A text's size and depths are scaled instead (measured: a
                # Size of 1 at scale 3 became 3; at 2, 5, 1 it became 9.487,
                # mat3_to_scale's length of the diagonal over √3).
                from mathutils import Vector
                factor = (matrix.to_3x3() @ Vector((1.0, 1.0, 1.0))).length / math.sqrt(3.0)
                if properties and scale:
                    for key in ('size', 'extrude', 'bevel_depth', 'offset'):
                        value = getattr(data, key, 0.0)
                        if value:
                            s.change(data, key, value * factor)
            else:
                copy = data.copy()
                if obj.type == 'MESH':
                    s._meshes.append(copy)
                else:
                    s._curves.append(copy)
                copy.transform(matrix)
                s.change(obj, 'data', copy)
            if location:
                s.change(obj, 'location', (0.0, 0.0, 0.0))
                s.change(obj, 'delta_location', (0.0, 0.0, 0.0))
            if rotation:
                s.change(obj, 'rotation_euler', (0.0, 0.0, 0.0))
                s.change(obj, 'rotation_quaternion', (1.0, 0.0, 0.0, 0.0))
                s.change(obj, 'rotation_axis_angle', (0.0, 0.0, 1.0, 0.0))
                s.change(obj, 'delta_rotation_euler', (0.0, 0.0, 0.0))
                s.change(obj, 'delta_rotation_quaternion', (1.0, 0.0, 0.0, 0.0))
            if scale:
                s.change(obj, 'scale', (1.0, 1.0, 1.0))
                s.change(obj, 'delta_scale', (1.0, 1.0, 1.0))
            for child in obj.children:
                # Apply keeps them where they are (it sets their parent inverse).
                s._moving[_pointer(child)] = False
            parts = [w for w, on in (("Location", location), ("Rotation", rotation), ("Scale", scale)) if on]
            _judge([obj] + [o for o in affected([obj], s) if o != obj], s, "Apply ▸ " + " & ".join(parts),
                   "Lower what %s's modifiers make first." % obj.name)
        finally:
            s.close()


def price_mesh_subdivide(number_cuts=1, **_):
    """Edit Mode ▸ Edge ▸ Subdivide at `number_cuts`, on each mesh in Edit
    Mode: an upper bound of what it makes — each selected edge gains the cuts,
    and each face with a selected edge at most a grid of (cuts + 1)² faces
    and cuts² vertices inside it (a quad's pattern; a triangle's makes
    fewer, an N-Gon's none) — through the stack. Round 4's fix-round review:
    10 cuts on a cube under Subdivision 6 made 2,973,698."""
    if not _is_real_blender():
        return
    n = max(0, int(number_cuts))
    if not n:
        return
    import numpy as np
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or ())
    for obj in objects:
        if obj.type != 'MESH' or obj.mode != 'EDIT':
            continue
        obj = _geometry_object(obj)  # the edit written back, selection and all
        mesh = obj.data
        v0, e0, f0, c0 = len(mesh.vertices), len(mesh.edges), len(mesh.polygons), len(mesh.loops)
        if not e0:
            continue
        chosen = np.zeros(e0, dtype=bool)
        hidden = np.zeros(e0, dtype=bool)
        mesh.edges.foreach_get('select', chosen)
        mesh.edges.foreach_get('hide', hidden)
        chosen &= ~hidden
        edges = int(chosen.sum())
        if not edges:
            continue
        t = k = 0
        if f0:
            corner_edges = np.empty(c0, dtype=np.int32)
            mesh.loops.foreach_get('edge_index', corner_edges)
            totals = np.empty(f0, dtype=np.int32)
            mesh.polygons.foreach_get('loop_total', totals)
            starts = np.concatenate(([0], np.cumsum(totals)[:-1]))
            touched = np.add.reduceat(chosen[corner_edges].astype(np.int32), starts) > 0
            face_hidden = np.zeros(f0, dtype=bool)
            mesh.polygons.foreach_get('hide', face_hidden)
            touched &= ~face_hidden
            t = int(touched.sum())
            k = int(totals[touched].sum())
        g = (n + 1) * (n + 1)
        base = (v0 + n * edges + n * n * t,
                e0 + n * edges + 2 * n * (n + 1) * t,
                f0 + (g - 1) * t,
                c0 + 4 * g * t + n * k)
        price_base(obj, base, "Subdivide with %d cut%s across %s selected edges"
                   % (n, "" if n == 1 else "s", format(edges, ',')),
                   "Use fewer cuts, or select fewer edges.")


def _edit_selection(obj):
    """(V, E, F, C, selected vertices, edges, faces, the corners of the
    selected faces, the corners at the selected vertices) of `obj`'s mesh as
    Edit Mode holds it (written back first), hidden elements left out."""
    import numpy as np
    obj = _geometry_object(obj)
    mesh = obj.data
    v, e, f, c = len(mesh.vertices), len(mesh.edges), len(mesh.polygons), len(mesh.loops)

    def chosen(collection, n):
        picked = np.zeros(n, dtype=bool)
        hidden = np.zeros(n, dtype=bool)
        if n:
            collection.foreach_get('select', picked)
            collection.foreach_get('hide', hidden)
        return picked & ~hidden

    vs, es, fs = chosen(mesh.vertices, v), chosen(mesh.edges, e), chosen(mesh.polygons, f)
    totals = np.empty(f, dtype=np.int32)
    corner_verts = np.empty(c, dtype=np.int32)
    if f:
        mesh.polygons.foreach_get('loop_total', totals)
    if c:
        mesh.loops.foreach_get('vertex_index', corner_verts)
    cs = int(totals[fs].sum()) if f else 0
    cv = int(vs[corner_verts].sum()) if c else 0
    return v, e, f, c, int(vs.sum()), int(es.sum()), int(fs.sum()), cs, cv


def _bevel_growth(n, affect, vs, es, cv):
    patch = _bevel_patch(max(1, int(n)), False) * 2
    if affect == 'VERTICES':
        dv = 2 * (int(n) + 1) * cv + vs
    else:
        dv = max(cv, 2 * es) * patch + 8
    return dv, math.ceil(2.25 * dv), math.ceil(1.25 * dv), math.ceil(4.5 * dv)


# Edit Mode's mesh operators that add geometry to the edited mesh: at most
# what each adds, from the selection and its own settings — (vertices, edges,
# faces, corners) added, from (V, E, F, C, selected vertices, edges, faces,
# corners of the selected faces, corners at the selected vertices, keywords).
# Each press can at most add its selection again (an Extrude, a Duplicate, an
# Inset), and a press repeated under a Subdivision multiplies what it adds;
# those with a count of their own (Bevel's Segments, Spin's Steps, Bridge's
# Cuts, up to 1,000 and more) multiply it at once. Priced through the stack
# as the mesh's new base (`price_base`).
def _g(k, name, default):
    return k.get(name, default)


_EDIT_GROWTH = {
    'mesh.bevel': lambda V, E, F, C, vs, es, fs, cs, cv, k: _bevel_growth(
        _g(k, 'segments', 1), _g(k, 'affect', 'EDGES'), vs, es, cv),
    'mesh.spin': lambda V, E, F, C, vs, es, fs, cs, cv, k: (
        lambda n: (n * vs, n * (es + vs), n * (es + fs), n * (4 * es + cs)))(int(_g(k, 'steps', 12)) + 1),
    'mesh.screw': lambda V, E, F, C, vs, es, fs, cs, cv, k: (
        lambda n: (n * vs, n * (es + vs), n * (es + fs), n * (4 * es + cs)))(
        int(_g(k, 'steps', 9)) * int(_g(k, 'turns', 1)) + 1),
    'mesh.bridge_edge_loops': lambda V, E, F, C, vs, es, fs, cs, cv, k: (
        lambda n: (n * vs, (n + 1) * (vs + es), (n + 1) * es, 4 * (n + 1) * es))(int(_g(k, 'number_cuts', 0))),
    'mesh.extrude_repeat': lambda V, E, F, C, vs, es, fs, cs, cv, k: (
        lambda n: (n * vs, n * (es + vs), n * (fs + es), n * (cs + 4 * es)))(int(_g(k, 'steps', 10))),
    'mesh.fill_grid': lambda V, E, F, C, vs, es, fs, cs, cv, k: (
        es * es // 4 + 4, es * es // 2 + es, es * es // 4 + es, es * es + 4 * es),
    'mesh.symmetrize': lambda V, E, F, C, vs, es, fs, cs, cv, k: (V, E, F, C),
    'mesh.bisect': lambda V, E, F, C, vs, es, fs, cs, cv, k: (E, E + F, F, C + 2 * F),
    'mesh.convex_hull': lambda V, E, F, C, vs, es, fs, cs, cv, k: (0, 3 * vs, 2 * vs, 6 * vs),
    'mesh.wireframe': lambda V, E, F, C, vs, es, fs, cs, cv, k: (
        2 * (vs + es) + cs, 8 * es + cs, 4 * es, 16 * es),
    'mesh.poke': lambda V, E, F, C, vs, es, fs, cs, cv, k: (fs, cs, cs, 3 * cs),
    'mesh.inset': lambda V, E, F, C, vs, es, fs, cs, cv, k: (cs, 2 * cs, cs, 4 * cs),
}
for _name in ('mesh.extrude_region_move', 'mesh.extrude_region_and_move', 'mesh.extrude_region_shrink_fatten',
              'mesh.extrude_manifold', 'mesh.extrude_context_move', 'mesh.extrude_region',
              'mesh.extrude_context', 'mesh.solidify'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (vs, es + vs, fs + es, cs + 4 * es)
for _name in ('mesh.extrude_faces_move', 'mesh.extrude_faces_indiv'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (cs, 3 * cs, fs + cs, 5 * cs)
for _name in ('mesh.extrude_edges_move', 'mesh.extrude_edges_indiv', 'mesh.extrude_vertices_move',
              'mesh.extrude_verts_indiv'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (2 * es + vs, 3 * es + vs, es, 4 * es)
for _name in ('mesh.duplicate_move', 'mesh.duplicate'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (vs, es, fs, cs)
for _name in ('mesh.offset_edge_loops_slide', 'mesh.offset_edge_loops'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (2 * vs, 3 * es + 2 * vs, 2 * es, 8 * es)
for _name in ('mesh.rip_edge_move', 'mesh.rip_move', 'mesh.split', 'mesh.edge_split'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (cv, es + cv, 0, 0)
for _name in ('mesh.vert_connect', 'mesh.vert_connect_path', 'mesh.face_split_by_edges', 'mesh.edge_face_add',
              'mesh.fill_holes', 'mesh.fill', 'mesh.beautify_fill'):
    _EDIT_GROWTH[_name] = lambda V, E, F, C, vs, es, fs, cs, cv, k: (0, es + vs, es + vs, 2 * (es + vs))


def price_edit_operator(path, keywords):
    """One of `_EDIT_GROWTH`'s operators on each mesh in Edit Mode, priced
    before it runs (`price_base`)."""
    if not _is_real_blender():
        return
    growth = _EDIT_GROWTH.get(path)
    if growth is None:
        return
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or ())
    label = _operator_name(path)
    for obj in objects:
        if obj.type != 'MESH' or obj.mode != 'EDIT':
            continue
        V, E, F, C, vs, es, fs, cs, cv = _edit_selection(obj)
        if not (vs or es or fs) and path not in ('mesh.symmetrize', 'mesh.bisect'):
            continue
        dv, de, df, dc = (int(n) for n in growth(V, E, F, C, vs, es, fs, cs, cv, keywords))
        if not (dv or de or df or dc):
            continue
        settings = ", ".join("%s %s" % (k.replace('_', ' ').title(), keywords[k])
                             for k in ('segments', 'steps', 'number_cuts', 'turns') if k in keywords)
        price_base(obj, (V + dv, E + de, F + df, C + dc),
                   label + (" (%s)" % settings if settings else "") + " on %s selected" % format(vs, ','),
                   "Use fewer segments, steps or cuts, or select less.")


def _edit_intersections(obj):
    """Intersect (Knife) and Intersect (Boolean): at most two vertices for
    each pair of the edited mesh's faces that meet (a BVH of the mesh against
    itself, which counts neighbours too)."""
    import bmesh
    from mathutils.bvhtree import BVHTree
    bm = bmesh.from_edit_mesh(obj.data)
    tree = BVHTree.FromBMesh(bm)
    pairs = len(tree.overlap(tree))
    return 2 * pairs


def price_edit_intersect(**_):
    if not _is_real_blender():
        return
    for obj in list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or ()):
        if obj.type != 'MESH' or obj.mode != 'EDIT':
            continue
        added = _edit_intersections(obj)
        V, E, F, C, vs, es, fs, cs, cv = _edit_selection(obj)
        price_base(obj, (V + added, E + 3 * added, F + 2 * added, C + 6 * added),
                   "Intersect, where %s's faces meet" % obj.name, "Select less, or lower what the modifiers make.")


def price_curve_extrude(**_):
    """A curve's Extrude: a point more for each selected end point."""
    if not _is_real_blender():
        return
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if obj is None or obj.type not in ('CURVE', 'SURFACE') or obj.mode != 'EDIT':
        return
    obj = _geometry_object(obj)
    ratio, chosen = 1.0, 0
    for spline in obj.data.splines:
        points = list(spline.bezier_points) if spline.type == 'BEZIER' else list(spline.points)
        flags = [(p.select_control_point if spline.type == 'BEZIER' else p.select) for p in points]
        picked = sum(1 for f in flags if f)
        if picked and points:
            chosen += picked
            ratio = max(ratio, (len(points) + picked) / float(max(1, len(points) - 1)))
    if not chosen:
        return
    now = Counts(*base_counts(obj))
    ring = _ring(obj.data)
    grown = Counts(math.ceil(now.v * ratio) + ring, math.ceil(now.e * ratio) + 2 * ring,
                   math.ceil(now.f * ratio) + ring, math.ceil(now.c * ratio) + 4 * ring, False)
    price_base(obj, grown.tuple(), "Extrude with %d selected points" % chosen, "Select fewer points.")


# --------------------------------------------------------------------------
# Object Mode moves: where an object is is what an Array fitted to a length
# counts its copies by, and what a Hook, an offset object or a Fit Curve's
# curve gives the modifiers after it. The gizmo's commit, the snaps and the
# clears move objects through operators that evaluate the scene themselves
# (measured in desktop 5.2.1: right after `transform.translate` of an Array's
# offset object to 0.0001 m, the Array's evaluated mesh already had
# 3,199,472 vertices), so they are priced before they run, from what they are
# called with.


def _operator_name(path):
    """Blender's own name for the operator `path` ('Clear Location' for
    object.location_clear), from its RNA."""
    module, _, name = path.partition('.')
    try:
        return getattr(getattr(bpy.ops, module), name).get_rna_type().name or name
    except (AttributeError, KeyError, RuntimeError):
        return name.replace('_', ' ').title()


_MOVES = ('transform.translate', 'transform.resize', 'transform.rotate', 'transform.mirror',
          'object.location_clear', 'object.rotation_clear', 'object.scale_clear',
          'view3d.snap_selected_to_cursor', 'view3d.snap_selected_to_active', 'view3d.snap_selected_to_grid',
          'object.parent_clear', 'object.origin_set')


def _moved_objects():
    """The objects an Object Mode transform moves: the selected editable
    ones, but not one whose parent is moved too (it follows its parent)."""
    chosen = list(getattr(bpy.context, 'selected_editable_objects', None) or ())
    picked = set(chosen)

    def ancestor_picked(o):
        p = o.parent
        while p is not None:
            if p in picked:
                return True
            p = p.parent
        return False

    return [o for o in chosen if not ancestor_picked(o)]


def _in_view_window():
    """Whether the call runs in a 3D View's main region (the app's
    `temp_override_view3d`), where Blender's transforms read the scene's
    Orientation and Pivot Point and the view's matrix; with no such region (a
    script line, the bare bridge) they take Global and the bounds centre
    (`initTransInfo`, `t_around_get`, transform_generics.cc)."""
    try:
        area, region = bpy.context.area, bpy.context.region
        return (area is not None and area.type == 'VIEW_3D' and region is not None
                and region.type == 'WINDOW')
    except (AttributeError, ReferenceError):
        return False


def _given_axes(value):
    """An `orient_matrix` as Blender reads it into its `float[3][3]`, whose
    `[i]` is axis i, as a Matrix whose columns are the axes. Measured in
    desktop 5.2.1 (fix round 3, October 29): nested rows (0, 1, 0),
    (-1, 0, 0), (0, 0, 1) with value=(1, 2, 3) moved an empty by (-2, 1, 3),
    each row an axis; the same numbers as a mathutils Matrix moved it by
    (2, -1, 3), each column an axis. The earlier price took nested rows as a
    Matrix's rows, so a turned orientation's move was priced the other way."""
    from mathutils import Matrix
    if isinstance(value, Matrix):
        return value.to_3x3()
    items = list(value)
    if len(items) == 9:
        items = [items[0:3], items[3:6], items[6:9]]
    return Matrix([tuple(float(c) for c in row) for row in items]).transposed()


def _axes_of(kind):
    """Blender's matrix (columns are the axes) for the orientation `kind`, as
    `calc_orientation_from_type_ex` works it out in the call's context:
    View from the region's view where there is one, else the identity;
    every other kind as `_blenderkit_orient.matrix`, its line-for-line port.
    None for a custom orientation that is not the scene's slot's (no API
    hands its matrix out)."""
    from mathutils import Matrix
    if kind == 'VIEW':
        rv3d = getattr(bpy.context, 'region_data', None) if _in_view_window() else None
        if rv3d is None:
            return Matrix.Identity(3)
        m = rv3d.view_matrix.inverted_safe().to_3x3()
        cols = [m.col[i].normalized() if m.col[i].length > 0 else m.col[i] for i in range(3)]
        return Matrix((cols[0], cols[1], cols[2])).transposed()
    orient = _sibling('_blenderkit_orient')
    if kind not in orient.TYPES:
        slot = bpy.context.scene.transform_orientation_slots[0]
        custom = slot.custom_orientation
        if custom is None or custom.name != kind:
            return None
    axes = orient.matrix(kind)
    if axes is None:
        return None
    return Matrix((tuple(axes[0]), tuple(axes[1]), tuple(axes[2]))).transposed()


def _orientation(keywords, constrained):
    """The orientation (`t->spacemtx`, columns the axes) a transform called
    with `keywords` moves in, as `initTransInfo` (transform_generics.cc)
    chooses it, or None where it cannot be worked out here. `constrained`:
    whether Blender applies a constraint (Move and Scale given a value always
    do, on all three axes).

    - No `orient_type` and no `orient_matrix`: the scene's Orientation in a
      3D View's region, else Global.
    - An `orient_matrix` is used as given only with no `orient_type`, or with
      an `orient_matrix_type` equal to it ("Constraints are forced to use the
      custom matrix when redoing"); otherwise Blender works the matrix out
      again from `orient_type`.

    Fix round 3's review (October 29), sandboxed desktop 5.2.1 with the app's
    context at the real budget: O, the offset of A's Array fitted to 40, at
    (1, 0, 0) and turned 90° about Z; `transform.resize(value=(1, 0.0001,
    1), orient_type='LOCAL', constraint_axis=(False, True, False),
    center_override=(0, 0, 0))` — what the gizmo commits for a Scale in
    Local — and `transform.translate(value=(0, 0.9999, 0), orient_type=
    'LOCAL')` — the redo panel's Orientation row, a script line, the
    Operator Search — each built A 328 -> 3,199,472 with no refusal: a bare
    orientation was priced as the identity."""
    kind = keywords.get('orient_type')
    given = keywords.get('orient_matrix')
    given_type = keywords.get('orient_matrix_type')
    scene_kind = 'GLOBAL'
    if _in_view_window():
        scene_kind = bpy.context.scene.transform_orientation_slots[0].type
    type_set = kind
    matrix_set = None
    custom = None
    if given is not None:
        try:
            custom = _given_axes(given)
        except (TypeError, ValueError):
            return None
        if given_type is not None:
            matrix_set = given_type
        elif type_set is None:
            type_set = 'CUSTOM_MATRIX'
    if type_set is None and matrix_set is not None:
        type_set = matrix_set
    if type_set is None:
        # O_SCENE when constrained, O_DEFAULT (the scene's) when not.
        chosen = scene_kind
    else:
        chosen = 'CUSTOM_MATRIX' if matrix_set is not None and matrix_set == type_set else type_set
    if chosen == 'CUSTOM_MATRIX':
        return custom
    return _axes_of(chosen)


def _constraint_axes(path, keywords):
    """The axes Blender constrains a transform to: all three for Move and
    Scale given a value ("so that the orientation is more intuitive in the
    Redo Panel"), else `constraint_axis` as given."""
    if path in ('transform.translate', 'transform.resize') and 'value' in keywords:
        return (True, True, True)
    try:
        axes = tuple(bool(a) for a in keywords.get('constraint_axis', (False, False, False)))
    except TypeError:
        return (False, False, False)
    return axes if len(axes) == 3 else (False, False, False)


def _pivot(keywords, moved):
    """The point a transform turns and scales about: `center_override` when
    given (RNA_property_is_set, (0, 0, 0) included); else, in a 3D View's
    region, the scene's Pivot Point (`t_around_get`), and with no region the
    bounds centre of what moves. None for Individual Origins (each about its
    own)."""
    from mathutils import Vector
    centre = keywords.get('center_override')
    if centre is not None:
        return Vector(centre)
    if not moved:
        return Vector((0.0, 0.0, 0.0))
    around = 'BOUNDING_BOX_CENTER'
    if _in_view_window():
        around = bpy.context.scene.tool_settings.transform_pivot_point
    points = [o.matrix_world.translation for o in moved]
    if around == 'INDIVIDUAL_ORIGINS':
        return None
    if around == 'CURSOR':
        return Vector(bpy.context.scene.cursor.location)
    if around == 'ACTIVE_ELEMENT':
        active = bpy.context.view_layer.objects.active
        if active is not None:
            return active.matrix_world.translation.copy()
        around = 'MEDIAN_POINT'
    if around == 'MEDIAN_POINT':
        return sum(points, Vector()) / len(points)
    low = Vector([min(p[i] for p in points) for i in range(3)])
    high = Vector([max(p[i] for p in points) for i in range(3)])
    return (low + high) / 2.0


def _transform_matrix(path, keywords, moved):
    """{object: the world-space matrix `transform.<path>(**keywords)` applies
    to it}, about its pivot (measured: 0.5 about Z turns (1, 0, 0) to
    (0.8776, 0.4794, 0) with no 3D View, and to (0.8776, -0.4794, 0) in one,
    where Blender turns an unconstrained rotation's axis over,
    `transform_mode_rotation_axis_get`; a Resize of 2 on X with no centre
    scales about the origins' bounds centre; a Mirror on X about the origin
    takes 1 to -1); or None where Blender's own cannot be worked out here.
    What Blender then evaluates is held to it in the operator's update
    (`priced_places`, read by the gate's `_within_move`)."""
    from mathutils import Matrix, Vector
    axes = _constraint_axes(path, keywords)
    orient = _orientation(keywords, any(axes))
    if orient is None:
        return None
    if path == 'transform.translate':
        delta = orient @ Vector(keywords.get('value', (0.0, 0.0, 0.0)))
        return {o: Matrix.Translation(delta) for o in moved}
    if path == 'transform.resize':
        x, y, z = keywords.get('value', (1.0, 1.0, 1.0))
        inner = orient @ Matrix.Diagonal((x, y, z)) @ orient.inverted_safe()
    elif path == 'transform.mirror':
        inner = orient @ Matrix.Diagonal(tuple(-1.0 if a else 1.0 for a in axes)) @ orient.inverted_safe()
    elif path == 'transform.rotate':
        picked = [i for i in range(3) if axes[i]]
        if len(picked) == 1:
            axis = orient.col[picked[0]].copy()
        elif len(picked) == 2:
            # A plane: the axis is its normal (`constraints_rotation_impl`).
            axis = orient.col[3 - picked[0] - picked[1]].copy()
        elif not picked:
            axis = orient.col[{'X': 0, 'Y': 1, 'Z': 2}.get(keywords.get('orient_axis', 'Z'), 2)].copy()
            if _in_view_window():
                axis = -axis
        else:
            return None
        inner = Matrix.Rotation(float(keywords.get('value', 0.0)), 3, axis)
    else:
        return None
    pivot = _pivot(keywords, moved)
    found = {}
    for o in moved:
        point = pivot if pivot is not None else o.matrix_world.translation
        found[o] = Matrix.Translation(point) @ inner.to_4x4() @ Matrix.Translation(-point)
    return found


# What an Object Mode move's own price priced, by object pointer: ('world',
# the world matrix the object was priced at) or ('values', {setting: value
# it was priced with}) (`price_object_moves`). The gate holds the move's
# update to it (`_within_move`) and prices the update whole wherever Blender
# moved an object otherwise: fix round 3's review measured a Scale in Local
# and a Move in Local priced as Global (the identity) and let through
# unpriced in the update, A 328 -> 3,199,472. Cleared as each priced
# operator's call begins (`forget_places`, from the gate's `_move_scope`).
priced_places = {}


def forget_places():
    priced_places.clear()


def _record_places(changes):
    from mathutils import Matrix
    for o, key, value in changes:
        p = _pointer(o)
        if key == 'matrix_world':
            priced_places[p] = ('world', Matrix(value))
            continue
        record = priced_places.setdefault(p, ('values', {}))
        if record[0] == 'values':
            record[1][key] = value


def price_object_moves(path, keywords):
    """An Object Mode move (`transform.translate`, `resize`, `rotate`,
    `mirror`, the snaps, the clears, Clear Parent, Set Origin) priced as the
    new places of what it moves (`price_all` of their world matrices)."""
    priced_places.clear()
    if not _is_real_blender() or getattr(bpy.context, 'mode', 'OBJECT') != 'OBJECT':
        return
    from mathutils import Matrix, Vector
    moved = _moved_objects()
    changes = []
    label = _operator_name(path)
    if path.startswith('transform.'):
        applied = _transform_matrix(path, keywords, moved)
        if applied is None:
            # Not worked out here (a custom orientation other than the
            # scene's slot's, all three axes of a Rotate): the update is
            # priced whole (`_within_move` finds no place priced).
            return
        changes = [(o, 'matrix_world', applied[o] @ o.matrix_world) for o in moved]
    elif path in ('object.location_clear', 'object.rotation_clear', 'object.scale_clear'):
        key = {'object.location_clear': 'location', 'object.scale_clear': 'scale'}.get(path)
        for o in getattr(bpy.context, 'selected_editable_objects', None) or ():
            if key == 'location':
                changes.append((o, 'location', (0.0, 0.0, 0.0)))
            elif key == 'scale':
                changes.append((o, 'scale', (1.0, 1.0, 1.0)))
            else:
                changes += [(o, 'rotation_euler', (0.0, 0.0, 0.0)), (o, 'rotation_quaternion', (1.0, 0.0, 0.0, 0.0)),
                            (o, 'rotation_axis_angle', (0.0, 0.0, 1.0, 0.0))]
    elif path in ('view3d.snap_selected_to_cursor', 'view3d.snap_selected_to_active',
                  'view3d.snap_selected_to_grid'):
        if path == 'view3d.snap_selected_to_cursor':
            target = Vector(bpy.context.scene.cursor.location)
        elif path == 'view3d.snap_selected_to_active':
            active = bpy.context.view_layer.objects.active
            if active is None:
                return
            target = active.matrix_world.translation.copy()
        else:
            target = None
        centre = _pivot({}, moved)
        for o in moved:
            m = o.matrix_world.copy()
            if target is None:
                m.translation = Vector([round(c) for c in m.translation])
            elif keywords.get('use_offset'):
                m.translation = m.translation - centre + target
            else:
                m.translation = target
            changes.append((o, 'matrix_world', m))
    elif path == 'object.parent_clear':
        kind = keywords.get('type', 'CLEAR')
        for o in getattr(bpy.context, 'selected_editable_objects', None) or ():
            if o.parent is None:
                continue
            if kind == 'CLEAR_KEEP_TRANSFORM':
                # Where it is stays where it is: held to that in the update.
                priced_places[_pointer(o)] = ('world', o.matrix_world.copy())
                continue
            if kind == 'CLEAR_INVERSE':
                changes.append((o, 'matrix_parent_inverse', Matrix.Identity(4)))
            else:
                changes.append((o, 'parent', None))
    elif path == 'object.origin_set':
        kind = keywords.get('type', 'GEOMETRY_ORIGIN')
        for o in getattr(bpy.context, 'selected_editable_objects', None) or ():
            if kind == 'ORIGIN_CURSOR':
                point = Vector(bpy.context.scene.cursor.location)
            elif kind in ('ORIGIN_GEOMETRY', 'ORIGIN_CENTER_OF_MASS', 'ORIGIN_CENTER_OF_VOLUME'):
                corners = [o.matrix_world @ Vector(c) for c in o.bound_box]
                point = sum(corners, Vector()) / max(1, len(corners))
            else:
                continue
            m = o.matrix_world.copy()
            m.translation = point
            changes.append((o, 'matrix_world', m))
    if changes:
        _record_places(changes)
        price_all(changes, label, "Move it less, or lower what the modifiers that read where it is make.")


def price_curve_subdivide(number_cuts=1, **_):
    """A curve's Edit Mode ▸ Segments ▸ Subdivide at `number_cuts`: each
    selected segment (both its points selected) made cuts + 1 segments, and
    what Blender builds of the curve grown as its segments are, through the
    stack. Round 4's fix-round review: 4 cuts twice under two Arrays of 64,
    425,984 → 1,998,848 → 9,863,168."""
    if not _is_real_blender():
        return
    n = max(0, int(number_cuts))
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if not n or obj is None or obj.type not in ('CURVE', 'SURFACE') or obj.mode != 'EDIT':
        return
    obj = _geometry_object(obj)
    ratio = 1.0
    selected_segments = 0
    for spline in obj.data.splines:
        points = list(spline.bezier_points) if spline.type == 'BEZIER' else list(spline.points)
        flags = [(p.select_control_point if spline.type == 'BEZIER' else p.select) for p in points]
        count = len(points)
        segments = count if spline.use_cyclic_u else max(count - 1, 0)
        chosen = sum(1 for i in range(segments) if flags[i] and flags[(i + 1) % count])
        if chosen and segments:
            selected_segments += chosen
            ratio = max(ratio, (segments + n * chosen) / float(segments))
    if not selected_segments:
        return
    now = Counts(*base_counts(obj))
    ring = _ring(obj.data)
    grown = Counts(math.ceil(now.v * ratio) + ring * len(obj.data.splines), math.ceil(now.e * ratio) + 2 * ring,
                   math.ceil(now.f * ratio) + ring, math.ceil(now.c * ratio) + 4 * ring, False)
    price_base(obj, grown.tuple(), "Subdivide with %d cut%s across %d selected segments"
               % (n, "" if n == 1 else "s", selected_segments),
               "Use fewer cuts, or select fewer points.")


def price_quadriflow(mode='FACES', target_faces=4000, target_ratio=1.0, target_edge_length=0.1, **_):
    """Remesh ▸ QuadriFlow: the active mesh rebuilt as about the faces it is
    asked for (measured, 500 to 20,000 faces asked of Suzanne at level 2:
    0.95 to 1.007 of them, and 1.012 vertices per face asked; run as the
    search and a script run it, Ratio and Edge Length asked the Faces value),
    through the stack. Round 4's fix-round review: 40,000 faces under
    Subdivision 3, 31,746 → 2,553,282."""
    if not _is_real_blender():
        return
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if obj is None or obj.type != 'MESH':
        return
    obj = _geometry_object(obj)
    mesh = obj.data
    faces = float(target_faces)
    if mode == 'RATIO':
        faces = max(faces, float(target_ratio) * len(mesh.polygons))
    elif mode == 'EDGE' and float(target_edge_length) > 0:
        area = sum(p.area for p in mesh.polygons) if len(mesh.polygons) < 2_000_000 else float('inf')
        faces = max(faces, area / float(target_edge_length) ** 2)
    if not math.isfinite(faces):
        faces = float(BUDGET) * 10
    f = math.ceil(1.05 * faces) + 8
    price_base(obj, (math.ceil(1.05 * f) + 8, 2 * f + 8, f, 4 * f),
               "QuadriFlow Remesh with %s faces" % format(int(faces), ','),
               "Ask for fewer faces, or lower what the modifiers make.")


def price_voxel_remesh(obj, count):
    """Voxel Remesh (the Sculpt header's Remesh, `object.voxel_remesh`): the
    mesh rebuilt as at most `count` vertices of quads (the estimate,
    `_blenderkit_sculpt.remesh_estimate`), through the stack — it was priced
    on its base alone, and a cube under Subdivision 3 at a voxel of 0.02 went
    from 386 to 3,917,186 vertices (round 4's fix-round review)."""
    count = int(math.ceil(count))
    price_base(obj, (count, 2 * count + 8, count + 8, 4 * count + 32),
               "Voxel Remesh at %g" % obj.data.remesh_voxel_size,
               "Use a larger voxel size, or lower what the modifiers make.")


class _Named:
    """What a refusal names when the object is not made yet."""

    def __init__(self, name):
        self.name = name


def price_metaball_add(type='BALL', radius=2.0, scale=(0.0, 0.0, 0.0), **_):
    """Add ▸ Metaball: an element of `radius` added to the edited metaball in
    its Edit Mode, else a new object of the "Mball" family — counted, with
    every element the family's basis polygonizes, as `_meta_base` counts it."""
    if not _is_real_blender():
        return
    view_layer = bpy.context.view_layer
    active = view_layer.objects.active if view_layer is not None else None
    factor = max((abs(float(c)) for c in scale), default=0.0) or 1.0
    extent = abs(float(radius)) * factor + (factor if type != 'BALL' else 0.0)
    if active is not None and active.type == 'META' and active.mode == 'EDIT':
        member = active
        basis, _ = meta_family(active)
        world = active.matrix_world
    else:
        member = None
        candidates = [o for o in bpy.data.objects if o.type == 'META' and _family_base(o.name) == 'Mball']
        basis = next((o for o in candidates if _is_basis(o)), None)
        from mathutils import Matrix
        world = Matrix.Identity(4)
    label = "Add ▸ Metaball with Radius %g" % float(radius)
    instead = "Use a smaller radius, or a larger Resolution on the metaball."
    if basis is None:
        # It becomes a family of its own, at a new metaball's resolution.
        resolution = bpy.types.MetaBall.bl_rna.properties['resolution'].default
        count = int(min(2.0 * 24.0 * extent * extent / (resolution * resolution), 1e15)) + 8
        refuse_count(member or _Named("the new metaball"), count, label, instead)
        return
    relative = basis.matrix_world.inverted_safe() @ world
    share = 24.0 * (extent * max(relative.col[i].xyz.length for i in range(3))) ** 2
    s = Prices()
    try:
        s.added_elements[_pointer(basis)] = [share]
        _judge([basis], s, label, instead)
    finally:
        s.close()


def price_detail_flood_fill():
    """Dynamic Topology's Detail Flood Fill: the whole mesh cut to the
    Constant detail (edges of 1 / Resolution in the object's units), at most
    two vertices per triangle of that edge over its area, through the stack."""
    if not _is_real_blender():
        return
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if obj is None or obj.type != 'MESH' or obj.mode != 'SCULPT':
        return
    settings = bpy.context.scene.tool_settings.sculpt
    edge = 1.0 / max(1e-6, float(settings.constant_detail_resolution))
    try:
        bpy.ops.ed.flush_edits()
    except RuntimeError:
        pass
    area = float(Measures(obj.data).areas.sum())
    count = int(min(2.0 * area / (0.433 * edge * edge), 1e15)) + len(obj.data.vertices)
    price_base(obj, (count, 3 * count, 2 * count, 6 * count),
               "Detail Flood Fill at a Resolution of %g" % settings.constant_detail_resolution,
               "Use a lower Resolution.")


def _rendered_scenes(scene):
    """`scene` and every scene a render of it renders too: its Background
    Scene and that one's, the scenes its compositor's Render Layers nodes
    name, and the scenes of its Sequencer's Scene strips — and theirs."""
    found, stack = [], [scene]
    while stack:
        other = stack.pop()
        if other is None or any(other == f for f in found):
            continue
        found.append(other)
        try:
            stack.append(other.background_set)
            tree = getattr(other, 'compositing_node_group', None) or getattr(other, 'node_tree', None)
            for node in (tree.nodes if tree is not None else ()):
                if node.type == 'R_LAYERS':
                    stack.append(getattr(node, 'scene', None))
            editor = other.sequence_editor
            if editor is not None:
                for strip in getattr(editor, 'strips_all', None) or getattr(editor, 'sequences_all', ()):
                    if strip.type == 'SCENE':
                        stack.append(strip.scene)
        except (AttributeError, ReferenceError, RuntimeError, TypeError):
            continue
    return found


def price_render(scene=None, doing="Rendering"):
    """A render (`render.render`, the app's F12 and Render menu, the search, a
    script line), priced before Blender renders: every object the render
    shows evaluated at its render settings — a new Subdivision Surface's
    Render level is 2 where its viewport's is 1, and a modifier hidden from
    renders is left out — refused, in words, past the budget or for its
    limit surface's time. `scene`: the one the call names (the context's when
    None), with every scene it renders too (`_rendered_scenes`). Fix round 3
    (October 29), desktop 5.2.1 with the app's context, the budget lowered
    to 100,000: `render.render(scene='S2')`, S2 holding X at 196,612
    vertices by its Render levels, rendered in Cycles with no refusal (the
    review had measured peak memory 307 → 1,465 MB at the full budget); this
    walked the context's scene whatever the call named. `doing` names the
    work for a bake or an export, which evaluate at render settings too."""
    if not _is_real_blender():
        return
    scene = scene or bpy.context.scene
    seen = set()
    for other in _rendered_scenes(scene):
        shown = [o for o in other.objects if o is not None and not o.hide_render]
        gate = _gate()
        if gate is not None:
            shown = gate._dependencies(shown)
        for obj in shown:
            if obj.type not in COUNTED_TYPES or obj.hide_render or _pointer(obj) in seen:
                continue
            seen.add(_pointer(obj))
            s = Prices(render=True)
            try:
                try:
                    w = _final(obj, s)
                except Unpriceable as why:
                    raise RuntimeError("%s: %s." % (doing, str(why))) from None
                instead = ("Lower its Render levels, or what its modifiers make in renders (their "
                           "camera toggles).")
                if _over(w.final.v):
                    refuse_count(obj, w.final.v, doing, instead, " at its render settings")
                seconds, name = _subdivision_seconds(w)
                if seconds > SUBDIVISION_SECONDS:
                    raise RuntimeError("%s: %s" % (doing, _subdivision_refusal(obj, name, seconds)))
            finally:
                s.close()


# Operators that evaluate the scene at its render settings besides a render:
# a bake (Cycles builds a render depsgraph of the view layer, object_bake_api.cc)
# and the exporters set to Render. Fix round 3 (October 29), desktop 5.2.1
# with the app's context, the budget lowered to 100,000: a cube under an
# Array of 2 and a Subdivision of Render level 7 (16 vertices in the
# viewport, 196,612 rendered), `object.bake(type='NORMAL')` from a script line
# ran with no refusal (the review: peak memory 307 → 2,967 MB at the full
# budget's level 9). What, and when: (the keyword, the value that renders),
# or None for always.
_RENDER_EVALUATIONS = {
    'object.bake': (None, "Baking"), 'object.bake_image': (None, "Baking"),
    'wm.obj_export': (('export_eval_mode', 'DAG_EVAL_RENDER'), "Exporting"),
    'wm.stl_export': (('evaluation_mode', 'DAG_EVAL_RENDER'), "Exporting"),
    'wm.usd_export': (('evaluation_mode', 'RENDER'), "Exporting"),
    'wm.alembic_export': (('evaluation_mode', 'RENDER'), "Exporting"),
    'export_scene.fbx': (('use_mesh_modifiers_render', True), "Exporting"),
}


def _keyword(path, keywords, name):
    """`name` as the call has it, or the operator's default."""
    if name in keywords:
        return keywords[name]
    module, _, op = path.partition('.')
    try:
        return getattr(getattr(bpy.ops, module), op).get_rna_type().properties[name].default
    except (AttributeError, KeyError, RuntimeError, TypeError):
        return None


def price_metaball_duplicates():
    """Duplicate (Shift+D) of metaball objects: each copy joins its family,
    whose basis then polygonizes the copied elements too (`_meta_base`).
    Any other duplicate is an object of its own, priced as it is changed."""
    if not _is_real_blender():
        return
    shares = {}
    for member in getattr(bpy.context, 'selected_editable_objects', None) or ():
        if member.type != 'META' or member.data is None:
            continue
        basis, _ = meta_family(member)
        if basis is None:
            continue
        s = Prices()
        try:
            relative = basis.matrix_world.inverted_safe() @ member.matrix_world
            scale = max(relative.col[i].xyz.length for i in range(3))
            share = sum(_meta_element_bound(e, s, scale) for e in member.data.elements)
        finally:
            s.close()
        shares.setdefault(basis, []).append(share)
    for basis, added in shares.items():
        s = Prices()
        try:
            s.added_elements[_pointer(basis)] = added
            _judge([basis], s, "Duplicate Objects", "Duplicate fewer metaballs, or use a larger Resolution.")
        finally:
            s.close()


def edit_price_before(obj):
    """(the vertices, the limit surface's seconds) `obj` counts before an
    operator runs in its Edit Mode — Object Mode's evaluation, every modifier
    shown in the viewport, which is what leaving Edit Mode builds: the
    'now' of the gate's Edit Mode transaction (`_blenderkit_gate._EditGuard`)."""
    s = Prices()
    try:
        try:
            w = _final(obj, s)
        except Unpriceable:
            return (BUDGET * 1000, 0.0)
        try:
            seconds = _subdivision_seconds(w)[0]
        except Unpriceable:
            seconds = 0.0
        return (w.final.v, seconds)
    finally:
        s.close()


def edit_price_after(obj, shown, before, label):
    """The gate's Edit Mode transaction, after the run: `obj`'s mesh as the
    operator left it, under its stack — the modifiers in `shown` hidden for
    the run and counted as shown — judged against `before`
    (`edit_price_before`). Returns the refusal's words, or None."""
    return edit_price_after_all([(obj, shown, before)], label)


def edit_price_after_all(entries, label):
    """`edit_price_after` for every object the transaction held at once —
    the edited meshes, and what reads them (another object sharing one, a
    Boolean's or a Surface Deform's): `entries` are (object, the modifiers
    hidden for the run, its `edit_price_before`). Returns the refusal's
    words, or None."""
    s = Prices()
    try:
        held = []
        lazy = {}
        for obj, shown, before in entries:
            for m in shown:
                s.change(m, 'show_viewport', True)
            if callable(before):
                # Worked out only where the judgement needs it: past the
                # budget or the time (`_Lazy`), from the mesh as it was.
                lazy[_pointer(obj)] = before
            else:
                s.was[_pointer(obj)] = before[0]
                s.was_seconds[_pointer(obj)] = before[1]
            held.append(obj)
        if lazy:
            s.was = _Lazy(s.was, lazy, 0)
            s.was_seconds = _Lazy(s.was_seconds, lazy, 1)
        reach = [o for o in affected([o.data if o.data is not None else o for o in held] + held, s)
                 if o not in held]
        _judge(held + reach, s, label + " in Edit Mode", "Select less, or lower what the modifiers make.")
    except RuntimeError as refusal:
        return str(refusal)
    finally:
        s.close()
    return None


class _Lazy(dict):
    """`Prices.was` (or `was_seconds`) whose values for some objects are
    worked out the first time they are read: the Edit Mode transaction's
    'now', which the judgement reads only for a count past the budget or a
    time past its bound. Measured in desktop 5.2.1 before this, on a
    90,601-vertex grid under a Subdivision and an Array of 2: the 'now' read
    before every run was 31 ms of a Remove Doubles' 95 ms of the gate."""

    def __init__(self, known, lazy, index):
        super().__init__(known)
        self.lazy, self.index = lazy, index
        self.done = {}

    def _work(self, key):
        if key not in self.done:
            self.done[key] = self.lazy[key]()
        return self.done[key][self.index]

    def __contains__(self, key):
        return super().__contains__(key) or key in self.lazy

    def get(self, key, default=None):
        if super().__contains__(key):
            return super().get(key)
        if key in self.lazy:
            return self._work(key)
        return default

    def __getitem__(self, key):
        if super().__contains__(key):
            return super().__getitem__(key)
        if key in self.lazy:
            return self._work(key)
        raise KeyError(key)


def price_metaball_edit_duplicate():
    """A metaball's Edit Mode Duplicate (`mball.duplicate_move`,
    `mball.duplicate_metaelems`): every selected element copied into the
    edited metaball, which its family's basis then polygonizes too (round 4's
    second fix-round review: Select All and Duplicate, pressed again and
    again, took one element to 256 — 3,993,600 vertices — with nothing
    refused; wrapped as every other operator was, it was never priced)."""
    if not _is_real_blender():
        return
    active = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if active is None or active.type != 'META' or active.mode != 'EDIT' or active.data is None:
        return
    basis, _ = meta_family(active)
    if basis is None:
        return
    s = Prices()
    try:
        relative = basis.matrix_world.inverted_safe() @ active.matrix_world
        scale = max(relative.col[i].xyz.length for i in range(3))
        shares = [_meta_element_bound(e, s, scale) for e in active.data.elements if e.select]
        if not shares:
            return
        s.added_elements[_pointer(basis)] = shares
        _judge([basis], s, "Duplicate with %d selected element%s" % (len(shares), "" if len(shares) == 1 else "s"),
               "Duplicate fewer elements, or use a larger Resolution.")
    finally:
        s.close()


def _curve_selection(obj):
    """(points, selected points) of a curve's or surface's splines in Edit
    Mode."""
    total = chosen = 0
    for spline in obj.data.splines:
        if spline.type == 'BEZIER':
            points = spline.bezier_points
            chosen += sum(1 for p in points if p.select_control_point)
        else:
            points = spline.points
            chosen += sum(1 for p in points if p.select)
        total += len(points)
    return total, chosen


def _price_curve_points(obj, added, change, instead):
    """`obj`'s curve or surface with `added` more points, each laid out at
    the data's resolutions and made into its cross-section (`_ring`), priced
    through the stack: an upper bound of what a copy, an extrusion or an
    added primitive of that many points makes."""
    obj = _geometry_object(obj)
    now = Counts(*base_counts(obj))
    u, v = _resolutions(obj.data)
    ring = _ring(obj.data)
    extra = added * u * v * ring
    grown = Counts(now.v + extra, now.e + 2 * extra + ring, now.f + extra, now.c + 4 * extra, False)
    price_base(obj, grown.tuple(), change, instead)


def _with_duplicates(data):
    """A copy of curve data `data` with each spline's selected points added
    again as a spline of their own, as Duplicate makes them (a run of
    selected points becomes one; the spline's own settings kept)."""
    copy = data.copy()
    for spline in list(data.splines):
        bezier = spline.type == 'BEZIER'
        points = spline.bezier_points if bezier else spline.points
        chosen = [p for p in points if (p.select_control_point if bezier else p.select)]
        if not chosen:
            continue
        made = copy.splines.new(spline.type)
        for key in _SPLINE_KEYS:
            if key.startswith('use_cyclic'):
                continue
            try:
                setattr(made, key, getattr(spline, key))
            except (AttributeError, TypeError, ValueError):
                pass
        if bezier:
            made.bezier_points.add(len(chosen) - 1)
            for a, b in zip(chosen, made.bezier_points):
                b.co, b.handle_left, b.handle_right = a.co, a.handle_left, a.handle_right
                b.radius, b.tilt = a.radius, a.tilt
        else:
            made.points.add(len(chosen) - 1)
            for a, b in zip(chosen, made.points):
                b.co, b.radius, b.tilt = a.co, a.radius, a.tilt
    return copy


def price_curve_duplicate(**_):
    """A curve's Edit Mode Duplicate (`curve.duplicate_move`, `curve.duplicate`):
    the selected points copied into splines of their own, which take the
    curve's bevel and its stack — built, as Blender would build them, and
    priced through the stack (round 4's second fix-round review: a curve with
    Bevel Depth 0.05 under two Arrays of 64, 425,984 vertices, Duplicated from
    the search four times to 2,129,920 and a sixth past the budget, with
    nothing refused). A surface's patches are counted by the bound."""
    if not _is_real_blender():
        return
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if obj is None or obj.type not in ('CURVE', 'SURFACE') or obj.mode != 'EDIT':
        return
    obj = _geometry_object(obj)
    total, chosen = _curve_selection(obj)
    if not chosen:
        return
    change = "Duplicate with %d selected point%s" % (chosen, "" if chosen == 1 else "s")
    if obj.type == 'SURFACE':
        _price_curve_points(obj, chosen, change, "Select fewer points.")
        return
    s = Prices()
    try:
        duplicated = _with_duplicates(obj.data)
        s._curves.append(duplicated)
        s.change(obj, 'data', duplicated)
        s.synthetic.add(_pointer(obj))
        _judge([obj] + [o for o in affected([obj], s) if o != obj], s, change, "Select fewer points.")
    finally:
        s.close()


# The points Add ▸ Curve's and Add ▸ Surface's primitives make, by their own
# operators' defaults (measured in desktop 5.2.1: a Bézier curve 2, a circle
# 4, a NURBS curve and circle 4 and 8, a path 5; a NURBS surface's patch 16,
# its sphere 40, torus 72).
_CURVE_PRIMITIVE_POINTS = {
    'curve.primitive_bezier_curve_add': 2, 'curve.primitive_bezier_circle_add': 4,
    'curve.primitive_nurbs_curve_add': 4, 'curve.primitive_nurbs_circle_add': 8,
    'curve.primitive_nurbs_path_add': 5, 'surface.primitive_nurbs_surface_curve_add': 4,
    'surface.primitive_nurbs_surface_circle_add': 8, 'surface.primitive_nurbs_surface_surface_add': 16,
    'surface.primitive_nurbs_surface_cylinder_add': 32, 'surface.primitive_nurbs_surface_sphere_add': 40,
    'surface.primitive_nurbs_surface_torus_add': 72,
}


def price_curve_primitive(path, **_):
    """Add ▸ Curve or Surface in that curve's or surface's Edit Mode, where
    Blender adds the primitive's points to the edited data, under its
    resolutions, bevel and stack (an Edit Mode add is not a new object)."""
    if not _is_real_blender():
        return
    obj = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if obj is None or obj.type not in ('CURVE', 'SURFACE') or obj.mode != 'EDIT':
        return
    added = _CURVE_PRIMITIVE_POINTS.get(path, 0)
    if added:
        _price_curve_points(obj, added, _operator_name(path) + " in Edit Mode", "Lower what the curve's modifiers make.")


def price_extrude_to_cursor():
    """Mesh ▸ Vertex ▸ Extrude to Cursor or Add (`_blenderkit_meshmenu.to_cursor`,
    the app's own bmesh code, which no operator wraps): first each edited
    mesh's own vertices after it, at most its selection again — or, with
    nothing selected, one vertex — refused past the budget before the mesh is
    touched; what the stack then makes of it is priced exactly by the gate's
    Edit Mode transaction around the code (`_blenderkit_gate.editing`).
    Round 4's second fix-round review: Suzanne under Subdivision 5, 504,482,
    Select All and three presses, 4,202,512 with nothing refused."""
    if not _is_real_blender():
        return
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or ())
    for obj in objects:
        if obj.type != 'MESH' or obj.mode != 'EDIT':
            continue
        V, E, F, C, vs, es, fs, cs, cv = _edit_selection(obj)
        refuse_count(obj, V + (vs if (vs or es or fs) else 1), "Extrude to Cursor or Add", "Select less.",
                     " before its modifiers")


# Multires Subdivide's time against Subdivision Surface's model of the same
# topology (`_limit_seconds`): measured in desktop 5.2.1 under load (a load
# average of 12), a UV sphere of 128 segments (two poles of 128 edges) 1.47 s,
# and of 256 15.2 s, where the model says 3.5 s and 39 s — 0.42 and 0.39 of it;
# its Quality setting is not Subdivision Surface's. Rounded up.
MULTIRES_TIME = 0.5


def price_multires_subdivide_time(obj, modifier):
    """Multires Subdivide's time: Blender builds the limit surface of the
    base mesh's topology for it as Subdivision Surface does (round 4's second
    fix-round review: on a 250-sided N-Gon it took 9.00 s, priced by its
    count alone), so it is held to SUBDIVISION_SECONDS by the same model
    (`_limit_seconds`, at the modifier's Quality)."""
    import numpy as np
    mesh = obj.data
    ends = np.empty(2 * len(mesh.edges), dtype=np.int32)
    totals = np.empty(len(mesh.polygons), dtype=np.int32)
    if len(ends):
        mesh.edges.foreach_get('vertices', ends)
    if len(totals):
        mesh.polygons.foreach_get('loop_total', totals)
    seconds = _limit_seconds(ends, totals, len(mesh.vertices)) * MULTIRES_TIME
    if seconds > SUBDIVISION_SECONDS:
        raise RuntimeError("Multires Subdivide: %s" % _subdivision_refusal(obj, modifier.name, seconds))


# --------------------------------------------------------------------------
# A frame change: what its animation sets, priced before Blender evaluates it
#
# Round 4's fix round priced every frame of the app's timeline from every
# F-curve of every object (`_animated_all`): 53–54 ms a frame with 3,000
# keyed empties, which took `anim.frame_set` from 67 to about 135 ms, and
# 42–75 ms with 200 keyed cubes under Subdivision 2 against Blender's own
# 1 ms. Most of what a frame sets reaches nothing the budget counts: an
# empty that nothing reads, a cube whose modifiers are the same wherever it
# is. So the frame is priced from a plan (`_FramePlan`), made once from the
# scene and kept until something other than a frame changes it: the F-curves
# and drivers that feed a priced input, evaluated each frame, and nothing
# else. A frame whose priced inputs hold the values Blender holds now is not
# priced at all.

# An object's own channels that place it (and their deltas).
_PLACE_CHANNELS = frozenset(('location', 'rotation_euler', 'rotation_quaternion', 'rotation_axis_angle',
                             'scale', 'delta_location', 'delta_rotation_euler', 'delta_rotation_quaternion',
                             'delta_scale'))
# An object's settings the model never reads: how it is drawn.
_UNREAD = frozenset(('color', 'empty_display_size', 'empty_display_type', 'display_type', 'hide_select',
                     'pass_index'))
# Modifier kinds whose count, time and memory are made in their object's own
# space: where the object is in the world changes none of them, as long as
# they read no other object (an Array's offset object, caps or curve, a
# Mirror's object, a Screw's axis object). Every other kind — a Boolean, a
# Hook, a Shrinkwrap, a Displace in global coordinates, Geometry Nodes, a
# simulation — makes its object's place a priced input, and so do a
# metaball's family and particle systems.
_PLACE_FREE = frozenset(('SUBSURF', 'MULTIRES', 'SOLIDIFY', 'BEVEL', 'TRIANGULATE', 'DECIMATE', 'WELD',
                         'EDGE_SPLIT', 'WIREFRAME', 'REMESH', 'SMOOTH', 'LAPLACIANSMOOTH',
                         'CORRECTIVE_SMOOTH', 'SKIN', 'MASK', 'BUILD', 'WEIGHTED_NORMAL', 'ARRAY', 'MIRROR',
                         'SCREW', 'VERTEX_WEIGHT_EDIT', 'VERTEX_WEIGHT_MIX', 'UV_WARP', 'OCEAN'))
# Blender's frames run from -1,048,574 to 1,048,574 (MINAFRAME, MAXFRAME): a
# linear extrapolation is bounded there.
_FRAME_LIMIT = 1048574.0
# How far from the world's origin a frame may take a vertex of an object
# whose place nothing else reads before that place is priced on each frame:
# a thousandth of REACH, the farthest the price lets a vertex go. Inside it no
# frame can be refused for its reach.
STATIC_REACH = REACH / 1000.0
# Interpolations whose curve stays within its keys' and handles' values: a
# Bézier segment within its four control points, each easing between its two
# keys. Back, Elastic and Bounce overshoot them.
_STEADY = ('CONSTANT', 'LINEAR', 'BEZIER', 'SINE', 'QUAD', 'CUBIC', 'QUART', 'QUINT', 'EXPO', 'CIRC')

_plan = None
_plan_handlers = False


class _Stale(Exception):
    """The plan names an F-curve, a driver or a data-block that is gone."""


class _Unknown(Exception):
    """A driver whose value cannot be worked out ahead of Blender."""


class _Later(Exception):
    """A driver that reads one not worked out yet this frame."""


class FrameRefused(RuntimeError):
    """A frame the plan refuses in words before anything is counted (drivers
    that read each other, see `_FramePlan.cycles`)."""


class _Entry:
    """One animated value of a data-block: where it is, what kind of number,
    and whether it is priced (or only read by a driver that is). `key` is
    the value's own place, the data-block that holds it and its path from
    there (`_target_key`), which is how a driver's variable finds it
    whatever path it reads it by. `low`, `high`: RNA's hard range, which
    Blender clamps a keyed value to (`_number`). `slot`: where its F-curve
    was in its channel bag when the plan was made (`_FramePlan.changes`)."""
    __slots__ = ('path', 'index', 'head', 'name', 'kind', 'is_array', 'priced', 'key', 'items', 'low', 'high',
                 'slot')

    def __init__(self, block, path, index, head, name, prop, priced, keys=None):
        self.path, self.index, self.head, self.name = path, index, head, name
        self.kind = prop.type if prop is not None else 'FLOAT'
        self.is_array = bool(getattr(prop, 'is_array', False)) if prop is not None else False
        self.priced = priced
        self.key = _target_key(block, path, index, keys)
        self.items = ({item.value: item.identifier for item in prop.enum_items}
                      if prop is not None and prop.type == 'ENUM' else None)
        self.low = self.high = None
        if prop is not None and prop.type in ('INT', 'FLOAT'):
            self.low, self.high = prop.hard_min, prop.hard_max
        self.slot = -1


class _FramePlan:
    """What a frame change is priced from (see the note above)."""

    def __init__(self, scene):
        self.scene = _pointer(scene)
        self.curves = []          # (block, [_Entry]) evaluated each frame
        self.drivers = []         # (block, _Entry) worked out each frame
        self.driven = set()       # their keys
        self.unpriced = []        # (block name, path): drivers no price can work out ahead
        # What only Blender's own evaluation of the frame says, read from it
        # with the modifiers that make more hidden (`probe_values`): (block,
        # [path]) of an NLA's strips and of drivers no price can work out.
        self.probed = []
        self.left_out = 0         # F-curves and drivers that feed no priced input
        self.objects = {}         # a data-block's pointer -> the counted objects its values reach
        # Drivers that read each other (and the drivers that read one of
        # those), which reach a priced value: (block, _Entry, whether one
        # reads the frame, the keys they read). Blender does not break such a
        # cycle: it works each driver out from the others' last values every
        # time it evaluates them, so what they set changes on every frame.
        # Round 4's fix round 2 review, desktop 5.2.1, budget 100,000: Count
        # = n * 2 + frame * 0 and ["n"] = Count + frame * 0 passed frames 2
        # to 19 while Blender went from 256 to 33,554,432 vertices, because
        # the plan listed both as priced and broke off working them out.
        self.cycles = []
        # A variable's or an F-curve's path to the data-block that holds the
        # value and its path there, worked out once a plan (`_target_key`).
        self.keys = {}
        # The data-blocks whose values now a static bound was made from
        # (`_static_reach`, `_pose_reach`): a change to them makes the plan
        # again (`note_pending`).
        self.static = set()
        self.failed = []

    @property
    def live(self):
        return bool(self.curves or self.drivers or self.probed or self.cycles)

    def changes(self, t, scene=None):
        """(owner, property, value) of every priced value the frame at `t`
        sets to something other than what Blender holds now."""
        when = _when(scene, t)
        ct = when[1]
        values = {}
        found = {}
        owners = {}
        # Priced drivers this frame could not work out after all (a division
        # by zero, a target gone, or reading one of those): read from
        # Blender's own evaluation of the frame (`_frame_changes`).
        self.failed = []
        for block, entries in self.curves:
            bag = _bag_of(block)
            fcurves = bag.fcurves
            n = len(fcurves)
            for e in entries:
                # Where the plan found it, checked; searched for only when it
                # moved. `find` is a walk of the bag: with 3,000 keyed bone
                # channels in one bag, finding each every frame took 12.6 ms
                # of a 14.6 ms price, and twice the bones 37.5 ms (round 4's
                # fix round 2 review, desktop 5.2.1). The F-curve itself is
                # never kept from one frame to the next: one removed would be
                # freed memory, where a path that finds nothing is a stale plan.
                curve = fcurves[e.slot] if 0 <= e.slot < n else None
                if curve is None or curve.array_index != e.index or curve.data_path != e.path:
                    curve = fcurves.find(e.path, index=e.index)
                    if curve is None:
                        raise _Stale(e.path)
                # At the scene's time, the frame through Time Stretching
                # (`_when`), as Blender evaluates its animation.
                value = curve.evaluate(ct)
                # As Blender stores it, which is what a driver reading it reads.
                try:
                    values[e.key] = (float(_number(e, value, True)) if e.kind in ('INT', 'BOOLEAN')
                                     else _number(e, value, True) if e.kind == 'FLOAT' else value)
                except _Unknown:
                    values[e.key] = value
                if e.priced:
                    _lay(found, block, e, value, curve=True, owners=owners)
        if self.cycles:
            for block, e, timed, inputs in self.cycles:
                if timed or any(k in values or k in self.driven for k in inputs):
                    raise FrameRefused(_cycle_words(block, e))
        if self.drivers:
            waiting = list(self.drivers)
            while waiting:
                later = []
                for block, e in waiting:
                    try:
                        value = _driver_value(block, e, when, values, self.driven, self.keys)
                    except _Later:
                        later.append((block, e))
                        continue
                    except _Unknown:
                        if e.priced:
                            self.failed.append((block, e))
                        continue
                    # As Blender stores it (cut toward zero, clamped), which
                    # is what a driver reading it reads.
                    try:
                        values[e.key] = (float(_number(e, value, False)) if e.kind in ('INT', 'BOOLEAN', 'FLOAT')
                                         else value)
                    except _Unknown:
                        values[e.key] = value
                    if e.priced:
                        _lay(found, block, e, value, curve=False, owners=owners)
                if len(later) == len(waiting):
                    # The plan takes drivers that read each other out
                    # (`cycles`): these read one that failed above.
                    self.failed.extend((block, e) for block, e in later if e.priced)
                    break
                waiting = later
        changes = _changed(found)
        reached = {}
        for owner, name, value in changes:
            try:
                objects = self.objects.get(_pointer(owner.id_data))
            except (AttributeError, ReferenceError):
                objects = None
            if objects is None:
                return changes, None      # judged by `affected`, as any other change
            for o in objects:
                reached[_pointer(o)] = o
        return changes, list(reached.values())


def _bag_of(block):
    try:
        ad = block.animation_data
    except ReferenceError:
        raise _Stale(block) from None
    if ad is None:
        raise _Stale(block)
    from bpy_extras import anim_utils
    action, slot = ad.action, ad.action_slot
    bag = None
    if action is not None and slot is not None:
        try:
            bag = anim_utils.action_get_channelbag_for_slot(action, slot)
        except (AttributeError, RuntimeError, TypeError):
            bag = None
    if bag is None:
        raise _Stale(block)
    return bag


def _number(e, value, curve):
    if e.kind == 'INT':
        if not math.isfinite(value):
            if e.low is None or value != value:
                raise _Unknown(e.path)
            return int(e.high if value > 0 else e.low)
        # An integer property's F-curve evaluates to whole numbers already
        # (Blender rounds it); a driver's value is cut to one toward zero
        # (measured in desktop 5.2.1: a driver at 3.75 set an Array's Count
        # to 3, at 7.6 to 7).
        return _within(e, int(math.ceil(value)) if curve else int(value))
    if e.kind == 'BOOLEAN':
        return value > 0.5 if curve else bool(int(value))
    if e.kind == 'ENUM':
        item = e.items.get(int(value)) if e.items else None
        if item is None:
            raise _Unknown(e.path)
        return item
    return _within(e, float(value))


def _within(e, number):
    """`number` as Blender stores it: clamped to RNA's hard range. Round 4's
    fix round 2 review, desktop 5.2.1: an Array's Count keyed to 0 is held
    at 1, and compared unclamped it read as a change on every frame, each
    priced (about 125 ms a frame after a 200 × 200 Boolean) while the Count
    stayed 1."""
    if e.low is not None and number < e.low:
        return type(number)(e.low)
    if e.high is not None and number > e.high:
        return type(number)(e.high)
    return number


def _when(scene, t):
    """(the frame `t`, the time Blender evaluates animation at, the scene's
    pointer). With Time Stretching Blender evaluates the frame at `t` × Map
    Old / Map New (`BKE_scene_frame_to_ctime`: measured in desktop 5.2.1,
    Map Old 100 and Map New 1 at frame 5, a driver's `frame` read 500 and
    `frame_current_final` 500.0). Round 4's fix round 2 review: a Count keyed
    20,000 at 500 passed frame 5, priced at frame 5's keys, and Blender built
    160,000 against a budget of 100,000."""
    if scene is None:
        scene = bpy.context.scene
    ct = t
    try:
        render = scene.render
        p = _pointer(scene)
        old, new = _stretch_laid.get(p) or (render.frame_map_old, render.frame_map_new)
        if old != new and new > 0:
            ct = t * old / new
    except (AttributeError, ReferenceError):
        p = None
    return (t, ct, p)


# A Time Stretching a price lays over a scene's own before it is written
# (`price_all`, `_stretched`): scene pointer -> (Map Old, Map New).
_stretch_laid = {}


class _stretched:
    """The Time Stretching `old`, `new` laid over `scene` for a price, the
    frame plan made for it and dropped after."""

    def __init__(self, scene, old, new):
        self.p, self.value = _pointer(scene), (int(old), int(new))

    def __enter__(self):
        _stretch_laid[self.p] = self.value
        drop_plan()
        return self

    def __exit__(self, *exc):
        _stretch_laid.pop(self.p, None)
        drop_plan()
        return False


def _price_stretch(changes):
    """A change of the context scene's Time Stretching (Map Old, Map New)
    priced as the frame it holds evaluated at its new time (see the gate's
    `_diff`): the Data API row sets it, and the gate lets a value its price
    passed through."""
    scene = bpy.context.scene
    if scene is None:
        return
    laid = {}
    for owner, key, value in changes:
        if key in ('frame_map_old', 'frame_map_new') and isinstance(owner, bpy.types.RenderSettings):
            try:
                if owner.id_data != scene:
                    continue
                laid[key] = int(value)
            except (AttributeError, ReferenceError, TypeError, ValueError):
                continue
    if not laid:
        return
    render = scene.render
    old = laid.get('frame_map_old', render.frame_map_old)
    new = laid.get('frame_map_new', render.frame_map_new)
    old, new = (_clamped(render, 'frame_map_old', old), _clamped(render, 'frame_map_new', new))
    if (old, new) == (render.frame_map_old, render.frame_map_new):
        return
    with _stretched(scene, old, new):
        price_frame(scene.frame_current, scene.frame_subframe, approve=False)


def _time_stretch(scene=None):
    """Map Old / Map New of `scene` (1 without Time Stretching)."""
    return _when(scene, 1.0)[1]


def _cycle_words(block, e):
    return ("%s's driver on %s reads a driver that reads it back, and Blender works such drivers out "
            "from each other's last values every time it evaluates them, so what they set grows or "
            "changes on every frame and cannot be priced ahead (measured in desktop 5.2.1: Count = n × 2 "
            "and n = Count doubled the Count on every frame). Break the cycle: a driver may not read what "
            "it drives, directly or through other drivers" % (getattr(block, 'name', 'A data-block'), e.path))


def _lay(found, block, e, value, curve, owners=None):
    try:
        if not e.head:
            owner = block
        elif owners is not None:
            # One resolve a struct a frame: a bone's ten channels share it.
            memo = (_pointer(block), e.head)
            owner = owners.get(memo)
            if owner is None:
                owner = owners[memo] = block.path_resolve(e.head)
        else:
            owner = block.path_resolve(e.head)
    except (ValueError, ReferenceError, AttributeError) as why:
        raise _Stale(e.path) from why
    try:
        number = _number(e, value, curve)
    except _Unknown:
        return
    key = (_pointer(owner), e.name)
    if e.is_array:
        if key not in found:
            found[key] = [owner, e.name, list(getattr(owner, e.name))]
        vector = found[key][2]
        if 0 <= e.index < len(vector):
            vector[e.index] = number
    else:
        found[key] = [owner, e.name, number]


def _single(value):
    """`value` as Blender stores a float: in single precision."""
    from array import array
    try:
        return array('f', [value])[0]
    except (OverflowError, TypeError):
        return value


def _same_number(new, now):
    if isinstance(new, float):
        if not isinstance(now, (int, float)):
            return False
        return _single(new) == now
    return new == now


def _changed(found):
    out = []
    for owner, name, value in found.values():
        now = getattr(owner, name)
        if isinstance(value, list):
            now = list(now)
            if len(now) == len(value) and all(_same_number(a, b) for a, b in zip(value, now)):
                continue
            out.append((owner, name, tuple(value)))
        else:
            if _same_number(value, now):
                continue
            out.append((owner, name, value))
    return out


# -- what a driver works out to ----------------------------------------------

_DRIVER_CALLS = {name: getattr(math, name) for name in (
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2', 'sinh', 'cosh', 'tanh', 'exp', 'log', 'log10',
    'log2', 'sqrt', 'floor', 'ceil', 'trunc', 'fabs', 'fmod', 'radians', 'degrees', 'pow', 'hypot',
    'copysign')}
_DRIVER_CALLS.update(abs=abs, min=min, max=max, round=round, int=int, float=float, bool=bool,
                     clamp=lambda x, a=0.0, b=1.0: min(max(x, a), b),
                     lerp=lambda a, b, t: a + (b - a) * t,
                     smoothstep=lambda a, b, x: (lambda t: t * t * (3.0 - 2.0 * t))(
                         min(max((x - a) / (b - a), 0.0), 1.0)) if b != a else float(x >= b))
_DRIVER_NAMES = {'pi': math.pi, 'e': math.e, 'tau': math.tau, 'True': 1.0, 'False': 0.0}
_EXPRESSIONS = {}
_BINARY = {_ast.Add: lambda a, b: a + b, _ast.Sub: lambda a, b: a - b, _ast.Mult: lambda a, b: a * b,
           _ast.Div: lambda a, b: a / b, _ast.FloorDiv: lambda a, b: a // b, _ast.Mod: lambda a, b: a % b,
           _ast.Pow: lambda a, b: math.pow(a, b)}
_COMPARE = {_ast.Lt: lambda a, b: a < b, _ast.LtE: lambda a, b: a <= b, _ast.Gt: lambda a, b: a > b,
            _ast.GtE: lambda a, b: a >= b, _ast.Eq: lambda a, b: a == b, _ast.NotEq: lambda a, b: a != b}


def _parsed(expression):
    """A driver's expression as a tree of the arithmetic Blender's own
    simple expressions allow (numbers, its variables, `frame`, operators,
    comparisons, `if`/`else` and math functions), or None: anything else is
    Python only Blender may run, and is not worked out ahead."""
    if expression in _EXPRESSIONS:
        return _EXPRESSIONS[expression]
    try:
        tree = _ast.parse(expression.strip(), mode='eval')
    except (SyntaxError, ValueError):
        tree = None
    if tree is not None:
        for node in _ast.walk(tree):
            if isinstance(node, (_ast.Expression, _ast.BinOp, _ast.UnaryOp, _ast.BoolOp, _ast.Compare,
                                 _ast.IfExp, _ast.Name, _ast.Load, _ast.operator, _ast.unaryop,
                                 _ast.boolop, _ast.cmpop)):
                continue
            if isinstance(node, _ast.Constant) and isinstance(node.value, (int, float)) \
                    and not isinstance(node.value, bool):
                continue
            if isinstance(node, _ast.Call) and isinstance(node.func, _ast.Name) \
                    and node.func.id in _DRIVER_CALLS and not node.keywords:
                continue
            tree = None
            break
        if tree is not None and any(isinstance(n, _ast.BinOp) and type(n.op) not in _BINARY
                                    for n in _ast.walk(tree)):
            tree = None
    if len(_EXPRESSIONS) < 4096:
        _EXPRESSIONS[expression] = tree
    return tree


def _run(node, names):
    if isinstance(node, _ast.Expression):
        return _run(node.body, names)
    if isinstance(node, _ast.Constant):
        return float(node.value)
    if isinstance(node, _ast.Name):
        if node.id in names:
            return names[node.id]
        if node.id in _DRIVER_NAMES:
            return _DRIVER_NAMES[node.id]
        raise _Unknown(node.id)
    if isinstance(node, _ast.BinOp):
        return float(_BINARY[type(node.op)](_run(node.left, names), _run(node.right, names)))
    if isinstance(node, _ast.UnaryOp):
        value = _run(node.operand, names)
        if isinstance(node.op, _ast.USub):
            return -value
        if isinstance(node.op, _ast.Not):
            return float(not value)
        return +value
    if isinstance(node, _ast.BoolOp):
        values = [_run(v, names) for v in node.values]
        if isinstance(node.op, _ast.And):
            return next((v for v in values if not v), values[-1])
        return next((v for v in values if v), values[-1])
    if isinstance(node, _ast.Compare):
        left = _run(node.left, names)
        for op, right_node in zip(node.ops, node.comparators):
            right = _run(right_node, names)
            if not _COMPARE[type(op)](left, right):
                return 0.0
            left = right
        return 1.0
    if isinstance(node, _ast.IfExp):
        return _run(node.body, names) if _run(node.test, names) else _run(node.orelse, names)
    if isinstance(node, _ast.Call):
        return float(_DRIVER_CALLS[node.func.id](*[_run(a, names) for a in node.args]))
    raise _Unknown(type(node).__name__)


def _split_path(path):
    """(head, name) of an RNA path: the struct and the property in it. A
    custom property's name is its brackets (`["n"]`), dots in it included."""
    if path.endswith('"]'):
        i = path.rfind('["')
        if i >= 0:
            head = path[:i]
            return (head[:-1] if head.endswith('.') else head), path[i:]
    head, dot, name = path.rpartition('.')
    if not dot:
        return '', path
    return head, name


def _target_key(idblock, path, index=None, keys=None):
    """(the pointer of the data-block that holds the value, its path from
    that data-block, its index): where an F-curve, a driver or a driver's
    variable puts or reads a value, whatever path it takes there.
    `location[0]` is `location` at 0; `parent.location[0]` on a cube is the
    parent's `location` at 0; `modifiers[0].count` is
    `modifiers["Array"].count`. Round 4's fix round 2 review, desktop 5.2.1,
    budget 100,000: a Count driver reading `parent.location[0]`, with the
    parent's X keyed to 20,000, and one reading `modifiers[0].count` of a
    keyed Array, ×20, each passed frame 10 and Blender built 160,000 — they
    were keyed by their own path, never found among the F-curves' values,
    and read as Blender held them on the frame it was leaving. `keys`: a
    cache (the plan's)."""
    memo = (_pointer(idblock), path, index)
    if keys is not None:
        found = keys.get(memo)
        if found is not None:
            return found
    import re
    whole, i = path, index
    if index is None:
        i = 0
        match = re.match(r'^(.*)\[(\d+)\]$', path)
        if match:
            try:
                value = idblock.path_resolve(match.group(1))
                if hasattr(value, '__len__') and not isinstance(value, str):
                    whole, i = match.group(1), int(match.group(2))
            except (ValueError, AttributeError, TypeError, ReferenceError):
                pass
    key = (_pointer(idblock), whole, i)
    head, name = _split_path(whole)
    if head:
        try:
            owner = idblock.path_resolve(head)
            holder = owner.id_data
            if holder is not None:
                own = owner.path_from_id() if holder != owner else ''
                joined = (own + name if name.startswith('[') else own + '.' + name) if own else name
                key = (_pointer(holder), joined, i)
        except (ValueError, AttributeError, TypeError, ReferenceError, RuntimeError):
            pass
    if keys is not None and len(keys) < 65536:
        keys[memo] = key
    return key


# A scene's frame, as a driver's variable reads it while Blender evaluates the
# frame: the frame being evaluated, not the one it is leaving. Round 4's fix
# round 2 review, desktop 5.2.1, budget 100,000: a Count driver of `f × 2000`,
# f = the scene's `frame_current`, passed frame 1 → 10 priced at frame 1's
# 2,000, and Blender went from 16,000 to 160,000 vertices; the same through a
# Context Property.
_FRAME_PROPS = frozenset(('frame_current', 'frame_subframe', 'frame_float', 'frame_current_final'))


def _frame_value(source, path, when):
    if when is None or path not in _FRAME_PROPS or not isinstance(source, bpy.types.Scene):
        return None
    t, ct, scene = when
    if scene is not None and _pointer(source) != scene:
        return None
    if path == 'frame_current':
        return float(math.floor(t))
    if path == 'frame_subframe':
        return t - math.floor(t)
    if path == 'frame_float':
        return t
    return ct


def _derived_path(path):
    """Whether a driver variable's path reads what Blender derives in its
    evaluation (`_DERIVED`: a matrix, Dimensions, a bound box, a pose's
    head and tail), which the original holds as Blender last evaluated it."""
    last = (path or '').rpartition('.')[2].split('[')[0]
    return last in _DERIVED


def _variable_value(var, values, driven, when=None, keys=None):
    kind = var.type
    target = var.targets[0]
    if kind == 'SINGLE_PROP':
        idblock, path = target.id, target.data_path
        if idblock is None or not path:
            raise _Unknown(var.name)
        frame = _frame_value(idblock, path, when)
        if frame is not None:
            return frame
        key = _target_key(idblock, path, None, keys)
        if key in values:
            return float(values[key])
        if key in driven:
            raise _Later(var.name)
        if _derived_path(path):
            # The original's matrix_world or Dimensions are what Blender last
            # evaluated, not what the change will make: only Blender's own
            # evaluation says (`probe_values`). Fix round 3's review (October
            # 29), sandboxed desktop 5.2.1 with the app's context: A's Count
            # driven by x * 40,000 + 2, x = E's `matrix_world[3][0]`; the Data
            # API row's Location (10, 0, 0), a script line `E.location.x = 10`
            # and `transform.translate(value=(10, 0, 0))` each built A
            # 16 -> 3,200,016 with no refusal, priced at the old 0; Count =
            # x * 20,000 with x = T's `dimensions[0]`, the row's Scale (10, 1,
            # 1), a line and a Resize each built 320,000 -> 3,200,000.
            raise _Unknown(var.name)
        try:
            value = idblock.path_resolve(path)
        except (ValueError, AttributeError, TypeError):
            raise _Unknown(var.name) from None
    elif kind == 'CONTEXT_PROP':
        source = (bpy.context.scene if target.context_property == 'ACTIVE_SCENE' else bpy.context.view_layer)
        if source is None or not target.data_path:
            raise _Unknown(var.name)
        frame = _frame_value(source, target.data_path, when)
        if frame is not None:
            return frame
        if _derived_path(target.data_path):
            raise _Unknown(var.name)
        key = _target_key(source, target.data_path, None, keys)
        if key in values:
            return float(values[key])
        if key in driven:
            raise _Later(var.name)
        try:
            value = source.path_resolve(target.data_path)
        except (ValueError, AttributeError, TypeError):
            raise _Unknown(var.name) from None
    elif kind == 'TRANSFORMS':
        value = _transform_value(target, values, driven, keys)
    else:
        # Distances and rotation differences read places in the world, which
        # only Blender's evaluation of the frame gives.
        raise _Unknown(var.name)
    if isinstance(value, bool) or isinstance(value, (int, float)):
        return float(value)
    raise _Unknown(var.name)


def _transform_value(target, values, driven, keys=None):
    """A Transform Channel variable in Transform Space: the object's (or the
    pose bone's) own location or scale — the object's deltas with them, as
    Blender reads them (measured in desktop 5.2.1: Scale 2 with a Delta Scale
    of 3 read 6). Rotations, World Space and Local Space are not worked out
    ahead: they are what Blender's evaluation makes of the channels."""
    obj = target.id
    kind = target.transform_type
    if obj is None or target.transform_space != 'TRANSFORM_SPACE' or kind.startswith('ROT'):
        raise _Unknown(kind)
    bone = target.bone_target if getattr(obj, 'type', None) == 'ARMATURE' else ''
    if bone:
        owner = obj.pose.bones.get(bone)
        if owner is None:
            raise _Unknown(bone)
        prefix = 'pose.bones["%s"].' % bone
    else:
        owner, prefix = obj, ''
    base = (_pointer(obj),)

    def channel(name, i):
        key = base + (prefix + name, i)
        if key in values:
            return float(values[key])
        if key in driven:
            raise _Later(name)
        return float(getattr(owner, name)[i])

    if kind.startswith('LOC'):
        i = 'XYZ'.index(kind[-1])
        return channel('location', i) + (channel('delta_location', i) if not bone else 0.0)

    def scale(i):
        value = channel('scale', i) * (channel('delta_scale', i) if not bone else 1.0)
        if value <= 0:
            raise _Unknown('scale')    # a matrix's scale is read back as its length
        return value

    if kind == 'SCALE_AVG':
        return (scale(0) + scale(1) + scale(2)) / 3.0
    return scale('XYZ'.index(kind[-1]))


def _driver_value(block, e, when, values, driven, keys=None):
    """What the driver of `e` works out to at `when` (`_when`: a driver's
    `frame` is the time Blender evaluates animation at, through Time
    Stretching; measured in desktop 5.2.1, Map Old 100, Map New 1, frame 5:
    `frame` read 500)."""
    if not isinstance(when, tuple):
        when = _when(None, float(when))
    try:
        drivers = block.animation_data.drivers
        # Where the plan found it, checked, as an F-curve (`changes`).
        curve = drivers[e.slot] if 0 <= e.slot < len(drivers) else None
        if curve is None or curve.array_index != e.index or curve.data_path != e.path:
            curve = drivers.find(e.path, index=e.index)
    except (AttributeError, ReferenceError):
        raise _Stale(e.path) from None
    if curve is None:
        raise _Stale(e.path)
    driver = curve.driver
    if driver.use_self:
        raise _Unknown('self')
    numbers = [_variable_value(v, values, driven, when, keys) for v in driver.variables]
    kind = driver.type
    if kind == 'SCRIPTED':
        tree = _parsed(driver.expression)
        if tree is None:
            raise _Unknown(driver.expression)
        names = {v.name: n for v, n in zip(driver.variables, numbers)}
        names['frame'] = when[1]
        try:
            raw = _run(tree, names)
        except (ArithmeticError, ValueError, TypeError):
            raise _Unknown(driver.expression) from None
    elif not numbers:
        raw = 0.0
    elif kind == 'AVERAGE':
        raw = sum(numbers) / len(numbers)
    elif kind == 'SUM':
        raw = sum(numbers)
    elif kind == 'MIN':
        raw = min(numbers)
    elif kind == 'MAX':
        raw = max(numbers)
    else:
        raise _Unknown(kind)
    # The driver's F-curve maps its value: measured, `driver_add` gives it two
    # keys at (0, 0) and (1, 1), extrapolated, and Blender's own value is the
    # curve's at the driver's. Modifiers with no keys work on the driver's
    # value, which `evaluate` does not take: not worked out ahead.
    if len(curve.keyframe_points):
        raw = curve.evaluate(raw)
    elif len(curve.modifiers):
        raise _Unknown('modifiers')
    return raw


_DERIVED = frozenset(('matrix_world', 'matrix_local', 'matrix_basis', 'matrix_parent_inverse', 'dimensions',
                      'bound_box', 'matrix', 'matrix_channel', 'head', 'tail', 'length', 'vector', 'center',
                      'normal', 'area'))


def _driver_computable(block, curve):
    """Whether a driver's value can be worked out ahead (`_driver_value`),
    as far as its settings say."""
    driver = curve.driver
    if driver.use_self or driver.type not in ('AVERAGE', 'SUM', 'MIN', 'MAX', 'SCRIPTED'):
        return False
    if driver.type == 'SCRIPTED' and _parsed(driver.expression) is None:
        return False
    if not len(curve.keyframe_points) and len(curve.modifiers):
        return False
    for var in driver.variables:
        target = var.targets[0]
        if var.type in ('SINGLE_PROP', 'CONTEXT_PROP'):
            # What Blender derives in its evaluation (a matrix, Dimensions, a
            # bound box) is the frame's only once Blender has evaluated it.
            last = (target.data_path or '').rpartition('.')[2].split('[')[0]
            if last in _DERIVED:
                return False
            continue
        if var.type == 'TRANSFORMS' and target.transform_space == 'TRANSFORM_SPACE' \
                and not target.transform_type.startswith('ROT'):
            continue
        return False
    return True


# -- the plan ---------------------------------------------------------------

def _targets_of(constraint):
    found = []
    for key in _TARGET_KEYS:
        target = getattr(constraint, key, None)
        if isinstance(target, bpy.types.Object):
            found.append(target)
    for t in getattr(constraint, 'targets', ()) or ():
        if getattr(t, 'target', None) is not None:
            found.append(t.target)
    return found


def _reads_place(obj):
    """Whether what `obj` evaluates to depends on where it is (see
    `_PLACE_FREE`)."""
    if obj.type == 'META' or len(getattr(obj, 'particle_systems', ())):
        return True
    for m in obj.modifiers:
        if m.type not in _PLACE_FREE:
            return True
        if any(getattr(m, identifier, None) is not None for identifier, _ in _pointer_props(m)):
            return True
    return False


def _curve_bound(curve):
    """The largest magnitude `curve` takes at any frame, or inf where its
    keys do not bound it (a modifier, an easing that overshoots)."""
    if len(curve.modifiers):
        return math.inf
    points = curve.keyframe_points
    n = len(points)
    if not n:
        return 0.0
    steady = _steady_names()
    if n <= 8:
        # Read point by point: four bulk reads of a two-key curve cost more
        # than its six numbers (desktop 5.2.1, 3,000 keyed cubes: the plan's
        # bounds took 158 ms of its 521 under cProfile at a load of 300).
        found = 0.0
        for point in points:
            if point.interpolation not in steady:
                return math.inf
            found = max(found, abs(point.co[1]), abs(point.handle_left[1]), abs(point.handle_right[1]))
        if curve.extrapolation == 'LINEAR':
            limit = _FRAME_LIMIT * max(1.0, _time_stretch())
            found = max(found, abs(curve.evaluate(limit)), abs(curve.evaluate(-limit)))
        return found if math.isfinite(found) else math.inf
    import numpy as np
    values = np.empty(2 * n, dtype=np.float64)
    found = 0.0
    for field in ('co', 'handle_left', 'handle_right'):
        points.foreach_get(field, values)
        found = max(found, float(np.abs(values[1::2]).max()))
    kinds = np.empty(n, dtype=np.int32)
    points.foreach_get('interpolation', kinds)
    steady = _steady_values()
    if any(k not in steady for k in set(kinds.tolist())):
        return math.inf
    if curve.extrapolation == 'LINEAR':
        # Through Time Stretching the frames reach further on the curve.
        limit = _FRAME_LIMIT * max(1.0, _time_stretch())
        found = max(found, abs(curve.evaluate(limit)), abs(curve.evaluate(-limit)))
    return found if math.isfinite(found) else math.inf


_STEADY_VALUES = None


def _steady_names():
    return _STEADY


def _steady_values():
    global _STEADY_VALUES
    if _STEADY_VALUES is None:
        items = bpy.types.Keyframe.bl_rna.properties['interpolation'].enum_items
        _STEADY_VALUES = frozenset(items[name].value for name in _STEADY if name in items)
    return _STEADY_VALUES


def _static_reach(obj, bounds):
    """How far from the world's origin a vertex of `obj` can get at any
    frame: its extent now, through its own channels and each parent's at the
    most their F-curves reach (`bounds`, by (object pointer, channel, index);
    inf for a driven channel) and the parents' inverse matrices. Inf where a
    constraint or a parent other than an object places it."""
    try:
        x = math.sqrt(3.0) * max((abs(v) for corner in obj.bound_box for v in corner), default=0.0)
    except (AttributeError, TypeError, ReferenceError):
        return math.inf
    o, depth = obj, 0
    while o is not None:
        if len(o.constraints) or depth > CHAIN_DEPTH:
            return math.inf
        p = _pointer(o)

        def top(name, i, now):
            return max(abs(now), bounds.get((p, name, i), 0.0))

        scale = max(top('scale', i, o.scale[i]) for i in range(3)) * \
            max(top('delta_scale', i, o.delta_scale[i]) for i in range(3))
        move = math.sqrt(sum((top('location', i, o.location[i]) + top('delta_location', i, o.delta_location[i])) ** 2
                             for i in range(3)))
        x = x * scale + move
        parent = o.parent
        if parent is not None:
            if o.parent_type != 'OBJECT':
                return math.inf
            inverse = o.matrix_parent_inverse
            norm = math.sqrt(sum(inverse[r][c] ** 2 for r in range(3) for c in range(3)))
            x = x * norm + math.sqrt(sum(inverse[r][3] ** 2 for r in range(3)))
        if not math.isfinite(x):
            return math.inf
        o, depth = parent, depth + 1
    return x


# A pose bone's channels: where it is, how it turns, its size.
_POSE_CHANNELS = frozenset(('location', 'rotation_euler', 'rotation_quaternion', 'rotation_axis_angle', 'scale'))


def _modifier_trees(obj):
    """The node groups `obj`'s Geometry Nodes modifiers run, with every group
    used inside them."""
    found = {}
    stack = [m.node_group for m in getattr(obj, 'modifiers', ()) if m.type == 'NODES' and m.node_group is not None]
    while stack:
        tree = stack.pop()
        p = _pointer(tree)
        if p in found:
            continue
        found[p] = tree
        for node in tree.nodes:
            inner = getattr(node, 'node_tree', None)
            if inner is not None:
                stack.append(inner)
    return list(found.values())


def _frobenius(matrix):
    return math.sqrt(sum(v * v for row in matrix for v in row))


def _pose_reach(arm, items, objects):
    """How far from the world's origin a vertex the armature `arm` deforms
    can get at any frame, from the most its bones' keyed channels reach
    (`items`, (block, F-curve, entry, is_driver)) and their values now. Down
    each bone's chain of parents: the scales multiplied (each at least 1),
    and the locations and rest places (head and tail) added, each times the
    scale above it; a vertex of the deformed objects (their extent now,
    `objects`, the counted ones read) times its bone's scale on top; all
    through the armature's matrix and its inverse (Frobenius norms, an
    upper bound of each map). Rotations move nothing farther. Inf where a
    channel's keys do not bound it."""
    scales = {}
    moves = {}
    for block, curve, entry, is_driver in items:
        if entry.name not in ('location', 'scale'):
            continue
        bound = _curve_bound(curve)
        if not math.isfinite(bound):
            return math.inf
        table = moves if entry.name == 'location' else scales
        table[entry.head] = max(table.get(entry.head, 0.0), bound)
    try:
        world = arm.matrix_world
        to_world, to_rig = _frobenius(world), _frobenius(world.inverted_safe())
        extent = 0.0
        for o in objects:
            if o.type not in COUNTED_TYPES:
                continue
            corner = math.sqrt(3.0) * max((abs(v) for c in o.bound_box for v in c), default=0.0)
            extent = max(extent, _frobenius(o.matrix_world) * (corner + 1.0))
        vertex = to_rig * (extent + 1.0)
        grown, reached = {}, {}
        farthest = 0.0
        for bone in arm.pose.bones:
            chain = []
            b = bone
            while b is not None and b.name not in grown:
                chain.append(b)
                b = b.parent
                if len(chain) > 4096:
                    return math.inf
            for b in reversed(chain):
                head = 'pose.bones["%s"]' % b.name
                parent = b.parent
                above = grown[parent.name] if parent is not None else 1.0
                start = reached[parent.name] if parent is not None else 0.0
                rest = b.bone
                offset = (math.sqrt(sum(v * v for v in rest.head_local))
                          + math.sqrt(sum(v * v for v in rest.tail_local))
                          + max(moves.get(head, 0.0), math.sqrt(sum(v * v for v in b.location))))
                reached[b.name] = start + above * offset
                grown[b.name] = above * max(1.0, scales.get(head, 0.0), max(abs(v) for v in b.scale))
                if not math.isfinite(grown[b.name]) or grown[b.name] > 1e300:
                    return math.inf
            farthest = max(farthest, reached[bone.name] + grown[bone.name] * vertex)
    except (AttributeError, ReferenceError, TypeError, ValueError):
        return math.inf
    reach = to_world * (farthest + 1.0)
    return reach if math.isfinite(reach) else math.inf


def _cyclic(accepted, reads):
    """The keys of `accepted` drivers in a cycle of drivers reading each other
    (a strongly connected set of two or more, or one reading itself), by
    Tarjan's walk, made without recursion."""
    order, low, on, stack, found = {}, {}, set(), [], set()
    counter = 0
    for root in accepted:
        if root in order:
            continue
        work = [(root, iter([k for k in reads.get(root, ()) if k in accepted]))]
        order[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on.add(root)
        while work:
            node, edges = work[-1]
            advanced = False
            for nxt in edges:
                if nxt not in order:
                    order[nxt] = low[nxt] = counter
                    counter += 1
                    stack.append(nxt)
                    on.add(nxt)
                    work.append((nxt, iter([k for k in reads.get(nxt, ()) if k in accepted])))
                    advanced = True
                    break
                if nxt in on:
                    low[node] = min(low[node], order[nxt])
            if advanced:
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == order[node]:
                members = []
                while True:
                    k = stack.pop()
                    on.discard(k)
                    members.append(k)
                    if k == node:
                        break
                if len(members) > 1 or node in reads.get(node, ()):
                    found.update(members)
    return found


def _in_time(block, seen):
    """Whether Blender evaluates `block` again on a frame change: it has an
    action or an unmuted NLA track, a driver reading the frame or reading
    something that moves in time, or — an object — a parent or a
    constraint's target that does (fix round 3, see `_plan_fill`'s cycles).
    A bound: an action that sets nothing counted still counts."""
    try:
        p = block.as_pointer()
    except (AttributeError, ReferenceError):
        return False
    if p in seen:
        return False
    seen.add(p)
    try:
        ad = getattr(block, 'animation_data', None)
        if ad is not None:
            if ad.action is not None or any(not track.mute for track in ad.nla_tracks):
                return True
            for curve in ad.drivers:
                if curve.mute:
                    continue
                driver = curve.driver
                if driver.type == 'SCRIPTED' and 'frame' in driver.expression:
                    return True
                for var in driver.variables:
                    if var.type == 'CONTEXT_PROP':
                        return True
                    for target in var.targets:
                        other = target.id
                        if other is not None and (isinstance(other, bpy.types.Scene) or _in_time(other, seen)):
                            return True
        if isinstance(block, bpy.types.Object):
            placing = [block.parent] if block.parent is not None else []
            for c in block.constraints:
                placing.extend(_targets_of(c))
            pose = getattr(block, 'pose', None)
            if pose is not None:
                for bone in pose.bones:
                    for c in bone.constraints:
                        placing.extend(_targets_of(c))
            if any(other is not None and _in_time(other, seen) for other in placing):
                return True
            data = block.data
            if data is not None and _in_time(data, seen):
                return True
    except (AttributeError, ReferenceError, RuntimeError, TypeError):
        return True
    return False


_OWN_PROPS = {}


def _resolve(block, path):
    head, dot, name = path.rpartition('.')
    if not dot:
        head, name = '', path
    if not head:
        # A data-block's own property is its type's: looked up once a type.
        key = (block.bl_rna.identifier, name)
        if key in _OWN_PROPS:
            return head, name, _OWN_PROPS[key]
    try:
        owner = block.path_resolve(head) if head else block
        prop = owner.bl_rna.properties[name]
    except (ValueError, KeyError, AttributeError, TypeError):
        return head, name, None
    if prop.type not in ('FLOAT', 'INT', 'BOOLEAN', 'ENUM') or (prop.type == 'ENUM' and prop.is_enum_flag):
        prop = None
    if not head:
        _OWN_PROPS[(block.bl_rna.identifier, name)] = prop
    return head, name, prop


def _plan_build(scene):
    plan = _FramePlan(scene)
    try:
        from bpy_extras import anim_utils
    except ImportError:
        return plan
    probe = Prices()
    try:
        _plan_fill(plan, scene, probe, anim_utils)
    finally:
        probe.close()
    return plan


def _plan_fill(plan, scene, probe, anim_utils):
    edges = {}

    def edges_of(o):
        """(what places `o`: its parent and its constraints' targets, its
        bones' too; what its modifiers and curve data read)."""
        p = _pointer(o)
        found = edges.get(p)
        if found is None:
            placing = [o.parent] if o.parent is not None else []
            for c in o.constraints:
                placing.extend(_targets_of(c))
            pose = getattr(o, 'pose', None)
            if pose is not None:
                for bone in pose.bones:
                    for c in bone.constraints:
                        placing.extend(_targets_of(c))
            data = o.data
            reading = (list(_references(o, probe)) if len(o.modifiers) or (
                data is not None and o.type in ('CURVE', 'SURFACE', 'FONT')) else [])
            found = edges[p] = (placing, reading)
        return found

    # Every object something counted reads, through parents, constraints,
    # modifiers and curve data, whether the scene lists it or not: what the
    # model's `affected` walks, from the other end.
    reach = {}
    stack = []
    for o in scene.objects:
        if o.type in COUNTED_TYPES:
            reach[_pointer(o)] = o
            stack.append(o)
    while stack:
        placing, reading = edges_of(stack.pop())
        for other in placing + reading:
            p = _pointer(other)
            if p not in reach:
                reach[p] = other
                stack.append(other)
    # The objects whose place is a priced input: what a modifier or a curve
    # reads of another object is read where that object is; a counted object
    # whose own stack reads its place; and whatever places one of those.
    place = {}
    for o in reach.values():
        placing, reading = edges_of(o)
        for other in reading:
            place[_pointer(other)] = other
        if o.type in COUNTED_TYPES and _reads_place(o):
            place[_pointer(o)] = o
    stack = list(place.values())
    while stack:
        for other in edges_of(stack.pop())[0]:
            p = _pointer(other)
            if p not in place:
                place[p] = other
                stack.append(other)

    blocks = {}
    for o in reach.values():
        blocks[_pointer(o)] = o
        data = o.data
        if data is not None:
            blocks.setdefault(_pointer(data), data)
            keys = getattr(data, 'shape_keys', None)
            if keys is not None:
                blocks.setdefault(_pointer(keys), keys)
        for system in getattr(o, 'particle_systems', ()):
            blocks.setdefault(_pointer(system.settings), system.settings)
        # The node groups its Geometry Nodes run, and the groups inside them:
        # a group's own keyed socket is the frame's too. Round 4's fix round 2
        # review, desktop 5.2.1, budget 100,000: a Grid node's Vertices X and
        # Y keyed 2 → 1,000 in its group passed frame 10 and Blender built
        # 1,000,000 vertices; node groups were not among the plan's blocks.
        for tree in _modifier_trees(o):
            blocks.setdefault(_pointer(tree), tree)
        # The legacy textures its modifiers read: a texture's keyed
        # Brightness moves what a Displace moves (fix round 3, see the gate's
        # `_texture_kinds`).
        for texture in _textures_of(o):
            blocks.setdefault(_pointer(texture), texture)
    blocks.setdefault(_pointer(scene), scene)
    # The rest of the scene's animation reaches nothing counted, unless a path
    # goes through a pointer into a data-block that does (an F-curve or a
    # driver on `parent.location` animates the parent): those blocks are
    # looked at too, and only those paths in them are priced.
    across = {}
    for o in scene.objects:
        for block in (o, o.data):
            if block is None or _pointer(block) in blocks:
                continue
            ad = getattr(block, 'animation_data', None)
            if ad is None:
                continue
            found = list(ad.drivers)
            if ad.action is not None and getattr(ad, 'action_slot', None) is not None:
                try:
                    bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
                except (AttributeError, RuntimeError, TypeError):
                    bag = None
                if bag is not None:
                    found.extend(bag.fcurves)
            for curve in found:
                head = curve.data_path.rpartition('.')[0]
                if not head:
                    continue
                try:
                    owner = block.path_resolve(head)
                    other = owner.id_data
                except (ValueError, AttributeError, TypeError, ReferenceError):
                    continue
                if other is not None and other != block and _pointer(other) in blocks:
                    across.setdefault(_pointer(block), set()).add(curve.data_path)
                    blocks[_pointer(block)] = block

    curves = {}          # block pointer -> (block, [entries])
    drivers = []
    candidates = {}      # object pointer -> [(block, curve, entry, is_driver)]
    poses = {}           # armature pointer -> [(block, curve, entry, is_driver)]
    blended = {}         # block pointer -> (block, {path}): its active action blended over its NLA
    # `_target_key`'s cache, the plan's (`keys` and `paths` are other things below).
    canon = plan.keys
    for p, block in blocks.items():
        ad = getattr(block, 'animation_data', None)
        if ad is None:
            continue
        found = []
        if ad.action is not None and getattr(ad, 'action_slot', None) is not None:
            try:
                bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
            except (AttributeError, RuntimeError, TypeError):
                bag = None
            if bag is not None:
                found.extend((c, False, i) for i, c in enumerate(bag.fcurves) if not c.mute and not c.is_empty)
            if ad.use_nla and (ad.action_blend_type != 'REPLACE' or ad.action_influence < 1.0):
                # The active action blended over what is under it: Blender's
                # own evaluation of the frame says the value (`probed`, as an
                # NLA's strips).
                blended.setdefault(p, (block, set()))[1].update(
                    c.data_path for c, _, _ in found if _counts_on(block, c.data_path))
        found.extend((c, True, i) for i, c in enumerate(ad.drivers) if not c.mute)
        only = across.get(p)
        for curve, is_driver, slot in found:
            if only is not None and curve.data_path not in only:
                continue
            head, name, prop = _resolve(block, curve.data_path)
            if prop is None or (isinstance(block, bpy.types.Object) and not head and name in _UNREAD):
                plan.left_out += 1
                continue
            entry = _Entry(block, curve.data_path, curve.array_index, head, name, prop, True, canon)
            entry.slot = slot
            if (isinstance(block, bpy.types.Object) and not head and name in _PLACE_CHANNELS
                    and p not in place):
                candidates.setdefault(p, []).append((block, curve, entry, is_driver))
                continue
            if (isinstance(block, bpy.types.Object) and block.type == 'ARMATURE' and head.startswith('pose.bones[')
                    and name in _POSE_CHANNELS and not is_driver):
                poses.setdefault(p, []).append((block, curve, entry, is_driver))
                continue
            if is_driver:
                drivers.append((block, curve, entry))
            else:
                curves.setdefault(p, (block, []))[1].append(entry)

    # A place channel of an object whose place nothing priced reads moves
    # only how far its vertices get: priced each frame only where the most
    # its F-curves reach could take a vertex past STATIC_REACH, where it is
    # driven, or where what it places is priced on that frame anyway.
    # Who reads whom, for what a priced value reaches (`plan.objects`, which
    # the frame's judgement takes in place of `affected`'s walk over every
    # object in the file: a keyed Count among 3,000 keyed empties was judged
    # in 0.10 ms a frame this way and in 8.15 ms with the walk, desktop 5.2.1)
    # and for the place channels below.
    readers = {}
    followers = {}
    for o in reach.values():
        placing, reading = edges_of(o)
        for other in placing + reading:
            readers.setdefault(_pointer(other), []).append(o)
        for other in placing:
            followers.setdefault(_pointer(other), []).append(o)
    owners = {}
    for o in reach.values():
        data = o.data
        if data is not None:
            owners.setdefault(_pointer(data), []).append(o)
            keys = getattr(data, 'shape_keys', None)
            if keys is not None:
                owners.setdefault(_pointer(keys), []).append(o)
        for system in getattr(o, 'particle_systems', ()):
            owners.setdefault(_pointer(system.settings), []).append(o)
        for tree in _modifier_trees(o):
            owners.setdefault(_pointer(tree), []).append(o)
        for texture in _textures_of(o):
            owners.setdefault(_pointer(texture), []).append(o)

    def users(block):
        if isinstance(block, bpy.types.Object):
            return [block]
        if isinstance(block, bpy.types.Scene):
            return [o for o in reach.values() if o.type in COUNTED_TYPES]
        return owners.get(_pointer(block), [])

    def spread(seeds, links):
        seen = {}
        stack = list(seeds)
        while stack:
            o = stack.pop()
            q = _pointer(o)
            if q not in seen:
                seen[q] = o
                stack.extend(links.get(q, ()))
        return seen

    families = {}
    for o in reach.values():
        if o.type == 'META':
            families.setdefault(_family_base(o.name), []).append(o)

    def reaches_of(block):
        """The counted objects a value of `block` can change: its users and
        whatever reads them, and a metaball's whole family (its basis
        polygonizes every member)."""
        found = spread(users(block), readers)
        for o in list(found.values()):
            if o.type == 'META':
                for member in families.get(_family_base(o.name), ()):
                    found.setdefault(_pointer(member), member)
        return [o for o in found.values() if o.type in COUNTED_TYPES]

    # A bone's channels move what its armature deforms, which changes no
    # count unless something they reach reads where vertices are (a Remesh, a
    # Boolean, a fitted Array, `_reaches_shapes`) or they could take a vertex
    # past STATIC_REACH (`_pose_reach`). Otherwise they are left out, as the
    # place channels of an object nothing reads. Round 4's fix round 2
    # review, desktop 5.2.1: a cube under an Armature of 300 keyed bones
    # (3,000 F-curves) priced each frame in 14.6 ms, 40.3 ms at 600 bones,
    # against Blender's own frame of 1.3 to 3.3 ms; an Armature only deforms.
    for p, items in poses.items():
        arm = items[0][0]
        if _reaches_shapes(arm) or _pose_reach(arm, items, reach.values()) >= STATIC_REACH:
            for block, curve, entry, is_driver in items:
                curves.setdefault(p, (block, []))[1].append(entry)
        else:
            plan.left_out += len(items)
            plan.static.add(p)
            plan.static.add(_pointer(arm.data))
            for o in reach.values():
                if o.type in COUNTED_TYPES:
                    plan.static.add(_pointer(o))
                    if o.data is not None:
                        plan.static.add(_pointer(o.data))

    if candidates:
        priced = spread([u for b, _ in curves.values() for u in users(b)]
                        + [u for b, _, _ in drivers for u in users(b)], readers)
        bounds = {}
        for p, items in candidates.items():
            for block, curve, entry, is_driver in items:
                if entry.name in ('location', 'delta_location', 'scale', 'delta_scale'):
                    bounds[(p, entry.name, entry.index)] = math.inf if is_driver else _curve_bound(curve)
        reaches = {}
        waiting = dict(candidates)
        while waiting:
            turned = []
            for p, items in waiting.items():
                for q, o in spread([items[0][0]], followers).items():
                    if o.type not in COUNTED_TYPES:
                        continue
                    if q not in reaches:
                        reaches[q] = _static_reach(o, bounds)
                        holder = o
                        while holder is not None and len(plan.static) < 1 << 20:
                            plan.static.add(_pointer(holder))
                            if holder.data is not None:
                                plan.static.add(_pointer(holder.data))
                            holder = holder.parent
                    if q in priced or reaches[q] >= STATIC_REACH:
                        turned.append(p)
                        break
            if not turned:
                break
            for p in turned:
                items = waiting.pop(p)
                for block, curve, entry, is_driver in items:
                    if is_driver:
                        drivers.append((block, curve, entry))
                    else:
                        curves.setdefault(p, (block, []))[1].append(entry)
                # What it moves is priced on its frames now, and what that
                # places may be too: looked at again.
                priced.update(spread([items[0][0]], readers))
        plan.left_out += sum(len(items) for items in waiting.values())

    # Drivers: worked out each frame where their settings allow, with every
    # F-curve and driver they read evaluated with them. A driver that reads
    # one that cannot be worked out cannot be either. What a variable reads
    # is keyed by where the value is (`_target_key`), so a driver reading
    # `parent.location[0]` reads the parent's F-curve.
    index = {}
    for block, curve, entry in drivers:
        index.setdefault(entry.key, (block, curve))

    def driver_of(key, idblock):
        if key in index:
            return index[key]
        ad = getattr(idblock, 'animation_data', None)
        if ad is None:
            return None
        curve = ad.drivers.find(key[1], index=key[2])
        return (idblock, curve) if curve is not None and not curve.mute else None

    def animated_elsewhere(key, idblock):
        """Whether Blender's evaluation sets the value another way than the
        plan works out: an NLA strip, or the active action blended."""
        try:
            ad = idblock.animation_data
        except (AttributeError, ReferenceError):
            return False
        if ad is None or not ad.use_nla:
            return False
        if ad.action is not None and (ad.action_blend_type != 'REPLACE' or ad.action_influence < 1.0):
            return True
        return key[1] in _nla_paths(idblock)

    accepted, refused, inputs, reads, timed, holders = {}, {}, {}, {}, set(), {}
    # Every driver looked at, worked out ahead or not, with what it reads: a
    # cycle can run through one only Blender works out (fix round 3, below).
    every = {}
    queue = list(drivers)
    while queue:
        block, curve, entry = queue.pop()
        if entry.key in accepted or entry.key in refused:
            continue
        every[entry.key] = (block, curve, entry)
        if not _driver_computable(block, curve):
            refused[entry.key] = (block, entry)
        else:
            accepted[entry.key] = (block, curve, entry)
        mine = reads[entry.key] = []
        if curve.driver.type == 'SCRIPTED' and 'frame' in curve.driver.expression:
            timed.add(entry.key)
        for var in curve.driver.variables:
            for key, idblock in _driver_inputs(var, scene, canon):
                mine.append(key)
                holders.setdefault(key, idblock)
                if key[0] == _pointer(scene) and key[1] in _FRAME_PROPS:
                    timed.add(entry.key)
                    continue
                if animated_elsewhere(key, idblock):
                    # What the plan would read there is not what Blender
                    # evaluates: the driver is read from Blender (`probed`).
                    refused[entry.key] = (block, entry)
                    continue
                if key in accepted or key in refused:
                    continue
                inner = driver_of(key, idblock)
                if inner is not None:
                    holder, found = inner
                    head, name, prop = _resolve(holder, found.data_path)
                    queue.append((holder, found, _Entry(holder, found.data_path, found.array_index, head, name,
                                                        prop, False, canon)))
                else:
                    inputs[key] = idblock
    for key in list(accepted):
        if key in refused:
            del accepted[key]
    again = True
    while again:
        again = False
        for key in list(accepted):
            if any(k in refused for k in reads.get(key, ())):
                refused[key] = accepted.pop(key)[0::2]
                again = True
    # Drivers that read each other (`plan.cycles`), and every driver that
    # reads one of them: Blender works each out from the others' last values,
    # so no value can be worked out ahead. Refused on a frame where Blender
    # evaluates them (`changes`), when one of them reaches a priced value.
    # Fix round 3 (October 29), desktop 5.2.1 with the app's context, the
    # budget lowered to 100,000, Count = n × 2 + x × 0 and n = Count: with x
    # an empty's Transform Channel X under a keyed parent, or its X location
    # with its rotation keyed, the plan listed the cycle and refused nothing
    # (Blender re-evaluates a driver whenever what it reads is evaluated, and
    # an object's transform is, on every frame its own animation or its
    # parent's runs): frames 2 to 13 doubled the Count to 131,072. With x a
    # Distance, which only Blender works out, the cycle was not found at all,
    # and the probe's own frame and the frame back stepped it twice more: 512
    # → 8,192 → 131,072. So cycles are found among every driver, and a cycle
    # is refused on every frame where anything it reads, or its owners, moves
    # in time (`_in_time`).
    cyclic = _cyclic(every, reads)
    if cyclic:
        readers_of = {}
        for key, inputs_of in reads.items():
            for k in inputs_of:
                readers_of.setdefault(k, []).append(key)
        stack = list(cyclic)
        while stack:
            for k in readers_of.get(stack.pop(), ()):
                if k in every and k not in cyclic:
                    cyclic.add(k)
                    stack.append(k)
        if any(every[k][2].priced for k in cyclic):
            ins = set()
            for k in cyclic:
                ins.update(i for i in reads.get(k, ()) if i not in cyclic)
            seen = set()
            moving = any(_in_time(every[k][0], seen) for k in cyclic)
            for k in sorted(cyclic, key=lambda k: (not every[k][2].priced, k[1])):
                block, curve, entry = every[k]
                plan.cycles.append((block, entry, bool(timed & cyclic) or moving, ins))
        for k in cyclic:
            accepted.pop(k, None)
            refused.pop(k, None)
    probed = {}
    for block, entry in refused.values():
        if entry.priced:
            plan.unpriced.append((getattr(block, 'name', ''), entry.path))
            probed.setdefault(_pointer(block), (block, set()))[1].add(entry.path)
    # An NLA's strips: Blender blends them (each strip's time, influence and
    # blending, the active action over them), which only its own evaluation
    # of the frame says. Round 4's fix round 2 review: a key of Count 400,000
    # in an NLA strip with no active action, the timeline's frame 10 built
    # 3,200,000 vertices with no refusal — the plan read the active action
    # alone.
    for p, block in blocks.items():
        paths = [path for path in _nla_paths(block) if _counts_on(block, path)]
        if paths:
            probed.setdefault(p, (block, set()))[1].update(paths)
    for p, (block, paths) in blended.items():
        if paths:
            probed.setdefault(p, (block, set()))[1].update(paths)
    plan.probed = [(block, sorted(paths)) for block, paths in probed.values()]
    plan.drivers = [(block, entry) for block, curve, entry in accepted.values()]
    plan.driven = set(accepted)
    present = {e.key for _, entries in curves.values() for e in entries}
    # Every F-curve a priced driver (or one of the cycles) reads, where it is.
    wanted = dict(inputs)
    for block, entry, _, ins in plan.cycles:
        for k in ins:
            wanted.setdefault(k, holders.get(k))
    by_block = {}
    for key, idblock in wanted.items():
        if key in present:
            continue
        if idblock is None:
            idblock = next((b for b in blocks.values() if _pointer(b) == key[0]), None)
            if idblock is None:
                continue
        by_block.setdefault(key[0], (idblock, set()))[1].add(key)
    for q, (idblock, wanted_keys) in by_block.items():
        ad = getattr(idblock, 'animation_data', None)
        if ad is None or ad.action is None or getattr(ad, 'action_slot', None) is None:
            continue
        try:
            bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
        except (AttributeError, RuntimeError, TypeError):
            bag = None
        if bag is None:
            continue
        for slot, curve in enumerate(bag.fcurves):
            if curve.mute or curve.is_empty:
                continue
            key = _target_key(idblock, curve.data_path, curve.array_index, canon)
            if key not in wanted_keys or key in present:
                continue
            head, name, prop = _resolve(idblock, curve.data_path)
            entry = _Entry(idblock, curve.data_path, curve.array_index, head, name, prop, False, canon)
            entry.slot = slot
            curves.setdefault(_pointer(idblock), (idblock, []))[1].append(entry)
            present.add(key)
    plan.curves = list(curves.values())
    # The counted objects each priced value can change, by the data-block its
    # owner is in (`price_frame` judges these alone).
    priced_entries = ([(b, e) for b, entries in plan.curves for e in entries if e.priced]
                      + [(b, e) for b, e in plan.drivers if e.priced])
    for block, e in priced_entries:
        try:
            idblock = block.path_resolve(e.head).id_data if e.head else block
        except (ValueError, AttributeError, ReferenceError):
            continue
        q = _pointer(idblock)
        if q not in plan.objects:
            plan.objects[q] = reaches_of(idblock)


def _holder(idblock, path):
    """The data-block that holds the value `path` reads from `idblock`
    (`_target_key`'s first member)."""
    head, _ = _split_path(path)
    if not head:
        return idblock
    try:
        holder = idblock.path_resolve(head).id_data
    except (ValueError, AttributeError, TypeError, ReferenceError, RuntimeError):
        return idblock
    return holder if holder is not None else idblock


def _driver_inputs(var, scene, keys=None):
    """(key, data-block) of what a driver variable reads, as `values` keys it:
    the data-block is the one that holds the value (`_target_key`)."""
    target = var.targets[0]
    if var.type == 'SINGLE_PROP' and target.id is not None and target.data_path:
        key = _target_key(target.id, target.data_path, None, keys)
        holder = target.id if key[0] == _pointer(target.id) else _holder(target.id, target.data_path)
        return [(key, holder)]
    if var.type == 'CONTEXT_PROP' and target.data_path:
        source = scene if target.context_property == 'ACTIVE_SCENE' else bpy.context.view_layer
        if source is not None:
            key = _target_key(source, target.data_path, None, keys)
            holder = source if key[0] == _pointer(source) else _holder(source, target.data_path)
            return [(key, holder)]
        return []
    if var.type == 'TRANSFORMS' and target.id is not None:
        obj = target.id
        bone = target.bone_target if getattr(obj, 'type', None) == 'ARMATURE' else ''
        prefix = 'pose.bones["%s"].' % bone if bone else ''
        names = ('location', 'scale') if bone else ('location', 'delta_location', 'scale', 'delta_scale')
        return [((_pointer(obj), prefix + n, i), obj) for n in names for i in range(3)]
    if var.type in ('LOC_DIFF', 'ROTATION_DIFF'):
        # A distance or a rotation between objects: where each of them is,
        # which only Blender's evaluation says (`_variable_value` leaves it
        # unknown), but which a change of any of them makes it read again.
        # Fix round 3: these read nothing here, so a Count driven by the
        # distance to an empty was not found as a reader of the empty's move.
        return [((_pointer(t.id), 'matrix_world', 0), t.id) for t in var.targets if t.id is not None]
    return []


def read_by_drivers(blocks):
    """Whether a driver anywhere (not muted) reads one of `blocks`, or an
    object one of them places (its children, at every depth): a change of
    them is a change of what it works out to."""
    wanted = set()
    stack = [b for b in blocks if b is not None]
    while stack:
        block = stack.pop()
        p = _pointer(block)
        if p in wanted:
            continue
        wanted.add(p)
        stack.extend(getattr(block, 'children', ()) or ())
    if not wanted:
        return False
    scene = bpy.context.scene
    for block in animated_blocks():
        try:
            drivers = block.animation_data.drivers
        except (AttributeError, ReferenceError):
            continue
        for curve in drivers:
            if curve.mute:
                continue
            for var in curve.driver.variables:
                if any(key[0] in wanted for key, _ in _driver_inputs(var, scene)):
                    return True
    return False


def _pending():
    """Whether Blender has been told of a change it has not evaluated."""
    try:
        layer = bpy.context.view_layer
        depsgraph = layer.depsgraph if layer is not None else None
    except (AttributeError, RuntimeError, ReferenceError):
        return True
    if depsgraph is None:
        return True
    for _ in depsgraph.updates:
        return True
    return False


def drop_plan(*_):
    """The plan is made again before the next frame: something other than a
    frame changed the scene (an evaluation, a load, an undo)."""
    global _plan
    _plan = None


# The kinds of struct whose change is a change of what animation sets or how
# the plan reads it.
_ANIMATION_STRUCTS = frozenset(('AnimData', 'FCurve', 'Driver', 'DriverVariable', 'DriverTarget', 'Keyframe',
                                'FModifier', 'NlaTrack', 'NlaStrip', 'ActionSlot', 'ActionChannelbag',
                                'ActionLayer', 'ActionKeyframeStrip', 'FCurveKeyframePoints'))


def _plan_neutral(found):
    """Whether every change the gate found (`_blenderkit_gate.Pending`) is a
    number the plan reads nothing of: not a pointer, not animation, not the
    scene's settings, not a modifier's or a constraint's switch or kind, and
    on nothing whose values a static bound was made from (`plan.static`)."""
    plan = _plan
    if plan is None:
        return True
    # `held`: drivers, an NLA or an action changed, or keys added. `animated`
    # alone also lists every user of an action a frame evaluated, which a
    # frame_change_post handler's checkpoint sees on every frame.
    if found.structs or found.held:
        return False
    for c in found.changes:
        owner, key = c.owner, c.key
        if isinstance(owner, bpy.types.Scene) and key in ('frame_current', 'frame_subframe'):
            continue
        if getattr(c, 'bulk', None) is not None:
            return False
        new, old = c.new, c.old
        if not isinstance(new, (int, float, tuple, list)) or not isinstance(old, (int, float, tuple, list)):
            return False
        if isinstance(new, bool) or isinstance(old, bool):
            return False
        if isinstance(new, (tuple, list)) and any(not isinstance(v, (int, float)) or isinstance(v, bool)
                                                  for v in new):
            return False
        try:
            block = owner.id_data
        except (AttributeError, ReferenceError):
            return False
        if block is None or isinstance(block, (bpy.types.Scene, bpy.types.Action)):
            return False
        if type(owner).__name__ in _ANIMATION_STRUCTS or key.startswith('matrix_') or key == 'parent_type':
            return False
        if _pointer(block) in plan.static:
            return False
    return True


def note_pending(found):
    """The gate found changes waiting to be evaluated (`_blenderkit_gate._run`):
    the plan is made again before the next frame unless they are numbers it
    reads nothing of (`_plan_neutral`). Their evaluation can come with no
    `depsgraph_update_post` the plan hears (`_plan_post`): what a script's
    `frame_change_post` handler writes is evaluated in the frame's second
    pass, and what the gate refuses is evaluated inside its price. Round 4's
    fix round 2 review, desktop 5.2.1, budget 100,000: a post handler that
    added an Array reading the keyed empty during frame 3 left the plan as it
    was, and frame 30 passed while Blender built 160,008."""
    if _plan is not None and not _plan_neutral(found):
        drop_plan()


def _plan_post(scene=None, depsgraph=None, *_):
    gate = sys.modules.get('_blenderkit_gate')
    if gate is not None and gate.busy():
        # The price's own evaluations, of its copies and stand-ins. A change
        # waiting when a price starts drops the plan there (`settle`).
        return
    drop_plan()


def _install_plan_handlers():
    global _plan_handlers
    if _plan_handlers:
        return
    from bpy.app.handlers import persistent
    handlers = bpy.app.handlers
    post = persistent(_plan_post)
    drop = persistent(drop_plan)
    post._blenderkit_frame_plan = drop._blenderkit_frame_plan = True
    # The app's own, by identity: no checkpoint after them
    # (`_blenderkit_gate._own`).
    gate = sys.modules.get('_blenderkit_gate')
    trust = getattr(gate, 'trust', None)
    if trust is not None:
        trust(post)
        trust(drop)
    for name, function in (('depsgraph_update_post', post), ('load_post', drop), ('undo_post', drop),
                           ('redo_post', drop)):
        handler_list = getattr(handlers, name, None)
        if handler_list is None:
            continue
        for existing in list(handler_list):
            if getattr(existing, '_blenderkit_frame_plan', False):
                handler_list.remove(existing)
        handler_list.append(function)
    _plan_handlers = True


def frame_plan():
    """The plan the next frame is priced from, made again when the scene
    changed since (see `drop_plan`)."""
    global _plan
    scene = bpy.context.scene
    if scene is None:
        return _FramePlan(None)
    if _plan is not None and (_plan.scene != _pointer(scene) or _pending()):
        _plan = None
    if _plan is None:
        _install_plan_handlers()
        _plan = _plan_build(scene)
    return _plan


def _frame_changes(t):
    """(the priced values the frame at `t` changes, the counted objects they
    reach or None for `affected` to find). Raises RuntimeError, in words,
    for a frame no price can be made for (`FrameRefused`)."""
    global _plan
    for attempt in range(2):
        plan = frame_plan()
        if not plan.live:
            return [], []
        try:
            changes, reached = plan.changes(t, bpy.context.scene)
        except (_Stale, ReferenceError):
            _plan = None
            continue
        except FrameRefused as why:
            raise FrameRefused("Frame %d: %s." % (int(math.floor(t)), str(why))) from None
        wanted = list(plan.probed)
        if plan.failed:
            extra = {}
            for block, e in plan.failed:
                extra.setdefault(_pointer(block), (block, set()))[1].add(e.path)
            wanted += [(block, sorted(paths)) for block, paths in extra.values()]
        if wanted:
            # Blender's own values where the plan cannot work them out (an
            # NLA, a Python driver, the active action blended over strips),
            # over what it worked out — on every path it probes, whatever the
            # probe found, since the plan's own value there is not Blender's.
            # The probe's own evaluation of the frame builds what the plan's
            # worked-out values reach as well, so their growth is hidden in
            # it too. Fix round 3 (October 29), desktop 5.2.1 with the app's
            # context, the budget lowered to 100,000: X's Count keyed 2 →
            # 1,000,000 and another cube Y with an NLA strip (or a driver
            # dividing by zero at frame 10), the timeline's frame 10 was
            # refused in words after the probe had built X at 8,000,000
            # (peak RSS 751 and 630 MB, against about 300 with X's growth
            # hidden).
            probed = probe_values(t, wanted, extra=[c[0] for c in changes])
            keys = {(_pointer(o), k) for o, k, v in probed}
            for block, paths in wanted:
                for path in paths:
                    head, name = _split_path(path)
                    try:
                        owner = block.path_resolve(head) if head else block
                        keys.add((_pointer(owner), name))
                    except (ValueError, AttributeError, ReferenceError, TypeError):
                        continue
            changes = [c for c in changes if (_pointer(c[0]), c[1]) not in keys] + probed
            reached = None
        return changes, reached
    # Made twice and stale twice: every F-curve, as the fix round priced them.
    return _animated_all(t), None


def _action_paths(action, slot=None):
    """The data paths an action's F-curves animate (of `slot`, or all)."""
    paths = []
    try:
        for layer in action.layers:
            for strip in layer.strips:
                for bag in getattr(strip, 'channelbags', ()):
                    if slot is not None and getattr(bag, 'slot', None) is not None and bag.slot != slot:
                        continue
                    paths.extend(curve.data_path for curve in bag.fcurves if not curve.mute)
    except (AttributeError, ReferenceError, RuntimeError):
        pass
    return paths


def _nla_paths(block):
    """The paths `block`'s NLA strips animate, where its NLA is on."""
    try:
        ad = block.animation_data
    except (AttributeError, ReferenceError):
        return []
    if ad is None or not ad.use_nla:
        return []
    paths = set()

    def strips_of(strips):
        for strip in strips:
            if strip.mute:
                continue
            if strip.type == 'META':
                strips_of(strip.strips)
            elif strip.action is not None:
                paths.update(_action_paths(strip.action, getattr(strip, 'action_slot', None)))
                if strip.use_animated_influence:
                    paths.add('influence')
    try:
        for track in ad.nla_tracks:
            if not track.mute:
                strips_of(track.strips)
    except (AttributeError, ReferenceError, RuntimeError):
        return []
    paths.discard('influence')
    return sorted(paths)


def probe_values(t, wanted, extra=()):
    """(owner, property, value) Blender's own evaluation sets on each of
    `wanted`'s paths — (block, [path]) — at the frame `t` (None: the
    refresh Blender is about to make), read from an evaluation of it made
    with every modifier that makes more hidden on what those values reach
    (and on `extra`, objects whose change is waiting), so it builds only the
    bases. Measured in desktop 5.2.1: inside `frame_change_pre`, a nested
    `frame_set(10)` with the Array hidden read the NLA's Count of 400,000
    with 8 vertices built, and the frame put back built frame 1's again."""
    gate = _gate()
    scene = bpy.context.scene
    blocks = [block for block, paths in wanted]
    probe = Prices()
    try:
        reach = set(affected(blocks + list(extra), probe))
    finally:
        probe.close()
    found = {}
    hidden = []
    before = {}
    for block, paths in wanted:
        for path in paths:
            head, name, prop = _resolve(block, path)
            if prop is None:
                continue
            try:
                owner = block.path_resolve(head) if head else block
                value = getattr(owner, name)
            except (ValueError, AttributeError, ReferenceError):
                continue
            before[(_pointer(owner), name)] = tuple(value) if hasattr(value, '__len__') and not isinstance(
                value, str) else value
    busy = gate._Busy() if gate is not None else _NullContext()
    muted = []
    with busy:
        for obj in reach:
            for m in obj.modifiers:
                if m.show_viewport and m.type not in _KEEPS_TOPOLOGY:
                    m.show_viewport = False
                    hidden.append(m)
            # A modifier's switch animated or driven would show it again in
            # the probe's own evaluation: its F-curves held off meanwhile.
            ad = getattr(obj, 'animation_data', None)
            if ad is not None:
                curves = list(ad.drivers)
                if ad.action is not None and getattr(ad, 'action_slot', None) is not None:
                    try:
                        from bpy_extras import anim_utils
                        bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
                        curves += list(bag.fcurves) if bag is not None else []
                    except (ImportError, AttributeError, RuntimeError, TypeError):
                        pass
                for curve in curves:
                    if curve.data_path.endswith('.show_viewport') and not curve.mute:
                        curve.mute = True
                        muted.append(curve)
        then = (scene.frame_current, scene.frame_subframe)
        try:
            if t is None:
                # The refresh Blender is about to make, with the change.
                bpy.context.view_layer.update()
            else:
                scene.frame_set(int(math.floor(t)), subframe=float(t - math.floor(t)))
            for block, paths in wanted:
                for path in paths:
                    head, name, prop = _resolve(block, path)
                    if prop is None:
                        continue
                    try:
                        owner = block.path_resolve(head) if head else block
                        value = getattr(owner, name)
                    except (ValueError, AttributeError, ReferenceError):
                        continue
                    if hasattr(value, '__len__') and not isinstance(value, str):
                        value = tuple(value)
                    found[(_pointer(owner), name)] = (owner, name, value)
        finally:
            if t is None:
                # Blender wrote the driven values back into the originals
                # (an active depsgraph does): put back as they were, so what
                # follows reads the state the price lays its changes over.
                for key, (owner, name, value) in found.items():
                    if key in before and before[key] != value:
                        try:
                            setattr(owner, name, before[key])
                        except (TypeError, ValueError, AttributeError, RuntimeError):
                            pass
            else:
                scene.frame_set(then[0], subframe=then[1])
            for m in hidden:
                try:
                    m.show_viewport = True
                except ReferenceError:
                    pass
            for curve in muted:
                try:
                    curve.mute = False
                except ReferenceError:
                    pass
    return [(owner, name, value) for key, (owner, name, value) in found.items() if before.get(key) != value]


class _NullContext:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _animated_all(frame):
    """(owner, property, value) for what each active action's F-curves would
    set at `frame`: an int raised to the next whole number, a bool on past 0.5,
    an array's other components as they are. Enums, NLA strips and drivers are
    left out. Round 4's fix round priced every frame this way; it stays for a
    plan that is stale again as soon as it is made (`_frame_changes`).
    Evaluated at the scene's time through Time Stretching (`_when`)."""
    try:
        from bpy_extras import anim_utils
    except ImportError:
        return []
    ct = _when(None, frame)[1]
    blocks = []
    for obj in bpy.context.scene.objects:
        blocks.append(obj)
        if obj.data is not None:
            blocks.append(obj.data)
        for system in getattr(obj, 'particle_systems', ()):
            blocks.append(system.settings)
    found = {}
    for block in blocks:
        ad = getattr(block, 'animation_data', None)
        if ad is None or ad.action is None or getattr(ad, 'action_slot', None) is None:
            continue
        try:
            bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
        except (AttributeError, RuntimeError, TypeError):
            bag = None
        if bag is None:
            continue
        for curve in bag.fcurves:
            if curve.mute or curve.is_empty:
                continue
            path = curve.data_path
            head, dot, name = path.rpartition('.')
            if not dot:
                head, name = '', path
            try:
                owner = block.path_resolve(head) if head else block
                prop = owner.bl_rna.properties[name]
            except (ValueError, KeyError, AttributeError, TypeError):
                continue
            value = curve.evaluate(ct)
            if prop.type == 'INT':
                value = int(math.ceil(value))
            elif prop.type == 'BOOLEAN':
                value = value > 0.5
            elif prop.type != 'FLOAT':
                continue
            key = (_pointer(owner), name)
            if getattr(prop, 'is_array', False):
                if key not in found:
                    found[key] = [owner, name, list(getattr(owner, name))]
                vector = found[key][2]
                if 0 <= curve.array_index < len(vector):
                    vector[curve.array_index] = value
            else:
                found[key] = [owner, name, value]
    return [(o, k, tuple(v) if isinstance(v, list) else v) for o, k, v in found.values()]


def price_frame(frame, subframe=0.0, approve=True):
    """A frame change (the timeline, playback, a scrub), priced from what its
    animation would set — a keyed Array's Count, a Subdivision's Levels, a
    shape key's Value, an offset object's place, a driver of one of them —
    before Blender evaluates the frame, and only that (`frame_plan`). Round
    4's fix-round review: the completeness check never changed a frame, and a
    keyed value reaches Blender there with no price."""
    if not _is_real_blender():
        return
    t = float(frame) + float(subframe)
    try:
        changes, reached = _frame_changes(t)
    except FrameRefused as why:
        raise RuntimeError(str(why)) from None
    gate = _gate()
    if changes:
        # The keyed values reach Blender in the frame's own evaluation, never
        # as a write the gate sees: priced here alone, with nothing to approve.
        settle()
        try:
            _judge_changes(changes, "Frame %d" % int(frame),
                           "Lower what the animation keys at that frame, or what the modifiers make.",
                           reached=reached)
        finally:
            # The price's own copies, taken out of the scene, leave the scene
            # told of it: evaluated here, inside the price, so the next frame
            # does not take it for a change and make its plan again. In the
            # app, a keyed Count among 3,000 empties made the plan again on
            # every frame it changed (12 ms each there, 0.3 s with 3,000
            # keyed cubes).
            _depsgraph()
    if approve and gate is not None and hasattr(gate, 'approve_frame'):
        # Priced here: the gate's frame handler need not price it again.
        gate.approve_frame(bpy.context.scene, t)


# -- animation the gate prices (round 4's fix round 2 review) ------------------
#
# The timeline prices a frame from its plan (`price_frame`). Everything else
# that makes Blender evaluate animation differently — a driver added or
# edited, an action's keys written, the frame moved by a script line, the
# Data API row or the search's frame operators, a value a driver reads —
# reaches the gate (_blenderkit_gate), which asks here what that animation
# would set, before Blender evaluates it. Measured in desktop 5.2.1 by the
# review, a cube under an Array of Count 2: each of those built 3,200,000
# vertices with no refusal.

# The data-block collections whose members can carry animation that reaches
# a count.
_ANIMATED_COLLECTIONS = ('objects', 'meshes', 'curves', 'metaballs', 'lattices', 'shape_keys', 'particles',
                         'armatures', 'node_groups', 'scenes', 'grease_pencils', 'hair_curves', 'pointclouds',
                         'volumes', 'textures')


def animated_blocks():
    """Every data-block in the file that has animation data."""
    found = []
    for name in _ANIMATED_COLLECTIONS:
        for block in getattr(bpy.data, name, ()):
            try:
                if block.animation_data is not None:
                    found.append(block)
            except (AttributeError, ReferenceError):
                continue
    return found


# The data-blocks a driven or keyed value counts on: anything else (a
# material's colour, a light, a camera) moves no vertex.
_COUNTED_OWNERS = ('Object', 'Mesh', 'Curve', 'TextCurve', 'SurfaceCurve', 'MetaBall', 'Lattice', 'Key',
                   'ParticleSettings', 'Armature', 'Scene', 'GeometryNodeTree', 'GreasePencil', 'Curves',
                   'PointCloud', 'Volume')


def _counts_on(block, path):
    """Whether an animated `path` of `block` can change a count: on a
    data-block of `_COUNTED_OWNERS`, not one of an object's settings the
    model never reads, and not a custom property (which only a driver reads,
    and that driver is priced itself)."""
    if type(block).__name__ not in _COUNTED_OWNERS and not isinstance(block, (bpy.types.NodeTree,
                                                                              bpy.types.Texture)):
        return False
    if path.startswith('[') or path.endswith(']') and '["' in path.rpartition('.')[2]:
        return False
    head, _, name = path.rpartition('.')
    if not head and isinstance(block, bpy.types.Object) and name in _UNREAD:
        return False
    # A place — an object's or a pose bone's channels, a shape key's Value —
    # counts only where something it reaches reads places (a fitted Array, a
    # Remesh, a Boolean...): a rig's corrective keys driven by its bones'
    # rotations, under deforms alone, are not worked out on every pose.
    if isinstance(block, bpy.types.Key) or (isinstance(block, bpy.types.Object) and head.startswith('pose.bones')):
        return _reaches_shapes(block)
    if isinstance(block, bpy.types.Object) and not head and name in _PLACE_CHANNELS:
        return _reaches_places(block)
    return True


# The modifiers whose count or time follows the shape of what they are given
# (where its vertices are), as the gate's `_PLACE_SENSITIVE`.
_SHAPE_SENSITIVE = ('REMESH', 'BOOLEAN', 'ARRAY', 'BEVEL', 'MESH_TO_VOLUME', 'NODES', 'SKIN', 'SOLIDIFY',
                    'WELD', 'DECIMATE', 'EDGE_SPLIT', 'FLUID', 'VOLUME_TO_MESH')


def _reaches_shapes(block):
    """Whether anything a shape key or a pose deforms has a count that
    follows where its vertices are."""
    probe = Prices()
    try:
        reach = affected([block], probe)
    finally:
        probe.close()
    gate = _gate()
    sensitive = getattr(gate, '_reads_places', None) or (lambda m: m.type in _SHAPE_SENSITIVE)
    for obj in reach:
        if obj.type == 'META' or len(getattr(obj, 'particle_systems', ())):
            return True
        if any(m.show_viewport and sensitive(m) for m in obj.modifiers):
            return True
    return False


def _reaches_places(block):
    """Whether anything `block` reaches reads where things are (`_PLACE_FREE`
    tells which modifiers do not)."""
    probe = Prices()
    try:
        reach = affected([block], probe)
    finally:
        probe.close()
    for obj in reach:
        if obj.type == 'META' or len(getattr(obj, 'particle_systems', ())):
            return True
        for m in obj.modifiers:
            if m.show_viewport and m.type not in _PLACE_FREE and m.type not in _KEEPS_TOPOLOGY:
                return True
            if m.show_viewport and m.type == 'ARRAY' and (m.fit_type != 'FIXED_COUNT' or m.use_object_offset):
                return True
            if m.show_viewport and m.type in ('MIRROR', 'SCREW') and getattr(m, 'mirror_object', None) is not None:
                return True
    return False


class Animated:
    """What the coming evaluation's animation would set (`animation_pairs`):
    `pairs` (owner, property, value) that differ from what Blender holds,
    `reached` the counted objects they reach where a plan knows them (else
    None), `unknown` drivers whose value only Blender can work out on a
    setting that counts — (block, F-curve, words) — and `sources`, for each
    pair, the F-curves that set it (to mute when what changed cannot be put
    back)."""

    def __init__(self):
        self.pairs = []
        self.reached = None
        self.unknown = []
        self.probed = []
        self.sources = {}
        self.label = None

    def __bool__(self):
        return bool(self.pairs or self.unknown)


def _expression_words(curve):
    driver = curve.driver
    if driver.type == 'SCRIPTED':
        return "its expression %r" % driver.expression
    return "its %s of %d variables" % (driver.type.lower(), len(driver.variables))


def animation_pairs(frame=None, blocks=(), inputs=(), laid=None, probe=True):
    """What the coming evaluation's animation would set (`Animated`): the
    frame `frame` (scene, time) priced from the timeline's plan
    (`frame_plan`); each of `blocks`, whose drivers, NLA or action changed,
    from its own F-curves and drivers at the time Blender is about to
    evaluate; and every driver anywhere that reads one of `inputs` (the
    data-blocks a change was written to), worked out with what they hold
    now — or, `laid`, with these values in place of what they read
    (`_target_key` -> number: a change about to be written, `_readers_of`).
    A driver Blender's simple expressions cannot cover, on a setting that
    counts, is `unknown`; read from Blender's own refresh (`probe_values`)
    unless `probe` is False."""
    out = Animated()
    scene = bpy.context.scene
    wanted = {_pointer(b): b for b in blocks}
    elsewhere = False
    timed = scene
    if frame is not None:
        other, t = frame
        out.label = "Frame %d" % int(t)
        if scene is not None and other == scene:
            changes, reached = _frame_changes(t)
            out.pairs.extend(changes)
            out.reached = reached
        else:
            # Another scene's frame (a script's `frame_set` on it): its own
            # animated data-blocks, each worked out at `t` below — the
            # timeline's plan is the context scene's.
            elsewhere = True
            timed = other
            for obj in other.objects:
                for block in (obj, obj.data, getattr(obj.data, 'shape_keys', None)):
                    try:
                        if block is not None and block.animation_data is not None:
                            wanted[_pointer(block)] = block
                    except (AttributeError, ReferenceError):
                        continue
    else:
        t = scene.frame_current + scene.frame_subframe if scene is not None else 0.0
    readers = []
    input_keys = {_pointer(b) for b in inputs}
    if input_keys:
        for block in animated_blocks():
            if _pointer(block) in wanted:
                continue
            try:
                drivers = list(block.animation_data.drivers)
            except (AttributeError, ReferenceError):
                continue
            for curve in drivers:
                if curve.mute:
                    continue
                for var in curve.driver.variables:
                    if any(key[0] in input_keys for key, _ in _driver_inputs(var, scene)):
                        readers.append((block, curve))
                        break
    if not wanted and not readers:
        return out
    from bpy_extras import anim_utils
    found = {}
    values = dict(laid) if laid else {}
    jobs = []           # (block, F-curve, entry, is_driver)
    for block in wanted.values():
        try:
            ad = block.animation_data
        except (AttributeError, ReferenceError):
            continue
        if ad is None:
            continue
        if ad.action is not None and getattr(ad, 'action_slot', None) is not None:
            try:
                bag = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
            except (AttributeError, RuntimeError, TypeError):
                bag = None
            for curve in (bag.fcurves if bag is not None else ()):
                if not curve.mute and not curve.is_empty:
                    jobs.append((block, curve, False))
        for curve in ad.drivers:
            if not curve.mute:
                jobs.append((block, curve, True))
    jobs.extend((block, curve, True) for block, curve in readers)
    driven = set()
    entries = []
    for block, curve, is_driver in jobs:
        head, name, prop = _resolve(block, curve.data_path)
        if prop is None:
            continue
        e = _Entry(block, curve.data_path, curve.array_index, head, name, prop, True)
        entries.append((block, curve, e, is_driver))
        if is_driver:
            driven.add(e.key)
    # The time Blender evaluates animation at, through Time Stretching.
    when = _when(timed, t)
    for block, curve, e, is_driver in entries:
        if not is_driver:
            value = curve.evaluate(when[1])
            values[e.key] = (float(_number(e, value, True)) if e.kind in ('INT', 'BOOLEAN') else value)
            _lay(found, block, e, value, curve=True)
            out.sources.setdefault(e.key, []).append((block, curve))
    waiting = [(block, curve, e) for block, curve, e, is_driver in entries if is_driver]
    while waiting:
        later = []
        for block, curve, e in waiting:
            try:
                value = _driver_value(block, e, when, values, driven)
            except _Later:
                later.append((block, curve, e))
                continue
            except (_Unknown, _Stale):
                if _counts_on(block, curve.data_path):
                    out.unknown.append((block, curve, _expression_words(curve)))
                continue
            values[e.key] = value
            _lay(found, block, e, value, curve=False)
            out.sources.setdefault(e.key, []).append((block, curve))
        if len(later) == len(waiting):
            for block, curve, e in later:      # drivers that read each other
                if _counts_on(block, curve.data_path):
                    out.unknown.append((block, curve, "a driver it reads, which reads it back"))
            break
        waiting = later
    out.pairs.extend(_changed(found))
    if blocks or readers:
        out.reached = None
    if out.unknown and not elsewhere and probe:
        # What only Blender works out (a Python expression, a distance, an
        # F-curve modifier): read from Blender's own refresh with every
        # modifier that makes more hidden on what it and the changes reach.
        # Refused only where that cannot be read.
        wanted = {}
        for block, curve, words in out.unknown:
            wanted.setdefault(_pointer(block), (block, set()))[1].add(curve.data_path)
        try:
            probed = probe_values(None, [(b, sorted(p)) for b, p in wanted.values()],
                                  extra=list(inputs) + [p[0] for p in out.pairs])
        except Exception:                                 # noqa: BLE001 - refused below instead
            probed = None
        if probed is not None:
            keys = {(_pointer(o), k) for o, k, v in probed}
            out.pairs = [p for p in out.pairs if (_pointer(p[0]), p[1]) not in keys] + probed
            out.probed = [(block, curve) for block, curve, words in out.unknown]
            out.unknown = []
    return out


def _modifier_targets(keywords):
    active = bpy.context.view_layer.objects.active if bpy.context.view_layer is not None else None
    if keywords.get('use_selected_objects'):
        chosen = [o for o in getattr(bpy.context, 'selected_objects', None) or [] if o != active]
        return ([active] if active is not None else []) + chosen
    return [active] if active is not None else []


def price_operator(path, keywords):
    """The price of `bpy.ops.<path>(**keywords)` before Blender runs it, for
    each of PRICED_OPERATORS (`_blenderkit_context`); a refusal is raised in
    words."""
    if not _is_real_blender():
        return
    keywords = dict(keywords)
    if path == 'object.join':
        price_join()
    elif path == 'object.make_links_data':
        price_link_data(keywords.get('type', 'OBDATA'))
    elif path == 'object.modifiers_copy_to_selected':
        price_modifiers_copy_to_selected()
    elif path == 'object.modifier_copy_to_selected':
        active = bpy.context.view_layer.objects.active
        price_copy_to_selected(active, keywords.get('modifier', ''),
                               list(getattr(bpy.context, 'selected_objects', None) or []))
    elif path == 'object.modifier_add':
        kind = keywords.get('type') or bpy.ops.object.modifier_add.get_rna_type().properties['type'].default
        price_add(kind, objects=_modifier_targets(keywords))
    elif path == 'object.modifier_copy':
        price_copy(keywords.get('modifier', ''), _modifier_targets(keywords))
    elif path in ('object.modifier_move_up', 'object.modifier_move_down'):
        for obj in _modifier_targets(keywords):
            check_move(keywords.get('modifier', ''), path.endswith('_up'), obj)
    elif path == 'object.modifier_move_to_index':
        for obj in _modifier_targets(keywords):
            check_move_to(keywords.get('modifier', ''), keywords.get('index', 0), obj)
    elif path == 'object.transform_apply':
        price_transform_apply(**keywords)
    elif path == 'mesh.subdivide':
        price_mesh_subdivide(**keywords)
    elif path == 'curve.subdivide':
        price_curve_subdivide(**keywords)
    elif path == 'object.quadriflow_remesh':
        price_quadriflow(**keywords)
    elif path == 'object.voxel_remesh':
        _sibling('_blenderkit_sculpt').refuse_voxel_remesh(bpy.context.view_layer.objects.active)
    elif path == 'object.metaball_add':
        price_metaball_add(**keywords)
    elif path in _MOVES:
        price_object_moves(path, keywords)
    elif path in _EDIT_GROWTH:
        price_edit_operator(path, keywords)
    elif path in ('mesh.intersect', 'mesh.intersect_boolean'):
        price_edit_intersect(**keywords)
    elif path in ('curve.extrude_move', 'curve.extrude'):
        price_curve_extrude(**keywords)
    elif path == 'mesh.subdivide_edgering':
        _sibling('_blenderkit_loopcut').check_edgering(int(keywords.get('number_cuts', 10)))
    elif path in ('object.duplicate', 'object.duplicate_move', 'object.duplicate_move_linked'):
        price_metaball_duplicates()
    elif path in ('mball.duplicate_move', 'mball.duplicate_metaelems'):
        price_metaball_edit_duplicate()
    elif path in ('curve.duplicate_move', 'curve.duplicate'):
        price_curve_duplicate(**keywords)
    elif path in _CURVE_PRIMITIVE_POINTS:
        price_curve_primitive(path, **keywords)
    elif path == 'render.render':
        named = keywords.get('scene') or ''
        price_render(bpy.data.scenes.get(named) if named else None)
    elif path in _RENDER_EVALUATIONS:
        rule, doing = _RENDER_EVALUATIONS[path]
        if rule is None or _keyword(path, keywords, rule[0]) == rule[1]:
            price_render(None, doing)
    elif path == 'sculpt.detail_flood_fill':
        price_detail_flood_fill()
    elif path == 'object.subdivision_set':
        _sibling('_blenderkit_multires').refuse_subdivision_set(**keywords)
        _price_subdivision_set_time(**keywords)
    elif path == 'object.multires_subdivide':
        obj = bpy.context.view_layer.objects.active
        if obj is not None and obj.type == 'MESH':
            name = keywords.get('modifier', '')
            modifier = obj.modifiers.get(name) if name else None
            if modifier is None:
                modifier = next((m for m in obj.modifiers if m.type == 'MULTIRES'), None)
            if modifier is not None and modifier.type == 'MULTIRES':
                _sibling('_blenderkit_multires').refuse_over_budget(obj, modifier.total_levels,
                                                                   'Multires Subdivide')
                price_multires_subdivide_time(_geometry_object(obj), modifier)


def _price_subdivision_set_time(level=1, relative=False, **_):
    """Subdivision Set's new or raised Subdivision Surface priced for its
    limit surface's time as Add Modifier and the row are (`_judge`): the count
    is `refuse_subdivision_set`'s."""
    active = bpy.context.view_layer.objects.active
    if active is not None and active.mode in ('SCULPT', 'VERTEX_PAINT', 'WEIGHT_PAINT', 'TEXTURE_PAINT'):
        objects = [active]
    else:
        objects = list(getattr(bpy.context, 'selected_editable_objects', None) or [])
    for obj in objects:
        if obj is None or obj.type not in GEOMETRY_TYPES:
            continue
        target = next((m for m in obj.modifiers if m.type in ('MULTIRES', 'SUBSURF')), None)
        if target is None:
            if level > 0 and obj.mode != 'SCULPT':
                price_add('SUBSURF', obj, settings={'levels': int(level)})
        elif target.type == 'SUBSURF':
            new = target.levels + level if relative else level
            if new > target.levels:
                price_modifier(target.name, {'levels': int(new)}, obj)


# The kinds that carry `eModifierTypeFlag_RequiresOriginalData` in 5.2.1's
# source, which Blender's Move Up and Move Down rules turn on.
_ORIGINAL_DATA = ('MULTIRES', 'SOFT_BODY')


def price_order(obj, order, change):
    """A new order of `obj`'s modifiers (`order`, their names), priced before
    Blender moves anything: refused when the new order is heavier than the old
    and passes the budget, or hands a Skin more loops than before past its
    cap. Before, not after: `bpy.ops` evaluates the view layer once a move has
    finished (in desktop 5.2.1 the Move Up of a level-4 Subdivision above a
    Skin took 44.1 s, round 4's review)."""
    if not _is_real_blender():
        return
    obj = _geometry_object(obj)
    if obj is None:
        return
    s = Prices()
    try:
        s.orders[_pointer(obj)] = list(order)
        _judge([obj] + [o for o in affected([obj], s) if o != obj], s, change,
               "Lower what the modifiers make first.")
    finally:
        s.close()


def check_move(name, up, obj=None):
    """Move Up or Move Down of the modifier `name` (the panel's arrows and the
    search's), priced before Blender moves it. Blender takes any swap of two
    modifiers neither of which needs the original mesh (`_ORIGINAL_DATA`);
    with one that does, it takes only a swap with a pure deform, which leaves
    the counts as they were, and cancels the rest itself."""
    if not _is_real_blender():
        return
    obj = obj if obj is not None else bpy.context.object
    if obj is None:
        return
    order = [m.name for m in obj.modifiers]
    if name not in order:
        return
    i = order.index(name)
    j = i - 1 if up else i + 1
    if not 0 <= j < len(order):
        return  # past an end: Blender cancels it
    if {obj.modifiers[i].type, obj.modifiers[j].type} & set(_ORIGINAL_DATA):
        return
    order[i], order[j] = order[j], order[i]
    price_order(obj, order, "Moving %s %s" % (name, "up" if up else "down"))


def check_move_to(name, index, obj=None):
    """The search's Move to Index."""
    if not _is_real_blender():
        return
    obj = obj if obj is not None else bpy.context.object
    if obj is None or obj.modifiers.get(name) is None:
        return
    order = [m.name for m in obj.modifiers]
    order.remove(name)
    index = max(0, min(int(index), len(order)))
    order.insert(index, name)
    if order == [m.name for m in obj.modifiers]:
        return
    price_order(obj, order, "Moving %s to %d" % (name, index))


# --------------------------------------------------------------------------
# The older calls, on the same model


def _legacy(obj, s, levels, add, sculpt, base, order):
    """`stack_vertices`' arguments as changes: `levels` maps a modifier's name
    to the one setting each kind used to be priced by (a level shown, a
    count, Replace Original, a Screw's or Ocean's settings as a dict), `add`
    is (kind, level) for a modifier not added yet, `base` counts standing in
    for the object's own, `order` the modifiers' names in a new order."""
    for name, override in (levels or {}).items():
        m = obj.modifiers.get(name)
        if m is None:
            continue
        s.shown.add(_pointer(m))
        if m.type == 'MULTIRES':
            s.change(m, 'sculpt_levels' if sculpt else 'levels', int(override))
            s.values[(_pointer(m), 'total_levels')] = max(m.total_levels, int(override))
        elif m.type == 'SUBSURF':
            s.change(m, 'levels', int(override))
        elif m.type == 'WIREFRAME':
            s.change(m, 'use_replace', bool(override))
        elif m.type == 'ARRAY':
            s.change(m, 'count', int(override))
        elif m.type in ('SCREW', 'OCEAN') and isinstance(override, dict):
            for key, value in override.items():
                if m.type == 'OCEAN' and key == 'resolution':
                    key = 'viewport_resolution'
                s.change(m, key, value)
        elif m.type == 'SCREW':
            s.change(m, 'steps', int(override))
        elif m.type == 'OCEAN':
            s.change(m, 'viewport_resolution', int(override))
    if add is not None:
        kind, level = add
        settings = None
        if kind == 'MULTIRES':
            level = int(level or 0)
            settings = {'levels': level, 'sculpt_levels': level, 'render_levels': level,
                        'total_levels': level}
        elif kind == 'SUBSURF':
            settings = {'levels': int(level or 0), 'render_levels': int(level or 0)}
        where = 'new'
        s.added[_pointer(obj)] = [(where, Virtual(kind, settings=settings))]
        if kind == 'MULTIRES':
            # The old call put a new Multires first.
            s.orders.pop(_pointer(obj), None)
    if base is not None:
        s.bases[_pointer(obj)] = tuple(int(n) for n in base)
    if order is not None:
        s.orders[_pointer(obj)] = list(order)


def stack_vertices(obj, levels=None, add=None, sculpt=None, base=None, order=None):
    """The vertices Blender's viewport evaluates `obj` to, the changes the
    arguments give (`_legacy`) made: its mesh — or what Blender makes of a
    text, curve or surface — then each modifier shown, in stack order. An
    exact count where the model is exact, an upper bound elsewhere, made
    exact as far as the budget allows when that bound passes it."""
    s = Prices()
    try:
        _legacy(obj, s, levels, add, sculpt, base, order)
        try:
            return _final(obj, s, sculpt).final.v
        except Unpriceable:
            return BUDGET * 1000
    finally:
        s.close()


def skin_loops(obj, levels=None, add=None, base=None, order=None):
    """(the most loops of edges, E - V + 1, any Skin shown in `obj`'s stack
    would be given, that Skin's name), or (0, None)."""
    s = Prices()
    try:
        _legacy(obj, s, levels, add, None, base, order)
        try:
            return _skin_loops(_final(obj, s))
        except Unpriceable:
            return (0, None)
    finally:
        s.close()


def refuse_slow_skin(obj, change, levels=None, add=None, base=None, order=None, before=None):
    """Raises, in words, when a change would hand a Skin in `obj`'s stack
    more than `SKIN_MAX_LOOPS` loops of edges — or, with `before` (the loops
    it gets now), more than it gets now when that is past the cap already."""
    loops, name = skin_loops(obj, levels, add, base, order)
    if loops <= SKIN_MAX_LOOPS or (before is not None and loops <= before):
        return
    raise RuntimeError("%s: %s" % (change, _skin_refusal(obj, loops)))


def price_channels(obj, fields, change=None):
    """The Transform fields' price (`TransformChannels.python(writing:)`):
    each (property, index, value) laid over the vector Blender holds, every
    property's whole new vector priced together (`price_all`)."""
    if obj is None:
        return
    vectors = {}
    for prop, index, value in fields:
        if prop not in vectors:
            vectors[prop] = list(getattr(obj, prop))
        if 0 <= int(index) < len(vectors[prop]):
            vectors[prop][int(index)] = float(value)
    price_all([(obj, prop, tuple(v)) for prop, v in vectors.items()], change)


def counted(owner, key, value):
    """{object name: the vertices the budget counts for it} with `owner.key`
    set to `value`, for every object the change reaches — what `price` judges
    of the viewport, without judging (the completeness check holds this to
    Blender's viewport count)."""
    return counted_all([(owner, key, value)])


def counted_all(changes):
    """`counted` for several changes at once, priced as `price_all` prices
    the viewport (the same `_pricing`): what a row that sends Levels Viewport
    and Render together is judged by."""
    s = _pricing([(o, k, v) for o, k, v in changes if o is not None], False)
    try:
        found = {}
        for obj in affected([o for o, k, v in changes if o is not None], s):
            try:
                found[obj.name] = _final(obj, s).final.v
            except Unpriceable:
                found[obj.name] = BUDGET * 1000
        return found
    finally:
        s.close()


def counted_add(kind, obj, settings=None):
    """The vertices the budget counts for `obj` with Add Modifier ▸ `kind`."""
    s = Prices()
    try:
        s.added[_pointer(obj)] = [('new', Virtual(kind, settings=settings))]
        try:
            return _final(obj, s).final.v
        except Unpriceable:
            return BUDGET * 1000
    finally:
        s.close()
