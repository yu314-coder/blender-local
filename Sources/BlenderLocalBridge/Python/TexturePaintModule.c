// The `_blenderkit_paint` module: Texture Paint's bridge between bpy and the
// app's paint engine. `_blenderkit_texpaint.py` is written against it.
//
// A module of its own rather than more rows in `_blenderkit`, so the feature
// arrives as a file: bk_python_start registers it beside `_blenderkit`, and
// every function it calls is implemented in TexturePaintBridge.swift.

#include <Python/Python.h>
#include <limits.h>
#include <string.h>

void bk_paint_surface_begin(void);
int  bk_paint_surface_push(const char *name,
                           const unsigned int *triangle_loops, int triangle_loop_count,
                           const float *loop_uvs, int loop_uv_count,
                           const int *triangle_slots, int triangle_slot_count,
                           const char *slot_images,
                           const unsigned char *base_color, int base_color_count,
                           int active_slot);
void bk_paint_surface_end(void);
int  bk_paint_image_push(const char *name, int width, int height, int channels, int is_float,
                         const float *pixels, int count);
int  bk_paint_image_info(const char *name, int *width, int *height, int *channels);
int  bk_paint_image_pixels(const char *name, float *out, int capacity);
int  bk_paint_image_written(const char *name);
int  bk_paint_shim_enter(const char *name, int width, int height, char *out, int capacity);

static PyObject *paint_surface_begin(PyObject *self, PyObject *args)
{
    (void)self; (void)args;
    bk_paint_surface_begin();
    Py_RETURN_NONE;
}

static PyObject *paint_surface_end(PyObject *self, PyObject *args)
{
    (void)self; (void)args;
    bk_paint_surface_end();
    Py_RETURN_NONE;
}

/// surface_push(name, triangle loops uint32, loop UVs float32, triangle
///              material indices int32, slot image names joined by newlines,
///              one byte per slot for "feeds Base Color", active slot)
static PyObject *paint_surface_push(PyObject *self, PyObject *args)
{
    (void)self;
    const char *name, *images;
    Py_buffer loops, uvs, slots, base;
    int active = 0;
    if (!PyArg_ParseTuple(args, "sy*y*y*sy*i", &name, &loops, &uvs, &slots, &images, &base, &active)) {
        return NULL;
    }
    int rc = -1;
    if (loops.len % (3 * sizeof(unsigned int)) == 0 && uvs.len % (2 * sizeof(float)) == 0 &&
        slots.len % sizeof(int) == 0 && loops.len / sizeof(unsigned int) < INT_MAX &&
        uvs.len / sizeof(float) < INT_MAX) {
        rc = bk_paint_surface_push(name,
                                   (const unsigned int *)loops.buf, (int)(loops.len / sizeof(unsigned int)),
                                   (const float *)uvs.buf, (int)(uvs.len / sizeof(float)),
                                   (const int *)slots.buf, (int)(slots.len / sizeof(int)),
                                   images, (const unsigned char *)base.buf, (int)base.len, active);
    }
    PyBuffer_Release(&loops);
    PyBuffer_Release(&uvs);
    PyBuffer_Release(&slots);
    PyBuffer_Release(&base);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed paint surface for %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// image_push(name, width, height, channels, is_float, pixels float32)
static PyObject *paint_image_push(PyObject *self, PyObject *args)
{
    (void)self;
    const char *name;
    int width, height, channels, is_float;
    Py_buffer pixels;
    if (!PyArg_ParseTuple(args, "siiipy*", &name, &width, &height, &channels, &is_float, &pixels)) {
        return NULL;
    }
    int rc = -1;
    if (pixels.len % sizeof(float) == 0 && pixels.len / sizeof(float) < INT_MAX) {
        rc = bk_paint_image_push(name, width, height, channels, is_float,
                                 (const float *)pixels.buf, (int)(pixels.len / sizeof(float)));
    }
    PyBuffer_Release(&pixels);
    if (rc != 0) {
        PyErr_Format(PyExc_ValueError, "malformed pixels for image %s", name);
        return NULL;
    }
    Py_RETURN_NONE;
}

/// image_pixels(name) -> bytes of float32 in Blender's layout, or None when
/// the viewport has no such image.
static PyObject *paint_image_pixels(PyObject *self, PyObject *args)
{
    (void)self;
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    int width = 0, height = 0, channels = 0;
    if (bk_paint_image_info(name, &width, &height, &channels) != 0) Py_RETURN_NONE;
    long long count = (long long)width * height * channels;
    if (count <= 0 || count >= INT_MAX / 4) {
        PyErr_Format(PyExc_ValueError, "image %s is too large to hand over", name);
        return NULL;
    }
    PyObject *bytes = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)(count * sizeof(float)));
    if (!bytes) return NULL;
    int written = bk_paint_image_pixels(name, (float *)PyBytes_AS_STRING(bytes), (int)count);
    if (written != count) {
        Py_DECREF(bytes);
        PyErr_Format(PyExc_RuntimeError, "the viewport's copy of %s could not be read", name);
        return NULL;
    }
    return bytes;
}

static PyObject *paint_image_written(PyObject *self, PyObject *args)
{
    (void)self;
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name)) return NULL;
    bk_paint_image_written(name);
    Py_RETURN_NONE;
}

/// shim_enter(object, width, height) -> the operators the simulator's stand-in
/// performed, one per line.
static PyObject *paint_shim_enter(PyObject *self, PyObject *args)
{
    (void)self;
    const char *name;
    int width = 1024, height = 1024;
    if (!PyArg_ParseTuple(args, "s|ii", &name, &width, &height)) return NULL;
    char out[256] = {0};
    if (bk_paint_shim_enter(name, width, height, out, (int)sizeof(out)) != 0) {
        PyErr_Format(PyExc_KeyError, "no object named %s", name);
        return NULL;
    }
    return PyUnicode_FromString(out);
}

static PyMethodDef paint_methods[] = {
    {"surface_begin", paint_surface_begin, METH_NOARGS,  "Start reporting paint surfaces."},
    {"surface_push",  paint_surface_push,  METH_VARARGS, "One object's UVs, slots and slot images."},
    {"surface_end",   paint_surface_end,   METH_NOARGS,  "Install the reported surfaces."},
    {"image_push",    paint_image_push,    METH_VARARGS, "Hand the viewport one image's pixels."},
    {"image_pixels",  paint_image_pixels,  METH_VARARGS, "The viewport's pixels for one image, as float32 bytes."},
    {"image_written", paint_image_written, METH_VARARGS, "Blender now holds the viewport's pixels for an image."},
    {"shim_enter",    paint_shim_enter,    METH_VARARGS, "The simulator's stand-in for entering Texture Paint."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef paint_module = {
    PyModuleDef_HEAD_INIT, "_blenderkit_paint",
    "Texture Paint's bridge between bpy and Blender Local's paint engine.",
    -1, paint_methods, NULL, NULL, NULL, NULL
};

PyObject *PyInit__blenderkit_paint(void) { return PyModule_Create(&paint_module); }
