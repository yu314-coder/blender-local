import Foundation

// The Swift half of Object ▸ Duplicate Linked, Join, Parent, Clear Parent and
// Convert, the Mesh menu's new rows and Shear: the Python each row sends, the
// redo panel's fields (Blender 5.2.1's names, defaults and ranges), which rows
// are offered, the Outliner's parent tree, and the selection a redo-panel
// re-run hands back to Blender. What Blender makes of the Python is
// scripts/run-objectops-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func equal(_ label: String, _ got: String, _ want: String) {
    check(label, got == want, "\n        got  \(got)\n        want \(want)")
}

print("the Mesh menu's new rows")

func keys(_ m: LastOperator.Mesh) -> [String] { LastOperator.mesh(m).parameters.map(\.key) }
func value(_ m: LastOperator.Mesh, _ key: String) -> Double? { LastOperator.mesh(m)[key] }
func lastLine(_ m: LastOperator.Mesh) -> String {
    LastOperator.mesh(m).python.split(separator: "\n").last.map(String.init) ?? ""
}

// Where Blender has them: Mesh ▸ Split, Clean Up, the Edge, Vertex and Face
// menus, and the Extrude menu beside Extrude.
let placed: [(LastOperator.Mesh, LastOperator.Mesh.Group, String)] = [
    (.splitSelection, .split, "Selection"), (.edgeSplitEdges, .split, "Faces by Edges"),
    (.edgeSplitVertices, .split, "Faces & Edges by Vertices"),
    (.limitedDissolve, .cleanUp, "Limited Dissolve"), (.deleteLoose, .cleanUp, "Delete Loose"),
    (.fillHoles, .cleanUp, "Fill Holes"), (.unsubdivide, .edge, "Un-Subdivide"),
    (.beautifyFaces, .fill, "Beautify Faces"), (.bevelVertices, .vertex, "Bevel Vertices"),
    (.extrudeIndividual, .build, "Extrude Individual Faces")]
for (m, group, label) in placed {
    check("\(label) is in \(group.rawValue), offered outside Edit Mode too",
          m.group == group && m.menuLabel == label && !m.editModeOnly,
          "\(m.group.rawValue), \(m.menuLabel)")
}
check("Split is Blender's Mesh ▸ Split, after Add Geometry",
      LastOperator.Mesh.Group.allCases.firstIndex(of: .split) == 2)
let build = LastOperator.Mesh.allCases.filter { $0.group == .build }
check("Extrude Individual Faces is listed right after Extrude",
      build.firstIndex(of: .extrudeIndividual) == build.firstIndex(of: .extrude).map { $0 + 1 },
      "\(build.map(\.menuLabel))")
check("the panel's title and undo step is the operator's own name: Bevel Vertices is a Bevel",
      LastOperator.mesh(.bevelVertices).name == "Bevel" && LastOperator.mesh(.edgeSplitVertices).name == "Edge Split"
      && LastOperator.mesh(.splitSelection).name == "Split")

// 5.2.1's RNA: names, then defaults.
check("Limited Dissolve: Max Angle 5° and All Boundaries off",
      keys(.limitedDissolve) == ["angle_limit", "use_dissolve_boundaries"]
      && abs((value(.limitedDissolve, "angle_limit") ?? 0) - 0.0872665) < 1e-6
      && value(.limitedDissolve, "use_dissolve_boundaries") == 0, "\(keys(.limitedDissolve))")
check("Limited Dissolve's angle reads in degrees",
      LastOperator.mesh(.limitedDissolve).parameters[0].display == "5.0°",
      LastOperator.mesh(.limitedDissolve).parameters[0].display)
check("Delete Loose: Vertices and Edges on, Faces off",
      keys(.deleteLoose) == ["use_verts", "use_edges", "use_faces"]
      && value(.deleteLoose, "use_verts") == 1 && value(.deleteLoose, "use_faces") == 0)
