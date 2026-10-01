"""A `mathutils`-shaped module: Vector, Euler, Quaternion and Matrix.

Blender scripts reach for these constantly, so having them means most snippets
run unmodified. This is pure Python — no bridge involved — and follows
Blender's conventions: Euler rotations are XYZ by default, matrices are
row-indexed (`m[0]` is the first row) and multiply with `@`.
"""

import math

__all__ = ["Vector", "Euler", "Quaternion", "Matrix"]


class Vector:
    """An n-component vector; 3 components unless told otherwise."""

    __slots__ = ("_v",)

    def __init__(self, values=(0.0, 0.0, 0.0)):
        self._v = [float(c) for c in values]

    # -- component access -------------------------------------------------

    def _axis(i):
        def get(self):
            if i >= len(self._v):
                raise AttributeError("vector has no component %d" % i)
            return self._v[i]

        def set(self, value):
            self._v[i] = float(value)

        return property(get, set)

    x = _axis(0)
    y = _axis(1)
    z = _axis(2)
    w = _axis(3)
    del _axis

    def __getitem__(self, i):
        return self._v[i]

    def __setitem__(self, i, value):
        self._v[i] = float(value)

    def __len__(self):
        return len(self._v)

    def __iter__(self):
        return iter(self._v)

    # -- arithmetic -------------------------------------------------------

    def _pair(self, other):
        o = other._v if isinstance(other, Vector) else [float(c) for c in other]
        if len(o) != len(self._v):
            raise ValueError("vectors must have matching length")
        return o

    def __add__(self, other):
        return Vector([a + b for a, b in zip(self._v, self._pair(other))])

    def __sub__(self, other):
        return Vector([a - b for a, b in zip(self._v, self._pair(other))])

    def __neg__(self):
        return Vector([-a for a in self._v])

    def __mul__(self, k):
        if isinstance(k, (int, float)):
            return Vector([a * k for a in self._v])
        # Blender uses `@` for dot/matrix products; `*` with a vector is
        # component-wise, and mirroring that avoids a silent surprise.
        return Vector([a * b for a, b in zip(self._v, self._pair(k))])

    __rmul__ = __mul__

    def __truediv__(self, k):
        return Vector([a / k for a in self._v])

    def __matmul__(self, other):
        """Dot product with a vector, or transform by a matrix."""
        if isinstance(other, Matrix):
            return other._transform(self)
        return self.dot(other)

    def __eq__(self, other):
        try:
            return self._v == self._pair(other)
        except Exception:
            return NotImplemented

    def __hash__(self):
        return hash(tuple(self._v))

    # -- vector maths -----------------------------------------------------

    def dot(self, other):
        return sum(a * b for a, b in zip(self._v, self._pair(other)))

    def cross(self, other):
        a, b = self._v, self._pair(other)
        if len(a) != 3 or len(b) != 3:
            raise ValueError("cross product needs 3D vectors")
        return Vector((a[1] * b[2] - a[2] * b[1],
                       a[2] * b[0] - a[0] * b[2],
                       a[0] * b[1] - a[1] * b[0]))

    @property
    def length(self):
        return math.sqrt(sum(a * a for a in self._v))

    @property
    def length_squared(self):
        return sum(a * a for a in self._v)

    def normalized(self):
        n = self.length
        return Vector(self._v) if n == 0 else Vector([a / n for a in self._v])

    def normalize(self):
        n = self.length
        if n:
            self._v = [a / n for a in self._v]

    def copy(self):
        return Vector(self._v)

    def to_tuple(self, precision=-1):
        if precision < 0:
            return tuple(self._v)
        return tuple(round(a, precision) for a in self._v)

    def __repr__(self):
        return "Vector((" + ", ".join("%.4f" % a for a in self._v) + "))"


def _vector_rotation_difference(self, other):
    """`Vector.rotation_difference` — the rotation taking self onto other.

    The idiom for pointing a cylinder along an arbitrary direction, and the
    reason a great many object-placement scripts need it.
    """
    return _quat_between(self.normalized(), Vector(other).normalized())


