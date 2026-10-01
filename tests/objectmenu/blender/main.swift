import Foundation
import CoreGraphics
import simd

// Show/Hide, Separate, Shade Auto Smooth, QuadriFlow and Add ▸ Curve and Text,
// both halves.
//
//   dump                  every string the 3D View sends for them — through
//                         `BpyBridge.run` itself for the menu rows, as
//                         `perform` sends them for the adjustable operators —
//                         for a headless Blender to run (verify.py).
//   dump <passes.json>    what Blender's own `_blenderkit_sync.sync()` pushed
//                         after each of those, replayed through the Swift the
//                         device runs (`SceneMirror`, `Modifier.stack`,
//                         `mirrorEditSelection`), and held to what Blender
//                         says it has: a hidden object still in the Outliner
//                         with its eye closed, hidden faces gone from edit
//                         mode, the separated objects on screen, the
//                         modifier Auto Smooth adds in the panel, curves and
//                         text drawn.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// Records what reaches the interpreter, as a device's runtime receives it.
final class RecordingRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = false
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
}

func dump() {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

    // The menu rows go through `BpyBridge.run`, the call LayoutWorkspace makes,
    // so the mode guard's bracket and anything else `run` adds is in what
    // Blender runs here.
    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    undo.seed(scene)
    let runtime = RecordingRuntime()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    var labels: [String] = []
    func sent(_ python: String, undo label: String) -> String {
        let before = runtime.sources.count
        bridge.run(python, undo: label)
        labels.append("\(label)\t\(undo.undoName ?? "-")")
        return runtime.sources.count > before ? runtime.sources[runtime.sources.count - 1] : ""
    }
    for editing in [false, true] {
        for what in Bpy.ShowHide.allCases {
            let name = (editing ? "MESH_" : "OBJECT_") + "\(what)".uppercased()
            emit(name, sent(Bpy.showHide(what, editing: editing), undo: what.undoName(editing: editing)))
        }
    }
    emit("EYE_HIDE_A", sent(Bpy.setHidden("A", true), undo: "Hide"))
    emit("EYE_SHOW_A", sent(Bpy.setHidden("A", false), undo: "Show"))
    emit("DISABLE_C", sent(Bpy.setDisabledInViewports("C", true), undo: "Show in Viewports"))
    emit("ENABLE_C", sent(Bpy.setDisabledInViewports("C", false), undo: "Enable in Viewports"))
    for type in Bpy.SeparateType.allCases {
        emit("SEPARATE_" + type.rawValue, sent(Bpy.separate(type), undo: "Separate"))
    }
    emit("UNDO_NAMES", labels.joined(separator: "\n"))

    // The adjustable ones, as `perform` sends them: into the mode, the backup
    // that makes the redo panel work without Blender's undo, the operator,
    // and back — and a re-run with a field changed, as the panel sends it.
    func performed(_ op: LastOperator) -> String { BpyBridge.performBody(for: op) }
    func rerun(_ op: LastOperator, _ change: (inout LastOperator) -> Void) -> String {
        var op = op
        op.subject = "@SUBJECT@"
        change(&op)
        return op.rerunPython
    }
    let autoSmooth = LastOperator.shadeAutoSmooth()
    emit("AUTO_SMOOTH", performed(autoSmooth))
    emit("AUTO_SMOOTH_RERUN", rerun(autoSmooth) { $0["angle"] = 60 * .pi / 180 })
    emit("AUTO_SMOOTH_BY_UNDO", BpyBridge.performBody(for: autoSmooth, backup: false))
    emit("SMOOTH_BY_ANGLE", performed(LastOperator.shadeSmoothByAngle()))
    // With Blender's undo keeping the history there is no mesh backup, and
    // every selected object comes back with the undo.
    emit("SMOOTH_BY_ANGLE_BY_UNDO", BpyBridge.performBody(for: LastOperator.shadeSmoothByAngle(), backup: false))
    // The app's own Add ▸ Circle: a wire, for QuadriFlow to refuse and for
    // edit mode to hide.
    emit("ADD_MESH_CIRCLE", performed(LastOperator.add(.circle, at: .zero)))
    // What the 3D View asks before offering Shade Auto Smooth.
    emit("ESSENTIALS_PROBE", BpySession.essentialsProbe)
    var quadriflow = LastOperator.quadriflowRemesh()
    quadriflow["target_faces"] = 1000
    emit("QUADRIFLOW", performed(quadriflow))
    emit("QUADRIFLOW_RERUN", rerun(quadriflow) { $0["target_faces"] = 2000 })
    let place = SIMD3<Float>(1, 2, 3)
    let text = LastOperator.add(.text, at: place)
    emit("ADD_TEXT", performed(text))
    emit("ADD_TEXT_RERUN", rerun(text) { $0["radius"] = 2 })
    emit("ADD_BEZIER", performed(LastOperator.add(.curve(.bezier), at: place)))
    emit("ADD_CIRCLE", performed(LastOperator.add(.curve(.circle), at: place)))
    emit("ADD_CIRCLE_RERUN", rerun(LastOperator.add(.curve(.circle), at: place)) { $0["radius"] = 0.5 })
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
    let bits: Int?
    let vsel: String?
    let tpoly: String?
    let psel: String?
    let ends: String?
    let esel: String?
    let vhide: String?
}
struct Truth: Decodable {
    let type: String
    let drawn: Bool
    let hidden: Bool
    let disabled: Bool
    let selected: Bool
    let vertices: Int
    let edges: Int
    let triangles: Int
    let modifiers: [String]
    /// `obj.dimensions`, drawn or not.
    let dimensions: [Double]?
}
struct Pass: Decodable {
    let name: String
    let calls: [Call]
    let blender: [String: Truth]
    /// For an edit-mode pass: the triangles of the faces Blender shows, and
    /// which vertices it has hidden.
    let shownTriangles: Int?
    let hiddenVertices: [Int]?
}

