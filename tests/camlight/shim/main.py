"""The simulator's shim, for cameras, lights and empties, run on the Mac.

The app's `_blenderkit` module is C and Swift; this stands in for it with the
same rules — Blender's `.001` names, a data-block name unique per kind, an add
selecting only what it added — so the shim's Python can run here without a
simulator. Run by scripts/run-camlight-tests.sh.

    main.py [calls.txt [records.json]]

With calls.txt, the Python the interface sends (tests/camlight/blender/main.swift)
is run through the shim too. With records.json — what Blender 5.2.1's mirror
sent for tests/camlight/scenario.py — the shim's mirror is held to it.
"""

import json
import math
import os
import sys
import types
from array import array

sys.dont_write_bytecode = True   # the modules ship inside the app; no .pyc beside them

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
SITE = os.path.join(ROOT, "Resources", "python", "site")
sys.path.insert(0, SITE)

failures = 0


def check(label, ok, detail=""):
    global failures
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        failures += 1


# ---------------------------------------------------------------------------
# A stand-in for the app's `_blenderkit`


# ObjectDisplay.swift's keys and defaults, in its order: what the app hands
# back for a record, whatever the shim sent it.
DEFAULTS = {
    "CAMERA": [("type", "PERSP"), ("lens", "50.0"), ("sensor_fit", "AUTO"),
               ("sensor_width", "36.0"), ("sensor_height", "24.0"), ("ortho_scale", "6.0"),
               ("clip_start", "0.1"), ("clip_end", "1000.0"), ("shift_x", "0.0"),
               ("shift_y", "0.0"), ("display_size", "1.0"), ("show_limits", "0"),
               ("focus_distance", "10.0"), ("aspect_x", "1920.0"), ("aspect_y", "1080.0"),
               ("scene_camera", "0")],
    "LIGHT": [("type", "POINT"), ("color", "1.0,1.0,1.0"), ("energy", "10.0"),
              ("shadow_soft_size", "0.0"), ("spot_size", repr(math.pi / 4)),
              ("spot_blend", "0.15"), ("show_cone", "0"), ("shape", "SQUARE"), ("size", "0.25"),
              ("size_y", "0.25"), ("cutoff_distance", "40.0"),
              ("shadow_buffer_clip_start", "0.05")],
    "EMPTY": [("empty_display_type", "PLAIN_AXES"), ("empty_display_size", "1.0"),
              ("empty_image_offset", "-0.5,-0.5"), ("image_aspect", "1.0,1.0")],
}


def normalised(kind, record):
    given = {}
    for pair in record.split(";"):
        key, sep, value = pair.partition("=")
        if sep:
            given[key] = value
    return ";".join(key + "=" + given.get(key, default) for key, default in DEFAULTS[kind])


class Thing:
    def __init__(self, name, location, display=None):
        self.name = name
        self.location = list(location)
        self.rotation = [0.0, 0.0, 0.0]
        self.scale = [1.0, 1.0, 1.0]
        # The app's two flags, as `bk_scene_set_visible` keeps them: Disable
        # in Viewports and the view layer's hide. Drawn when neither is set.
        self.disabled = False
        self.hidden = False
        self.display = display      # [type, data name, record] or None

    @property
    def visible(self):
        return not (self.disabled or self.hidden)


