import Foundation
import simd

// The UV Editor, end to end: the UV menu's rows run in a headless Blender, and
// the UV map and seams Blender's own `_blenderkit_sync.sync()` pushes after
// them are built and merged by the Swift the device runs.
//
// With no argument this prints the Python every row of the UV menu sends
// (`Bpy.uv`), for verify.py to run. With a path it reads what that Blender's
// sync pushed — every `sync_push` and `sync_uvs`, pass by pass, with what
// Blender itself holds — and replays it through `SceneMirror`, the code
// `bk_sync_push`, `bk_sync_uvs` and `bk_sync_end` call.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
if args.count < 2 {
    print(UVOperator.allCases
        .map { "### \($0.rawValue)|\($0.label)\n\(Bpy.uv($0))" }
        .joined(separator: "\n#--\n"))
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
    let map: String?
    let loops: String?
    let uvs: String?
    let seams: String?
}
/// What Blender holds for one object after a pass: the UV of every drawn
/// triangle corner, its seams by vertex pair, how many polygon edges the drawn
/// faces have (the loops of the drawn polygons: an n-gon has n), and how many
/// of those sides are seams.
struct Truth: Decodable {
    let map: String
    let corners: String
    let seams: [[UInt32]]
    let polygonEdges: Int
    let seamSides: Int
    /// The same, of the map Blender's UV Editor draws: the object's own mesh
    /// before its modifiers.
    let editorMap: String
    let editorCorners: String
    let editorPolygonEdges: Int
    let editorSeamSides: Int
}
struct Pass: Decodable {
    let label: String
    let calls: [Push]
    let blender: [String: Truth]
}

