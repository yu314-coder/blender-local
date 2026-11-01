import Foundation
import simd
import CoreGraphics

// The Swift half of scripts/run-selectpick-blender-check.sh.
//
//   run <scenes.json> <calls.txt>
//
// For every pixel Blender's own pick was measured at (verify.py measure), the
// app's: MeshPicker's pick on the same mesh in the same view, the Blender
// index it is named by (SelectPick.element), the active vertex or face a loop
// makes (SelectPick.loopActive), the tap that sets a path's start
// (EditSelection.tapped, pushed by Bpy.pushEditSelection) and the call
// (LastOperator.pick) — written out for verify.py apply to run and hold to
// Blender's result. Then the fixed calls the apply phase refuses, walks and
// selects with.

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

func numbers(_ v: Any?) -> [Double] { (v as? [NSNumber])?.map(\.doubleValue) ?? [] }

struct Scene {
    let name: String
    let size: CGSize
    let matrix: simd_float4x4
    let eye: SIMD3<Float>
    let direction: SIMD3<Float>?
    let mesh: MeshData
    let topology: EditTopology
    let object: BKObject
    let samples: [[String: Any]]
}

func load(_ scene: [String: Any]) -> Scene {
    let size = numbers(scene["size"])
    let rows = (scene["matrix"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
    let matrix = simd_float4x4(columns: (SIMD4(rows[0][0], rows[1][0], rows[2][0], rows[3][0]),
                                         SIMD4(rows[0][1], rows[1][1], rows[2][1], rows[3][1]),
                                         SIMD4(rows[0][2], rows[1][2], rows[2][2], rows[3][2]),
                                         SIMD4(rows[0][3], rows[1][3], rows[2][3], rows[3][3])))
    let eye = numbers(scene["eye"]).map(Float.init)
    let direction = (scene["direction"] as? [NSNumber]).map { SIMD3($0[0].floatValue, $0[1].floatValue, $0[2].floatValue) }
    let vertices = (scene["vertices"] as! [[NSNumber]]).map {
        MeshVertex(SIMD3($0[0].floatValue, $0[1].floatValue, $0[2].floatValue), SIMD3(0, 0, 1))
    }
    let triangles = (scene["triangles"] as! [[NSNumber]]).flatMap { $0.map { UInt32($0.intValue) } }
    let trianglePolygons = (scene["triangle_polygons"] as! [NSNumber]).map { UInt32($0.intValue) }
    let blenderEdges = (scene["edges"] as! [[NSNumber]]).flatMap { $0.map { UInt32($0.intValue) } }
    let polygons = (scene["polygons"] as! NSNumber).intValue
    let mesh = MeshData(vertices: vertices, indices: triangles)
    // The mirror's report, as the device builds it: Blender's edges found
    // among the viewport's by their ends.
    func key(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
    var real = Set<Int>()
    let keys = Set(stride(from: 0, to: blenderEdges.count, by: 2).map { key(blenderEdges[$0], blenderEdges[$0 + 1]) })
    for e in 0..<(mesh.edges.count / 2) where keys.contains(key(mesh.edges[2 * e], mesh.edges[2 * e + 1])) {
        real.insert(e)
    }
    let topology = EditTopology(vertexCount: vertices.count, polygonCount: polygons,
                                trianglePolygons: trianglePolygons, realEdges: real,
                                blenderEdges: blenderEdges)
    let object = BKObject(name: "Probe", kind: .plane)
    object.setMirroredMesh(mesh)
    object.editTopology = topology
    return Scene(name: scene["name"] as! String, size: CGSize(width: size[0], height: size[1]), matrix: matrix,
                 eye: SIMD3(eye[0], eye[1], eye[2]), direction: direction, mesh: mesh, topology: topology,
                 object: object, samples: scene["samples"] as! [[String: Any]])
}

let modes: [String: MeshSelectMode] = ["VERT": .vertex, "EDGE": .edge, "FACE": .face]

/// The app's pick at Blender's region pixel `px` (counted up from the
/// bottom): what MeshPicker takes there, the tap's point in the view's
/// coordinates (down from the top) and the NDC.
func appPick(_ s: Scene, _ px: [Double], mode: MeshSelectMode) -> (hit: MeshPicker.Hit, point: CGPoint) {
    let (W, H) = (Float(s.size.width), Float(s.size.height))
    let ndc = SIMD2(Float(px[0]) / W * 2 - 1, Float(px[1]) / H * 2 - 1)
    let inverse = s.matrix.inverse
    func unproject(_ z: Float) -> SIMD3<Float> {
        let p = inverse * SIMD4(ndc.x, ndc.y, z, 1)
        return SIMD3(p.x, p.y, p.z) / p.w
    }
    let near = unproject(-1), far = unproject(1)
    let hit = MeshPicker.pick(mesh: s.mesh, topology: s.topology, mode: mode, ndc: ndc,
                              viewSize: SIMD2(W, H), viewProjection: s.matrix, eye: s.eye,
                              viewDirection: s.direction, ray: (near, simd_normalize(far - near)))
    return (hit, CGPoint(x: px[0], y: Double(H) - px[1]))
}

func pyQuote(_ s: String) -> String { Bpy.quote(s) }
let pushTarget = "bpy.data.objects[\"Probe\"]"
func onActive(_ python: String) -> String {
    python.replacingOccurrences(of: pushTarget, with: "bpy.context.object")
}

/// Blender's polygons with a triangle side on Blender edge `edge`.
func faces(of edge: Int, in s: Scene) -> Set<Int> {
    let a = s.topology.blenderEdges[2 * edge], b = s.topology.blenderEdges[2 * edge + 1]
    var out = Set<Int>()
    for t in 0..<(s.mesh.indices.count / 3) {
        let c = (0..<3).map { s.mesh.indices[3 * t + $0] }
        for k in 0..<3 where Set([c[k], c[(k + 1) % 3]]) == Set([a, b]) {
            out.insert(Int(s.topology.trianglePolygons[t]))
        }
    }
    return out
}

print("MeshPicker against Blender's own click, at the pixels Blender was measured at")
var gridScene: Scene?
var gridRaw: [String: Any]?
for raw in scenes {
    let s = load(raw)
    if s.name == "grid" { gridScene = s; gridRaw = raw }
    var agree: [String: (Int, Int)] = [:]
    var ambiguous = 0
    let counts = SelectPick.counts(s.topology)
    for sample in s.samples {
        guard let blender = sample["blender"] as? [NSNumber], sample["reference"] != nil else { continue }
        // A pixel where Blender's own click took another element than the
        // one aimed at — measured: on the sphere's silhouette two edges
        // within 0.15 to 0.35 of a point of each other, X-Ray taking the one
        // behind — means nothing about the tap, and is counted, not compared.
        if (sample["sampled"] as? [NSNumber])?.map(\.intValue) != blender.map(\.intValue) {
            ambiguous += 1
            continue
        }
        let id = sample["id"] as! String
        let mode = modes[sample["mode"] as! String]!
        let pick = SelectPick(rawValue: sample["pick"] as! String)!
        let pickMode = pick.pickMode(mode)
        let px = numbers(sample["px"])
        let (hit, point) = appPick(s, px, mode: pickMode)
        let element = SelectPick.element(hit, mode: pickMode, cage: s.mesh, topology: s.topology)
        let want: EditElement = [EditElement.vertex, EditElement.edge, EditElement.face][blender[0].intValue](blender[1].intValue)
        let offMiddle = (sample["where"] as? String) == "off the middle"
        let key = "\(pick.rawValue) \(sample["mode"] as! String)" + (offMiddle ? " off the middle" : "")
        var tally = agree[key] ?? (0, 0)
        tally.1 += 1
        if element == want { tally.0 += 1 } else {
            print("        at \(px.map { Int($0) }): Blender took \(want), MeshPicker \(element.map { "\($0)" } ?? "nothing")")
        }
        agree[key] = tally
        guard let element else { continue }
        var active: (vertex: Int?, face: Int?) = (nil, nil)
        if pick == .loop || pick == .ring, case .edge(let edge) = element {
            active = SelectPick.loopActive(edge: edge, at: point, mode: mode, cage: s.mesh, topology: s.topology) {
                BoxSelect.project($0, viewProjection: s.matrix, size: s.size)
            }
        }
        var lead = ""
        if pick == .path, let source = sample["source_px"] as? [NSNumber] {
            // The start: an ordinary tap there, which leaves it selected and
            // active, pushed as the next command pushes it.
            let (sourceHit, _) = appPick(s, source.map(\.doubleValue), mode: mode)
            let tapped = EditSelection().tapped(sourceHit, action: .set, mode: mode, cage: s.mesh, topology: s.topology)
            lead = onActive(Bpy.pushEditSelection(tapped, mode: mode, of: s.object)) + "\n"
        }
        let op = LastOperator.pick(pick, element: element, shift: false, mode: mode, counts: counts,
                                   activeVertex: active.vertex, activeFace: active.face)
        emit(id, lead + op.executedPython)
        if pick == .path {
            let fill = LastOperator.pick(pick, element: element, shift: true, mode: mode, counts: counts)
            emit(id + "+fill", lead + fill.executedPython)
        }
        // The negative control: the far end of the edge made active.
        if s.name == "grid", pick == .loop, mode == .vertex, case .edge(let edge) = element, let v = active.vertex {
            let a = Int(s.topology.blenderEdges[2 * edge]), b = Int(s.topology.blenderEdges[2 * edge + 1])
            let wrong = LastOperator.pick(pick, element: element, shift: false, mode: mode, counts: counts,
                                          activeVertex: v == a ? b : a)
            emit("NEG \(id)", wrong.executedPython)
        }
        // Two wrong rules, off the middle: the edge's first end always, and
        // its lower-numbered face always. verify.py holds that each is
        // caught somewhere — that these pixels tell the invoke's rule apart.
        if offMiddle, pick == .loop, case .edge(let edge) = element {
            if mode == .vertex {
                let first = Int(s.topology.blenderEdges[2 * edge])
                emit("NEGV1 \(id)", LastOperator.pick(pick, element: element, shift: false, mode: mode,
                                                      counts: counts, activeVertex: first).executedPython)
            } else if mode == .face, let low = faces(of: edge, in: s).min() {
                emit("NEGLOW \(id)", LastOperator.pick(pick, element: element, shift: false, mode: mode,
                                                       counts: counts, activeFace: low).executedPython)
            }
        }
    }
    if ambiguous > 0 {
        print("  (\(s.name): \(ambiguous) pixels where Blender's own click took another element than the one "
              + "aimed at, left out)")
    }
    for key in agree.keys.sorted() {
        let (good, total) = agree[key]!
        check("\(s.name), \(key): MeshPicker names Blender's element at \(good) of \(total) pixels",
              total > 0 && good == total, "\(good)/\(total)")
    }
}

// The fixed calls.
let grid = gridScene!
let counts = SelectPick.counts(grid.topology)
// A selection order of two vertices, as two taps leave it.
var two = EditSelection()
two.vertices = [0, 1]
two.history = [.vertex(0), .vertex(1)]
emit("PUSH ORDER", onActive(Bpy.pushEditSelection(two, mode: .vertex, of: grid.object)))
emit("PUSH ORDER WANT", "[[0, 0], [0, 1]]")
var unordered = EditSelection()
unordered.vertices = [0]
emit("PATH NO ORDER", onActive(Bpy.pushEditSelection(unordered, mode: .vertex, of: grid.object)) + "\n"
     + LastOperator.pick(.path, element: .vertex(48), shift: false, mode: .vertex, counts: counts).executedPython)
emit("LOOP HIDDEN 3", LastOperator.pick(.loop, element: .edge(3), shift: false, mode: .edge, counts: counts).executedPython)
emit("LOOP STALE", LastOperator.pick(.loop, element: .edge(3), shift: false, mode: .edge,
                                     counts: (counts.vertices + 1, counts.edges, counts.faces)).executedPython)
emit("LOOP PAST", LastOperator.pick(.loop, element: .edge(9999), shift: false, mode: .edge, counts: counts).executedPython)
emit("PATH FACE FROM VERTEX", LastOperator.pick(.path, element: .face(3), shift: false, mode: .face,
                                                counts: counts).executedPython)
var noView = LastOperator.pick(.loop, element: .edge(3), shift: false, mode: .edge, counts: counts)
noView.within = nil
emit("LOOP NO VIEW", noView.executedPython)
for item in [SelectMenu.MeshItem.nextActive, .previousActive, .sideOfActive, .byAttribute] {
    emit("MENU \(item.rawValue)", item.operation.executedPython)
}
var view = SelectMenu.MeshItem.sideOfActive.operation(view: SelectMenu.ViewDirection(forward: SIMD3(-1, 0, 0),
                                                                                     up: SIMD3(0, 0, 1)))
view["orientation"] = 4    // View
emit("MENU sideOfActive VIEW right", view.executedPython)
func body(_ action: SelectMenu.Action) -> String {
    switch action {
    case .run(let python, _): return python
    case .perform(let op): return op.executedPython
    }
}
for type in SelectMenu.groupedTypes {
    emit("GROUPED \(type.identifier)", body(SelectMenu.selectGrouped(type.identifier)))
}
if case .perform(var op) = SelectMenu.selectGrouped("CHILDREN") {
    op["extend"] = 1
    emit("GROUPED CHILDREN extend", op.executedPython)
}
emit("OBJECT child", body(SelectMenu.ObjectItem.child.action))
emit("OBJECT random", body(SelectMenu.ObjectItem.random.action))

// Select ▸ Select Linked ▸ Linked and Ctrl+L, as LayoutWorkspace.select sends
// the row: with Blender's select mode.
for (token, mode) in [("VERT", MeshSelectMode.vertex), ("EDGE", .edge), ("FACE", .face)] {
    emit("LINKED ROW \(token)", body(SelectMenu.Command.mesh(.linked).action(editing: true, selectMode: mode)))
}
// Its redo panel's toggles, item by item: [identifier, label, heading].
let linkedPanel = SelectMenu.MeshItem.linked.operation(view: nil, selectMode: .face).parameters.compactMap {
    p -> String? in
    guard case .flag(_, let heading, let identifier) = p.kind else { return nil }
    return "[\"\(identifier)\", \"\(p.label)\", \"\(heading)\"]"
}
emit("LINKED PANEL", "[" + linkedPanel.joined(separator: ", ") + "]")

// A Box Select over the grid's centre vertex from the starts verify.py
// measured Blender's own box from: what the pass leaves (`regionSelection`),
// whether the viewport pushes it (`BKObject.regionChanges`), and the push.
if let raw = gridRaw, let cases = raw["region_sets"] as? [[String: Any]] {
    let H = Double(grid.size.height)
    for c in cases {
        let name = c["name"] as! String
        let rect = c["rect"] as! [String: NSNumber]
        let (x0, x1) = (rect["xmin"]!.doubleValue, rect["xmax"]!.doubleValue)
        let (y0, y1) = (rect["ymin"]!.doubleValue, rect["ymax"]!.doubleValue)
        // Blender's region pixels count up from the bottom; the view's points down from the top.
        let box = SelectionRegion.box(CGRect(x: x0, y: H - y1, width: x1 - x0, height: y1 - y0))
        let seed = (c["seed"] as! [NSNumber]).map(\.intValue)
        var current = EditSelection()
        current.vertices = Set(seed)
        if c["ordered"] as! Bool { current.history = seed.map(EditElement.vertex) }
        let action: SelectAction = (c["mode"] as! String) == "SET" ? .set : .extend
        let selection = grid.object.regionSelection(box, mode: .vertex, action: action, current: current,
                                                    viewProjection: grid.matrix, size: grid.size, seeThrough: true)
        let changes = BKObject.regionChanges(selection, from: current, mode: .vertex, action: action)
        emit("REGION \(name) CHANGES", changes ? "True" : "False")
        // The negative control: the rule as it was, the mode's elements alone.
        emit("REGION \(name) OLD", selection.vertices != current.vertices ? "True" : "False")
        emit("REGION \(name)", changes ? onActive(Bpy.pushEditSelection(selection, mode: .vertex, of: grid.object))
                                       : "pass")
    }
} else {
    check("the measurements have the Box Select starts", false)
}

try! calls.joined(separator: "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
print(failures == 0 ? "\nALL PASS (the picking)" : "\n\(failures) FAILED (the picking)")
exit(failures == 0 ? 0 : 1)
