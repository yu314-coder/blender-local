"""The app's names, held to Blender itself (desktop 5.2.1).

The rows are what tests/names/main.swift prints: every label, operator, redo
panel title and undo step name the app builds from its tables. In a Blender
with the app's context — its undo history (`_blenderkit_undo`), gpu.init(),
its modules — this checks:

  * each redo panel's title is its operator's name (`get_rna_type().name`),
    which is what Blender's Adjust Last Operation panel shows;
  * each undo step the app records is the step Blender's own undo history
    records for the same call: the operator run with its undo on (a bpy.ops
    call's second argument, which is how a button's call pushes its step),
    the step read back with `print_undo_steps` (`_blenderkit_undo.blender_steps`);
  * each enum the app names a choice of — modes, the pivot point, snapping,
    proportional falloff, Separate, Set Origin, handle types, Lattice ▸ Flip,
    lights, empties, modifiers, render engines — by the enum item's name;
  * the sculpt brushes the simulator's section names are Essentials brushes.

Operators that poll for a 3D View are not run with their undo on here:
called that way under the borrowed startup 3D View
(`_blenderkit_context.temp_override_view3d`) Blender 5.2.1 crashes in
`ED_area_type_hud_ensure`, building the redo panel for a region the
background session never drew (measured with hide_view_set, camera_to_view,
object_as_camera and snap_selected_to_grid; the app never calls an operator
with its undo on there). Their step is held to the operator's name, which is
what every step measured here turned out to be.

A check that cannot fail checks nothing: the first section runs the same
comparisons on names the app used to have, which must fail.
"""
import bpy, bmesh, gpu, sys, os, json, importlib.util, pathlib, types

# Nothing here may reach a browser or another program.
import webbrowser, subprocess
def _blocked(*a, **k):
    raise RuntimeError("blocked: no browser or subprocess in this check")
webbrowser.open = webbrowser.open_new = webbrowser.open_new_tab = _blocked
subprocess.Popen = subprocess.run = subprocess.call = subprocess.check_output = _blocked
os.system = _blocked

sys.dont_write_bytecode = True
ROWS, WORK = sys.argv[-2], sys.argv[-1]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / "Resources" / "python" / "site"
rows = json.load(open(ROWS))
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)), flush=True)
    if not ok:
        fail += 1


