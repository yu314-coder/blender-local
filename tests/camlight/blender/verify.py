"""Cameras, lights and empties, run by a headless Blender the way an iPad runs them.

scripts/run-camlight-blender-check.sh starts Blender 5.2.1 with
`-b --factory-startup`: no user settings and no 3D View, so `bpy.context.area`
is None, as it is for the bpy module on a device. The Python checked here is
what the Swift sends (printed by tests/camlight/blender/main.swift), and the
mirror is `_blenderkit_sync` itself.

    verify.py -- calls.txt out-directory

It leaves two files for the stages after it: frames.json, Blender's own camera
frames beside the records the mirror sent for those cameras, which the Swift
overlay code is held to; and records.json, what the mirror sent for
tests/camlight/scenario.py, which the simulator's shim is held to.
"""
import bpy, sys, json, math, types, pathlib, importlib.util
from array import array
from mathutils import Matrix, Vector

CALLS, OUT = sys.argv[-2], pathlib.Path(sys.argv[-1])
ROOT = pathlib.Path(__file__).resolve().parents[3]
fail = 0


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


def floats(name):
    return [float(x) for x in blocks[name].split()]


def run(name, subject=None):
    text = blocks[name] if subject is None else blocks[name].replace("@SUBJECT@", subject)
    namespace = {"bpy": bpy}
    exec(compile(text, "<" + name + ">", "exec"), namespace)
    return namespace


def fresh():
    bpy.ops.wm.read_homefile(use_empty=True)


