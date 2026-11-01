import Foundation
import simd

// The normals the 3D View shades a mesh with, end to end: Blender's own
// `_blenderkit_sync.sync()` (and `_blenderkit_anim.push_mesh`, a frame
// change's and a sculpt stroke's way) pushes the scene, and the Swift the
// device runs installs what it pushed (`SceneMirror.object`, `installEdges`,
// `carryShading`, `merge`, `AnimationMirror.applyMesh`).
//
// With no argument this prints what the Normals menu's rows send for a first
// press (`BpyBridge.performBody`), for verify.py to run in desktop Blender.
// With a path it reads what that Blender pushed, pass by pass, and holds the
// normal every triangle corner is drawn with (`MeshData.shadingNormal`) to
// the corner normals Blender's Solid view draws, read from Blender's
// evaluated mesh beside each pass. The controls: the vertex normals the 3D
// View drew before, and the same passes replayed without `sync_shading`.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
if args.count < 2 {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
    let pointer = MeshPointer(eye: SIMD3(6, -7, 5), forward: simd_normalize(SIMD3(-6, 7, -5)), up: SIMD3(0, 0, 1),
                              orthographic: false, cursor: SIMD3(2, -1, 2.5))
    for m: LastOperator.Mesh in [.setNormalsFromFaces, .pointNormals, .averageCustomNormal, .averageFaceArea,
                                 .averageCornerAngle, .smoothNormals] {
        emit("row.\(m.rawValue)", BpyBridge.performBody(for: LastOperator.mesh(m, spinningAround: nil, pointer: pointer),
                                                       backup: false))
    }
    print(out.joined(separator: "\n#--\n"))
    exit(0)
}

struct Call: Decodable {
    let call: String
    let name: String
    let kind: String?
    let matrix: String?
    let positions: String?
    let normals: String?
    let triangles: String?
    let edges: String?
    let domain: UInt32?
    let loops: String?
}
struct Truth: Decodable {
    /// Blender's `normals_domain` for the evaluated mesh.
    let domain: String
    /// Blender's corner normals, three floats per triangle corner, in the
    /// order of the triangles pushed (hidden faces left out while editing).
    let corners: [Float]
}
struct Pass: Decodable {
    let label: String
    let calls: [Call]
    let blender: [String: Truth]
    /// A frame change (`push_mesh`), not a mirroring pass.
    let frame: Bool?
}

func values<T>(_ base64: String?, as: T.Type) -> [T] {
    guard let base64, let data = Data(base64Encoded: base64) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

/// The angle between two directions, by atan2 in doubles: acos of a Float
/// dot product cannot tell 0° from 0.028° (1 - 1.2e-7).
func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let x = SIMD3<Double>(a), y = SIMD3<Double>(b)
    return Float(atan2(simd_length(simd_cross(x, y)), simd_dot(x, y)) * 180 / .pi)
}

let passes = try! JSONDecoder().decode([Pass].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))

struct Measured {
    let drawn: Float
    let byVertex: Float
    let domain: String
    let corners: Int
    /// What the 3D View draws at each triangle corner, and Blender's.
    var normals: [SIMD3<Float>] = []
    var blender: [SIMD3<Float>] = []
}

/// The worst angle between what the 3D View draws at each triangle corner
/// and Blender's corner normal there, and the same for the vertex normals.
func compare(_ obj: BKObject, _ truth: Truth) -> (drawn: Float, byVertex: Float)? {
    let mesh = obj.mesh
    guard truth.corners.count == 3 * mesh.indices.count, !mesh.indices.isEmpty else { return nil }
    var drawn: Float = 0, byVertex: Float = 0
    for c in mesh.indices.indices {
        let blender = SIMD3(truth.corners[3 * c], truth.corners[3 * c + 1], truth.corners[3 * c + 2])
        drawn = max(drawn, degrees(mesh.shadingNormal(corner: c), blender))
        byVertex = max(byVertex, degrees(mesh.vertices[Int(mesh.indices[c])].normal, blender))
    }
    return (drawn, byVertex)
}