def load(name):
    spec = importlib.util.spec_from_file_location(name, SITE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class _BK(types.ModuleType):
    """The app's C module, which a desktop Blender has not got: each entry
    point records nothing; this is Blender's main thread."""
    def is_main_thread(self):
        return True

    def __getattr__(self, name):
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


sys.modules['_blenderkit'] = _BK('_blenderkit')
context = load("_blenderkit_context")
for module in ("_blenderkit_texpaint", "_blenderkit_anim", "_blenderkit_tools"):
    load(module)
load("_blenderkit_sync")
undo = load("_blenderkit_undo")
for module in ("_blenderkit_knife", "_blenderkit_multires", "_blenderkit_sculpt"):
    load(module)
gpu.init()
HISTORY = os.path.join(WORK, "history")


def op_name(idname):
    module, name = idname.split(".")
    return getattr(getattr(bpy.ops, module), name).get_rna_type().name


def enum_names(owner, prop):
    return {i.identifier: i.name for i in owner.bl_rna.properties[prop].enum_items}


def of(kind):
    return [r for r in rows if r["kind"] == kind]


# --------------------------------------------------------------------------
print("\nThe checks can fail: names the app used to have")

check("Tris to Quads is not tris_convert_to_quads' name", op_name("mesh.tris_convert_to_quads") != "Tris to Quads",
      op_name("mesh.tris_convert_to_quads"))
check("Merge at Center is not mesh.merge's", op_name("mesh.merge") != "Merge at Center")
check("Select Edge Loops is not select_edge_loop_multi's", op_name("mesh.select_edge_loop_multi") != "Select Edge Loops")
check("Toggle Edit Mode is not editmode_toggle's in 5.2.1", op_name("object.editmode_toggle") != "Toggle Edit Mode",
      op_name("object.editmode_toggle"))

# --------------------------------------------------------------------------
print("\nEach redo panel's title is its operator's name")

for row in rows:
    if row.get("name") and row.get("call") and row["kind"] in ("mesh", "operator", "add", "select-mesh",
                                                                 "select-object", "select-loops", "select-pick",
                                                                 "menu-row", "object-row", "collection-row",
                                                                 "local-view", "constraint-op"):
        try:
            want = op_name(row["call"])
        except (AttributeError, KeyError) as error:
            check(f"{row['label']}: {row['call']} exists", False, error)
            continue
        check(f"{row['label']} ({row['call']}): {row['name']}", row["name"] == want, want)

# --------------------------------------------------------------------------
print("\nEach redo panel field is named as its property is")

# Blender's Adjust Last Operation draws an operator's properties by their RNA
# names. Round 4's review found four of the app's rows named otherwise
# (Bisect's Plane Normal was "Axis", Edge Rings' Edge Ring Delimit
# "Delimit", Slide Vertices' Slide Direction "Direction", Shear's Axis
# "Axes"). A vector's rows are its components (X, Y, Z); a macro's are its
# operators' — Extrude's Offset is Shrink/Fatten's `value`.
FIELD_EXCEPTIONS = {
    # One row for Blender's two, Axis and Axis Ortho, so that no choice
    # pairs an axis with itself ("Along X, by Y", ...).
    ("transform.shear", "orient_axis"): "Axes",
}


def field_names(idname):
    """{key: name} for an operator's properties and, for a macro, its
    operators' (`TRANSFORM_OT_shrink_fatten` -> its `value`'s name)."""
    rna_type = getattr(getattr(bpy.ops, idname.split(".")[0]), idname.split(".")[1]).get_rna_type()
    names = {p.identifier: p.name for p in rna_type.properties}
    for p in rna_type.properties:
        if p.type == 'POINTER' and "_OT_" in p.identifier:
            sub = p.fixed_type.properties
            names.update({q.identifier: q.name for q in sub if q.identifier not in names})
            if "value" in sub:
                names[p.identifier] = sub["value"].name
    return names


compared = 0
for row in rows:
    parameters = (row.get("extra") or {}).get("parameters")
    if not parameters or not row.get("call") or row["kind"] == "operator" and row["label"] == "Knife":
        # The Knife's fields are knife_project's (Cut Through), which it runs.
        continue
    names = field_names(row["call"])
    for pair in parameters.split("|"):
        key, _, label = pair.partition("=")
        if "." in key or "[" in key:
            check(f"{row['call']} {key}: a vector's component, {label}", label in ("X", "Y", "Z", "W"), label)
            continue
        want = FIELD_EXCEPTIONS.get((row["call"], key)) or names.get(key)
        compared += 1
        check(f"{row['label']} ({row['call']}): the field {key} is {want!r}", label == want, label)
check(f"the redo panels' fields compared ({compared})", compared > 100, compared)
for (idname, key), label in FIELD_EXCEPTIONS.items():
    check(f"the exception {idname} {key} is still the app's row ({label!r}, Blender's {field_names(idname)[key]!r})",
          any(f"{key}={label}" in ((r.get('extra') or {}).get('parameters') or '').split('|')
              for r in rows if r.get('call') == idname))

# --------------------------------------------------------------------------
print("\nEach undo step the app records is the one Blender's history records")


def scene(edit=None):
    """Startup scene, a sphere parented to the cube, the cube active and
    selected; in Edit Mode with `edit` selected (ALL, EDGE, NONE)."""
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.wm.read_homefile(load_ui=False)
    bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
    bpy.context.object.parent = bpy.data.objects['Cube']
    cube = bpy.data.objects['Cube']
    bpy.context.view_layer.objects.active = cube
    cube.select_set(True)
    if edit:
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_mode(type='VERT')
        bpy.ops.mesh.select_all(action='SELECT' if edit == 'ALL' else 'DESELECT')
        if edit == 'EDGE':
            bm = bmesh.from_edit_mesh(cube.data)
            bm.edges.ensure_lookup_table()
            bm.select_mode = {'EDGE'}
            bm.edges[0].select = True
            bm.select_flush_mode()
            bmesh.update_edit_mesh(cube.data)
    undo.push(HISTORY, "before")


def active_step():
    steps = undo.blender_steps() or []
    active = [s for s in steps if s[3]]
    return active[-1][2] if active else None


def measured(setup, call):
    """The step Blender pushes for `call`, run with its undo on."""
    setup()
    before = active_step()
    result = call()
    after = active_step()
    return after if after != before and 'FINISHED' in result else None


obj_file = os.path.join(WORK, "triangle.obj")
with open(obj_file, "w") as f:
    f.write("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")

ops = bpy.ops
CASES = {
    # idname: (setup, the call with its undo on)
    "object.select_all": (lambda: scene(), lambda: ops.object.select_all('EXEC_DEFAULT', True, action='SELECT')),
    "mesh.select_all": (lambda: scene('ALL'), lambda: ops.mesh.select_all('EXEC_DEFAULT', True, action='INVERT')),
    "object.editmode_toggle": (lambda: scene(), lambda: ops.object.editmode_toggle('EXEC_DEFAULT', True)),
    "object.mode_set:EDIT": (lambda: scene(), lambda: ops.object.mode_set('EXEC_DEFAULT', True, mode='EDIT')),
    "object.mode_set:OBJECT": (lambda: scene('ALL'), lambda: ops.object.mode_set('EXEC_DEFAULT', True, mode='OBJECT')),
    "sculpt.sculptmode_toggle": (lambda: scene(), lambda: ops.object.mode_set('EXEC_DEFAULT', True, mode='SCULPT')),
    "mesh.duplicate_move": (lambda: scene('ALL'), lambda: ops.mesh.duplicate_move('EXEC_DEFAULT', True)),
    "object.duplicate_move": (lambda: scene(), lambda: ops.object.duplicate_move('EXEC_DEFAULT', True)),
    "object.delete": (lambda: scene(), lambda: ops.object.delete('EXEC_DEFAULT', True)),
    "mesh.delete": (lambda: scene('ALL'), lambda: ops.mesh.delete('EXEC_DEFAULT', True, type='VERT')),
    "mesh.separate": (lambda: scene('EDGE'), lambda: ops.mesh.separate('EXEC_DEFAULT', True, type='SELECTED')),
    "object.shade_smooth": (lambda: scene(), lambda: ops.object.shade_smooth('EXEC_DEFAULT', True)),
    "object.shade_flat": (lambda: scene(), lambda: ops.object.shade_flat('EXEC_DEFAULT', True)),
    "mesh.mark_seam": (lambda: scene('EDGE'), lambda: ops.mesh.mark_seam('EXEC_DEFAULT', True, clear=True)),
    "mesh.mark_sharp": (lambda: scene('EDGE'), lambda: ops.mesh.mark_sharp('EXEC_DEFAULT', True, clear=True)),
    "transform.translate": (lambda: scene(), lambda: ops.transform.translate('EXEC_DEFAULT', True, value=(1, 0, 0))),
    "transform.rotate": (lambda: scene(), lambda: ops.transform.rotate('EXEC_DEFAULT', True, value=0.3)),
    "transform.resize": (lambda: scene(), lambda: ops.transform.resize('EXEC_DEFAULT', True, value=(2, 2, 2))),
    "mesh.hide": (lambda: scene('ALL'), lambda: ops.mesh.hide('EXEC_DEFAULT', True, unselected=False)),
    "mesh.reveal": (lambda: scene('ALL'), lambda: ops.mesh.reveal('EXEC_DEFAULT', True)),
    "object.modifier_add": (lambda: scene(), lambda: ops.object.modifier_add('EXEC_DEFAULT', True, type='SUBSURF')),
    "mesh.extrude_region_shrink_fatten": (lambda: scene('ALL'),
                                          lambda: ops.mesh.extrude_region_shrink_fatten('EXEC_DEFAULT', True)),
    "mesh.extrude_faces_move": (lambda: scene('ALL'), lambda: ops.mesh.extrude_faces_move('EXEC_DEFAULT', True)),
    "mesh.select_edge_loop_multi": (lambda: scene('EDGE'), lambda: ops.mesh.select_edge_loop_multi('EXEC_DEFAULT', True)),
    "mesh.subdivide_edgering": (lambda: scene('EDGE'), lambda: ops.mesh.subdivide_edgering('EXEC_DEFAULT', True)),
    "mesh.tris_convert_to_quads": (lambda: scene('ALL'), lambda: ops.mesh.tris_convert_to_quads('EXEC_DEFAULT', True)),
    "mesh.vertices_smooth": (lambda: scene('ALL'), lambda: ops.mesh.vertices_smooth('EXEC_DEFAULT', True)),
    "mesh.edge_face_add": (lambda: scene('ALL'), lambda: ops.mesh.edge_face_add('EXEC_DEFAULT', True)),
    "mesh.merge": (lambda: scene('ALL'), lambda: ops.mesh.merge('EXEC_DEFAULT', True, type='CENTER')),
    "transform.vert_slide": (lambda: scene('EDGE'), lambda: ops.transform.vert_slide('EXEC_DEFAULT', True, value=0.1)),
    "mesh.quads_convert_to_tris": (lambda: scene('ALL'), lambda: ops.mesh.quads_convert_to_tris('EXEC_DEFAULT', True)),
    "object.parent_clear": (lambda: scene(), lambda: ops.object.parent_clear('EXEC_DEFAULT', True)),
    "object.select_hierarchy": (lambda: scene(), lambda: ops.object.select_hierarchy('EXEC_DEFAULT', True,
                                                                                     direction='CHILD')),
    "object.select_by_type": (lambda: scene(), lambda: ops.object.select_by_type('EXEC_DEFAULT', True, type='MESH')),
    "object.select_pattern": (lambda: scene(), lambda: ops.object.select_pattern('EXEC_DEFAULT', True, pattern='C*')),
    "object.select_camera": (lambda: scene(), lambda: ops.object.select_camera('EXEC_DEFAULT', True)),
    "object.origin_set": (lambda: scene(), lambda: ops.object.origin_set('EXEC_DEFAULT', True, type='ORIGIN_GEOMETRY')),
    "object.transform_apply": (lambda: scene(), lambda: ops.object.transform_apply('EXEC_DEFAULT', True, location=True,
                                                                                  rotation=False, scale=False)),
    "object.vertex_group_add": (lambda: scene(), lambda: ops.object.vertex_group_add('EXEC_DEFAULT', True)),
    "object.shape_key_add": (lambda: scene(), lambda: ops.object.shape_key_add('EXEC_DEFAULT', True, from_mix=True)),
    "object.join": (lambda: scene(), lambda: ops.object.join('EXEC_DEFAULT', True)),
    "object.add": (lambda: scene(), lambda: ops.object.add('EXEC_DEFAULT', True, type='LATTICE')),
    "wm.obj_import": (lambda: scene(), lambda: ops.wm.obj_import('EXEC_DEFAULT', True, filepath=obj_file)),
}
steps = {}
for key, (setup, call) in CASES.items():
    try:
        steps[key] = measured(setup, call)
    except Exception as error:
        steps[key] = f"ERROR {type(error).__name__}: {error}"
for key, step in steps.items():
    check(f"{key} records a step of its own: {step}", step is not None and not str(step).startswith("ERROR"), step)
# The negative control: the labels the app used to record are not these.
for key, old in (("object.select_all", "Select All"), ("mesh.select_all", "Invert Selection"),
                 ("object.editmode_toggle", "Toggle Edit Mode"), ("mesh.duplicate_move", "Duplicate"),
                 ("wm.obj_import", "Import Model"), ("mesh.tris_convert_to_quads", "Tris to Quads")):
    check(f"the old step {old!r} is not what Blender records for {key} ({steps.get(key)!r})", steps.get(key) != old)

# The app's label for each of those calls, every one read from the dump: the
# 3D View's own steps are UndoStep's (`view-step` rows), the gizmo's its
# LastOperator's, Show/Hide's Bpy.ShowHide's. Round 4's review found sixteen
# of these typed in here, so a label changed in the app failed nothing.
app_steps = {}
for row in rows:
    if row.get("undo") and row.get("call"):
        app_steps.setdefault(row["call"], set()).add(row["undo"])
for key, step in steps.items():
    labels = app_steps.get(key)
    if not labels:
        check(f"the app names a step for {key}", False, "no label in the dump")
        continue
    check(f"{key}: the app's step {sorted(labels)} is Blender's {step!r}", labels == {step}, labels)

# The script that measures these in the app (tests/names/app_steps.py, run
# there through -eval64): its own scene and the app's script context — a
# window and its screen, no area — here, where it has to measure exactly what
# the calls above did. Its JSON is what app_steps_compare.py holds the app's
# labels to.
spec = importlib.util.spec_from_file_location("app_steps", ROOT / "tests" / "names" / "app_steps.py")
app_steps_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app_steps_module)
app_steps_module.OUT = os.path.join(WORK, "app-steps.json")
objects_before = sorted(o.name for o in bpy.data.objects)
in_app_context = app_steps_module.run()
check(f"app_steps.py measures {len(in_app_context)} of these calls", len(in_app_context) >= 40,
      len(in_app_context))