check("Fill Holes: Sides 4, down to 0 (any)",
      keys(.fillHoles) == ["sides"] && value(.fillHoles, "sides") == 4
      && LastOperator.mesh(.fillHoles).parameters[0].softMin == 0)
check("Split takes nothing", keys(.splitSelection).isEmpty)
equal("Split's call", lastLine(.splitSelection), "bpy.ops.mesh.split()")
equal("Faces by Edges", lastLine(.edgeSplitEdges), "bpy.ops.mesh.edge_split(type='EDGE')")
equal("Faces & Edges by Vertices", lastLine(.edgeSplitVertices), "bpy.ops.mesh.edge_split(type='VERT')")
check("Un-Subdivide: Iterations 2", keys(.unsubdivide) == ["iterations"] && value(.unsubdivide, "iterations") == 2)
equal("Un-Subdivide's call", lastLine(.unsubdivide), "bpy.ops.mesh.unsubdivide(iterations=2)")
check("Beautify Faces: Max Angle 180°", keys(.beautifyFaces) == ["angle_limit"]
      && LastOperator.mesh(.beautifyFaces).parameters[0].display == "180.0°",
      LastOperator.mesh(.beautifyFaces).parameters[0].display)
equal("Extrude Individual Faces is the macro, out along the normals by 0.2",
      lastLine(.extrudeIndividual),
      "bpy.ops.mesh.extrude_faces_move(TRANSFORM_OT_shrink_fatten={\"value\": 0.2})")
equal("Extrude (Along Normals) starts outward too, where it went in at -0.2",
      LastOperator.mesh(.extrude).python,
      "bpy.ops.mesh.extrude_region_shrink_fatten(TRANSFORM_OT_shrink_fatten={\"value\": 0.2})")
equal("Bevel Vertices is Bevel with Affect on Vertices",
      LastOperator.mesh(.bevelVertices).python,
      "bpy.ops.mesh.bevel(affect='VERTICES', offset=0.1, segments=2, profile=0.5)")
var toEdges = LastOperator.mesh(.bevelVertices)
toEdges["affect"] = 1
check("and its Affect field turns it into Bevel's own call",
      toEdges.python == LastOperator.mesh(.bevel).python, toEdges.python)
check("Affect reads as Blender's words", LastOperator.mesh(.bevel).parameters[0].display == "Edges"
      && LastOperator.mesh(.bevelVertices).parameters[0].display == "Vertices")
var individual = LastOperator.mesh(.inset)
individual["use_individual"] = 1
equal("Inset's Individual field", individual.python,
      "bpy.ops.mesh.inset(thickness=0.3, depth=0, use_individual=True)")

print("\n  refused before Blender changes anything")
// Every mesh in Edit Mode counts (Blender's own operators act on all of
// them), and only an empty selection is refused.
for (m, attribute) in [(LastOperator.Mesh.limitedDissolve, "total_vert_sel"),
                       (.splitSelection, "total_vert_sel"), (.unsubdivide, "total_vert_sel"),
                       (.fillHoles, "total_edge_sel"), (.beautifyFaces, "total_face_sel"),
                       (.extrudeIndividual, "total_face_sel")] {
    let python = LastOperator.mesh(m).python
    let lines = python.split(separator: "\n").map(String.init)
    check("\(m.displayName) (\(m.menuLabel)) refuses an empty selection of every edit-mode mesh, before the call",
          python.hasPrefix(LastOperator.Mesh.editMeshes + "\n")
          && lines.contains("if not any(_bk_me.\(attribute) for _bk_me in _bk_meshes):")
          && lines.contains { $0.contains("raise RuntimeError('\(m.displayName) ") }
          && lines.last?.hasPrefix(LastOperator.mesh(m).call) == true,
          lines.joined(separator: " / "))
}
check("the edit-mode meshes are Blender's objects_in_mode_unique_data, the active one where there is none",
      LastOperator.Mesh.editMeshes.contains("getattr(bpy.context, 'objects_in_mode_unique_data', None)")
      && LastOperator.Mesh.editMeshes.contains("or [bpy.context.object]"))
