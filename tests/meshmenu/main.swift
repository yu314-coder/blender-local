import Foundation
import simd

// The Mesh menu's rows round 4 (group 6) added, the Swift half: the names,
// groups and order the menu draws them in, the calls each row sends, the
// refusals in words, the panels' rows and which are hidden when, the vector
// of a macro's sub-operator, the pointer the 3D cursor stands in for, and
// the rows that cannot run. What Blender makes of the calls is
// scripts/run-meshmenu-blender-check.sh.
//
//     scripts/run-meshmenu-tests.sh

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "\n        " + detail()))
    if !ok { failures += 1 }
}
typealias M = LastOperator.Mesh

print("\n== the rows, where Blender keeps them ==")
let groups: [(M.Group, [String])] = [
    (.merge, ["At Center", "At Cursor", "Collapse", "At First", "At Last", "By Distance"]),
    (.delete, ["Vertices", "Edges", "Faces", "Only Edges & Faces", "Only Faces", "Dissolve Vertices",
               "Dissolve Edges", "Dissolve Faces", "Limited Dissolve", "Collapse Edges & Faces", "Edge Loops"]),
    (.vertex, ["Bevel Vertices", "New Edge/Face from Vertices", "Connect Vertex Path", "Connect Vertex Pairs",
               "Rip Vertices and Extend", "Slide Vertices", "Smooth Vertices", "Smooth Vertices (Laplacian)"]),
    (.mesh, ["Bisect", "Convex Hull", "Symmetrize", "Snap to Symmetry"]),
    (.normals, ["Flip", "Recalculate Outside", "Recalculate Inside", "Set from Faces", "Point to Target…",
                "Smooth Vectors"]),
    (.average, ["Custom Normal", "Face Area", "Corner Angle"]),
    (.extrude, ["Extrude Faces Along Normals", "Extrude Individual Faces", "Extrude Manifold", "Spin"]),
]
for (group, labels) in groups {
    check("\(group.rawValue) holds Blender's rows in its order", group.rows.map(\.menuLabel) == labels,
          "\(group.rows.map(\.menuLabel))")
}
check("the Edge menu has Rotate Edge CW and CCW after Un-Subdivide",
      Array(M.Group.edge.rows.map(\.menuLabel)[4...6]) == ["Un-Subdivide", "Rotate Edge CW", "Rotate Edge CCW"])
check("the Face menu ends with Intersect (Knife), Intersect (Boolean), Weld Edges into Faces",
      Array(M.Group.face.rows.map(\.menuLabel).suffix(3))
      == ["Intersect (Knife)", "Intersect (Boolean)", "Weld Edges into Faces"])
check("Average is drawn inside Normals, after Point to Target…",
      M.Group.average.parent == .normals && M.Group.average.after == .pointNormals
      && M.Group.allCases.filter { $0.parent == nil }.contains(.normals)
      && !M.Group.allCases.filter { $0.parent == nil }.contains(.average))
check("Limited Dissolve is in Clean Up and in Delete, as in Blender; its row names Clean Up",
      M.Group.cleanUp.rows.contains(.limitedDissolve) && M.Group.delete.rows.contains(.limitedDissolve)
      && M.limitedDissolve.group == .cleanUp)