for key, step in in_app_context.items():
    check(f"app_steps.py, window and screen: {key} is {step!r}, as measured above", step == steps.get(key),
          steps.get(key))
check("and it leaves the scene's objects as it found them",
      sorted(o.name for o in bpy.data.objects) == objects_before,
      sorted(set(o.name for o in bpy.data.objects) ^ set(objects_before)))

# The view-polling operators, held to their names (see the docstring).
for row in of("snap"):
    want = {"Selection to Grid": "view3d.snap_selected_to_grid", "Selection to Cursor": "view3d.snap_selected_to_cursor",
            "Selection to Cursor (Keep Offset)": "view3d.snap_selected_to_cursor",
            "Selection to Active": "view3d.snap_selected_to_active", "Cursor to Selected": "view3d.snap_cursor_to_selected",
            "Cursor to World Origin": "view3d.snap_cursor_to_center", "Cursor to Grid": "view3d.snap_cursor_to_grid",
            "Cursor to Active": "view3d.snap_cursor_to_active"}[row["label"]]
    check(f"Snap ▸ {row['label']}'s step is {want}'s name", row["undo"] == op_name(want), (row["undo"], op_name(want)))
for row in of("showhide"):
    if row["extra"]["editing"] == "false":
        want = op_name("object.hide_view_clear" if row["label"] == "Show Hidden Objects" else "object.hide_view_set")
        check(f"Show/Hide ▸ {row['label']}'s step is {want}", row["undo"] == want, row["undo"])
