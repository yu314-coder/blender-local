"""Round 4, group 7, run by the Blender it runs on: the Outliner's collections,
Object ▸ Collection, the Object Constraints tab, the Object menu's Mirror,
Link/Transfer Data, Make Single User, Copy Modifiers to Selected Objects,
Randomize Transform and Align Objects rows, and Local View.

scripts/run-relations-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: a window and a screen but no 3D View area in the
context, as for the bpy module on a device. The app's context is built the
way the app builds it: Blender's undo started through the app's own
`_blenderkit_undo.push`, `gpu.init()`, and the startup screen's 3D View
borrowed by `_blenderkit_context.temp_override_view3d` where the app borrows
it, all loaded from the source tree. Every string run is the one the Swift
sends (tests/relations/blender/main.swift). After the steps that change what
the Outliner, the Constraints tab or the viewport shows, the app's own
`_blenderkit_sync.sync()` runs against a `_blenderkit` that records what it
is handed, and the Swift replays that against what Blender holds.

Each check that can be held to Blender's own operator is: the Swift's call
against the operator Blender's menu row calls, on the same fixture. Each
refusal leaves the scene as it was. The controls that have to fail are run
too.
"""
import bpy, bmesh, gpu, sys, types, json, math, base64, pathlib, importlib.util, contextlib, io, os

sys.dont_write_bytecode = True
CALLS, PASSES, WORK = sys.argv[sys.argv.index("--") + 1:][:3]
ROOT = pathlib.Path(__file__).resolve().parents[3]
HISTORY = os.path.join(WORK, "Documents", ".blender-history")
fail = 0
measured = {}


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