print("\n== redo panel titles and undo steps: the operators' own names (5.2.1's RNA) ==")
let titles: [(M, String, String)] = [
    (.mergeAtCursor, "Merge", "bpy.ops.mesh.merge"), (.mergeAtLast, "Merge", "bpy.ops.mesh.merge"),
    (.deleteOnlyFaces, "Delete", "bpy.ops.mesh.delete"), (.collapseEdgesFaces, "Collapse Edges & Faces", "bpy.ops.mesh.edge_collapse"),
    (.deleteEdgeLoops, "Delete Edge Loop", "bpy.ops.mesh.delete_edgeloop"),
    (.connectVertexPairs, "Vertex Connect", "bpy.ops.mesh.vert_connect"),
    (.ripVerticesExtend, "Extend Vertices", "bpy.ops.mesh.rip_edge_move"),
    (.smoothLaplacian, "Laplacian Smooth Vertices", "bpy.ops.mesh.vertices_smooth_laplacian"),
    (.rotateEdgeCCW, "Rotate Selected Edge", "bpy.ops.mesh.edge_rotate"),
    (.intersectKnife, "Intersect (Knife)", "bpy.ops.mesh.intersect"),
    (.intersectBoolean, "Intersect (Boolean)", "bpy.ops.mesh.intersect_boolean"),
    (.weldEdgesIntoFaces, "Weld Edges into Faces", "bpy.ops.mesh.face_split_by_edges"),
    (.convexHull, "Convex Hull", "bpy.ops.mesh.convex_hull"),
    (.symmetrySnap, "Snap to Symmetry", "bpy.ops.mesh.symmetry_snap"),
    (.recalculateInside, "Recalculate Normals", "bpy.ops.mesh.normals_make_consistent"),
    (.setNormalsFromFaces, "Set Normals from Faces", "bpy.ops.mesh.set_normals_from_faces"),
    (.pointNormals, "Point Normals to Target", "bpy.ops.mesh.point_normals"),
    (.averageCornerAngle, "Average Normals", "bpy.ops.mesh.average_normals"),
    (.smoothNormals, "Smooth Normals Vectors", "bpy.ops.mesh.smooth_normals"),
    (.extrudeManifold, "Extrude Manifold", "bpy.ops.mesh.extrude_manifold"),
]
for (m, title, call) in titles {
    let op = LastOperator.mesh(m)
    check("\(m.menuLabel): \(title), \(call)", op.name == title && op.call == call, "\(op.name) \(op.call)")
}
check("each is offered in Edit Mode only, but Recalculate Inside",
      M.roundFourRows.allSatisfy(\.editModeOnly) && !M.recalculateInside.editModeOnly
      && M.roundFourRows.count == 28, "\(M.roundFourRows.count)")

print("\n== the calls ==")
func line(_ m: M, _ change: (inout LastOperator) -> Void = { _ in }) -> String {
    var op = LastOperator.mesh(m)
    change(&op)
    return op.python.split(separator: "\n").last.map(String.init) ?? ""
}
check("Merge ▸ At First: merge(type='FIRST', uvs=False)", line(.mergeAtFirst) == "bpy.ops.mesh.merge(type='FIRST', uvs=False)",
      line(.mergeAtFirst))
check("At Center keeps its call, now with Blender's five types and UVs",
      line(.mergeAtCenter) == "bpy.ops.mesh.merge(type='CENTER', uvs=False)"
      && LastOperator.mesh(.mergeAtCenter).parameters.first?.label == "Type", line(.mergeAtCenter))
check("the panel's Type switches the call: At Center to At Last",
      line(.mergeAtCenter) { $0["type"] = 4 } == "bpy.ops.mesh.merge(type='LAST', uvs=False)")
let merge = LastOperator.mesh(.mergeAtFirst)
check("and Merge's check reads the panel's Type, not the row's",
      merge.python.contains("check_merge('FIRST')")
      && { var o = merge; o["type"] = 1; return o.python.contains("check_merge('CURSOR')") }(), merge.python)
for (m, type) in [(M.deleteVertices, "VERT"), (.deleteEdges, "EDGE"), (.deleteFaces, "FACE"),
                  (.deleteEdgesFaces, "EDGE_FACE"), (.deleteOnlyFaces, "ONLY_FACE")] {
    let op = LastOperator.mesh(m)
    check("Delete ▸ \(m.menuLabel): delete(type='\(type)'), no field (Type is hidden in Blender's panel)",
          op.python == "bpy.ops.mesh.delete(type='\(type)')" && op.parameters.isEmpty, op.python)
    check("  and its CANCELLED is said in words, kept out of the Info log",
          op.executedPython.contains("if 'CANCELLED' in bpy.ops.mesh.delete(type='\(type)'):")
          && op.executedPython.contains("RuntimeError(\"Delete ▸ \(m.menuLabel)") && !op.python.contains("raise"))
}
check("Rotate Edge CW and CCW: use_ccw False and True, Blender's Counter Clockwise",
      line(.rotateEdgeCW) == "bpy.ops.mesh.edge_rotate(use_ccw=False)"
      && line(.rotateEdgeCCW) == "bpy.ops.mesh.edge_rotate(use_ccw=True)"
      && LastOperator.mesh(.rotateEdgeCW).parameters.map(\.label) == ["Counter Clockwise"])
check("Recalculate Outside and Inside: the checkbox Inside",
      line(.recalculateNormals) == "bpy.ops.mesh.normals_make_consistent(inside=False)"
      && line(.recalculateInside) == "bpy.ops.mesh.normals_make_consistent(inside=True)"
      && LastOperator.mesh(.recalculateInside).parameters.map(\.label) == ["Inside"])
