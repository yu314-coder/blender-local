import Foundation
import simd
import CoreGraphics

// The Swift half of scripts/run-regionselect-blender-check.sh.
//
//   run <scenes.json> <calls.txt>
//
// Reads what Blender's own view3d.select_box / circle / lasso selected with
// X-Ray on (verify.py measure), runs RegionSelect over the same regions in the
// same view, and compares element by element. Then writes, for verify.py
// apply, the Python the app would send: each of those selections pushed as
// Bpy.pushEditSelection pushes it, and every Select menu row.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
guard args.count == 3,
      let data = FileManager.default.contents(atPath: args[1]),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let scenes = root["scenes"] as? [[String: Any]] else {
    print("usage: run <scenes.json> <calls.txt>"); exit(2)
}

var calls: [String] = []
func emit(_ head: String, _ body: String) { calls.append("#-- \(head)\n\(body)") }

func point(_ v: Any) -> CGPoint {
    let p = v as! [Any]
    return CGPoint(x: (p[0] as! NSNumber).doubleValue, y: (p[1] as! NSNumber).doubleValue)
}

print("RegionSelect against Blender's own select operators, X-Ray on")
for scene in scenes {
    let name = scene["name"] as! String
    let size = (scene["size"] as! [NSNumber]).map { CGFloat($0.doubleValue) }
    let (W, H) = (size[0], size[1])
    // mathutils rows; simd columns.
    let rows = (scene["matrix"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
    let matrix = simd_float4x4(columns: (SIMD4(rows[0][0], rows[1][0], rows[2][0], rows[3][0]),
                                         SIMD4(rows[0][1], rows[1][1], rows[2][1], rows[3][1]),
                                         SIMD4(rows[0][2], rows[1][2], rows[2][2], rows[3][2]),
                                         SIMD4(rows[0][3], rows[1][3], rows[2][3], rows[3][3])))
    let vertices = (scene["vertices"] as! [[NSNumber]]).map {
        MeshVertex(SIMD3($0[0].floatValue, $0[1].floatValue, $0[2].floatValue), SIMD3(0, 0, 1))
    }
    let triangles = (scene["triangles"] as! [[NSNumber]]).flatMap { $0.map { UInt32($0.intValue) } }
    let trianglePolygons = (scene["triangle_polygons"] as! [NSNumber]).map { UInt32($0.intValue) }
    let blenderEdges = (scene["edges"] as! [[NSNumber]]).map { ($0[0].intValue, $0[1].intValue) }
    let polygons = (scene["polygons"] as! NSNumber).intValue
    let mesh = MeshData(vertices: vertices, indices: triangles)
    // The mirror's report, as the device builds it: Blender's edges found
    // among the viewport's by their ends.
    func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
    var blenderEdge: [UInt64: Int] = [:]
    for (i, e) in blenderEdges.enumerated() { blenderEdge[key(e.0, e.1)] = i }
    var real = Set<Int>()
    var displayToBlender: [Int: Int] = [:]
    for e in 0..<(mesh.edges.count / 2) {
        if let b = blenderEdge[key(Int(mesh.edges[2 * e]), Int(mesh.edges[2 * e + 1]))] {
            real.insert(e); displayToBlender[e] = b
        }
    }
    let topology = EditTopology(vertexCount: vertices.count, polygonCount: polygons,
                                trianglePolygons: trianglePolygons, realEdges: real)
    let object = BKObject(name: "Probe", kind: .plane)
    object.setMirroredMesh(mesh)
    object.editTopology = topology
    let viewSize = CGSize(width: W, height: H)
    func screen(_ p: SIMD3<Float>) -> CGPoint? {
        BoxSelect.project(p, viewProjection: matrix, size: viewSize)
    }

    print("\n\(name): \(vertices.count) vertices, \(polygons) faces, a \(Int(W)) × \(Int(H)) view")
    for (index, test) in (scene["tests"] as! [[String: Any]]).enumerated() {
        let mode: MeshSelectMode = ["VERT": .vertex, "EDGE": .edge, "FACE": .face][test["mode"] as! String]!
        let kind = test["kind"] as! String
        let params = test["params"] as! [String: Any]
        // Blender's region pixels count up from the bottom; the view's down
        // from the top.
        let region: SelectionRegion
        switch kind {
        case "box":
            let x0 = CGFloat((params["xmin"] as! NSNumber).doubleValue), x1 = CGFloat((params["xmax"] as! NSNumber).doubleValue)
            let y0 = CGFloat((params["ymin"] as! NSNumber).doubleValue), y1 = CGFloat((params["ymax"] as! NSNumber).doubleValue)
            region = .box(CGRect(x: x0, y: H - y1, width: x1 - x0, height: y1 - y0))
        case "circle":
            let c = CGPoint(x: (params["x"] as! NSNumber).doubleValue, y: (params["y"] as! NSNumber).doubleValue)
            region = .circle(path: [CGPoint(x: c.x, y: H - c.y)],
                             radius: CGFloat((params["radius"] as! NSNumber).doubleValue))
        default:
            region = .lasso((params["path"] as! [Any]).map { let p = point($0); return CGPoint(x: p.x, y: H - p.y) })
        }
        let own = RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                                        viewProjection: matrix, size: viewSize, region: region,
                                        mode: mode, seeThrough: true)
        let got: Set<Int>
        switch mode {
        case .vertex: got = own.vertices
        case .edge:   got = Set(own.edges.compactMap { displayToBlender[$0] })
        case .face:   got = Set(own.faces.map { Int(trianglePolygons[$0]) })
        }
        let want = Set((test["selected"] as! [NSNumber]).map(\.intValue))
        // Blender's lasso tests a vertex at its integer pixel, so an element
        // within a point of the outline can go either way; anything further
        // out is a real disagreement.
        func key(_ i: Int) -> [CGPoint] {
            switch mode {
            case .vertex: return screen(vertices[i].position).map { [$0] } ?? []
            case .edge:
                let e = blenderEdges[i]
                return [screen(vertices[e.0].position), screen(vertices[e.1].position)].compactMap { $0 }
            case .face:
                let corners = Set((0..<trianglePolygons.count).filter { Int(trianglePolygons[$0]) == i }
                    .flatMap { t in (0..<3).map { Int(triangles[3 * t + $0]) } })
                let c = corners.reduce(SIMD3<Float>.zero) { $0 + vertices[$1].position } / Float(max(corners.count, 1))
                return screen(c).map { [$0] } ?? []
            }
        }
        func nearOutline(_ p: CGPoint) -> Bool {
            [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)]
                .contains { region.contains(CGPoint(x: p.x + $0.x, y: p.y + $0.y)) != region.contains(p) }
        }
        let differ = got.symmetricDifference(want)
        let borderline = differ.filter { key($0).contains(where: nearOutline) }
        let real = differ.subtracting(borderline)
        check("\(test["mode"] as! String) \(kind) #\(index): Blender \(want.count), the pass \(got.count)"
              + (borderline.isEmpty ? "" : " (\(borderline.count) on the outline itself)"),
              real.isEmpty && !want.isEmpty || (want.isEmpty && got.isEmpty),
              "only Blender: \(want.subtracting(got).sorted()), only the pass: \(got.subtracting(want).sorted())")

        // What the app would send Blender for this gesture: Set, pushed.
        let full = EditSelection.implied(by: own, mode: mode, mesh: mesh, topology: topology)
        let push = Bpy.pushEditSelection(full, mode: mode, of: object)
            .replacingOccurrences(of: "bpy.data.objects[\"Probe\"]", with: "bpy.context.object")
        let blenderMode = test["mode"] as! String
        let expect = mode == .edge
            ? "[" + got.sorted().map { "[\(blenderEdges[$0].0), \(blenderEdges[$0].1)]" }.joined(separator: ", ") + "]"
            : "\(got.sorted())"
        emit("PUSH \(name) \(blenderMode) \(index)", push + "\n# expect \(expect)")
    }
}

