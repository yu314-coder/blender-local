// Prints, as one JSON document, every name the app builds from data rather
// than from a literal in a view: the toolbar's tools, the Mesh menu's groups
// and rows with the operator each runs, the Select menu's rows, the Snap
// menu, Show/Hide, Set Origin and Apply, the Curve and Lattice menus, the
// Vertex Groups and Shape Keys controls, File ▸ Import and Export, the render
// engines, the modes, the tool settings' choices, the sculpt header's rows,
// the redo panel's titles and every undo step name these carry.
//
// tests/names/verify.py holds them to Blender's menus and toolbar as 5.2.1
// draws them (tests/names/reference), and tests/names/blender/verify.py to
// Blender itself: each operator's name, each enum's, and the undo step
// Blender's own history records for the same call.
import Foundation
import simd

struct Row: Encodable {
    var kind: String
    var label: String
    var name: String? = nil
    var undo: String? = nil
    var call: String? = nil
    var group: String? = nil
    var menu: String? = nil
    var extra: [String: String]? = nil
}

var rows: [Row] = []
func add(_ kind: String, _ label: String, name: String? = nil, undo: String? = nil, call: String? = nil,
         group: String? = nil, menu: String? = nil, extra: [String: String]? = nil) {
    rows.append(Row(kind: kind, label: label, name: name, undo: undo, call: call, group: group, menu: menu,
                    extra: extra))
}

/// The operator a LastOperator runs, without its arguments: "mesh.bevel".
func idname(_ call: String) -> String {
    call.replacingOccurrences(of: "bpy.ops.", with: "")
}

// The toolbar.
for tool in ActiveTool.allCases {
    add("tool", tool.label, extra: ["case": tool.rawValue, "implemented": String(tool.isImplemented),
                                    "mode": tool.requiredMode?.bpyMode ?? "ANY"])
}

// The Mesh menu: its groups in order, each row's label, the operator it runs
// and the name its redo panel and undo step carry.
for group in LastOperator.Mesh.Group.allCases {
    add("mesh-group", group.rawValue, extra: ["inline": String(group.isInline),
                                              "rows": group.rows.map(\.rawValue).joined(separator: ",")])
}
for op in LastOperator.Mesh.allCases {
    let made = LastOperator.mesh(op, spinningAround: .zero)
    add("mesh", op.menuLabel, name: made.name, undo: made.name, call: idname(op.call), group: op.group.rawValue,
        extra: ["case": op.rawValue, "tool": op.toolLabel, "row": op.rowName,
                "fixed": made.fixedArguments.joined(separator: ", "),
                "parameters": made.parameters.map { "\($0.key)=\($0.label)" }.joined(separator: "|")])
}

// The other operators the redo panel shows.
let others: [(String, LastOperator)] = [
    ("Duplicate Linked", .duplicateLinked()), ("Join", .join()),
    ("Object", .parent(keepTransform: false)), ("Object (Keep Transform)", .parent(keepTransform: true)),
    ("Clear Parent", .clearParent(.clear)), ("Clear and Keep Transformation", .clearParent(.keepTransform)),
    ("Clear Parent Inverse", .clearParent(.inverse)),
    ("Mesh", .convert(to: .mesh)), ("Curve", .convert(to: .curve)),
    ("Shear", .shear()), ("Shear", .shearObjects()),
    ("Shade Auto Smooth", .shadeAutoSmooth()), ("Shade Smooth by Angle", .shadeSmoothByAngle()),
    ("QuadriFlow Remesh", .quadriflowRemesh()), ("Knife Project", .knifeProject(cutter: "Cutter")),
    ("Lattice", .addLattice(at: .zero)),
]
for (label, op) in others {
    add("operator", label, name: op.name, undo: op.name, call: idname(op.call),
        extra: ["parameters": op.parameters.map { "\($0.key)=\($0.label)" }.joined(separator: "|")])
}
// Loop Cut and the Knife (CutTools.swift): the redo panel and the step carry
// the name Blender's history gives the cut. Loop Cut runs Blender's own
// operator. The Knife's cut is Blender's Knife Topology Tool, made through
// knife_project (the knife without a pointer), so its name is held to
// knife_tool's and `runs` says which operator the Info line shows.
let loopCutOp = LastOperator.loopCutAndSlide(edge: 4)
add("operator", "Loop Cut", name: loopCutOp.name, undo: loopCutOp.name, call: idname(loopCutOp.call),
    extra: ["parameters": loopCutOp.parameters.map { "\($0.key)=\($0.label)" }.joined(separator: "|")])
