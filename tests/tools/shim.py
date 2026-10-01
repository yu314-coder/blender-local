"""The simulator's side of snapping, the pivot and proportional editing, on
the Mac, against a model of the Swift the shim calls.

The simulator is not booted to check this. What is checked is the shim's
Python — Resources/python/site/bpy and _blenderkit_tools — and the calls it
makes: that `bpy.ops.transform.*` hands TransformOperation everything the
gizmo sends (the pivot, proportional editing, a view axis, a local scale)
rather than dropping it, that it refuses what it cannot model instead of doing
something else, and that the tool settings behave as Blender 5.2.1's do. What
the Swift does with the call is tests/tools/main.swift's.
"""
import contextlib
import io
import json
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
    """A model of the Swift the shim's bridge reaches."""

    def __init__(self):
        super().__init__("_blenderkit")
        self.objects = {}
        self.order = []
        self.active = None
        self.editing = False
        self.calls = []
        self.ops = []
        # TransformToolsMirror.scalars for Blender's factory settings: eleven
        # ints (Auto Merge off, Include Active and Non-edited on) and five
        # doubles (the merge threshold last, 0.001).
        self.tools = [0, 1, 0, 0, 3, 0, 0, 0, 0, 0, 3, 1.0, 0.0, 0.0, 0.0, 0.001]

    def add(self, name, location, selected=True):
        self.objects[name] = dict(location=list(location), rotation_euler=[0.0, 0.0, 0.0],
                                  scale=[1.0, 1.0, 1.0], selected=selected)
        self.order.append(name)
        if selected:
            self.active = name

    def object_names(self):
        return list(self.order)

    def is_selected(self, name):
        return self.objects[name]["selected"]

    def select(self, name, state):
        self.objects[name]["selected"] = bool(state)

    def active_name(self):
        return self.active

    def set_active(self, name):
        self.active = name or None

    def mode(self):
        return "EDIT" if self.editing else "OBJECT"

    def get_vec(self, name, prop):
        return tuple(self.objects[name][prop])

    def get_visible(self, name, which=2):
        return True

    def tool_state(self, *values):
        self.tools = list(values)

    def tool_state_get(self):
        return tuple(self.tools)

    def object_op(self, name, amount=0.0):
        self.ops.append((name, amount))
        return 0

    def transform_operator(self, call):
        self.calls.append(json.loads(call))
        return 1


app = App()
sys.modules["_blenderkit"] = app
import bpy  # noqa: E402  the shim, over the model
import _blenderkit_tools as tools  # noqa: E402


def refused(fn):
    """The exception a call raises, as text, or None."""
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - the point is what it says
            return "%s: %s" % (type(exc).__name__, exc)
    return None


def last():
    return app.calls[-1]


print("the stand-in's transforms carry what the gizmo sends")
app.add("A", (0, 0, 0))
# Exactly what TransformGizmo.python writes for each kind of drag.
bpy.ops.transform.translate(value=(0.25, 0.0, 0.0), constraint_axis=(True, False, False),
                            use_proportional_edit=True, proportional_edit_falloff='SHARP',
                            proportional_size=3.00000, use_proportional_connected=True)
check("a move, with proportional editing",
      last() == {"kind": "translate", "value": [0.25, 0.0, 0.0], "orientation": "GLOBAL",
                 "center": None,
                 "proportional": {"falloff": "SHARP", "size": 3.0, "connected": True}}, last())
bpy.ops.transform.rotate(value=0.5, orient_axis='X', center_override=(1.0, 2.0, 3.0))
check("a turn about a world axis, about the pivot it names — not in place",
      last()["axis"] == [1.0, 0.0, 0.0] and last()["value"] == [0.5]
      and last()["center"] == [1.0, 2.0, 3.0] and last()["proportional"] is None, last())
bpy.ops.transform.rotate(value=0.3, orient_axis='Z', orient_type='VIEW',
                         orient_matrix=((1, 0, 0), (0, 0, -1), (0, 1, 0)),
                         orient_matrix_type='VIEW', center_override=(0.0, 0.0, 0.0))
check("a turn about the view: the orientation's Z row is the axis",
      last()["axis"] == [0.0, 1.0, 0.0], last())
bpy.ops.transform.resize(value=(2.0, 1.0, 1.0), constraint_axis=(True, False, False),
                         orient_type='LOCAL', center_override=(4.6667, 0.0, 0.0))
check("a scale along each object's own axes, about the pivot",
      last()["orientation"] == "LOCAL" and last()["center"] == [4.6667, 0.0, 0.0]
      and last()["value"] == [2.0, 1.0, 1.0], last())
