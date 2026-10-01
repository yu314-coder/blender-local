"""Vertex groups and shape keys, run by the Blender they run on.

scripts/run-groups-blender-check.sh starts desktop Blender with
`-b --factory-startup` and a home of its own. Every string run here is the one
the Swift sends (tests/groups/blender/main.swift prints them), through the
module the app ships (Resources/python/site/_blenderkit_groups.py), with the
context the app has: an undo stack, from `ed.undo_push` under the startup
window and screen, as `_blenderkit_undo` makes one.

What is checked, in the order a session meets it:

  * each vertex-group control lands on Blender: add, rename (and a name with
    every separator the record uses), the active group, lock, Assign at the
    Weight field's weight, Remove, Select, Deselect, remove one and all;
  * the refusals are sentences, not silence: Assign and Remove with nothing
    selected (Blender returns FINISHED and CANCELLED, saying nothing) or on a
    locked group, Assign in Object Mode, a group or key that is not there,
    and shape keys added in Edit Mode;
  * each shape-key control lands: Basis and new keys, a value (clamped as
    Blender clamps it), the range, relative key, vertex group, mute, lock,
    rename, Relative, Shape Key Lock, Edit Mode, New Shape from Mix, remove,
    Delete All and Apply All — and each moves the evaluated mesh the way
    Blender's own button does;
  * editing a key's shape: in Edit Mode with Key 1 active, the app's move
    changes Key 1 and leaves Basis, and the mirror draws Key 1 at full;
  * one Undo takes each change back, except where the Swift sends none —
    those are measured here to stay, which is why it sends none;
  * the mirror: the app's own `sync()` hands `sync_groups` the record, with
    counts for the active object only, and the Swift (main.swift replay)
    reads back exactly what Blender held; and every modifier kind with a
    Vertex Group field takes the row's edit, changes its result with it, and
    reads back through `_modifier_record`.
"""
import bpy, bmesh, sys, os, json, types, pathlib, importlib.util, contextlib, io