let knifeOp = LastOperator.knife(path: [.zero, SIMD3(1, 0, 0)], eye: SIMD3(0, -5, 0), forward: SIMD3(0, 1, 0),
                                 up: SIMD3(0, 0, 1), orthographic: false)
add("operator", "Knife", name: knifeOp.name, undo: knifeOp.name, call: "mesh.knife_tool",
    extra: ["runs": idname(knifeOp.call),
            "parameters": knifeOp.parameters.map { "\($0.key)=\($0.label)" }.joined(separator: "|")])
// The Vertex menu's rows that are not plain operators (MeshMenuTools): Extrude
// to Cursor or Add, run from the app's port of its invoke, and Rip Vertices and
// Rip Vertices and Fill, shown and refused. Each is Blender's row of that label,
// held to the operator Blender's row runs and to the row Blender draws next.
add("menu-row", MeshMenuTools.extrudeToCursor, name: MeshMenuTools.extrudeToCursor,
    undo: MeshMenuTools.extrudeToCursor, call: "mesh.dupli_extrude_cursor", menu: "VIEW3D_MT_edit_mesh_vertices",
    extra: ["before": LastOperator.Mesh.bevelVertices.menuLabel])
for (k, row) in MeshMenuTools.ripRows.enumerated() {
    add("menu-row", row, call: "mesh.rip_move", menu: "VIEW3D_MT_edit_mesh_vertices",
        extra: ["before": k + 1 < MeshMenuTools.ripRows.count ? MeshMenuTools.ripRows[k + 1]
                    : LastOperator.Mesh.ripVerticesExtend.menuLabel])
}
// Normals ▸ Average sits inside Normals, after Point to Target….
for group in LastOperator.Mesh.Group.allCases where group.parent != nil {
    add("mesh-subgroup", group.rawValue, extra: ["parent": group.parent!.rawValue,
                                                 "after": group.after!.menuLabel])
}
// The Mesh menu's rows that pick the two tools, as Blender's start them.
for cut in [CutTool.loopCut, .knife] {
    let row = cut.menuRow
    add("tool-row", row.label, call: row.idname, menu: row.menu, extra: ["after": row.after, "tool": cut.tool.label])
}
for kind in PrimitiveKind.allCases {
    let op = LastOperator.add(kind, at: .zero)
    add("add", kind.displayName, name: op.name, undo: op.name, call: idname(op.call), menu: "VIEW3D_MT_mesh_add")
}
let additions: [ObjectAddition] = ObjectAddition.CurveKind.allCases.map { .curve($0) } + [.text, .lattice]
    + EmptyDisplay.Kind.addMenu.map { .empty($0) } + LightDisplay.Kind.allCases.map { .light($0) } + [.camera]
for addition in additions {
    let op = LastOperator.add(addition, at: .zero, viewRotation: nil)
    add("add", addition.label, name: op.name, undo: op.name, call: idname(op.call))
}