def _vector_to_track_quat(self, track="Z", up="Y"):
    """`Vector.to_track_quat` — orient `track` along this vector."""
    axes = {"X": (1.0, 0.0, 0.0), "Y": (0.0, 1.0, 0.0), "Z": (0.0, 0.0, 1.0),
            "-X": (-1.0, 0.0, 0.0), "-Y": (0.0, -1.0, 0.0), "-Z": (0.0, 0.0, -1.0)}
    base = axes.get(track, (0.0, 0.0, 1.0))
    return _quat_between(base, self.normalized())


Vector.rotation_difference = _vector_rotation_difference
Vector.to_track_quat = _vector_to_track_quat


def _quat_between(a, b):
    """Shortest rotation taking unit vector `a` onto unit vector `b`."""
    dot = sum(x * y for x, y in zip(a, b))
    if dot > 0.999999:
        return Quaternion((1.0, 0.0, 0.0, 0.0))
    if dot < -0.999999:
        # Opposite: any perpendicular axis will do for a half turn.
        axis = Vector((1.0, 0.0, 0.0)).cross(Vector(a))
        if axis.length < 1e-6:
            axis = Vector((0.0, 1.0, 0.0)).cross(Vector(a))
        axis = axis.normalized()
        return Quaternion((0.0, axis.x, axis.y, axis.z))
    axis = Vector(a).cross(Vector(b))
    w = 1.0 + dot
    q = Quaternion((w, axis.x, axis.y, axis.z))
    return q.normalized()


class Euler:
    """An XYZ Euler rotation in radians — Blender's default rotation mode."""

    __slots__ = ("_v", "order")

    def __init__(self, angles=(0.0, 0.0, 0.0), order="XYZ"):
        self._v = [float(a) for a in angles]
        self.order = order

    def _axis(i):
        return property(lambda self: self._v[i],
                        lambda self, value: self._v.__setitem__(i, float(value)))

    x = _axis(0)
    y = _axis(1)
    z = _axis(2)
    del _axis

    def __getitem__(self, i):
        return self._v[i]

    def __setitem__(self, i, value):
        self._v[i] = float(value)

    def __len__(self):
        return 3

    def __iter__(self):
        return iter(self._v)

    def copy(self):
        return Euler(self._v, self.order)

    def to_matrix(self):
        return Matrix.Rotation_euler(self._v, self.order)

    def to_quaternion(self):
        cx, sx = math.cos(self._v[0] / 2), math.sin(self._v[0] / 2)
        cy, sy = math.cos(self._v[1] / 2), math.sin(self._v[1] / 2)
        cz, sz = math.cos(self._v[2] / 2), math.sin(self._v[2] / 2)
        return Quaternion((cx * cy * cz + sx * sy * sz,
                           sx * cy * cz - cx * sy * sz,
                           cx * sy * cz + sx * cy * sz,
                           cx * cy * sz - sx * sy * cz))

    def __repr__(self):
        return "Euler((%.4f, %.4f, %.4f), '%s')" % (*self._v, self.order)


class Quaternion:
    """(w, x, y, z), matching Blender's component order."""

    __slots__ = ("_v",)

    def __init__(self, values=(1.0, 0.0, 0.0, 0.0)):
        self._v = [float(c) for c in values]

    def _axis(i):
        return property(lambda self: self._v[i],
                        lambda self, value: self._v.__setitem__(i, float(value)))

    w = _axis(0)
    x = _axis(1)
    y = _axis(2)
    z = _axis(3)
    del _axis

    def __getitem__(self, i):
        return self._v[i]

    def __len__(self):
        return 4

    def to_euler(self, order="XYZ"):
        """XYZ Euler, matching the order Blender objects default to."""
        w, x, y, z = self._v
        # Standard quaternion-to-Euler for the Rz*Ry*Rx composition.
        sinr = 2 * (w * x + y * z)
        cosr = 1 - 2 * (x * x + y * y)
        roll = math.atan2(sinr, cosr)
        sinp = max(-1.0, min(1.0, 2 * (w * y - z * x)))
        pitch = math.asin(sinp)
        siny = 2 * (w * z + x * y)
        cosy = 1 - 2 * (y * y + z * z)
        yaw = math.atan2(siny, cosy)
        return Euler((roll, pitch, yaw))

    def __iter__(self):
        return iter(self._v)

    @property
    def magnitude(self):
        return math.sqrt(sum(a * a for a in self._v))

    def normalized(self):
        n = self.magnitude
        return Quaternion(self._v) if n == 0 else Quaternion([a / n for a in self._v])

    def __repr__(self):
        return "Quaternion((%.4f, %.4f, %.4f, %.4f))" % tuple(self._v)


