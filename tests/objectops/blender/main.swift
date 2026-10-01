import Foundation
import simd

// Object ▸ Duplicate Linked, Join, Parent, Clear Parent and Convert, the Mesh
// menu's clean-up, split and extrude rows, Bevel Vertices, Inset Individual
// and Shear — both halves.
//
//   dump                  every string the 3D View sends for them, as `perform`
//                         sends it on a device where Blender's undo keeps the
//                         history (and as the checkpoint fallback sends the
//                         object ones), with the undo history's own push and
//                         rewind — for a headless Blender to run (verify.py).
//   dump <passes.json>    what Blender's own `_blenderkit_sync.sync()` pushed
//                         after them, replayed through the Swift the device
//                         runs (`SceneMirror`, `carryRelations`, the
//                         Outliner's `outlinerRows`) and held to what Blender
//                         says it has: the hierarchy in the Outliner, the
//                         joined, duplicated and converted objects on screen.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

func dump() {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
    /// What `perform` sends with Blender's undo keeping the history, and what
    /// the checkpoint fallback sends.
    func performed(_ name: String, _ op: LastOperator) {
        emit(name, BpyBridge.performBody(for: op, backup: false))
        emit(name + "_CHECKPOINT", BpyBridge.performBody(for: op, backup: true))
    }
    emit("PUSH", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false,
                                           forceCheckpoints: false))
    emit("PUSH_REPLACE", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: true,
                                                   forceCheckpoints: false))
    emit("REWIND", BackendHistoryPython.rewind)
    emit("UNDO", BackendHistoryPython.step(-1))
    emit("REDO", BackendHistoryPython.step(1))

    performed("DUP_LINKED", .duplicateLinked())
    performed("JOIN", .join())
    performed("PARENT", .parent(keepTransform: false))
    performed("PARENT_KEEP", .parent(keepTransform: true))
    for type in LastOperator.ClearParentType.allCases {
        performed("CLEAR_" + type.rawValue, .clearParent(type))
    }
    /// What `readjustThroughUndo` runs after the rewind: the object
    /// selection the operator ran on — as `perform` read it from the mirror —
    /// then the body with the panel's values.
    func adjusted(_ name: String, _ op: LastOperator, selected: [String], active: String) {
        emit(name, BpyBridge.script(push: BpyBridge.rerunLead(selection: Bpy.objectSelection(selected, active: active),
                                                              editPush: nil),
                                    discardBackup: false, body: BpyBridge.performBody(for: op, backup: false)))
        // Without the selection, as the bridge ran it before 2026-09-22.
        emit(name + "_BODY_ONLY", BpyBridge.performBody(for: op, backup: false))
    }
    // The panel's Type field, moved from the first row's value.
    var clearToInverse = LastOperator.clearParent(.clear)
    clearToInverse["type"] = 2
    adjusted("CLEAR_ADJUSTED_INVERSE", clearToInverse, selected: ["B"], active: "B")
    var keepAdjusted = LastOperator.parent(keepTransform: false)
    keepAdjusted["keep_transform"] = 1
    adjusted("PARENT_ADJUSTED_KEEP", keepAdjusted, selected: ["B"], active: "C")
    for target in LastOperator.ConvertTarget.allCases {
        performed("CONVERT_" + target.rawValue, .convert(to: target))
        var keep = LastOperator.convert(to: target)
        keep["keep_original"] = 1
        performed("CONVERT_" + target.rawValue + "_KEEP", keep)
        adjusted("CONVERT_" + target.rawValue + "_ADJUSTED_KEEP", keep, selected: ["A"], active: "A")
    }

    // The Mesh menu's new rows, as the menu builds them.
    let rows: [LastOperator.Mesh] = [.bevelVertices, .extrudeIndividual, .splitSelection,
                                     .edgeSplitEdges, .edgeSplitVertices, .unsubdivide,
                                     .beautifyFaces, .limitedDissolve, .deleteLoose, .fillHoles,
                                     .bevel, .inset, .extrude]
    for m in rows {
        performed("MESH_" + m.rawValue, .mesh(m, spinningAround: .zero))
    }
    func variant(_ name: String, _ m: LastOperator.Mesh, _ key: String, _ value: Double) {
        var op = LastOperator.mesh(m, spinningAround: .zero)
        op[key] = value
        performed(name, op)
    }
    variant("MESH_unsubdivide_1", .unsubdivide, "iterations", 1)
    variant("MESH_fillHoles_3", .fillHoles, "sides", 3)
    variant("MESH_fillHoles_0", .fillHoles, "sides", 0)
    variant("MESH_edgeSplitEdges_VERT", .edgeSplitEdges, "type", 1)
    variant("MESH_deleteLoose_faces", .deleteLoose, "use_faces", 1)
    variant("MESH_deleteLoose_noverts", .deleteLoose, "use_verts", 0)
    variant("MESH_extrudeIndividual_in", .extrudeIndividual, "TRANSFORM_OT_shrink_fatten", -0.2)
    variant("MESH_bevel_VERTICES", .bevel, "affect", 0)
    variant("MESH_bevelVertices_EDGES", .bevelVertices, "affect", 1)
    variant("MESH_inset_individual", .inset, "use_individual", 1)
    variant("MESH_limitedDissolve_0", .limitedDissolve, "angle_limit", 0)

    performed("SHEAR", .shear())
    performed("SHEAR_OBJECTS", .shearObjects())
    for (i, option) in LastOperator.shearAxes.enumerated() {
        var op = LastOperator.shear()
        op["orient_axis"] = Double(i)
        op["angle"] = 0.5
        emit("SHEAR_AXES_\(i)", BpyBridge.performBody(for: op, backup: false))
        emit("SHEAR_AXES_\(i)_LABEL", option.label)
    }
    var steep = LastOperator.shear()
    steep["angle"] = 2
    emit("SHEAR_STEEP", BpyBridge.performBody(for: steep, backup: false))
    emit("SHEAR_STEEP_ANGLE", LastOperator.number(steep["angle"] ?? 0))
    print(out.joined(separator: "\n#--\n"))
}