// The Select menu.
for (command, label) in [(SelectMenu.Command.all, "All"), (.none, "None"), (.invert, "Invert")] {
    for editing in [false, true] {
        if case .run(_, let undo) = command.action(editing: editing) {
            add("select", label, undo: undo, call: editing ? "mesh.select_all" : "object.select_all",
                menu: editing ? "VIEW3D_MT_select_edit_mesh" : "VIEW3D_MT_select_object")
        }
    }
}
for item in SelectMenu.MeshItem.allCases {
    let undo: String
    switch SelectMenu.Command.mesh(item).action(editing: true) {
    case .run(_, let u): undo = u
    case .perform(let op): undo = op.name
    }
    add("select-mesh", item.title, name: item.operatorName, undo: undo, call: idname(item.call))
}
for type in SelectMenu.SimilarType.allCases {
    add("select-similar", type.label, extra: ["identifier": type.rawValue])
}
for item in SelectMenu.ObjectItem.allCases {
    add("select-object", item.title, name: item.operatorName, undo: item.operation.name,
        call: idname(String(item.call.split(separator: "(").first ?? "")))
}
for type in SelectMenu.objectTypes { add("select-type", type.label, extra: ["identifier": type.identifier]) }
for (label, action, call) in [("Select All by Type", SelectMenu.selectByType("MESH"), "object.select_by_type"),
                              ("Select Linked", SelectMenu.selectLinked("MATERIAL"), "object.select_linked"),
                              ("Select Pattern…", SelectMenu.selectPattern("C*"), "object.select_pattern"),
                              ("Select Grouped", SelectMenu.selectGrouped("TYPE"), "object.select_grouped")] {
    switch action {
    case .run(_, let undo): add("select-object-menu", label, undo: undo, call: call)
    case .perform(let op):  add("select-object-menu", label, undo: op.name, call: call)
    }
}
for type in SelectMenu.groupedTypes { add("select-grouped", type.label, extra: ["identifier": type.identifier]) }
// Blender's pick selections: keys, not rows, in Blender; their names are the
// operators' (redo panel title and undo step).
for pick in SelectPick.allCases {
    add("select-pick", pick.operatorName, name: pick.operatorName, undo: pick.operatorName,
        call: idname(pick.call), extra: ["shift": pick.shiftLabel])
}
for type in SelectMenu.linkedTypes { add("select-linked", type.label, extra: ["identifier": type.identifier]) }
for loop in [LastOperator.Mesh.selectEdgeLoops, .selectEdgeRings] {
    if case .perform(let op) = SelectMenu.Command.loops(loop).action(editing: true) {
        add("select-loops", loop.menuLabel, name: op.name, undo: op.name, call: idname(op.call))
    }
}
for region in [SelectionRegion.box(.zero), .circle(path: [], radius: 1), .lasso([])] {
    let call: String
    switch region {
    case .box: call = "view3d.select_box"
    case .circle: call = "view3d.select_circle"
    case .lasso: call = "view3d.select_lasso"
    }
    add("region", region.undoName, undo: region.undoName, call: call)
}

// Snap (Shift+S) and the tool settings' choices.
for action in SnapAction.allCases {
    add("snap", action.title, undo: action.undoName, menu: "VIEW3D_MT_snap")
}
for value in TransformPivot.allCases { add("pivot", value.label, extra: ["identifier": value.bpyIdentifier]) }
for value in SnapElement.allCases { add("snap-element", value.label, extra: ["identifier": value.bpyIdentifier]) }
for value in SnapElementIndividual.allCases {
    add("snap-individual", value.label, extra: ["identifier": value.bpyIdentifier])
}
for value in SnapTarget.allCases { add("snap-target", value.label, extra: ["identifier": value.bpyIdentifier]) }
for value in MeshEditor.ProportionalFalloff.allCases {
    add("falloff", value.label, extra: ["identifier": value.bpyIdentifier])
}
for mode in InteractionMode.allCases { add("mode", mode.label, extra: ["identifier": mode.bpyMode]) }
for mode in MeshSelectMode.allCases { add("select-mode", mode.label, extra: ["identifier": mode.bpyType]) }
for flag in SymmetryBpy.Flag.allCases {
    add("symmetry", flag.label, undo: SymmetryBpy.undoLabel(flag, mode: .texturePaint),
        extra: ["property": flag.property])
}

