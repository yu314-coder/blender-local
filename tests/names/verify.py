"""The app's names, held to Blender 5.2.1's menus and toolbar.

tests/names/main.swift prints every name the app builds from its tables — a
menu row's label, the operator it runs, the redo panel's title, the undo
step — and this holds them to what Blender's own interface draws, as the
reference files in tests/names/reference record it (generated in desktop
5.2.1 by running each VIEW3D_MT_* / TOPBAR_MT_* menu's draw and the 3D View's
toolbar; menus.py and toolbar.py there). Where a row is in one of Blender's
menus, it has to be there under the same label and run the same operator.
The few that cannot are listed below with the reason, and docs/blender-names.md
lists every name the app keeps as its own.

What only Blender can say — each operator's name, each enum item's, and the
step its undo history records — is tests/names/blender/verify.py.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
REF = ROOT / "tests" / "names" / "reference"
rows = json.load(open(sys.argv[1]))
menus = json.load(open(REF / "blender_menus.json"))
toolbar = json.load(open(REF / "blender_toolbar.json"))
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "\n        " + str(detail)))
    if not ok:
        fail += 1


def menu(name, mode=None):
    """A Blender menu's (label, items) as 5.2.1 draws it: items are
    (kind, label, idname)."""
    for m in ([mode] if mode else ["EDIT_MESH", "OBJECT"]):
        if name in menus.get(m, {}):
            entry = menus[m][name]
            return entry["label"], [tuple(i) for i in entry["items"]]
    raise KeyError(name)


def items(name, mode=None):
    return {label: idname for kind, label, idname in menu(name, mode)[1] if kind in ("op", "enum", "menu")}


def of(kind):
    return [r for r in rows if r["kind"] == kind]


# --------------------------------------------------------------------------
print("\nThe toolbar's tools, by Blender's toolbar names")

TOOL_MODE = {"ANY": ["OBJECT"], "EDIT": ["EDIT_MESH"], "SCULPT": ["SCULPT"],
             "TEXTURE_PAINT": ["PAINT_TEXTURE"], "VERTEX_PAINT": ["PAINT_VERTEX"],
             "WEIGHT_PAINT": ["PAINT_WEIGHT"], "PAINT_GREASE_PENCIL": ["PAINT_GREASE_PENCIL"]}
# The sculpt brushes are brush assets in 5.x, not toolbar tools: the toolbar
# has one Brush tool, and these are the brushes (Essentials names, held to
# Blender's asset library by tests/names/blender/verify.py).
BRUSHES = {"sculptDraw", "sculptInflate", "sculptSmooth", "sculptFlatten", "sculptGrab", "sculptPinch"}
for tool in of("tool"):
    case, mode = tool["extra"]["case"], tool["extra"]["mode"]
    if case in BRUSHES:
        continue
    modes = TOOL_MODE[mode]
    if case in ("paintDraw", "paintBlur", "paintSmear", "paintAverage"):
        modes = ["PAINT_TEXTURE", "PAINT_VERTEX", "PAINT_WEIGHT"]
    names = {n for m in modes for n in toolbar[m]}
    check(f"{tool['label']} is a {'/'.join(modes)} toolbar tool", tool["label"] in names, sorted(names))
check("the select tools are Tweak, Select Box, Select Circle and Select Lasso",
      [t["label"] for t in of("tool")][:4] == ["Tweak", "Select Box", "Select Circle", "Select Lasso"],
      [t["label"] for t in of("tool")][:4])

# --------------------------------------------------------------------------
print("\nThe Mesh menu: Blender's menus, their labels, their rows and operators, in order")

GROUP_MENU = {"Select Loops": "VIEW3D_MT_edit_mesh_select_loops", "Transform": "VIEW3D_MT_transform",
              "Extrude": "VIEW3D_MT_edit_mesh_extrude", "Merge": "VIEW3D_MT_edit_mesh_merge",
              "Split": "VIEW3D_MT_edit_mesh_split", "Mesh": "VIEW3D_MT_edit_mesh",
              "Normals": "VIEW3D_MT_edit_mesh_normals", "Shading": "VIEW3D_MT_edit_mesh_shading",
              "Clean Up": "VIEW3D_MT_edit_mesh_clean",
              "Delete": "VIEW3D_MT_edit_mesh_delete", "Vertex": "VIEW3D_MT_edit_mesh_vertices",
              "Average": "VIEW3D_MT_edit_mesh_normals_average",
              "Edge": "VIEW3D_MT_edit_mesh_edges", "Face": "VIEW3D_MT_edit_mesh_faces"}
# VIEW3D_MT_transform as Edit Mode draws it: the reference drew it in Object
# Mode, and space_view3d.py (5.2.1, VIEW3D_MT_transform.draw) adds these when
# `context.mode == 'EDIT_MESH'`.
EDIT_TRANSFORM = {"To Circle": "mesh.circularize", "Flatten": "mesh.flatten",
                  "Shrink/Fatten": "transform.shrink_fatten",
                  "Space Edge Loops Evenly": "mesh.space_edge_loops_evenly",
                  "Skin Resize": "transform.skin_resize", "Warp": "transform.vertex_warp",
                  "Randomize": "transform.vertex_random"}
# Rows whose operator is not the one Blender's row calls, and why.
OPERATOR_EXCEPTIONS = {
    # Blender's rows call a Python wrapper that needs a 3D View region to
    # invoke the macro; the app calls the macro the wrapper calls.
    "Extrude Faces Along Normals": ("view3d.edit_mesh_extrude_move_shrink_fatten", "mesh.extrude_region_shrink_fatten"),
    # The same for Extrude Manifold: `view3d.edit_mesh_extrude_manifold_normal`
    # calls the `mesh.extrude_manifold` macro with the arguments the app sends.
    "Extrude Manifold": ("view3d.edit_mesh_extrude_manifold_normal", "mesh.extrude_manifold"),
}
# Rows Blender's menu does not have, under a name Blender's toolbar gives
# the same thing. None now: the Edge menu's "Loop Cut" (the ring through the
# selected edges, subdivided) is Blender's Subdivide Edge-Ring since round 4
# (group 3), and the toolbar's Loop Cut is a tool of its own.
TOOLBAR_ROWS = {}

mesh_rows = of("mesh")
groups = of("mesh-group")
for group in groups:
    name = group["label"]
    blender_label, _ = menu(GROUP_MENU[name], "EDIT_MESH" if name != "Transform" else "OBJECT")
    check(f"the group {name} is Blender's menu {GROUP_MENU[name]}, labelled {blender_label}",
          blender_label == name, blender_label)
    allowed = items(GROUP_MENU[name], "EDIT_MESH" if name != "Transform" else "OBJECT")
    if name == "Transform":
        allowed.update(EDIT_TRANSFORM)
    order = list(allowed)
    positions = []
    for case in group["extra"]["rows"].split(","):
        row = next(r for r in mesh_rows if r["extra"]["case"] == case)
        # Blender draws "...", the app "…" (docs/blender-names.md).
        label = row["label"].replace("…", "...")
        if label in TOOLBAR_ROWS:
            check(f"{name} ▸ {label} is Blender's toolbar tool of that name",
                  label in toolbar[TOOLBAR_ROWS[label]])
            continue
        ok = label in allowed
        detail = f"{label} not in {sorted(allowed)}"
        if ok:
            want = allowed[label]
            got = row["call"]
            if label in OPERATOR_EXCEPTIONS:
                ok = OPERATOR_EXCEPTIONS[label] == (want, got)
                detail = f"{label}: Blender {want}, the app {got}"
            else:
                ok = want.split(":")[0] == got
                detail = f"{label}: Blender runs {want}, the app {got}"
            positions.append(order.index(label))
        check(f"{name} ▸ {label} runs {row['call']}", ok, detail)
    check(f"{name}'s rows are in Blender's order", positions == sorted(positions), positions)

# Blender keeps Limited Dissolve in two menus, Clean Up and Delete, and so
# does the app; every other row is in one.
IN_TWO = {"limitedDissolve"}
placed = sorted(c for g in groups for c in g["extra"]["rows"].split(","))
check("every Mesh row is in one group, once (Limited Dissolve in Clean Up and Delete, as in Blender)",
      placed == sorted([r["extra"]["case"] for r in mesh_rows] + sorted(IN_TWO)), placed)
for case in IN_TWO:
    label = next(r["label"] for r in mesh_rows if r["extra"]["case"] == case)
    check(f"{label} is a row of both of Blender's menus it is in",
          all(label in items(GROUP_MENU[g["label"]], "EDIT_MESH") for g in groups
              if case in g["extra"]["rows"].split(",")))
for sub in of("mesh-subgroup"):
    parent = menu(GROUP_MENU[sub["extra"]["parent"]], "EDIT_MESH")[1]
    labels = [label for kind, label, _ in parent]
    check(f"{sub['label']} is a submenu of Blender's {sub['extra']['parent']} menu",
          ("menu", sub["label"], GROUP_MENU[sub["label"]]) in parent, parent)
    after = sub["extra"]["after"].replace("…", "...")
    check(f"and comes after {after} there, where the app draws it",
          after in labels and labels.index(sub["label"]) > labels.index(after), labels)
check("the groups are Blender's: no Add Geometry, Cut and Divide, Fill or Deform",
      not {"Add Geometry", "Cut and Divide", "Fill", "Deform"} & {g["label"] for g in groups})
for row in mesh_rows:
    check(f"{row['label']}'s redo panel and undo step carry one name, {row['name']}",
          row.get("name") == row.get("undo"))
check("the bar's buttons are the toolbar's Extrude Along Normals, Bevel and Inset Faces, and Subdivide",
      [next(r for r in mesh_rows if r["extra"]["case"] == c)["extra"]["tool"]
       for c in ("extrude", "bevel", "inset", "subdivide")]
      == ["Extrude Along Normals", "Bevel", "Inset Faces", "Subdivide"])
check("and the toolbar has the first three", {"Extrude Along Normals", "Bevel", "Inset Faces"} <= set(toolbar["EDIT_MESH"]))

# --------------------------------------------------------------------------
print("\nThe rows that pick Loop Cut and the Knife")

for row in of("tool-row"):
    menu_items = [(label, idname) for kind, label, idname in menu(row["menu"], "EDIT_MESH")[1]]
    labels = [label for label, _ in menu_items]
    check(f"{row['label']} is a row of {row['menu']} running {row['call']}",
          (row["label"], row["call"]) in menu_items, menu_items)
    check(f"and follows {row['extra']['after']} there, where the app's menu puts it",
          row["extra"]["after"] in labels and row["label"] in labels
          and labels.index(row["label"]) == labels.index(row["extra"]["after"]) + 1, labels)
    check(f"and the tool it picks is Blender's toolbar's {row['extra']['tool']}",
          row["extra"]["tool"] in toolbar["EDIT_MESH"])
for row in of("operator"):
    if row["label"] in ("Loop Cut", "Knife"):
        check(f"{row['label']}'s redo panel and undo step carry one name, {row['name']}",
              row["name"] == row["undo"] and row["name"] in ("Loop Cut and Slide", "Knife Topology Tool"), row)

# --------------------------------------------------------------------------
print("\nThe Vertex menu's rows that are not plain operators")

for row in of("menu-row"):
    menu_items = [(label, idname) for kind, label, idname in menu(row["menu"], "EDIT_MESH")[1]]
    labels = [label for label, _ in menu_items]
    check(f"{row['label']} is a row of {row['menu']} running {row['call']}",
          (row["label"], row["call"]) in menu_items, menu_items)
    check(f"and comes right before {row['extra']['before']} there, as the app draws it",
          row["extra"]["before"] in labels and row["label"] in labels
          and labels.index(row["extra"]["before"]) == labels.index(row["label"]) + 1, labels)
check("the three are there", len(of("menu-row")) == 3, len(of("menu-row")))

# --------------------------------------------------------------------------
print("\nThe Object menu's rows that were the Operator Search's alone (round 4, group 7)")

# Blender's VIEW3D_MT_mirror sets each row's Constraint Axis by item
# assignment, which the reference's stand-in layout could not run past its
# first row ("'Props' object does not support item assignment"); its rows are
# read in space_view3d.py instead: "{axis} {space}" for Global and Local, each
# transform.mirror.
SPACE_VIEW3D = pathlib.Path("/Applications/Blender.app/Contents/Resources/5.2/scripts/startup/bl_ui/space_view3d.py")
mirror_source = SPACE_VIEW3D.read_text() if SPACE_VIEW3D.exists() else ""
mirror_rows = []
if 'for (space_name, space_id) in (("Global", \'GLOBAL\'), ("Local", \'LOCAL\')):' in mirror_source \
        and 'for axis_index, axis_name in enumerate("XYZ"):' in mirror_source:
    mirror_rows = [a + " " + sp for sp in ("Global", "Local") for a in "XYZ"]
for row in of("object-row"):
    if row["menu"] == "VIEW3D_MT_mirror":
        check(f"Object ▸ Mirror ▸ {row['label']} is Blender's row, transform.mirror",
              row["label"] in mirror_rows and row["call"] == "transform.mirror", mirror_rows or "space_view3d.py not read")
        continue
    menu_items = [(label, idname) for kind, label, idname in menu(row["menu"], "OBJECT")[1] if kind in ("op", "enum")]
    want = row["extra"]["row"]
    check(f"{row['label']} is a row of {row['menu']} running {want}", (row["label"], want) in menu_items,
          menu_items)
check("the Mirror rows, in Blender's order", [r["label"] for r in of("object-row") if r["menu"] == "VIEW3D_MT_mirror"]
      == mirror_rows, mirror_rows)
link_rows = [r["label"] for r in of("object-row") if r["menu"] == "VIEW3D_MT_make_links"]
blender_links = [label for kind, label, idname in menu("VIEW3D_MT_make_links", "OBJECT")[1]
                 if idname.startswith("object.make_links_data:") or idname == "object.join_uvs"]
check("Link/Transfer Data's rows, in Blender's order", link_rows == blender_links, (link_rows, blender_links))
single_rows = [r["label"] for r in of("object-row") if r["menu"] == "VIEW3D_MT_make_single_user"]
check("Make Single User's rows, in Blender's order",
      single_rows == [label for kind, label, idname in menu("VIEW3D_MT_make_single_user", "OBJECT")[1]],
      single_rows)
for row in of("object-menu"):
    blender_label, _ = menu(row["menu"], "OBJECT")
    parent_items = [(label, idname) for kind, label, idname in menu(row["extra"]["parent"], "OBJECT")[1] if kind == "menu"]
    check(f"the menu {row['label']} is Blender's {row['menu']}, in {row['extra']['parent']}",
          blender_label == row["label"] and (row["label"], row["menu"]) in parent_items, (blender_label, parent_items))
# Move to and Link to Collection are C menus (object_edit.cc, `mt->label`
# "Move to Collection" / "Link to Collection"); the reference records them by
# their idnames in Object ▸ Collection.
collection_menu = [idname for kind, label, idname in menu("VIEW3D_MT_object_collection", "OBJECT")[1] if kind == "menu"]
for row in of("collection-row"):
    check(f"Object ▸ Collection ▸ {row['label']} is Blender's {row['menu']}", row["menu"] in collection_menu,
          collection_menu)
    check(f"and its step is its operator's name, {row['label']}", row["undo"] == row["label"])
for row in of("local-view"):
    check(f"View ▸ Local View ▸ {row['label']} runs {row['call']}",
          items("VIEW3D_MT_view_local", "OBJECT").get(row["label"]) == row["call"],
          items("VIEW3D_MT_view_local", "OBJECT"))
check("control: a row under another label is caught",
      ("Mirror X", "transform.mirror") not in [(l, i) for k, l, i in menu("VIEW3D_MT_make_links", "OBJECT")[1]])

# --------------------------------------------------------------------------
print("\nThe Select menu")

SELECT_MESH = {}
for sub in ["VIEW3D_MT_select_edit_mesh", "VIEW3D_MT_edit_mesh_select_more_less", "VIEW3D_MT_edit_mesh_select_similar",
            "VIEW3D_MT_edit_mesh_select_by_trait", "VIEW3D_MT_edit_mesh_select_linked",
            "VIEW3D_MT_edit_mesh_select_loops"]:
    SELECT_MESH.update(items(sub, "EDIT_MESH"))
for row in of("select-mesh"):
    want = SELECT_MESH.get(row["label"])
    check(f"Select ▸ {row['label']} runs {row['call']}", want is not None and want.split(":")[0] == row["call"],
          f"Blender: {want}")
SELECT_OBJECT = {}
for sub in ["VIEW3D_MT_select_object", "VIEW3D_MT_select_object_more_less"]:
    SELECT_OBJECT.update(items(sub, "OBJECT"))
for row in of("select-object"):
    want = SELECT_OBJECT.get(row["label"])
    check(f"Select ▸ {row['label']} runs {row['call']}", want is not None and want.split(":")[0] == row["call"],
          f"Blender: {want}")
for row in of("select-object-menu"):
    want = items("VIEW3D_MT_select_object", "OBJECT").get(row["label"].replace("…", "..."))
    check(f"Select ▸ {row['label']} runs {row['call']}", want is not None and want.split(":")[0] == row["call"],
          f"Blender: {want}")
# Blender's pick selections are keys, not rows: their keymap entries, the
# operator each runs, and what Shift adds (blender_default.py, 5.2.1).
PICK_KEYS = {"mesh.loop_select": "Toggle Select", "mesh.edgering_select": "Toggle Select",
             "mesh.shortest_path_pick": "Fill Region", "mesh.select_linked_pick": "Deselect"}
for row in of("select-pick"):
    check(f"the pick {row['label']} runs {row['call']}, Shift adding {row['extra']['shift']}",
          PICK_KEYS.get(row["call"]) == row["extra"]["shift"], PICK_KEYS.get(row["call"]))
check("all four picks are there", len(of("select-pick")) == 4, len(of("select-pick")))
for row in of("select-loops"):
    want = items("VIEW3D_MT_edit_mesh_select_loops", "EDIT_MESH").get(row["label"])
    check(f"Select ▸ Select Loops ▸ {row['label']} runs {row['call']}", want == row["call"], want)
for row in of("select"):
    check(f"Select ▸ {row['label']} ({row['menu']}) is Blender's row", row["label"] in items(row["menu"]),
          sorted(items(row["menu"])))
    check(f"and its step is select_all's, (De)select All", row["undo"] == "(De)select All", row["undo"])

# --------------------------------------------------------------------------
print("\nSnap, Show/Hide, Separate, Apply")

for row in of("snap"):
    check(f"Snap ▸ {row['label']}", row["label"] in items("VIEW3D_MT_snap", "OBJECT"))
for row in of("showhide"):
    editing = row["extra"]["editing"] == "true"
    # The Edit Mode menu is Blender's ShowHideMenu, which draws the reveal row
    # with the operator's own name (mesh.reveal: "Reveal Hidden") — the
    # reference has it for the metaball menu, the same class; the mesh one
    # could not be drawn outside Blender's UI.
    name = "VIEW3D_MT_edit_meta_showhide" if editing else "VIEW3D_MT_object_showhide"
    check(f"Show/Hide ▸ {row['label']} ({'Edit' if editing else 'Object'} Mode)", row["label"] in items(name),
          sorted(items(name)))
for row in of("apply"):
    check(f"Apply ▸ {row['label']}", row["label"] in items("VIEW3D_MT_object_apply", "OBJECT"))

# --------------------------------------------------------------------------
print("\nThe 3D View's own steps: each name is UndoStep's, on the call it stands for")

# The Blender check holds each name to the step Blender records for `call`
# (tests/names/blender/verify.py); this holds the call to the Python the
# button sends, so the measured call is the one the app makes.


def sends(python, call):
    if call == "object.editmode_toggle":
        # The app's Tab is mode_set into Edit Mode or out of it.
        return "bpy.ops.object.mode_set(mode='EDIT')" in python and "bpy.ops.object.mode_set(mode='OBJECT')" in python
    op, _, mode = call.partition(":")
    return f"bpy.ops.{op}(" in python and (not mode or f"mode='{mode}'" in python)


view_steps = of("view-step")
check("the dump has the 3D View's steps", len(view_steps) >= 10, len(view_steps))
check("a Python is held to the call it makes (negative control: Shift+D's is not object.delete)",
      not sends("bpy.ops.mesh.duplicate_move()", "object.delete")
      and not sends("bpy.ops.object.mode_set(mode='OBJECT')", "object.mode_set:EDIT"))
for row in view_steps + of("gizmo") + of("separate"):
    check(f"{row['label']}: the step {row['undo']!r} stands for {row['call']}, which the button sends",
          sends(row["extra"]["python"], row["call"]), row["extra"]["python"][:120])
for row in of("showhide"):
    check(f"Show/Hide ▸ {row['label']} sends {row['extra']['op']}", sends(row["extra"]["python"], row["extra"]["op"]),
          row["extra"]["python"][:120])

# --------------------------------------------------------------------------
print("\nThe Curve and Lattice menus")

CURVE = {}
for sub in ["VIEW3D_MT_edit_curve", "VIEW3D_MT_edit_curve_context_menu", "VIEW3D_MT_edit_curve_delete",
            "VIEW3D_MT_edit_curve_segments", "VIEW3D_MT_edit_lattice"]:
    CURVE.update(items(sub, "OBJECT"))
for row in of("points"):
    label = row["label"]
    if label in CURVE:
        check(f"{label} runs {row['call']}", CURVE[label].split(":")[0] == row["call"], CURVE[label])
    elif row["call"] in ("curve.handle_type_set", "lattice.flip", "curve.subdivide"):
        # Enum items (Blender's names checked by tests/names/blender) and the
        # app's Subdivide ▸ 1–4 Cuts, which picks Number of Cuts up front.
        continue
    else:
        check(f"{label} is a row of Blender's Curve or Lattice menus", False, sorted(CURVE))

# --------------------------------------------------------------------------
print("\nFile ▸ Import and Export")

for kind, name in (("import", "TOPBAR_MT_file_import"), ("export", "TOPBAR_MT_file_export")):
    blender = items(name, "OBJECT")
    positions = []
    for row in of(kind):
        ok = blender.get(row["label"]) == row["call"]
        check(f"{kind.title()} ▸ {row['label']} runs {row['call']}", ok, blender.get(row["label"]))
        if ok:
            positions.append(list(blender).index(row["label"]))
    check(f"{kind.title()}'s rows are in Blender's order", positions == sorted(positions), positions)

# --------------------------------------------------------------------------
print("\nThe workspaces")

top = (ROOT / "Sources/BlenderLocalUI/Chrome/TopBar.swift").read_text()
visible = re.search(r"static var visible: \[Workspace\] \{ \[([^\]]*)\] \}", top).group(1)
names = {m.group(1): m.group(2) for m in re.finditer(r'case (\w+)\s*=\s*"([^"]+)"', top)}
shown = [names[c.strip().lstrip(".")] for c in visible.split(",")]
check("the two tabs are Blender's Scripting and Layout workspaces", shown == ["Scripting", "Layout"], shown)

print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
