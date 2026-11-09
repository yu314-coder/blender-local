"""Properties ▸ Material, run by the Blender it runs on.

scripts/run-material-blender-check.sh starts desktop Blender with
`-b --factory-startup` and a home of its own. Every string run here is the one
the Swift sends (tests/material/blender/main.swift prints them), through the
module the app ships (Resources/python/site/_blenderkit_material.py), with the
context the app has: no area, and an undo stack from `ed.undo_push` under the
startup window and screen, as `_blenderkit_undo` makes one.

What is checked, in the order a session meets it:

  * the module's tables against Blender itself: the Surface menu's shaders
    (every shader node type with a Shader output, by its name, in Blender's
    order), each node's panels, the inputs they hold, the settings drawn
    above them, and the soft ranges' sockets;
  * the slot list: + (an empty slot, made active), the active slot, -, the
    move arrows (and a move past the end, refused in words), Material
    Specials' five rows, and in Edit Mode Assign, Select and Deselect on
    faces — each landing where Blender keeps it;
  * the datablock: New on an empty slot (Blender's default node tree,
    "Material.001", one user) and on a full one (a copy), browse, Unlink
    (the material kept), the user count tapped (a single-user copy), Fake
    User, a name with quotes and Unicode, the slot's Link;
  * Surface: every shader of the menu linked in Blender's way — at the old
    node's place, matching inputs carried, the old node and what fed only it
    removed — Disconnect and Remove; a textured material's Image Texture
    shown on Base Color and kept by a Principled BSDF;
  * every input of the Principled BSDF the tab shows, as the tab sends it
    (built by the Swift from Blender's own state): colours picked in sRGB
    landing linear, numbers clamped to the slider's range, vectors, the
    switch, and the node's settings;
  * Settings and Viewport Display;
  * Undo: one Undo takes back each change in Object Mode; in Edit Mode the
    changes the Swift sends with no step stay after Undo in Blender too;
  * the mirror: `_blenderkit_sync.sync()` hands `sync_materials` each slot's
    look and each triangle's slot, and the Swift (main.swift replay) reads
    the tab's states and the looks back exactly as Blender held them.
"""
import bpy, bmesh, sys, os, json, types, pathlib, importlib.util, contextlib, io, subprocess, re

sys.dont_write_bytecode = True
CALLS, OUT, DUMP, WORK = sys.argv[sys.argv.index("--") + 1:][:4]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


def parse_blocks(text):
    found = {}
    for chunk in text.split("#--"):
        chunk = chunk.strip()
        if chunk:
            head, _, body = chunk.partition("\n")
            found[head[4:].strip()] = body
    return found