// MARK: - the replay

struct Call: Decodable {
    let call: String
    let name: String
    let kind: String?
    let matrix: String?
    let positions: String?
    let normals: String?
    let triangles: String?
    let selected: Int?
    let active: Int?
    let edges: String?
    let record: String?
    let type: String?
    let dataName: String?
    let parent: String?
    let names: [String]?
    let values: String?
}
struct Truth: Decodable {
    let type: String
    let parent: String?
    let depth: Int
    let drawn: Bool
    let vertices: Int
    let edges: Int
    let triangles: Int
}
struct Pass: Decodable {
    let name: String
    let calls: [Call]
    let blender: [String: Truth]
    let order: [String]
}

func values<T>(_ base64: String?, as: T.Type) -> [T] {
    guard let base64, let data = Data(base64Encoded: base64) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

/// One pass onto `scene` — empty at first, then the last pass's, as every
/// pass after the first is on a device.
func replay(_ pass: Pass, onto scene: BKScene) {
    let previous = Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var pending: [BKObject] = []
    var unchanged: Set<String> = []
    var selection: Set<UUID> = []
    var active: UUID?
    var refused: [String] = []
    for call in pass.calls {
        switch call.call {
        case "push":
            let matrix = values(call.matrix, as: Double.self)
            let positions = values(call.positions, as: Float.self)
            let normals = values(call.normals, as: Float.self)
            let triangles = values(call.triangles, as: UInt32.self)
            let made = matrix.withUnsafeBufferPointer { m in
                positions.withUnsafeBufferPointer { p in
                    normals.withUnsafeBufferPointer { n in
                        triangles.withUnsafeBufferPointer { t in
                            SceneMirror.object(named: call.name, kind: call.kind ?? "MESH", matrix: m,
                                               positions: p, normals: n, triangles: t, colour: nil,
                                               previous: previous[call.name])
                        }
                    }
                }
            }
            guard let made else { refused.append(call.name); continue }
            if made.unchanged { unchanged.insert(call.name) }
            pending.append(made.object)
            if call.selected == 1 { selection.insert(made.object.id) }
            if call.active == 1 { active = made.object.id }
        case "edges":
            guard let target = pending.last(where: { $0.name == call.name }),
                  let valid = values(call.edges, as: UInt32.self).withUnsafeBufferPointer({
                      SceneMirror.edges($0, vertexCount: target.mesh.vertices.count)
                  })
            else { refused.append(call.name); continue }
            if SceneMirror.installEdges(valid, on: target) { unchanged.remove(call.name) }
        case "modifiers":
            pending.last(where: { $0.name == call.name })?.modifiers = Modifier.stack(from: call.record ?? "")
        case "display":
            if let target = pending.last(where: { $0.name == call.name }) {
                target.display = ObjectDisplay(type: call.type ?? "", dataName: call.dataName ?? "",
                                               record: call.record ?? "")
            }
        case "relations":
            // What `bk_sync_relations` does with `_push_relations`' call.
            if !SceneMirror.carryRelations(parent: call.parent, dependencies: call.names ?? [],
                                           named: call.name, pass: pending) {
                refused.append(call.name + " (relations)")
            }
        case "knots":
            if !SceneMirror.carryKnots(values(call.values, as: Float.self), named: call.name, pass: pending) {
                refused.append(call.name + " (knots)")
            }
        default:
            break
        }
    }
    check("\(pass.name): every buffer Blender's sync pushed is accepted", refused.isEmpty,
          refused.joined(separator: ", "))
    SceneMirror.merge(pending, into: scene, unchanged: unchanged, selection: selection, active: active)
}

func replayAll(_ path: String) -> Int32 {
    let passes = try! JSONDecoder().decode([Pass].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var scene = BKScene(startupFile: false)
    scene.objects = []
    for pass in passes {
        print("\n\(pass.name)")
        // A pass that begins a new scene in Blender begins a new one here:
        // the mirror merges by name, and a fresh file reuses names.
        if pass.name.hasPrefix("new:") {
            scene = BKScene(startupFile: false)
            scene.objects = []
        }
        replay(pass, onto: scene)
        let shown = Set(scene.objects.map(\.name))
        check("\(pass.name): the objects on screen are Blender's",
              shown == Set(pass.blender.keys),
              "on screen \(shown.sorted()), Blender \(pass.blender.keys.sorted())")
        let rows = scene.outlinerRows()
        let rowIndex = Dictionary(rows.enumerated().map { ($1.object.name, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, truth) in pass.blender.sorted(by: { $0.key < $1.key }) {
            guard let object = scene.objects.first(where: { $0.name == name }) else { continue }
            check("\(pass.name): \(name) is \(truth.type) with parent \(truth.parent ?? "none"), as in Blender",
                  object.blenderType == truth.type && object.parentName == truth.parent,
                  "\(object.blenderType), parent \(object.parentName ?? "none")")
            guard let at = rowIndex[name] else {
                check("\(pass.name): \(name) has an Outliner row", false); continue
            }
            let row = rows[at]
            var placed = row.depth == truth.depth
            if let parent = truth.parent, let parentAt = rowIndex[parent] {
                // Under its parent: after it, a level deeper, with nothing
                // shallower between them.
                placed = placed && parentAt < at && rows[parentAt].depth == row.depth - 1
                    && rows[(parentAt + 1)..<at].allSatisfy { $0.depth >= row.depth }
            }
            check("\(pass.name): the Outliner lists \(name) \(truth.depth) level(s) in"
                  + (truth.parent.map { ", under \($0)" } ?? ", at the top"),
                  placed, "depth \(row.depth), row \(at) of \(rows.map { "\($0.depth)\($0.object.name)" })")
            if truth.drawn, truth.vertices > 0, truth.type == "MESH" {
                check("\(pass.name): \(name) is drawn with Blender's \(truth.vertices) vertices and "
                      + "\(truth.triangles) triangles",
                      object.mesh.vertices.count == truth.vertices
                          && object.mesh.indices.count / 3 == truth.triangles,
                      "\(object.mesh.vertices.count), \(object.mesh.indices.count / 3)")
            }
            if truth.drawn, truth.type == "CURVE", truth.triangles == 0, truth.edges > 0 {
                check("\(pass.name): the curve \(name) is drawn as its \(truth.edges) edges",
                      object.mesh.isWire && object.mesh.edges.count / 2 == truth.edges,
                      "\(object.mesh.edges.count / 2) edges, wire \(object.mesh.isWire)")
            }
        }
        let parents = Set(pass.blender.values.compactMap(\.parent))
        for row in rows {
            check("\(pass.name): \(row.object.name) offers its children only if it has some",
                  row.hasChildren == parents.contains(row.object.name))
        }
        // The menu rows' state, read from the same scene.
        let state = ObjectRelationState(scene: scene, editing: false, isRunning: false)
        let selectedParent = pass.blender.contains { name, truth in
            truth.parent != nil && scene.objects.contains { $0.name == name && scene.selection.contains($0.id) }
        }
        check("\(pass.name): Clear Parent is offered exactly when something selected has a parent",
              state.canClearParent == selectedParent)
    }
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    return failures == 0 ? 0 : 1
}

if CommandLine.arguments.count > 1 {
    exit(replayAll(CommandLine.arguments[1]))
}
dump()
