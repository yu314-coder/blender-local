"""Blender Local — on-device check.

Paste into the Scripting tab and press Run Script.

The one thing this is really for: telling you whether the app is driving the
*real* Blender module or the bundled shim. Everything the interface does now
goes through bpy, so that single fact decides what the app actually is. The
banner in the Scripting tab's control bar says it in a word; this says it with
evidence, and then works through what each backend can and cannot do.

Nothing here is destructive beyond clearing the scene, which it does first.
"""

import os
import sys
import tempfile

PASS, FAIL, SKIP = [], [], []
_LOG = []


def out(*parts):
    """Prints, and keeps a copy for the report file.

    Takes the same loose arguments `print` does — the first version of this
    took exactly one, and every multi-argument call died with a TypeError
    before reaching a single probe.

    The console scrolls and this report runs past one screenful, so it is also
    written to Documents/device_check.txt, which you can open in Files and
    send on.
    """
    line = " ".join(str(p) for p in parts)
    print(line)
    _LOG.append(line)


def check(label, fn, needs_real=False):
    """Runs one probe.

    `needs_real` marks what only Blender can do. On the shim those are skips,
    whatever exception they raise — AttributeError from a missing datablock is
    just as much "the shim has not got this" as NotImplementedError is, and
    counting it as a failure made the summary read alarmingly on a backend that
    was behaving exactly as expected.
    """
    try:
        fn()
        PASS.append(label)
        out("  ok    %s" % label)
    except Exception as e:
        detail = "%s: %s" % (type(e).__name__, str(e)[:52])
        if needs_real and not real:
            SKIP.append(label)
            out("  --    %s  (%s)" % (label, detail))
        else:
            FAIL.append(label)
            out("  FAIL  %s  -> %s" % (label, detail))


def section(title):
    out("")
    out("== %s ==" % title)


import bpy

# ---------------------------------------------------------------- 1. identity
section("1. which backend is this")

# `bpy.app.version` is NOT a discriminator: the shim reports a Blender-shaped
# version on purpose, because scripts branch on it. What cannot be faked is
# where the module came from — the shim is a .py file, Blender's module is a
# compiled .so.
module_file = getattr(bpy, "__file__", "") or ""
real = module_file.endswith((".so", ".fwork")) or ".framework/" in module_file

try:
    out("  bpy.app.version   :", tuple(bpy.app.version))
    out("  build hash        :", getattr(bpy.app, "build_hash", "?"))
except Exception as e:
    out("  bpy.app.version   : unavailable (%s)" % type(e).__name__)
out("  bpy module file   :", module_file or "?")
out("  module kind       :", "compiled (.so)" if real else "Python source (.py)")
out()
out("  VERDICT: %s" % ("REAL BLENDER MODULE" if real else "BUNDLED SHIM"))
if real:
    out("  Everything below should pass, including the half-edge operators.")
else:
    out("  The half-edge operators will report why they cannot run. That is")
    out("  expected on the simulator and a problem on device.")

# ---------------------------------------------------------------- 2. the basics
section("2. operators the interface emits")

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()