def b64(data):
    return base64.b64encode(bytes(data)).decode()


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps every call a pass makes."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.calls = []
        self.frames = []

    def is_main_thread(self):
        return True

    def sync_begin(self):
        self.calls = []

    def sync_push(self, name, kind, matrix, positions, normals, triangles, selected, active, rgba):
        self.calls.append(dict(call="push", name=name, kind=kind, matrix=b64(matrix),
                               positions=b64(positions), normals=b64(normals),
                               triangles=b64(triangles), selected=selected, active=active))

    def sync_relations(self, name, parent, names):
        self.calls.append(dict(call="relations", name=name, parent=parent, names=list(names)))

    def sync_record(self, kind, name, record):
        self.calls.append(dict(call="record", kind=kind, name=name, record=record))

    def sync_display(self, name, type, data, record):
        self.calls.append(dict(call="display", name=name, type=type, data=data, record=record))

    def sync_channels(self, name, values):
        import array
        decoded = array.array('d')
        decoded.frombytes(bytes(values))
        self.calls.append(dict(call="channels", name=name, values=list(decoded)))

    def anim_frame(self, frame, subframe, names, matrices):
        import array
        values = array.array('d')
        values.frombytes(matrices)
        self.frames.append(dict(zip(names.decode().split('\0'),
                                    [list(values[i * 16:(i + 1) * 16]) for i in range(len(values) // 16)])))

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *a, **k: None


bridge = Bridge()
sys.modules["_blenderkit"] = bridge


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "Resources/python/site" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


context = load("_blenderkit_context")
context.install(bpy)
for sibling in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(sibling)
sync = load("_blenderkit_sync")
undo = load("_blenderkit_undo")
collections = load("_blenderkit_collections")
constraints = load("_blenderkit_constraints")
localview = load("_blenderkit_localview")
# A lattice is pushed through `_push_lattice` only when the points module is
# there, as on the device.
points = load("_blenderkit_points")
# The Select menu's object rows guard themselves with it, as on the device.
load("_blenderkit_select")
gpu.init()

namespace = {"bpy": bpy}


def run(block, **fill):
    """A block of what the Swift sends, in one namespace as the app's
    interpreter keeps: (error text or None, what it printed)."""
    source = blocks[block]
    for key, value in fill.items():
        source = source.replace("@" + key.upper() + "@", str(value))
    for placeholder, uid in uids().items():
        source = source.replace(str(placeholder), str(uid))
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(source, "<" + block + ">", "exec"), namespace)
    except Exception as error:                     # noqa: BLE001 - the failure is the finding
        return str(error).strip(), printed.getvalue()
    return None, printed.getvalue()


def history(block, label=""):
    error, printed = run(block, root=HISTORY, label=label)
    if error:
        raise RuntimeError(block + ": " + error)
    return json.loads([line for line in printed.splitlines() if line.startswith("{")][-1])


def steps():
    return [s[2] for s in (undo.blender_steps() or [])]


def active_step():
    active = [s for s in (undo.blender_steps() or []) if s[3]]
    return active[-1][2] if active else None


def ran(label, block, push=True, **fill):
    """What the bridge does: the body, then a history step named as the
    Swift names it, if it worked."""
    error, _ = run(block, **fill)
    check(label, error is None, error)
    if error is None and push:
        name = blocks.get(block + "_UNDO", "")
        if name:
            history("PUSH", name)
            check(label + " — Blender's history records it as " + name, active_step() == name, active_step())
    return error


def photo():
    out = {}
    for obj in bpy.data.objects:
        out[obj.name] = dict(colls=sorted(c.name for c in obj.users_collection),
                             matrix=[round(c, 5) for row in obj.matrix_world for c in row],
                             selected=obj.select_get(), data=obj.data.name if obj.data else None,
                             cons=[(c.name, c.type, c.enabled, round(c.influence, 5)) for c in obj.constraints],
                             mods=[m.name for m in getattr(obj, 'modifiers', ())])
    tree = []

    def walk(layer, depth):
        c = layer.collection
        tree.append((depth, layer.name, layer.exclude, layer.hide_viewport, c.hide_select, c.hide_render,
                     sorted(o.name for o in c.objects)))
        for child in layer.children:
            walk(child, depth + 1)
    walk(bpy.context.view_layer.layer_collection, 0)
    view = localview.space()
    return dict(objects=out, tree=tree, colls=sorted(c.name for c in bpy.data.collections),
                local=sorted(localview.members(view)) if localview.members(view) is not None else None,
                active=bpy.context.view_layer.objects.active.name if bpy.context.view_layer.objects.active else None)


def refused(label, block, words, **fill):
    before = photo()
    error, _ = run(block, **fill)
    check(label, error is not None and words in error, error)
    check(label + " — and nothing changed", photo() == before)


# --------------------------------------------------------------------------
# The fixture and its uids

def uids():
    found = {}
    scene = bpy.context.scene
    found[900001] = scene.collection.session_uid
    for placeholder, name in ((900002, "Collection"), (900003, "Parts"), (900004, "Inner"), (900010, "A"),
                              (900011, "B"), (900012, "C"), (900013, "D")):
        c = bpy.data.collections.get(name)
        if c is not None:
            found[placeholder] = c.session_uid
    return found


def fresh(parts=True):
    """The startup scene, a sphere at (3, 0, 0) and a curve, with Parts
    inside Collection and Inner inside Parts; Cube active and selected.
    Sphere is in Collection and Parts; Ring (a Bézier circle) in Inner."""
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    view = localview.space()
    if view is not None and view.local_view is not None:
        with context.temp_override_view3d('fixture'):
            bpy.ops.view3d.localview(frame_selected=False)
    bpy.ops.wm.read_homefile(load_ui=False)
    bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
    sphere = bpy.context.object
    bpy.ops.curve.primitive_bezier_circle_add(radius=2, location=(0, 0, 0))
    ring = bpy.context.object
    if parts:
        coll = bpy.data.collections['Collection']
        p = bpy.data.collections.new('Parts')
        coll.children.link(p)
        inner = bpy.data.collections.new('Inner')
        p.children.link(inner)
        p.objects.link(sphere)
        inner.objects.link(ring)
        coll.objects.unlink(ring)
    for o in bpy.context.scene.objects:
        o.select_set(False)
    cube = bpy.data.objects['Cube']
    cube.select_set(True)
    bpy.context.view_layer.objects.active = cube
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children['Collection']
    history("PUSH", "Fixture")


def select(*names):
    for o in bpy.context.view_layer.objects:
        o.select_set(o.name in names)
    if names:
        bpy.context.view_layer.objects.active = bpy.data.objects[names[-1]]


class _Live:
    """An object by name, looked up at each use: an Undo re-reads what it
    changed, and a reference held across one is "removed"."""

    def __init__(self, name):
        object.__setattr__(self, '_name', name)

    def __getattr__(self, key):
        return getattr(bpy.data.objects[self._name], key)

    def __setattr__(self, key, value):
        setattr(bpy.data.objects[self._name], key, value)


passes = []


def outliner_tree():
    """Blender's Outliner in View Layer mode with its default filters, written
    as the Swift writes the app's: collections before objects, each object
    under every collection it is in, a child under its parent there."""
    out = []

    def walk(layer, depth):
        c = layer.collection
        name = "Scene Collection" if depth == 0 else c.name
        out.append("." * depth + "[" + name + (" excl" if (layer.exclude and depth) else "")
                   + (" hid" if layer.hide_viewport else "") + (" unsel" if (c.hide_select and depth) else "")
                   + (" norender" if (c.hide_render and depth) else "") + "]")
        for child in layer.children:
            walk(child, depth + 1)
        members = list(c.objects)

        def place(o, d):
            out.append("." * d + o.name)
            for kid in members:
                if kid.parent == o:
                    place(kid, d + 1)
        for o in members:
            if o.parent is None or o.parent not in members:
                place(o, depth + 1)
    walk(bpy.context.view_layer.layer_collection, 0)
    return out


def mirror(name, framing=None, framed=None):
    """One mirroring pass, recorded for the Swift with what Blender holds."""
    sync.sync()
    view = localview.space()
    local = localview.members(view)
    truth = {}
    for o in bpy.context.scene.objects:
        try:
            visible = o.visible_get()
        except RuntimeError:
            visible = False
        truth[o.name] = dict(
            visible=bool(visible and not o.hide_viewport),
            local=(o.name in local) if local is not None else None,
            collections=[c.name if c != bpy.context.scene.collection else "Scene Collection"
                         for c in bpy.data.collections if o.name in c.objects]
            + (["Scene Collection"] if o.name in bpy.context.scene.collection.objects else []),
            constraints=["%s:%s:%d:%s:%s" % (c.name, c.type, 1 if c.enabled else 0,
                                             ("%.4f" % c.influence).rstrip('0').rstrip('.'),
                                             c.target.name if getattr(c, 'target', None) else '')
                         for c in o.constraints],
            matrix=[c for row in o.matrix_world for c in row],
            selected=o.select_get())
    passes.append(dict(name=name, calls=list(bridge.calls), blender=truth, tree=outliner_tree(),
                       localView=sorted(local) if local is not None else None,
                       activeCollection=bpy.context.view_layer.active_layer_collection.name
                       if bpy.context.view_layer.active_layer_collection.collection != bpy.context.scene.collection
                       else "Scene Collection",
                       framing=framing, framed=framed))


# --------------------------------------------------------------------------
print("\nThe app's undo history keeps Blender's")
os.makedirs(os.path.join(WORK, "Documents"), exist_ok=True)
check("Blender's undo keeps the history", history("PUSH", "Original")["mode"] == "blender")

# --------------------------------------------------------------------------
print("\nCollections: the record and the Outliner's tree")
fresh()
mirror("new: the fixture")
record = collections.record()
check("the record carries four collections", record.count("kind=collection") == 4, record)
check("an object in two collections is in both entries",
      sum(1 for e in record.split("|") if "Sphere" in e) == 2, record)

print("\nNew Collection")
ran("New Collection inside the Scene Collection", "NEW_MASTER")
check("it is named as BKE_collection_new_name_get names it, " + blocks["NEW_NAME_MASTER"],
      blocks["NEW_NAME_MASTER"] in bpy.data.collections
      and blocks["NEW_NAME_MASTER"] in bpy.context.scene.collection.children,
      [c.name for c in bpy.data.collections])
ran("New Collection inside Collection", "NEW_COLLECTION")
want = blocks["NEW_NAME_COLLECTION"]
# "Collection 2" is taken by the one just made in the Scene Collection, and
# Blender's names are unique: it gets .001, as BKE_id_new names any.
made_inside = [c.name for c in bpy.data.collections['Collection'].children if c.name != "Parts"]
check("it is named " + want + ", inside Collection — " + want + ".001, the name being taken",
      made_inside == [want + ".001"], made_inside)
want = want + ".001"
mirror("after two New Collections")
history("UNDO")
history("UNDO")
check("two Undos take both back", blocks["NEW_NAME_MASTER"] not in bpy.data.collections
      and want not in bpy.data.collections, [c.name for c in bpy.data.collections])
mirror("after two Undos")

print("\nRename")
ran("Rename Parts", "RENAME_PARTS")
check("Blender holds the new name, separators and all", "Parts; renamed" in bpy.data.collections,
      [c.name for c in bpy.data.collections])
mirror("after Rename")
history("UNDO")

print("\nDelete and Delete Hierarchy")
before = photo()
ran("Delete Parts", "DELETE_PARTS")
check("Parts is gone", "Parts" not in bpy.data.collections)
check("its child Inner is now inside Collection, as BKE_collection_delete relinks it",
      "Inner" in bpy.data.collections['Collection'].children)
check("its Sphere is in Collection still, and in nothing deleted", [c.name for c in bpy.data.objects['Sphere'].users_collection] == ['Collection'],
      [c.name for c in bpy.data.objects['Sphere'].users_collection])
check("every object is still in the scene", set(o.name for o in bpy.context.scene.objects) == {"Cube", "Light", "Camera", "Sphere", "BézierCircle"},
      sorted(o.name for o in bpy.context.scene.objects))
mirror("after Delete")
history("UNDO")
check("Undo puts it back as it was", photo() == before)
# Delete Hierarchy: Ring is only in Inner (deleted with it); Sphere is in
# Collection too (kept).
ran("Delete Hierarchy Parts", "DELETE_H_PARTS")
check("Parts and Inner are gone", "Parts" not in bpy.data.collections and "Inner" not in bpy.data.collections)
check("the curve, in nothing else, went with them", "BézierCircle" not in bpy.data.objects,
      [o.name for o in bpy.data.objects])
check("Sphere, in Collection too, stayed", "Sphere" in bpy.context.scene.objects)
mirror("after Delete Hierarchy")
history("UNDO")
check("Undo puts the hierarchy back", photo() == before)
# The control: the data API's remove alone, which is what a Delete that did
# not relink would do, leaves Inner in no collection of the scene.
bpy.data.collections.remove(bpy.data.collections['Parts'])
check("control: removing the collection alone loses its child from the scene",
      "Inner" not in [c.name for c in bpy.data.collections['Collection'].children]
      and not any(c.name == "Inner" for c in bpy.context.scene.collection.children_recursive))
fresh()

print("\nThe toggles")
for toggle, prop in (("exclude", "exclude"), ("hide", "hide_viewport"), ("selectable", "hide_select"),
                     ("render", "hide_render")):
    for placeholder, name in ((900002, "Collection"), (900004, "Inner")):
        layer = collections.layer(uids()[placeholder])
        owner = layer if prop in ("exclude", "hide_viewport") else layer.collection
        ran("%s off for %s" % (toggle, name), "TOGGLE_%s_%d_OFF" % (toggle, placeholder))
        # Off as the Outliner draws it: excluded, hidden, unselectable, not rendering.
        check("Blender holds %s %s" % (name, prop), getattr(owner, prop) is True, getattr(owner, prop))
        mirror("after %s off for %s" % (toggle, name))
        ran("%s on for %s" % (toggle, name), "TOGGLE_%s_%d_ON" % (toggle, placeholder))
        check("and back", getattr(owner, prop) is False, getattr(owner, prop))
cube = _Live('Cube')
ran("Disable Selection on Collection", "TOGGLE_selectable_900002_OFF")
bpy.ops.object.select_all(action='SELECT')
check("then Select All leaves Collection's objects unselected, as Blender's does",
      not cube.select_get() and not bpy.data.objects['Sphere'].select_get())
ran("and on again", "TOGGLE_selectable_900002_ON")
ran("Exclude Collection", "TOGGLE_exclude_900002_OFF")
check("its objects leave the view layer and stay in the scene",
      'Cube' not in bpy.context.view_layer.objects and 'Cube' in bpy.context.scene.objects)
mirror("Collection excluded")
ran("Include it again", "TOGGLE_exclude_900002_ON")
fresh()
bpy.ops.object.mode_set(mode='EDIT')
refused("Exclude is refused while Cube, inside, is in Edit Mode", "TOGGLE_exclude_900002_OFF", "Edit Mode")
bpy.ops.object.mode_set(mode='OBJECT')
bpy.data.collections['Parts'].objects.link(bpy.data.objects['Cube'])
history("PUSH", "Cube in Parts")
bpy.ops.object.mode_set(mode='EDIT')
refused("Delete is refused while Cube, inside Parts, is in Edit Mode", "DELETE_PARTS", "Edit Mode")
refused("and Delete Hierarchy", "DELETE_H_PARTS", "Edit Mode")
check("Hide in Viewport is allowed there, as in Blender", run("TOGGLE_hide_900002_OFF")[0] is None
      and bpy.data.objects['Cube'].mode == 'EDIT')
run("TOGGLE_hide_900002_ON")
bpy.ops.object.mode_set(mode='OBJECT')

print("\nThe active collection")
fresh()
ran("A tap on Parts makes it the active collection", "ACTIVE_PARTS", push=False)
check("Blender's active collection is Parts", bpy.context.view_layer.active_layer_collection.name == "Parts")
bpy.ops.mesh.primitive_cone_add()
check("and a new object goes into it", [c.name for c in bpy.context.object.users_collection] == ["Parts"])
mirror("Parts active, a cone added")
ran("the Scene Collection", "ACTIVE_MASTER", push=False)
check("Blender's active collection is the scene's own",
      bpy.context.view_layer.active_layer_collection.collection == bpy.context.scene.collection)

print("\nMove to Collection (M) and Link to Collection (Shift+M)")
fresh()
select("Cube")
cube = _Live('Cube')
ran("Move Cube to Parts", "MOVE_PARTS")
check("Cube is in Parts only", [c.name for c in cube.users_collection] == ["Parts"],
      [c.name for c in cube.users_collection])
mirror("Cube moved to Parts")
ran("Link Cube to Inner", "LINK_INNER")
check("Cube is in Parts and Inner", sorted(c.name for c in cube.users_collection) == ["Inner", "Parts"])
mirror("Cube linked to Inner")
refused("Link to Inner again is Blender's own refusal", "LINK_INNER", "already in")
ran("Move Cube to the Scene Collection", "MOVE_MASTER")
check("Cube is in the scene's own collection only",
      [c for c in cube.users_collection] == [bpy.context.scene.collection])
history("UNDO")
history("UNDO")
history("UNDO")
check("three Undos put Cube back in Collection",
      [c.name for c in bpy.data.objects['Cube'].users_collection] == ["Collection"])
select("Cube", "Sphere")
ran("Move to New Collection inside Collection", "MOVE_NEW")
made = blocks["NEW_NAME_COLLECTION"]
check("both are in the new " + made + ", inside Collection",
      made in bpy.data.collections['Collection'].children
      and all([c.name for c in bpy.data.objects[n].users_collection] == [made] for n in ("Cube", "Sphere")),
      [(n, [c.name for c in bpy.data.objects[n].users_collection]) for n in ("Cube", "Sphere")])
mirror("Move to New Collection")
ran("Link to New Collection inside the Scene Collection", "LINK_NEW")
check("both are in Linked as well", all("Linked" in [c.name for c in bpy.data.objects[n].users_collection]
                                         for n in ("Cube", "Sphere")))
select()
refused("Move to Collection with nothing selected is refused (Blender: FINISHED, nothing moved)",
        "MOVE_PARTS", "none is selected")
select("Cube")
bpy.ops.object.mode_set(mode='EDIT')
refused("Move to Collection in Edit Mode is refused (Blender's poll: Object Mode)", "MOVE_PARTS", "Object Mode")
bpy.ops.object.mode_set(mode='OBJECT')
# The control: the operator search's own call, with the uid left out.
try:
    bpy.ops.object.move_to_collection()
    control = None
except RuntimeError as error:
    control = str(error)
check("control: without collection_uid Blender says what the search hit, 'No collection selected'",
      control is not None and "No collection selected" in control, control)
measured["move_to_collection undo"] = None
fresh()
select("Cube")
bpy.ops.object.move_to_collection('EXEC_DEFAULT', True, collection_uid=uids()[900003])
check("Blender's own step for it, called with its undo on, is Move to Collection",
      active_step() == blocks["MOVE_PARTS_UNDO"], active_step())
bpy.ops.object.link_to_collection('EXEC_DEFAULT', True, collection_uid=uids()[900004])
check("and Link to Collection's is Link to Collection", active_step() == blocks["LINK_INNER_UNDO"], active_step())

# --------------------------------------------------------------------------
print("\nConstraints")
FIELD_VALUES = {
    'use_x': 'False', 'use_y': 'False', 'invert_x': 'True', 'use_offset': 'True', 'target_space': "'LOCAL'",
    'owner_space': "'LOCAL'", 'euler_order': "'ZXY'", 'mix_mode': "'ADD'", 'power': '2.0',
    'use_make_uniform': 'True', 'use_add': 'True', 'remove_target_shear': 'True',
    'track_axis': "'TRACK_NEGATIVE_Z'", 'up_axis': "'UP_Y'", 'use_target_z': 'True',
    'use_min_x': 'True', 'min_x': '-0.5', 'use_max_z': 'True', 'max_z': '0.25', 'use_transform_limit': 'True',
    'use_limit_x': 'True', 'use_legacy_behavior': 'True', 'use_location_x': 'False',
    'use_rotation_z': 'False', 'use_scale_y': 'False', 'use_fixed_location': 'True', 'offset': '5.0',
    'offset_factor': '0.25', 'forward_axis': "'TRACK_NEGATIVE_Y'", 'use_curve_follow': 'True',
    'use_curve_radius': 'True',
}
TRACK_UP = {'TRACK_TO': "'UP_X'", 'FOLLOW_PATH': "'UP_X'"}
# Copy Transforms' Mix has its own items (no Add).
KIND_VALUES = {('COPY_TRANSFORMS', 'mix_mode'): "'BEFORE'", ('TRACK_TO', 'track_axis'): "'TRACK_NEGATIVE_Y'"}
fresh(parts=False)
select("Cube")
cube = _Live('Cube')
for kind in constraints.FIELDS:
    for c in list(cube.constraints):
        cube.constraints.remove(c)
    history("PUSH", "Cleared")
    ran("Add Object Constraint ▸ " + kind, "CON_ADD_" + kind)
    con = cube.constraints[-1] if len(cube.constraints) else None
    check(kind + ": Blender added it", con is not None and con.type == kind)
    if con is None:
        continue
    name = con.name
    if 'target' in constraints.FIELDS[kind]:
        target = 'BézierCircle' if kind == 'FOLLOW_PATH' else 'Sphere'
        error, _ = run("CON_TARGET", con=name) if kind != 'FOLLOW_PATH' else (None, None)
        if kind == 'FOLLOW_PATH':
            refused(kind + ": a mesh is refused as Follow Path's target", "CON_TARGET", "not one", con=name)
            con.target = bpy.data.objects[target]
        else:
            check(kind + ": Target Sphere", error is None and con.target == bpy.data.objects['Sphere'], error)
        refused(kind + ": the object itself is refused as its target", "CON_TARGET_SELF", "own target", con=name)
    for prop in constraints.FIELDS[kind]:
        if prop == 'target':
            continue
        value = KIND_VALUES.get((kind, prop)) or (TRACK_UP.get(kind) if prop == 'up_axis' else FIELD_VALUES.get(prop))
        if value is None:
            continue
        error, _ = run("CON_SET", con=name, prop=prop, value=value)
        got = getattr(con, prop)
        check(kind + ": " + prop + " = " + value, error is None and repr(got).strip("'") == value.strip("'")
              or (isinstance(got, float) and abs(got - float(value)) < 1e-6), (error, got))
    ran(kind + ": Influence 0.5", "CON_INFLUENCE", con=name)
    check(kind + ": Blender holds 0.5", abs(con.influence - 0.5) < 1e-6)
    mirror("constraint " + kind)
    ran(kind + ": Enabled off", "CON_DISABLE", con=name)
    check(kind + ": Blender holds it off", con.enabled is False)
    mirror("constraint " + kind + " off")
    ran(kind + ": on", "CON_ENABLE", con=name)
    record = constraints.record(cube)
    check(kind + ": its record carries every field the panel shows",
          all(("%s=" % f) in record for f in constraints.FIELDS[kind]), record)
# The evaluated matrix, held against Blender's own evaluation, and the
# control: a mirror that sent the object's own channels would not see it.
for c in list(cube.constraints):
    cube.constraints.remove(c)
history("PUSH", "Cleared")
ran("Copy Location", "CON_ADD_COPY_LOCATION")
run("CON_TARGET", con="Copy Location")
mirror("Copy Location from Sphere")
check("Blender evaluates the cube at the sphere, (3, 0, 0)",
      [round(v, 4) for v in cube.matrix_world.translation] == [3.0, 0.0, 0.0])
check("control: the cube's own location is still the origin, which a mirror of the channels would draw",
      list(cube.location) == [0.0, 0.0, 0.0])
# Order.
ran("Track To", "CON_ADD_TRACK_TO")
ran("Limit Scale", "CON_ADD_LIMIT_SCALE")
order = lambda: [c.name for c in cube.constraints]
ran("Move Constraint Up", "CON_UP", con="Limit Scale")
check("Limit Scale is second", order() == ["Copy Location", "Limit Scale", "Track To"], order())
ran("Move Constraint Down", "CON_DOWN", con="Copy Location")
check("Copy Location is second", order() == ["Limit Scale", "Copy Location", "Track To"], order())
ran("Move to First", "CON_FIRST", con="Track To")
check("Track To is first", order() == ["Track To", "Limit Scale", "Copy Location"], order())
refused("Move Up at the top is refused (Blender: CANCELLED)", "CON_UP", "already the first", con="Track To")
mirror("three constraints, reordered")
history("UNDO")
check("Undo takes Move to First back", order() == ["Limit Scale", "Copy Location", "Track To"], order())
ran("Rename", "CON_RENAME", con="Track To")
check("Blender holds Renamed", "Renamed" in order())
ran("Delete Constraint", "CON_REMOVE", con="Renamed")
check("it is gone", "Renamed" not in order(), order())
ran("Duplicate", "CON_OP_copy", con="Copy Location")
check("Copy Location.001 is there", "Copy Location.001" in order(), order())
select("Sphere", "Cube")
ran("Copy to Selected", "CON_OP_copy_to_selected", con="Copy Location")
check("Sphere has Copy Location", "Copy Location" in [c.name for c in bpy.data.objects['Sphere'].constraints])
select("Cube")
refused("Copy to Selected with no other object selected is refused", "CON_OP_copy_to_selected",
        "none is selected", con="Copy Location")
ran("Apply", "CON_OP_apply", con="Copy Location")
check("applied: the cube's own location is now the sphere's", [round(v, 4) for v in cube.location] == [3.0, 0.0, 0.0],
      list(cube.location))
mirror("Copy Location applied")
refused("Set Inverse on a Limit Scale is refused", "CON_OP_childof_set_inverse", "not a Child Of", con="Limit Scale")
# Child Of: set and clear inverse, against Blender.
fresh(parts=False)
select("Cube")
cube = _Live('Cube')
ran("Child Of", "CON_ADD_CHILD_OF")
run("CON_TARGET", con="Child Of")
bpy.context.evaluated_depsgraph_get()
check("Child Of sets its inverse on the first evaluation: the cube stays at the origin",
      [round(v, 4) for v in cube.matrix_world.translation] == [0.0, 0.0, 0.0])
ran("Clear Inverse", "CON_OP_childof_clear_inverse", con="Child Of")
bpy.context.evaluated_depsgraph_get()
check("Clear Inverse puts it at the sphere", [round(v, 4) for v in cube.matrix_world.translation] == [3.0, 0.0, 0.0])
mirror("Child Of, inverse cleared")
ran("Set Inverse", "CON_OP_childof_set_inverse", con="Child Of")
bpy.context.evaluated_depsgraph_get()
check("Set Inverse back at the origin", [round(v, 4) for v in cube.matrix_world.translation] == [0.0, 0.0, 0.0])
mirror("Child Of, inverse set")
# Follow Path and Animate Path.
for c in list(cube.constraints):
    cube.constraints.remove(c)
history("PUSH", "Cleared")
ran("Follow Path", "CON_ADD_FOLLOW_PATH")
refused("Animate Path with no target is refused", "CON_OP_followpath_path_animate", "no Target", con="Follow Path")
cube.constraints['Follow Path'].target = bpy.data.objects['BézierCircle']
history("PUSH", "Target")
mirror("Follow Path on the circle")
check("Follow Path puts the cube on the circle, (0, -2, 0)",
      [round(v, 4) for v in cube.matrix_world.translation] == [0.0, -2.0, 0.0],
      list(cube.matrix_world.translation))
ran("Animate Path", "CON_OP_followpath_path_animate", con="Follow Path")
ring = bpy.data.objects['BézierCircle']
check("Blender keyed the curve's evaluation time",
      bool(ring.data.animation_data and ring.data.animation_data.action))
mirror("Follow Path on the circle, animated")
# A type the tab has no rows for: the controls every one has.
ran("Armature (no rows here)", "CON_ADD_ARMATURE")
check("its record says no more than every constraint's",
      "kind=ARMATURE" in constraints.record(cube) and "target=" not in constraints.record(cube).split("|")[-1])
refused("a setting the panel does not show is refused", "CON_SET", "no setting", con="Armature",
        prop="use_deform_preserve_volume", value="True")
# Blender's own steps, with their undo on, for the names the Swift uses.
for c in list(cube.constraints):
    cube.constraints.remove(c)
history("PUSH", "Cleared")
bpy.ops.object.constraint_add('EXEC_DEFAULT', True, type='COPY_LOCATION')
check("Blender's step for Add Object Constraint is " + blocks["CON_ADD_COPY_LOCATION_UNDO"],
      active_step() == blocks["CON_ADD_COPY_LOCATION_UNDO"], active_step())
bpy.ops.object.constraint_add('EXEC_DEFAULT', True, type='TRACK_TO')
bpy.ops.constraint.move_up('EXEC_DEFAULT', True, constraint='Track To', owner='OBJECT')
check("for Move Constraint Up, " + blocks["CON_UP_UNDO"], active_step() == blocks["CON_UP_UNDO"], active_step())
bpy.ops.constraint.move_to_index('EXEC_DEFAULT', True, constraint='Track To', owner='OBJECT', index=1)
check("for Move to Last, " + blocks["CON_FIRST_UNDO"], active_step() == blocks["CON_FIRST_UNDO"], active_step())
bpy.ops.constraint.copy('EXEC_DEFAULT', True, constraint='Track To', owner='OBJECT')
check("for Duplicate, " + blocks["CON_OP_copy_UNDO"], active_step() == blocks["CON_OP_copy_UNDO"], active_step())
bpy.ops.constraint.delete('EXEC_DEFAULT', True, constraint='Track To', owner='OBJECT')
check("for Delete, " + blocks["CON_REMOVE_UNDO"], active_step() == blocks["CON_REMOVE_UNDO"], active_step())
bpy.ops.constraint.apply('EXEC_DEFAULT', True, constraint='Copy Location', owner='OBJECT')
check("for Apply, " + blocks["CON_OP_apply_UNDO"], active_step() == blocks["CON_OP_apply_UNDO"], active_step())

# A drag of what a constraint decides, previewed by Blender: each frame the
# channels go back, the release's own call runs, and the viewport is handed
# Blender's evaluated matrices — here held to Blender's own evaluation of the
# committed drag.
print("\nA drag that constraints decide, previewed by Blender")
fresh(parts=False)
select("Cube")
run("CON_ADD_COPY_LOCATION")
run("CON_TARGET", con="Copy Location")
history("PUSH", "Copy Location")
# The gizmo's own commit for a Move along Z (`LastOperator.gizmo`, as
# TransformGizmo.commitOperator builds it), which every frame runs through
# `exec(call, {'bpy': bpy})`: the Swift's string, not one written here.
call = blocks["DRAG_GIZMO_MOVE_Z"]
check("the gizmo's call is a translate along Z", call.startswith("bpy.ops.transform.translate(") and
      "constraint_axis=(False, False, True)" in call, call)
check("the drag begins", constraints.drag_begin() >= 1)
bridge.frames = []
constraints.drag_frame(call)
preview = bridge.frames[-1]
constraints.drag_end()
check("its end puts Cube's channels back", list(cube.location) == [0.0, 0.0, 0.0], list(cube.location))
check("and no step was pushed for the frames", active_step() == "Copy Location", active_step())
exec(call, {"bpy": bpy})
bpy.context.evaluated_depsgraph_get()
committed = [c for row in cube.matrix_world for c in row]
check("the frame showed Cube where the committed drag leaves it: on the sphere",
      max(abs(a - b) for a, b in zip(preview["Cube"], committed)) < 1e-6, (preview["Cube"], committed))
check("control: the channels alone, which the viewport's own preview drew, put it at z = 1 off the sphere",
      list(cube.location) == [0.0, 0.0, 1.0] and abs(committed[3] - 3.0) < 1e-6)
cube.location = (0.0, 0.0, 0.0)
select("Sphere")
constraints.drag_begin()
bridge.frames = []
constraints.drag_frame(blocks["DRAG_GIZMO_MOVE_Y"])
check("moving the target, the constrained Cube follows in the frame",
      abs(bridge.frames[-1]["Cube"][7] - 1.0) < 1e-6 and abs(bridge.frames[-1]["Sphere"][7] - 1.0) < 1e-6,
      bridge.frames[-1])
constraints.drag_end()
check("and both are back after", bpy.data.objects['Sphere'].location.y == 0.0)
try:
    constraints.drag_frame("pass")
    raised = None
except RuntimeError as error:
    raised = str(error)
check("a frame with no drag under way is refused in words", raised is not None and "No constrained drag" in raised,
      raised)

# The Transform field's own string for Location Z = 1 (TransformFieldEdit),
# through a frame: Blender's preview equals the committed write.
fresh(parts=False)
select("Cube")
run("CON_ADD_COPY_LOCATION")
run("CON_TARGET", con="Copy Location")
history("PUSH", "Copy Location")
field = blocks["DRAG_FIELD_LOC_Z"]
check("the field's write is an assignment to Cube's location", "location" in field and "Cube" in field, field)
constraints.drag_begin()
bridge.frames = []
constraints.drag_frame(field)
preview = bridge.frames[-1]
constraints.drag_end()
exec(field, {"bpy": bpy})
bpy.context.evaluated_depsgraph_get()
committed = [c for row in bpy.data.objects['Cube'].matrix_world for c in row]
check("the field's frame showed Cube where its commit leaves it, on the sphere",
      max(abs(a - b) for a, b in zip(preview["Cube"], committed)) < 1e-6, (preview["Cube"], committed))

print("\nA constrained drag holds the history")
# Round 4's review: Limit Location, then Move Y to 2; a drag's frame; an Undo
# between frames.
fresh(parts=False)
select("Cube")
cube = _Live('Cube')
ran("Limit Location", "CON_ADD_LIMIT_LOCATION")
cube.location.y = 2.0
history("PUSH", "Move Y")
constraints.drag_begin()
constraints.drag_frame(blocks["DRAG_GIZMO_MOVE_Z"])
try:
    history("UNDO")
    refusal = None
except RuntimeError as error:
    refusal = str(error)
check("an Undo between two frames is refused in words", refusal is not None and "let go" in refusal, refusal)
check("and the history and the data are as the drag found them",
      active_step() == "Move Y" and round(cube.location.y, 6) == 2.0, (active_step(), list(cube.location)))
constraints.drag_end()
check("the drag's end puts the channels back: y 2, z 0", [round(v, 6) for v in cube.location] == [0.0, 2.0, 0.0],
      list(cube.location))
history("UNDO")
check("after it, Undo works: Move Y undone", active_step() == "Add Constraint" and round(cube.location.y, 6) == 0.0,
      (active_step(), list(cube.location)))
history("REDO")
# The control: the same Undo with the guard out of the way, as before.
constraints.drag_begin()
constraints.drag_frame(blocks["DRAG_GIZMO_MOVE_Z"])
held = constraints._drag
constraints._drag = None
history("UNDO")
constraints._drag = held
constraints.drag_frame(blocks["DRAG_GIZMO_MOVE_Z"])
constraints.drag_end()
check("control: without the guard the undone change comes back with no step (review: y 2 at the constraint's step)",
      active_step() == "Add Constraint" and round(cube.location.y, 6) == 2.0, (active_step(), list(cube.location)))
# A drag begun over one whose end never came ends it first.
fresh(parts=False)
select("Cube")
cube = _Live('Cube')
history("PUSH", "Plain")
constraints.drag_begin()
constraints.drag_frame(blocks["DRAG_GIZMO_MOVE_Z"])
check("a frame moved it", round(cube.location.z, 6) == 1.0, list(cube.location))
constraints.drag_begin()
check("a drag begun over an open one puts its channels back first: z 0, not a baseline at 1",
      round(cube.location.z, 6) == 0.0 and constraints._drag['states']['Cube'][0] == (0.0, 0.0, 0.0),
      (list(cube.location), constraints._drag['states']['Cube'][0]))
constraints.drag_end()

# --------------------------------------------------------------------------
print("\nA lattice's constraints reach the interface")
fresh(parts=False)
bpy.ops.object.add(type='LATTICE', location=(0, 3, 0))
lattice = bpy.context.object
lattice.name = "Lattice"
lattice.constraints.new('COPY_LOCATION').target = bpy.data.objects['Sphere']
bpy.ops.object.empty_add(location=(0, -3, 0))
empty = bpy.context.object
empty.constraints.new('COPY_LOCATION').target = bpy.data.objects['Sphere']
history("PUSH", "Lattice and Empty")
mirror("a lattice and an empty with Copy Location")
sent = {c["name"] for c in bridge.calls if c["call"] == "record" and c["kind"] == "constraints"}
check("the lattice's pass sends its constraints record", "Lattice" in sent, sorted(sent))
check("as the empty's does", "Empty" in sent, sorted(sent))
pushed = {c["name"]: c["kind"] for c in bridge.calls if c["call"] == "push"}
check("and the lattice went through its own path, drawn as its grid", pushed.get("Lattice", "").startswith("LATTICE")
      and any(c["call"] == "push" and c["name"] == "Lattice" and len(base64.b64decode(c["positions"])) > 12
              for c in bridge.calls), pushed.get("Lattice"))

# --------------------------------------------------------------------------
print("\nLocal View: the 3D View's commands take only what it holds")


def local_fixture():
    """Local View holding Cube and Cone (a mesh at x -3 sharing Cube's
    material); Sphere, Light, Camera and the curve outside it. Cone active and
    selected, and Sphere and Light selected too — as a tap in the Outliner,
    which lists them, selects them in Blender."""
    fresh(parts=True)
    bpy.ops.mesh.primitive_cone_add(location=(-3, 0, 0))
    cone = bpy.context.object
    cone.data.materials.append(bpy.data.objects['Cube'].data.materials[0])
    select("Cube", "Cone")
    error, _ = run("LOCAL")
    if error:
        raise RuntimeError("Local View: " + error)
    select("Cone")
    bpy.data.objects['Sphere'].select_set(True)
    bpy.data.objects['Light'].select_set(True)
    history("PUSH", "Local View fixture")


OUTSIDE = ("Sphere", "Light", "Camera", "BézierCircle")
for block, label in (("LV_TYPE_MESH", "Select All by Type ▸ Mesh"), ("LV_RANDOM", "Select Random"),
                     ("LV_PATTERN", "Select Pattern *"), ("LV_GROUPED_TYPE", "Select Grouped ▸ Type"),
                     ("LV_LINKED_MATERIAL", "Select Linked ▸ Material"), ("LOCAL_SELECT_ALL", "Select All"),
                     ("LOCAL_INVERT", "Invert"), ("LV_DELETE", "Delete"), ("LV_DUPLICATE", "Duplicate Objects"),
                     ("LV_GIZMO_MOVE", "the gizmo's Move"), ("LV_GIZMO_ROTATE", "the gizmo's Rotate"),
                     ("LV_GIZMO_SCALE", "the gizmo's Scale"), ("LV_ROTATE", "Rotate"), ("LV_MIRROR", "Mirror ▸ X Global"),
                     ("LV_RANDOMIZE", "Randomize Transform"), ("LV_MOVE_TO", "Move to Collection ▸ Parts")):
    local_fixture()
    before = photo()
    error, _ = run(block)
    after = photo()
    touched = [n for n in OUTSIDE if after["objects"].get(n) != before["objects"][n]]
    inside = [n for n in ("Cube", "Cone") if after["objects"].get(n) != before["objects"].get(n)]
    if block == "LV_RANDOM":
        # Random may pick what is already picked; then the row says so.
        check(label + " in Local View: runs", error is None or "changed nothing" in error, error)
    else:
        check(label + " in Local View: runs and changes what it holds",
              error is None and (inside or after["local"] != before["local"]), (error, inside))
    check(label + ": every object outside Local View as it was", not touched, touched)
    local_fixture()
    before = photo()
    run(block + "_BARE")
    after = photo()
    bare = [n for n in OUTSIDE if after["objects"].get(n) != before["objects"][n]]
    measured.setdefault("bare in Local View, outside objects changed", {})[block] = bare
    if block not in ("LV_RANDOM",):
        check("control: " + label + " without the scope acts on objects outside Local View", bool(bare), bare)
# The Operator Search's Run in Local View: through `bridge.run`, as every
# command goes, so under the scope — a row that acts on objects takes what
# Local View holds, as the menus' rows do.
for block, label in (("LV_SEARCH_SELECT_ALL", "the search's (De)select All"),
                     ("LV_SEARCH_DELETE", "the search's Delete")):
    local_fixture()
    before = photo()
    error, _ = run(block)
    after = photo()
    touched = [n for n in OUTSIDE if after["objects"].get(n) != before["objects"][n]]
    inside = [n for n in ("Cube", "Cone") if after["objects"].get(n) != before["objects"].get(n)]
    check(label + " in Local View: runs and changes what it holds", error is None and bool(inside), (error, inside))
    check(label + ": every object outside Local View as it was", not touched, touched)
    local_fixture()
    before = photo()
    run(block + "_BARE")
    after = photo()
    bare = [n for n in OUTSIDE if after["objects"].get(n) != before["objects"][n]]
    check("control: " + label + " without the scope acts on objects outside Local View", bool(bare), bare)
# One of the interface's own operators from the search in Local View runs with
# no area, as the search runs it everywhere else, and leaves the borrowed 3D
# View what it was; under the view it would make it an Image Editor.
local_fixture()
area = [a for a in bpy.context.window_manager.windows[0].screen.areas if a.type == 'VIEW_3D'][0]
before = photo()
error, _ = run("LV_SEARCH_SPACE_TYPE")
check("the search's Cycle Space Type Set in Local View: refused by its poll, as with no area anywhere",
      error is not None and "needs a different selection or Blender editor context" in error, error)
check("and the borrowed 3D View is still one, in Local View, the scene as it was",
      area.type == 'VIEW_3D' and localview.members(localview.space()) == {"Cube", "Cone"} and photo() == before,
      (area.type, localview.members(localview.space())))
error, _ = run("LV_SEARCH_CALL_MENU")
check("the search's Call Menu with a menu named: refused in words, Blender still running (%s)"
      % (error or "")[:60], error is not None and "Blender's own interface" in error, error)
real = sync._interface_context
sync._interface_context = lambda path: contextlib.nullcontext()
error, _ = run("LV_SEARCH_SPACE_TYPE")
sync._interface_context = real
changed = area.type
area.type = 'VIEW_3D'
check("control: without the rule the same row runs under the view and makes the borrowed area an %s"
      % changed, error is None and changed == 'IMAGE_EDITOR', (error, changed))
check("  (the area put back: a 3D View in Local View again)", area.type == 'VIEW_3D'
      and localview.members(localview.space()) == {"Cube", "Cone"}, (area.type, localview.members(localview.space())))
local_fixture()
run("LV_DUPLICATE")
check("Duplicate in Local View: the copy joins it, as Blender's does",
      localview.members(localview.space()) == {"Cube", "Cone", "Cone.001"}, localview.members(localview.space()))
# The rotation, the one command a 3D View turns the other way: under the scope
# it turns as the app previews it (the headless Blender's way).
local_fixture()
cone = _Live('Cone')
run("LV_GIZMO_ROTATE_BARE")
bare_turn = cone.rotation_euler.z
local_fixture()
run("LV_GIZMO_ROTATE")
check("Rotate under the scope turns Cone the way the bare call does, " + "%.4f" % bare_turn,
      abs(cone.rotation_euler.z - bare_turn) < 1e-6 and abs(bare_turn - 0.4) < 1e-6, (cone.rotation_euler.z, bare_turn))
local_fixture()
real = context.flips_rotation
context.flips_rotation = lambda args, keywords: False
run("LV_GIZMO_ROTATE")
context.flips_rotation = real
check("control: without the value turned round, Blender's 3D View turns it the other way, -0.4",
      abs(cone.rotation_euler.z + 0.4) < 1e-6, cone.rotation_euler.z)
local_fixture()
run("LOCAL")
check("left Local View", localview.members(localview.space()) is None)
select("Cone", "Sphere")
before = photo()
run("LV_GIZMO_MOVE")
after = photo()
check("outside Local View the scope does nothing: the same Move moves every selected object",
      after["objects"]["Sphere"] != before["objects"]["Sphere"] and after["objects"]["Cone"] != before["objects"]["Cone"])

# --------------------------------------------------------------------------
print("\nLocal View frames an object with no box as Blender does")
for kind, make in (("an empty", lambda: bpy.ops.object.empty_add(location=(2, 1, 0.5))),
                   ("a point light", lambda: bpy.ops.object.light_add(type='POINT', location=(-1, 2, 1))),
                   ("a camera", lambda: bpy.ops.object.camera_add(location=(0, -4, 2))),
                   ("an empty of display size 2 and scale (1, 2, 1)", lambda: (
                       bpy.ops.object.empty_add(location=(1, 1, 1)),
                       setattr(bpy.context.object, 'empty_display_size', 2.0),
                       setattr(bpy.context.object, 'scale', (1, 2, 1)))),
                   ("a cube turned 0.7 about Z", lambda: (
                       bpy.ops.mesh.primitive_cube_add(location=(1, 0, 0)),
                       setattr(bpy.context.object, 'rotation_euler', (0, 0, 0.7))))):
    fresh(parts=False)
    make()
    made = bpy.context.object.name
    select(made)
    history("PUSH", "Add")
    view = localview.space()
    rv3d = view.region_3d
    ran("Local View on " + kind, "LOCAL")
    region = [r for a in bpy.context.window_manager.windows[0].screen.areas if a.type == 'VIEW_3D'
              for r in a.regions if r.type == 'WINDOW'][0]
    mirror("new: Local View on " + kind, framed=[region.width, region.height, rv3d.view_distance]
           + list(rv3d.view_location))
    measured.setdefault("Local View framing", {})[kind] = round(rv3d.view_distance, 4)
    ran("and out", "LOCAL")

# --------------------------------------------------------------------------
print("\nA collection linked into two parents")


def two_parents():
    """Scene ▸ A ▸ C ▸ D and Scene ▸ B ▸ C ▸ D, Cube in D only."""
    fresh(parts=False)
    scene = bpy.context.scene
    a, b, c, d = (bpy.data.collections.new(n) for n in "ABCD")
    scene.collection.children.link(a)
    scene.collection.children.link(b)
    a.children.link(c)
    b.children.link(c)
    c.children.link(d)
    cube = bpy.data.objects['Cube']
    for coll in list(cube.users_collection):
        coll.objects.unlink(cube)
    d.objects.link(cube)
    history("PUSH", "Two parents")


two_parents()
mirror("new: C in A and in B")
record = collections.record()
check("the record has one entry per layer collection, C and D twice",
      sum(1 for e in record.split("|") if ";name=C;" in e) == 2 and sum(1 for e in record.split("|") if ";name=D;" in e) == 2)


def lc():
    """The view layer's layer collection, read at each use: a reference held
    across the fixture's file load is freed memory, and reading it crashed
    desktop 5.2.1 (LayerCollection_children_lookup_string, 2026-10-20)."""
    return bpy.context.view_layer.layer_collection


ran("B ▸ C's checkbox off", "TWO_EXCLUDE_BC")
check("excludes B ▸ C and leaves A ▸ C", lc().children['B'].children['C'].exclude and not lc().children['A'].children['C'].exclude,
      (lc().children['A'].children['C'].exclude, lc().children['B'].children['C'].exclude))
mirror("B ▸ C excluded")
ran("and on again", "TWO_INCLUDE_BC")
check("both included", not lc().children['B'].children['C'].exclude and not lc().children['A'].children['C'].exclude)
ran("B ▸ C's eye", "TWO_HIDE_BC")
check("hides B ▸ C alone", lc().children['B'].children['C'].hide_viewport and not lc().children['A'].children['C'].hide_viewport)
mirror("B ▸ C hidden")
ran("a tap on B ▸ C", "TWO_ACTIVE_BC", push=False)
check("makes that instance active", bpy.context.view_layer.active_layer_collection == lc().children['B'].children['C'])
mirror("B ▸ C active")
# The control: the uid alone, as the call was, takes the first instance.
two_parents()
collections.set_exclude(uids()[900012], True)
check("control: by the uid alone, the first instance, A ▸ C, is the one excluded",
      lc().children['A'].children['C'].exclude and not lc().children['B'].children['C'].exclude)

# --------------------------------------------------------------------------
print("\nAn instancer is not moved into what it instances")


def instancer():
    """An empty instancing Parts (which holds Inner), selected alone."""
    fresh(parts=True)
    bpy.ops.object.empty_add(location=(0, 0, 3))
    e = bpy.context.object
    e.name = "Instancer"
    e.instance_type = 'COLLECTION'
    e.instance_collection = bpy.data.collections['Parts']
    select("Instancer")
    history("PUSH", "Instancer")


for block, label in (("MOVE_PARTS", "Move to Collection ▸ Parts"), ("MOVE_INNER", "Move to Collection ▸ Inner, inside Parts"),
                     ("LINK_PARTS", "Link to Collection ▸ Parts"), ("MOVE_NEW_PARTS", "Move to New Collection inside Parts")):
    instancer()
    refused(label + ", for an empty instancing Parts, is refused", block, "instances Parts")
instancer()
ran("Move to Collection ▸ Collection, outside what it instances, is allowed", "MOVE_COLLECTION")
check("and moves it", [c.name for c in bpy.data.objects['Instancer'].users_collection] == ["Collection"])
instancer()
bpy.ops.object.move_to_collection(collection_uid=uids()[900003])
gone = bpy.data.objects['Instancer']
check("control: Blender's own Move into Parts leaves it in no collection, with no users, out of the scene",
      not gone.users_collection and gone.users == 0 and gone.name not in bpy.context.scene.objects,
      ([c.name for c in gone.users_collection], gone.users))
instancer()
before = photo()
bpy.ops.object.link_to_collection(collection_uid=uids()[900003])
check("control: Blender's own Link into Parts answers and changes nothing", photo() == before)

# --------------------------------------------------------------------------
print("\nThe Object menu's rows: each against Blender's own operator, as its menu row calls it")


def against(label, block, blender_call, setup, compare=None):
    """The Swift's body, then Blender's own call, each from the same
    fixture (`setup`), held to the same scene."""
    setup()
    error, _ = run(block)
    check(label + ": runs", error is None, error)
    if error is None:
        history("PUSH", blocks[block + "_UNDO"])
        check(label + ": Blender's history records it as " + blocks[block + "_UNDO"],
              active_step() == blocks[block + "_UNDO"], active_step())
    ours = photo()
    setup()
    blender_call()
    theirs = photo()
    check(label + ": the same as Blender's own call", (compare or (lambda a, b: a == b))(ours, theirs),
          [k for k in ours["objects"] if ours["objects"][k] != theirs["objects"].get(k)])
    return ours


def two():
    """Cube turned 0.7 about Z and selected with Other (a second mesh with a
    shared material slot), Cube active."""
    fresh(parts=False)
    cube = bpy.data.objects['Cube']
    cube.rotation_euler = (0, 0, 0.7)
    cube.modifiers.new('Bevel', 'BEVEL')
    cube.constraints.new('COPY_ROTATION')
    me = bpy.data.meshes.new('M2')
    other = bpy.data.objects.new('Other', me)
    bpy.data.collections['Collection'].objects.link(other)
    other.location = (5, 3, 1)
    select("Other", "Cube")
    history("PUSH", "Two")


ops = bpy.ops
for i, (label, axis, local) in enumerate((("X Global", 0, False), ("Y Global", 1, False), ("Z Global", 2, False),
                                          ("X Local", 0, True), ("Y Local", 1, True), ("Z Local", 2, True))):
    want = [False, False, False]
    want[axis] = True
    against("Mirror ▸ " + label, "MIRROR_%d" % i,
            lambda w=want, l=local: ops.transform.mirror(orient_type='LOCAL' if l else 'GLOBAL',
                                                       constraint_axis=tuple(w)), two)
against("Mirror, the panel's X and Y", "MIRROR_XY",
        lambda: ops.transform.mirror(orient_type='GLOBAL', constraint_axis=(True, True, False)), two)
two()
run("MIRROR_0")
check("X Global left the cube at scale x -1, its turn mirrored to -0.7",
      [round(v, 4) for v in bpy.data.objects['Cube'].scale] == [-1.0, 1.0, 1.0]
      and round(bpy.data.objects['Cube'].rotation_euler.z, 4) == -0.7,
      (list(bpy.data.objects['Cube'].scale), bpy.data.objects['Cube'].rotation_euler.z))
mirror("new: Mirror X Global")
for option in ("GLOBAL", "LOCAL", "NORMAL", "GIMBAL", "CURSOR", "PARENT"):
    against("Mirror's Orientation " + option, "MIRROR_ORIENT_" + option,
            lambda o=option: ops.transform.mirror(orient_type=o, constraint_axis=(True, False, False)), two)
two()
select()
refused("Mirror with nothing selected is refused (Blender: CANCELLED)", "MIRROR_0", "select one first")
for t in ("OBDATA", "MATERIAL", "ANIMATION", "GROUPS", "DUPLICOLLECTION", "FONTS", "MODIFIERS", "CONSTRAINTS",
          "EFFECTS", "LIGHT_LINKING", "SHADOW_LINKING"):
    against("Link/Transfer Data ▸ " + t, "LINKS_" + t, lambda t=t: ops.object.make_links_data(type=t), two)
two()
run("LINKS_MODIFIERS")
check("Copy Modifiers gave Other the cube's Bevel", [m.name for m in bpy.data.objects['Other'].modifiers] == ["Bevel"])
mirror("new: Copy Modifiers")
two()
select("Cube")
refused("Link/Transfer Data with only the active selected is refused (Blender: FINISHED, nothing done)",
        "LINKS_OBDATA", "no other object")
bpy.context.view_layer.objects.active = None
select()
bpy.data.objects['Other'].select_set(True)
refused("with no active object, refused (Blender's poll failed)", "LINKS_OBDATA", "no selected object is active")


def shared():
    two()
    bpy.data.objects['Other'].data = bpy.data.objects['Cube'].data
    select("Other")
    history("PUSH", "Shared")


for row in ("object", "objectData", "objectDataMaterials", "materials", "objectAnimation", "objectDataAnimation"):
    flags = dict(object=(True, False, False, False, False), objectData=(True, True, False, False, False),
                 objectDataMaterials=(True, True, True, False, False), materials=(False, False, True, False, False),
                 objectAnimation=(False, False, False, True, False),
                 objectDataAnimation=(False, False, False, False, True))[row]
    against("Make Single User ▸ " + row, "SINGLE_" + row,
            lambda f=flags: ops.object.make_single_user(type='SELECTED_OBJECTS', object=f[0], obdata=f[1],
                                                        material=f[2], animation=f[3], obdata_animation=f[4]),
            shared)
shared()
run("SINGLE_objectData")
check("Object & Data gave Other a mesh of its own", bpy.data.objects['Other'].data != bpy.data.objects['Cube'].data)
shared()
select()
refused("Make Single User with nothing selected is refused (Blender: FINISHED, nothing done)",
        "SINGLE_object", "none is selected")
against("Make Single User, the panel's Type All", "SINGLE_ALL",
        lambda: ops.object.make_single_user(type='ALL', object=True, obdata=True, material=False, animation=False,
                                            obdata_animation=False), shared)
against("Copy Modifiers to Selected Objects", "MODCOPY", lambda: ops.object.modifiers_copy_to_selected(), two)
two()
run("MODCOPY")
check("Other has the cube's Bevel", [m.name for m in bpy.data.objects['Other'].modifiers] == ["Bevel"])
two()
select("Other")
bpy.context.view_layer.objects.active = bpy.data.objects['Other']
refused("Copy Modifiers from an object with none is refused", "MODCOPY", "it has none")
two()
still = photo()
ours = against("Randomize Transform, defaults", "RANDOMIZE", lambda: ops.object.randomize_transform(), two)
check("its defaults move nothing", ours["objects"] == still["objects"])
ours = against("Randomize Transform, the panel's seed 7, Location 2 1 0, Rotation Z, Scale X 1.5", "RANDOMIZE_SET",
               lambda: ops.object.randomize_transform(random_seed=7, loc=(2, 1, 0), rot=(0, 0, 0.5),
                                                      scale=(1.5, 1, 1)), two)
check("and those move the cube and Other", ours["objects"]["Cube"]["matrix"] != still["objects"]["Cube"]["matrix"]
      and ours["objects"]["Other"]["matrix"] != still["objects"]["Other"]["matrix"])
two()
select()
refused("Randomize Transform with nothing selected is refused (Blender: FINISHED, nothing done)", "RANDOMIZE",
        "none is selected")
against("Align Objects, defaults (no axis)", "ALIGN", lambda: ops.object.align(), two)
ours = against("Align Objects, the panel's X and Z", "ALIGN_XZ", lambda: ops.object.align(align_axis={'X', 'Z'}), two)
check("Other went to the cube's x and z", [round(v, 4) for v in [ours["objects"]["Other"]["matrix"][3],
                                                                 ours["objects"]["Other"]["matrix"][11]]] == [0.0, 0.0],
      ours["objects"]["Other"]["matrix"])
against("Align Objects to the 3D Cursor, Positive Sides", "ALIGN_CURSOR",
        lambda: ops.object.align(align_axis={'X', 'Z'}, relative_to='OPT_2', align_mode='OPT_3'), two)
two()
select()
refused("Align Objects with nothing selected is refused (Blender: CANCELLED)", "ALIGN", "none is selected")
against("Add Constraint (with Targets) ▸ Copy Rotation", "CON_WITH_TARGETS",
        lambda: ops.object.constraint_add_with_targets(type='COPY_ROTATION'), two)
against("Copy Constraints to Selected Objects", "CON_COPY", lambda: ops.object.constraints_copy(), two)
against("Clear Object Constraints", "CON_CLEAR", lambda: ops.object.constraints_clear(), two)
two()
for o in bpy.data.objects:
    o.constraints.clear()
history("PUSH", "None")
refused("Clear Object Constraints with none is refused", "CON_CLEAR", "none of them has one")
# The redo panel: the step put back and the call again with the panel's
# value, as `readjustThroughUndo` does.
two()
run("MIRROR_0")
history("PUSH", "Mirror")
history("REWIND")
run("MIRROR_XY")
history("PUSH_REPLACE", "Mirror")
check("the panel's Y on top of X Global: scale (-1, -1, 1), one Mirror step",
      [round(v, 4) for v in bpy.data.objects['Cube'].scale] == [-1.0, -1.0, 1.0]
      and steps().count("Mirror") == 1, (list(bpy.data.objects['Cube'].scale), steps()))
# Blender's steps for these, called with their undo on.
two()
ops.transform.mirror('EXEC_DEFAULT', True, orient_type='GLOBAL', constraint_axis=(True, False, False))
check("Blender's own step for Mirror is " + blocks["MIRROR_0_UNDO"], active_step() == blocks["MIRROR_0_UNDO"],
      active_step())
for block, call in (("LINKS_OBDATA", lambda: ops.object.make_links_data('EXEC_DEFAULT', True, type='MATERIAL')),
                    ("SINGLE_object", lambda: ops.object.make_single_user('EXEC_DEFAULT', True, object=True)),
                    ("MODCOPY", lambda: ops.object.modifiers_copy_to_selected('EXEC_DEFAULT', True)),
                    ("RANDOMIZE", lambda: ops.object.randomize_transform('EXEC_DEFAULT', True, loc=(1, 0, 0))),
                    ("ALIGN", lambda: ops.object.align('EXEC_DEFAULT', True, align_axis={'X'})),
                    ("CON_WITH_TARGETS", lambda: ops.object.constraint_add_with_targets('EXEC_DEFAULT', True,
                                                                                       type='COPY_LOCATION')),
                    ("CON_COPY", lambda: ops.object.constraints_copy('EXEC_DEFAULT', True))):
    call()
    check("Blender's own step for %s is %s" % (block, blocks[block + "_UNDO"]),
          active_step() == blocks[block + "_UNDO"], active_step())

# --------------------------------------------------------------------------
print("\nLocal View")
fresh()
view = localview.space()
select("Cube")
ran("Toggle Local View with Cube selected", "LOCAL")
check("Blender is in Local View with Cube alone", localview.members(view) == {"Cube"}, localview.members(view))
mirror("new: Local View, Cube")
region = [r for a in bpy.context.window_manager.windows[0].screen.areas if a.type == 'VIEW_3D'
          for r in a.regions if r.type == 'WINDOW'][0]
# Blender's own framing, in the borrowed region, for the Swift to match.
from mathutils import Vector
cube = _Live('Cube')
corners = [cube.matrix_world @ Vector(c) for c in cube.bound_box]
box_lo = [min(c[i] for c in corners) for i in range(3)]
box_hi = [max(c[i] for c in corners) for i in range(3)]
rv3d = view.region_3d
ran("Leave it", "LOCAL")
check("Blender left Local View", localview.members(view) is None)
with context.temp_override_view3d('measure'):
    bpy.ops.view3d.localview(frame_selected=True)
distance = rv3d.view_distance
with context.temp_override_view3d('measure'):
    bpy.ops.view3d.localview(frame_selected=True)
mirror("Local View left", framing=[region.width, region.height] + box_lo + box_hi + [distance])
select("Cube")
ran("Local View again", "LOCAL")
ran("Select ▸ All in Local View", "LOCAL_SELECT_ALL", push=False)
check("selects only what Local View holds (Blender's select_all under its view)",
      [o.name for o in bpy.context.view_layer.objects if o.select_get()] == ["Cube"],
      [o.name for o in bpy.context.view_layer.objects if o.select_get()])
run("SELECT_ALL_PLAIN")
check("control: the plain select_all, with no view, selects every object",
      len([o for o in bpy.context.view_layer.objects if o.select_get()]) == len(bpy.context.view_layer.objects))
bpy.ops.object.select_all(action='DESELECT')
select("Cube")
mirror("Local View, Cube selected")
# An add in Local View joins it, as Blender's Add from its view does; the
# control is the add alone, as a script's add is outside it in Blender too.
before_names = set(o.name for o in bpy.data.objects)
error, _ = run("ADD_IN_LOCAL")
added = [o.name for o in bpy.data.objects if o.name not in before_names]
check("Add in Local View: the new cone is in it", error is None and len(added) == 1
      and added[0] in (localview.members(localview.space()) or set()), (error, added, localview.members(localview.space())))
history("PUSH", "Add Cone")
mirror("a cone added in Local View")
before_names = set(o.name for o in bpy.data.objects)
error, _ = run("ADD_PLAIN")
plain = [o.name for o in bpy.data.objects if o.name not in before_names]
check("control: the add alone leaves it outside", error is None and len(plain) == 1
      and plain[0] not in (localview.members(localview.space()) or set()))
history("PUSH", "Add Cone")
history("UNDO")
history("UNDO")
select("Cube")
# Undo of a later change stays in Local View: the step is what holds it.
bpy.data.objects['Cube'].location.x = 1
history("PUSH", "Move")
history("UNDO")
check("an Undo of a later change stays in Local View (its step is in the history)",
      localview.members(localview.space()) == {"Cube"}, localview.members(localview.space()))
history("UNDO")
check("Undo of Local View's own step leaves it, as Blender's does",
      localview.members(localview.space()) is None, localview.members(localview.space()))
mirror("Local View undone")
# The control: entered without its step, an Undo of the next change leaves.
select("Cube")
with context.temp_override_view3d('control'):
    bpy.ops.view3d.localview(frame_selected=False)
bpy.data.objects['Cube'].location.x = 2
history("PUSH", "Move")
history("UNDO")
check("control: entered without a step, an Undo of the next change leaves Local View",
      localview.members(localview.space()) is None)
# Remove from Local View, and leaving it when empty.
fresh()
select("Cube", "Sphere")
ran("Local View with Cube and Sphere", "LOCAL")
select("Sphere")
ran("Remove from Local View", "LOCAL_REMOVE")
check("Sphere is out, deselected; Cube stays",
      localview.members(localview.space()) == {"Cube"} and not bpy.data.objects['Sphere'].select_get())
mirror("Sphere removed from Local View")
select()
refused("Remove from Local View with nothing selected is refused", "LOCAL_REMOVE", "none is")
select("Cube")
bpy.ops.object.delete()
history("PUSH", "Delete")
mirror("the only object in Local View deleted")
check("the pass left Local View when it emptied, as Blender's redraw does",
      localview.members(localview.space()) is None)
select()
refused("Local View with nothing selected is refused (Blender: CANCELLED)", "LOCAL", "none is selected")

check("Blender's history named the steps Local View and Remove from Local View",
      "Local View" in steps() and "Remove from Local View" in steps(), steps())
# From Edit Mode and Sculpt Mode, as the More menu offers it there: Blender
# takes the object being edited.
fresh(parts=False)
select("Cube")
bpy.ops.object.mode_set(mode='EDIT')
ran("Local View from Edit Mode", "LOCAL")
check("it holds the object being edited", localview.members(localview.space()) == {"Cube"},
      localview.members(localview.space()))
refused("Remove from Local View is refused in Edit Mode (Blender's poll: no edit object)", "LOCAL_REMOVE",
        "Object Mode")
ran("and leaving it from Edit Mode", "LOCAL")
check("left, still in Edit Mode", localview.members(localview.space()) is None
      and bpy.data.objects['Cube'].mode == 'EDIT')
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.mode_set(mode='SCULPT')
ran("Local View from Sculpt Mode", "LOCAL")
check("it holds the sculpted object", localview.members(localview.space()) == {"Cube"})
ran("and leaving it", "LOCAL")
bpy.ops.object.mode_set(mode='OBJECT')

json.dump(passes, open(PASSES, "w"))
print("\n%d mirror passes written for the Swift" % len(passes))
print("\nverify.py: %s" % ("ALL PASS" if fail == 0 else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