// Object ▸ Show/Hide, Separate, Set Origin, Apply.
for what in Bpy.ShowHide.allCases {
    for editing in [false, true] {
        // The operator the row sends: `mesh.hide` / `mesh.reveal` while
        // editing, whose steps the Blender check measures; the object rows'
        // `hide_view_set` / `hide_view_clear` poll for a 3D View and are held
        // to their names there.
        let call = editing ? (what == .reveal ? "mesh.reveal" : "mesh.hide")
            : (what == .reveal ? "object.hide_view_clear" : "object.hide_view_set")
        add("showhide", what.label(editing: editing), undo: what.undoName(editing: editing),
            call: editing ? call : nil,
            menu: editing ? "VIEW3D_MT_edit_mesh_showhide" : "VIEW3D_MT_object_showhide",
            extra: ["editing": String(editing), "python": Bpy.showHide(what, editing: editing), "op": call])
    }
}
for type in Bpy.SeparateType.allCases {
    add("separate", type.label, undo: UndoStep.separate, call: "mesh.separate",
        extra: ["identifier": type.rawValue, "python": Bpy.separate(type)])
}

// The steps the 3D View's own buttons, keys and gizmo push (UndoStep, which
// LayoutWorkspace, RootView, PropertiesView and TransformGizmo use), each with
// the call Blender's history was measured for and the Python the button
// sends: tests/names/blender/verify.py reads the names from here — round 4's
// review found it typing them in — and verify.py holds each Python to its
// call. tests/names/scan.py holds the call sites to these constants.
let viewSteps: [(call: String, undo: String, python: String)] = [
    // Tab: Blender's is `editmode_toggle`; the app's sends `mode_set` into
    // Edit Mode or out of it, by Blender's mode (both measured as Edit Mode).
    ("object.editmode_toggle", UndoStep.editMode, Bpy.toggleEditMode),
    ("object.mode_set:EDIT", UndoStep.editMode, Bpy.setMode(.edit)),
    ("object.mode_set:OBJECT", UndoStep.editMode, Bpy.setMode(.object)),
    ("mesh.duplicate_move", UndoStep.duplicateElements, Bpy.duplicateElements),
    ("object.duplicate_move", UndoStep.duplicateObjects, Bpy.duplicate),
    ("object.delete", UndoStep.delete, Bpy.deleteSelection(editing: false, mode: .vertex)),
    ("mesh.delete", UndoStep.delete, Bpy.deleteSelection(editing: true, mode: .vertex)),
    ("object.shade_smooth", UndoStep.shadeSmooth, Bpy.shadeSmooth),
    ("object.shade_flat", UndoStep.shadeFlat, Bpy.shadeFlat),
    ("object.modifier_add", UndoStep.addModifier, Bpy.addModifier("SUBSURF")),
]
for step in viewSteps {
    add("view-step", step.undo, undo: step.undo, call: step.call, extra: ["python": step.python])
}
// A gizmo drag commits a LastOperator (TransformCommit.swift) whose name is
// its redo panel's title and its step; the drags that go through `bridge.run`
// (a curve's points, the Cursor tool) use the same UndoStep names.
let axes = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))
for kind in [GizmoCommit.Kind.translate(values: SIMD3(1, 0, 0), constraint: "(True, False, False)"),
             .rotate(angle: 0.3, axis: 2), .resize(values: SIMD3(2, 2, 2), constraint: "(True, True, True)")] {
    let op = LastOperator.gizmo(GizmoCommit(kind: kind, orientation: .global, axes: axes, viewAxes: axes,
                                            editing: false))
    add("gizmo", op.name, name: op.name, undo: op.name, call: idname(op.call), extra: ["python": op.python])
}
for choice in Bpy.originMenu {
    add("origin", choice.title, undo: Bpy.originReach.undoName, call: "object.origin_set",
        extra: ["identifier": choice.type.rawValue, "center": choice.center.rawValue])
}
for what in Bpy.AppliedTransform.allCases {
    add("apply", what.title, undo: what.undoName, call: "object.transform_apply", menu: "VIEW3D_MT_object_apply")
}

