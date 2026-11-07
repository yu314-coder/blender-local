import Foundation
import simd

// The keys build 58 added that Blender runs (docs/blender-local.md, "November
// 8"): what the Swift sends for each, printed for a headless Blender to run
// (verify.py) — Fill (Alt+F), Triangulate Faces at Fixed and Clip
// (Shift+Ctrl+T), Ctrl+G's Vertex Groups rows, K's Insert Keyframe Menu, and
// Ctrl+M's Interactive Mirror as its commit goes.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("#-- \(name)\n\(body)") }

// Alt+F, as `perform` runs it: the call with its refusal.
emit("FILL", LastOperator.mesh(.fill).executedPython)
// Shift+Ctrl+T: Triangulate Faces started at Fixed and Clip, and Ctrl+T's.
var fixed = LastOperator.mesh(.triangulate)
fixed["quad_method"] = 1
fixed["ngon_method"] = 1
emit("TRIANGULATE_FIXED", fixed.executedPython)
emit("TRIANGULATE", LastOperator.mesh(.triangulate).executedPython)

// Ctrl+G's rows.
emit("ASSIGN_NEW", GroupsBpy.assignNew(weight: 0.5, object: "Cube").executed)
emit("REMOVE_FROM_ALL", GroupsBpy.removeFromAll(object: "Cube").executed)
emit("SET_ACTIVE_GROUP", GroupsBpy.setActiveGroupFromMenu("Group", object: "Cube").executed)

// K: the menu's rows, and a row run.
emit("KEYING_ROWS", BpyAnimation.keyingSetRows)
emit("KEYING_LOCATION", BpyAnimation.insertKeyingSet("Location").body)
emit("KEYING_LOCROTSCALE", BpyAnimation.insertKeyingSet("LocRotScale").body)

// Ctrl+M: the commit, as `TransformGizmo.mirrorOperator` builds it from the
// session's frame and pivot.
func mirror(_ axes: [Bool], orientation: TransformOrientation, editing: Bool, centre: SIMD3<Float>,
            individual: Bool = false) -> String {
    let commit = GizmoCommit(kind: .mirror(constraint: axes), orientation: orientation,
                             axes: matrix_identity_float3x3, viewAxes: matrix_identity_float3x3,
                             editing: editing, centre: centre, individualOrigins: individual)
    return LastOperator.gizmo(commit).executedPython
}
emit("MIRROR_X_GLOBAL", mirror([true, false, false], orientation: .global, editing: false, centre: SIMD3(1, 0, 0)))
emit("MIRROR_YZ_LOCAL", mirror([false, true, true], orientation: .local, editing: false, centre: SIMD3(2, 0, 0)))
emit("MIRROR_X_INDIVIDUAL", mirror([true, false, false], orientation: .global, editing: false, centre: .zero,
                                    individual: true))
emit("MIRROR_Z_EDIT", mirror([false, false, true], orientation: .global, editing: true, centre: SIMD3(0, 0, 0.5)))
let panel = LastOperator.gizmo(GizmoCommit(kind: .mirror(constraint: [true, false, false]), orientation: .global,
                                           axes: matrix_identity_float3x3, viewAxes: matrix_identity_float3x3,
                                           editing: false, centre: .zero))
emit("MIRROR_PANEL", panel.name + "\n" + panel.parameters.map(\.label).joined(separator: "|"))

print(out.joined(separator: "\n"))
