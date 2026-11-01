"""Geometry Nodes counted for the vertex budget (round 4's fix round 2,
October 21).

Until this round a Geometry Nodes modifier was counted as keeping what it is
given (`_blenderkit_budget._UNMODELLED`), and the gate compared no node tree.
Round 4's fix round 2 review measured, in sandboxed desktop 5.2.1, a script
line building a node group with a Grid of 1,900 × 1,900 on a cube's Geometry
Nodes modifier: 3,610,000 vertices with no refusal; raising a Grid's Vertices
X and Y from 10 to 1,900 made 100 → 3,610,000 both from a script line and
from the Data API row (`set_property("bpy.data.node_groups['G'].nodes['Grid']
.inputs[2]", 'default_value', 1900)`).

So a node group is now read the way Blender would run it, node by node from
the Group Output back to what it is given, for an upper bound of what it
makes (`Geo`): a mesh's vertices, edges, faces and corners, the points of its
curves and point clouds, and its instances with what each holds. The numbers
that decide a count (a Grid's Vertices, a Mesh Line's Count, a Subdivide's
Level, Instance on Points' points) are read where they are constant: a
socket's own value, the modifier's input, a Value or Integer node, Math and
Integer Math on constants, a Switch on a constant. A count that hangs on a
field, a node not on these lists (a volume, a Mesh Boolean, a simulation or a
repeat zone, Distribute Points by a density field) cannot be counted ahead,
and is refused in words (`Unknown`) rather than let through: only Blender
running the group would say what it makes. Nodes that only move, mark or
read what they are given (Set Position, Set Shade Smooth — Smooth by Angle,
the one group the app's rows edit, is made of those — Store Named Attribute,
Transform) keep it; those that only take away (Delete Geometry, Merge by
Distance, Separate Geometry) are counted as keeping it, an upper bound.
"""

import math

import bpy


class Unknown(Exception):
    """What a group makes cannot be counted ahead: the words say which node."""


class Geo:
    """An upper bound of a geometry: a mesh (v, e, f, l), the points of its
    curves and point clouds, and its instances (how many, and the largest
    geometry one of them holds)."""
    __slots__ = ('v', 'e', 'f', 'l', 'points', 'instances', 'held')

    def __init__(self, v=0, e=0, f=0, l=0, points=0, instances=0, held=None):
        self.v, self.e, self.f, self.l = int(v), int(e), int(f), int(l)
        self.points, self.instances = int(points), int(instances)
        self.held = held

    def plus(self, other):
        held = self.held
        if other.held is not None and (held is None or other.held.size() > held.size()):
            held = other.held
        return Geo(self.v + other.v, self.e + other.e, self.f + other.f, self.l + other.l,
                   self.points + other.points, self.instances + other.instances, held)

    def size(self):
        """What it holds once every instance is made real (`realized`): the
        larger of two instanced geometries is the one that is larger then,
        not the one with more instances of its own."""
        return self.realized().total()

    def total(self):
        """What it holds in memory, counted as vertices: its own elements, and
        the instances themselves (not what they share)."""
        return self.v + self.points + self.instances

    def elements(self):
        """Points, as Duplicate Elements, Mesh to Points and Instance on Points
        read a geometry: every mesh vertex and every point."""
        return self.v + self.points

    def realized(self):
        """Every instance made real, at every level: Realize Instances
        realizes instances inside instances too (with Realize All, its
        default; a Depth only realizes less). Fix round 2's re-check,
        sandboxed desktop 5.2.1: Points (100) -> Instance on Points of
        [Instance on Points (Points 100, Grid 20 x 20)] -> Realize Instances,
        added by a script line, built 4,000,000 vertices with no refusal —
        this realized one level and counted the inner instances' grids as
        instances (100 x 100 of nothing)."""
        held = self.held.realized() if self.held is not None else Geo()
        n = self.instances
        return Geo(self.v + n * held.v, self.e + n * held.e, self.f + n * held.f, self.l + n * held.l,
                   self.points + n * held.points, 0, None)


def _mesh(v, e, f, l):
    return Geo(max(0, v), max(0, e), max(0, f), max(0, l))


# The most a single number in a count may be, where Blender has no limit of
# its own: past it, it is refused as a count no device can hold.
_MOST = 1 << 40


def _int(value, what):
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise Unknown(what) from None
    if math.isnan(number) or math.isinf(number):
        raise Unknown(what)
    return int(max(-_MOST, min(_MOST, number)))