// The Curve and Lattice menus.
var points: [PointsBpy.Command] = [PointsBpy.extrude, PointsBpy.delete(segments: false),
                                   PointsBpy.delete(segments: true), PointsBpy.toggleCyclic,
                                   PointsBpy.switchDirection, PointsBpy.makeRegular, PointsBpy.subdivide(cuts: 1)]
points += PointsBpy.handleTypes.map { PointsBpy.handleType($0.identifier) }
points += ["U", "V", "W"].map { PointsBpy.flip($0) }
for command in points {
    add("points", command.label, undo: command.undo,
        call: idname(String(command.python.split(separator: "(").first ?? "")))
}

// Vertex Groups and Shape Keys.
let groupCommands: [GroupsBpy.Command] = [
    GroupsBpy.addGroup(object: "O"), GroupsBpy.removeGroup("G", object: "O"), GroupsBpy.removeAllGroups(object: "O"),
    GroupsBpy.assign("G", weight: 1, object: "O"), GroupsBpy.removeFromGroup("G", object: "O"),
    GroupsBpy.selectGroup("G", select: true, object: "O"), GroupsBpy.selectGroup("G", select: false, object: "O"),
    GroupsBpy.addKey(fromMix: false, object: "O"), GroupsBpy.addKey(fromMix: true, object: "O"),
    GroupsBpy.removeKey("K", object: "O"), GroupsBpy.removeAllKeys(apply: false, object: "O"),
    GroupsBpy.removeAllKeys(apply: true, object: "O")]
for command in groupCommands {
    add("groups", command.undo ?? "", undo: command.undo,
        call: idname(String(command.call.split(separator: "(").first ?? "")))
}
for toggle in GroupsBpy.Switch.allCases { add("shape-key-switch", toggle.label, extra: ["property": toggle.rawValue]) }
for setting in GroupsBpy.KeySetting.allCases {
    add("shape-key-setting", setting.label, extra: ["property": setting.rawValue])
}

// File ▸ Import and Export, the render engines, the UV menu.
for format in BpySession.importFormats {
    add("import", format.label, undo: format.undo, call: format.op, menu: "TOPBAR_MT_file_import")
}
for exporter in BpySession.exporters {
    add("export", exporter.label, call: exporter.op, menu: "TOPBAR_MT_file_export")
}
for engine in RenderRequest.Engine.allCases { add("engine", engine.label, extra: ["identifier": engine.rawValue]) }
for op in UVOperator.allCases {
    add("uv", op.label, undo: op.label, call: idname(String(op.python.split(separator: "(").first ?? "")))
}

// Sculpt Mode's header and its steps.
for action in SculptMaskAction.allCases { add("mask", action.label, undo: SculptBpy.maskUndo) }
for mode in SculptFaceSetInit.allCases { add("face-sets", mode.label, undo: SculptBpy.faceSetsInitUndo) }
add("sculpt-step", "Dynamic Topology", undo: SculptBpy.dyntopoUndo, call: "sculpt.dynamic_topology_toggle")
add("sculpt-step", "Voxel Remesh", undo: SculptBpy.voxelRemeshUndo, call: "object.voxel_remesh")
add("sculpt-step", "Subdivide", undo: SculptBpy.multiresSubdivideUndo, call: "object.multires_subdivide")
add("sculpt-step", "Face Set from Masked", undo: SculptBpy.faceSetFromMaskUndo, call: "sculpt.face_sets_create")
add("sculpt-step", "Sculpt Mode", undo: SculptBpy.modeUndo, call: "sculpt.sculptmode_toggle")
add("sculpt-step", "Sculpt", undo: SculptBpy.strokeName, call: "sculpt.brush_stroke")
for mode in SculptStrokeMode.allCases { add("stroke-mode", mode.label, extra: ["identifier": mode.rawValue]) }