class Bridge(types.ModuleType):
    def __init__(self):
        super().__init__("_blenderkit")
        self.objects = []
        self.selection = set()
        self.active = None
        self.pushed = {}
        self.displays = {}
        self.order = []

    # -- the scene
    def _find(self, name):
        for thing in self.objects:
            if thing.name == name:
                return thing
        raise KeyError("no object named %s" % name)

    def _unique(self, base):
        taken = {t.name for t in self.objects}
        if base not in taken:
            return base
        n = 1
        while "%s.%03d" % (base, n) in taken:
            n += 1
        return "%s.%03d" % (base, n)

    def _unique_data(self, name, kind):
        taken = {t.display[1] for t in self.objects if t.display and t.display[0] == kind}
        if name not in taken:
            return name
        base = name
        head, dot, tail = name.rpartition(".")
        if dot and len(tail) == 3 and tail.isdigit():
            base = head
        n = 1
        while "%s.%03d" % (base, n) in taken:
            n += 1
        return "%s.%03d" % (base, n)

    def object_names(self):
        return [t.name for t in self.objects]

    def add_object(self, kind, name, x, y, z, data_name, record, select=True):
        if kind not in DEFAULTS:
            raise ValueError("cannot add an object of type %s" % kind)
        data = self._unique_data(data_name, kind) if kind != "EMPTY" else ""
        thing = Thing(self._unique(name), (x, y, z), [kind, data, normalised(kind, record)])
        self.objects.append(thing)
        if select:
            self.selection = {thing.name}
            self.active = thing.name
        return thing.name

    def object_display(self, name):
        thing = self._find(name)
        return tuple(thing.display) if thing.display else None

    def set_object_display(self, name, data_name, record):
        thing = self._find(name)
        if thing.display is None:
            raise TypeError("%s is not a camera, light or empty" % name)
        kind = thing.display[0]
        thing.display = [kind, data_name if kind != "EMPTY" else "", normalised(kind, record)]

    def get_vec(self, name, prop):
        thing = self._find(name)
        return tuple({"location": thing.location, "rotation_euler": thing.rotation,
                      "scale": thing.scale}[prop])

    def set_vec(self, name, prop, x, y, z):
        thing = self._find(name)
        {"location": thing.location, "rotation_euler": thing.rotation, "scale": thing.scale}[prop][:] = [x, y, z]

    def rename(self, old, new):
        thing = self._find(old)
        resolved = new if new == old else self._unique(new)
        if old in self.selection:
            self.selection = (self.selection - {old}) | {resolved}
        if self.active == old:
            self.active = resolved
        thing.name = resolved
        return resolved

    def select(self, name, on=True):
        self._find(name)
        if on:
            self.selection.add(name)
            self.active = name
        else:
            self.selection.discard(name)

    def select_all(self, on=True):
        if on:
            self.selection = set(self.object_names())
        else:
            self.selection = set()
            self.active = None

    def is_selected(self, name):
        self._find(name)
        return name in self.selection

    def active_name(self):
        return self.active

    def set_active(self, name):
        self.active = name or None

    def remove(self, name):
        thing = self._find(name)
        self.objects.remove(thing)
        self.selection.discard(name)
        if self.active == name:
            self.active = None

    def delete_selected(self):
        doomed = [t for t in self.objects if t.name in self.selection]
        for thing in doomed:
            self.objects.remove(thing)
        self.selection = set()
        self.active = None
        return len(doomed)

    def duplicate_selected(self):
        made = []
        for thing in [t for t in self.objects if t.name in self.selection]:
            copy = Thing(self._unique(thing.name), thing.location)
            copy.rotation, copy.scale = list(thing.rotation), list(thing.scale)
            if thing.display:
                kind, data, record = thing.display
                copy.display = [kind, self._unique_data(data, kind) if kind != "EMPTY" else "", record]
            self.objects.append(copy)
            made.append(copy.name)
        if made:
            self.selection = set(made)
            self.active = made[-1]
        return len(made)

    # `which` as the app's bridge takes it: 0 Disable in Viewports, 1 the view
    # layer, 2 drawn (EmbeddedBpyRuntime.swift's bk_scene_get_visible).
    def get_visible(self, name, which=2):
        thing = self._find(name)
        return (not thing.disabled, not thing.hidden, thing.visible)[min(max(which, 0), 2)]

    def set_visible(self, name, visible, which=0):
        thing = self._find(name)
        if which == 1:
            thing.hidden = not visible
        else:
            thing.disabled = not visible

    def get_color(self, name):
        return (1.0, 1.0, 1.0, 1.0)

    def mode(self):
        return "OBJECT"

    def set_mode(self, mode):
        pass

    def set_frame(self, frame):
        return 1

    # -- the mirror, as bk_sync_* receive it
    def sync_begin(self):
        self.pushed, self.displays, self.order = {}, {}, []

    def sync_push(self, name, kind, matrix, verts, normals, tris, selected, active, rgba):
        values = array("d")
        values.frombytes(matrix)
        self.pushed[name] = dict(kind=kind, verts=len(verts) // 12, tris=len(tris) // 12,
                                 selected=selected, active=active, matrix=list(values))
        self.order.append(name)

    def sync_display(self, name, kind, data, record):
        if not self.order or self.order[-1] != name:
            raise ValueError("a display for %s did not follow its object" % name)
        self.displays[name] = dict(type=kind, data=data, record=record)

    def sync_end(self):
        pass


bridge = Bridge()
sys.modules["_blenderkit"] = bridge

import bpy                      # noqa: E402  (the shim, in Resources/python/site)
import _blenderkit_sync as sync  # noqa: E402


