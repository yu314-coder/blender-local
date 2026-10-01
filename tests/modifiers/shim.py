"""The simulator's modifiers, on the Mac, against a model of the Swift the shim
calls.

Every string the Modifiers panel's rows send (tests/modifiers/blender/main.swift
prints them; desktop Blender runs the same file) is run here through the
shim's `bpy`. The rows no longer write the display cache before sending, so in
the simulator a setting the shim refuses would now simply not change — which
used to be hidden by the cache write: Mirror's `use_axis[0] = …`, Wave's
`use_x`, and both object pointers all raised there.
"""
import contextlib
import io
import pathlib
import re
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources/python/site"))
sys.dont_write_bytecode = True
CALLS = sys.argv[1]

fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


# Display names, as ModifierKind.displayName and its bpyType.
KINDS = {"SUBSURF": ("subdivision", "Subdivision"), "MIRROR": ("mirror", "Mirror"),
         "WAVE": ("wave", "Wave"), "SHRINKWRAP": ("shrinkwrap", "Shrinkwrap"),
         "SCREW": ("screw", "Screw"), "DECIMATE": ("decimate", "Decimate"),
         "REMESH": ("remesh", "Remesh"), "BOOLEAN": ("boolean", "Boolean"),
         "BEVEL": ("bevel", "Bevel"),
         "WEIGHTED_NORMAL": ("weightedNormal", "WeightedNormal"), "MULTIRES": ("multires", "Multires"),
         "EDGE_SPLIT": ("edgeSplit", "EdgeSplit"), "LAPLACIANSMOOTH": ("laplacianSmooth", "LaplacianSmooth"),
         "CORRECTIVE_SMOOTH": ("correctiveSmooth", "CorrectiveSmooth"), "LATTICE": ("lattice", "Lattice")}


def swift_keys():
    """What `bk_scene_modifier_set` in EmbeddedBpyRuntime.swift takes, read out
    of its `switch` rather than copied here. A hand-kept copy could not fail:
    with `case "use_x"` dropped from the Swift this file went on passing."""
    source = (ROOT / "Sources/BlenderLocalBridge/Python/EmbeddedBpyRuntime.swift").read_text()
    start = source.index("func bk_scene_modifier_set(")
    body = source[start:source.index("@_cdecl(", start)]
    body = body[body.index("switch k {"):]
    keys = set()
    for labels in re.findall(r'^\s*case ((?:"[a-z_]+"(?:,\s*)?)+):', body, re.M):
        keys.update(re.findall(r'"([a-z_]+)"', labels))
    return keys


KEYS = swift_keys()
TRIPLES = ("use_axis", "relative_offset", "use_bisect_axis", "use_bisect_flip_axis")


class App(types.ModuleType):
    """A model of the Swift the shim's bridge reaches, for modifiers."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.reset()

    def reset(self):
        self.current_mode = "OBJECT"
        self.modes = []
        self.order = ["Target", "Sphere"]
        self.selected = {"Sphere"}
        self.active = "Sphere"
        self.stacks = {"Target": [], "Sphere": []}
        self.values = {}

    def object_names(self):
        return list(self.order)

    # `bk_mode` and `bk_scene_set_mode`: the interface's mode, which is the
    # stand-in's `object.mode`. Every mode it is put in is kept, so a check
    # can see Multires's buttons leave the app's Sculpt Mode and come back.
    def mode(self):
        return self.current_mode

    def set_mode(self, mode):
        if mode.upper() not in ("OBJECT", "EDIT", "SCULPT", "VERTEX_PAINT", "WEIGHT_PAINT",
                                "TEXTURE_PAINT"):
            raise ValueError("unknown mode %s" % mode)
        self.current_mode = mode.upper()
        self.modes.append(self.current_mode)

    def is_selected(self, name):
        return name in self.selected

    def active_name(self):
        return self.active

    # Blender's OnlyDeform kinds and the one that needs the original mesh, as
    # `ModifierKind.onlyDeforms` / `requiresOriginalData` in the Swift.
    ONLY_DEFORM = {"smooth", "cast", "simpleDeform", "displace", "wave", "shrinkwrap",
                   "laplacianSmooth", "correctiveSmooth", "lattice"}

    def modifier_add(self, obj, kind):
        base, label = KINDS[kind.upper()]
        taken = sum(1 for n, k in self.stacks[obj] if k == base)
        name = label if taken == 0 else "%s.%03d" % (label, taken)
        # `ModifierStack.insertionIndex`: a Multires goes above the first
        # modifier that is not a pure deform.
        at = len(self.stacks[obj])
        if base == "multires":
            at = next((i for i, (_, k) in enumerate(self.stacks[obj]) if k not in self.ONLY_DEFORM), at)
        self.stacks[obj].insert(at, (name, base))
        return name

    # What Multires's Subdivide reads after the operator: the object is a
    # mesh (no camera or light record) with faces — the 32 x 16 UV sphere,
    # counted in triangles as the stand-in counts them.
    def object_display(self, name):
        return None

    def mesh_counts(self, name):
        return (482, 960)

    def modifier_remove(self, obj, mod):
        self.stacks[obj] = [(n, k) for n, k in self.stacks[obj] if n != mod]

    def modifier_list(self, obj):
        return "\n".join("%s|%s" % entry for entry in self.stacks[obj])

    def modifier_set(self, obj, mod, key, a=0.0, b=0.0, c=0.0):
        if key not in KEYS or (key == "decimate_type" and int(a) != 0):
            raise AttributeError("modifier has no setting '%s'" % key)
        if mod not in [n for n, _ in self.stacks[obj]]:
            raise KeyError("no modifier named %s on %s" % (mod, obj))
        self.values[(obj, mod, key)] = (a, b, c) if key in TRIPLES else a

    def object_op(self, op, amount=0.0):
        """The shim's Move Up / Move Down: 1 when it moved, 0 past an end."""
        stack = self.stacks[self.active]
        index = int(amount)
        target = index - 1 if op == "modifier_move_up" else index + 1
        if not (0 <= index < len(stack) and 0 <= target < len(stack)):
            return 0
        # `ModifierStack.canMove`: Blender's rule around a Multires.
        moving, neighbour = stack[index][1], stack[target][1]
        if op == "modifier_move_up" and moving not in self.ONLY_DEFORM and neighbour == "multires":
            return 0
        if op == "modifier_move_down" and moving == "multires" and neighbour not in self.ONLY_DEFORM:
            return 0
        stack[index], stack[target] = stack[target], stack[index]
        return 1

    def modifier_set_object(self, obj, mod, key, other):
        kind = dict(self.stacks[obj]).get(mod)
        if not ((key == "object" and kind in ("boolean", "lattice")) or (key == "target" and kind == "shrinkwrap")):
            raise AttributeError("modifier has no setting '%s'" % key)
        if other == obj:
            raise TypeError("bpy_struct: item.attr = val: %s ID type does not support "
                            "assignment to itself" % key)
        self.values[(obj, mod, key)] = other