bpy.ops.transform.translate(value=(1, 2, 3), orient_type='VIEW',
                            orient_matrix=((0, 1, 0), (-1, 0, 0), (0, 0, 1)))
check("a move in a view orientation, turned into world space",
      last()["value"] == [-2.0, 1.0, 3.0], last())

print("\nit refuses what it cannot model, rather than doing something else")
before = len(app.calls)
check("a mirrored transform",
      "mirror=True" in (refused(lambda: bpy.ops.transform.translate(value=(1, 0, 0), mirror=True)) or ""))
check("a normal orientation",
      "NORMAL" in (refused(lambda: bpy.ops.transform.rotate(value=1, orient_type='NORMAL')) or ""))
check("a local turn, which Blender takes per object",
      "LOCAL" in (refused(lambda: bpy.ops.transform.rotate(value=1, orient_type='LOCAL')) or ""))
check("a view orientation it was not given",
      "orient_matrix" in (refused(lambda: bpy.ops.transform.rotate(value=1, orient_type='VIEW')) or ""))
check("snapping, which a headless Blender does not do either",
      "snap=True" in (refused(lambda: bpy.ops.transform.translate(value=(1, 0, 0), snap=True)) or ""))
check("and a name Blender's operator has not got, as Blender refuses it",
      "TypeError" in (refused(lambda: bpy.ops.transform.translate(value=(1, 0, 0), wobble=1)) or ""))
check("none of which reached the scene", len(app.calls) == before)
# The Mesh menu's edge tools slide along, and write to, edges the stand-in's
# triangles do not keep; each says which it is instead of AttributeError.
for name, call in (("edge slide", lambda: bpy.ops.transform.edge_slide(value=0.5)),
                   ("vertex slide", lambda: bpy.ops.transform.vert_slide(value=0.5)),
                   ("edge attributes", lambda: bpy.ops.transform.edge_crease(value=1)),
                   ("edge attributes", lambda: bpy.ops.transform.edge_bevelweight(value=1)),
                   ("edge loops", lambda: bpy.ops.mesh.select_edge_loop_multi()),
                   ("connecting vertices", lambda: bpy.ops.mesh.vert_connect_path()),
                   ("offset edge loops",
                    lambda: bpy.ops.mesh.offset_edge_loops_slide(TRANSFORM_OT_edge_slide={"value": 0.5}))):
    said = refused(call) or ""
    check("the edge tools: " + name, said.startswith("NotImplementedError") and name in said, said)
check("and the selection count their leads read", "NotImplementedError: counting selected edges"
      in (refused(lambda: bpy.Mesh("A").total_edge_sel) or ""))
check("none of which reached the scene either", len(app.calls) == before)
# Every argument at its default, as the operator catalogue sends them.
bpy.ops.transform.translate(
    value=(0, 0, 1), orient_type='GLOBAL', orient_matrix=((1, 0, 0), (0, 1, 0), (0, 0, 1)),
    orient_matrix_type='GLOBAL', constraint_axis=(False, False, False), mirror=False,
    use_proportional_edit=False, proportional_edit_falloff='SMOOTH', proportional_size=1,
    use_proportional_connected=False, use_proportional_projected=False, snap=False,
    snap_elements={'INCREMENT'}, use_snap_project=False, snap_target='CLOSEST', use_snap_self=True,
    use_snap_edit=True, use_snap_nonedit=True, use_snap_selectable=False, snap_point=(0, 0, 0),
    snap_align=False, snap_normal=(0, 0, 0), gpencil_strokes=False, cursor_transform=False,
    texture_space=False, remove_on_cancel=False, use_duplicated_keyframes=False,
    view2d_edge_pan=False, release_confirm=False, use_accurate=False,
    use_automerge_and_split=False, translate_origin=False)
check("while every argument at its default is accepted",
      len(app.calls) == before + 1 and last()["value"] == [0.0, 0.0, 1.0], last())

print("\nthe tool settings answer as Blender 5.2.1's do")
ts = bpy.context.scene.tool_settings
ts.snap_elements_base = {'VERTEX'}
ts.snap_elements_base = set()
check("assigning set() leaves snap_elements_base as it was, as measured",
      ts.snap_elements_base == {'VERTEX'}, ts.snap_elements_base)
ts.snap_elements_individual = {'FACE_PROJECT'}
ts.snap_elements_base = set()
check("but takes it while the individual set holds something, as measured",
      ts.snap_elements_base == set() and ts.snap_elements_individual == {'FACE_PROJECT'},
      (ts.snap_elements_base, ts.snap_elements_individual))