def fresh():
    bridge.objects, bridge.selection, bridge.active = [], set(), None
    bpy._objects._other_scene_camera[0] = None
    bpy.context.scene.render.resolution_x = 1920
    bpy.context.scene.render.resolution_y = 1080
    bpy.context.scene.render.pixel_aspect_x = 1.0
    bpy.context.scene.render.pixel_aspect_y = 1.0


def fields(record):
    out = {}
    for pair in record.split(";"):
        key, sep, value = pair.partition("=")
        if sep:
            out[key] = value
    return out


def raises(kind, action):
    try:
        action()
    except kind as error:
        return str(error)
    return None


print("the shim makes cameras, lights and empties")
fresh()
check("camera_add finishes", bpy.ops.object.camera_add(location=(1, 2, 3), rotation=(0.5, 0, 0)) == {"FINISHED"})
cam = bpy.context.object
check("and leaves the camera active, as a camera", cam is not None and cam.name == "Camera" and cam.type == "CAMERA",
      cam and cam.type)
check("where it was put, turned as asked", tuple(cam.location) == (1, 2, 3) and tuple(cam.rotation_euler) == (0.5, 0, 0))
check("its data is a Camera with Blender 5.2.1's settings",
      repr(cam.data) == 'bpy.data.cameras["Camera"]' and cam.data.lens == 50.0 and cam.data.sensor_width == 36.0
      and cam.data.sensor_fit == "AUTO" and cam.data.display_size == 1.0 and cam.data.dof.focus_distance == 10.0)
cam.data.lens = 35
check("a setting written is a setting read back", cam.data.lens == 35.0)
check("and reaches the app's record", fields(bridge.object_display("Camera")[2])["lens"] == "35.0")
cam.data.angle = math.radians(90)
check("angle sets the lens from the sensor, as Blender's does", abs(cam.data.lens - 18.0) < 1e-9, cam.data.lens)
check("a type Blender does not have is refused as Blender refuses it",
      raises(TypeError, lambda: setattr(cam.data, "type", "FISHEYE")) is not None)
check("the scene has no camera until one is chosen", bpy.context.scene.camera is None)
bpy.context.scene.camera = cam
check("then it has that one", bpy.context.scene.camera == cam)
bpy.ops.object.camera_add()
second = bpy.context.object
check("a second camera is Camera.001, holding Camera.001", second.name == "Camera.001" and second.data.name == "Camera.001")
bpy.context.scene.camera = second
check("choosing another moves the mark", fields(bridge.object_display("Camera")[2])["scene_camera"] == "0"
      and fields(bridge.object_display("Camera.001")[2])["scene_camera"] == "1")
bpy.context.scene.render.resolution_y = 1920
check("the render size is every camera's frame shape",
      fields(bridge.object_display("Camera")[2])["aspect_y"] == "1920.0")
check("cameras are listed as data", len(bpy.data.cameras) == 2 and bpy.data.cameras.keys() == ["Camera", "Camera.001"])

bpy.ops.object.light_add(type="POINT")
point = bpy.context.object
check("light_add names the light after its type", point.name == "Point" and point.type == "LIGHT"
      and point.data.type == "POINT" and point.data.energy == 10.0)
check("a point light has no spot size, as a PointLight has none",
      "PointLight" in (raises(AttributeError, lambda: point.data.spot_size) or ""))
point.data.type = "SPOT"
check("until it is a spot", abs(point.data.spot_size - math.radians(45)) < 1e-9 and point.data.spot_blend == 0.15)
bpy.ops.object.light_add(type="AREA", radius=2.0)
check("an area light's radius is its size, four times Blender's quarter", bpy.context.object.data.size == 2.0)
bpy.ops.object.light_add(type="SUN")
check("a sun starts at one watt", bpy.context.object.data.energy == 1.0)
check("an unknown light type is refused", raises(TypeError, lambda: bpy.ops.object.light_add(type="LASER")) is not None)