app = App()
sys.modules["_blenderkit"] = app
import bpy  # noqa: E402  the shim, over the model

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


def run(name):
    app.reset()
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            exec(compile(blocks[name], "<" + name + ">", "exec"), {"bpy": bpy})
        except Exception as error:  # noqa: BLE001 - the failure is the finding
            return "%s: %s" % (type(error).__name__, error)
    return None


def value(mod, key):
    return app.values.get(("Sphere", mod, key))


print("every line the rows send is taken by the simulator's stand-in")
for name in ("SHRINKWRAP", "SHRINKWRAP_NONE", "SCREW", "DECIMATE", "REMESH_VOXEL",
             "REMESH_BLOCKS", "SUBSURF", "WAVE", "MIRROR", "MIRROR_FULL", "REMESH_ADD_SMALL"):
    check(name, run(name) is None, run(name))

run("SHRINKWRAP")
check("Shrinkwrap's target reaches the scene by name", value("Shrinkwrap", "target") == "Target",
      app.values)
run("WAVE")
check("Wave's Motion X and Y reach it", value("Wave", "use_x") == 0.0 and value("Wave", "use_y") == 1.0,
      app.values)
run("MIRROR")
check("Mirror's three axes, in one call", value("Mirror", "use_axis") == (0.0, 0.0, 1.0), app.values)
run("MIRROR_FULL")
check("Mirror's Bisect and Flip reach it as triples",
      value("Mirror", "use_bisect_axis") == (1.0, 0.0, 0.0)
      and value("Mirror", "use_bisect_flip_axis") == (1.0, 0.0, 1.0), app.values)
check("and Clipping, Merge and the distance as numbers",
      value("Mirror", "use_clip") == 1.0 and value("Mirror", "use_mirror_merge") == 0.0
      and abs(value("Mirror", "merge_threshold") - 0.0025) < 1e-9, app.values)
check("Add Modifier's Remesh on a large object sets the floor on the one it added",
      run("REMESH_ADD_LARGE") is None and value("Remesh", "voxel_size") == 0.390625, app.values)

print("\nwhat the stand-in refuses, it refuses as Blender does")
app.reset()
bpy.ops.object.modifier_add(type='SHRINKWRAP')
shrinkwrap = bpy.context.object.modifiers["Shrinkwrap"]


def refused(fn):
    try:
        fn()
    except Exception as error:  # noqa: BLE001
        return "%s: %s" % (type(error).__name__, error)
    return None


said = refused(lambda: setattr(shrinkwrap, "target", bpy.context.object))
check("a modifier's own object as its target: TypeError", said and said.startswith("TypeError"), said)
said = refused(lambda: setattr(shrinkwrap, "target", "Target"))
check("a name where an object goes: TypeError", said and said.startswith("TypeError"), said)
check("None clears it", refused(lambda: setattr(shrinkwrap, "target", None)) is None
      and value("Shrinkwrap", "target") == "")