for row in of("region"):
    check(f"{row['label']} is {row['call']}'s name", row["undo"] == op_name(row["call"]))
for row in of("groups") + of("points") + of("uv") + of("import") + of("sculpt-step") + of("step"):
    if row["call"] in ("sculpt.brush_stroke",):
        continue
    if row["kind"] in ("uv",):
        # The UV menu's rows are named after their labels: Unwrap's three
        # methods are one operator.
        continue
    check(f"{row['label']}: the step {row['undo']!r} is {row['call']}'s name", row["undo"] == op_name(row["call"]),
          op_name(row["call"]))
for row in of("select-object"):
    check(f"Select ▸ {row['label']}: {row['undo']}", row["undo"] == op_name(row["call"]))

# --------------------------------------------------------------------------
print("\nEach choice is named by its enum item")

ts = bpy.types.ToolSettings
ENUMS = {
    "mode": enum_names(bpy.types.Object, "mode"),
    "pivot": enum_names(ts, "transform_pivot_point"),
    "snap-element": enum_names(ts, "snap_elements_base"),
    "snap-individual": enum_names(ts, "snap_elements_individual"),
    "snap-target": enum_names(ts, "snap_target"),
    "falloff": enum_names(ts, "proportional_edit_falloff"),
    "select-mode": {i.identifier: i.name for i in
                    ops.mesh.select_mode.get_rna_type().properties['type'].enum_items},
    "select-type": enum_names(bpy.types.Object, "type"),
    "select-linked": {i.identifier: i.name for i in
                      ops.object.select_linked.get_rna_type().properties['type'].enum_items},
    "select-similar": {i.identifier: i.name for i in
                       ops.mesh.select_similar.get_rna_type().properties['type'].enum_items},
    "select-grouped": {i.identifier: i.name for i in
                       ops.object.select_grouped.get_rna_type().properties['type'].enum_items},
    "separate": {i.identifier: i.name for i in ops.mesh.separate.get_rna_type().properties['type'].enum_items},
    "stroke-mode": {i.identifier: i.name for i in
                    ops.sculpt.brush_stroke.get_rna_type().properties['mode'].enum_items},
    "modifier": enum_names(bpy.types.Modifier, "type"),
    # Add Object Constraint's types (round 4, group 7): the constraint type
    # enum's names. The object operator's own Type is dynamic and empty here.
    "constraint-type": enum_names(bpy.types.Constraint, "type"),
}
for kind, names in ENUMS.items():
    for row in of(kind):
        identifier = row["extra"]["identifier"]
        if kind == "stroke-mode" and identifier == "SMOOTH":
            # Never sent: the app strokes with NORMAL or INVERT, and 5.2.1's
            # brush_stroke has no SMOOTH (Shift swaps the brush instead).
            check("SculptStrokeMode.smooth is not an item of 5.2.1's brush_stroke mode, and is not sent",
                  identifier not in names)
            continue
        check(f"{kind} {identifier}: {row['label']}", names.get(identifier) == row["label"], names.get(identifier))