bpy.ops.object.empty_add(type="CUBE", radius=0.5)
box = bpy.context.object
check("empty_add makes an empty with no data", box.type == "EMPTY" and box.data is None and box.name == "Empty")
check("its radius is its display size", box.empty_display_type == "CUBE" and box.empty_display_size == 0.5)
box.empty_display_type = "SPHERE"
check("and its display type can be changed", box.empty_display_type == "SPHERE")
loose = bpy.data.objects.new("Loose", None)
bpy.context.collection.objects.link(loose)
check("objects.new with no data makes an empty, unselected", loose.type == "EMPTY" and not loose.select_get())
made = bpy.data.lights.new("Lamp", "SPOT")
holder = bpy.data.objects.new("Lamp", made)
check("and with a light makes a light holding it", holder.type == "LIGHT" and holder.data.name == "Lamp")
made.spot_size = 0.5
check("the data-block stays bound to the object that took it", holder.data.spot_size == 0.5)

bridge.objects.append(Thing("Cube", (0, 0, 0)))
check("an object with no display is still a mesh, holding its mesh",
      bpy.data.objects["Cube"].type == "MESH" and type(bpy.data.objects["Cube"].data).__name__ == "Mesh")
bridge.remove("Cube")

print("\nthe shim's objects reach the mirror")
bridge.select_all(False)
bridge.select("Camera", True)
sync.sync()
check("every one is pushed with a display", set(bridge.displays) == set(bridge.object_names()),
      sorted(set(bridge.object_names()) - set(bridge.displays)))
check("as an origin with no faces", all(p["verts"] == 1 and p["tris"] == 0 for p in bridge.pushed.values()))
check("a camera's record carries its lens",
      abs(float(fields(bridge.displays["Camera"]["record"])["lens"]) - 18.0) < 1e-9,
      bridge.displays["Camera"]["record"])
bpy.data.objects.remove(bpy.data.objects["Point"], do_unlink=True)
check("removing an object takes its light with it", "Point" not in bpy.data.lights.keys())

calls = sys.argv[1] if len(sys.argv) > 1 else None
if calls:
    blocks = {}
    for chunk in open(calls).read().split("#--"):
        chunk = chunk.strip()
        if chunk:
            head, _, body = chunk.partition("\n")
            blocks[head[4:].strip()] = body

    def run(name, subject=None):
        text = blocks[name] if subject is None else blocks[name].replace("@SUBJECT@", subject)
        namespace = {"bpy": bpy}
        exec(compile(text, "<" + name + ">", "exec"), namespace)
        return namespace

    print("\nthe Python the interface sends runs through the shim")
    fresh()
    ns = run("ADD_CAMERA")
    added = bpy.context.object
    check("Add Camera: the camera, adjustable", added.type == "CAMERA" and ns.get("_bk_adjustable") is True)
    check("at the cursor", [round(c, 4) for c in added.location] == [float(x) for x in blocks["CURSOR"].split()],
          tuple(added.location))
    check("made the scene's camera", bpy.context.scene.camera == added)
    run("RERUN_CAMERA", subject=added.name)
    check("adjusting it replaces it rather than adding another",
          len(bpy.data.cameras) == 1 and bpy.context.object.name == "Camera"
          and tuple(bpy.context.object.location) == (0, 0, 3))
    check("and the replacement is the scene's camera", bpy.context.scene.camera == bpy.context.object)
    for kind in ("POINT", "SUN", "SPOT", "AREA"):
        fresh()
        run("ADD_LIGHT_" + kind)
        check("Add Light ▸ " + kind.title(), bpy.context.object.type == "LIGHT" and bpy.context.object.data.type == kind)
    fresh()
    run("ADD_LIGHT_POINT")
    run("RERUN_LIGHT_TYPE", subject="Point")
    check("adjusting the type and radius", [o.name for o in bpy.data.objects] == ["Area"]
          and bpy.data.objects["Area"].data.size == 2.0)
    for kind in ("PLAIN_AXES", "ARROWS", "SINGLE_ARROW", "CIRCLE", "CUBE", "SPHERE", "CONE", "IMAGE"):
        fresh()
        run("ADD_EMPTY_" + kind)
        check("Add Empty ▸ " + kind, bpy.context.object.empty_display_type == kind)
    fresh()
    run("ADD_EMPTY_PLAIN_AXES")
    run("RERUN_EMPTY", subject="Empty")
    check("adjusting an empty", [o.name for o in bpy.data.objects] == ["Empty"]
          and bpy.context.object.empty_display_type == "CUBE" and bpy.context.object.empty_display_size == 0.25)
    fresh()
    bpy.ops.object.camera_add()
    bpy.ops.object.light_add()
    run("TAP_SELECT_RUN")
    check("a tap selects the camera", bridge.selection == {"Camera"} and bridge.active == "Camera",
          (bridge.selection, bridge.active, bridge.object_names()))
    run("DUPLICATE")
    check("Duplicate copies it, with data of its own",
          bridge.active == "Camera.001" and "Camera.001" in bpy.data.objects
          and bpy.data.objects["Camera.001"].data.name == "Camera.001",
          (bridge.selection, bridge.active, bridge.object_names()))
    run("DELETE")
    check("Delete removes it", "Camera.001" not in bpy.data.objects)

    print("\nSet Origin and Apply refuse, in the simulator, what Blender does nothing to")
    for guard, make, label in (("APPLY_GUARD", lambda: bpy.ops.object.camera_add(), "Apply, a camera"),
                               ("APPLY_GUARD", lambda: bpy.ops.object.light_add(type='SUN'), "Apply, a sun"),
                               ("ORIGIN_GUARD", lambda: bpy.ops.object.empty_add(), "Set Origin, an empty"),
                               ("ORIGIN_GUARD", lambda: bpy.ops.object.light_add(type='AREA'),
                                "Set Origin, an area light")):
        fresh()
        make()
        said = raises(RuntimeError, lambda: run(guard))
        check(label + ": refused in words, naming it",
              said is not None and "does nothing to" in said and bpy.context.object.name in said, said)
    for make, label in ((lambda: bpy.ops.object.light_add(type='AREA'), "an area light"),
                        (lambda: bpy.ops.object.empty_add(), "an empty")):
        fresh()
        make()
        check("Apply lets " + label + " through, as Blender acts on it",
              raises(RuntimeError, lambda: run("APPLY_GUARD")) is None)
        said = raises(NotImplementedError, lambda: bpy.ops.object.transform_apply(
            location=False, rotation=False, scale=True))
        check("and the shim, which does not model that bake, says so instead of answering FINISHED",
              said is not None and bpy.context.object.name in said, said)
    fresh()
    bpy.ops.object.light_add(type='AREA')
    said = raises(RuntimeError, lambda: bpy.ops.object.transform_apply(location=True, rotation=False, scale=False))
    check("Apply Location on an area light is refused in Blender's words",
          said is not None and 'Area Lights can only have scale applied: "Area"' in said, said)