func values<T>(_ base64: String?, as: T.Type) -> [T] {
    guard let base64, let data = Data(base64Encoded: base64) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

let passes = try! JSONDecoder().decode([Pass].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let scene = BKScene(startupFile: false)
scene.objects = []
var versions: [String: Int] = [:]

for pass in passes {
    print("\n\(pass.label)")
    let previous = Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var pending: [BKObject] = []
    var unchanged: Set<String> = []
    var refused: [String] = []
    var geometryBytes = 0, uvBytes = 0
    var clock = ContinuousClock.Duration.zero
    for call in pass.calls {
        switch call.call {
        case "push":
            let matrix = values(call.matrix, as: Double.self)
            let positions = values(call.positions, as: Float.self)
            let normals = values(call.normals, as: Float.self)
            let triangles = values(call.triangles, as: UInt32.self)
            geometryBytes += (positions.count + normals.count) * 4 + triangles.count * 4 + 128
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
        case "uvs":
            guard let target = pending.last(where: { $0.name == call.name }) else {
                refused.append(call.name); continue
            }
            let loops = values(call.loops, as: UInt32.self)
            let uvs = values(call.uvs, as: Float.self)
            let seams = values(call.seams, as: UInt32.self)
            uvBytes += (loops.count + uvs.count + seams.count) * 4
            let start = ContinuousClock.now
            let changed = loops.withUnsafeBufferPointer { l in
                uvs.withUnsafeBufferPointer { u in
                    seams.withUnsafeBufferPointer { s in
                        SceneMirror.installUVs(mapName: call.map ?? "", triangleLoops: l, loopUVs: u,
                                               seams: s, on: target)
                    }
                }
            }
            clock += ContinuousClock.now - start
            guard let changed else { refused.append(call.name); continue }
            if changed { unchanged.remove(call.name) }
        case "layout":
            // bk_sync_uv_layout: the map before the modifiers.
            guard let target = pending.last(where: { $0.name == call.name }) else {
                refused.append(call.name); continue
            }
            let positions = values(call.positions, as: Float.self)
            let triangles = values(call.triangles, as: UInt32.self)
            let loops = values(call.loops, as: UInt32.self)
            let uvs = values(call.uvs, as: Float.self)
            let seams = values(call.seams, as: UInt32.self)
            uvBytes += (positions.count + triangles.count + loops.count + uvs.count + seams.count) * 4
            let layout = positions.withUnsafeBufferPointer { p in
                triangles.withUnsafeBufferPointer { t in
                    loops.withUnsafeBufferPointer { l in
                        uvs.withUnsafeBufferPointer { u in
                            seams.withUnsafeBufferPointer { s in
                                SceneMirror.uvLayout(mapName: call.map ?? "", positions: p, triangles: t,
                                                     triangleLoops: l, loopUVs: u, seams: s)
                            }
                        }
                    }
                }
            }
            guard let layout else { refused.append(call.name); continue }
            target.uvLayout = layout
        default:
            break
        }
    }
    check("every buffer Blender's sync pushed is accepted", refused.isEmpty, refused.joined(separator: ", "))
    SceneMirror.merge(pending, into: scene, unchanged: unchanged, selection: [], active: nil)
    print(String(format: "  ....  %d bytes of geometry, %d of UV map and seams (%.0f%%); installing the maps took %.2f ms",
                 geometryBytes, uvBytes, Double(uvBytes) / Double(max(geometryBytes, 1)) * 100,
                 Double(clock.components.attoseconds) / 1e15 + Double(clock.components.seconds) * 1e3))

    let shown = Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    for (name, truth) in pass.blender.sorted(by: { $0.key < $1.key }) {
        guard let obj = shown[name] else { check("\(name) is on screen", false); continue }
        let mesh = obj.mesh
        let corners = values(truth.corners, as: Float.self)
        if truth.map.isEmpty {
            check("\(name): no UV map in Blender, none on screen", !mesh.hasUVs && mesh.uvMapName.isEmpty)
        } else {
            let drawn = (0..<mesh.indices.count).flatMap { [mesh.cornerUV($0).x, mesh.cornerUV($0).y] }
            check("\(name): the viewport textures every corner with Blender's evaluated UV from \(truth.map)",
                  mesh.hasUVs && mesh.uvMapName == truth.map && drawn == corners,
                  "\(drawn.count / 2) corners drawn, \(corners.count / 2) in Blender")
        }
        // What the UV Editor draws (`UVEditor.map(of:)`): the map before the
        // modifiers when the mirror sent one. It drew the evaluated map, and a
        // cube under a level-1 Subdivision showed 96 polygon sides for 24.
        let map = obj.uvLayout ?? obj.mesh
        let editorCorners = values(truth.editorCorners, as: Float.self)
        if truth.editorMap.isEmpty {
            check("\(name): the UV Editor shows no map, as Blender's", !map.hasUVs)
        } else {
            let drawn = (0..<map.indices.count).flatMap { [map.cornerUV($0).x, map.cornerUV($0).y] }
            check("\(name): the UV Editor draws Blender's UV Editor map, \(editorCorners.count / 2) corners"
                  + (obj.uvLayout != nil ? " (the map before the modifiers)" : ""),
                  map.hasUVs && map.uvMapName == truth.editorMap && drawn == editorCorners,
                  "\(drawn.count / 2) corners drawn, \(editorCorners.count / 2) in Blender's editor")
            let lines = map.uvEditorLines()
            check("\(name): the editor draws Blender's \(truth.editorPolygonEdges) polygon sides, no diagonal",
                  lines.edges.count + lines.seams.count == truth.editorPolygonEdges,
                  "\(lines.edges.count + lines.seams.count)")
            check("\(name): \(truth.editorSeamSides) of them in seam red",
                  lines.seams.count == truth.editorSeamSides, "\(lines.seams.count)")
        }
        let seams = Set(stride(from: 0, to: mesh.seamEdges.count, by: 2).map {
            [min(mesh.seamEdges[$0], mesh.seamEdges[$0 + 1]), max(mesh.seamEdges[$0], mesh.seamEdges[$0 + 1])]
        })
        let expected = Set(truth.seams.map { [min($0[0], $0[1]), max($0[0], $0[1])] })
        check("\(name): its \(expected.count) seams, by vertex", seams == expected,
              "\(seams.count) on screen")
    }
    if pass.label.hasPrefix("nothing changed") {
        let same = pass.blender.keys.filter { name in
            shown[name].map { versions[name] == $0.meshVersion } ?? false
        }
        check("nothing changed: every object stays on the fast path, not reinstalled",
              same.count == pass.blender.count, "\(pass.blender.count - same.count) reinstalled")
    }
    for (name, obj) in shown { versions[name] = obj.meshVersion }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
