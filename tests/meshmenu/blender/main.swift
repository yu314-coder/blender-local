import Foundation
import simd

// Every call the Mesh menu's round-4 rows send, printed for a real Blender to
// run (tests/meshmenu/blender/verify.py): what the bridge sends for a first
// press (`BpyBridge.performBody`), a few panel changes, Extrude to Cursor or
// Add's line, and Rip Vertices and Extend's, from the pointers below.
// Generated from the catalogue, so what Blender runs is what the app sends.

var out: [String] = []
func emit(_ head: String, _ body: String) { out.append("### \(head)\n\(body)") }

/// The views the pointer rows are run from: the eye, the line of sight, the
/// up, perspective or not. verify.py aims Blender's own 3D View the same way
/// and asks Blender's own operators where its pointer would be.
let looks: [(eye: SIMD3<Float>, at: SIMD3<Float>, ortho: Bool)] = [
    (SIMD3(6, -7, 5), SIMD3(0.2, 0.1, 0.3), false),
    (SIMD3(6, -7, 5), SIMD3(0.2, 0.1, 0.3), true),
    (SIMD3(-5, -4, 6), SIMD3(0, 0, 0), false),
    (SIMD3(0.5, -9, 1.5), SIMD3(0.5, 0, 1), true),
]
let cursors: [SIMD3<Float>] = [SIMD3(2, -1, 2.5), SIMD3(-1.5, 0.7, 1.8), SIMD3(0, 3, -2)]
var pointers: [MeshPointer] = []
for look in looks {
    for cursor in cursors {
        pointers.append(MeshPointer(eye: look.eye, forward: simd_normalize(look.at - look.eye), up: SIMD3(0, 0, 1),
                                    orthographic: look.ortho, cursor: cursor))
    }
}
func json(_ p: MeshPointer) -> String {
    func v(_ x: SIMD3<Float>) -> String { "[\(x.x), \(x.y), \(x.z)]" }
    return "{\"eye\": \(v(p.eye)), \"forward\": \(v(p.forward)), \"up\": \(v(p.up)), "
        + "\"ortho\": \(p.orthographic), \"cursor\": \(v(p.cursor))}"
}

// The rows, each first press as the menu makes it, from the first pointer —
// as the bridge sends it on the device, where Blender's undo keeps the
// history and no mesh backup is taken (`backup: false`); the backup's path is
// tests/redo/blender's, for every Mesh row.
for m in LastOperator.Mesh.allCases where LastOperator.Mesh.roundFourRows.contains(m)
    || [.mergeAtCenter, .recalculateNormals, .recalculateInside].contains(m) {
    emit("row.\(m.rawValue) PERFORM",
         BpyBridge.performBody(for: LastOperator.mesh(m, spinningAround: nil, pointer: pointers[0]), backup: false))
}
// Panel changes, re-run as a first press with those values.
func variant(_ m: LastOperator.Mesh, _ name: String, _ change: (inout LastOperator) -> Void) {
    var op = LastOperator.mesh(m, spinningAround: nil, pointer: pointers[0])
    change(&op)
    emit("row.\(m.rawValue).\(name) PERFORM", BpyBridge.performBody(for: op, backup: false))
}
variant(.extrudeManifold, "in") { $0["value.z"] = -0.5 }
variant(.mergeAtCenter, "last") { $0["type"] = 4 }
variant(.intersectKnife, "self") { $0["mode"] = 0 }
variant(.intersectBoolean, "union") { $0["operation"] = 1 }
variant(.intersectBoolean, "self") { $0["use_self"] = 1 }
variant(.intersectBoolean, "float") { $0["solver"] = 0; $0["threshold"] = 0.0005 }
variant(.averageFaceArea, "weight") { $0["weight"] = 90 }
variant(.pointNormals, "spherize") { $0["spherize"] = 1; $0["spherize_strength"] = 0.5 }
variant(.smoothLaplacian, "five") { $0["repeat"] = 5; $0["lambda_factor"] = 2 }
variant(.ripVerticesExtend, "moved") { $0["value.x"] = 0.25; $0["value.z"] = -0.5 }
variant(.deleteEdgeLoops, "nosplit") { $0["use_face_split"] = 0 }

// Extrude to Cursor or Add and Rip Vertices and Extend, from every pointer.
for (i, p) in pointers.enumerated() {
    emit("pointer.\(i) VIEW", json(p))
    emit("pointer.\(i) EXTRUDE", MeshMenuTools.extrudeToCursorPython(p))
    emit("pointer.\(i) NOROT", MeshMenuTools.extrudeToCursorPython(p, rotateSource: false))
    emit("pointer.\(i) RIP", BpyBridge.performBody(for: LastOperator.mesh(.ripVerticesExtend, spinningAround: nil,
                                                                             pointer: p), backup: false))
}
print(out.joined(separator: "\n#--\n"))