# The nodes that pass on what they are given, unchanged in size (their first
# geometry input to their first geometry output).
_KEEPS = frozenset((
    'GeometryNodeSetPosition', 'GeometryNodeSetShadeSmooth', 'GeometryNodeSetMaterial',
    'GeometryNodeSetMaterialIndex', 'GeometryNodeStoreNamedAttribute', 'GeometryNodeCaptureAttribute',
    'GeometryNodeSetID', 'GeometryNodeTransform', 'GeometryNodeSetCurveRadius', 'GeometryNodeSetCurveTilt',
    'GeometryNodeSetCurveNormal', 'GeometryNodeSetCurveHandlePositions', 'GeometryNodeCurveSetHandles',
    'GeometryNodeSetSplineCyclic', 'GeometryNodeSetPointRadius', 'GeometryNodeSortElements',
    'GeometryNodeRotateInstances', 'GeometryNodeTranslateInstances', 'GeometryNodeScaleInstances',
    'GeometryNodeSetInstanceTransform', 'GeometryNodeFlipFaces', 'GeometryNodeScaleElements',
    'GeometryNodeRemoveAttribute', 'GeometryNodeViewer', 'GeometryNodeWarning', 'GeometryNodeReverseCurve',
    'GeometryNodeSetMeshNormal', 'GeometryNodeSetGeometryName', 'GeometryNodeBake',
    'GeometryNodeSetFaceSet', 'GeometryNodeSetSplineType',
    # What only takes away: an upper bound kept as it was given.
    'GeometryNodeDeleteGeometry', 'GeometryNodeMergeByDistance', 'GeometryNodeSeparateGeometry',
    'GeometryNodeSeparateComponents', 'GeometryNodeTrimCurve', 'GeometryNodeMeshFaceSetBoundaries',
))


# The nodes that make a geometry from one geometry, which Blender runs on
# every geometry nested in its instances too (`_Group._each`).
_EACH = frozenset((
    'GeometryNodeSubdivideMesh', 'GeometryNodeSubdivisionSurface', 'GeometryNodeTriangulate',
    'GeometryNodeDualMesh', 'GeometryNodeSplitEdges', 'GeometryNodeExtrudeMesh', 'GeometryNodeDuplicateElements',
    'GeometryNodeMeshToPoints', 'GeometryNodePointsToVertices', 'GeometryNodeMeshToCurve',
    'GeometryNodeCurveToPoints', 'GeometryNodeResampleCurve', 'GeometryNodeSubdivideCurve',
    'GeometryNodeFilletCurve', 'GeometryNodeFillCurve', 'GeometryNodeCurveToMesh',
))