blocks = parse_blocks(open(CALLS).read())


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`, keeping what the mirror hands
    the 3D View."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.materials = {}

    def sync_begin(self):
        self.materials = {}

    def sync_push(self, *args):
        pass

    def sync_end(self):
        pass

    def sync_materials(self, name, record, slots):
        import array
        values = array.array('i')
        values.frombytes(slots)
        self.materials[name] = (record, list(values))

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


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


sys.path.insert(0, str(SITE))
mat = load("_blenderkit_material")
sync_module = load("_blenderkit_sync")

window = bpy.context.window_manager.windows[0]


def ed(name, **kw):
    with bpy.context.temp_override(window=window, screen=window.screen):
        return getattr(bpy.ops.ed, name)(**kw)


namespace = {"bpy": bpy}


def run(name, source=None):
    """One block as the bridge runs it; the sentence it raised, or None."""
    code = blocks[name] if source is None else source
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            exec(compile(code, "<" + name + ">", "exec"), namespace)
    except RuntimeError as error:
        return str(error)
    namespace["_last_out"] = out.getvalue()
    return None


def ran(name, label=None):
    error = run(name)
    check(label or (name + " runs"), error is None, error)
    return error is None


def refused(name, words):
    error = run(name)
    check(name + " is refused in words: " + repr(words), error is not None and words in error, error)


def C():
    return bpy.data.objects["Cube"]


def M(name="Material"):
    return bpy.data.materials.get(name)


def slots(obj=None):
    obj = obj or C()
    return [s.material.name if s.material else None for s in obj.material_slots]


def state_text(block="STATE"):
    run(block)
    return namespace.get("_last_out", "").strip().splitlines()[-1]


states = []


def record_state(label, expect, block="STATE"):
    states.append({"label": label, "json": state_text(block), "expect": expect})


def face_slots():
    obj = C()
    if obj.mode == 'EDIT':
        obj.update_from_editmode()
    return [p.material_index for p in obj.data.polygons]


def snapshot():
    """What the tab's commands can change, as one comparable value: the
    Cube's slots, its faces' slots, and the material called Material (the
    one the blocks edit), whichever slot holds it."""
    obj = C()
    if obj.mode == 'EDIT':
        obj.update_from_editmode()
    m = M("Material")
    tree = []
    if m is not None and m.node_tree is not None:
        for n in m.node_tree.nodes:
            values = []
            for s in n.inputs:
                v = getattr(s, 'default_value', None)
                if v is not None and not isinstance(v, (str, bool, int, float)):
                    v = tuple(round(x, 4) for x in v)
                elif isinstance(v, float):
                    v = round(v, 4)
                values.append(v)
            tree.append((n.bl_idname, tuple(values)))
    settings = tuple(getattr(m, k) if not hasattr(getattr(m, k), '__len__') or isinstance(getattr(m, k), str)
                     else tuple(round(x, 4) for x in getattr(m, k))
                     for k in mat.SETTINGS + ('diffuse_color', 'metallic', 'roughness', 'use_fake_user')) if m else ()
    return (tuple(slots()), obj.active_material_index, tuple(face_slots()), tuple(sorted(tree)), settings,
            tuple(s.link for s in obj.material_slots), len(bpy.data.materials),
            tuple(p.select for p in obj.data.polygons))


def undo_round(label, change):
    """`change` (a block name), one undo step under its own name, then Undo:
    whether it changed anything, whether Undo took it back, whether Redo
    put it back."""
    ed("undo_push", message="before " + label)
    before = snapshot()
    error = run(change)
    if error:
        check(label + ": runs", False, error)
        return None
    after = snapshot()
    ed("undo_push", message=label)
    ed("undo")
    undone = snapshot()
    ed("redo")
    redone = snapshot()
    if undone != before:
        names = ("slots", "active", "faces", "nodes", "settings", "links", "materials", "selection")
        print("        %s: after Undo %s differ from before it" % (
            label, [n for n, a, b in zip(names, undone, before) if a != b]))
    return before != after, undone == before, redone == after


def undo_label(name):
    return blocks[name + ".undo"].strip()


# --------------------------------------------------------------------------
print("== the module's tables, held to Blender ==")
probe = bpy.data.materials.new("probe")
tree = probe.node_tree
found = []
nodes = {}
for name in dir(bpy.types):
    cls = getattr(bpy.types, name)
    try:
        if not issubclass(cls, bpy.types.ShaderNode) or cls is bpy.types.ShaderNode:
            continue
    except TypeError:
        continue
    if name in ('ShaderNodeGroup', 'ShaderNodeCustomGroup'):
        continue
    try:
        node = tree.nodes.new(name)
    except RuntimeError:
        continue
    if any(o.type == 'SHADER' for o in node.outputs):
        found.append((node.bl_rna.name, node.bl_idname))
        nodes[node.bl_idname] = node
    else:
        tree.nodes.remove(node)


def natural(s):
    return [int(p) if p.isdigit() else p.casefold() for p in re.split(r'(\d+)', s)]


found.sort(key=lambda f: natural(f[0]))
check("the Surface menu's %d shaders: every shader node type with a Shader output, by its name, sorted as "
      "Blender sorts them" % len(found), [(t, n) for n, t in found] == list(mat.SHADERS),
      sorted(set((t, n) for n, t in found) ^ set(mat.SHADERS)))
swift_shaders = [tuple(line.split("|")) for line in blocks["SHADERS"].splitlines()]
check("the Swift's list is the module's", swift_shaders == list(mat.SHADERS))
for idname, panels in mat.PANELS.items():
    node = nodes[idname]
    ids = {s.identifier for s in node.inputs}
    check("%s: %d panels, as Blender's node has" % (idname, len(panels)), len(node.panel_states) == len(panels),
          len(node.panel_states))
    missing = [sid for _, _, sids in panels for sid in sids if sid not in ids]
    layouts = [p for _, p, _ in panels if p is not None and node.bl_rna.properties.get(p) is None]
    check("%s: every socket its panels hold is one of its inputs, every panel setting one of its properties"
          % idname, not missing and not layouts, (missing, layouts))
for idname, nodes_panels in [(k, v) for k, v in nodes.items() if k not in mat.PANELS]:
    if len(nodes_panels.panel_states):
        check("%s has panels, and the module lists them" % idname, False, len(nodes_panels.panel_states))
for idname, labels in mat.SHORT_LABELS.items():
    ids = {s.identifier for s in nodes[idname].inputs}
    check("%s: the short labels name its sockets" % idname, set(labels) <= ids, set(labels) - ids)
for idname, props in mat.NODE_BUTTONS.items():
    bad = [p for p in props if getattr(nodes[idname].bl_rna.properties.get(p), 'type', None) != 'ENUM']
    check("%s: its buttons %s are enum settings" % (idname, props), not bad, bad)
for idname, ranges in mat.SOFT_RANGES.items():
    ids = {s.identifier for s in nodes[idname].inputs}
    check("%s: the soft ranges name its sockets" % idname, set(ranges) <= ids, set(ranges) - ids)
for idname in mat.SETTINGS:
    check("Material.%s is a property of 5.2.1's materials" % idname, probe.bl_rna.properties.get(idname) is not None)
for line in blocks["SPECIALS"].splitlines():
    row, call = line.split("|")
    op = call.replace("bpy.ops.", "").replace("()", "")
    module_name, op_name = op.split(".")
    check("Material Specials' %s runs %s, whose name it is" % (row, op),
          getattr(getattr(bpy.ops, module_name), op_name).get_rna_type().name == row)
props_menu = [l.split("|") for l in blocks.get("SETTING_displacement_method.label", "").splitlines()[1:2]]
for key in [k for k in blocks if k.startswith("SETTING_") and k.endswith(".label")]:
    identifier = key[len("SETTING_"):-len(".label")]
    lines = blocks[key].splitlines()
    rna = probe.bl_rna.properties[identifier]
    if len(lines) > 1:
        options = [tuple(o.split("|")) for o in lines[1].split(",")]
        check("%s's items are Blender's: %s" % (identifier, [n for _, n in options]),
              options == [(i.identifier, i.name) for i in rna.enum_items])
tree.nodes.clear()
bpy.data.materials.remove(probe)
nodes = {}

# --------------------------------------------------------------------------
print("\n== the scene and the app's context ==")
bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
sphere = bpy.context.active_object
sphere.name = "Sphere"
bpy.ops.object.select_all(action='DESELECT')
bpy.context.view_layer.objects.active = C()
C().select_set(True)
check("the startup Cube with its Material, and a Sphere with none",
      slots() == ["Material"] and slots(bpy.data.objects["Sphere"]) == [])
check("an undo stack, as _blenderkit_undo makes one", 'FINISHED' in ed("undo_push", message="start"))
record_state("the startup cube", {"slots": ["Material"], "active": 0, "material": "Material", "users": 1,
                                  "surface": "Principled BSDF", "listed": ["Material"],
                                  "panels": ["Diffuse", "Subsurface", "Specular", "Transmission", "Coat",
                                             "Sheen", "Emission", "Thin Film"],
                                  "labels": {"Subsurface Weight": "Weight", "Specular IOR Level": "IOR Level",
                                             "Coat Tint": "Tint", "Emission Strength": "Strength",
                                             "Thin Film Thickness": "Thickness", "Diffuse Roughness": "Roughness",
                                             "Base Color": "Base Color", "Anisotropic Rotation": "Anisotropic Rotation"},
                                  "inputs": [s.identifier for s in M().node_tree.nodes["Principled BSDF"].inputs
                                             if s.enabled]})
parsed = json.loads(state_text())
check("the state is one JSON line Blender printed", parsed["object"] == "Cube" and parsed["mode"] == "OBJECT")
check("the startup cube's swatch is its Base Color in sRGB (0.8 linear is 0.906)",
      abs(parsed["slots"][0]["swatch"][0] - 0.9063) < 1e-3, parsed["slots"][0]["swatch"])

# --------------------------------------------------------------------------
print("\n== the slot list ==")
check("+ is Blender's Add Material Slot", undo_label("ADD_SLOT") == "Add Material Slot")
ran("ADD_SLOT")
check("+ adds an empty slot and makes it active", slots() == ["Material", None] and C().active_material_index == 1)
record_state("an empty slot added", {"slots": ["Material", None], "active": 1, "material": None})
ran("ACTIVE_0")
check("a tap on the first row makes it active", C().active_material_index == 0)
refused("ACTIVE_9", "has no material slot 10")
ran("ACTIVE_1")
check("New's step is Blender's New Material", undo_label("NEW") == "New Material")
ran("NEW")
check("New on an empty slot: Material.001, Blender's default node tree, one user",
      slots() == ["Material", "Material.001"] and M("Material.001").users == 1
      and sorted(n.bl_idname for n in M("Material.001").node_tree.nodes)
      == ["ShaderNodeBsdfPrincipled", "ShaderNodeOutputMaterial"]
      and M("Material.001").node_tree.nodes["Principled BSDF"].outputs[0].links[0].to_socket.name == "Surface",
      (slots(), M("Material.001") and M("Material.001").users))
ran("NEW")
check("New on a full slot copies its material (Material.002), as Blender's duplicate button does",
      slots() == ["Material", "Material.002"] and M("Material.001").users == 0 and M("Material.002").users == 1)
ran("MOVE_UP")
check("the up arrow moves the active slot up, and it stays active",
      slots() == ["Material.002", "Material"] and C().active_material_index == 0)
error = run("MOVE_UP")
check("a move past the top is refused in words, not done silently", error is not None and "first" in error, error)
ran("MOVE_DOWN")
check("the down arrow moves it back", slots() == ["Material", "Material.002"] and C().active_material_index == 1)
check("-'s step is Blender's Remove Material Slot", undo_label("REMOVE_SLOT") == "Remove Material Slot")
ran("REMOVE_SLOT")
check("- removes the active slot, the material stays in the file",
      slots() == ["Material"] and M("Material.002") is not None)

# --------------------------------------------------------------------------
print("\n== the datablock ==")
ran("ADD_SLOT")
ran("BROWSE_MATERIAL")
check("browse puts the chosen material in the active slot", slots() == ["Material", "Material"])
check("browse's step is the browse button's words", undo_label("BROWSE_MATERIAL") == "Browse Material to be linked")
record_state("Material in both slots of one object", {"slots": ["Material", "Material"], "material": "Material",
                                                      "users": 2})
ran("ACTIVE_0")
bpy.context.view_layer.objects.active = bpy.data.objects["Sphere"]
ran("NEW_SPHERE", "New on the Sphere, which has no slot")
bpy.context.view_layer.objects.active = C()
made = slots(bpy.data.objects["Sphere"])
check("New on an object with no slot adds the slot first, as Blender's New does: a new material, "
      "Blender's default tree", len(made) == 1 and made[0] not in (None, "Material")
      and len(M(made[0]).node_tree.nodes) == 2 and M(made[0]).users == 1, made)
check("Material in two slots of one object has two users, as Blender counts them", M("Material").users == 2)
bpy.data.objects["Sphere"].material_slots[0].material = M("Material")
check("the Sphere shares Material: three users", M("Material").users == 3)
record_state("Material shared by two objects", {"material": "Material", "users": 3})
check("the user count's step is Blender's Make Single User", undo_label("SINGLE_USER") == "Make Single User")
ran("SINGLE_USER")
check("the user count, tapped: the Cube's slot gets a copy and the Sphere keeps Material",
      slots()[0] not in (None, "Material") and slots()[0].startswith("Material.")
      and slots(bpy.data.objects["Sphere"]) == ["Material"] and M(slots()[0]).users == 1,
      (slots(), slots(bpy.data.objects["Sphere"])))
error = run("SINGLE_USER")
check("Make Single User on a material of one user is refused in words (Blender shows no count to tap)",
      error is not None and "one user" in error, error)
ran("BROWSE_MATERIAL")
ran("FAKE_ON")
check("Fake User on", M("Material").use_fake_user and M("Material").users == 4)
record_state("Fake User: Blender's count leaves the fake user out", {"material": "Material", "users": 3})
ran("FAKE_OFF")
check("Fake User off", not M("Material").use_fake_user)
ran("RENAME_ODD")
check("a name with quotes, Unicode and the record's separators", M("Q \"uoted\" 名前;|=%") is not None)
ran("BROWSE_ODD")
check("and browsed by it", slots()[0] == "Q \"uoted\" 名前;|=%")
ran("RENAME_BACK")
refused("RENAME_EMPTY", "needs a name")
refused("BROWSE_MISSING", "no material called 'Nope'")
check("Unlink's step is Blender's Unlink Data-Block", undo_label("UNLINK") == "Unlink Data-Block")
ran("UNLINK")
check("Unlink empties the slot and keeps the material", C().material_slots[0].material is None
      and M("Material") is not None and slots(bpy.data.objects["Sphere"]) == ["Material"])
ran("BROWSE_MATERIAL")
ran("LINK_OBJECT")
check("Link ▸ Object: the slot links to the object, and the object's own material is empty",
      C().material_slots[0].link == 'OBJECT' and C().material_slots[0].material is None)
ran("BROWSE_MATERIAL")
check("browsing into an Object slot sets the object's material", C().material_slots[0].material == M("Material")
      and C().material_slots[0].link == 'OBJECT')
ran("LINK_DATA")
check("Link ▸ Data: the mesh's material again", C().material_slots[0].link == 'DATA')
C().data.materials[0] = M("Material")

# --------------------------------------------------------------------------
print("\n== Material Specials ==")
check("Copy Material makes no step: it changes nothing in the file", undo_label("COPY_MATERIAL") == "-")
ran("COPY_MATERIAL")
M().node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value = 0.0
ran("ACTIVE_1")
C().material_slots[1].material = M("Material.002")
M("Material.002").node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value = 0.9
ran("PASTE_MATERIAL")
check("Paste Material: the copied settings in the active material, its name kept",
      slots()[1] == "Material.002"
      and abs(M("Material.002").node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value) < 1e-6)
bpy.data.objects["Sphere"].select_set(True)
ran("COPY_MATERIAL_TO_SELECTED")
check("Copy Material to Selected: the Sphere takes the Cube's slots",
      slots(bpy.data.objects["Sphere"]) == slots())
bpy.data.objects["Sphere"].select_set(False)
ran("ADD_SLOT")
ran("REMOVE_UNUSED_SLOTS")
check("Remove Unused Slots: the slots no face uses go", slots() == ["Material"], slots())

# --------------------------------------------------------------------------
print("\n== Edit Mode: Assign, Select, Deselect ==")
ran("ADD_SLOT")
ran("ACTIVE_1")
ran("BROWSE_MATERIAL")
ran("NEW")
red = M(slots()[1])
red.diffuse_color = (0.8, 0.05, 0.05, 1.0)
red.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.8, 0.05, 0.05, 1.0)
red_name = red.name
bpy.ops.object.mode_set(mode='EDIT')
ed("undo_push", message="Toggle Edit Mode")
bm = bmesh.from_edit_mesh(C().data)
for f in bm.faces:
    f.select_set(False)
bm.faces.ensure_lookup_table()
bm.faces[0].select_set(True)
bm.faces[1].select_set(True)
bmesh.update_edit_mesh(C().data)
refused("REMOVE_SLOT", "Unable to remove material slot in edit mode")
refused("REMOVE_UNUSED_SLOTS_EDIT", "Unable to remove material slot in edit mode")
check("Assign's step is Blender's Assign Material Slot", undo_label("ASSIGN") == "Assign Material Slot")
ran("ASSIGN")
check("Assign: the two selected faces take slot 2", face_slots() == [1, 1, 0, 0, 0, 0], face_slots())
bpy.ops.mesh.select_all(action='DESELECT')
ran("SELECT")
C().update_from_editmode()
check("Select: the faces using the active slot", [p.select for p in C().data.polygons] == [True, True] + [False] * 4)
ran("DESELECT")
C().update_from_editmode()
check("Deselect: none of them", not any(p.select for p in C().data.polygons))
bpy.ops.mesh.select_all(action='DESELECT')
error = run("ASSIGN")
check("Assign with no face selected is refused in words (Blender says nothing)",
      error is not None and "no face is selected" in error, error)

print("\n== the mirror, in Edit Mode and out ==")
sync_module.sync()
record, tri = bridge.materials.get("Cube", ("", []))
check("sync() hands sync_materials the Cube's two slots", record.count("kind=slot") == 2, record)
check("and a slot per triangle: 4 of the 12 in slot 2", len(tri) == 12 and tri.count(1) == 4, tri)
bpy.ops.object.mode_set(mode='OBJECT')
ed("undo_push", message="Toggle Object Mode")
sync_module.sync()
record, tri = bridge.materials["Cube"]
records = [{"label": "a cube of two materials", "record": record, "slots": tri, "triangles": len(tri),
            "runs": {"0": 8, "1": 4},
            "expect": [{"name": "Material", "display": list(M("Material").diffuse_color),
                        "base": list(M("Material").node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value)[:3],
                        "metallic": 0.0, "roughness": 0.5, "connected": True},
                       {"name": red_name, "display": [0.8, 0.05, 0.05, 1.0], "base": [0.8, 0.05, 0.05],
                        "connected": True}]}]
record_state("two slots, the second active", {"slots": ["Material", red_name], "active": 1, "material": red_name})
bridge.materials.clear()
sync_module.sync()
check("an object with no slot is sent with none: the Camera is not a mesh, and nothing is sent for it",
      "Camera" not in bridge.materials)
sphere = bpy.data.objects["Sphere"]
sphere.data.materials.clear()
sync_module.sync()
check("a mesh with no slot is sent an empty record", bridge.materials.get("Sphere") == ("", []),
      bridge.materials.get("Sphere"))

# --------------------------------------------------------------------------
print("\n== Surface ==")
ran("ACTIVE_0")
check("the menu's step is Blender's Node input modify", undo_label("SHADER_DIFFUSE_BSDF") == "Node input modify")
principled = M().node_tree.nodes["Principled BSDF"]
principled.inputs["Base Color"].default_value = (0.2, 0.4, 0.6, 1.0)
principled.inputs["Roughness"].default_value = 0.25
where = tuple(principled.location)
ran("SHADER_DIFFUSE_BSDF")
surface = mat.surface_node(M())
check("Diffuse BSDF linked into Surface, at the Principled BSDF's place",
      surface.bl_idname == "ShaderNodeBsdfDiffuse" and tuple(surface.location) == where)
check("its Roughness carried (the same identifier and type), its Color not (Base Color is another)",
      abs(surface.inputs["Roughness"].default_value - 0.25) < 1e-6
      and tuple(surface.inputs["Color"].default_value)[:3] != (0.2, 0.4, 0.6))
check("the Principled BSDF removed", "Principled BSDF" not in M().node_tree.nodes)
for idname, name in mat.SHADERS:
    key = "SHADER_" + name.upper().replace(" ", "_")
    error = run(key)
    node = mat.surface_node(M())
    check("Surface ▸ %s" % name, error is None and node is not None and node.bl_idname == idname
          and len([n for n in M().node_tree.nodes if n.type != 'OUTPUT_MATERIAL']) == 1, error)
refused("SHADER_NOT_ONE", "is not a shader")
ran("SHADER_PRINCIPLED_BSDF")
ran("SHADER_PRINCIPLED_BSDF", "the same shader again")
check("the same shader again keeps its node", mat.surface_node(M()).name == "Principled BSDF"
      or mat.surface_node(M()).bl_idname == "ShaderNodeBsdfPrincipled")
ran("DISCONNECT")
check("Disconnect: the link goes, the node stays", mat.surface_node(M()) is None
      and any(n.bl_idname == "ShaderNodeBsdfPrincipled" for n in M().node_tree.nodes))
record_state("nothing connected to Surface", {"material": "Material", "surface": None})
looks = mat.look(M())
check("a material with nothing connected is drawn black: its look says so", "connected=0" in looks, looks)
for n in [n for n in M().node_tree.nodes if n.type != 'OUTPUT_MATERIAL']:
    M().node_tree.nodes.remove(n)
ran("SHADER_PRINCIPLED_BSDF", "Surface ▸ Principled BSDF with nothing there")
check("a new Principled BSDF left of the output, linked", mat.surface_node(M()) is not None)
ran("VOLUME_PRINCIPLED")
out = mat.output_node(M())
check("Volume ▸ Principled Volume, linked into the output's Volume",
      out.inputs["Volume"].is_linked and out.inputs["Volume"].links[0].from_node.bl_idname == "ShaderNodeVolumePrincipled")
ran("REMOVE")
check("Remove: the surface's node goes", mat.surface_node(M()) is None
      and not any(n.bl_idname == "ShaderNodeBsdfPrincipled" for n in M().node_tree.nodes))
ran("SHADER_PRINCIPLED_BSDF")

print("\n== a textured material, as Image to 3D Model makes one ==")
image = bpy.data.images.new("Tex", 4, 4)
textured = M()
texture = textured.node_tree.nodes.new("ShaderNodeTexImage")
texture.image = image
textured.node_tree.links.new(texture.outputs["Color"], mat.surface_node(textured).inputs["Base Color"])
record_state("Base Color from an Image Texture", {"material": "Material", "surface": "Principled BSDF",
                                                   "linked_input": ["Base Color", "Image Texture"]})
check("its look says the base colour is linked", "base_linked=1" in mat.look(textured))
ran("SHADER_PRINCIPLED_BSDF", "Principled BSDF again over the textured one")
check("the same shader again keeps the Image Texture on Base Color",
      mat.surface_node(textured).inputs["Base Color"].is_linked)
ran("SHADER_DIFFUSE_BSDF", "Diffuse BSDF over it")
check("Diffuse BSDF has no Base Color, so the Image Texture went with the Principled BSDF, as in Blender",
      not any(n.bl_idname == "ShaderNodeTexImage" for n in textured.node_tree.nodes))
ran("SHADER_PRINCIPLED_BSDF")

# --------------------------------------------------------------------------
print("\n== every input of the Principled BSDF, as the tab sends it ==")
path = os.path.join(WORK, "state.json")
with open(path, "w") as handle:
    handle.write(state_text())


def input_blocks(edit=False):
    made = subprocess.run([DUMP, "inputs", path] + (["edit"] if edit else []), capture_output=True, text=True)
    return parse_blocks(made.stdout)


inputs = input_blocks()
blocks.update(inputs)
count = 0
for key in sorted(k for k in inputs if k.startswith("INPUT_") and "." not in k):
    index, identifier, kind, expect, label = inputs[key + ".expect"].split("|")
    error = run(key)
    socket = mat.surface_node(M()).inputs[int(index)]
    held = socket.default_value
    if kind == "RGBA":
        wanted = [float(x) for x in expect.split(",")]
        ok = all(abs(a - b) < 1e-5 for a, b in zip(tuple(held)[:3], wanted)) and abs(held[3] - 1.0) < 1e-6
    elif kind == "VECTOR":
        wanted = [float(x) for x in expect.split(",")]
        ok = all(abs(a - b) < 1e-5 for a, b in zip(tuple(held), wanted))
    elif kind == "BOOLEAN":
        ok = str(bool(held)) == expect
    else:
        ok = abs(float(held) - float(expect)) < 1e-5
    check("%s (%s, inputs[%s]) holds %s, the step named %r" % (identifier, kind, index, expect,
                                                                inputs[key + ".undo"].strip()),
          error is None and ok and inputs[key + ".undo"].strip() == label, (error, held))
    count += 1
check("the tab sends a value for every input it shows a value for (%d)" % count, count >= 25, count)
for key in sorted(k for k in inputs if k.startswith("PROP_") and "." not in k):
    identifier, value, label = inputs[key + ".expect"].split("|")
    error = run(key)
    check("the node's %s set to %s" % (label, value),
          error is None and getattr(mat.surface_node(M()), identifier) == value, error)
blue_base = tuple(mat.surface_node(M()).inputs["Base Color"].default_value)[:3]
check("sRGB (0.5, 0.25, 0.75) is Blender's (0.214, 0.0508, 0.522) linear",
      abs(blue_base[0] - 0.2140) < 1e-3 and abs(blue_base[1] - 0.0508) < 1e-3 and abs(blue_base[2] - 0.5225) < 1e-3,
      blue_base)
error = run("INPUT_0", inputs["INPUT_0"].replace("'Principled BSDF'", "'Nope'").replace('"Principled BSDF"', '"Nope"'))
check("an input of a node that is not there is refused in words", error is not None and "no node" in error, error)

# --------------------------------------------------------------------------
print("\n== Settings and Viewport Display ==")
for key in sorted(k for k in blocks if k.startswith("SETTING_") and "." not in k and k != "SETTING_EDIT"):
    identifier = key[len("SETTING_"):]
    before = getattr(M(), identifier)
    error = run(key)
    after = getattr(M(), identifier)
    label = blocks[key + ".label"].splitlines()[0]
    check("Settings ▸ %s (%s): %r → %r, the step named %s" % (label, identifier, before, after, undo_label(key)),
          error is None and after != before and undo_label(key) == label, error)
check("Pass Index typed 7.4 is 7", M().pass_index == 7)
ran("PASS_INDEX_PAST")
check("Pass Index past its range is its top, 32767", M().pass_index == 32767)
record_state("the Settings as set", {"settings": {"use_backface_culling": True, "surface_render_method": "BLENDED",
                                                  "thickness_mode": "SLAB", "displacement_method": "BOTH"}})
ran("VIEWPORT_COLOR")
held = tuple(M().diffuse_color)
check("Viewport Display ▸ Color: sRGB (0.5, 0.25, 0.75) at 0.5 is held linear, alpha as picked",
      abs(held[0] - 0.2140) < 1e-3 and abs(held[2] - 0.5225) < 1e-3 and abs(held[3] - 0.5) < 1e-6, held)
ran("VIEWPORT_METALLIC")
ran("VIEWPORT_ROUGHNESS")
check("Metallic 0.3, Roughness 1.7 held as 1 (0 to 1)", abs(M().metallic - 0.3) < 1e-6 and M().roughness == 1.0)
sync_module.sync()
record, tri = bridge.materials["Cube"]
records.append({"label": "the material's Viewport Display and its Principled BSDF", "record": record,
                "slots": tri, "triangles": len(tri), "runs": {"0": 8, "1": 4},
                "expect": [{"name": "Material", "display": list(M().diffuse_color),
                            "base": list(blue_base), "connected": True}, {"name": red_name}]})

# --------------------------------------------------------------------------
print("\n== Undo ==")
bpy.ops.object.mode_set(mode='OBJECT')
# Back to the defaults the blocks below change from.
M().use_backface_culling = False
M().diffuse_color = (0.8, 0.8, 0.8, 1.0)
M().use_fake_user = False
ed("undo_push", message="Toggle Object Mode")
for name in ("ADD_SLOT", "ACTIVE_0", "NEW", "BROWSE_MATERIAL", "UNLINK", "LINK_OBJECT", "LINK_DATA",
             "SHADER_EMISSION", "SHADER_PRINCIPLED_BSDF", "SETTING_use_backface_culling", "VIEWPORT_COLOR",
             "FAKE_ON", "FAKE_OFF", "REMOVE_SLOT"):
    if name == "UNLINK" and C().active_material is None:
        run("BROWSE_MATERIAL")
    result = undo_round(name, name)
    check("Object Mode, %s: one Undo takes it back and Redo puts it back (%s)" % (name, undo_label(name)),
          result is not None and all(result), result)
bpy.ops.object.mode_set(mode='EDIT')
ed("undo_push", message="Toggle Edit Mode")
C().active_material_index = 1
C().material_slots[0].material = M("Other") or bpy.data.materials.new("Other")
ed("undo_push", message="Other in slot 1")
for name in ("ADD_SLOT_EDIT", "NEW_EDIT", "SETTING_EDIT", "VIEWPORT_EDIT", "ACTIVE_0_EDIT", "BROWSE_EDIT",
             "UNLINK_EDIT"):
    if name == "BROWSE_EDIT":
        C().active_material_index = 0
        ed("undo_push", message="slot 1")
    if name == "UNLINK_EDIT" and C().active_material is None:
        C().active_material = M("Material")
        ed("undo_push", message="Material in the slot")
    check("Edit Mode, %s: the Swift sends no step" % name, undo_label(name) == "-")
    result = undo_round(name, name)
    check("Edit Mode, %s: Blender's Undo does not take it back, which is why no step is sent" % name,
          result is not None and result[0] and not result[1], result)
edit_inputs = input_blocks(edit=True)
blocks.update({"EDIT_" + k: v for k, v in edit_inputs.items()})
check("Edit Mode: every input's command carries no step",
      all(edit_inputs[k].strip() == "-" for k in edit_inputs if k.endswith(".undo")))
result = undo_round("Metallic in Edit Mode", "EDIT_INPUT_1")
check("Edit Mode, an input's value: Blender's Undo leaves it changed", result is not None and result[0]
      and not result[1], result)
bm = bmesh.from_edit_mesh(C().data)
bm.faces.ensure_lookup_table()
for f in bm.faces:
    f.select_set(False)
bm.faces[2].select_set(True)
bmesh.update_edit_mesh(C().data)
C().active_material_index = (face_slots()[2] + 1) % len(C().material_slots)
ed("undo_push", message="select")
for name in ("ASSIGN", "SELECT", "DESELECT"):
    if name == "SELECT":
        bpy.ops.mesh.select_all(action='DESELECT')
        ed("undo_push", message="none")
    result = undo_round(name, name)
    check("Edit Mode, %s: one Undo takes it back (%s)" % (name, undo_label(name)),
          result is not None and result[0] and result[1], result)
bpy.ops.object.mode_set(mode='OBJECT')

json.dump({"states": states, "records": records}, open(OUT, "w"))
print("\n" + ("ALL PASS" if fail == 0 else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