origin = {i.identifier: i.name for i in ops.object.origin_set.get_rna_type().properties['type'].enum_items}
for row in of("origin"):
    want = origin[row["extra"]["identifier"]] + (" (Bounds)" if row["extra"]["center"] == "BOUNDS" else "")
    check(f"Set Origin ▸ {row['label']}", row["label"] == want, want)
# The Outliner's collection toggles: each step is its property's name.
toggle_props = {"exclude": (bpy.types.LayerCollection, "exclude"), "hide": (bpy.types.LayerCollection, "hide_viewport"),
                "selectable": (bpy.types.Collection, "hide_select"), "render": (bpy.types.Collection, "hide_render")}
for row in of("collection-toggle"):
    owner, prop = toggle_props[row["extra"]["toggle"]]
    check(f"the Outliner's {row['extra']['toggle']} toggle steps as {prop}'s name, {row['label']}",
          owner.bl_rna.properties[prop].name == row["label"], owner.bl_rna.properties[prop].name)
handles = {i.name for i in ops.curve.handle_type_set.get_rna_type().properties['type'].enum_items}
flips = {i.name for i in ops.lattice.flip.get_rna_type().properties['axis'].enum_items}
for row in of("points"):
    if row["call"] == "curve.handle_type_set":
        check(f"Set Handle Type ▸ {row['label']}", row["label"] in handles, sorted(handles))
    if row["call"] == "lattice.flip":
        check(f"Flip (Distortion Free) ▸ {row['label']}", row["label"] in flips, sorted(flips))
        check(f"and its step is lattice.flip's name", row["undo"] == op_name("lattice.flip"))