// Edge Split's check follows its Type field: Faces & Edges by Vertices needs
// a vertex, not an edge (measured: one inner vertex, 49 → 52).
for (m, type) in [(LastOperator.Mesh.edgeSplitEdges, "EDGE"), (.edgeSplitVertices, "VERT")] {
    let python = LastOperator.mesh(m).python
    check("\(m.menuLabel): the check reads the panel's Type, \(type)",
          python.contains("if '\(type)' == 'VERT':") && !python.contains("@arg:")
          && python.contains("total_vert_sel for _bk_me in _bk_meshes")
          && python.contains("total_edge_sel for _bk_me in _bk_meshes")
          && python.contains("select a vertex first") && python.contains("select an edge first"), python)
}
var toVertices = LastOperator.mesh(.edgeSplitEdges)
toVertices["type"] = 1
check("and a Type changed in the panel changes the check with it",
      toVertices.python.contains("if 'VERT' == 'VERT':"), toVertices.python)
let loose = LastOperator.mesh(.deleteLoose).python
check("Delete Loose looks for something loose first, in every edit mesh, by its own switches",
      loose.hasPrefix("try:\n    import bmesh\nexcept ImportError:")
      && loose.contains("for _bk_me in _bk_meshes:\n    _bk_bm = bmesh.from_edit_mesh(_bk_me)")
      && loose.contains("(True and any(v.select and not v.link_edges")
      && loose.contains("(True and any(e.select and not e.link_faces")
      && loose.contains("(False and any(f.select and all(len(e.link_faces) == 1")
      && !loose.contains("@arg:")
      && loose.hasSuffix("bpy.ops.mesh.delete_loose(use_verts=True, use_edges=True, use_faces=False)"), loose)
var looseFaces = LastOperator.mesh(.deleteLoose)
looseFaces["use_faces"] = 1
looseFaces["use_verts"] = 0
check("and its switches, changed in the panel, change the check",
      looseFaces.python.contains("(True and any(f.select") && looseFaces.python.contains("(False and any(v.select"),
      looseFaces.python)
check("Bevel and Bevel Vertices turn Blender's silent CANCELLED into words",
      LastOperator.mesh(.bevel).executedPython.hasPrefix("if 'CANCELLED' in bpy.ops.mesh.bevel(")
      && LastOperator.mesh(.bevelVertices).refusal == LastOperator.mesh(.bevel).refusal)

print("\nShear")
let shear = LastOperator.shear()
equal("through the borrowed 3D View, at 20°, Blender's Z and X, in Global",
      shear.python,
      "import _blenderkit_context\nwith _blenderkit_context.temp_override_view3d('Shear'):\n"
      + "    bpy.ops.transform.shear(angle=0.3491, orient_axis='Z', orient_axis_ortho='X', orient_type='GLOBAL')")
check("Edit Mode, with the mesh backed up like any mesh operator",
      shear.needsEditMode && shear.restoration == .restoreMesh)
check("the refusal goes inside the override, around the call",
      shear.executedPython.contains("with _blenderkit_context.temp_override_view3d('Shear'):\n    if 'CANCELLED' in bpy.ops.transform.shear("),
      shear.executedPython)
check("the angle reads in degrees", shear.parameters[0].display == "20.0°", shear.parameters[0].display)
let shearObjects = LastOperator.shearObjects()
check("Object Mode's Shear is the same call, in Object Mode, undone through Blender's undo",
      shearObjects.python == shear.python && !shearObjects.needsEditMode
      && shearObjects.restoration == .throughBlenderUndo
      && shearObjects.refusal == "Shear moves the selected objects: select some first", shearObjects.python)
var steep = shear
steep["angle"] = 3
check("and stops at 80°, short of tan(90°)", abs((steep["angle"] ?? 0) - 80 * .pi / 180) < 1e-9)
check("six axis pairs, never an axis with itself",
      LastOperator.shearAxes.count == 6 && LastOperator.shearAxes.allSatisfy { option in
          let letters = option.identifier.filter { "XYZ".contains($0) }
          return letters.count == 2 && letters.first != letters.last
      })