// Steps named outside the tables above.
add("step", "(De)select All", undo: SelectMenu.selectAllUndo, call: "object.select_all")
add("step", "Image Paint", undo: TexturePaintBpy.undoName, call: "paint.image_paint")
add("step", "Insert Keyframe", undo: BpyAnimation.insertUndoName, call: "anim.keyframe_insert")
add("step", "Delete Keyframe", undo: BpyAnimation.deleteUndoName, call: "anim.keyframe_delete_v3d")

// Modifiers: the Add Modifier menu's labels and the rows' steps.
for kind in ModifierKind.allCases where kind != .other {
    add("modifier", kind.label, extra: ["identifier": kind.bpyType])
}

// Round 4, group 7: the Object menu's rows that were the Operator Search's
// alone, each by its row's label in its Blender menu, running that row's
// operator, its redo panel and step the operator's name.
func objectRow(_ label: String, _ op: LastOperator, menu: String, row: String? = nil) {
    add("object-row", label, name: op.name, undo: op.name, call: idname(op.call), menu: menu,
        extra: ["row": row ?? idname(op.call)])
}
for row in LastOperator.mirrorRows {
    objectRow(row.label, .mirror(axis: row.axis, local: row.local), menu: "VIEW3D_MT_mirror")
}
for type in LastOperator.makeLinksTypes {
    objectRow(type.label, .makeLinksData(type.identifier), menu: "VIEW3D_MT_make_links",
              row: "object.make_links_data:type=\(type.identifier)")
}
objectRow("Copy UV Maps", .copyUVMaps(), menu: "VIEW3D_MT_make_links")
for row in LastOperator.SingleUser.allCases {
    objectRow(row.label, .makeSingleUser(row), menu: "VIEW3D_MT_make_single_user")
}
objectRow("Copy Modifiers to Selected Objects", .copyModifiersToSelected(), menu: "VIEW3D_MT_object_modifiers")
objectRow("Randomize Transform", .randomizeTransform(), menu: "VIEW3D_MT_transform_object")
objectRow("Align Objects", .alignObjects(), menu: "VIEW3D_MT_transform_object")
objectRow("Add Constraint (with Targets)", .addConstraintWithTargets("COPY_LOCATION"),
          menu: "VIEW3D_MT_object_constraints")
objectRow("Copy Constraints to Selected Objects", .copyConstraintsToSelected(), menu: "VIEW3D_MT_object_constraints")
objectRow("Clear Object Constraints", .clearObjectConstraints(), menu: "VIEW3D_MT_object_constraints")
for (label, menu, parent) in [("Mirror", "VIEW3D_MT_mirror", "VIEW3D_MT_object"),
                              ("Collection", "VIEW3D_MT_object_collection", "VIEW3D_MT_object"),
                              ("Relations", "VIEW3D_MT_object_relations", "VIEW3D_MT_object"),
                              ("Make Single User", "VIEW3D_MT_make_single_user", "VIEW3D_MT_object_relations"),
                              ("Modifiers", "VIEW3D_MT_object_modifiers", "VIEW3D_MT_object"),
                              ("Constraints", "VIEW3D_MT_object_constraints", "VIEW3D_MT_object"),
                              ("Link/Transfer Data", "VIEW3D_MT_make_links", "VIEW3D_MT_object"),
                              ("Transform", "VIEW3D_MT_transform_object", "VIEW3D_MT_object")] {
    add("object-menu", label, menu: menu, extra: ["parent": parent])
}
// Move and Link to Collection, and Local View: Blender's own operators, with
// no redo panel (their only fields are hidden, or there are none).
let moveToCollection = CollectionsBpy.move(to: 1, link: false)
let linkToCollection = CollectionsBpy.move(to: 1, link: true)
add("collection-row", "Move to Collection", name: moveToCollection.undo, undo: moveToCollection.undo,
    call: "object.move_to_collection", menu: "OBJECT_MT_move_to_collection")