class Matrix:
    """A 4x4 matrix, indexed by row like Blender's."""

    __slots__ = ("_rows",)

    def __init__(self, rows=None):
        if rows is None:
            self._rows = [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]
        else:
            self._rows = [[float(c) for c in row] for row in rows]

    # -- constructors -----------------------------------------------------

    @classmethod
    def Identity(cls, size=4):
        return cls()

    @classmethod
    def Translation(cls, v):
        m = cls()
        m._rows[0][3], m._rows[1][3], m._rows[2][3] = float(v[0]), float(v[1]), float(v[2])
        return m

    @classmethod
    def Scale(cls, factor, size=4, axis=None):
        m = cls()
        if axis is None:
            m._rows[0][0] = m._rows[1][1] = m._rows[2][2] = float(factor)
        else:
            for i in range(3):
                if axis[i]:
                    m._rows[i][i] = float(factor)
        return m

    @classmethod
    def Diagonal(cls, v):
        m = cls()
        for i in range(min(3, len(v))):
            m._rows[i][i] = float(v[i])
        return m

    @classmethod
    def Rotation(cls, angle, size=4, axis="Z"):
        c, s = math.cos(angle), math.sin(angle)
        m = cls()
        if axis in ("X", 0):
            m._rows[1][1], m._rows[1][2] = c, -s
            m._rows[2][1], m._rows[2][2] = s, c
        elif axis in ("Y", 1):
            m._rows[0][0], m._rows[0][2] = c, s
            m._rows[2][0], m._rows[2][2] = -s, c
        else:
            m._rows[0][0], m._rows[0][1] = c, -s
            m._rows[1][0], m._rows[1][1] = s, c
        return m

    @classmethod
    def Rotation_euler(cls, angles, order="XYZ"):
        m = cls()
        for axis, angle in zip(order, [angles["XYZ".index(a)] for a in order]):
            m = cls.Rotation(angle, 4, axis) @ m
        return m

    # -- operations -------------------------------------------------------

    def __getitem__(self, i):
        return self._rows[i]

    def __len__(self):
        return 4

    def __iter__(self):
        return iter(self._rows)

    def __matmul__(self, other):
        if isinstance(other, Matrix):
            out = [[sum(self._rows[i][k] * other._rows[k][j] for k in range(4))
                    for j in range(4)] for i in range(4)]
            return Matrix(out)
        return self._transform(other)

    def _transform(self, v):
        vals = list(v) + [1.0] * (4 - len(v)) if len(v) < 4 else list(v)
        out = [sum(self._rows[i][k] * vals[k] for k in range(4)) for i in range(4)]
        return Vector(out[:3]) if len(v) == 3 else Vector(out)

    def transposed(self):
        return Matrix([[self._rows[j][i] for j in range(4)] for i in range(4)])

    def copy(self):
        return Matrix(self._rows)

    @property
    def translation(self):
        return Vector((self._rows[0][3], self._rows[1][3], self._rows[2][3]))

    def to_translation(self):
        return self.translation

    def to_scale(self):
        return Vector([math.sqrt(sum(self._rows[i][j] ** 2 for i in range(3)))
                       for j in range(3)])

    def __repr__(self):
        return "Matrix((" + ",\n        ".join(
            "(" + ", ".join("%.4f" % c for c in row) + ")" for row in self._rows) + "))"