var pair = shear
pair["orient_axis"] = 3
check("a pair is both keywords: X, ortho Z reads Along Z, by Y",
      pair.python.contains("orient_axis='X', orient_axis_ortho='Z'")
      && pair.parameters[1].display == "Along Z, by Y", pair.python)

print("\nthe Object menu's rows")
let parent = LastOperator.parent(keepTransform: false)
check("Parent ▸ Object: parent_set with type OBJECT and Keep Transform off",
      parent.python.hasSuffix("bpy.ops.object.parent_set(keep_transform=False, type='OBJECT')")
      && parent.name == "Make Parent", parent.python)
check("Parent ▸ Object (Keep Transform) is the same row with the switch on",
      LastOperator.parent(keepTransform: true).python.hasSuffix("parent_set(keep_transform=True, type='OBJECT')"))
check("both refuse no active object and nothing else selected first",
      parent.python.contains("if _bk_a is None:") && parent.python.contains("no other object is selected"))
for type in LastOperator.ClearParentType.allCases {
    let op = LastOperator.clearParent(type)
    check("\(type.label): parent_clear(type='\(type.rawValue)'), the Type its panel's one field",
          op.python.hasSuffix("bpy.ops.object.parent_clear(type='\(type.rawValue)')")
          && op.parameters.map(\.key) == ["type"] && op.parameters[0].display == type.label, op.python)
}
check("Clear Parent refuses a selection with no parent in it",
      LastOperator.clearParent(.clear).python.contains("nothing selected has a parent"))
check("Duplicate Linked is Blender's Alt+D macro, its CANCELLED said in words",
      LastOperator.duplicateLinked().python == "bpy.ops.object.duplicate_move_linked()"
      && LastOperator.duplicateLinked().refusal?.contains("none is selected") == true)
check("Join refuses a type Blender cannot join before its poll does",
      LastOperator.join().python.contains("if _bk_a.type not in ('MESH', 'CURVE', 'SURFACE', 'ARMATURE', 'GREASEPENCIL', 'CURVES', 'POINTCLOUD'):")
      && LastOperator.join().python.hasSuffix("bpy.ops.object.join()"))
for target in LastOperator.ConvertTarget.allCases {
    let op = LastOperator.convert(to: target)
    check("Convert ▸ \(target.label): convert(target='\(target.rawValue)') with Keep Original off",
          op.python.hasSuffix("bpy.ops.object.convert(keep_original=False, target='\(target.rawValue)')")
          && op.parameters.map(\.key) == ["keep_original"], op.python)
}
check("Convert ▸ Curve looks for a loose edge in the mesh with its modifiers",
      LastOperator.convert(to: .curve).python.contains("evaluated_get(_bk_dg).data")
      && LastOperator.convert(to: .curve).python.contains("foreach_get('edge_index'"))
for op in [LastOperator.parent(keepTransform: false), .clearParent(.clear), .join(),
           .duplicateLinked(), .convert(to: .mesh)] {
    check("\(op.name): in Object Mode, adjustable through Blender's undo only",
          op.requiredBlenderMode == "OBJECT" && op.restoration == .throughBlenderUndo)
    let undo = BpyBridge.performBody(for: op, backup: false)
    let checkpoint = BpyBridge.performBody(for: op, backup: true)
    check("\(op.name): with Blender's undo the panel opens; without it, it runs with none",
          undo.contains("    _bk_adjustable = True") && !checkpoint.contains("_bk_adjustable = True")
          && checkpoint.contains(op.call) && !checkpoint.contains("_bk_redo"))
    check("\(op.name): its re-run is the call alone, never a restoration",
          { var o = op; o.subject = "A"; return o.rerunPython == o.executedPython }())
}