add("collection-row", "Link to Collection", name: linkToCollection.undo, undo: linkToCollection.undo,
    call: "object.link_to_collection", menu: "OBJECT_MT_link_to_collection")
add("local-view", "Toggle Local View", name: LocalViewBpy.toggle.undo, undo: LocalViewBpy.toggle.undo,
    call: "view3d.localview", menu: "VIEW3D_MT_view_local")
add("local-view", "Remove from Local View", name: LocalViewBpy.removeFrom.undo, undo: LocalViewBpy.removeFrom.undo,
    call: "view3d.localview_remove_from", menu: "VIEW3D_MT_view_local")
// The Outliner's collection controls: their steps, by the properties' names.
for toggle in CollectionsBpy.Toggle.allCases {
    add("collection-toggle", toggle.label, undo: toggle.label, extra: ["toggle": toggle.rawValue])
}
// The Constraints tab (its name is SpaceProperties.context's, "Constraints",
// checked with the other tabs): Add Object Constraint's types, the operators'
// steps.
for type in ConstraintMenu.types { add("constraint-type", type.label, extra: ["identifier": type.id]) }
for (command, call) in [(ConstraintsBpy.add("COPY_LOCATION", to: "O"), "object.constraint_add"),
                        (ConstraintsBpy.remove("C", of: "O"), "constraint.delete"),
                        (ConstraintsBpy.move("C", of: "O", by: -1), "constraint.move_up"),
                        (ConstraintsBpy.move("C", of: "O", by: 1), "constraint.move_down"),
                        (ConstraintsBpy.move("C", of: "O", to: 0), "constraint.move_to_index")] {
    add("constraint-op", command.undo ?? "", name: command.undo, undo: command.undo, call: call)
}
for operation in ConstraintsBpy.Operation.allCases {
    add("constraint-op", operation.label, name: operation.undo, undo: operation.undo,
        call: "constraint.\(operation.rawValue)")
}

// The Cursor tool's settings (round 4, group 9): `view3d.cursor3d`'s
// properties and enum items; the Measure tool's Ruler Remove; the overlays'
// switches, by the View3DOverlay property each stands for.
add("cursor-setting", CursorTool.surfaceProjectLabel, call: "view3d.cursor3d", extra: ["prop": "use_depth"])
add("cursor-setting", CursorTool.orientationLabel, call: "view3d.cursor3d", extra: ["prop": "orientation"])
for o in CursorTool.Orientation.allCases {
    add("cursor-orientation", o.label, call: "view3d.cursor3d", extra: ["identifier": o.rawValue])
}
add("operator-name", RulerTool.removeLabel, name: RulerTool.removeLabel, call: "view3d.ruler_remove")
for (label, prop) in [(MeasureOverlays.statisticsLabel, "show_stats"), (MeasureOverlays.edgeLengthLabel, "show_extra_edge_length"),
                      (MeasureOverlays.edgeAngleLabel, "show_extra_edge_angle"), (MeasureOverlays.faceAreaLabel, "show_extra_face_area"),
                      (MeasureOverlays.faceAngleLabel, "show_extra_face_angle")] {
    add("overlay-toggle", label, extra: ["prop": prop])
}
for (label, panel) in [(MeasureOverlays.measurementLabel, "VIEW3D_PT_overlay_edit_mesh_measurement"),
                       (MeasureOverlays.meshEditModeLabel, "VIEW3D_PT_overlay_edit_mesh"),
                       (MeasureOverlays.textLabel, "VIEW3D_PT_overlay_text")] {
    add("overlay-panel", label, extra: ["panel": panel])
}
add("step", CursorTool.dragUndo, name: CursorTool.dragUndo, undo: CursorTool.dragUndo, call: "transform.translate")

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
print(String(data: try! encoder.encode(rows), encoding: .utf8)!)