records_path = sys.argv[2] if len(sys.argv) > 2 else None
if records_path:
    print("\nthe shim mirrors the scenario as Blender 5.2.1 does")
    blender = json.load(open(records_path))
    fresh()
    namespace = {"bpy": bpy}
    exec(compile(open(os.path.join(ROOT, "tests", "camlight", "scenario.py")).read(), "scenario.py", "exec"),
         namespace)
    sync.sync()
    check("the same objects", sorted(bridge.pushed) == sorted(blender), (sorted(bridge.pushed), sorted(blender)))
    for name in sorted(blender):
        theirs, ours = blender[name], bridge.pushed.get(name)
        if ours is None:
            continue
        mine = bridge.displays.get(name)
        problems = []
        if ours["kind"] != theirs["kind"]:
            problems.append("kind %s, Blender %s" % (ours["kind"], theirs["kind"]))
        if (ours["selected"], ours["active"]) != (theirs["selected"], theirs["active"]):
            problems.append("selection %s, Blender %s" % ((ours["selected"], ours["active"]),
                                                           (theirs["selected"], theirs["active"])))
        if any(abs(a - b) > 1e-5 for a, b in zip(ours["matrix"], theirs["matrix"])):
            problems.append("matrix %s, Blender %s" % (ours["matrix"], theirs["matrix"]))
        if mine is None or mine["type"] != theirs["type"] or mine["data"] != theirs["data"]:
            problems.append("display %s, Blender %s/%s" % (mine, theirs["type"], theirs["data"]))
        else:
            a, b = fields(mine["record"]), fields(theirs["record"])
            if set(a) != set(b):
                problems.append("keys %s, Blender %s" % (sorted(a), sorted(b)))
            for key in sorted(set(a) & set(b)):
                try:
                    same = all(abs(float(x) - float(y)) <= 1e-5 * max(1.0, abs(float(y)))
                               for x, y in zip(a[key].split(","), b[key].split(",")))
                except ValueError:
                    same = a[key] == b[key]
                if not same:
                    problems.append("%s %s, Blender %s" % (key, a[key], b[key]))
        check("%s: as Blender mirrors it" % name, not problems, "; ".join(problems))

print("\n" + ("ALL PASS" if not failures else "%d FAILED" % failures))
sys.exit(1 if failures else 0)