ts.snap_elements_individual = set()
check("and the individual set cannot then be emptied, as measured",
      ts.snap_elements_individual == {'FACE_PROJECT'}, ts.snap_elements_individual)
ts.snap_elements_base = {'INCREMENT'}
ts.snap_elements_individual = set()
check("the two back to the factory's", ts.snap_elements_base == {'INCREMENT'}
      and ts.snap_elements_individual == set())
check("Auto Merge and its threshold at the factory's",
      ts.use_mesh_automerge is False and abs(ts.double_threshold - 0.001) < 1e-9,
      (ts.use_mesh_automerge, ts.double_threshold))
ts.use_mesh_automerge = True
ts.double_threshold = 7
check("written through the one tool state, the threshold clamped to bl_rna's 0..1",
      ts.use_mesh_automerge is True and ts.double_threshold == 1.0
      and app.tools[9] == 1 and app.tools[15] == 1.0, app.tools)
ts.use_mesh_automerge = False
ts.double_threshold = 0.001
check("Include Active and Non-edited on, as the factory has them",
      ts.use_snap_self is True and ts.use_snap_nonedit is True and app.tools[10] == 3, app.tools)
ts.use_snap_nonedit = False
check("one bit each", ts.use_snap_self is True and ts.use_snap_nonedit is False and app.tools[10] == 1,
      app.tools)
ts.use_snap_nonedit = True
check("and nothing else moved", app.tools == [0, 1, 0, 0, 3, 0, 0, 0, 0, 0, 3, 1.0, 0.0, 0.0, 0.0, 0.001],
      app.tools)
for bit, name in ((4, 'use_mesh_automerge_and_split'), (8, 'use_transform_skip_children'),
                  (16, 'use_transform_data_origin')):
    setattr(ts, name, True)
    check(name + " is bit %d of the same int, as _blenderkit_tools packs it" % bit,
          getattr(ts, name) is True and app.tools[10] == 3 | bit, app.tools[10])
    setattr(ts, name, False)
# The stand-in's transform moves whole objects and welds vertices only, so a
# setting it would not honour is refused rather than run as something else.
ts.use_transform_data_origin = True
check("a move with Affect Only Origins on is refused in object mode",
      "use_transform_data_origin" in (refused(lambda: bpy.ops.transform.translate(value=(1, 0, 0))) or ""))
ts.use_transform_data_origin = False
check("and runs again with it off", refused(lambda: bpy.ops.transform.translate(value=(1, 0, 0))) is None)

print("\nthe Snap menu's new actions reach the stand-in's operators")
for action, op in (("SELECTED_TO_ACTIVE", "snap_selected_to_active"),
                   ("CURSOR_TO_GRID", "snap_cursor_to_grid"),
                   ("CURSOR_TO_ACTIVE", "snap_cursor_to_active")):
    app.ops.clear()
    tools.snap(action, step=0.5)
    check("%s runs %s" % (action, op), app.ops and app.ops[0][0] == op, app.ops)
app.ops.clear()
tools.snap("CURSOR_TO_GRID", step=0.5)
check("and Cursor to Grid carries the viewport's step", app.ops == [("snap_cursor_to_grid", 0.5)], app.ops)
check("in Blender's order",
      tools.SNAP_ACTIONS == ('SELECTED_TO_GRID', 'SELECTED_TO_CURSOR', 'SELECTED_TO_ACTIVE',
                             'CURSOR_TO_SELECTED', 'CURSOR_TO_CENTER', 'CURSOR_TO_GRID',
                             'CURSOR_TO_ACTIVE'))

print("\nIndividual Origins with proportional editing, in the simulator")
app.calls.clear()
app.objects.clear()
app.order.clear()
app.add("A", (0, 0, 0))
app.add("B", (3, 0, 0))
app.add("C", (1, 0, 0), selected=False)
app.add("D", (1.5, 1, 0), selected=False)
app.add("E", (9, 0, 0), selected=False)
tools.transform_individual('RESIZE', value=(2.0, 2.0, 2.0), constraint_axis=(False, False, False),
                           orient_type='LOCAL', use_proportional_edit=True,
                           proportional_edit_falloff='LINEAR', proportional_size=2.0)
calls = app.calls
check("one call per selected object at full strength, about its own origin, with no proportional",
      [c["center"] for c in calls[:2]] == [[0.0, 0.0, 0.0], [3.0, 0.0, 0.0]]
      and all(c["value"] == [2.0, 2.0, 2.0] and c["proportional"] is None for c in calls[:2]),
      calls[:2])