func values<T>(_ base64: String?, as: T.Type) -> [T] {
    guard let base64, let data = Data(base64Encoded: base64) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

/// One pass, as `bk_sync_begin` … `bk_sync_end` and `bk_sync_edit_selection`
/// take it, onto an empty scene — or, as every pass after the first on a
/// device, onto `screen`, the scene the last pass left. Then each push meets
/// the object of its name on screen (`previous`), and the geometry that came
/// back as it was is reused rather than rebuilt, which is where a mirror can
/// keep what Blender no longer shows.
func replay(_ pass: Pass, onto screen: BKScene? = nil) -> BKScene {
    let scene: BKScene
    if let screen {
        scene = screen
    } else {
        scene = BKScene(startupFile: false)
        scene.objects = []
    }
    let label = screen == nil ? pass.name : pass.name + ", onto the last pass"
    // What `bk_sync_begin` takes: the objects on screen, by name.
    let previous = Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var pending: [BKObject] = []
    var unchanged: Set<String> = []
    var selection: Set<UUID> = []
    var active: UUID?
    var refused: [String] = []
    var reports: [(String, BlenderEditReport)] = []
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
            // As `bk_sync_edges` does: edges that changed the mesh make it a change.
            if SceneMirror.installEdges(valid, on: target) { unchanged.remove(call.name) }
        case "modifiers":
            pending.last(where: { $0.name == call.name })?.modifiers = Modifier.stack(from: call.record ?? "")
        case "display":
            if let target = pending.last(where: { $0.name == call.name }) {
                target.display = ObjectDisplay(type: call.type ?? "", dataName: call.dataName ?? "",
                                               record: call.record ?? "")
            }
        case "edit":
            reports.append((call.name, BlenderEditReport(
                selectMode: Int32(call.bits ?? 1),
                vertexSelected: values(call.vsel, as: UInt8.self),
                trianglePolygons: values(call.tpoly, as: UInt32.self),
                polygonSelected: values(call.psel, as: UInt8.self),
                edgeVertices: values(call.ends, as: UInt32.self),
                edgeSelected: values(call.esel, as: UInt8.self),
                vertexHidden: values(call.vhide, as: UInt8.self))))
        default:
            break
        }
    }
    check("\(label): every buffer Blender's sync pushed is accepted", refused.isEmpty,
          refused.joined(separator: ", "))
    SceneMirror.merge(pending, into: scene, unchanged: unchanged, selection: selection, active: active)
    // `_report_edit_selection` runs after `sync_end`, as it does here.
    scene.mode = reports.isEmpty ? .object : .edit
    for (name, report) in reports {
        if let object = scene.objects.first(where: { $0.name == name }) {
            scene.mirrorEditSelection(report, on: object)
        }
    }
    let missing = pass.blender.keys.filter { name in !scene.objects.contains { $0.name == name } }
    check("\(label): every object Blender has is on screen, hidden or not", missing.isEmpty,
          "missing: " + missing.sorted().joined(separator: ", "))
    for (name, truth) in pass.blender {
        guard let obj = scene.objects.first(where: { $0.name == name }) else { continue }
        check("\(label): \(name) drawn \(truth.drawn), eye \(truth.hidden ? "closed" : "open"), "
              + "disabled \(truth.disabled), selected \(truth.selected), as in Blender",
              obj.visible == truth.drawn && obj.hiddenInViewLayer == truth.hidden
                  && obj.disabledInViewports == truth.disabled
                  && scene.selection.contains(obj.id) == truth.selected,
              "drawn \(obj.visible), eye \(obj.hiddenInViewLayer), disabled \(obj.disabledInViewports), "
                  + "selected \(scene.selection.contains(obj.id))")
    }
    return scene
}