engines = {"BLENDER_EEVEE": "EEVEE", "BLENDER_WORKBENCH": "Workbench"}
engines.update({c.bl_idname: c.bl_label for c in bpy.types.RenderEngine.__subclasses__()
                if getattr(c, "bl_idname", None)})
engines.update(enum_names(bpy.types.RenderSettings, "engine"))
for row in of("engine"):
    check(f"Render engine {row['extra']['identifier']}: {row['label']}",
          engines.get(row["extra"]["identifier"]) == row["label"], engines.get(row["extra"]["identifier"]))
for row in of("symmetry"):
    names = {"use_mirror_x": "X", "use_mirror_y": "Y", "use_mirror_z": "Z"}
    want = names.get(row["extra"]["property"]) or bpy.types.Mesh.bl_rna.properties[row["extra"]["property"]].name
    check(f"the mirror row's {row['label']}", row["label"] == want, want)

# --------------------------------------------------------------------------
print("\nThe simulator's sculpt brushes are Essentials brushes")

sculpt_module = sys.modules["_blenderkit_sculpt"]
check("a stroke's step is read as its brush's, whichever case the build prints the type in",
      sculpt_module.stroke_step([("a", "GLOBAL_UNDO", "Sculpt Mode", False, False),
                                 ("b", "Sculpt", "Draw Brush", True, False)]) == "Draw Brush"
      and sculpt_module.stroke_step([("b", "SCULPT", "Grab Brush", True, False)]) == "Grab Brush")
