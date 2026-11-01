"""Round 4, group 8's declared modifier rows in the simulator's stand-in:
every line a row sends for them, run through the stand-in's `bpy` against a
model of the Swift it calls.

The model's rules are read out of the Swift, not copied: which keys each
declared kind has, and whether a key travels as a number
(`bk_scene_modifier_set`: numbers, integers, switches, vectors) or as text
(`bk_scene_modifier_set_object`: enums, enum sets, other objects), come from
`ModifierKind.fields` in ModifierFields.swift. The stand-in's own table
(`Modifier._SETTINGS` in site/bpy/__init__.py) is held to the same rules, so a
key the stand-in sends down the wrong channel, or not at all, fails here.
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


def swift_fields():
    """{BPY_TYPE: {key: channel}} from `ModifierKind.fields`."""
    source = (ROOT / "Sources/BlenderLocalBridge/ModifierFields.swift").read_text()
    body = source[source.index("var fields: [ModifierField] {"):source.index("public extension Modifier {")]
    kinds = {"curve": "CURVE", "wireframe": "WIREFRAME", "skin": "SKIN", "hook": "HOOK", "armature": "ARMATURE",
             "surfaceDeform": "SURFACE_DEFORM", "meshDeform": "MESH_DEFORM", "dataTransfer": "DATA_TRANSFER",
             "normalEdit": "NORMAL_EDIT", "mask": "MASK", "build": "BUILD"}
    out = {}
    for case, chunk in re.findall(r"case \.(\w+):\n(.*?)(?=\n        case \.|\n        default:)", body, re.S):
        if case not in kinds:
            continue
        fields = {}
        # Each field's declaration runs to the next one; a choice's or a
        # set's identifiers are the C("…") inside it, or the `mix` list.
        pieces = re.split(r'(?=F\(")', chunk)
        mix = re.findall(r'C\("(\w+)"', chunk.split("return [")[0])
        for piece in pieces:
            found = re.match(r'F\("(\w+)", "[^"]*", \.(\w+)', piece)
            if not found:
                continue
            key, kind = found.groups()
            channel = {"number": "number", "integer": "number", "toggle": "number", "vector3": "vector",
                       "choice": "text", "flags": "text", "object": "object", "readOnly": None}[kind]
            if channel is None:
                continue
            ids = re.findall(r'C\("(\w+)"', piece) or (mix if ".choice(mix)" in piece else [])
            fields[key] = (channel, kind, ids)
        out[kinds[case]] = fields
    return out


FIELDS = swift_fields()
NAMES = {"WIREFRAME": "Wireframe", "SKIN": "Skin", "HOOK": "Hook", "ARMATURE": "Armature",
         "SURFACE_DEFORM": "SurfaceDeform", "MESH_DEFORM": "MeshDeform", "DATA_TRANSFER": "DataTransfer",
         "NORMAL_EDIT": "NormalEdit", "MASK": "Mask", "BUILD": "Build"}


class App(types.ModuleType):
    """A model of the Swift the stand-in's bridge reaches, for these rows."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.reset()

    def reset(self):
        self.stacks = {"Target": [], "Sphere": []}
        self.values = {}

    def object_names(self):
        return ["Target", "Sphere"]

    def is_selected(self, name):
        return name == "Sphere"

    def active_name(self):
        return "Sphere"

    def mode(self):
        return "OBJECT"

    def modifier_add(self, obj, kind):
        name = NAMES[kind.upper()]
        self.stacks[obj].append((name, kind.upper()))
        return name

    def modifier_list(self, obj):
        # The engine lists a kind by its Swift case name; the stand-in maps it.
        swift = {"SURFACE_DEFORM": "surfaceDeform", "MESH_DEFORM": "meshDeform",
                 "DATA_TRANSFER": "dataTransfer", "NORMAL_EDIT": "normalEdit"}
        return "\n".join("%s|%s" % (n, swift.get(k, k.lower())) for n, k in self.stacks[obj])

    def _kind(self, obj, mod):
        found = dict(self.stacks[obj]).get(mod)
        if found is None:
            raise KeyError("no modifier named %s on %s" % (mod, obj))
        return found

    def modifier_set(self, obj, mod, key, a=0.0, b=0.0, c=0.0):
        kind = self._kind(obj, mod)
        channel = FIELDS.get(kind, {}).get(key, (None,))[0]
        if key in ("show_viewport", "show_render"):
            channel = "number"
        if channel not in ("number", "vector"):
            raise AttributeError("modifier has no setting '%s'" % key)
        self.values[(mod, key)] = (a, b, c) if channel == "vector" else a

    def modifier_set_object(self, obj, mod, key, text):
        kind = self._kind(obj, mod)
        channel, swift_kind, ids = FIELDS.get(kind, {}).get(key, (None, None, []))
        if channel not in ("text", "object"):
            raise AttributeError("modifier has no setting '%s'" % key)
        # `bk_scene_modifier_set_object` answers -2 for an identifier the
        # field's enum does not have, which the C raises as AttributeError.
        if swift_kind == "choice" and text not in ids:
            raise AttributeError("modifier has no setting '%s'" % key)
        if swift_kind == "flags" and not set(t for t in text.split(",") if t) <= set(ids):
            raise AttributeError("modifier has no setting '%s'" % key)
        if text == obj:
            raise TypeError("assignment to itself")
        self.values[(mod, key)] = text

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *a, **k: None


app = App()
sys.modules["_blenderkit"] = app
import bpy  # noqa: E402  the stand-in, over the model

blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[3:].strip()] = body

print("the Swift's declared rows, read")
check("ten kinds the stand-in takes, and Curve, which it keeps its own of",
      sorted(FIELDS) == sorted(list(NAMES) + ["CURVE"]), sorted(FIELDS))

print("\nthe stand-in's table against the Swift's channels")
for kind, fields in sorted(FIELDS.items()):
    if kind == "CURVE":
        continue
    table = bpy.Modifier._SETTINGS.get(kind.lower())
    check("%s: the stand-in has a table" % kind, table is not None)
    if table is None:
        continue
    for key, (channel, _, _) in fields.items():
        theirs = table.get(key)
        want = {"number": 1, "vector": 3, "text": "text", "object": "object"}[channel]
        check("%s %s goes as %s" % (kind, key, channel), theirs == want, theirs)

print("\nevery line each row sends")
for kind in sorted(NAMES):
    app.reset()
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            exec(compile(blocks["SHIM " + kind], "<" + kind + ">", "exec"), {"bpy": bpy})
            error = None
        except Exception as e:                    # noqa: BLE001 - the failure is the finding
            error = "%s: %s" % (type(e).__name__, e)
    name = NAMES[kind]
    sent = {k for (m, k) in app.values if m == name}
    check("%s: added and every setting taken" % kind, error is None and sent == set(FIELDS[kind]),
          (error, sorted(set(FIELDS[kind]) - sent)))

print("\nwhat it refuses")
app.reset()
bpy.ops.object.modifier_add(type='MASK')
mask = bpy.context.object.modifiers["Mask"]
try:
    mask.mode = 'SIDEWAYS'
    said = None
except ValueError as e:
    said = str(e)
check("an enum value the Swift does not have: ValueError", said is not None, said)
try:
    mask.nonsense = 1
    said = None
except AttributeError as e:
    said = str(e)
check("control: a key no row has: AttributeError", said is not None, said)

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