sys.dont_write_bytecode = True
CALLS, OUT = sys.argv[sys.argv.index("--") + 1:][:2]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`, keeping what the mirror hands
    the Data tab and the Modifiers panel."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.groups, self.modifiers, self.calls = {}, {}, []

    def sync_begin(self):
        self.groups, self.modifiers = {}, {}

    def sync_push(self, *args):
        pass

    def sync_end(self):
        pass

    def sync_modifiers(self, name, record):
        self.modifiers[name] = record

    def select_all(self, *args):
        pass

    def select(self, *args):
        pass

    def set_active(self, *args):
        pass

    def anim_frame(self, *args):
        pass

    def anim_mesh(self, *args):
        pass

    def sync_groups(self, name, record, during_pass=1):
        self.groups[name] = record
        self.calls.append((name, bool(during_pass)))


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sys.path.insert(0, str(SITE))
groups_module = load("_blenderkit_groups")
sync_module = load("_blenderkit_sync")

window = bpy.context.window_manager.windows[0]


def ed(name, **kw):
    with bpy.context.temp_override(window=window, screen=window.screen):
        return getattr(bpy.ops.ed, name)(**kw)


namespace = {"bpy": bpy}


def run(name):
    """One block as the bridge runs it; the sentence it raised, or None."""
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(blocks[name], "<" + name + ">", "exec"), namespace)
    except RuntimeError as error:
        return str(error)
    return None


def ran(name, label=None):
    error = run(name)
    check(label or (name + " runs"), error is None, error)
    return error is None


def refused(name, words):
    error = run(name)
    check(name + " is refused in words: " + repr(words), error is not None and words in error, error)


def O():
    return bpy.data.objects["Grid"]


def members(group_name):
    """{vertex index: weight} of one group, as the mesh or the edit mesh has it."""
    obj = O()
    group = obj.vertex_groups[group_name]
    if obj.mode == 'EDIT':
        bm = bmesh.from_edit_mesh(obj.data)
        layer = bm.verts.layers.deform.active
        if layer is None:
            return {}
        return {v.index: round(v[layer][group.index], 4) for v in bm.verts if group.index in v[layer]}
    return {v.index: round(g.weight, 4) for v in obj.data.vertices for g in v.groups if g.group == group.index}


def select_where(test):
    """The vertices `test` passes selected and nothing else, as the app's
    tap hands a selection over (`Bpy.pushEditSelection`): faces and edges
    deselected first, or a face left selected re-selects its corners when
    the edit mesh is rebuilt (measured: a key switch in Edit Mode then
    showed all 25 selected)."""
    bm = bmesh.from_edit_mesh(O().data)
    for seq in (bm.faces, bm.edges, bm.verts):
        for element in seq:
            element.select = False
    for v in bm.verts:
        v.select = bool(test(v))
    bm.select_flush_mode()
    bmesh.update_edit_mesh(O().data)


def selected():
    return sum(v.select for v in bmesh.from_edit_mesh(O().data).verts)


def evaluated():
    obj = O()
    if obj.mode == 'EDIT':
        obj.update_from_editmode()
    e = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    m = e.to_mesh()
    co = [tuple(round(c, 5) for c in v.co) for v in m.vertices]
    e.to_mesh_clear()
    return co


replays = []


def truth(label):
    """What Blender holds now, beside the record `push` hands the mirror."""
    obj = O()
    if obj.mode == 'EDIT':
        obj.update_from_editmode()
    groups_module.push(obj, during_pass=True, with_counts=True)
    keys = obj.data.shape_keys
    counts = [len(members(g.name)) for g in obj.vertex_groups]
    replays.append({
        "label": label, "record": bridge.groups[obj.name],
        "groups": [g.name for g in obj.vertex_groups], "counts": counts,
        "locks": [g.lock_weight for g in obj.vertex_groups],
        "active_group": obj.vertex_groups.active_index,
        "weight": bpy.context.scene.tool_settings.vertex_group_weight,
        "active_key": obj.active_shape_key_index if keys else -1,
        "use_relative": keys.use_relative if keys else True,
        "reference": keys.reference_key.name if keys else "",
        "show_only": obj.show_only_shape_key, "key_edit_mode": obj.use_shape_key_edit_mode,
        "keys": [{"name": k.name, "value": k.value, "min": k.slider_min, "max": k.slider_max,
                  "relative": k.relative_key.name if k.relative_key else "", "mute": k.mute,
                  "lock": k.lock_shape, "vertex_group": k.vertex_group}
                 for k in (keys.key_blocks if keys else [])]})


def undo_round(label, change):
    """`change` (a block name or a function), one undo step, then Undo:
    whether the state came back, and Redo: whether the change did."""
    def state():
        obj = O()
        if obj.mode == 'EDIT':
            obj.update_from_editmode()
        groups_module.push(obj, during_pass=True, with_counts=True)
        return bridge.groups[obj.name]
    # The app pushes a step after every change, so the step before this one
    # is the state it starts from.
    ed("undo_push", message="before " + label)
    before = state()
    if isinstance(change, str):
        error = run(change)
        if error:
            check(label + ": runs", False, error)
            return None
    else:
        change()
    ed("undo_push", message=label)
    after = state()
    ed("undo")
    undone = state()
    ed("redo")
    redone = state()
    return before != after, undone == before, redone == after


# --------------------------------------------------------------------------
print("== the scene and the app's context ==")
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
bpy.ops.mesh.primitive_grid_add(x_subdivisions=4, y_subdivisions=4, size=2)
check("a 5 x 5 grid called Grid", O().name == "Grid" and len(O().data.vertices) == 25)
check("an undo stack, as _blenderkit_undo makes one", 'FINISHED' in ed("undo_push", message="start"))

print("\n== vertex groups ==")
ran("ADD_GROUP")
ran("ADD_GROUP", "a second Add")
check("Blender named them Group and Group.001, the second active",
      [g.name for g in O().vertex_groups] == ["Group", "Group.001"] and O().vertex_groups.active_index == 1)
check("the Info log line is Blender's operator", blocks["ADD_GROUP.call"] == "bpy.ops.object.vertex_group_add()")
ran("RENAME_GROUP")
ran("RENAME_GROUP_2")
check("renamed Left and Right", [g.name for g in O().vertex_groups] == ["Left", "Right"])
refused("RENAME_GROUP_EMPTY", "needs a name")
refused("ACTIVE_MISSING", "no vertex group called 'Nope'")
ran("ACTIVE_LEFT")
check("Left active", O().vertex_groups.active_index == 0)
ran("LOCK_RIGHT")
check("Right locked", O().vertex_groups["Right"].lock_weight)
refused("ASSIGN_LEFT", "works in Edit Mode")
truth("object mode, two groups, Right locked")

bpy.ops.object.mode_set(mode='EDIT')
ed("undo_push", message="Edit Mode")
select_where(lambda v: v.co.x < -0.1)
check("ten vertices selected, x < 0", selected() == 10)
ran("WEIGHT")
check("the Weight field sets Blender's tool setting",
      abs(bpy.context.scene.tool_settings.vertex_group_weight - 0.25) < 1e-6)
ran("WEIGHT_PAST")
check("a weight past Blender's range is sent clamped",
      bpy.context.scene.tool_settings.vertex_group_weight == 0.0)
ran("ASSIGN_LEFT")
left = members("Left")
check("Assign put the ten selected into Left at the weight sent (0.5)",
      len(left) == 10 and set(left.values()) == {0.5}, left)
check("and the Weight field shows the weight Assign used",
      abs(bpy.context.scene.tool_settings.vertex_group_weight - 0.5) < 1e-6)
ran("ASSIGN_LEFT_HEAVY")
check("a weight of 7 is sent as 1, Blender's maximum", set(members("Left").values()) == {1.0})
refused("ASSIGN_RIGHT", "Right is locked: unlock it")
check("Right stays empty", members("Right") == {})
refused("REMOVE_FROM_RIGHT", "Right is locked: unlock it")
select_where(lambda v: False)
refused("ASSIGN_LEFT", "Nothing is selected")
refused("REMOVE_FROM_LEFT", "Nothing is selected")
ran("SELECT_LEFT")
check("Select by Left selects its ten", selected() == 10)
select_where(lambda v: True)
ran("DESELECT_LEFT")
check("Deselect by Left leaves the other fifteen", selected() == 15)
select_where(lambda v: v.index == 0)
ran("REMOVE_FROM_LEFT")
check("Remove takes the one selected out of Left", len(members("Left")) == 9 and 0 not in members("Left"))
truth("edit mode, Left holding nine")
ran("UNLOCK_RIGHT")
ran("ADD_GROUP", "Add in Edit Mode")
ran("RENAME_GROUP_ODD")
check("a name with every separator the record uses",
      [g.name for g in O().vertex_groups] == ["Left", "Right", "a;b|c=d%e"])
truth("a group named a;b|c=d%e")
ran("REMOVE_GROUP_RIGHT")
check("Remove takes Right, whichever group was active",
      [g.name for g in O().vertex_groups] == ["Left", "a;b|c=d%e"])

print("\n== undo, in Edit Mode ==")
select_where(lambda v: v.co.y > 0.1)
# Assign sends the weight the Weight field shows, so the field already holds
# it — and a tool setting is not in any undo step.
bpy.context.scene.tool_settings.vertex_group_weight = 0.5
for label, change in (("Assign", "ASSIGN_LEFT"), ("Active group", "ACTIVE_LEFT"),
                      ("Add Vertex Group", "ADD_GROUP"), ("Lock", "LOCK_RIGHT_ODD")):
    if change == "LOCK_RIGHT_ODD":
        change = lambda: setattr(O().vertex_groups["Left"], "lock_weight", True)
    result = undo_round(label, change)
    if result:
        check(label + ": changed, one Undo takes it back, Redo brings it again",
              result == (True, True, True) or (label == "Active group" and result[1:] == (True, True)), result)
O().vertex_groups["Left"].lock_weight = False
result = undo_round("Weight", "WEIGHT")
check("the Weight field: Undo does not take it back, so no step is sent",
      result is not None and result[1] is False and blocks["ASSIGN_LEFT.undo"] == "Assign to Vertex Group",
      result)

print("\n== shape keys ==")
refused("ADD_KEY", "works in Object Mode")
bpy.ops.object.mode_set(mode='OBJECT')
ed("undo_push", message="Object Mode")
base = evaluated()
ran("ADD_KEY")
check("the first key is Basis", [k.name for k in O().data.shape_keys.key_blocks] == ["Basis"])
ran("ADD_KEY")
ran("ADD_KEY")
keys = O().data.shape_keys.key_blocks
check("then Key 1 and Key 2", [k.name for k in keys] == ["Basis", "Key 1", "Key 2"])
# Key 1 lifts the left half by one, as a sculpt or an edit would.
for point, vertex in zip(keys["Key 1"].data, O().data.vertices):
    if vertex.co.x < -0.1:
        point.co.z += 1.0
ran("KEY_VALUE_HALF")
check("Value 0.5 lifts the left half by 0.5",
      sorted(set(round(c[2], 4) for c in evaluated())) == [0.0, 0.5], sorted(set(c[2] for c in evaluated())))
ran("KEY_VALUE_PAST")
check("a drag to 1.5 under a maximum of 1 is sent as 1, which Blender holds",
      abs(O().data.shape_keys.key_blocks["Key 1"].value - 1.0) < 1e-6
      and blocks["KEY_VALUE_PAST"].rstrip().endswith('"value", 1)'), blocks["KEY_VALUE_PAST"])
ran("KEY_MAX_2")
ran("KEY_VALUE_WIDE")
check("with the range to 2, 1.5 is held and lifts by 1.5",
      abs(O().data.shape_keys.key_blocks["Key 1"].value - 1.5) < 1e-6
      and max(c[2] for c in evaluated()) == 1.5)
ran("KEY_MIN")
check("Range Min -0.5", abs(O().data.shape_keys.key_blocks["Key 1"].slider_min + 0.5) < 1e-6)
ran("KEY_RELATIVE")
check("Key 2 relative to Key 1", O().data.shape_keys.key_blocks["Key 2"].relative_key.name == "Key 1")
refused("KEY_RELATIVE_MISSING", "no shape key called 'Nope'")
# Key 2 is relative to Key 1 now and, new, at value 1 (Blender's default
# for a new key, measured): it would pull Key 1's lift back down. Off, so
# what is counted below is Key 1's alone.
O().data.shape_keys.key_blocks["Key 2"].value = 0.0
check("Left holds nine of the ten lifted vertices",
      sum(1 for i in members("Left") if O().data.vertices[i].co.x < -0.1) == 9, members("Left"))
ran("KEY_VGROUP_LEFT")
k1 = O().data.shape_keys.key_blocks["Key 1"]
check("Key 1 weighted by Left", k1.vertex_group == "Left")
lifted = sum(1 for c in evaluated() if c[2] > 0.01)
check("which lifts only Left's nine (vertex 0 was taken out of it)", lifted == 9,
      (lifted, members("Left"), [c[2] for c in evaluated()], [round(p.co.z, 3) for p in k1.data], k1.value))
ran("KEY_VGROUP_NONE")
check("and None takes the group off: all ten lift",
      O().data.shape_keys.key_blocks["Key 1"].vertex_group == "" and sum(1 for c in evaluated() if c[2] > 0.01) == 10)
ran("KEY_MUTE")
check("Key 2 muted", O().data.shape_keys.key_blocks["Key 2"].mute)
ran("KEY_UNMUTE")
ran("KEY_LOCK")
check("Key 2's shape locked", O().data.shape_keys.key_blocks["Key 2"].lock_shape)

print("\n== undo, in Object Mode ==")
for name in ("KEY_MUTE", "RELATIVE_OFF", "SHOW_ONLY_ON", "ACTIVE_KEY_BASIS", "KEY_VGROUP_LEFT", "ADD_KEY"):
    result = undo_round(name, name)
    check(name + ": one Undo takes it back, Redo brings it again; its step is " + repr(blocks[name + ".undo"]),
          result == (True, True, True) and blocks[name + ".undo"] != "-", result)
# Back to where the session was: what Redo brought back, taken off again.
keys = O().data.shape_keys
keys.key_blocks["Key 2"].mute = False
keys.use_relative = True
O().show_only_shape_key = False
keys.key_blocks["Key 1"].vertex_group = ""
O().active_shape_key_index = len(keys.key_blocks) - 1
bpy.ops.object.shape_key_remove(all=False)
check("and the keys are Basis, Key 1 and Key 2 again",
      [k.name for k in O().data.shape_keys.key_blocks] == ["Basis", "Key 1", "Key 2"])
ran("KEY_RENAME")
check("Key 2 renamed Smile", [k.name for k in O().data.shape_keys.key_blocks] == ["Basis", "Key 1", "Smile"])
ran("RELATIVE_OFF")
check("Relative off", not O().data.shape_keys.use_relative)
ran("RELATIVE_ON")
ran("ACTIVE_KEY_1")
check("Key 1 active", O().active_shape_key_index == 1)
ran("SHOW_ONLY_ON")
check("Shape Key Lock shows Key 1 alone, at full: lifted by 1", O().show_only_shape_key
      and max(c[2] for c in evaluated()) == 1.0)
ran("SHOW_ONLY_OFF")
truth("object mode, three keys")

print("\n== editing a key's shape ==")
bpy.ops.object.mode_set(mode='EDIT')
ed("undo_push", message="Edit Key 1")
check("Edit Mode draws the active key at full, whatever its value (1.5)",
      max(c[2] for c in evaluated()) == 1.0)
select_where(lambda v: v.co.x < -0.1)
# What the gizmo's Move commits (TransformGizmo.python), as the edit-mode drag
# check runs it elsewhere.
bpy.ops.transform.translate(value=(0, 0, 0.25))
bpy.ops.object.mode_set(mode='OBJECT')
blocks_now = O().data.shape_keys.key_blocks
basis_z = sorted(set(round(p.co.z, 4) for p in blocks_now["Basis"].data))
key1_z = sorted(set(round(p.co.z, 4) for p in blocks_now["Key 1"].data))
check("the move changed Key 1 (its lifted half now at 1.25) and left Basis flat",
      basis_z == [0.0] and key1_z == [0.0, 1.25], (basis_z, key1_z))
bpy.ops.object.mode_set(mode='EDIT')
select_where(lambda v: v.co.x < -0.1)
ran("ACTIVE_KEY_BASIS")
check("the active key changed in Edit Mode reloads the edit mesh with Basis",
      max(v.co.z for v in bmesh.from_edit_mesh(O().data).verts) == 0.0)
check("and keeps the selection a tap made (ten)", selected() == 10, selected())
ran("KEY_VALUE_EDIT")
check("a value set in Edit Mode lands", abs(O().data.shape_keys.key_blocks["Key 1"].value - 0.75) < 1e-6)
check("and is sent with no undo step", blocks["KEY_VALUE_EDIT.undo"] == "-")
result = undo_round("Value in Edit Mode", lambda: setattr(O().data.shape_keys.key_blocks["Key 1"], "value", 0.3))
check("measured: Undo in Edit Mode leaves a key's value as set", result is not None and result[1] is False, result)
for name in ("KEY_RENAME_EDIT", "KEY_EDIT_MODE_ON"):
    check(name + " is sent with no undo step in Edit Mode", blocks[name + ".undo"] == "-")
ran("KEY_RENAME_EDIT")
refused("ADD_KEY_MIX", "works in Object Mode")
refused("REMOVE_KEY_SMILE", "works in Object Mode")
truth("edit mode on Basis")
bpy.ops.object.mode_set(mode='OBJECT')

print("\n== New Shape from Mix, remove, Delete All, Apply All ==")
O().data.shape_keys.key_blocks["Key 1"].value = 0.5
mix = evaluated()
ran("ADD_KEY_MIX")
newest = O().data.shape_keys.key_blocks[-1]
check("New Shape from Mix holds the shape as drawn (lifted by 0.5)",
      sorted(set(round(p.co.z, 4) for p in newest.data)) == sorted(set(c[2] for c in mix)))
O().data.shape_keys.key_blocks["Grin"].name = "Smile"
# Smile (Key 2) was locked above; Blender refuses to remove a locked key, in
# its own words, which the banner shows.
refused("REMOVE_KEY_SMILE", "locked shape key")
refused("APPLY_ALL_KEYS", "has locked shape keys")
O().data.shape_keys.key_blocks["Smile"].lock_shape = False
ran("REMOVE_KEY_SMILE")
check("Remove takes Smile", "Smile" not in O().data.shape_keys.key_blocks)
drawn = evaluated()
ran("APPLY_ALL_KEYS")
check("Apply All Shape Keys: no keys, and the mesh is what was drawn",
      O().data.shape_keys is None and evaluated() == drawn)
refused("DELETE_ALL_KEYS", "has no shape keys")
ran("ADD_KEY")
ran("ADD_KEY")
ran("DELETE_ALL_KEYS")
check("Delete All Shape Keys", O().data.shape_keys is None)
truth("no keys")

print("\n== the mirror: the app's own pass ==")
bpy.ops.mesh.primitive_cube_add(location=(4, 0, 0))
cube = bpy.context.active_object
cube.vertex_groups.new(name="CubeGroup").add([0, 1], 1.0, 'REPLACE')
bpy.context.view_layer.objects.active = O()
bridge.calls.clear()
sync_module.sync()
check("the pass hands every mesh's groups and keys over", set(bridge.groups) >= {"Grid", "Cube"})
check("counted for the active object only",
      "count=" in bridge.groups["Grid"] and "count=" not in bridge.groups["Cube"], bridge.groups)
bridge.calls.clear()
bpy.context.view_layer.objects.active = cube
sync_module.sync_selection()
check("a tap that makes the Cube active counts its groups, outside a pass",
      bridge.calls == [("Cube", False)] and "count=2.0" in bridge.groups["Cube"], (bridge.calls, bridge.groups["Cube"]))
bpy.context.view_layer.objects.active = O()

print("\n== the Vertex Group field on every modifier that has one ==")
O().vertex_groups.remove(O().vertex_groups["a;b|c=d%e"])
bpy.ops.object.mode_set(mode='EDIT')
select_where(lambda v: v.co.x < -0.1)
bpy.ops.object.vertex_group_set_active(group="Left")
bpy.ops.object.vertex_group_assign()
bpy.ops.object.mode_set(mode='OBJECT')
for v in O().data.vertices:
    v.co.z = 0.2 * ((v.index * 7919) % 13) / 13.0
lattice = bpy.data.objects.new("Cage", bpy.data.lattices.new("Cage"))
bpy.context.scene.collection.objects.link(lattice)
lattice.scale = (3, 3, 3)
lattice.data.points[0].co_deform.z += 1.0
target = cube
kinds = sorted({name.split(" ", 1)[1] for name in blocks if name.startswith("MOD_ADD ")})
print("  " + ", ".join(kinds))
# What changes each kind's result enough for a group to show (as the probe
# that chose the kinds measured them).
settings = {"SMOOTH": {"factor": 1.0, "iterations": 5}, "CAST": {"factor": 1.0},
            "SIMPLE_DEFORM": {"angle": 1.0}, "DISPLACE": {"strength": 0.5}, "WAVE": {"height": 0.5},
            "LAPLACIANSMOOTH": {"lambda_factor": 2.0, "iterations": 5}, "DECIMATE": {"ratio": 0.3},
            "WELD": {"merge_threshold": 0.6}}
no_effect_here = {"CORRECTIVE_SMOOTH", "WEIGHTED_NORMAL"}   # nothing deformed / normals only
for kind in kinds:
    O().modifiers.clear()
    namespace["bpy"] = bpy
    if not ran("MOD_ADD " + kind, kind + ": Add Modifier"):
        continue
    m = O().modifiers[-1]
    for key, value in settings.get(kind, {}).items():
        setattr(m, key, value)
    if kind == "SHRINKWRAP":
        m.target = target
    if kind == "LATTICE":
        m.object = lattice
    plain = evaluated()
    ran("MOD_GROUP " + kind, kind + ": the row's Vertex Group edit runs")
    check(kind + ": vertex_group is Left", m.vertex_group == "Left", m.vertex_group)
    grouped = evaluated()
    if kind not in no_effect_here:
        check(kind + ": the group changes what it makes", grouped != plain)
    sync_module.sync()
    replays.append({"label": kind + " grouped", "modifier": kind, "record": bridge.modifiers["Grid"],
                    "vertex_group": "Left", "invert": False})
    ran("MOD_INVERT " + kind, kind + ": Invert runs")
    check(kind + ": inverted", m.invert_vertex_group)
    if kind not in no_effect_here:
        check(kind + ": Invert changes it again", evaluated() != grouped)
    sync_module.sync()
    replays.append({"label": kind + " inverted", "modifier": kind, "record": bridge.modifiers["Grid"],
                    "vertex_group": "Left", "invert": True})
    ran("MOD_CLEAR " + kind, kind + ": None runs")
    check(kind + ": cleared, and with Invert left on and no group the mesh is the plain one",
          m.vertex_group == "" and (kind in no_effect_here or evaluated() == plain))
    ran("MOD_STALE " + kind, kind + ": a name that is no group is taken")
    check(kind + ": and Blender clears it, so the row shows None", m.vertex_group == "")
    sync_module.sync()
    replays.append({"label": kind + " stale name", "modifier": kind, "record": bridge.modifiers["Grid"],
                    "vertex_group": "", "invert": True})
check("a kind without the field sends nothing for it", blocks["MOD_SUBSURF_GROUP"].strip() == "")

print("\n== a keyed value, as the playhead moves ==")
O().modifiers.clear()
anim_module = load("_blenderkit_anim")
ran("ADD_KEY")
ran("ADD_KEY")
key1 = O().data.shape_keys.key_blocks["Key 1"]
key1.value = 0.0
key1.keyframe_insert("value", frame=1)
key1.value = 1.0
key1.keyframe_insert("value", frame=11)
bpy.context.scene.frame_set(1)
bridge.calls.clear()
anim_module.frame_set(6)
held = O().data.shape_keys.key_blocks["Key 1"].value
sent = bridge.groups.get("Grid", "")
check("a frame change hands the Data tab the value Blender holds at that frame, uncounted",
      ("Grid", False) in bridge.calls and 0.05 < held < 0.95
      and ("value=" + repr(float(held))) in sent and "count=" not in sent, (held, sent))
replays.append({"label": "keyed value at frame 6", **{k: v for k, v in {
    "record": sent}.items()}, "groups": [g.name for g in O().vertex_groups], "counts": [],
    "locks": [g.lock_weight for g in O().vertex_groups], "active_group": O().vertex_groups.active_index,
    "weight": bpy.context.scene.tool_settings.vertex_group_weight, "active_key": O().active_shape_key_index,
    "use_relative": True, "reference": "Basis", "show_only": False, "key_edit_mode": False,
    "keys": [{"name": k.name, "value": k.value, "min": k.slider_min, "max": k.slider_max,
              "relative": k.relative_key.name, "mute": k.mute, "lock": k.lock_shape,
              "vertex_group": k.vertex_group} for k in O().data.shape_keys.key_blocks]})
ran("DELETE_ALL_KEYS")

print("\n== outside Object and Edit Mode, refused before Blender is asked ==")
bpy.ops.object.mode_set(mode='SCULPT')
check("in Sculpt Mode", O().mode == 'SCULPT')
for name in ("ACTIVE_LEFT", "ADD_GROUP", "ADD_KEY", "KEY_VALUE_HALF", "SHOW_ONLY_ON"):
    refused(name, "in Sculpt Mode")
bpy.ops.object.mode_set(mode='OBJECT')

json.dump(replays, open(OUT, "w"))
print(f"\n  {len(replays)} records written for the Swift")
print("\nALL PASS" if fail == 0 else f"\n{fail} FAILED")
sys.exit(1 if fail else 0)