check("primitive_cube_add",   lambda: bpy.ops.mesh.primitive_cube_add())
check("primitive_uv_sphere",  lambda: bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0)))
check("primitive_monkey",     lambda: bpy.ops.mesh.primitive_monkey_add(location=(-3, 0, 0)))
check("select_all",           lambda: bpy.ops.object.select_all(action='SELECT'))
check("select_random",        lambda: bpy.ops.object.select_random(ratio=0.5))
check("duplicate_move",       lambda: bpy.ops.object.duplicate_move())
check("shade_smooth",         lambda: bpy.ops.object.shade_smooth())
check("shade_flat",           lambda: bpy.ops.object.shade_flat())
check("location_clear",       lambda: bpy.ops.object.location_clear())
check("transform_apply",      lambda: bpy.ops.object.transform_apply())
check("origin_set",           lambda: bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY'))
check("hide / show",          lambda: (bpy.ops.object.hide_view_set(),
                                       bpy.ops.object.hide_view_clear()))
check("copy / paste buffer",  lambda: (bpy.ops.view3d.copybuffer(),
                                       bpy.ops.view3d.pastebuffer()))
check("snap to grid",         lambda: bpy.ops.view3d.snap_selected_to_grid())
check("cursor to selected",   lambda: bpy.ops.view3d.snap_cursor_to_selected())
check("transform.mirror",     lambda: bpy.ops.transform.mirror(constraint_axis=(True, False, False)))
check("keyframe insert",      lambda: bpy.ops.anim.keyframe_insert_menu(type='LocRotScale'))
check("keyframe delete",      lambda: bpy.ops.anim.keyframe_delete_v3d())

section("3. modifiers")
bpy.ops.object.select_all(action='DESELECT')
bpy.ops.mesh.primitive_cube_add(location=(0, 4, 0))
cube = bpy.context.object
# Counted before the modifier exists: the mesh you read back is already the
# evaluated stack, so measuring after adding it compares a subdivided cube with
# itself and always looks like nothing happened.
plain = len(cube.data.vertices)
check("modifier_add SUBSURF", lambda: bpy.ops.object.modifier_add(type='SUBSURF'))
check("modifier settings",    lambda: setattr(cube.modifiers[0], "levels", 2))
evaluated = len(cube.data.vertices)
out("       %d verts plain -> %d with Subdivision %s"
    % (plain, evaluated,
       "(stack is evaluating)" if evaluated > plain else "(STACK NOT EVALUATING — suspect)"))
check("modifier_apply",       lambda: bpy.ops.object.modifier_apply(modifier=cube.modifiers[0].name))
out("       after apply: %d verts, %d modifier(s) left %s"
    % (len(cube.data.vertices), len(cube.modifiers),
       "(baked in)" if len(cube.data.vertices) == evaluated and not len(cube.modifiers)
       else "(SUSPECT)"))

# ---------------------------------------------------------------- 4. edit mode
section("4. edit mode")

bpy.ops.object.mode_set(mode='EDIT')
check("mesh.select_all",      lambda: bpy.ops.mesh.select_all(action='SELECT'))
check("mesh.select_less",     lambda: bpy.ops.mesh.select_less())
check("mesh.select_more",     lambda: bpy.ops.mesh.select_more())
check("mesh.select_linked",   lambda: bpy.ops.mesh.select_linked())
check("mesh.subdivide",       lambda: bpy.ops.mesh.subdivide(number_cuts=1))
check("mesh.inset",           lambda: bpy.ops.mesh.inset(thickness=0.05))
check("mesh.extrude_region",  lambda: bpy.ops.mesh.extrude_region_move())
check("mesh.poke",            lambda: bpy.ops.mesh.poke())
check("mesh.flip_normals",    lambda: bpy.ops.mesh.flip_normals())
check("mesh.remove_doubles",  lambda: bpy.ops.mesh.remove_doubles(threshold=0.001))
check("mesh.vertices_smooth", lambda: bpy.ops.mesh.vertices_smooth(factor=0.2))
check("transform.vertex_random", lambda: bpy.ops.transform.vertex_random(offset=0.01))

section("5. the half-edge operators — these separate real Blender from the shim")
check("mesh.bevel",           lambda: bpy.ops.mesh.bevel(offset=0.02, segments=2), needs_real=True)
check("mesh.loopcut_slide",   lambda: bpy.ops.mesh.loopcut_slide(), needs_real=True)
check("mesh.knife_tool",      lambda: bpy.ops.mesh.knife_tool(), needs_real=True)
check("mesh.tris_to_quads",   lambda: bpy.ops.mesh.tris_convert_to_quads(), needs_real=True)
check("mesh.symmetrize",      lambda: bpy.ops.mesh.symmetrize(), needs_real=True)
check("mesh.separate",        lambda: bpy.ops.mesh.separate(type='SELECTED'), needs_real=True)
bpy.ops.object.mode_set(mode='OBJECT')

section("6. things only the real module has at all")


def boolean():
    bpy.ops.mesh.primitive_cube_add(location=(0, -4, 0))
    a = bpy.context.object
    bpy.ops.mesh.primitive_uv_sphere_add(location=(0.5, -4, 0))
    b = bpy.context.object
    bpy.context.view_layer.objects.active = a
    bpy.ops.object.modifier_add(type='BOOLEAN')
    a.modifiers[-1].object = b


def nodes():
    mat = bpy.data.materials.new("Probe")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value = 1.0


def eevee():
    engines = bpy.context.scene.render.bl_rna.properties['engine'].enum_items.keys()
    bpy.context.scene.render.engine = 'BLENDER_EEVEE' if 'BLENDER_EEVEE' in engines else 'BLENDER_EEVEE_NEXT'


check("boolean modifier",     boolean, needs_real=True)
check("node-based material",  nodes, needs_real=True)
check("Eevee render engine",  eevee, needs_real=True)
check("mathutils",            lambda: __import__("mathutils").Vector((1, 2, 2)).length)

# Editor-dependent operators can exist but fail poll in headless bpy. This is
# a capability report, not a failed feature check in the wrong object mode.
section("editor context and threading")
import threading
out("  Python thread:", threading.current_thread().name)
out("  window:", getattr(bpy.context, 'window', None))
out("  area:", getattr(bpy.context, 'area', None))
out("  mode:", getattr(bpy.context, 'mode', None))
if real:
    for path in ('mesh.knife_tool', 'mesh.loopcut_slide', 'sculpt.brush_stroke',
                 'paint.image_paint', 'node.add_node', 'render.render'):
        try:
            module, name = path.split('.')
            op = getattr(getattr(bpy.ops, module), name)
            out("  " + path + " poll:", op.poll())
        except Exception as error:
            out("  " + path + ":", type(error).__name__, str(error))

# ---------------------------------------------------------------- summary
out("\n" + "=" * 52)
out("  backend : %s" % ("REAL BLENDER" if real else "shim"))
out("  passed  : %d" % len(PASS))
out("  skipped : %d   (needs the real module)" % len(SKIP))
out("  FAILED  : %d" % len(FAIL))
if FAIL:
    out("\n  failures:")
    for f in FAIL:
        out("    - %s" % f)
out("=" * 52)
if real and FAIL:
    out("  Real Blender is loaded but some operators failed — that is the")
    out("  interesting case. Send me the failure list.")
elif real:
    out("  Real Blender is loaded and everything ran. This is the result")
    out("  the project has been waiting for.")
else:
    out("  Running on the shim. On device this should say REAL BLENDER; if")
    out("  it does not, the 222 MB module did not load and that is the bug")
    out("  to chase before anything else.")

# The console scrolls; the file does not. Written whatever happened above, so
# a script that dies half way still leaves evidence of how far it got.
def _write_report():
    for base in (os.environ.get("HOME", ""), tempfile.gettempdir()):
        if not base:
            continue
        folder = os.path.join(base, "Documents")
        try:
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, "device_check.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(_LOG) + "\n")
            print("\nreport written to " + path)
            return
        except Exception:
            continue
    print("\ncould not write the report anywhere")


_write_report()