// The menu, as SelectMenu.swift has it.
func body(_ action: SelectMenu.Action) -> String {
    switch action {
    case .run(let python, _): return python
    case .perform(let op): return op.executedPython
    }
}
for item in SelectMenu.MeshItem.allCases {
    emit("MESH \(item.rawValue)", item.operation.executedPython)
    emit("NAME \(item.call)", item.operatorName)
}
for type in SelectMenu.SimilarType.allCases {
    let mode = ["VERT", "EDGE", "FACE"][[MeshSelectMode.vertex, .edge, .face].firstIndex(of: type.mode)!]
    emit("SIMILAR \(mode) \(type.rawValue)", type.operation.executedPython)
}
emit("NAME bpy.ops.mesh.select_similar", "Select Similar")
for item in SelectMenu.ObjectItem.allCases {
    emit("OBJECT \(item.rawValue)", body(item.action))
}
emit("TYPE MESH", body(SelectMenu.selectByType("MESH")))
emit("TYPE LIGHT", body(SelectMenu.selectByType("LIGHT")))
emit("LINKED MATERIAL", body(SelectMenu.selectLinked("MATERIAL")))
emit("LINKED OBDATA", body(SelectMenu.selectLinked("OBDATA")))
emit("PATTERN", body(SelectMenu.selectPattern("Wheel*")))
emit("PATTERN NONE", body(SelectMenu.selectPattern("Nothing*")))
// A region over Body and Point, from what each case starts with.
for (action, seed, want) in [(SelectAction.set, "Wheel.L", "Body,Point"),
                             (.extend, "Wheel.L", "Body,Point,Wheel.L"),
                             (.subtract, "Body,Wheel.L", "Wheel.L"),
                             (.difference, "Body", "Point"),
                             (.intersect, "Body,Wheel.L", "Body")] {
    emit("REGION \(action.rawValue) \(seed) \(want)", SelectMenu.objectRegion(["Body", "Point"], action: action))
}

try! calls.joined(separator: "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
print(failures == 0 ? "\nALL PASS (the pass)" : "\n\(failures) FAILED (the pass)")
exit(failures == 0 ? 0 : 1)