print("\nwhich rows are offered")
func scene(_ names: [String], selected: [String], active: String?, parents: [String: String] = [:]) -> BKScene {
    let s = BKScene(startupFile: false)
    s.objects = names.map { BKObject(name: $0, kind: .cube) }
    for object in s.objects { object.parentName = parents[object.name] }
    s.selection = Set(s.objects.filter { selected.contains($0.name) }.map(\.id))
    s.activeID = s.objects.first { $0.name == active }?.id
    return s
}
let two = ObjectRelationState(scene: scene(["A", "B"], selected: ["A", "B"], active: "A"),
                              editing: false, isRunning: false)
check("two selected, one active: every row", two.canDuplicate && two.canJoin && two.canParent
      && two.canConvert && !two.canClearParent)
let one = ObjectRelationState(scene: scene(["A", "B"], selected: ["A"], active: "A"),
                              editing: false, isRunning: false)
check("one selected: no Join and no Parent, which need another", !one.canJoin && !one.canParent
      && one.canDuplicate && one.canConvert)
let child = ObjectRelationState(scene: scene(["A", "B"], selected: ["B"], active: "B", parents: ["B": "A"]),
                                editing: false, isRunning: false)
check("a child selected: Clear Parent", child.canClearParent)
let editing = ObjectRelationState(scene: scene(["A", "B"], selected: ["A", "B"], active: "A"),
                                  editing: true, isRunning: false)
check("in Edit Mode, none: Blender's Object menu is not there",
      !editing.canDuplicate && !editing.canJoin && !editing.canParent && !editing.canConvert && !editing.available)
let running = ObjectRelationState(scene: scene(["A"], selected: ["A"], active: "A"), editing: false, isRunning: true)
check("nor while a script runs", !running.canDuplicate && !running.canConvert)

print("\nthe Outliner's parent tree")
func tree(_ s: BKScene, _ search: String = "") -> String {
    s.outlinerRows(matching: search).map { String(repeating: ">", count: $0.depth) + $0.object.name
        + ($0.hasChildren ? "+" : "") }.joined(separator: " ")
}
equal("children under their parent, a level in, in the scene's order",
      tree(scene(["A", "B", "C", "D"], selected: [], active: nil, parents: ["B": "A", "D": "A"])),
      "A+ >B >D C")
equal("a chain goes a level deeper each time, whichever order the scene lists them",
      tree(scene(["C", "B", "A"], selected: [], active: nil, parents: ["C": "B", "B": "A"])),
      "A+ >B+ >>C")
equal("a parent the mirror does not hold leaves its child at the top",
      tree(scene(["B"], selected: [], active: nil, parents: ["B": "Gone"])), "B")
equal("a loop is broken, and nobody goes missing",
      tree(scene(["A", "B"], selected: [], active: nil, parents: ["A": "B", "B": "A"])), "A+ >B")
equal("an object is never its own parent",
      tree(scene(["A"], selected: [], active: nil, parents: ["A": "A"])), "A")
equal("a search lists the matches flat",
      tree(scene(["Body", "Wheel.L", "Wheel.R"], selected: [], active: nil,
                 parents: ["Wheel.L": "Body", "Wheel.R": "Body"]), "wheel"),
      "Wheel.L Wheel.R")

print("\nthe selection a redo-panel re-run hands back")
let restore = Bpy.objectSelection(["B"], active: "C")
check("it selects exactly those, and makes the active one active, in Object Mode only",
      restore.hasPrefix("if getattr(bpy.context.view_layer.objects.active, 'mode', 'OBJECT') == 'OBJECT':")
      && restore.contains("_bk_keep = set([\"B\"])")
      && restore.contains("bpy.context.view_layer.objects.active = bpy.data.objects.get(\"C\")"), restore)
check("with no active object it clears the active one",
      Bpy.objectSelection([], active: nil).contains("bpy.context.view_layer.objects.active = None"))