/// Every pass replayed onto one screen, as `bk_sync_begin` … `bk_sync_end`
/// and the frame-change entry points do it; `shading: false` drops every
/// `sync_shading` call (the control).
func replay(shading: Bool) -> [[String: Measured]] {
    let scene = BKScene(startupFile: false)
    scene.objects = []
    var out: [[String: Measured]] = []
    for pass in passes {
        if pass.frame == true {
            for call in pass.calls {
                switch call.call {
                case "frame_mesh":
                    let p: [Float] = values(call.positions, as: Float.self)
                    let n: [Float] = values(call.normals, as: Float.self)
                    let t: [UInt32] = values(call.triangles, as: UInt32.self)
                    p.withUnsafeBufferPointer { pp in n.withUnsafeBufferPointer { nn in t.withUnsafeBufferPointer { tt in
                        _ = AnimationMirror.applyMesh(named: call.name, positions: pp, normals: nn, triangles: tt,
                                                      to: scene)
                    } } }
                case "shading" where shading:
                    let l: [UInt32] = values(call.loops, as: UInt32.self)
                    let n: [Float] = values(call.normals, as: Float.self)
                    var changed = false
                    l.withUnsafeBufferPointer { ll in n.withUnsafeBufferPointer { nn in
                        _ = SceneMirror.carryShading(domain: call.domain ?? 0, triangleLoops: ll, loopNormals: nn,
                                                     named: call.name, pass: nil, screen: scene.objects,
                                                     changed: &changed)
                    } }
                default: break
                }
            }
        } else {
            let previous = Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var pending: [BKObject] = []
            var unchanged = Set<String>()
            for call in pass.calls {
                switch call.call {
                case "push":
                    let m: [Double] = values(call.matrix, as: Double.self)
                    let p: [Float] = values(call.positions, as: Float.self)
                    let n: [Float] = values(call.normals, as: Float.self)
                    let t: [UInt32] = values(call.triangles, as: UInt32.self)
                    let made = m.withUnsafeBufferPointer { mm in p.withUnsafeBufferPointer { pp in
                        n.withUnsafeBufferPointer { nn in t.withUnsafeBufferPointer { tt in
                            SceneMirror.object(named: call.name, kind: call.kind ?? "MESH", matrix: mm, positions: pp,
                                               normals: nn, triangles: tt, colour: nil, previous: previous[call.name])
                        } } } }
                    guard let made else { check("\(pass.label): \(call.name) is pushed", false); continue }
                    if made.unchanged { unchanged.insert(call.name) }
                    pending.append(made.object)
                case "edges":
                    if let target = pending.last(where: { $0.name == call.name }),
                       let checked = values(call.edges, as: UInt32.self).withUnsafeBufferPointer({
                           SceneMirror.edges($0, vertexCount: target.mesh.vertices.count) }) {
                        if SceneMirror.installEdges(checked, on: target) { unchanged.remove(call.name) }
                    }
                case "shading" where shading:
                    let l: [UInt32] = values(call.loops, as: UInt32.self)
                    let n: [Float] = values(call.normals, as: Float.self)
                    var changed = false
                    let taken = l.withUnsafeBufferPointer { ll in n.withUnsafeBufferPointer { nn in
                        SceneMirror.carryShading(domain: call.domain ?? 0, triangleLoops: ll, loopNormals: nn,
                                                 named: call.name, pass: pending, screen: [], changed: &changed)
                    } }
                    if taken < 0 { check("\(pass.label): \(call.name)'s shading is taken", false) }
                    // What `bk_sync_shading` does with a change.
                    if changed { unchanged.remove(call.name) }
                default: break
                }
            }
            SceneMirror.merge(pending, into: scene, unchanged: unchanged, selection: [], active: nil)
        }
        // Measured at once: the next pass changes these same objects.
        var measured: [String: Measured] = [:]
        for (name, truth) in pass.blender {
            guard let obj = scene.objects.first(where: { $0.name == name }) else { continue }
            measured[name] = compare(obj, truth).map {
                Measured(drawn: $0.drawn, byVertex: $0.byVertex,
                         domain: obj.mesh.shadingFits ? "\(obj.mesh.shadingDomain)" : "vertex",
                         corners: obj.mesh.indices.count,
                         normals: obj.mesh.indices.indices.map { obj.mesh.shadingNormal(corner: $0) },
                         blender: stride(from: 0, to: truth.corners.count, by: 3).map {
                             SIMD3(truth.corners[$0], truth.corners[$0 + 1], truth.corners[$0 + 2]) })
            } ?? Measured(drawn: .infinity, byVertex: .infinity, domain: "none", corners: obj.mesh.indices.count)
        }
        out.append(measured)
    }
    return out
}

