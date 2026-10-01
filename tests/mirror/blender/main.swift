import Foundation
import simd

// The mirror, end to end: Blender's own `_blenderkit_sync.sync()` pushes a
// scene, and the Swift builds, merges and shows it exactly as the device does.
//
// With no argument this prints what the Add menu sends for a circle and a
// plane, for verify.py to run in a headless Blender. With a path it reads what
// that Blender's sync pushed — every `sync_push`, `sync_edges`,
// `sync_modifiers` and `sync_display`, pass by pass — and replays it through
// `SceneMirror`, the code `bk_sync_push`, `bk_sync_edges` and `bk_sync_end`
// call; the entry points themselves only copy the buffers out of Python.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
if args.count < 2 {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
    // Exactly what Add ▸ Circle and Add ▸ Plane send (`BpyBridge.perform`).
    emit("ADD_CIRCLE", BpyBridge.performBody(for: LastOperator.add(.circle, at: SIMD3(0.3, -0.2, 2))))
    emit("ADD_PLANE", BpyBridge.performBody(for: LastOperator.add(.plane, at: .zero)))
    print(out.joined(separator: "\n#--\n"))
    exit(0)
}

struct Push: Decodable {
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
    let frame: Int?
}
struct Truth: Decodable {
    let type: String
    let vertices: Int
    let edges: Int
    let triangles: Int
    let evaluated: Bool
    /// Blender's evaluated positions, for the small meshes.
    let co: [Float]?
}
struct Pass: Decodable {
    let calls: [Push]
    let blender: [String: Truth]
    /// A frame change (`push_frame`), not a mirroring pass: its meshes go
    /// through `AnimationMirror.applyMesh` onto what is on screen.
    let frame: Bool?
}

