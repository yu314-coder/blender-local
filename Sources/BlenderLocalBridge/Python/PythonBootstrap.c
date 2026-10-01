#include "PythonBootstrap.h"
#include <Python/Python.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>

// ---------------------------------------------------------------------------
// The `_blenderkit` extension module.
//
// This is the whole surface the bundled `bpy` shim is written against. Keeping
// it small and boring means the interesting API shape lives in Python, where it
// is far easier to match Blender's.
// ---------------------------------------------------------------------------

static PyObject *bk_add(PyObject *self, PyObject *args)
{
    const char *kind;
    double x = 0, y = 0, z = 0;
    if (!PyArg_ParseTuple(args, "s|ddd", &kind, &x, &y, &z)) return NULL;

    char name[256] = {0};
    if (bk_scene_add_primitive(kind, x, y, z, name, (int)sizeof(name)) != 0) {
        PyErr_Format(PyExc_ValueError, "unknown primitive: %s", kind);
        return NULL;
    }
    return PyUnicode_FromString(name);
}

static PyObject *bk_add_torus(PyObject *self, PyObject *args)
{
    double x = 0, y = 0, z = 0, major = 1, minor = 0.25;
    int major_seg = 48, minor_seg = 12;
    if (!PyArg_ParseTuple(args, "ddddd|ii", &x, &y, &z, &major, &minor,
                          &major_seg, &minor_seg)) return NULL;
    char name[256] = {0};
    if (bk_scene_add_torus(x, y, z, major, minor, major_seg, minor_seg,
                           name, (int)sizeof(name)) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "no scene to add to");
        return NULL;
    }
    return PyUnicode_FromString(name);
}

static PyObject *bk_delete(PyObject *self, PyObject *args)
{
    return PyLong_FromLong(bk_scene_delete_selected());
}

static PyObject *bk_duplicate(PyObject *self, PyObject *args)
{
    return PyLong_FromLong(bk_scene_duplicate_selected());
}

static PyObject *bk_select_all(PyObject *self, PyObject *args)
{
    int on = 1;
    if (!PyArg_ParseTuple(args, "|p", &on)) return NULL;
    bk_scene_select_all(on);
    Py_RETURN_NONE;
}