check("the object selection goes before the edit selection, and nothing is sent for neither",
      BpyBridge.rerunLead(selection: "S", editPush: "E") == "S\nE"
      && BpyBridge.rerunLead(selection: nil, editPush: nil) == nil
      && BpyBridge.rerunLead(selection: nil, editPush: "E") == "E")

/// Answers the history's calls the way `_blenderkit_undo` does (the same
/// stand-in tests/undo uses), and records what was sent.
final class HistoryRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sent: [String] = []
    var index = -1
    var steps = 0
    var rewound = false
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "history" }
    func state() -> [BpyLine] {
        [BpyLine(.output, #"{"undo": \#(index > 0), "redo": \#(index + 1 < steps), "undo_label": "Step", "redo_label": "", "mode": "blender", "why": "scripted", "steps": \#(steps), "index": \#(index), "timing": {"total": 0.5}}"#)]
    }
    func answer(_ source: String) -> [BpyLine] {
        sent.append(source)
        if source.contains("_bk_undo.push(") {
            if !source.contains("replace=True") || index < 0 || rewound { index += 1 }
            rewound = false
            steps = index + 1
            return state()
        }
        if source.contains("_bk_undo.rewind()") { index -= 1; rewound = true; return state() }
        if source.contains("print(_bk_adjustable)") { return [BpyLine(.output, "True"), BpyLine(.output, "C")] }
        return []
    }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] { answer(source) }
    func query(_ source: String, scene: BKScene) -> [BpyLine] { answer(source) }
}

do {
    let device = HistoryRuntime()
    let s = scene(["A", "B", "C"], selected: ["B"], active: "C")
    let undo = UndoStack()
    let session = BpySession(runtime: device)
    session.bind(scene: s, undo: undo)
    let bridge = BpyBridge(session: session, scene: s, undo: undo)
    bridge.perform(.parent(keepTransform: false))
    check("Parent opens the redo panel where Blender's undo keeps the history",
          bridge.adjustable?.name == "Make Parent", bridge.adjustable?.name ?? "none")
    // Blender changes the selection; the mirror would show it. The re-run
    // must still act on what Parent ran on.
    s.selection = []
    var keep = bridge.adjustable!
    keep["keep_transform"] = 1
    let before = device.sent.count
    let adjusted = bridge.readjust(keep)
    let rerun = device.sent.dropFirst(before).first { $0.contains("bpy.ops.object.parent_set(") } ?? ""
    let restoreAt = rerun.range(of: "_bk_keep = set([\"B\"])")
    let callAt = rerun.range(of: "parent_set(keep_transform=True, type='OBJECT')")
    check("the re-run hands back B selected and C active before the call, after the rewind",
          adjusted != nil && restoreAt != nil && callAt != nil && restoreAt!.lowerBound < callAt!.lowerBound
          && rerun.contains("objects.get(\"C\")")
          && device.sent.dropFirst(before).firstIndex { $0.contains("_bk_undo.rewind()") }
             .map { $0 < device.sent.dropFirst(before).firstIndex { $0.contains("parent_set(") }! } == true,
          rerun)
    withExtendedLifetime(s) {}
}
do {
    // A mesh operator's re-run carries no object selection: it runs on the
    // mesh being edited, whose own selection is the edit push's business.
    let device = HistoryRuntime()
    let s = scene(["A"], selected: ["A"], active: "A")
    let undo = UndoStack()
    let session = BpySession(runtime: device)
    session.bind(scene: s, undo: undo)
    let bridge = BpyBridge(session: session, scene: s, undo: undo)
    bridge.perform(.mesh(.unsubdivide))
    var op = bridge.adjustable!
    op["iterations"] = 1
    let before = device.sent.count
    _ = bridge.readjust(op)
    let rerun = device.sent.dropFirst(before).first { $0.contains("bpy.ops.mesh.unsubdivide(") } ?? ""
    check("an edit-mode operator's re-run hands back no object selection",
          !rerun.isEmpty && !rerun.contains("_bk_keep"), rerun)
    withExtendedLifetime(s) {}
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
