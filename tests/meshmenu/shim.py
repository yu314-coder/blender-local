"""The simulator's stand-in for Blender, given the Mesh menu's round-4 rows.

The iOS Simulator runs the app on Resources/python/site/bpy, which has no
BMesh, no edge selection, no custom normals and no 3D View. Every call those
rows send (the same blocks scripts/run-meshmenu-blender-check.sh puts through
desktop Blender) must there either do what Blender does or refuse in words:
NotImplementedError or RuntimeError saying what the stand-in lacks — never an
AttributeError, TypeError or NameError, which would put a traceback on the
banner, and never FINISHED for something else (Merge At First used to weld by
distance here).
"""
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Resources/python/site"))
sys.dont_write_bytecode = True
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


class App(types.ModuleType):
    """The Swift the stand-in calls, holding one cube being edited."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.ops = []

    def object_names(self):
        return ["Cube"]

    def active_name(self):
        return "Cube"

    def is_selected(self, name):
        return True

    def mode(self):
        return "EDIT"

    def object_kind(self, name):
        return "MESH"

    def mesh_counts(self, name):
        return (8, 12)

    def mesh_op(self, name, value):
        self.ops.append(name)
        return 0

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *a, **k: None


app = App()
sys.modules["_blenderkit"] = app
import bpy  # noqa: E402  (the stand-in, from Resources/python/site)
import _blenderkit_meshmenu  # noqa: E402,F401

blocks = {}
for b in open(sys.argv[1]).read().split("#--"):
    b = b.strip()
    if b:
        head, body = b.split("\n", 1)
        blocks[head[4:]] = body

# What the stand-in can do, as Blender does it.
DOES = {"row.deleteVertices PERFORM", "row.deleteEdges PERFORM", "row.deleteFaces PERFORM"}
# Recalculate Outside: FINISHED with nothing to turn, as Blender on a mesh
# whose faces already face out (the stand-in builds them so).
NOTHING = {"row.recalculateNormals PERFORM"}
ran = 0
for name, body in sorted(blocks.items()):
    if not (name.endswith(" PERFORM") or name.endswith(" EXTRUDE") or name.endswith(" NOROT")
            or name.endswith(" RIP")):
        continue
    ran += 1
    app.ops.clear()
    try:
        exec(compile(body, "<" + name + ">", "exec"), {"bpy": bpy})
        error = None
    except Exception as e:                       # noqa: BLE001 - the kind and the words are the point
        error = e
    if name in NOTHING:
        check(f"{name}: done, nothing to turn", error is None and not app.ops, (error, app.ops))
        continue
    if name in DOES:
        check(f"{name}: done, as Blender does it ({app.ops})", error is None and app.ops, error)
        continue
    words = str(error) if error is not None else ""
    check(f"{name}: refused in words: {type(error).__name__}: {words[:90]}",
          isinstance(error, (NotImplementedError, RuntimeError)) and len(words.split()) >= 4
          and not app.ops, f"{type(error).__name__}: {error}; ran {app.ops}")

# The stand-in's own Merge and Delete, by type.
for kind in ("CURSOR", "FIRST", "LAST"):
    try:
        bpy.ops.mesh.merge(type=kind)
        error = None
    except NotImplementedError as e:
        error = e
    check(f"Merge {kind} is refused in words, not welded by distance", error is not None and "Merge" in str(error))
for kind in ("EDGE_FACE", "ONLY_FACE"):
    try:
        bpy.ops.mesh.delete(type=kind)
        error = None
    except NotImplementedError as e:
        error = e
    check(f"Delete {kind} is refused in words", error is not None and "Delete" in str(error))
check(f"{ran} calls put through the stand-in", ran > 40, ran)

# The rule can fail: an operator the stand-in does not name.
try:
    bpy.ops.mesh.not_an_operator_of_the_stand_in()
    error = None
except Exception as e:                           # noqa: BLE001
    error = e
check(f"the negative control: an unnamed operator is not words ({type(error).__name__})",
      not isinstance(error, (NotImplementedError, RuntimeError)) or len(str(error).split()) < 4, error)

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