check("Average ▸ Face Area: average_type='FACE_AREA', weight=50, threshold=0.01",
      line(.averageFaceArea) == "bpy.ops.mesh.average_normals(average_type='FACE_AREA', weight=50, threshold=0.01)",
      line(.averageFaceArea))
check("Smooth Vertices (Laplacian) with Blender's defaults, its border factor sent as Blender's 5e-5",
      line(.smoothLaplacian) == "bpy.ops.mesh.vertices_smooth_laplacian(repeat=1, lambda_factor=1, "
      + "lambda_border=0.00005, use_x=True, use_y=True, use_z=True, preserve_volume=True)", line(.smoothLaplacian))
check("  the negative control: at the usual four places it would have been 0.0001",
      LastOperator.number(5e-5) == "0.0001")
check("  and by Blender's labels", LastOperator.mesh(.smoothLaplacian).parameters.map(\.label)
      == ["Number of iterations to smooth the mesh", "Lambda factor", "Lambda factor in border", "Smooth X Axis",
          "Smooth Y Axis", "Smooth Z Axis", "Preserve Volume"])

print("\n== a sub-operator's vector is one entry of its dictionary ==")
let manifold = line(.extrudeManifold)
check("Extrude Manifold: the Move along the normal's Z, as Blender's row calls it",
      manifold.contains("TRANSFORM_OT_translate={\"value\": (0, 0, 0.2), \"orient_type\": 'NORMAL', "
                        + "\"constraint_axis\": (False, False, True)")
      && manifold.contains("MESH_OT_extrude_region={\"use_normal_flip\": False, \"use_dissolve_ortho_edges\": True"),
      manifold)
check("the negative control: never one key per axis, `\"value.z\": 0.2`, which Blender would refuse",
      !manifold.contains("value.z") && manifold.components(separatedBy: "TRANSFORM_OT_translate=").count == 2, manifold)
check("the panel's Z changes the tuple", line(.extrudeManifold) { $0["value.z"] = -0.5 }.contains("\"value\": (0, 0, -0.5)"))
check("and the one field is Z under Move, the constrained axis",
      LastOperator.mesh(.extrudeManifold).parameters.map { "\($0.label)" } == ["Z"])

print("\n== the pointer: over the 3D cursor, in the app's view ==")
let pointer = MeshPointer(eye: SIMD3(6, -7, 5), forward: simd_normalize(SIMD3(-1, 1, -0.8)), up: SIMD3(0, 0, 1),
                          orthographic: false, cursor: SIMD3(0.5, 0.25, 2))
let rip = LastOperator.mesh(.ripVerticesExtend, spinningAround: nil, pointer: pointer)
check("Rip Vertices and Extend asks for the ray through Blender's cursor from the view's eye",
      rip.python.contains("_bk_ray = _blenderkit_meshmenu.pointer_ray(eye=(6, -7, 5), forward=(")
      && rip.python.contains("ortho=False)") && !rip.python.contains("up="), rip.python)
check("and hands rip_edge the ray, the Move its own dictionary",
      rip.python.contains("bpy.ops.mesh.rip_edge_move(TRANSFORM_OT_translate={\"value\": (0, 0, 0)}, "
                          + "MESH_OT_rip_edge={\"location\": _bk_ray[0], \"direction\": _bk_ray[1]})"), rip.python)
check("under the borrowed 3D View its poll wants",
      rip.python.contains("with _blenderkit_context.temp_override_view3d('Rip Vertices and Extend'):"), rip.python)
check("its panel: Move X, Y, Z", rip.parameters.map(\.label) == ["X", "Y", "Z"]
      && rip.parameters.allSatisfy { $0.member == "TRANSFORM_OT_translate" })
var moved = rip
moved["value.x"] = 0.25
moved["value.z"] = -1
check("a typed Move reaches the call", moved.python.contains("{\"value\": (0.25, 0, -1)}"), moved.python)
check("refused in words when it would change nothing",
      rip.executedPython.contains("could extend none") && !rip.python.contains("could extend none"), rip.executedPython)
let ortho = MeshPointer(eye: SIMD3(0, -10, 0), forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), orthographic: true,
                        cursor: .zero)
check("an orthographic view says so", LastOperator.mesh(.ripVerticesExtend, spinningAround: nil, pointer: ortho)
      .python.contains("ortho=True)"))