bpy.ops.object.modifier_add(type='WAVE')
said = refused(lambda: setattr(bpy.context.object.modifiers["Wave"], "deform_axis", 'X'))
check("Wave has no deform_axis, as in Blender 5.2.1", said and said.startswith("AttributeError"), said)
check("modifiers.active is the one just added", bpy.context.object.modifiers.active.name == "Wave")

print("\nthe six new rows, and the controls every row has")
for name in ("WEIGHTED_NORMAL", "MULTIRES", "EDGE_SPLIT", "LAPLACIANSMOOTH", "CORRECTIVE_SMOOTH",
             "LATTICE_NONE"):
    check(name, run(name) is None, run(name))
run("WEIGHTED_NORMAL")
check("Weighted Normal's mode goes by its own enum, not Remesh's (CORNER_ANGLE is 1)",
      value("WeightedNormal", "mode") == 1.0 and value("WeightedNormal", "weight") == 70.0, app.values)
run("LAPLACIANSMOOTH")
check("Laplacian Smooth's axes reach it as its own", value("LaplacianSmooth", "use_y") == 0.0
      and value("LaplacianSmooth", "use_z") == 1.0 and value("LaplacianSmooth", "lambda_factor") == 0.5,
      app.values)
run("CORRECTIVE_SMOOTH")
check("Corrective Smooth's type by its index", value("CorrectiveSmooth", "smooth_type") == 1.0
      and value("CorrectiveSmooth", "scale") == 2.0, app.values)
run("MULTIRES")
check("Multires's Subdivide reaches the stand-in's operator",
      value("Multires", "multires_subdivide") == 0.0, app.values)
check("and its render level stays its own, where a Subdivision's folds into the viewport's",
      value("Multires", "render_levels") == 2.0 and value("Multires", "levels") == 1.0, app.values)
said = run("LATTICE")
check("the stand-in has no lattice to point a Lattice at, and says so",
      said is not None and "Cage" in said, said)


def stack(obj="Sphere"):
    return [n for n, _ in app.stacks[obj]]


def with_pair(name):
    app.reset()
    with contextlib.redirect_stdout(io.StringIO()):
        bpy.ops.object.modifier_add(type='SUBSURF')
        bpy.ops.object.modifier_add(type='WAVE')
        try:
            exec(compile(blocks[name], "<" + name + ">", "exec"), {"bpy": bpy})
        except Exception as error:  # noqa: BLE001 - the failure is the finding
            return "%s: %s" % (type(error).__name__, error)
    return None


said = with_pair("SHIM_UP_WAVE")
check("Move Up reaches the stand-in", said is None and stack() == ["Wave", "Subdivision"], (said, stack()))
said = with_pair("SHIM_DOWN_SUBSURF")
check("Move Down too", said is None and stack() == ["Wave", "Subdivision"], (said, stack()))
said = with_pair("SHIM_UP_FIRST")
check("a move past the top is CANCELLED there as in Blender, and the row's refusal raises",
      said is not None and said.startswith("RuntimeError") and stack() == ["Subdivision", "Wave"], said)
said = with_pair("SHIM_VIEWPORT_WAVE")
check("the header's switch reaches it on any kind", said is None and value("Wave", "show_viewport") == 0.0,
      (said, app.values))
said = with_pair("SHIM_REMOVE_WAVE")
check("remove", said is None and stack() == ["Subdivision"], (said, stack()))
app.reset()
bpy.ops.object.modifier_add(type='MULTIRES')
for op, ok in (("subdivide", True), ("deleteHigher", True), ("unsubdivide", False), ("applyBase", False)):
    said = refused(lambda: exec(blocks["SHIM_MULTIRES_" + op], {"bpy": bpy}))
    check("Multires %s: %s" % (op, "taken" if ok else "refused in words, as the stand-in cannot"),
          (said is None) if ok else (said is not None and said.startswith("NotImplementedError")), said)

# The app's own Sculpt Mode in the simulator: the buttons go through
# _blenderkit_multires, which leaves for Object Mode, runs the stand-in's
# operator there and comes back, as the mode guard did for the bare operator.
app.reset()
bpy.ops.object.modifier_add(type='MULTIRES')
app.set_mode("SCULPT")
app.modes = []
said = refused(lambda: exec(blocks["SHIM_MULTIRES_subdivide"], {"bpy": bpy}))
check("from the simulator's Sculpt Mode, Subdivide runs in Object Mode and returns to Sculpt Mode",
      said is None and app.modes == ["OBJECT", "SCULPT"]
      and value("Multires", "multires_subdivide") == 0.0, (said, app.modes, app.values))
app.set_mode("SCULPT")
app.modes = []
said = refused(lambda: exec(blocks["SHIM_MULTIRES_applyBase"], {"bpy": bpy}))
check("and a refusal there still puts Sculpt Mode back", said is not None
      and said.startswith("NotImplementedError") and app.modes == ["OBJECT", "SCULPT"], (said, app.modes))

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