static PyObject *bk_select(PyObject *self, PyObject *args)
{
    const char *name;
    int on = 1;
    if (!PyArg_ParseTuple(args, "s|p", &name, &on)) return NULL;
    if (bk_scene_select(name, on) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_emit(PyObject *self, PyObject *args)
{
    const char *text;
    if (!PyArg_ParseTuple(args, "s", &text)) return NULL;
    bk_console_emit(text);
    Py_RETURN_NONE;
}

static PyObject *bk_set_active(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    if (bk_scene_set_active(name) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_names(PyObject *self, PyObject *args)
{
    int n = bk_scene_object_count();
    PyObject *list = PyList_New(0);
    if (!list) return NULL;
    for (int i = 0; i < n; i++) {
        char buf[256] = {0};
        if (bk_scene_object_name(i, buf, (int)sizeof(buf)) != 0) continue;
        PyObject *s = PyUnicode_FromString(buf);
        if (!s) { Py_DECREF(list); return NULL; }
        if (PyList_Append(list, s) != 0) { Py_DECREF(s); Py_DECREF(list); return NULL; }
        Py_DECREF(s);
    }
    return list;
}

static PyObject *bk_get_vec(PyObject *self, PyObject *args)
{
    const char *name, *prop;
    if (!PyArg_ParseTuple(args, "ss", &name, &prop)) return NULL;
    double x, y, z;
    if (bk_scene_get_vec(name, prop, &x, &y, &z) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return Py_BuildValue("(ddd)", x, y, z);
}

static PyObject *bk_set_vec(PyObject *self, PyObject *args)
{
    const char *name, *prop;
    double x, y, z;
    if (!PyArg_ParseTuple(args, "ssddd", &name, &prop, &x, &y, &z)) return NULL;
    if (bk_scene_set_vec(name, prop, x, y, z) != 0) {
        /* Two different failures reach here: an unknown object and an unknown
           property. Reporting both as a missing object sends whoever reads the
           traceback looking for the wrong thing. */
        if (strcmp(prop, "location") != 0 && strcmp(prop, "rotation_euler") != 0 &&
            strcmp(prop, "scale") != 0) {
            PyErr_Format(PyExc_AttributeError,
                         "no transform property named %s; expected location, "
                         "rotation_euler or scale", prop);
        } else {
            PyErr_Format(PyExc_KeyError, "no object named %s", name);
        }
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_kind(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    char buf[64] = {0};
    if (bk_scene_object_kind(name, buf, (int)sizeof(buf)) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return PyUnicode_FromString(buf);
}

/// add_object(type, name, x, y, z, data_name, record[, select]) -> the name it took
///
/// A camera, light or empty for the shim, drawn from `record` — the same
/// `key=value;...` settings the mirror sends from Blender (ObjectDisplay.swift).
static PyObject *bk_add_object(PyObject *self, PyObject *args)
{
    const char *type, *name, *data_name, *record;
    double x = 0, y = 0, z = 0;
    int select = 1;
    if (!PyArg_ParseTuple(args, "ssdddss|p", &type, &name, &x, &y, &z,
                          &data_name, &record, &select)) return NULL;
    char actual[512] = {0};
    if (bk_scene_add_object(type, name, x, y, z, data_name, record, select,
                            actual, (int)sizeof(actual)) != 0) {
        PyErr_Format(PyExc_ValueError, "cannot add an object of type %s", type);
        return NULL;
    }
    return PyUnicode_FromString(actual);
}

/// object_display(name) -> (type, data_name, record), or None for an object
/// drawn from its mesh.
static PyObject *bk_object_display(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    char type[32] = {0}, data[512] = {0}, record[4096] = {0};
    int r = bk_scene_object_display(name, type, (int)sizeof(type), data, (int)sizeof(data),
                                    record, (int)sizeof(record));
    if (r < 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    if (r == 0) Py_RETURN_NONE;
    return Py_BuildValue("(sss)", type, data, record);
}

/// set_object_display(name, data_name, record)
static PyObject *bk_set_object_display(PyObject *self, PyObject *args)
{
    const char *name, *data_name, *record;
    if (!PyArg_ParseTuple(args, "sss", &name, &data_name, &record)) return NULL;
    int r = bk_scene_set_object_display(name, data_name, record);
    if (r == -2) {
        PyErr_Format(PyExc_TypeError, "%s is not a camera, light or empty", name);
        return NULL;
    }
    if (r != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_display(name, type, data_name, record) — during a mirroring pass, what
/// the object just pushed is drawn from.
static PyObject *bk_sync_display_py(PyObject *self, PyObject *args)
{
    const char *name, *type, *data_name, *record;
    if (!PyArg_ParseTuple(args, "ssss", &name, &type, &data_name, &record)) return NULL;
    if (bk_sync_display(name, type, data_name, record) != 0) {
        PyErr_Format(PyExc_ValueError, "no mirrored object named %s to draw as %s", name, type);
        return NULL;
    }
    Py_RETURN_NONE;
}


/// sync_modifiers(name, record) — the object's modifier stack, as Blender has
/// it. Without this the Modifiers panel could add one and then never see it.
static PyObject *bk_sync_modifiers_py(PyObject *self, PyObject *args)
{
    const char *name, *record;
    if (!PyArg_ParseTuple(args, "ss", &name, &record)) return NULL;
    if (bk_sync_modifiers(name, record) != 0) {
        PyErr_Format(PyExc_ValueError, "no mirrored object named %s to carry modifiers", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_edges(name, edges) — the edges of the mesh just pushed, two vertex
/// indices each, for a mesh with no faces to draw: a wire circle, an unfilled
/// curve. Without it such an object never reached the interface at all.
static PyObject *bk_sync_edges_py(PyObject *self, PyObject *args)
{
    const char *name;
    Py_buffer edges;
    if (!PyArg_ParseTuple(args, "sy*", &name, &edges)) return NULL;
    int rc = -1;
    if (edges.len % (2 * sizeof(unsigned int)) == 0) {
        rc = bk_sync_edges(name, (const unsigned int *)edges.buf,
                           (int)(edges.len / sizeof(unsigned int)));
    }
    PyBuffer_Release(&edges);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed edges for mirrored object %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_uvs(name, map_name, loops, uvs, seams) — the active UV map of the mesh
/// just pushed, as Blender holds it (the loop behind each triangle corner and a
/// UV per loop; both empty for no map), and its seams as vertex pairs.
static PyObject *bk_sync_uvs_py(PyObject *self, PyObject *args)
{
    const char *name, *map_name;
    Py_buffer loops, uvs, seams;
    if (!PyArg_ParseTuple(args, "ssy*y*y*", &name, &map_name, &loops, &uvs, &seams)) return NULL;
    int rc = -1;
    if (loops.len % (3 * sizeof(unsigned int)) == 0 && uvs.len % (2 * sizeof(float)) == 0 &&
        seams.len % (2 * sizeof(unsigned int)) == 0) {
        rc = bk_sync_uvs(name, map_name,
                         (const unsigned int *)loops.buf, (int)(loops.len / sizeof(unsigned int)),
                         (const float *)uvs.buf, (int)(uvs.len / sizeof(float)),
                         (const unsigned int *)seams.buf, (int)(seams.len / sizeof(unsigned int)));
    }
    PyBuffer_Release(&loops); PyBuffer_Release(&uvs); PyBuffer_Release(&seams);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed UVs for mirrored object %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_uv_layout(name, map_name, positions, triangles, loops, uvs, seams) —
/// the map Blender's UV Editor draws for the mesh just pushed, from the
/// object's own mesh before its modifiers, sent when it differs from the one
/// the pushed mesh carries.
static PyObject *bk_sync_uv_layout_py(PyObject *self, PyObject *args)
{
    const char *name, *map_name;
    Py_buffer positions, triangles, loops, uvs, seams;
    if (!PyArg_ParseTuple(args, "ssy*y*y*y*y*", &name, &map_name, &positions, &triangles,
                          &loops, &uvs, &seams)) return NULL;
    int rc = -1;
    if (positions.len % (3 * sizeof(float)) == 0 && triangles.len % (3 * sizeof(unsigned int)) == 0 &&
        loops.len % (3 * sizeof(unsigned int)) == 0 && uvs.len % (2 * sizeof(float)) == 0 &&
        seams.len % (2 * sizeof(unsigned int)) == 0) {
        rc = bk_sync_uv_layout(name, map_name,
                               (const float *)positions.buf, (int)(positions.len / sizeof(float)),
                               (const unsigned int *)triangles.buf, (int)(triangles.len / sizeof(unsigned int)),
                               (const unsigned int *)loops.buf, (int)(loops.len / sizeof(unsigned int)),
                               (const float *)uvs.buf, (int)(uvs.len / sizeof(float)),
                               (const unsigned int *)seams.buf, (int)(seams.len / sizeof(unsigned int)));
    }
    PyBuffer_Release(&positions); PyBuffer_Release(&triangles); PyBuffer_Release(&loops);
    PyBuffer_Release(&uvs); PyBuffer_Release(&seams);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed UV layout for mirrored object %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_relations(name, parent, dependencies) — the object's parent ('' for
/// none) and the names of the objects it depends on, a sequence of str: what a
/// drag leaves out of its snap targets and carries along in its preview.
static PyObject *bk_sync_relations_py(PyObject *self, PyObject *args)
{
    const char *name, *parent;
    PyObject *sequence;
    if (!PyArg_ParseTuple(args, "ssO", &name, &parent, &sequence)) return NULL;
    PyObject *fast = PySequence_Fast(sequence, "dependencies must be a sequence of names");
    if (!fast) return NULL;
    Py_ssize_t count = PySequence_Fast_GET_SIZE(fast);
    const char **names = count > 0 ? (const char **)malloc((size_t)count * sizeof(char *)) : NULL;
    if (count > 0 && !names) {
        Py_DECREF(fast);
        return PyErr_NoMemory();
    }
    for (Py_ssize_t i = 0; i < count; i++) {
        names[i] = PyUnicode_AsUTF8(PySequence_Fast_GET_ITEM(fast, i));
        if (!names[i]) {
            free(names);
            Py_DECREF(fast);
            return NULL;
        }
    }
    int rc = bk_sync_relations(name, parent, names, (int)count);
    free(names);
    Py_DECREF(fast);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "no mirrored object named %s to carry relations", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_knots(name, points) — a curve's control points, three floats each in
/// its own space, for a curve Blender snaps by them alone.
static PyObject *bk_sync_knots_py(PyObject *self, PyObject *args)
{
    const char *name;
    Py_buffer points;
    if (!PyArg_ParseTuple(args, "sy*", &name, &points)) return NULL;
    int rc = -1;
    if (points.len % (3 * sizeof(float)) == 0) {
        rc = bk_sync_knots(name, (const float *)points.buf, (int)(points.len / sizeof(float)));
    }
    PyBuffer_Release(&points);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed control points for mirrored object %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_points(name, record, positions, flags, lines, during_pass) — a curve's
/// or a lattice's settings (`key=value;…`) and, while it is edited, its control
/// points: three floats and one byte of flags each, and the lines between them
/// as index pairs (`_blenderkit_points`). `during_pass` 0 is a drag's frame or
/// a tap, outside any pass, naming the object on screen.
static PyObject *bk_sync_points_py(PyObject *self, PyObject *args)
{
    const char *name;
    const char *record;
    Py_buffer positions, flags, lines;
    int during_pass = 1;
    if (!PyArg_ParseTuple(args, "ssy*y*y*|p", &name, &record, &positions, &flags, &lines,
                          &during_pass)) return NULL;
    int rc = -1;
    if (positions.len % (3 * sizeof(float)) == 0 && lines.len % (2 * sizeof(unsigned int)) == 0
        && (Py_ssize_t)(positions.len / (3 * sizeof(float))) == flags.len) {
        rc = bk_sync_points(name, record, (const float *)positions.buf,
                            (const unsigned char *)flags.buf, (int)flags.len,
                            (const unsigned int *)lines.buf,
                            (int)(lines.len / sizeof(unsigned int)), during_pass);
    }
    PyBuffer_Release(&positions);
    PyBuffer_Release(&flags);
    PyBuffer_Release(&lines);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed control points for mirrored object %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_groups(name, record, during_pass=1) — a mesh's vertex groups and
/// shape keys, as the Data tab shows them (`_blenderkit_groups.record`).
/// `during_pass` 0 is a tap or a frame change, naming the object on screen.
static PyObject *bk_sync_groups_py(PyObject *self, PyObject *args)
{
    const char *name, *record;
    int during_pass = 1;
    if (!PyArg_ParseTuple(args, "ss|p", &name, &record, &during_pass)) return NULL;
    if (bk_sync_groups(name, record, during_pass) != 0) {
        PyErr_Format(PyExc_ValueError, "no mirrored object named %s to carry vertex groups and shape keys", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_local(name, values) — the object's own channels as ten doubles:
/// location, rotation (w, x, y, z), scale, deltas folded in. What
/// `transform_apply` bakes, which `matrix_world` cannot say under a parent or
/// a negative scale.
static PyObject *bk_sync_local_py(PyObject *self, PyObject *args)
{
    const char *name;
    Py_buffer values;
    if (!PyArg_ParseTuple(args, "sy*", &name, &values)) return NULL;
    int rc = -1;
    if (values.len == 10 * sizeof(double)) {
        rc = bk_sync_local(name, (const double *)values.buf);
    }
    PyBuffer_Release(&values);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError,
                     "transform channels for %s are not ten doubles, or this pass pushed no object of that name",
                     name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// sync_channels(name, values) — what the Transform fields show and write, as
/// eleven doubles: location, the rotation mode's number, the rotation in that
/// mode's own property (an Euler's fourth is 0), scale — no deltas. Not
/// `sync_local`'s ten, which fold the deltas in for Apply.
static PyObject *bk_sync_channels_py(PyObject *self, PyObject *args)
{
    const char *name;
    Py_buffer values;
    if (!PyArg_ParseTuple(args, "sy*", &name, &values)) return NULL;
    int rc = -1;
    if (values.len == 11 * sizeof(double)) {
        rc = bk_sync_channels(name, (const double *)values.buf);
    }
    PyBuffer_Release(&values);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError,
                     "transform fields for %s are not eleven doubles, or this pass pushed no object of that name",
                     name);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_rename(PyObject *self, PyObject *args)
{
    const char *old_name, *new_name;
    if (!PyArg_ParseTuple(args, "ss", &old_name, &new_name)) return NULL;
    char actual[256] = {0};
    if (bk_scene_rename(old_name, new_name, actual, (int)sizeof(actual)) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", old_name);
        return NULL;
    }
    // Blender resolves a name collision by suffixing, so return what it became.
    return PyUnicode_FromString(actual);
}

static PyObject *bk_remove(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    if (bk_scene_remove(name) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_active(PyObject *self, PyObject *args)
{
    char buf[256] = {0};
    if (bk_scene_active_name(buf, (int)sizeof(buf)) != 0) Py_RETURN_NONE;
    return PyUnicode_FromString(buf);
}

/// Whether the caller is on the process's main thread: the one thread on which
/// Blender's context gives out its window, screen, area and region. See
/// `_blenderkit_context.py`.
static PyObject *bk_is_main_thread(PyObject *self, PyObject *args)
{
    (void)self; (void)args;
    return PyBool_FromLong(pthread_main_np());
}

static PyObject *bk_mode(PyObject *self, PyObject *args)
{
    char buf[32] = {0};
    if (bk_scene_mode(buf, (int)sizeof(buf)) != 0) return PyUnicode_FromString("OBJECT");
    return PyUnicode_FromString(buf);
}

static PyObject *bk_is_selected(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    int r = bk_scene_is_selected(name);
    if (r < 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return PyBool_FromLong(r);
}

static PyObject *bk_bounds(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    double b[6];
    if (bk_scene_bounds(name, b) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return Py_BuildValue("(dddddd)", b[0], b[1], b[2], b[3], b[4], b[5]);
}

/// get_visible(name, which=2): 0 Disable in Viewports is off, 1 the view
/// layer does not hide it, 2 it is drawn. set_visible(name, visible, which=0)
/// sets one of the first two.
static PyObject *bk_get_visible(PyObject *self, PyObject *args)
{
    const char *name;
    int which = 2;
    if (!PyArg_ParseTuple(args, "s|i", &name, &which)) return NULL;
    int r = bk_scene_get_visible(name, which);
    if (r < 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return PyBool_FromLong(r);
}

static PyObject *bk_set_visible(PyObject *self, PyObject *args)
{
    const char *name;
    int visible;
    int which = 0;
    if (!PyArg_ParseTuple(args, "sp|i", &name, &visible, &which)) return NULL;
    if (bk_scene_set_visible(name, visible, which) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_transform(PyObject *self, PyObject *args)
{
    const char *json;
    if (!PyArg_ParseTuple(args, "s", &json)) return NULL;
    char reason[256] = {0};
    int n = bk_scene_transform_operator(json, reason, (int)sizeof reason);
    if (n < 0) {
        PyErr_SetString(PyExc_RuntimeError,
                        reason[0] ? reason : "the transform could not be applied");
        return NULL;
    }
    return PyLong_FromLong(n);
}

static PyObject *bk_mesh_counts(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    int v = 0, t = 0;
    if (bk_scene_mesh_counts(name, &v, &t) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return Py_BuildValue("(ii)", v, t);
}

static PyObject *bk_mod_add(PyObject *self, PyObject *args)
{
    const char *obj, *kind;
    if (!PyArg_ParseTuple(args, "ss", &obj, &kind)) return NULL;
    char name[128] = {0};
    int r = bk_scene_modifier_add(obj, kind, name, (int)sizeof(name));
    if (r == -2) { PyErr_Format(PyExc_ValueError, "unknown modifier type: %s", kind); return NULL; }
    if (r != 0)  { PyErr_Format(PyExc_KeyError, "no object named %s", obj); return NULL; }
    return PyUnicode_FromString(name);
}

static PyObject *bk_mod_remove(PyObject *self, PyObject *args)
{
    const char *obj, *mod;
    if (!PyArg_ParseTuple(args, "ss", &obj, &mod)) return NULL;
    if (bk_scene_modifier_remove(obj, mod) != 0) {
        PyErr_Format(PyExc_KeyError, "no modifier named %s on %s", mod, obj);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_mod_list(PyObject *self, PyObject *args)
{
    const char *obj;
    if (!PyArg_ParseTuple(args, "s", &obj)) return NULL;
    char buf[4096] = {0};
    if (bk_scene_modifier_list(obj, buf, (int)sizeof(buf)) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", obj);
        return NULL;
    }
    return PyUnicode_FromString(buf);
}

static PyObject *bk_mod_set(PyObject *self, PyObject *args)
{
    const char *obj, *mod, *key;
    double a = 0, b = 0, c = 0;
    if (!PyArg_ParseTuple(args, "sss|ddd", &obj, &mod, &key, &a, &b, &c)) return NULL;
    int r = bk_scene_modifier_set(obj, mod, key, a, b, c);
    if (r == -2) { PyErr_Format(PyExc_AttributeError, "modifier has no setting '%s'", key); return NULL; }
    if (r != 0)  { PyErr_Format(PyExc_KeyError, "no modifier named %s on %s", mod, obj); return NULL; }
    Py_RETURN_NONE;
}

/// modifier_set_object(obj, modifier, key, other) — a Boolean's `object` or a
/// Shrinkwrap's `target`, by name; "" clears it. The errors are Blender's own.
static PyObject *bk_mod_set_object(PyObject *self, PyObject *args)
{
    const char *obj, *mod, *key, *other;
    if (!PyArg_ParseTuple(args, "ssss", &obj, &mod, &key, &other)) return NULL;
    int r = bk_scene_modifier_set_object(obj, mod, key, other);
    if (r == -2) { PyErr_Format(PyExc_AttributeError, "modifier has no setting '%s'", key); return NULL; }
    if (r == -3) {
        PyErr_Format(PyExc_TypeError, "bpy_struct: item.attr = val: %s ID type does not support "
                     "assignment to itself", key);
        return NULL;
    }
    if (r == -4) { PyErr_Format(PyExc_KeyError, "no object named %s", other); return NULL; }
    if (r != 0)  { PyErr_Format(PyExc_KeyError, "no modifier named %s on %s", mod, obj); return NULL; }
    Py_RETURN_NONE;
}

static PyObject *bk_get_color(PyObject *self, PyObject *args)
{
    const char *obj;
    if (!PyArg_ParseTuple(args, "s", &obj)) return NULL;
    double c[4];
    if (bk_scene_get_color(obj, c) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", obj);
        return NULL;
    }
    return Py_BuildValue("(dddd)", c[0], c[1], c[2], c[3]);
}

static PyObject *bk_set_color(PyObject *self, PyObject *args)
{
    const char *obj;
    double r, g, b, a = 1.0;
    if (!PyArg_ParseTuple(args, "sddd|d", &obj, &r, &g, &b, &a)) return NULL;
    if (bk_scene_set_color(obj, r, g, b, a) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", obj);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_sync_begin_py(PyObject *self, PyObject *args)
{
    bk_sync_begin();
    Py_RETURN_NONE;
}

static PyObject *bk_sync_end_py(PyObject *self, PyObject *args)
{
    bk_sync_end();
    Py_RETURN_NONE;
}

/// push(name, kind, matrix(16 doubles as bytes), verts, normals, tris,
///      selected, active, rgba)
static PyObject *bk_sync_push_py(PyObject *self, PyObject *args)
{
    const char *name, *kind;
    Py_buffer mat, verts, norms, tris, rgba;
    int selected = 0, active = 0;
    if (!PyArg_ParseTuple(args, "ssy*y*y*y*iiy*", &name, &kind, &mat,
                          &verts, &norms, &tris, &selected, &active, &rgba)) {
        return NULL;
    }
    if (mat.len != 16 * sizeof(double) || rgba.len != 4 * sizeof(float) ||
        verts.len % (3 * sizeof(float)) || norms.len != verts.len ||
        tris.len % (3 * sizeof(unsigned int))) {
        PyBuffer_Release(&mat); PyBuffer_Release(&verts); PyBuffer_Release(&norms);
        PyBuffer_Release(&tris); PyBuffer_Release(&rgba);
        PyErr_SetString(PyExc_ValueError, "invalid viewport buffer dimensions");
        return NULL;
    }
    int rc = bk_sync_push(name, kind,
                          (const double *)mat.buf,
                          (const float *)verts.buf, (int)(verts.len / 4),
                          (const float *)norms.buf, (int)(norms.len / 4),
                          (const unsigned int *)tris.buf, (int)(tris.len / 4),
                          selected, active, (const float *)rgba.buf);
    PyBuffer_Release(&mat); PyBuffer_Release(&verts); PyBuffer_Release(&norms);
    PyBuffer_Release(&tris); PyBuffer_Release(&rgba);
    if (rc != 0) {
        PyErr_SetString(PyExc_ValueError, "malformed mesh in sync push");
        return NULL;
    }
    Py_RETURN_NONE;
}

/// Returns (verts, normals, tris) as bytes for one object in the shim scene.
static PyObject *bk_mesh_arrays_py(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;

    int vcount = 0, tcount = 0;
    if (bk_scene_mesh_arrays(name, NULL, 0, NULL, 0, NULL, 0, &vcount, &tcount) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }

    PyObject *vb = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)vcount * 3 * 4);
    PyObject *nb = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)vcount * 3 * 4);
    PyObject *tb = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)tcount * 3 * 4);
    if (!vb || !nb || !tb) { Py_XDECREF(vb); Py_XDECREF(nb); Py_XDECREF(tb); return NULL; }

    bk_scene_mesh_arrays(name,
                         (float *)PyBytes_AS_STRING(vb), vcount * 3,
                         (float *)PyBytes_AS_STRING(nb), vcount * 3,
                         (unsigned int *)PyBytes_AS_STRING(tb), tcount * 3,
                         &vcount, &tcount);
    return Py_BuildValue("(NNN)", vb, nb, tb);
}

static PyObject *bk_set_mode(PyObject *self, PyObject *args)
{
    const char *mode;
    if (!PyArg_ParseTuple(args, "s", &mode)) return NULL;
    if (bk_scene_set_mode(mode) != 0) {
        PyErr_Format(PyExc_ValueError, "unsupported mode: %s", mode);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_mesh_select_all(PyObject *self, PyObject *args)
{
    int select = 1;
    if (!PyArg_ParseTuple(args, "|p", &select)) return NULL;
    return PyLong_FromLong(bk_scene_mesh_select_all(select));
}

static PyObject *bk_mesh_op(PyObject *self, PyObject *args)
{
    const char *op;
    double amount = 0.0;
    if (!PyArg_ParseTuple(args, "s|d", &op, &amount)) return NULL;
    int r = bk_scene_mesh_op(op, amount);
    if (r == -2) { PyErr_Format(PyExc_ValueError, "unknown mesh op: %s", op); return NULL; }
    // Only negatives are failures. Several operators report a count — how many
    // vertices merged, how many faces a grow selected — and returning that as
    // an error was the sort of bug that only shows up once one is called.
    if (r < 0)   { PyErr_SetString(PyExc_RuntimeError, "not in edit mode with an active object"); return NULL; }
    return PyLong_FromLong(r);
}

static PyObject *bk_object_op(PyObject *self, PyObject *args)
{
    const char *op;
    double amount = 0.0;
    if (!PyArg_ParseTuple(args, "s|d", &op, &amount)) return NULL;
    int r = bk_scene_object_op(op, amount);
    if (r == -2) { PyErr_Format(PyExc_ValueError, "unknown object op: %s", op); return NULL; }
    if (r < 0)   { PyErr_SetString(PyExc_RuntimeError, "no scene or active object"); return NULL; }
    return PyLong_FromLong(r);
}

static PyObject *bk_object_shade(PyObject *self, PyObject *args)
{
    int smooth = 1;
    if (!PyArg_ParseTuple(args, "|p", &smooth)) return NULL;
    return PyLong_FromLong(bk_scene_object_shade(smooth));
}

static PyObject *bk_modifier_apply(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    int r = bk_scene_modifier_apply(name);
    if (r == -3) { PyErr_SetString(PyExc_RuntimeError, "Modifier is disabled, skipping apply"); return NULL; }
    if (r == -2) { PyErr_Format(PyExc_KeyError, "no modifier named \"%s\"", name); return NULL; }
    if (r < 0)   { PyErr_SetString(PyExc_RuntimeError, "no active object"); return NULL; }
    Py_RETURN_NONE;
}

static PyObject *bk_join_selected(PyObject *self, PyObject *args)
{
    (void)args;
    int r = bk_scene_join_selected();
    if (r < 0) { PyErr_SetString(PyExc_RuntimeError, "no active object to join into"); return NULL; }
    return PyLong_FromLong(r);
}

static PyObject *bk_keyframe(PyObject *self, PyObject *args)
{
    const char *obj, *path;
    int frame = 0, insert = 1;
    if (!PyArg_ParseTuple(args, "ssi|p", &obj, &path, &frame, &insert)) return NULL;
    if (bk_scene_keyframe(obj, path, frame, insert) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", obj);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_set_frame(PyObject *self, PyObject *args)
{
    int frame;
    if (!PyArg_ParseTuple(args, "i", &frame)) return NULL;
    return PyLong_FromLong(bk_scene_set_frame(frame));
}

static PyObject *bk_timeline(PyObject *self, PyObject *args)
{
    int start, end, current;
    if (!PyArg_ParseTuple(args, "iii", &start, &end, &current)) return NULL;
    bk_scene_set_timeline(start, end, current);
    Py_RETURN_NONE;
}

static PyObject *bk_sculpt(PyObject *self, PyObject *args)
{
    const char *obj, *brush;
    double x, y, z, nx, ny, nz, radius, strength;
    if (!PyArg_ParseTuple(args, "sddddddsdd", &obj, &x, &y, &z, &nx, &ny, &nz,
                          &brush, &radius, &strength)) return NULL;
    int r = bk_scene_sculpt_stroke(obj, x, y, z, nx, ny, nz, brush, radius, strength);
    if (r == -2) { PyErr_Format(PyExc_ValueError, "unknown brush: %s", brush); return NULL; }
    /* -3: the mesh on screen is Blender's evaluated mesh, which the stand-in
       brush never touches (BKObject.sculptStandIn). */
    if (r == -3) {
        PyErr_Format(PyExc_RuntimeError, "%s is Blender's mesh: sculpt it with "
                     "bpy.ops.sculpt.brush_stroke, not the simulator's stand-in brush", obj);
        return NULL;
    }
    if (r != 0)  { PyErr_Format(PyExc_KeyError, "no object named %s", obj); return NULL; }
    Py_RETURN_NONE;
}

static PyObject *bk_uv_project(PyObject *self, PyObject *args)
{
    const char *obj, *kind;
    if (!PyArg_ParseTuple(args, "ss", &obj, &kind)) return NULL;
    double stretch = 0.0; int count = 0;
    int r = bk_scene_uv_project(obj, kind, &stretch, &count);
    if (r == -2) { PyErr_Format(PyExc_ValueError, "unknown projection: %s", kind); return NULL; }
    if (r != 0)  { PyErr_Format(PyExc_KeyError, "no object named %s", obj); return NULL; }
    return Py_BuildValue("(id)", count, stretch);
}

static PyObject *bk_material_set(PyObject *self, PyObject *args)
{
    const char *obj, *key;
    double a = 0, b = 0, c = 0;
    if (!PyArg_ParseTuple(args, "ss|ddd", &obj, &key, &a, &b, &c)) return NULL;
    int r = bk_scene_material_set(obj, key, a, b, c);
    if (r == -2) { PyErr_Format(PyExc_AttributeError, "no material input '%s'", key); return NULL; }
    if (r != 0)  { PyErr_Format(PyExc_KeyError, "no object named %s", obj); return NULL; }
    Py_RETURN_NONE;
}

static PyObject *bk_material_get(PyObject *self, PyObject *args)
{
    const char *obj, *key;
    if (!PyArg_ParseTuple(args, "ss", &obj, &key)) return NULL;
    double v[3] = {0, 0, 0};
    int n = bk_scene_material_get(obj, key, v);
    if (n == -2) { PyErr_Format(PyExc_AttributeError, "no material input '%s'", key); return NULL; }
    if (n < 0)   { PyErr_Format(PyExc_KeyError, "no object named %s", obj); return NULL; }
    if (n == 3)  return Py_BuildValue("(ddd)", v[0], v[1], v[2]);
    return PyFloat_FromDouble(v[0]);
}

static PyObject *bk_paint(PyObject *self, PyObject *args)
{
    const char *obj;
    double u, v, r, g, b, radius = 0.04, strength = 0.8;
    if (!PyArg_ParseTuple(args, "sddddd|dd", &obj, &u, &v, &r, &g, &b, &radius, &strength))
        return NULL;
    int rc = bk_scene_paint(obj, u, v, r, g, b, radius, strength);
    if (rc == -2) { PyErr_SetString(PyExc_RuntimeError, "mesh has no UVs; unwrap first"); return NULL; }
    if (rc != 0)  { PyErr_Format(PyExc_KeyError, "no object named %s", obj); return NULL; }
    Py_RETURN_NONE;
}

static PyObject *bk_texture_info(PyObject *self, PyObject *args)
{
    const char *obj;
    if (!PyArg_ParseTuple(args, "s", &obj)) return NULL;
    int w = 0, h = 0, painted = 0;
    if (bk_scene_texture_info(obj, &w, &h, &painted) != 0) Py_RETURN_NONE;
    return Py_BuildValue("(iii)", w, h, painted);
}

/// sync_edit_selection(name, select_mode_bits, vertex_selected, triangle_polygons,
///                     polygon_selected, edge_vertices, edge_selected
///                     [, vertex_hidden [, vertex_coordinates]])
///
/// vertex_hidden is empty when nothing is hidden. vertex_coordinates, three
/// floats per vertex, are the edit mesh's own when a modifier shown in edit
/// mode may have moved what the viewport drew (`_edit_coordinates`).
static PyObject *bk_sync_edit_selection_py(PyObject *self, PyObject *args)
{
    const char *name;
    int select_mode = 0;
    Py_buffer vsel, tpoly, psel, ends, esel;
    Py_buffer vhide = {0}, vco = {0};
    if (!PyArg_ParseTuple(args, "siy*y*y*y*y*|y*y*", &name, &select_mode,
                          &vsel, &tpoly, &psel, &ends, &esel, &vhide, &vco)) {
        return NULL;
    }
    int rc = -1;
    if (tpoly.len % sizeof(unsigned int) == 0 &&
        ends.len % (2 * sizeof(unsigned int)) == 0 &&
        vco.len % (3 * sizeof(float)) == 0) {
        rc = bk_sync_edit_selection(name, select_mode,
                                    (const unsigned char *)vsel.buf, (int)vsel.len,
                                    (const unsigned int *)tpoly.buf,
                                    (int)(tpoly.len / sizeof(unsigned int)),
                                    (const unsigned char *)psel.buf, (int)psel.len,
                                    (const unsigned int *)ends.buf,
                                    (int)(ends.len / sizeof(unsigned int)),
                                    (const unsigned char *)esel.buf, (int)esel.len,
                                    (const unsigned char *)vhide.buf, (int)vhide.len,
                                    (const float *)vco.buf, (int)(vco.len / sizeof(float)));
    }
    PyBuffer_Release(&vsel); PyBuffer_Release(&tpoly); PyBuffer_Release(&psel);
    PyBuffer_Release(&ends); PyBuffer_Release(&esel);
    if (vhide.obj != NULL) PyBuffer_Release(&vhide);
    if (vco.obj != NULL) PyBuffer_Release(&vco);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "no edit selection to mirror for %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

// ---------------------------------------------------------------------------
// Animation: the timeline's mirror of Blender, and the shim's animation state.
// Resources/python/site/_blenderkit_anim.py is the other side of these.
// ---------------------------------------------------------------------------

/// anim_state(start, end, current, subframe, fps, use_preview, preview_start,
///            preview_end, auto_key, replace, only_available, only_selected, loop)
static PyObject *bk_anim_state_py(PyObject *self, PyObject *args)
{
    int start, end, current, preview, preview_start, preview_end;
    int auto_key, replace, only_available, only_selected, loop;
    double subframe, fps;
    if (!PyArg_ParseTuple(args, "iiiddiiiiiiii", &start, &end, &current, &subframe, &fps,
                          &preview, &preview_start, &preview_end, &auto_key, &replace,
                          &only_available, &only_selected, &loop)) return NULL;
    const int ints[11] = {start, end, current, preview, preview_start, preview_end,
                          auto_key, replace, only_available, only_selected, loop};
    const double doubles[2] = {subframe, fps};
    if (bk_anim_set_state(ints, doubles) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "no scene to mirror the animation state into");
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_anim_state_get_py(PyObject *self, PyObject *args)
{
    (void)args;
    int ints[11] = {0};
    double doubles[2] = {0, 24};
    if (bk_anim_get_state(ints, doubles) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "no scene to read the animation state from");
        return NULL;
    }
    return Py_BuildValue("(iiiddiiiiiiii)", ints[0], ints[1], ints[2], doubles[0], doubles[1],
                         ints[3], ints[4], ints[5], ints[6], ints[7], ints[8], ints[9], ints[10]);
}

/// anim_keys(names, counts, frames, selected, scene_frames, scene_selected)
static PyObject *bk_anim_keys_py(PyObject *self, PyObject *args)
{
    Py_buffer names, counts, frames, selected, scene_frames, scene_selected;
    if (!PyArg_ParseTuple(args, "y*y*y*y*y*y*", &names, &counts, &frames, &selected,
                          &scene_frames, &scene_selected)) return NULL;
    int rc = -1;
    if (counts.len % sizeof(unsigned int) == 0 && frames.len % sizeof(float) == 0 &&
        scene_frames.len % sizeof(float) == 0 &&
        selected.len == frames.len / (Py_ssize_t)sizeof(float) &&
        scene_selected.len == scene_frames.len / (Py_ssize_t)sizeof(float)) {
        rc = bk_anim_set_keys((const unsigned char *)names.buf, (int)names.len,
                              (const unsigned int *)counts.buf,
                              (int)(counts.len / sizeof(unsigned int)),
                              (const float *)frames.buf, (const unsigned char *)selected.buf,
                              (int)(frames.len / sizeof(float)),
                              (const float *)scene_frames.buf,
                              (const unsigned char *)scene_selected.buf,
                              (int)(scene_frames.len / sizeof(float)));
    }
    PyBuffer_Release(&names); PyBuffer_Release(&counts); PyBuffer_Release(&frames);
    PyBuffer_Release(&selected); PyBuffer_Release(&scene_frames);
    PyBuffer_Release(&scene_selected);
    if (rc != 0) {
        PyErr_SetString(PyExc_ValueError, "malformed keyframe report");
        return NULL;
    }
    Py_RETURN_NONE;
}

/// anim_frame(frame, subframe, names, matrices) -> how many objects moved
static PyObject *bk_anim_frame_py(PyObject *self, PyObject *args)
{
    int frame;
    double subframe;
    Py_buffer names, matrices;
    if (!PyArg_ParseTuple(args, "idy*y*", &frame, &subframe, &names, &matrices)) return NULL;
    int rc = -1;
    if (matrices.len % (16 * sizeof(double)) == 0) {
        rc = bk_anim_set_frame(frame, subframe, (const unsigned char *)names.buf, (int)names.len,
                               (const double *)matrices.buf,
                               (int)(matrices.len / (16 * sizeof(double))));
    }
    PyBuffer_Release(&names); PyBuffer_Release(&matrices);
    if (rc < 0) {
        PyErr_SetString(PyExc_ValueError, "malformed frame update");
        return NULL;
    }
    return PyLong_FromLong(rc);
}

/// anim_mesh(name, verts, normals, tris[, edges]) -> 1 replaced, 0 unchanged.
/// `edges` comes with a mesh that has no faces; without it the edge count
/// passed on is -1, which the Swift reads as "derive them from the triangles".
static PyObject *bk_anim_mesh_py(PyObject *self, PyObject *args)
{
    const char *name;
    Py_buffer verts, norms, tris, edges;
    edges.buf = NULL; edges.obj = NULL; edges.len = 0;
    if (!PyArg_ParseTuple(args, "sy*y*y*|y*", &name, &verts, &norms, &tris, &edges)) return NULL;
    int has_edges = PyTuple_GET_SIZE(args) > 4;
    int rc = -1;
    if (verts.len % (3 * sizeof(float)) == 0 && norms.len == verts.len &&
        tris.len % (3 * sizeof(unsigned int)) == 0 &&
        (!has_edges || edges.len % (2 * sizeof(unsigned int)) == 0)) {
        rc = bk_anim_set_mesh(name, (const float *)verts.buf, (int)(verts.len / sizeof(float)),
                              (const float *)norms.buf, (int)(norms.len / sizeof(float)),
                              (const unsigned int *)tris.buf,
                              (int)(tris.len / sizeof(unsigned int)),
                              has_edges ? (const unsigned int *)edges.buf : NULL,
                              has_edges ? (int)(edges.len / sizeof(unsigned int)) : -1);
    }
    PyBuffer_Release(&verts); PyBuffer_Release(&norms); PyBuffer_Release(&tris);
    if (has_edges) PyBuffer_Release(&edges);
    if (rc < 0) {
        PyErr_Format(PyExc_ValueError, "no object named %s to deform, or a malformed mesh", name);
        return NULL;
    }
    return PyLong_FromLong(rc);
}

/// sync_mask(name, bytes) — Blender's sculpt mask for one object, as float32
/// per vertex of the mesh the viewport draws; b'' when nothing is masked.
static PyObject *bk_sync_mask_py(PyObject *self, PyObject *args)
{
    const char *name;
    Py_buffer values;
    if (!PyArg_ParseTuple(args, "sy*", &name, &values)) return NULL;
    int rc = -1;
    if (values.len % sizeof(float) == 0) {
        rc = bk_sculpt_set_mask(name, (const float *)values.buf, (int)(values.len / sizeof(float)));
    }
    PyBuffer_Release(&values);
    if (rc < 0) {
        PyErr_Format(PyExc_ValueError, "no object named %s to mask, or a malformed mask", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_anim_notice_py(PyObject *self, PyObject *args)
{
    const char *text;
    if (!PyArg_ParseTuple(args, "s", &text)) return NULL;
    bk_anim_notice(text);
    Py_RETURN_NONE;
}

/// anim_channels(name) -> "path:frame,frame" lines, the shim's keyed channels
static PyObject *bk_anim_channels_py(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    int needed = bk_anim_channels(name, NULL, 0);
    if (needed < 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    char *buf = (char *)malloc((size_t)needed + 1);
    if (!buf) return PyErr_NoMemory();
    bk_anim_channels(name, buf, needed + 1);
    PyObject *text = PyUnicode_FromString(buf);
    free(buf);
    return text;
}

// ---------------------------------------------------------------------------
// Tool settings: snapping, the pivot point, proportional editing and the 3D
// cursor. Resources/python/site/_blenderkit_tools.py is the other side.
// ---------------------------------------------------------------------------

/// tool_state(use_snap, elements, individual, target, pivot, proportional_edit,
///            proportional_objects, connected, falloff, automerge, snap_flags,
///            size, cursor_x, cursor_y, cursor_z, merge_threshold)
///
/// `elements` and `individual` are bit fields over _blenderkit_tools.ELEMENTS
/// and .INDIVIDUAL, `snap_flags` over .SNAP_FLAGS; the other four enums are
/// indices into its tuples.
static PyObject *bk_tool_state_py(PyObject *self, PyObject *args)
{
    int use_snap, elements, individual, target, pivot;
    int prop_edit, prop_objects, connected, falloff, automerge, snap_flags;
    double size, x, y, z, merge_threshold;
    if (!PyArg_ParseTuple(args, "iiiiiiiiiiiddddd", &use_snap, &elements, &individual,
                          &target, &pivot, &prop_edit, &prop_objects, &connected,
                          &falloff, &automerge, &snap_flags,
                          &size, &x, &y, &z, &merge_threshold)) return NULL;
    const int ints[11] = {use_snap, elements, individual, target, pivot,
                          prop_edit, prop_objects, connected, falloff, automerge, snap_flags};
    const double doubles[5] = {size, x, y, z, merge_threshold};
    if (bk_tool_set_state(ints, doubles) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "no scene to mirror the tool settings into");
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bk_tool_state_get_py(PyObject *self, PyObject *args)
{
    (void)args;
    int ints[11] = {0};
    double doubles[5] = {1, 0, 0, 0, 0.001};
    if (bk_tool_get_state(ints, doubles) != 0) {
        PyErr_SetString(PyExc_RuntimeError, "no scene to read the tool settings from");
        return NULL;
    }
    return Py_BuildValue("(iiiiiiiiiiiddddd)", ints[0], ints[1], ints[2], ints[3], ints[4],
                         ints[5], ints[6], ints[7], ints[8], ints[9], ints[10],
                         doubles[0], doubles[1], doubles[2], doubles[3], doubles[4]);
}

static PyMethodDef bk_methods[] = {
    {"emit",              bk_emit,      METH_VARARGS, "Hand one chunk of script output to the console as it is written."},
    {"add_primitive",     bk_add,       METH_VARARGS, "Add a mesh primitive; returns its name."},
    {"add_torus",         bk_add_torus, METH_VARARGS, "Add a torus at given major/minor radii."},
    {"delete_selected",   bk_delete,    METH_NOARGS,  "Delete the selection; returns how many went."},
    {"duplicate_selected",bk_duplicate, METH_NOARGS,  "Duplicate the selection; returns how many."},
    {"select_all",        bk_select_all,METH_VARARGS, "Select or deselect everything."},
    {"select",            bk_select,    METH_VARARGS, "Set one object's selection state."},
    {"object_names",      bk_names,     METH_NOARGS,  "Names of every object, in scene order."},
    {"get_vec",           bk_get_vec,   METH_VARARGS, "Read location/rotation/scale."},
    {"set_vec",           bk_set_vec,   METH_VARARGS, "Write location/rotation/scale."},
    {"object_kind",       bk_kind,      METH_VARARGS, "The primitive kind of an object."},
    {"add_object",        bk_add_object, METH_VARARGS, "Add a camera, light or empty; returns its name."},
    {"object_display",    bk_object_display, METH_VARARGS, "(type, data name, record) of a camera, light or empty, or None."},
    {"set_object_display", bk_set_object_display, METH_VARARGS, "Replace a camera's, light's or empty's settings."},
    {"sync_display",      bk_sync_display_py, METH_VARARGS, "Hand the renderer what a mirrored camera, light or empty is drawn from."},
    {"sync_modifiers",    bk_sync_modifiers_py, METH_VARARGS, "Hand the interface the object's modifier stack as Blender has it."},
    {"sync_local",        bk_sync_local_py, METH_VARARGS, "Hand the interface the object's own location, rotation and scale."},
    {"sync_channels",     bk_sync_channels_py, METH_VARARGS, "Hand the Transform fields the location, rotation and scale they show."},
    {"sync_relations",    bk_sync_relations_py, METH_VARARGS, "Hand the interface the object's parent and what it depends on."},
    {"sync_knots",        bk_sync_knots_py, METH_VARARGS, "Hand the interface a curve's control points, which it snaps to."},
    {"sync_edges",        bk_sync_edges_py, METH_VARARGS, "Hand the renderer the edges of a mirrored mesh that has no faces."},
    {"sync_points",       bk_sync_points_py, METH_VARARGS, "Hand Edit Mode a curve's or a lattice's control points, and the Data tab its settings."},
    {"sync_groups",       bk_sync_groups_py, METH_VARARGS, "Hand the Data tab a mesh's vertex groups and shape keys."},
    {"sync_uvs",          bk_sync_uvs_py, METH_VARARGS, "Hand the UV Editor the active UV map and seams of the mesh just pushed."},
    {"sync_uv_layout",    bk_sync_uv_layout_py, METH_VARARGS, "Hand the UV Editor the map before the modifiers, when it differs from the pushed mesh's."},
    {"rename",            bk_rename,    METH_VARARGS, "Rename an object; returns the resolved name."},
    {"remove",            bk_remove,    METH_VARARGS, "Remove one object by name."},
    {"active_name",       bk_active,    METH_NOARGS,  "Name of the active object, or None."},
    {"mode",              bk_mode,      METH_NOARGS,  "The mode the interface is in."},
    {"is_main_thread",    bk_is_main_thread, METH_NOARGS, "Whether this is the main thread, where Blender gives out window and area."},
    {"set_active",        bk_set_active,METH_VARARGS, "Make one object active, without selecting it."},
    {"is_selected",       bk_is_selected, METH_VARARGS, "Whether one object is selected."},
    {"bounds",            bk_bounds,    METH_VARARGS, "World-space (minx,miny,minz,maxx,maxy,maxz)."},
    {"get_visible",       bk_get_visible, METH_VARARGS, "Viewport visibility."},
    {"set_visible",       bk_set_visible, METH_VARARGS, "Set viewport visibility."},
    {"transform_operator", bk_transform, METH_VARARGS, "One bpy.ops.transform call, applied as the gizmo previews it."},
    {"mesh_counts",       bk_mesh_counts, METH_VARARGS, "(vertex count, triangle count)."},
    {"modifier_add",      bk_mod_add,   METH_VARARGS, "Append a modifier; returns its name."},
    {"modifier_remove",   bk_mod_remove,METH_VARARGS, "Remove a modifier by name."},
    {"modifier_set_object", bk_mod_set_object, METH_VARARGS, "Set a Boolean's object or a Shrinkwrap's target by name."},
    {"modifier_list",     bk_mod_list,  METH_VARARGS, "Newline-separated 'name|kind' entries."},
    {"modifier_set",      bk_mod_set,   METH_VARARGS, "Set one modifier setting."},
    {"get_color",         bk_get_color, METH_VARARGS, "Object viewport colour as RGBA."},
    {"sync_begin",        bk_sync_begin_py, METH_NOARGS,  "Start replacing the mirrored scene."},
    {"sync_push",         bk_sync_push_py,  METH_VARARGS, "Hand one evaluated mesh to the renderer."},
    {"sync_end",          bk_sync_end_py,   METH_NOARGS,  "Commit the mirrored scene."},
    {"sync_edit_selection", bk_sync_edit_selection_py, METH_VARARGS, "Mirror Blender's edit-mode selection for the object being edited."},
    {"mesh_arrays",       bk_mesh_arrays_py, METH_VARARGS,"(verts, normals, tris) bytes for one object."},
    {"set_mode",          bk_set_mode,  METH_VARARGS, "Switch between OBJECT, EDIT and SCULPT."},
    {"keyframe",          bk_keyframe,  METH_VARARGS, "Insert or delete a transform keyframe."},
    {"set_timeline",      bk_timeline,  METH_VARARGS, "Mirror Blender's timeline range and frame."},
    {"set_frame",         bk_set_frame, METH_VARARGS, "Set the current frame; returns it."},
    {"sculpt_stroke",     bk_sculpt,    METH_VARARGS, "One brush dab in object-local space."},
    {"mesh_select_all",   bk_mesh_select_all, METH_VARARGS, "Select or deselect all mesh elements."},
    {"mesh_op",           bk_mesh_op,   METH_VARARGS, "Run one mesh operator on the selection; returns its count."},
    {"join_selected",     bk_join_selected, METH_NOARGS, "Merge the selection into the active object."},
    {"modifier_apply",    bk_modifier_apply, METH_VARARGS, "Bake one modifier into the mesh."},
    {"object_shade",      bk_object_shade, METH_VARARGS, "Object-mode shade smooth/flat."},
    {"object_op",         bk_object_op, METH_VARARGS, "Run one object-level operator by name."},
    {"uv_project",        bk_uv_project, METH_VARARGS,"Unwrap; returns (uv count, average stretch)."},
    {"material_set",      bk_material_set, METH_VARARGS,"Set a Principled BSDF input."},
    {"material_get",      bk_material_get, METH_VARARGS,"Read a Principled BSDF input back."},
    {"paint",             bk_paint,     METH_VARARGS, "One paint dab at a UV."},
    {"texture_info",      bk_texture_info, METH_VARARGS,"(width, height, painted pixels) or None."},
    {"set_color",         bk_set_color, METH_VARARGS, "Set object viewport colour."},
    {"anim_state",        bk_anim_state_py, METH_VARARGS, "Mirror the scene's frame range, rate and keying settings."},
    {"anim_state_get",    bk_anim_state_get_py, METH_NOARGS, "The animation state the interface holds."},
    {"anim_keys",         bk_anim_keys_py, METH_VARARGS, "Mirror every object's keyframe columns."},
    {"anim_frame",        bk_anim_frame_py, METH_VARARGS, "Mirror a frame change: the frame and what it moved."},
    {"anim_mesh",         bk_anim_mesh_py, METH_VARARGS, "Mirror one mesh a frame change deformed."},
    {"sync_mask",         bk_sync_mask_py, METH_VARARGS, "Mirror Blender's sculpt mask onto one object."},
    {"anim_notice",       bk_anim_notice_py, METH_VARARGS, "Show a report Blender would put in its status bar."},
    {"anim_channels",     bk_anim_channels_py, METH_VARARGS, "The shim's keyed channels on one object."},
    {"tool_state",        bk_tool_state_py, METH_VARARGS, "Mirror snapping, the pivot, proportional editing and the 3D cursor."},
    {"tool_state_get",    bk_tool_state_get_py, METH_NOARGS, "The tool settings the interface holds."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef bk_module = {
    PyModuleDef_HEAD_INIT, "_blenderkit",
    "Native bridge from the bundled bpy shim to Blender Local's scene.",
    -1, bk_methods, NULL, NULL, NULL, NULL
};

static PyObject *PyInit__blenderkit(void) { return PyModule_Create(&bk_module); }
PyObject *PyInit__blenderkit_paint(void);  // TexturePaintModule.c

// ---------------------------------------------------------------------------
// Interpreter lifecycle
// ---------------------------------------------------------------------------

static int   g_started = 0;
static char  g_version[256] = {0};

// stdout and stderr are swapped for one buffer so scripts, expression results
// and tracebacks all arrive in the console in the order they happened.
static const char *kBootstrap =
    "import sys, io\n"
    "import _blenderkit\n"
    "class _BKOut(io.TextIOBase):\n"
    "    def __init__(self):\n"
    "        self._parts = []\n"
    "    def write(self, s):\n"
    "        self._parts.append(s)\n"
    // Hand it over as it is written, not only when the run ends. A long
    // bpy script that prints its progress was silent until it finished,
    // which is exactly when the progress stops being useful.
    "        try:\n"
    "            _blenderkit.emit(s)\n"
    "        except Exception:\n"
    "            pass\n"
    "        return len(s)\n"
    "    def writable(self):\n"
    "        return True\n"
    "    def drain(self):\n"
    "        out = ''.join(self._parts)\n"
    "        self._parts.clear()\n"
    "        return out\n"
    "_bk_out = _BKOut()\n"
    "sys.stdout = _bk_out\n"
    "sys.stderr = _bk_out\n"
    // A console echoes expression values; this is what makes `2 + 2` print 4.
    "sys.displayhook = lambda v: (None if v is None else print(repr(v)))\n"
    "__bk_globals__ = {'__name__': '__main__', '__builtins__': __builtins__}\n";

// Blender's console does not make you type `import bpy` before you can do
// anything, and neither should this one: it pre-imports bpy and the maths
// modules, and binds C and D to the context and data the way Blender does.
//
// Run on the first statement rather than at startup. The real module is a
// 428 MB binary, and importing it while the app is still launching would stall
// the launch for every user, including the ones who never open this tab.
static const char *BK_CONSOLE_PRELUDE =
    "try:\n"
    "    import bpy\n"
    "    C = bpy.context\n"
    "    D = bpy.data\n"
    "except Exception as _e:\n"
    "    print('bpy could not be imported:', _e)\n"
    // The real module only: a temp_override naming the window on the script
    // thread wiped the main thread's window and screen (_blenderkit_context.py).
    "try:\n"
    "    if hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type'):\n"
    "        __import__('_blenderkit_context').install(bpy)\n"
    "except NameError:\n"
    "    pass\n"
    "except Exception as _e:\n"
    "    print('temp_override guard not installed:', _e)\n"
    "try:\n"
    "    from mathutils import *\n"
    "except Exception:\n"
    "    pass\n"
    "from math import *\n";

/// The pending call itself. CPython runs this on the main thread between two
/// bytecodes, with the GIL held, which is the only moment in a synchronous run
/// where turning the run loop is safe.
static int bk_pump_pending(void *arg)
{
    (void)arg;
    bk_pump_runloop();
    return 0;
}

int bk_request_pump(void)
{
    if (!g_started) return -1;
    return Py_AddPendingCall(bk_pump_pending, NULL);
}

int bk_python_start(const char *home, const char *pythonpath,
                    const char *executable)
{
    if (g_started) return 0;

    // Registered before initialisation so `import _blenderkit` resolves to the
    // built-in table rather than looking for a file on disk.
    if (PyImport_AppendInittab("_blenderkit", PyInit__blenderkit) != 0) return -1;
    if (PyImport_AppendInittab("_blenderkit_paint", PyInit__blenderkit_paint) != 0) return -1;

    // UTF-8 mode lives on PyPreConfig in 3.14, so it has to be set before the
    // interpreter is configured. Without it the interpreter falls back to the
    // POSIX locale on iOS and any non-ASCII path or literal fails.
    PyPreConfig preconfig;
    PyPreConfig_InitPythonConfig(&preconfig);
    preconfig.utf8_mode = 1;
    if (PyStatus_Exception(Py_PreInitialize(&preconfig))) return -1;

    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    // The interpreter is embedded in a GUI app: it has no argv, no stdin to
    // read from, no site-packages to scan, and must not try to write .pyc into
    // a read-only bundle.
    config.write_bytecode = 0;
    config.user_site_directory = 0;
    config.install_signal_handlers = 0;
    config.buffered_stdio = 0;

    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
    if (PyStatus_Exception(status)) goto fail;

    // sys.executable has to be the app binary, and this is load-bearing rather
    // than cosmetic. Extension modules are packaged as frameworks with a
    // .fwork pointer holding a path relative to the bundle, and CPython's
    // AppleFrameworkLoader resolves them as
    //     join(dirname(sys.executable), <.fwork contents>)
    // Leave sys.executable unset and that join yields a *relative* path, which
    // dyld refuses in hardened mode on a real device — every C extension fails
    // to import. Setting it makes the result absolute, which works in both
    // hardened and development modes.
    if (executable && *executable) {
        status = PyConfig_SetBytesString(&config, &config.executable, executable);
        if (PyStatus_Exception(status)) goto fail;
    }

    config.module_search_paths_set = 1;
    {
        char *paths = strdup(pythonpath);
        if (!paths) goto fail;
        for (char *p = strtok(paths, ":"); p; p = strtok(NULL, ":")) {
            wchar_t *w = Py_DecodeLocale(p, NULL);
            if (!w) continue;
            status = PyWideStringList_Append(&config.module_search_paths, w);
            PyMem_RawFree(w);
            if (PyStatus_Exception(status)) { free(paths); goto fail; }
        }
        free(paths);
    }

    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) goto fail;
    PyConfig_Clear(&config);

    if (PyRun_SimpleString(kBootstrap) != 0) {
        return -2;
    }

    snprintf(g_version, sizeof(g_version), "%s", Py_GetVersion());
    g_started = 1;
    // Hand the GIL back. `Py_InitializeFromConfig` leaves the starting thread
    // holding it, and every later call takes it through `PyGILState_Ensure`,
    // so leaving it held here means the first call from any other thread waits
    // for a lock nobody will ever drop.
    PyEval_SaveThread();
    return 0;

fail:
    PyConfig_Clear(&config);
    return -1;
}

const char *bk_python_version(void) { return g_version; }

/// Whether the convenience imports have been run for this session.
static int g_prelude_done = 0;

static atomic_int g_interrupt_requested = 0;
void bk_python_request_interrupt(void)
{
    atomic_store(&g_interrupt_requested, 1);
}

static int bk_interrupt_trace(PyObject *obj, PyFrameObject *frame, int event, PyObject *arg)
{
    (void)obj; (void)frame; (void)event; (void)arg;
    if (atomic_exchange(&g_interrupt_requested, 0)) {
        PyErr_SetString(PyExc_KeyboardInterrupt, "Stopped by user");
        return -1;
    }
    return 0;
}


static char *bk_python_run_locked(const char *source, int *ok);

char *bk_python_run(const char *source, int *ok)
{
    if (ok) *ok = 1;
    // Take the GIL. Until scripts moved off the main thread there was only
    // ever one thread in the interpreter and this was unnecessary; now the
    // editor's completion lookups run on the main thread while a script may be
    // running on another, and two threads in CPython without the GIL is not a
    // race, it is a crash.
    PyGILState_STATE _gil = PyGILState_Ensure();
    char *_result = bk_python_run_locked(source, ok);
    PyGILState_Release(_gil);
    return _result;
}

static char *bk_python_run_locked(const char *source, int *ok)
{
    if (!g_started) {
        if (ok) *ok = 0;
        return strdup("interpreter is not running");
    }

    PyObject *main_mod = PyImport_AddModule("__main__");
    PyObject *main_dict = PyModule_GetDict(main_mod);
    PyObject *globals = PyDict_GetItemString(main_dict, "__bk_globals__");
    if (!globals) globals = main_dict;

    // First statement of the session pays for the convenience imports.
    if (!g_prelude_done) {
        g_prelude_done = 1;
        PyObject *pre = PyRun_String(BK_CONSOLE_PRELUDE, Py_file_input, globals, globals);
        if (pre) {
            Py_DECREF(pre);
        } else {
            // A failed prelude must not take the statement down with it; the
            // console still works, you just have to import things yourself.
            PyErr_Clear();
        }
    }

    // A single line runs as a console statement so its value is echoed;
    // anything multi-line runs as a script, which is what Run Script sends.
    int mode = strchr(source, '\n') ? Py_file_input : Py_single_input;

    PyThreadState *thread = PyThreadState_Get();
    Py_tracefunc previous_trace = thread->c_tracefunc;
    PyObject *previous_trace_object = Py_XNewRef(thread->c_traceobj);
    atomic_store(&g_interrupt_requested, 0);
    PyEval_SetTrace(bk_interrupt_trace, NULL);
    PyObject *result = PyRun_String(source, mode, globals, globals);
    PyEval_SetTrace(previous_trace, previous_trace_object);
    Py_XDECREF(previous_trace_object);
    if (!result) {
        if (ok) *ok = 0;
        if (PyErr_ExceptionMatches(PyExc_SystemExit)) {
            // Never hand a SystemExit to PyErr_Print: printing one *exits the
            // process*. `exit()` typed at the console, or a script's
            // `sys.exit()`, closed the whole app as if it had crashed. Say what
            // happened instead, and keep going.
            PyObject *type = NULL, *value = NULL, *tb = NULL;
            PyErr_Fetch(&type, &value, &tb);
            PyErr_NormalizeException(&type, &value, &tb);
            PyObject *code = value ? PyObject_GetAttrString(value, "code") : NULL;
            if (!code) PyErr_Clear();
            int clean = !code || code == Py_None;
            if (!clean && PyLong_Check(code)) {
                long n = PyLong_AsLong(code);
                if (n == -1 && PyErr_Occurred()) PyErr_Clear();
                else clean = n == 0;
            }
            PyObject *text = (code && code != Py_None) ? PyObject_Str(code) : NULL;
            if (!text) PyErr_Clear();
            const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL;
            if (!utf8) PyErr_Clear();
            if (clean) {
                PySys_WriteStderr("exit() ends a program, not the app; the console stays open.\n");
            } else {
                PySys_WriteStderr("SystemExit: %.900s\n", utf8 ? utf8 : "?");
            }
            if (ok) *ok = clean;
            Py_XDECREF(text);
            Py_XDECREF(code);
            Py_XDECREF(type);
            Py_XDECREF(value);
            Py_XDECREF(tb);
        } else {
            PyErr_Print();      // the traceback lands in the captured buffer
        }
    } else {
        Py_DECREF(result);
    }

    // Drain whatever the run produced.
    char *out = NULL;
    PyObject *cap = PyDict_GetItemString(main_dict, "_bk_out");
    if (cap) {
        PyObject *text = PyObject_CallMethod(cap, "drain", NULL);
        if (text) {
            const char *utf8 = PyUnicode_AsUTF8(text);
            if (utf8) out = strdup(utf8);
            Py_DECREF(text);
        }
    }
    PyErr_Clear();
    return out ? out : strdup("");
}

void bk_python_stop(void)
{
    if (!g_started) return;
    Py_FinalizeEx();
    g_started = 0;
}