class _Group:
    """One node group being read, with what its Group Input gives: the
    geometry (`given`) and the values (`values`, by the interface socket's
    identifier, a callable that reads it)."""

    def __init__(self, counter, tree, given, values, depth):
        self.counter, self.tree, self.given, self.values = counter, tree, given, values
        self.depth = depth
        self.memo = {}

    def get(self, owner, key):
        """A node's or a socket's setting, as the price lays its changes
        over Blender's (`_blenderkit_budget.Prices.get`)."""
        return self.counter.read(owner, key)

    # -- following links

    def _source(self, socket):
        """(node, output socket) feeding `socket`, through reroutes, or
        None when it is not linked (or muted)."""
        links = [link for link in socket.links if not link.is_muted and link.is_valid]
        if not links:
            return None
        link = links[0]
        node, out = link.from_node, link.from_socket
        seen = 0
        while node.bl_idname == 'NodeReroute':
            seen += 1
            inner = [l for l in node.inputs[0].links if not l.is_muted and l.is_valid] if node.inputs else []
            if not inner or seen > 256:
                return None
            node, out = inner[0].from_node, inner[0].from_socket
        return node, out

    def geometry(self, socket):
        """The geometry an input socket is given: every link of a
        multi-input (Join Geometry's), nothing when it is not linked."""
        if socket is None:
            return Geo()
        links = [link for link in socket.links if not link.is_muted and link.is_valid]
        total = Geo()
        for link in links:
            node, out = link.from_node, link.from_socket
            seen = 0
            while node.bl_idname == 'NodeReroute':
                seen += 1
                inner = [l for l in node.inputs[0].links if not l.is_muted and l.is_valid] if node.inputs else []
                if not inner or seen > 256:
                    node = None
                    break
                node, out = inner[0].from_node, inner[0].from_socket
            if node is None:
                continue
            total = total.plus(self.output(node, out))
        return total

    def value(self, socket):
        """The constant an input socket is given, or `Unknown`."""
        source = self._source(socket)
        if source is None:
            value = self.get(socket, 'default_value') if hasattr(socket, 'default_value') else None
            if value is None:
                raise Unknown(self._words(socket.node, socket.name))
            return value.name if hasattr(value, 'name') and not isinstance(value, str) else value
        node, out = source
        return self.output_value(node, out)

    def number(self, node, name):
        socket = node.inputs.get(name)
        if socket is None:
            raise Unknown(self._words(node, name))
        return _int(self.value(socket), self._words(node, name))

    def real(self, node, name):
        socket = node.inputs.get(name)
        if socket is None:
            raise Unknown(self._words(node, name))
        try:
            return float(self.value(socket))
        except (TypeError, ValueError):
            raise Unknown(self._words(node, name)) from None

    def _words(self, node, what=None):
        name = node.label or node.name
        if what:
            return "the %s of %s (in %s)" % (what, name, self.tree.name)
        return "%s (in %s)" % (name, self.tree.name)

    # -- values

    def output_value(self, node, out):
        kind = node.bl_idname
        if kind == 'NodeGroupInput':
            read = self.values.get(out.identifier)
            if read is None:
                raise Unknown("the group input %s of %s" % (out.name, self.tree.name))
            return read()
        if kind == 'FunctionNodeInputInt':
            return self.get(node, 'integer')
        if kind == 'FunctionNodeInputBool':
            return self.get(node, 'boolean')
        if kind == 'FunctionNodeInputVector':
            return tuple(self.get(node, 'vector'))
        if kind == 'ShaderNodeValue':
            return self.get(node.outputs[0], 'default_value')
        if kind == 'FunctionNodeInputString':
            return self.get(node, 'string')
        if kind == 'ShaderNodeMath':
            return self._math(node)
        if kind == 'FunctionNodeIntegerMath':
            return self._integer_math(node)
        if kind == 'FunctionNodeFloatToInt':
            x = self.real(node, 'Float')
            mode = self.get(node, 'rounding_mode')
            return {'ROUND': round(x), 'FLOOR': math.floor(x), 'CEILING': math.ceil(x),
                    'TRUNCATE': math.trunc(x)}.get(mode, round(x))
        if kind == 'ShaderNodeClamp':
            x, a, b = self.real(node, 'Value'), self.real(node, 'Min'), self.real(node, 'Max')
            if self.get(node, 'clamp_type') == 'RANGE' and a > b:
                a, b = b, a
            return min(max(x, a), b)
        if kind in ('GeometryNodeSwitch', 'GeometryNodeIndexSwitch', 'GeometryNodeMenuSwitch'):
            return self.value(self._switched(node))
        if kind == 'GeometryNodeGroup':
            return self._group_value(node, out)
        raise Unknown(self._words(node))

    def _math(self, node):
        op = self.get(node, 'operation')
        values = [s for s in node.inputs if s.enabled]
        a = float(self.value(values[0])) if values else 0.0
        b = float(self.value(values[1])) if len(values) > 1 else 0.0
        c = float(self.value(values[2])) if len(values) > 2 else 0.0
        try:
            result = {
                'ADD': lambda: a + b, 'SUBTRACT': lambda: a - b, 'MULTIPLY': lambda: a * b,
                'DIVIDE': lambda: a / b if b else 0.0, 'MULTIPLY_ADD': lambda: a * b + c,
                'POWER': lambda: math.pow(a, b), 'MINIMUM': lambda: min(a, b), 'MAXIMUM': lambda: max(a, b),
                'ABSOLUTE': lambda: abs(a), 'ROUND': lambda: math.floor(a + 0.5), 'FLOOR': lambda: math.floor(a),
                'CEIL': lambda: math.ceil(a), 'TRUNC': lambda: math.trunc(a), 'SQRT': lambda: math.sqrt(a),
                'MODULO': lambda: math.fmod(a, b) if b else 0.0, 'SNAP': lambda: math.floor(a / b) * b if b else 0.0,
                'LOGARITHM': lambda: math.log(a, b), 'EXPONENT': lambda: math.exp(a),
                'SIGN': lambda: math.copysign(1.0, a) if a else 0.0,
            }[op]()
        except KeyError:
            raise Unknown(self._words(node, op.replace('_', ' ').title())) from None
        except (ValueError, OverflowError, ZeroDivisionError):
            raise Unknown(self._words(node)) from None
        if self.get(node, 'use_clamp'):
            result = min(max(result, 0.0), 1.0)
        return result

    def _integer_math(self, node):
        op = self.get(node, 'operation')
        values = [s for s in node.inputs if s.enabled]
        a = _int(self.value(values[0]), self._words(node)) if values else 0
        b = _int(self.value(values[1]), self._words(node)) if len(values) > 1 else 0
        c = _int(self.value(values[2]), self._words(node)) if len(values) > 2 else 0
        try:
            return {
                'ADD': lambda: a + b, 'SUBTRACT': lambda: a - b, 'MULTIPLY': lambda: a * b,
                'DIVIDE': lambda: int(a / b) if b else 0, 'DIVIDE_FLOOR': lambda: a // b if b else 0,
                'DIVIDE_CEIL': lambda: -((-a) // b) if b else 0, 'DIVIDE_ROUND': lambda: round(a / b) if b else 0,
                'MULTIPLY_ADD': lambda: a * b + c, 'POWER': lambda: a ** b if b >= 0 else 0,
                'MINIMUM': lambda: min(a, b), 'MAXIMUM': lambda: max(a, b), 'ABSOLUTE': lambda: abs(a),
                'NEGATE': lambda: -a, 'MODULO': lambda: math.fmod(a, b) if b else 0,
                'FLOORED_MODULO': lambda: a % b if b else 0, 'SIGN': lambda: (a > 0) - (a < 0),
            }[op]()
        except KeyError:
            raise Unknown(self._words(node, op.replace('_', ' ').title())) from None
        except (ValueError, OverflowError):
            raise Unknown(self._words(node)) from None

    def _switched(self, node):
        """The input a Switch, Index Switch or Menu Switch passes on, read
        from a constant choice."""
        kind = node.bl_idname
        if kind == 'GeometryNodeSwitch':
            choice = self.value(node.inputs[0])
            return node.inputs[2] if bool(choice) else node.inputs[1]
        if kind == 'GeometryNodeIndexSwitch':
            index = _int(self.value(node.inputs[0]), self._words(node, 'Index'))
            items = [s for s in node.inputs[1:] if s.identifier != '__extend__']
            if not 0 <= index < len(items):
                raise Unknown(self._words(node, 'Index'))
            return items[index]
        choice = self.value(node.inputs[0])
        for socket in node.inputs[1:]:
            if socket.name == choice:
                return socket
        raise Unknown(self._words(node, 'Menu'))

    # -- geometry

    def output(self, node, out):
        key = (node.as_pointer(), out.identifier)
        if key in self.memo:
            return self.memo[key]
        self.memo[key] = Geo()   # a cycle reads as nothing, once
        made = self._make(node, out)
        self.memo[key] = made
        return made

    def _first_geometry(self, node):
        for socket in node.inputs:
            if socket.type == 'GEOMETRY':
                return socket
        return None

    def _make(self, node, out):
        kind = node.bl_idname
        if out.type != 'GEOMETRY':
            raise Unknown(self._words(node))
        if self.get(node, 'mute'):
            # A muted node passes its first geometry input on.
            return self.geometry(self._first_geometry(node))
        if kind == 'NodeGroupInput':
            return self.given if out.identifier in self.counter.geometry_inputs(self.tree) else Geo()
        if kind in _KEEPS:
            return self.geometry(self._first_geometry(node))
        if kind == 'GeometryNodeGroup':
            return self._group_geometry(node, out)
        if kind in ('GeometryNodeSwitch', 'GeometryNodeIndexSwitch', 'GeometryNodeMenuSwitch'):
            return self.geometry(self._switched(node))
        if kind == 'GeometryNodeJoinGeometry':
            return self.geometry(node.inputs[0])
        if kind == 'GeometryNodeMeshGrid':
            x, y = self.number(node, 'Vertices X'), self.number(node, 'Vertices Y')
            if x < 1 or y < 1:
                return Geo()
            f = max(0, x - 1) * max(0, y - 1)
            return _mesh(x * y, x * max(0, y - 1) + y * max(0, x - 1), f, 4 * f)
        if kind == 'GeometryNodeMeshCube':
            x, y, z = (max(1, self.number(node, n)) for n in ('Vertices X', 'Vertices Y', 'Vertices Z'))
            v = 2 * (x * y + y * z + x * z)
            f = 2 * (max(1, x - 1) * max(1, y - 1) + max(1, y - 1) * max(1, z - 1) + max(1, x - 1) * max(1, z - 1))
            return _mesh(v, 2 * v + f, f, 4 * f)
        if kind == 'GeometryNodeMeshUVSphere':
            s, r = max(3, self.number(node, 'Segments')), max(2, self.number(node, 'Rings'))
            return _mesh(s * (r - 1) + 2, s * (2 * r - 1), s * r, 4 * s * r)
        if kind == 'GeometryNodeMeshIcoSphere':
            n = min(10, max(1, self.number(node, 'Subdivisions')))
            k = 4 ** (n - 1)
            return _mesh(10 * k + 2, 30 * k, 20 * k, 60 * k)
        if kind in ('GeometryNodeMeshCylinder', 'GeometryNodeMeshCone'):
            v = max(3, self.number(node, 'Vertices'))
            sides = max(1, self.number(node, 'Side Segments'))
            fill = max(1, self.number(node, 'Fill Segments'))
            verts = v * (sides + 1) + 2 * (v * fill + 1)
            faces = v * sides + 2 * v * fill
            return _mesh(verts, 2 * verts + faces, faces, 4 * faces)
        if kind == 'GeometryNodeMeshLine':
            if self.get(node, 'mode') == 'OFFSET' or self.get(node, 'count_mode') == 'TOTAL':
                n = self.number(node, 'Count')
            else:
                raise Unknown(self._words(node, 'Resolution'))
            n = max(0, n)
            return _mesh(n, max(0, n - 1), 0, 0)
        if kind == 'GeometryNodeMeshCircle':
            n = max(3, self.number(node, 'Vertices'))
            fill = self.get(node, 'fill_type')
            if fill == 'TRIANGLE_FAN':
                return _mesh(n + 1, 2 * n, n, 3 * n)
            return _mesh(n, n, 1 if fill == 'NGON' else 0, n if fill == 'NGON' else 0)
        if kind == 'GeometryNodePoints':
            return Geo(points=max(0, self.number(node, 'Count')))
        if kind == 'GeometryNodeCurvePrimitiveCircle':
            return Geo(points=max(3, self.number(node, 'Resolution')))
        if kind == 'GeometryNodeCurveSpiral':
            turns = abs(self.real(node, 'Rotations'))
            return Geo(points=int(math.ceil(max(1, self.number(node, 'Resolution')) * max(turns, 1.0))) + 1)
        if kind == 'GeometryNodeCurveStar':
            return Geo(points=2 * max(3, self.number(node, 'Points')))
        if kind in ('GeometryNodeCurveArc', 'GeometryNodeCurveQuadraticBezier',
                    'GeometryNodeCurvePrimitiveBezierSegment'):
            return Geo(points=max(2, self.number(node, 'Resolution')) + 2)
        if kind in ('GeometryNodeCurvePrimitiveLine', 'GeometryNodeCurvePrimitiveQuadrilateral'):
            return Geo(points=4)
        if kind in _EACH:
            # What the node makes of a geometry's own mesh, points and curves
            # (`_one`), and of every geometry its instances hold (`_each`).
            if kind == 'GeometryNodeDuplicateElements' and self.get(node, 'domain') == 'INSTANCE':
                g = self.geometry(node.inputs[0])
                amount = max(0, self.number(node, 'Amount'))
                return Geo(instances=g.instances * amount, held=g.held)
            source = node.inputs['Curve'] if kind == 'GeometryNodeCurveToMesh' else node.inputs[0]
            return self._each(self.geometry(source), lambda g: self._one(node, kind, g))
        if kind == 'GeometryNodeConvexHull':
            g = self.geometry(node.inputs[0])
            n = g.realized().elements()
            return _mesh(n, 3 * n, 2 * n, 6 * n)
        if kind == 'GeometryNodeBoundBox':
            return _mesh(8, 12, 6, 24)
        if kind == 'GeometryNodeInstanceOnPoints':
            points = self.geometry(node.inputs['Points'])
            held = self.geometry(node.inputs['Instance'])
            # On the points of the geometry and on those inside its
            # instances, at every level (see `_each`).
            return self._each(points, lambda g: Geo(instances=g.elements(), held=held))
        if kind == 'GeometryNodeGeometryToInstance':
            g = self.geometry(node.inputs[0])
            return Geo(instances=max(1, len(node.inputs[0].links)), held=g)
        if kind == 'GeometryNodeRealizeInstances':
            return self.geometry(node.inputs[0]).realized()
        if kind == 'GeometryNodeObjectInfo':
            obj = self.value(node.inputs['Object']) if node.inputs['Object'].is_linked else \
                self.get(node.inputs['Object'], 'default_value')
            if isinstance(obj, str):
                obj = bpy.data.objects.get(obj)
            if obj is None:
                return Geo()
            made = self.counter.object_counts(obj)
            as_instance = self.value(node.inputs['As Instance'])
            return Geo(instances=1, held=made) if as_instance else made
        if kind == 'GeometryNodeCollectionInfo':
            collection = self.get(node.inputs['Collection'], 'default_value')
            if node.inputs['Collection'].is_linked:
                collection = self.value(node.inputs['Collection'])
                if isinstance(collection, str):
                    collection = bpy.data.collections.get(collection)
            if collection is None:
                return Geo()
            total = Geo()
            objects = list(collection.all_objects)
            for obj in objects:
                total = total.plus(self.counter.object_counts(obj))
            try:
                separate = bool(self.value(node.inputs['Separate Children']))
            except (Unknown, KeyError):
                return Geo(instances=max(1, len(objects)), held=total)
            if not separate:
                # One instance of the whole collection
                # (node_geo_collection_info.cc): realized, every object once.
                # Counted as one instance per object holding them all, it
                # took the collection's objects times what they hold (fix
                # round 3: a 1000 x 1000 grid duplicated once into the
                # collection was counted at 4,008,004 where Blender makes
                # 2,004,002).
                return Geo(instances=1, held=total)
            # One instance per child, object or collection, each holding at
            # most the largest child's geometry.
            largest = None
            for child in list(collection.objects) + list(collection.children):
                if isinstance(child, bpy.types.Collection):
                    made = Geo()
                    for obj in child.all_objects:
                        made = made.plus(self.counter.object_counts(obj))
                else:
                    made = self.counter.object_counts(child)
                if largest is None or made.size() > largest.size():
                    largest = made
            children = len(collection.objects) + len(collection.children)
            return Geo(instances=max(1, children), held=largest or Geo())
        if kind == 'GeometryNodeStringToCurves':
            text = self.value(node.inputs['String'])
            # Each character's outline, at most the points of the densest
            # letter at the font's resolution: measured in desktop 5.2.1 with
            # the default font, "@" 26 points at Resolution 1, 244 at 12.
            return Geo(instances=len(str(text)), held=Geo(points=1300))
        if kind == 'GeometryNodeDistributePointsOnFaces':
            raise Unknown(self._words(node, 'Density') + ", which reads the faces' area")
        raise Unknown(self._words(node))

    def _each(self, g, one):
        """`one` (what a node makes of one geometry's own mesh, points and
        curves) on `g`, and on what `g`'s instances hold, at every level:
        Blender runs such a node on every geometry nested in instances
        (`GeometrySet::modify_geometry_sets`). Fix round 3 (October 29),
        sandboxed desktop 5.2.1: Points (10) -> Instance on Points (a Grid
        3 × 3) -> Instance on Points (a Cube) -> Realize Instances made 720
        vertices, counted 0 — the second Instance on Points instanced on
        each grid instance's points; and a Subdivide Mesh between instancing
        and realizing subdivides the instanced meshes too."""
        made = one(Geo(g.v, g.e, g.f, g.l, g.points))
        if g.held is None or not g.instances:
            return made
        inner = self._each(g.held, one)
        held = inner if made.held is None or inner.size() >= made.held.size() else made.held
        return Geo(made.v, made.e, made.f, made.l, made.points, made.instances + g.instances, held)

    def _one(self, node, kind, g):
        """What the node `kind` makes of the geometry `g`, which holds no
        instances (`_each` takes those)."""
        if kind in ('GeometryNodeSubdivideMesh', 'GeometryNodeSubdivisionSurface'):
            level = max(0, min(11, self.number(node, 'Level')))
            return self._subdivided(g, level)
        if kind == 'GeometryNodeTriangulate':
            tris = max(0, g.l - 2 * g.f)
            return Geo(g.v, g.e + max(0, g.l - 3 * g.f), tris, 3 * tris, g.points, g.instances, g.held)
        if kind == 'GeometryNodeDualMesh':
            return Geo(g.f + g.e, g.e + g.l, g.v, g.l + 2 * g.e, g.points, g.instances, g.held)
        if kind == 'GeometryNodeSplitEdges':
            return Geo(max(g.v, g.l), g.e + g.l, g.f, g.l, g.points, g.instances, g.held)
        if kind == 'GeometryNodeExtrudeMesh':
            mode = self.get(node, 'mode')
            if mode == 'FACES':
                return Geo(g.v + g.l, g.e + 2 * g.l, g.f + g.l, g.l + 4 * g.l, g.points, g.instances, g.held)
            if mode == 'EDGES':
                return Geo(2 * g.v, 3 * g.e + g.v, g.f + g.e, g.l + 4 * g.e, g.points, g.instances, g.held)
            return Geo(2 * g.v, g.e + g.v, g.f, g.l, g.points, g.instances, g.held)
        if kind == 'GeometryNodeDuplicateElements':
            amount = max(0, self.number(node, 'Amount'))
            domain = self.get(node, 'domain')
            if domain == 'INSTANCE':
                return Geo(instances=g.instances * amount, held=g.held)
            if domain == 'POINT':
                return Geo(g.v * amount, 0, 0, 0, g.points * amount)
            if domain == 'EDGE':
                return Geo(2 * g.e * amount, g.e * amount, 0, 0)
            if domain == 'FACE':
                return Geo(g.l * amount, g.l * amount, g.f * amount, g.l * amount)
            return Geo(points=g.points * amount)
        if kind == 'GeometryNodeMeshToPoints':
            return Geo(points=max(g.v, g.e, g.f, g.l))
        if kind == 'GeometryNodePointsToVertices':
            return _mesh(g.points, 0, 0, 0)
        if kind == 'GeometryNodeMeshToCurve':
            return Geo(points=2 * g.e)
        if kind == 'GeometryNodeCurveToPoints':
            if self.get(node, 'mode') == 'COUNT':
                return Geo(points=max(0, self.number(node, 'Count')) * max(1, g.points))
            if self.get(node, 'mode') == 'EVALUATED':
                return Geo(points=g.points)
            raise Unknown(self._words(node, 'Length'))
        if kind == 'GeometryNodeResampleCurve':
            mode = self.value(node.inputs['Mode']) if node.inputs.get('Mode') is not None else 'Count'
            if mode in ('Count', 'COUNT'):
                return Geo(points=max(1, self.number(node, 'Count')) * max(1, g.points))
            if mode in ('Evaluated', 'EVALUATED'):
                return Geo(points=g.points)
            raise Unknown(self._words(node, 'Length'))
        if kind == 'GeometryNodeSubdivideCurve':
            return Geo(points=g.points * (max(0, self.number(node, 'Cuts')) + 1))
        if kind == 'GeometryNodeFilletCurve':
            mode = self.value(node.inputs['Mode']) if node.inputs.get('Mode') is not None else 'Poly'
            if mode in ('Poly', 'POLY'):
                return Geo(points=g.points * (max(1, self.number(node, 'Count')) + 1))
            return Geo(points=3 * g.points)
        if kind == 'GeometryNodeFillCurve':
            return _mesh(g.points, 3 * g.points, 2 * g.points, 3 * g.points)
        if kind == 'GeometryNodeCurveToMesh':
            curve = g
            profile = self.geometry(node.inputs['Profile Curve'])
            n = max(1, profile.points)
            v = curve.points * n + 2 * n
            return _mesh(v, 2 * v, v, 4 * v)
        raise Unknown(self._words(node))

    def _subdivided(self, g, level):
        v, e, f, l = g.v, g.e, g.f, g.l
        for _ in range(level):
            v, e, f, l = v + e + f, 2 * e + l, l, 4 * l
            if v > _MOST:
                break
        return Geo(v, e, f, l, g.points, g.instances, g.held)

    # -- groups inside groups

    def _inner(self, node):
        tree = self.get(node, 'node_tree')
        if tree is None:
            return None
        if self.depth >= 32:
            raise Unknown("%s, groups nested more than 32 deep" % self._words(node))
        given = Geo()
        values = {}
        for socket in node.inputs:
            if socket.type == 'GEOMETRY':
                given = given.plus(self.geometry(socket))
            else:
                values[socket.identifier] = (lambda s=socket: self.value(s))
        return _Group(self.counter, tree, given, values, self.depth + 1)

    def _group_geometry(self, node, out):
        inner = self._inner(node)
        if inner is None:
            return Geo()
        return inner.result(out.identifier)

    def _group_value(self, node, out):
        inner = self._inner(node)
        if inner is None:
            raise Unknown(self._words(node))
        output = inner.group_output()
        if output is None:
            raise Unknown(self._words(node))
        socket = next((s for s in output.inputs if s.identifier == out.identifier), None)
        if socket is None:
            raise Unknown(self._words(node))
        return inner.value(socket)

    def group_output(self):
        found = [n for n in self.tree.nodes if n.bl_idname == 'NodeGroupOutput']
        active = [n for n in found if getattr(n, 'is_active_output', False)]
        return (active or found or [None])[0]

    def result(self, identifier=None):
        """What the group makes at its output `identifier` (the first
        geometry output when None)."""
        kinds = [n.bl_idname for n in self.tree.nodes]
        for zone in ('GeometryNodeRepeatInput', 'GeometryNodeSimulationInput',
                     'GeometryNodeForeachGeometryElementInput'):
            if zone in kinds:
                raise Unknown("the %s zone of %s" % ({
                    'GeometryNodeRepeatInput': 'Repeat', 'GeometryNodeSimulationInput': 'Simulation',
                    'GeometryNodeForeachGeometryElementInput': 'For Each Element'}[zone], self.tree.name))
        output = self.group_output()
        if output is None:
            return Geo()
        for socket in output.inputs:
            if socket.type == 'GEOMETRY' and (identifier is None or socket.identifier == identifier):
                return self.geometry(socket)
        return Geo()


def input_of(modifier, identifier):
    """A Geometry Nodes modifier's input `identifier`, as Blender 5 holds it
    (`modifier.properties.inputs.Socket_2`, with `value` and `type`), or
    None (a modifier the price adds, not made yet)."""
    inputs = getattr(getattr(modifier, 'properties', None), 'inputs', None)
    if inputs is None:
        return None
    try:
        return getattr(inputs, identifier, None)
    except (AttributeError, TypeError):
        return None


def inputs_of(modifier):
    """Each of a Geometry Nodes modifier's inputs (see `input_of`)."""
    inputs = getattr(getattr(modifier, 'properties', None), 'inputs', None)
    if inputs is None:
        return []
    found = []
    for prop in inputs.bl_rna.properties:
        if prop.type == 'POINTER' and prop.identifier != 'rna_type':
            holder = getattr(inputs, prop.identifier, None)
            if holder is not None:
                found.append(holder)
    return found


class Counter:
    """What a Geometry Nodes modifier makes (`count`), for the budget's walk:
    `object_counts` is the walk's own count of another object (an Object
    Info's, a Collection Info's)."""

    def __init__(self, object_counts, read):
        self.object_counts = object_counts
        self.read = read
        self._geometry_inputs = {}

    def geometry_inputs(self, tree):
        key = tree.as_pointer()
        found = self._geometry_inputs.get(key)
        if found is None:
            found = set()
            for item in tree.interface.items_tree:
                if getattr(item, 'item_type', '') == 'SOCKET' and item.in_out == 'INPUT' \
                        and item.socket_type == 'NodeSocketGeometry':
                    found.add(item.identifier)
            self._geometry_inputs[key] = found
        return found

    def count(self, modifier, given):
        """Geo of what `modifier`'s group makes from `given` (a Geo), every
        setting read through `read(owner, key)` (the price's own values laid
        over Blender's)."""
        read = self.read
        tree = read(modifier, 'node_group')
        if tree is None:
            return given
        values = {}
        for item in tree.interface.items_tree:
            if getattr(item, 'item_type', '') != 'SOCKET' or item.in_out != 'INPUT':
                continue
            if item.socket_type == 'NodeSocketGeometry':
                continue
            identifier = item.identifier

            def value(identifier=identifier, item=item):
                holder = input_of(modifier, identifier)
                if holder is not None:
                    # Blender 5's modifier inputs: `properties.inputs.<identifier>`,
                    # its `value` and whether it is read from an attribute.
                    if read(holder, 'type') == 'ATTRIBUTE':
                        raise Unknown("the modifier's input %s, read from an attribute" % item.name)
                    found = read(holder, 'value')
                else:
                    found = getattr(item, 'default_value', None)
                if found is None:
                    raise Unknown("the modifier's input %s" % item.name)
                return found
            values[identifier] = value
        return _Group(self, tree, given, values, 0).result()