let target = LastOperator.mesh(.pointNormals, spinningAround: nil, pointer: pointer)
check("Point to Target…'s Target starts at the 3D cursor",
      target.python.contains("target_location=(0.5, 0.25, 2)"), target.python)
check("its Spherize Strength is shown only with Spherize",
      !target.isShown(target.parameters.first { $0.key == "spherize_strength" }!)
      && { var o = target; o["spherize"] = 1; return o.isShown(o.parameters.first { $0.key == "spherize_strength" }!) }())

print("\n== the rows each panel hides, as Blender's do ==")
for m in [M.intersectKnife, .intersectBoolean] {
    var op = LastOperator.mesh(m)
    let threshold = op.parameters.first { $0.key == "threshold" }!
    check("\(m.menuLabel): Merge Threshold hidden for the Exact solver", !op.isShown(threshold))
    op["solver"] = 0
    check("  and shown for Float", op.isShown(threshold))
    check("  and sent as Blender's 1e-6, not rounded to 0",
          op.python.contains("threshold=0.000001"), op.python)
}
var average = LastOperator.mesh(.averageCustomNormal)
check("Average ▸ Custom Normal hides Weight and Threshold",
      average.parameters.filter { !average.isShown($0) }.map(\.label) == ["Weight", "Threshold"])
average["average_type"] = 2
check("  Corner Angle shows them", average.parameters.allSatisfy { average.isShown($0) })

print("\n== refused before Blender is asked ==")
for m in [M.collapseEdgesFaces, .deleteEdgeLoops, .ripVerticesExtend, .convexHull, .intersectKnife,
          .intersectBoolean, .weldEdgesIntoFaces, .setNormalsFromFaces, .smoothNormals, .extrudeManifold,
          .averageFaceArea] {
    let op = LastOperator.mesh(m)
    check("\(m.menuLabel) checks the selection first", op.python.contains("_blenderkit_meshmenu.require("),
          op.python)
}
check("Convex Hull wants three vertices",
      LastOperator.mesh(.convexHull).python.contains("verts=3, edges=0, faces=0"))
for m in [M.collapseEdgesFaces, .deleteEdgeLoops, .connectVertexPairs, .weldEdgesIntoFaces, .ripVerticesExtend,
          .mergeAtCenter, .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast, .smoothLaplacian] {
    check("\(m.menuLabel) says so when Blender changes nothing", LastOperator.mesh(m).unchanged != nil)
}
for m in [M.convexHull, .symmetrySnap, .intersectKnife] {
    check("\(m.menuLabel) does not: its panel's fields decide what there is to do",
          LastOperator.mesh(m).unchanged == nil)
}
check("what changed is read as counts, positions and edges (`edit_state`), so a Merge ▸ At Cursor that "
      + "moves one vertex is not read as nothing done",
      LastOperator.mesh(.mergeAtCursor).executedPython.contains("if _bk_lc.edit_state() == _bk_counts:")
      && !LastOperator.mesh(.mergeAtCursor).executedPython.contains("edit_counts"))
let knife = LastOperator.mesh(.intersectKnife), boolean = LastOperator.mesh(.intersectBoolean)
check("Intersect (Knife) wants an unselected face for Selected/Unselected, as its Source reads",
      knife.python.contains("if 'SELECT_UNSELECT' == 'SELECT_UNSELECT':\n    _blenderkit_meshmenu.require_unselected_faces(")
      && { var o = knife; o["mode"] = 0; return o.python.contains("if 'SELECT' == 'SELECT_UNSELECT':") }(), knife.python)
check("Intersect (Boolean) unless Self Intersection is on",
      boolean.python.contains("if not False:\n    _blenderkit_meshmenu.require_unselected_faces(")
      && { var o = boolean; o["use_self"] = 1; return o.python.contains("if not True:") }(), boolean.python)
check("Extrude Manifold's refusal says it takes faces, edges or vertices, as it does",
      LastOperator.mesh(.extrudeManifold).python.contains("extrudes the selected faces, edges or vertices"))

print("\n== Extrude to Cursor or Add ==")
let extrude = MeshMenuTools.extrudeToCursorPython(pointer)
check("the app's port of Blender's invoke, the pointer over the cursor, Rotate Source on as the menu calls it",
      extrude.contains("_blenderkit_meshmenu.to_cursor(eye=(6, -7, 5), forward=(")
      && extrude.contains("up=(0, 0, 1), ortho=False, rotate_source=True)"), extrude)