def near(a, b, tolerance=1e-4):
    return all(abs(x - y) <= tolerance * max(1.0, abs(y)) for x, y in zip(a, b))


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit` and records what the mirror hands it."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.pushed, self.displays, self.order = {}, {}, []
        self.selection, self.active = set(), None

    def sync_begin(self):
        self.pushed, self.displays, self.order = {}, {}, []

    def sync_push(self, name, kind, matrix, verts, normals, tris, selected, active, rgba):
        values = array('d')
        values.frombytes(matrix)
        self.pushed[name] = dict(kind=kind, verts=len(verts) // 12, tris=len(tris) // 12,
                                 selected=selected, active=active, matrix=list(values))
        self.order.append(name)

    def sync_display(self, name, kind, data, record):
        # bk_sync_display looks for the object just pushed.
        if not self.order or self.order[-1] != name:
            raise ValueError("a display for %s did not follow its object" % name)
        self.displays[name] = dict(type=kind, data=data, record=record)

    def sync_end(self):
        pass

    def mode(self):
        return "OBJECT"

    def set_mode(self, mode):
        pass

    def select_all(self, on=True):
        if not on:
            self.selection, self.active = set(), None

    def select(self, name, on=True):
        (self.selection.add if on else self.selection.discard)(name)

    def set_active(self, name):
        self.active = name or None

    def material_set(self, *args):
        pass

    def set_timeline(self, *args):
        pass


bridge = Bridge()
sys.modules["_blenderkit"] = bridge
# The module ships inside the app: no .pyc written beside it.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "_blenderkit_sync", ROOT / "Resources/python/site/_blenderkit_sync.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
sys.modules["_blenderkit_sync"] = sync


def fields(record):
    out = {}
    for pair in record.split(";"):
        key, sep, value = pair.partition("=")
        if sep:
            out[key] = value
    return out


def truth(obj):
    """What a record should say for an object, read from bpy directly."""
    scene = bpy.context.scene
    if obj.type == 'CAMERA':
        d, render = obj.data, scene.render
        return dict(type=d.type, lens=d.lens, sensor_fit=d.sensor_fit, sensor_width=d.sensor_width,
                    sensor_height=d.sensor_height, ortho_scale=d.ortho_scale, clip_start=d.clip_start,
                    clip_end=d.clip_end, shift_x=d.shift_x, shift_y=d.shift_y,
                    display_size=d.display_size, show_limits=d.show_limits,
                    focus_distance=d.dof.focus_distance,
                    aspect_x=render.resolution_x * render.pixel_aspect_x,
                    aspect_y=render.resolution_y * render.pixel_aspect_y,
                    scene_camera=scene.camera == obj)
    if obj.type == 'LIGHT':
        d = obj.data
        values = dict(type=d.type, color=tuple(d.color), energy=d.energy,
                      shadow_soft_size=d.shadow_soft_size, cutoff_distance=d.cutoff_distance,
                      shadow_buffer_clip_start=d.shadow_buffer_clip_start)
        if d.type == 'SPOT':
            values.update(spot_size=d.spot_size, spot_blend=d.spot_blend, show_cone=d.show_cone)
        if d.type == 'AREA':
            values.update(shape=d.shape, size=d.size, size_y=d.size_y)
        return values
    return dict(empty_display_type=obj.empty_display_type, empty_display_size=obj.empty_display_size)


def agrees(record, values):
    """Every value a record carries matches bpy's, and it carries them all."""
    got = fields(record)
    problems = [key for key in values if key not in got]
    for key, want in values.items():
        if key not in got:
            continue
        text = got[key]
        if isinstance(want, bool):
            same = text == ('1' if want else '0')
        elif isinstance(want, (int, float)):
            same = abs(float(text) - want) <= 1e-5 * max(1.0, abs(want))
        elif isinstance(want, tuple):
            same = near([float(c) for c in text.split(',')], want, 1e-5)
        else:
            same = text == want
        if not same:
            problems.append("%s=%s, bpy %r" % (key, text, want))
    return problems


print("headless, as on an iPad")
check("there is no 3D View area here, as there is none for bpy on a device",
      bpy.context.area is None, bpy.context.area)


print("\nthe mirror hands over what Blender draws them from")
fresh()
exec(compile(open(ROOT / "tests/camlight/scenario.py").read(), "scenario.py", "exec"), {"bpy": bpy})
sync.sync()
records = {name: dict(bridge.pushed[name], **bridge.displays[name])
           for name in bridge.pushed if name in bridge.displays}
json.dump(records, open(OUT / "records.json", "w"), indent=1)
displayed = [o for o in bpy.context.scene.objects if o.type in {'CAMERA', 'LIGHT', 'EMPTY'}]
check("every camera, light and empty is pushed with its display, straight after it",
      sorted(bridge.displays) == sorted(o.name for o in displayed), sorted(bridge.displays))
check("as one origin vertex and no triangles",
      all(bridge.pushed[o.name]["verts"] == 1 and bridge.pushed[o.name]["tris"] == 0 for o in displayed))
for o in displayed:
    problems = agrees(bridge.displays[o.name]["record"], truth(o))
    data = o.data.name if o.data is not None and o.type != 'EMPTY' else ''
    check("%s: the record is Blender's %s" % (o.name, o.type.lower()),
          not problems and bridge.displays[o.name]["data"] == data and bridge.displays[o.name]["type"] == o.type,
          problems)
# The scenario turns it off with `hide_viewport`: not drawn, and disabled in
# viewports, which the Outliner shows apart from the eye H closes.
check("a light disabled in viewports is still pushed, as hidden and disabled",
      bridge.pushed["Sun"]["kind"] == "LIGHT|hidden|disabled", bridge.pushed["Sun"]["kind"])
check("only the scene's camera is marked as it",
      [n for n, d in bridge.displays.items() if fields(d["record"]).get("scene_camera") == "1"] == ["Camera"])
check("the selection travels as for meshes",
      [n for n, p in bridge.pushed.items() if p["selected"]] == ["Empty.006"]
      and [n for n, p in bridge.pushed.items() if p["active"]] == ["Empty.006"])

bpy.ops.mesh.primitive_cube_add(location=(0, 0, -4))
lens = bpy.data.objects["Ortho"].data
cam = bpy.data.objects["Camera"]
cam.data.keyframe_insert("lens", frame=1)
cam.data.lens = 85.0
cam.data.keyframe_insert("lens", frame=21)
bpy.context.scene.frame_set(11)
sync.sync()
check("a mesh gets no display", "Cube" not in bridge.displays and bridge.pushed["Cube"]["tris"] == 12)
evaluated = cam.evaluated_get(bpy.context.evaluated_depsgraph_get()).data.lens
check("an animated lens is sent as it is on this frame",
      abs(float(fields(bridge.displays["Camera"]["record"])["lens"]) - evaluated) < 1e-4 and 35 < evaluated < 85,
      (fields(bridge.displays["Camera"]["record"])["lens"], evaluated))
target = bpy.data.objects["Empty"]
cam.data.dof.focus_object = target
bpy.context.view_layer.update()
sync.sync()
view = cam.matrix_world.col[2].to_3d().normalized()
expected = abs(view.dot(cam.matrix_world.translation - target.matrix_world.translation))
check("a focus object puts the focus where it is along the view",
      abs(float(fields(bridge.displays["Camera"]["record"])["focus_distance"]) - expected) < 1e-4, expected)
bpy.ops.object.empty_add(type='IMAGE')
picture = bpy.context.object
picture.data = bpy.data.images.new("Picture", 64, 32)
sync.sync()
check("an image empty's frame takes the image's proportions",
      fields(bridge.displays[picture.name]["record"]).get("image_aspect") == "1.0,0.5",
      bridge.displays[picture.name]["record"])
bpy.data.lights.remove(bpy.data.objects["Made Light"].data)
sync.sync()
# Measured in 5.2.1: removing the data-block takes the object with it — which
# the shim's bpy.data.lights.remove copies.
check("removing a light's data removes the light, and the pass goes on without it",
      "Made Light" not in bridge.pushed and "Camera" in bridge.displays)


print("\ncamera frames, for the overlay code to be held to")
frames = []
renders = [(1920, 1080, 1.0, 1.0), (1080, 1920, 1.0, 1.0), (1000, 1000, 1.0, 1.0),
           (1280, 720, 2.0, 1.0), (720, 1280, 1.0, 3.0)]
cases = [dict(), dict(lens=35.0), dict(sensor_fit='HORIZONTAL', sensor_width=24.0, sensor_height=36.0),
         dict(sensor_fit='VERTICAL'), dict(shift_x=0.2, shift_y=-0.1), dict(display_size=2.5, lens=85.0),
         dict(type='ORTHO', ortho_scale=4.0), dict(type='ORTHO', ortho_scale=9.0, shift_x=0.3, sensor_fit='VERTICAL'),
         dict(type='PANO')]
for rx, ry, px, py in renders:
    for case in cases:
        fresh()
        render = bpy.context.scene.render
        render.resolution_x, render.resolution_y, render.pixel_aspect_x, render.pixel_aspect_y = rx, ry, px, py
        bpy.ops.object.camera_add(location=(0.5, -1.0, 2.0), rotation=(0.4, 0.1, -0.7))
        obj = bpy.context.object
        obj.scale = (1.5, 1.5, 1.5)
        for key, value in case.items():
            setattr(obj.data, key, value)
        bpy.context.view_layer.update()
        sync.sync()
        corners = [tuple(v) for v in obj.data.view_frame(scene=bpy.context.scene)]
        # Camera.view_frame always measures at a draw size of 1
        # (BKE_camera_view_frame); the overlay draws at the display size
        # (overlay_camera.hh passes cam.drawsize), which scales a perspective
        # frame whole and an orthographic one only in depth. The overlay works
        # the frame out with the inverse of the object's scale and scales it
        # back: a perspective frame grows with the object, and an orthographic
        # one, whose width is ortho_scale in world units, does not.
        size = obj.data.display_size
        location, rotation, _ = obj.matrix_world.decompose()
        unscaled = Matrix.LocRotScale(location, rotation, None)
        if obj.data.type == 'ORTHO':
            drawn = [unscaled @ Vector((c[0], c[1], c[2] * size)) for c in corners]
        else:
            drawn = [obj.matrix_world @ (Vector(c) * size) for c in corners]
        frames.append(dict(label="%dx%d %g:%g %s" % (rx, ry, px, py, case or "defaults"),
                           record=bridge.displays[obj.name]["record"], data=bridge.displays[obj.name]["data"],
                           matrix=bridge.pushed[obj.name]["matrix"], view_frame=corners,
                           world_frame=[tuple(v) for v in drawn],
                           truth={k: v for k, v in truth(obj).items() if not isinstance(v, str)}))
json.dump(dict(frames=frames), open(OUT / "frames.json", "w"), indent=1)
check("%d frames from Blender's Camera.view_frame, with their records" % len(frames), len(frames) == 45)


print("\nAdd Camera, as the Add menu performs it")
axes = floats("ADD_CAMERA_AXES")
cursor = floats("CURSOR")
for start in ("OBJECT", "EDIT", "SCULPT"):
    fresh()
    bpy.ops.mesh.primitive_cube_add()
    bpy.ops.object.mode_set(mode=start)
    try:
        ns, error = run("ADD_CAMERA"), None
    except Exception as exc:
        ns, error = {}, str(exc)
    cameras = [o for o in bpy.data.objects if o.type == 'CAMERA']
    check("from %s: one camera, adjustable" % start,
          error is None and len(cameras) == 1 and ns.get("_bk_adjustable") is True, error or len(cameras))
    if cameras:
        c = cameras[0]
        m = c.matrix_world.to_3x3()
        columns = [m[row][column] for column in range(3) for row in range(3)]
        check("from %s: at the cursor" % start, near(c.location, cursor), tuple(c.location))
        check("from %s: facing the way the view faces" % start, near(columns, axes, 1e-4), (columns, axes))
        check("from %s: and made the scene's camera" % start, bpy.context.scene.camera == c)
fresh()
bpy.ops.object.camera_add()
first = bpy.context.object
bpy.context.scene.camera = first
run("ADD_CAMERA")
check("a camera added to a scene that has one leaves the scene's camera alone",
      bpy.context.scene.camera == first and len(bpy.data.cameras) == 2)
fresh()
run("ADD_CAMERA_LOG")
check("the line the Info log shows runs as it stands",
      len(bpy.data.cameras) == 1 and bpy.context.scene.camera is not None)
fresh()
run("ADD_CAMERA")
made = bpy.context.view_layer.objects.active.name
for _ in range(5):
    run("RERUN_CAMERA", subject=made)
    made = bpy.context.view_layer.objects.active.name
check("adjusting it five times leaves one camera and no orphaned camera data",
      len(bpy.data.objects) == 1 and len(bpy.data.cameras) == 1 and made == "Camera",
      ([o.name for o in bpy.data.objects], [c.name for c in bpy.data.cameras]))
check("at the adjusted location, still the scene's camera",
      near(bpy.data.objects[made].location, (0, 0, 3)) and bpy.context.scene.camera == bpy.data.objects[made])


print("\nAdd Light ▸ each type")
for kind in ('POINT', 'SUN', 'SPOT', 'AREA'):
    fresh()
    ns = run("ADD_LIGHT_" + kind)
    o = bpy.context.view_layer.objects.active
    check("%s: named %s, at the cursor, adjustable" % (kind.title(), kind.title()),
          o.name == kind.title() and o.data.type == kind and near(o.location, cursor)
          and ns.get("_bk_adjustable") is True, (o.name, tuple(o.location)))
fresh()
run("ADD_LIGHT_POINT")
run("RERUN_LIGHT_RADIUS", subject="Point")
check("adjusting the radius replaces the light and its data",
      [o.name for o in bpy.data.objects] == ["Point"] and len(bpy.data.lights) == 1,
      ([o.name for o in bpy.data.objects], [l.name for l in bpy.data.lights]))
run("RERUN_LIGHT_TYPE", subject="Point")
area = bpy.data.objects.get("Area")
check("adjusting the type makes the other kind, sized by the radius as Blender sizes it",
      area is not None and len(bpy.data.objects) == 1 and len(bpy.data.lights) == 1
      and abs(area.data.size - 2.0) < 1e-6, area and area.data.size)


print("\nAdd Empty ▸ each display type")
for kind in ('PLAIN_AXES', 'ARROWS', 'SINGLE_ARROW', 'CIRCLE', 'CUBE', 'SPHERE', 'CONE', 'IMAGE'):
    fresh()
    ns = run("ADD_EMPTY_" + kind)
    o = bpy.context.view_layer.objects.active
    check("%s: an empty of that type, at the cursor" % kind,
          o.type == 'EMPTY' and o.empty_display_type == kind and near(o.location, cursor)
          and ns.get("_bk_adjustable") is True, (o.type, o.empty_display_type))
fresh()
run("ADD_EMPTY_PLAIN_AXES")
run("RERUN_EMPTY", subject="Empty")
o = bpy.context.view_layer.objects.active
check("adjusting the type and radius", [x.name for x in bpy.data.objects] == ["Empty"]
      and o.empty_display_type == 'CUBE' and abs(o.empty_display_size - 0.25) < 1e-6,
      (o.empty_display_type, o.empty_display_size))


print("\nselected, moved, turned, scaled, deleted and duplicated")
fresh()
bpy.ops.object.light_add(type='POINT')
bpy.ops.object.camera_add()
cam = bpy.context.object
bpy.ops.object.select_all(action='DESELECT')
bpy.context.view_layer.objects.active = bpy.data.objects["Point"]
run("TAP_SELECT")
check("a tap selects the camera and makes it active",
      cam.select_get() and not bpy.data.objects["Point"].select_get()
      and bpy.context.view_layer.objects.active == cam)
check("and tells the interface", bridge.selection == {"Camera"} and bridge.active == "Camera",
      (bridge.selection, bridge.active))

start = floats("MOVE_CAMERA_START")
fresh()
bpy.ops.object.camera_add(location=start[:3], rotation=start[3:])
run("MOVE_CAMERA")
check("a camera moves where the drag's preview put it",
      near(bpy.context.object.location, floats("MOVE_CAMERA_EXPECT"), 2e-3),
      (tuple(bpy.context.object.location), floats("MOVE_CAMERA_EXPECT")))

start = floats("ROTATE_LIGHT_START")
fresh()
bpy.ops.object.light_add(type='POINT', location=start[:3], rotation=start[3:])
run("ROTATE_LIGHT")
bpy.context.view_layer.update()
m = bpy.context.object.matrix_world.to_3x3()
check("a light turns where the preview turned it",
      near([m[i][j] for i in range(3) for j in range(3)], floats("ROTATE_LIGHT_EXPECT"), 2e-3)
      and near(bpy.context.object.location, start[:3], 1e-4))

start = floats("SCALE_EMPTY_START")
fresh()
bpy.ops.object.empty_add(type='CUBE', location=start[:3], rotation=start[3:])
run("SCALE_EMPTY")
check("an empty scales along its own X as the preview showed",
      near(bpy.context.object.scale, floats("SCALE_EMPTY_EXPECT"), 2e-3),
      (tuple(bpy.context.object.scale), floats("SCALE_EMPTY_EXPECT")))

fresh()
bpy.ops.object.camera_add()
cam = bpy.context.object
cam.data.lens = 35.0
bpy.context.scene.camera = cam
run("DUPLICATE")
copy = bpy.context.object
check("Duplicate copies a camera, with a camera of its own",
      copy.name == "Camera.001" and copy.data.name == "Camera.001" and copy.data != cam.data
      and copy.data.lens == 35.0, (copy.name, copy.data.name))
run("DELETE")
check("Delete removes the selected copy and leaves the scene's camera",
      "Camera.001" not in bpy.data.objects and bpy.context.scene.camera == cam)
bpy.ops.object.select_all(action='DESELECT')
cam.select_set(True)
run("DELETE")
check("and deleting the scene's camera leaves the scene without one",
      len(bpy.data.objects) == 0 and bpy.context.scene.camera is None)

fresh()
bpy.ops.object.camera_add()
bpy.ops.object.light_add()
bpy.ops.object.empty_add()
run("BOX_SELECT")
check("a box select's Python selects a camera and a light",
      {o.name for o in bpy.context.selected_objects} == {"Camera", "Point"}
      and bpy.context.view_layer.objects.active.name == "Camera")

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