func object(_ scene: BKScene, _ name: String) -> BKObject? {
    scene.objects.first { $0.name == name }
}

func replayAll(_ path: String) -> Int32 {
    let passes = try! JSONDecoder().decode([Pass].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var byName: [String: (Pass, BKScene)] = [:]
    for pass in passes {
        print("\n\(pass.name)")
        let scene = replay(pass)
        byName[pass.name] = (pass, scene)
        // Drawn geometry against Blender's evaluated counts, for everything drawn.
        for (name, truth) in pass.blender where truth.drawn && truth.vertices > 0 && pass.shownTriangles == nil {
            guard let obj = object(scene, name) else { continue }
            check("\(pass.name): \(name) is drawn with Blender's \(truth.vertices) vertices and "
                  + "\(truth.triangles) triangles",
                  obj.mesh.vertices.count == truth.vertices && obj.mesh.indices.count / 3 == truth.triangles,
                  "\(obj.mesh.vertices.count), \(obj.mesh.indices.count / 3)")
            if truth.triangles == 0 && truth.edges > 0 {
                check("\(pass.name): \(name) has no faces, so it is drawn as its \(truth.edges) edges",
                      obj.mesh.isWire && obj.mesh.edges.count / 2 == truth.edges, "\(obj.mesh.edges.count / 2)")
            }
        }
        for (name, truth) in pass.blender where !truth.modifiers.isEmpty {
            check("\(pass.name): \(name)'s modifiers all have rows, named as in Blender",
                  object(scene, name)?.modifiers.map(\.name) == truth.modifiers,
                  "\(object(scene, name)?.modifiers.map(\.name) ?? [])")
        }
    }

    if let (pass, scene) = byName["mesh hide"], let grid = object(scene, "Grid") {
        print("\nedit mode, after Hide Selected")
        check("the viewport draws only the faces Blender shows: \(pass.shownTriangles ?? -1) triangles",
              grid.mesh.indices.count / 3 == pass.shownTriangles, "\(grid.mesh.indices.count / 3)")
        let topology = grid.editTopology
        check("the mirror still names Blender's elements by index", topology?.describes(grid.mesh) == true)
        check("and knows which vertices are hidden, as Blender does",
              topology.map { $0.hiddenVertices == Set(pass.hiddenVertices ?? [-1]) } == true,
              "\(topology?.hiddenVertices.sorted() ?? []) vs \(pass.hiddenVertices ?? [])")
        check("hidden elements are not selected", scene.editSelection.isEmpty,
              "\(scene.editSelection.vertices.sorted())")
        // Everything the grid spans, seen from above: a box round the lot.
        let viewProjection = simd_float4x4(diagonal: SIMD4(0.4, 0.4, 0.4, 1))
        let size = CGSize(width: 400, height: 400)
        let boxed = grid.editElements(in: CGRect(x: -10, y: -10, width: 420, height: 420),
                                      mode: .vertex, viewProjection: viewProjection, size: size)
        let hidden = Set(pass.hiddenVertices ?? [])
        check("a box round the whole grid takes every vertex but the hidden ones",
              boxed.vertices == Set(grid.mesh.vertices.indices).subtracting(hidden)
                  && !hidden.isEmpty,
              "\(boxed.vertices.count) of \(grid.mesh.vertices.count), \(hidden.count) hidden")
    }
    if let (pass, scene) = byName["mesh reveal"], let grid = object(scene, "Grid") {
        print("\nedit mode, after Reveal Hidden")
        check("every face is back: \(pass.shownTriangles ?? -1) triangles",
              grid.mesh.indices.count / 3 == pass.shownTriangles, "\(grid.mesh.indices.count / 3)")
        check("and nothing is hidden", grid.editTopology?.hiddenVertices.isEmpty == true)
    }
    if let (pass, scene) = byName["mesh hide all"], let grid = object(scene, "Grid") {
        print("\nedit mode, with every face hidden")
        check("nothing of the grid is drawn: no triangle and no edge",
              grid.mesh.indices.isEmpty && grid.mesh.edges.isEmpty,
              "\(grid.mesh.indices.count / 3) triangles, \(grid.mesh.edges.count / 2) edges")
        check("and every vertex is known to be hidden",
              grid.editTopology?.hiddenVertices == Set(pass.hiddenVertices ?? []))
        // With no face left there is no surface to hide a vertex behind, so
        // the picker's own visibility test lets every vertex through: only the
        // hidden flags keep a tap off them.
        let viewProjection = simd_float4x4(diagonal: SIMD4(0.4, 0.4, 0.4, 1))
        let v = 12
        let p = viewProjection * SIMD4(grid.mesh.vertices[v].position, 1)
        let hit = MeshPicker.pick(mesh: grid.mesh, topology: grid.editTopology, mode: .vertex,
                                  ndc: SIMD2(p.x / p.w, p.y / p.w), viewSize: SIMD2(400, 400),
                                  viewProjection: viewProjection, eye: SIMD3(0, 0, 10),
                                  ray: (SIMD3(grid.mesh.vertices[v].position.x,
                                              grid.mesh.vertices[v].position.y, 10), SIMD3(0, 0, -1)))
        check("a tap right on a hidden vertex picks nothing", hit.vertex == nil,
              "\(String(describing: hit.vertex))")
    }
    if let (_, scene) = byName["auto smooth"], let sphere = object(scene, "Sphere") {
        print("\nthe modifier Shade Auto Smooth adds")
        let m = sphere.modifiers.first
        check("it has a row, as Geometry Nodes, not dropped",
              m?.kind == .geometryNodes && m?.name == "Smooth by Angle", "\(String(describing: m?.kind))")
        check("its group is Blender's Smooth by Angle, and the row can set its inputs",
              m?.nodeGroup == "Smooth by Angle" && m?.smoothByAngle == true, m?.nodeGroup ?? "")
        check("its Angle is Blender's 30 degrees",
              m.map { abs($0.angle - 30 * .pi / 180) < 1e-4 } == true, "\(m?.angle ?? -1)")
        check("Ignore Sharpness is off", m?.ignoreSharpness == false)
        check("a Geometry Nodes modifier is not offered by Add Modifier",
              !ModifierKind.addable.contains(.geometryNodes))
    }
    if let (_, scene) = byName["adds"] {
        print("\nAdd ▸ Curve and Text")
        let text = object(scene, "Text"), bezier = object(scene, "BézierCurve"),
            circle = object(scene, "BézierCircle")
        check("the text is drawn by its faces, as a FONT",
              text?.blenderType == "FONT" && (text?.mesh.indices.isEmpty == false))
        check("the Bézier and the circle are drawn as wires, as CURVEs",
              bezier?.blenderType == "CURVE" && circle?.blenderType == "CURVE"
                  && bezier?.mesh.isWire == true && circle?.mesh.isWire == true)
        check("none of them offers Edit Mesh", [text, bezier, circle].allSatisfy { $0?.hasEditMode == false })
        scene.activeID = object(scene, "Plane")?.id
        check("all three can cut the plane with Knife Project",
              Set(scene.knifeProjectCutters.map(\.name)).isSuperset(of: ["Text", "BézierCurve", "BézierCircle"]),
              scene.knifeProjectCutters.map(\.name).joined(separator: ", "))
        // A tap: the viewport's hitTest asks ObjectOverlayPicking first, and
        // it takes a wire by its lines — the renderer's ray meets triangles
        // only, and these have none. Each curve alone, looked at from 10 m
        // above its origin, tapped on its vertex furthest from the origin.
        for curve in [bezier, circle].compactMap({ $0 }) {
            let alone = BKScene(startupFile: false)
            alone.objects = [curve]
            let o = curve.modelMatrix.columns.3
            let view = simd_float4x4(rows: [SIMD4(1, 0, 0, -o.x), SIMD4(0, 1, 0, -o.y),
                                            SIMD4(0, 0, 1, -o.z - 10), SIMD4(0, 0, 0, 1)])
            let f = 1 / tan(Float(25) * .pi / 180), near: Float = 0.1, far: Float = 100
            let projection = simd_float4x4(rows: [SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0),
                                                  SIMD4(0, 0, (far + near) / (near - far),
                                                        2 * far * near / (near - far)),
                                                  SIMD4(0, 0, -1, 0)])
            let overlay = OverlayView(view: view, projection: projection, size: CGSize(width: 800, height: 800))
            let farthest = curve.mesh.vertices.max { simd_length($0.position) < simd_length($1.position) }!
            let world = curve.modelMatrix * SIMD4(farthest.position, 1)
            let tap = overlay.project(SIMD3(world.x, world.y, world.z))
            check("\(curve.name) is taken by a tap on its line",
                  tap.map { ObjectOverlayPicking.object(at: $0, in: alone, view: overlay) === curve } == true)
            // The circle's middle is a metre from its line; the Bézier runs
            // through its own origin, so it has no such point to try.
            if curve === circle, let centre = overlay.project(SIMD3(o.x, o.y, o.z)) {
                check("and not by one in its empty middle",
                      ObjectOverlayPicking.object(at: centre, in: alone, view: overlay) == nil)
            }
        }
    }
    let chainNames = ["chain drawn", "chain A hidden", "chain A shown", "chain others hidden",
                      "chain C disabled", "chain C enabled"]
    let chain = chainNames.compactMap { byName[$0]?.0 }
    check("(the H, Shift+H and Show in Viewports passes all arrived)", chain.count == chainNames.count)
    if chain.count == chainNames.count {
        // The app's own vertex paint and weights, which bpy has no copy of:
        // nothing a pass sends can bring them back once the merge drops them.
        print("\nthe app's own paint, through H, Shift+H and Show in Viewports, pass after pass")
        let scene = replay(chain[0])
        if let a = object(scene, "A"), let c = object(scene, "C") {
            for painted in [a, c] {
                painted.vertexColours = Array(repeating: SIMD4(1, 0, 0, 1), count: painted.mesh.vertices.count)
                painted.vertexWeights = Array(repeating: 0.5, count: painted.mesh.vertices.count)
            }
            let (na, nc) = (a.mesh.vertices.count, c.mesh.vertices.count)
            let version = a.meshVersion
            func size(_ obj: BKObject) -> SIMD3<Float> { obj.worldBounds.max - obj.worldBounds.min }
            let drawnA = size(a)
            for pass in chain.dropFirst() {
                _ = replay(pass, onto: scene)
                check("\(pass.name): A and C are the objects first listed",
                      object(scene, "A") === a && object(scene, "C") === c)
                check("\(pass.name): and keep their paint, \(na) and \(nc) colours and weights",
                      a.vertexColours.count == na && a.vertexWeights.count == na
                          && c.vertexColours.count == nc && c.vertexWeights.count == nc,
                      "A \(a.vertexColours.count)/\(a.vertexWeights.count), "
                          + "C \(c.vertexColours.count)/\(c.vertexWeights.count)")
                // What the N panel measures Dimensions from. C has no
                // modifier, and its size is Blender's `dimensions`, drawn or
                // not. A's is not even while drawn: under a level-1
                // Subdivision Blender reports 2 m on each axis and its
                // evaluated mesh spans 1.679 m (found here; the N panel's
                // own difference, not a hidden object's), so A is held to
                // the size it was drawn at.
                if let truth = pass.blender["C"], let blender = truth.dimensions, blender.count == 3 {
                    let shown = size(c)
                    check("\(pass.name): C's size on screen is Blender's, drawn or not",
                          (0..<3).allSatisfy { abs(Double(shown[$0]) - blender[$0]) < 1e-3 },
                          "\(shown) vs \(blender)")
                }
                check("\(pass.name): A's size on screen is the size it was drawn at",
                      simd_length(size(a) - drawnA) < 1e-5, "\(size(a)) vs \(drawnA)")
            }
            check("A's mesh came back unchanged when shown, so it was never re-uploaded",
                  a.meshVersion == version, "\(version) → \(a.meshVersion)")
        } else {
            check("A and C are on screen after the first pass", false)
        }
    }
    if let editing = byName["wire editing"]?.0, let hidden = byName["wire all hidden"]?.0 {
        print("\na wire in edit mode, then every vertex of it hidden, onto the last pass")
        let scene = replay(editing)
        let circle = object(scene, "Circle")
        check("it is first drawn as its 32 edges", circle?.mesh.isWire == true && circle?.mesh.edges.count == 64,
              "\((circle?.mesh.edges.count ?? 0) / 2)")
        _ = replay(hidden, onto: scene)
        check("then nothing of it is drawn — no edge, no triangle — as Blender draws nothing",
              object(scene, "Circle") === circle && circle?.mesh.edges.isEmpty == true
                  && circle?.mesh.indices.isEmpty == true,
              "\((circle?.mesh.edges.count ?? 0) / 2) edges")
        check("and every vertex is known to be hidden, so none gets a dot",
              circle?.hiddenEditVertices.count == 32, "\(circle?.hiddenEditVertices.count ?? -1)")
    }
    if let (_, scene) = byName["separate"] {
        print("\nafter Separate")
        check("the separated part is its own object on screen, selected",
              object(scene, "Cube.001").map { scene.selection.contains($0.id) } == true)
        check("the edited cube stays active", scene.active?.name == "Cube", scene.active?.name ?? "-")
    }
    print("\nthe 3D View's question about the Essentials library, asked of a session")
    for (said, expected) in [("True", true), ("False", false)] {
        let runtime = Answering(said)
        let session = BpySession(runtime: runtime)
        let scene = BKScene(startupFile: false)
        let undo = UndoStack()
        session.bind(scene: scene, undo: undo)
        session.probeEssentialsLibrary()
        session.probeEssentialsLibrary()
        check("Blender's \(said) \(expected ? "offers the Auto Smooth row" : "greys it out"), asked once",
              session.essentialsLibrary == expected && runtime.asked == [BpySession.essentialsProbe],
              "\(String(describing: session.essentialsLibrary)), asked \(runtime.asked.count)")
    }
    let silent = Answering("")
    let unanswered = BpySession(runtime: silent)
    unanswered.bind(scene: BKScene(startupFile: false), undo: UndoStack())
    unanswered.probeEssentialsLibrary()
    check("no answer leaves it unknown, and the row offered", unanswered.essentialsLibrary == nil)
    let stub = BpySession(runtime: StubBpyRuntime())
    stub.bind(scene: BKScene(startupFile: false), undo: UndoStack())
    stub.probeEssentialsLibrary()
    check("the command subset, which has no bpy, is not asked and has no library",
          stub.essentialsLibrary == false)

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    return failures == 0 ? 0 : 1
}

/// A backend that answers every question with one line, and remembers them.
final class Answering: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    let said: String
    var asked: [String] = []
    init(_ said: String) { self.said = said }
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "answering" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        asked.append(source)
        return said.isEmpty ? [] : [BpyLine(.output, said)]
    }
}

if CommandLine.arguments.count > 1 {
    exit(replayAll(CommandLine.arguments[1]))
}
dump()