check("its step is the operator's name", MeshMenuTools.extrudeToCursor == "Extrude to Cursor or Add")
check("the view's numbers carry six places",
      MeshPointer(eye: SIMD3(0.1234567, 0, 0), forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), orthographic: false,
                  cursor: .zero).pythonArguments().contains("eye=(0.123457, 0, 0)"))

print("\n== the rows Blender cannot run here ==")
check("Rip Vertices and Rip Vertices and Fill are shown, by Blender's names",
      MeshMenuTools.ripRows == ["Rip Vertices", "Rip Vertices and Fill"])
check("and say why, and what works", MeshMenuTools.ripRefusal.contains("pointer")
      && MeshMenuTools.ripRefusal.contains("Rip Vertices and Extend"))
check("Poly Build says what was measured, not 'Blender can do it'",
      ActiveTool.polyBuild.requirement == MeshMenuTools.polyBuildRefusal
      && !ActiveTool.polyBuild.requirement.contains("Blender can do it") && !ActiveTool.polyBuild.isImplemented)
check("Rip Region's tooltip points at the row that works", ActiveTool.ripRegion.requirement == MeshMenuTools.ripRefusal)

print("\n== the Operator Search sends the pointer operators to these rows ==")
// `_blenderkit_sync._POINTER_OPERATORS` refuses Blender's pointer operators
// in the search, naming the Mesh menu row that does the same toward the 3D
// cursor (tests/opsearch/blender holds what Blender makes of it). Every row it
// names has to be one of this menu's, by its label.
let sync = (try? String(contentsOfFile: "Resources/python/site/_blenderkit_sync.py", encoding: .utf8)) ?? ""
/// The labels the search's sentences name after "Mesh ▸ Vertex ▸ ", read up
/// to the first word that is not part of a label, and those of them the Vertex
/// menu does not have.
func namedRows(_ text: String) -> (named: Set<String>, missing: Set<String>) {
    let known = Set(M.Group.vertex.rows.map(\.menuLabel) + MeshMenuTools.ripRows + [MeshMenuTools.extrudeToCursor])
    var named = Set<String>()
    var rest = Substring(text)
    while let r = rest.range(of: "Mesh ▸ \(M.Group.vertex.rawValue) ▸ ") {
        rest = rest[r.upperBound...]
        if rest.hasPrefix("{row}") { continue }
        // The longest label of the menu the text starts with, or the words up
        // to the next verb as an unknown one.
        if let label = known.filter({ rest.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
            named.insert(label)
        } else {
            named.insert(String(rest.prefix { $0 != " " && $0 != "," && $0 != ";" }) + "…")
        }
    }
    let rowArguments = sync.components(separatedBy: "row='").dropFirst().map { String($0.prefix { $0 != "'" }) }
    if text == sync { named.formUnion(rowArguments) }
    return (named, named.subtracting(known))
}
let named = namedRows(sync)
check("the search names \(named.named.count) rows, each one of the Vertex menu's: \(named.named.sorted())",
      named.named.count >= 3 && named.missing.isEmpty, "not the menu's: \(named.missing.sorted())")
check("it names Extrude to Cursor or Add and Rip Vertices and Extend, the rows that run",
      named.named.isSuperset(of: [MeshMenuTools.extrudeToCursor, M.ripVerticesExtend.menuLabel])
      && M.Group.vertex.rows.contains(.ripVerticesExtend))
let renamed = sync.replacingOccurrences(of: "Mesh ▸ Vertex ▸ Rip Vertices and Extend", with: "Mesh ▸ Vertex ▸ Rip Vertex and Extend")
check("  the negative control: with the row misnamed in the sentence the same reading finds a row the menu has not got",
      namedRows(renamed).missing == ["Rip…"], "\(namedRows(renamed).missing)")
check("Extend Vertices' sentence says what the row does: a new vertex split off on the edge toward the cursor, "
      + "moved by the panel's Move — not that it extends toward the cursor",
      sync.contains("gets a new vertex split off on its edge pointing most toward the cursor")
      && sync.contains("which the panel's Move then moves") && !sync.contains("Extend works, toward the 3D cursor"))
check("and so do the row's own refusal and Rip's tooltip",
      LastOperator.mesh(.ripVerticesExtend).python.contains("splits a new vertex off each selected vertex, on its edge pointing most toward the 3D cursor")
      && MeshMenuTools.ripRefusal.contains("splits a new vertex off on the edge pointing most toward the cursor")
      && !MeshMenuTools.ripRefusal.contains("works, toward the 3D cursor"))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