check("and is none when the active step is not a sculpt step, or there is no stack",
      sculpt_module.stroke_step([("a", "GLOBAL_UNDO", "Sculpt Mode", True, False)]) is None
      and sculpt_module.stroke_step(None) is None and sculpt_module.stroke_step([]) is None)
brushes = set(sculpt_module.brushes())
check("Blender has its Essentials sculpt brushes here", len(brushes) > 30, len(brushes))
for row in of("tool"):
    if row["extra"]["case"].startswith("sculpt"):
        check(f"the brush {row['label']}", row["label"] in brushes)

# --------------------------------------------------------------------------
print("\nThe Cursor tool's settings, Ruler Remove and the overlays' switches")
cursor3d = bpy.ops.view3d.cursor3d.get_rna_type()
for row in of("cursor-setting"):
    check(f"the Cursor's {row['label']} is {row['extra']['prop']}'s name",
          cursor3d.properties[row["extra"]["prop"]].name == row["label"],
          cursor3d.properties[row["extra"]["prop"]].name)
items = [(i.identifier, i.name) for i in cursor3d.properties["orientation"].enum_items]
check("the Orientation's items, in Blender's order", items == [(r["extra"]["identifier"], r["label"])
                                                               for r in of("cursor-orientation")], items)
for row in of("operator-name"):
    check(f"{row['call']} is named {row['label']}", op_name(row["call"]) == row["label"], op_name(row["call"]))
# The overlays' switches are drawn with text of their own, which is what the
# popover shows: read from this Blender's own space_view3d.py.
import re as _re, inspect as _inspect
import bl_ui.space_view3d as _v3d
_source = _inspect.getsource(_v3d)
for row in of("overlay-toggle"):
    texts = _re.findall(r'"%s",\s*text="([^"]+)"' % row["extra"]["prop"], _source)
    check(f"the overlay switch {row['label']} ({row['extra']['prop']})", row["label"] in texts, texts)
for row in of("overlay-panel"):
    panel = getattr(_v3d, row["extra"]["panel"])
    check(f"the overlay panel {row['label']} ({row['extra']['panel']})", panel.bl_label == row["label"],
          panel.bl_label)
check("the popover's own heading is Viewport Overlays", 'layout.label(text="Viewport Overlays")' in _source)

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