let shown = replay(shading: true)
let bare = replay(shading: false)
var worstDrawn: Float = 0
var controls: [(String, String, Float)] = []
for (k, pass) in passes.enumerated() {
    print("\n\(pass.label)")
    for name in pass.blender.keys.sorted() {
        let truth = pass.blender[name]!
        guard let result = shown[k][name], result.drawn.isFinite else {
            check("\(name): drawn by as many corners as Blender has (\(truth.corners.count / 3))", false,
                  "\(shown[k][name]?.corners ?? -1) on screen")
            continue
        }
        worstDrawn = max(worstDrawn, result.drawn)
        check("\(name) (Blender's \(truth.domain)): drawn by its \(result.domain) normals, worst "
              + String(format: "%.5f", result.drawn) + "° from Blender's corner normals", result.drawn < 0.01)
        if truth.domain != "POINT" {
            // The control: the same passes without `sync_shading`, which is
            // the 3D View as it was, drawing the vertex normals.
            let old = bare[k][name]?.drawn ?? 0
            controls.append((name, truth.domain, old))
            print("        control: without sync_shading drawn \(String(format: "%.2f", old))° off")
        }
    }
}
print("\nworst of every corner of every pass: " + String(format: "%.5f", worstDrawn) + "°")

// What each Normals row changed on screen, beside what it changed in Blender:
// the review's defect was a row Blender's Solid view showed and the 3D View
// did not.
if let before = passes.firstIndex(where: { $0.label.hasPrefix("the six rows' spheres before") }) {
    print("\nwhat each row changed, the worst corner")
    func change(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        a.count == b.count ? zip(a, b).map { degrees($0, $1) }.max() ?? 0 : .infinity
    }
    for name in passes[before].blender.keys.sorted() {
        guard let was = shown[before][name], let now = shown[before + 1][name],
              let bareWas = bare[before][name], let bareNow = bare[before + 1][name] else {
            check("\(name): measured before and after its row", false); continue
        }
        let inBlender = change(was.blender, now.blender)
        let onScreen = change(was.normals, now.normals)
        let old = change(bareWas.normals, bareNow.normals)
        check("\(name): Blender's corners turned up to \(String(format: "%.2f", inBlender))°, the 3D View's "
              + "\(String(format: "%.2f", onScreen))° (it drew \(String(format: "%.2f", old))° of change without sync_shading)",
              inBlender > 1 && abs(onScreen - inBlender) < 0.01)
    }
}
// Every flat mesh was drawn wrong without it; Blender's vertex normals stand
// in for its corner normals in some custom-normal cases (5.2.1, a smooth
// sphere after Point to Target…), so of those at least one must differ.
let faceControls = controls.filter { $0.1 == "FACE" }
let cornerControls = controls.filter { $0.1 == "CORNER" }
check("the control: without sync_shading every FACE mesh is drawn more than 1° off "
      + "(\(faceControls.map { "\($0.0) \(String(format: "%.1f", $0.2))°" }.joined(separator: ", ")))",
      !faceControls.isEmpty && faceControls.allSatisfy { $0.2 > 1 })
check("  and \(cornerControls.filter { $0.2 > 1 }.count) of the \(cornerControls.count) CORNER meshes "
      + "(\(cornerControls.map { "\($0.0) \(String(format: "%.1f", $0.2))°" }.joined(separator: ", ")))",
      cornerControls.contains { $0.2 > 1 })
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