func values<T>(_ base64: String?, as: T.Type) -> [T] {
    guard let base64, let data = Data(base64Encoded: base64) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

let passes = try! JSONDecoder().decode([Pass].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let scene = BKScene(startupFile: false)
scene.objects = []
var shown: [[String: BKObject]] = []

func firstPass(_ first: [String: BKObject]) {
    print("\nwhat the first pass put on screen")
    check("the Add menu's circle is a wire of 32 edges",
          first["Circle"]?.mesh.isWire == true && first["Circle"]?.blenderType == "MESH")
    check("an unfilled Bézier circle is a wire too, as a curve",
          first["BezierCircle"]?.mesh.isWire == true && first["BezierCircle"]?.blenderType == "CURVE")
    check("a mesh of loose vertices arrives with its bounds and nothing to draw",
          first["Points"].map { $0.mesh.vertices.count == 2 && $0.mesh.edges.isEmpty } == true)
    check("an empty mesh, an empty text and a curve with no splines arrive as their origin",
          ["EmptyMesh", "EmptyText", "NoSplines"].allSatisfy { first[$0]?.mesh.vertices.count == 1 })
    check("a hidden wire circle arrives hidden",
          first["HiddenCircle"].map { !$0.visible } == true)
    if let huge = first["Huge"] {
        check("a mesh past the limit arrives as its bounding box, 12 lines",
              huge.undrawnVertexCount == passes[0].blender["Huge"]?.vertices
                  && huge.mesh.vertices.count == 8 && huge.mesh.edges.count == 24 && huge.mesh.isWire,
              "\(String(describing: huge.undrawnVertexCount)), \(huge.mesh.vertices.count) vertices")
        let lines = stride(from: 0, to: huge.mesh.edges.count, by: 2).map {
            (huge.mesh.vertices[Int(huge.mesh.edges[$0])].position,
             huge.mesh.vertices[Int(huge.mesh.edges[$0 + 1])].position)
        }
        check("its twelve lines are the box's edges, not diagonals",
              lines.allSatisfy { a, b in (0..<3).filter { a[$0] != b[$0] }.count == 1 })
        let (lo, hi) = ModifierStack.bounds(huge.mesh)
        check("whose box is the object's own bounds", abs(hi.x - lo.x - 2) < 1e-4 && abs(hi.z - lo.z - 2) < 1e-4,
              "\(lo) \(hi)")
    }
    scene.activeID = first["Plane"]?.id
    check("Knife Project offers the circle and the curve to cut the plane with",
          Set(scene.knifeProjectCutters.map(\.name)).isSuperset(of: ["Circle", "BezierCircle"])
              && !scene.knifeProjectCutters.contains { $0.name == "HiddenCircle" || $0.name == "Plane" },
          scene.knifeProjectCutters.map(\.name).joined(separator: ", "))
    check("a mesh with a Screw is drawn at Blender's evaluated count, with its row",
          first["Screwed"].map { $0.modifiers.map(\.kind) == [.screw] } == true)
}

func secondPass(_ first: [String: BKObject], _ second: [String: BKObject]) {
    print("\nthe second pass, onto the first")
    check("the objects on screen keep their identity",
          first["Circle"] === second["Circle"] && first["Plane"] === second["Plane"])
    check("an edge moved between vertices that all stay reaches the screen",
          second["Edges"]?.mesh.edges == [0, 1, 0, 2], "\(second["Edges"]?.mesh.edges ?? [])")
    check("a Screw added to the plane already on screen gets its row",
          second["Plane"]?.modifiers.map(\.kind) == [.screw])
    check("over Blender's evaluated plane, not a second Screw on it",
          second["Plane"]?.mesh.vertices.count == passes[1].blender["Plane"]?.vertices,
          "\(second["Plane"]?.mesh.vertices.count ?? -1) vs \(passes[1].blender["Plane"]?.vertices ?? -1)")
    check("a filled circle is drawn by its faces again",
          second["Circle"].map { !$0.mesh.isWire && !$0.mesh.indices.isEmpty } == true)
    // Its 32 vertices came back identical, which is what the mirror reuses a
    // mesh on; only the empty edge list says the circle is gone.
    check("a wire that lost every edge and kept every vertex draws no line",
          second["Stripped"].map { $0.mesh.edges.isEmpty && !$0.mesh.isWire && $0.mesh.vertices.count == 32 } == true,
          "\(second["Stripped"]?.mesh.edges.count ?? -1) edge indices")
}

func framePass(_ onScreen: [String: BKObject], _ truth: [String: Truth]) {
    print("\nthe frame change, onto the second pass")
    check("the Screw under the Wave is Blender's count, not the Swift Screw run over it",
          onScreen["ScrewWave"]?.mesh.vertices.count == truth["ScrewWave"]?.vertices,
          "\(onScreen["ScrewWave"]?.mesh.vertices.count ?? -1) drawn, \(truth["ScrewWave"]?.vertices ?? -1) in Blender")
    check("and every deformed mesh stays Blender's evaluated one",
          ["Waver", "ScrewWave", "WireWave"].allSatisfy { onScreen[$0]?.meshIsEvaluated == true })
    check("the wire moved with the frame and is still a wire",
          onScreen["WireWave"].map { $0.mesh.isWire && $0.mesh.edges.count / 2 == truth["WireWave"]?.edges } == true)
}

/// What is on screen after pass `index`, object by object, against what
/// Blender held at that moment.
func compare(_ index: Int, _ pass: Pass) {
    let label = pass.frame == true ? "frame \(index + 1)" : "pass \(index + 1)"
    let missing = pass.blender.keys.filter { shown[index][$0] == nil }.sorted()
    check("\(label): every object Blender has is on screen, faces or not", missing.isEmpty,
          "missing: " + missing.joined(separator: ", "))
    for (name, truth) in pass.blender.sorted(by: { $0.key < $1.key }) where truth.evaluated {
        guard let obj = shown[index][name] else { continue }
        let mesh = obj.mesh
        guard obj.undrawnVertexCount == nil else { continue }
        check("\(label): \(name) is drawn with Blender's \(truth.vertices) vertices",
              mesh.vertices.count == truth.vertices, "\(mesh.vertices.count)")
        check("\(label): and its \(truth.triangles) triangles",
              mesh.indices.count / 3 == truth.triangles, "\(mesh.indices.count / 3)")
        if truth.triangles == 0 {
            // Every count, none included: a wire that lost its last edge
            // went on drawing the old ones while this checked only above 0.
            check("\(label): \(name) has no faces, so its \(truth.edges) edges are what is drawn",
                  mesh.edges.count / 2 == truth.edges && mesh.isWire == (truth.edges > 0),
                  "\(mesh.edges.count / 2)")
        }
        if let co = truth.co, co.count == mesh.vertices.count * 3 {
            let worst = mesh.vertices.enumerated().map { i, v in
                max(abs(v.position.x - co[3 * i]), abs(v.position.y - co[3 * i + 1]),
                    abs(v.position.z - co[3 * i + 2]))
            }.max() ?? 0
            check("\(label): and every vertex where Blender has it", worst < 1e-5, "off by \(worst)")
        }
    }
}

for (index, pass) in passes.enumerated() {
    if pass.frame == true {
        // bk_anim_set_mesh, onto the objects the last pass left on screen.
        var refused: [String] = []
        for call in pass.calls where call.call == "frame_mesh" {
            let positions = values(call.positions, as: Float.self)
            let normals = values(call.normals, as: Float.self)
            let triangles = values(call.triangles, as: UInt32.self)
            // No `edges` key: a mesh with faces, which `anim_mesh` is sent
            // without them, as the entry point passes nil.
            let edges: [UInt32]? = call.edges.map { values($0, as: UInt32.self) }
            let rc = positions.withUnsafeBufferPointer { p in
                normals.withUnsafeBufferPointer { n in
                    triangles.withUnsafeBufferPointer { t in
                        if let edges {
                            return edges.withUnsafeBufferPointer { e in
                                AnimationMirror.applyMesh(named: call.name, positions: p, normals: n,
                                                          triangles: t, edges: e, to: scene)
                            }
                        }
                        return AnimationMirror.applyMesh(named: call.name, positions: p, normals: n,
                                                         triangles: t, to: scene)
                    }
                }
            }
            if rc < 0 { refused.append(call.name) }
        }
        check("frame \(index + 1): every mesh Blender's frame change pushed is accepted", refused.isEmpty,
              refused.joined(separator: ", "))
        shown.append(Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
        compare(index, pass)
        framePass(shown[index], pass.blender)
        continue
    }
    // bk_sync_begin .. bk_sync_end, with the buffers the Python handed over.
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
            guard let target = pending.last(where: { $0.name == call.name }) else {
                refused.append(call.name); continue
            }
            let edges = values(call.edges, as: UInt32.self)
            guard let valid = edges.withUnsafeBufferPointer({
                SceneMirror.edges($0, vertexCount: target.mesh.vertices.count)
            }) else { refused.append(call.name); continue }
            if SceneMirror.installEdges(valid, on: target) { unchanged.remove(call.name) }
        case "modifiers":
            pending.last(where: { $0.name == call.name })?.modifiers = Modifier.stack(from: call.record ?? "")
        case "display":
            if let target = pending.last(where: { $0.name == call.name }) {
                target.display = ObjectDisplay(type: call.type ?? "", dataName: call.dataName ?? "",
                                               record: call.record ?? "")
            }
        default:
            break
        }
    }
    check("pass \(index + 1): every buffer Blender's sync pushed is accepted", refused.isEmpty,
          refused.joined(separator: ", "))
    SceneMirror.merge(pending, into: scene, unchanged: unchanged, selection: selection, active: active)
    shown.append(Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))

    compare(index, pass)
    // Read now: the next pass merges onto these very objects.
    if index == 0 { firstPass(shown[0]) }
    if index == 1 { secondPass(shown[0], shown[1]) }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