check("then each neighbour in reach, in place, by its share: C 1.5, D 1.0986",
      len(calls) == 4 and calls[2]["center"] == [1.0, 0.0, 0.0] and abs(calls[2]["value"][0] - 1.5) < 1e-9
      and calls[3]["center"] == [1.5, 1.0, 0.0] and abs(calls[3]["value"][0] - 1.0986122886681098) < 1e-6,
      calls[2:])
check("and the selection comes back as it was, the neighbours unselected",
      [n for n in app.order if app.objects[n]["selected"]] == ["A", "B"],
      [n for n in app.order if app.objects[n]["selected"]])

print("\nShow/Hide and the Object menu's other rows, in the simulator")
app.ops.clear()
# The model hides nothing, so both answer CANCELLED, as Blender does.
check("Hide Unselected passes its flag on", bpy.ops.object.hide_view_set(unselected=True) == {"CANCELLED"}
      and app.ops[-1] == ("hide_view_set", 1.0), app.ops)
check("Show Hidden without selecting passes that on", bpy.ops.object.hide_view_clear(select=False) == {"CANCELLED"}
      and app.ops[-1] == ("hide_view_clear", 0.0), app.ops)
counted = app.object_op
app.object_op = lambda name, amount=0.0: 2
check("with something hidden, FINISHED", bpy.ops.object.hide_view_set() == {"FINISHED"})
app.object_op = counted
asked = []
app.get_visible = lambda name, which=2: asked.append(which) or True
obj = bpy.data.objects["A"]
check("hide_get asks for the view layer's flag, hide_viewport for Disable in Viewports",
      obj.hide_get() is False and obj.hide_viewport is False and asked == [1, 0], asked)
import _blenderkit_context  # noqa: E402
hidden = []


def hide_through_the_view():
    with _blenderkit_context.temp_override_view3d("Hide Selected"):
        hidden.append(bpy.ops.object.hide_view_set(unselected=False))


check("the 3D View the rows borrow is not needed in the stand-in", refused(hide_through_the_view) is None
      and hidden, refused(hide_through_the_view))
for call in (bpy.ops.object.shade_auto_smooth, bpy.ops.object.shade_smooth_by_angle,
             bpy.ops.object.quadriflow_remesh, bpy.ops.object.text_add,
             bpy.ops.curve.primitive_bezier_curve_add, bpy.ops.curve.primitive_bezier_circle_add,
             bpy.ops.mesh.hide, bpy.ops.mesh.reveal, bpy.ops.mesh.separate,
             # Round 3's Object and Mesh rows the stand-in cannot model.
             bpy.ops.object.duplicate_move_linked, bpy.ops.object.parent_set,
             bpy.ops.object.parent_clear, bpy.ops.object.convert, bpy.ops.transform.shear,
             bpy.ops.mesh.split, bpy.ops.mesh.edge_split, bpy.ops.mesh.dissolve_limited,
             bpy.ops.mesh.delete_loose, bpy.ops.mesh.fill_holes, bpy.ops.mesh.unsubdivide,
             bpy.ops.mesh.beautify_fill):
    error = refused(call)
    check("%s says it needs the real bpy, not AttributeError" % call.__name__,
          error is not None and error.startswith("NotImplementedError"), error)
# Object > Convert > Curve reads every loop's edge at once to find loose
# edges; the stand-in says it cannot, rather than AttributeError.
error = refused(lambda: bpy._Elements(4, "MeshLoop").foreach_get("edge_index", []))
check("foreach_get on a mesh's elements says it needs the real bpy, not AttributeError",
      error is not None and error.startswith("NotImplementedError") and "real bpy" in error, error)
import _blenderkit_context  # noqa: E402,F811
check("the Essentials library the Auto Smooth row asks after is not here, so the row is greyed out",
      _blenderkit_context.essentials_available() is False)
check("the selection Auto Smooth's refusal reads is the selection",
      [o.name for o in bpy.context.selected_editable_objects]
      == [n for n in app.order if app.objects[n]["selected"]],
      [o.name for o in bpy.context.selected_editable_objects])

check("Inset Individual is refused rather than inset as one region",
      (refused(lambda: bpy.ops.mesh.inset(thickness=0.1, use_individual=True)) or "").startswith("NotImplementedError"),
      refused(lambda: bpy.ops.mesh.inset(thickness=0.1, use_individual=True)))

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
