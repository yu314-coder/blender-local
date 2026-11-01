import Foundation
import simd
import CoreGraphics

// The Swift half of scripts/run-transformops-blender-check.sh.
//
//   main dump <fixtures.json> <cases.json>
//       Every gizmo drag on Blender's fixtures (write_fixtures.py) in every
//       orientation, through the real session — begin, resolve, snap, the
//       preview — and the call its release performs (`TransformGizmo.commit`
//       → `BpyBridge.performBody`), with where the preview put things; then
//       the redo panel's changes: the Orientation switched, the values typed,
//       Proportional Editing turned on. run_calls.py runs each in Blender and
//       holds Blender's result to the preview.
//   main parse <reports.txt> <states.txt>
//       The lines `_blenderkit_orient.report` and `_blenderkit_item.state`
//       printed in Blender, read back as the app reads them.

func load(_ path: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
}
func floats(_ any: Any?) -> [Float] { (any as! [NSNumber]).map { $0.floatValue } }
func ints(_ any: Any?) -> [UInt32] { (any as! [NSNumber]).map { UInt32($0.intValue) } }

/// A failure while building the cases, said and counted rather than trapped
/// on: the stage exits non-zero and the run goes on to the next stage.
var dumpFailures = 0
func dumpFailed(_ what: String) {
    print("  FAIL  " + what)
    dumpFailures += 1
}

/// A runtime that answers as the app's undo history does (`_blenderkit_undo`):
/// enough for `perform` to remember an operator and for the redo panel to
/// rewind and re-run it, so what the bridge sends can be run in Blender.
final class HistoryRecorder: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    var index = -1, steps = 0, rewound = false
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "history" }
    func state() -> [BpyLine] {
        [BpyLine(.output, #"{"undo": \#(index > 0), "redo": false, "undo_label": "Step", "redo_label": "", "mode": "blender", "why": "scripted", "steps": \#(steps), "index": \#(index), "timing": {}}"#)]
    }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        if source.contains("_bk_undo.push(") {
            if !source.contains("replace=True") || index < 0 || rewound { index += 1 }
            rewound = false; steps = index + 1
            return state()
        }
        if source.contains("_bk_undo.rewind()") { index -= 1; rewound = true; return state() }
        if source.contains("print(_bk_adjustable)") { return [BpyLine(.output, "True"), BpyLine(.output, "Sphere")] }
        return []
    }
}

let args = CommandLine.arguments
let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

func matrix(_ m: [Float]) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                            SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
}

func axes(_ nine: [Float]) -> simd_float3x3 {
    simd_float3x3(SIMD3(nine[0], nine[1], nine[2]), SIMD3(nine[3], nine[4], nine[5]),
                  SIMD3(nine[6], nine[7], nine[8]))
}

/// The fixture as the mirror would install it.
func scene(_ f: [String: Any]) -> (BKScene, BKObject) {
    let s = BKScene(startupFile: false)
    var active: BKObject?
    var selected: Set<UUID> = []
    for record in f["objects"] as! [[String: Any]] {
        let o = s.add(.cube)
        o.name = record["name"] as! String
        o.setMirroredTransform(matrix(floats(record["matrix"])))
        if let parent = record["parent"] as? String {
            o.parentName = parent
            o.dependencies = [parent]
        }
        if record["selected"] as? Bool == true { selected.insert(o.id) }
        if o.name == f["active"] as! String { active = o }
    }
    s.selection = selected
    s.activeID = active!.id
    let c = floats(f["cursor"])
    s.cursor = SIMD3(c[0], c[1], c[2])
    s.tools.pivot = TransformPivot.allCases.first { $0.bpyIdentifier == f["pivot"] as! String } ?? .medianPoint
    if f["mode"] as? String == "EDIT" {
        let o = active!
        let co = floats(f["co"])
        let edges = ints(f["edges"])
        let selection = Set((f["selected"] as! [NSNumber]).map(\.intValue))
        let vertices = stride(from: 0, to: co.count, by: 3).map {
            MeshVertex(SIMD3(co[$0], co[$0 + 1], co[$0 + 2]), SIMD3(0, 0, 1))
        }
        var mesh = MeshData(vertices: vertices, indices: ints(f["tris"]))
        ModifierStack.recomputeNormals(&mesh, welded: true)
        let m = o.modelMatrix
        o.setEvaluatedMesh(mesh)
        o.setMirroredTransform(m)
        s.setMode(.edit)
        let report = BlenderEditReport(
            selectMode: 1,
            vertexSelected: vertices.indices.map { selection.contains($0) ? 1 : 0 },
            trianglePolygons: ints(f["tri_poly"]),
            polygonSelected: Array(repeating: 0, count: (f["polygons"] as! NSNumber).intValue),
            edgeVertices: edges,
            edgeSelected: stride(from: 0, to: edges.count, by: 2).map {
                selection.contains(Int(edges[$0])) && selection.contains(Int(edges[$0 + 1])) ? 1 : 0
            })
        precondition(s.mirrorEditSelection(report, on: o), "the fixture did not mirror as Blender's mesh")
    }
    return (s, active!)
}

func orientation(_ f: [String: Any], _ o: TransformOrientation) -> OrientationState {
    let table = f["orient"] as! [String: Any]
    guard o != .view, let nine = table[o.bpyIdentifier] else { return OrientationState(type: o) }
    return OrientationState(type: o, axes: axes(floats(nine)))
}

/// Where things stand, as one list: an edited mesh's vertices in the world,
/// or each selected object's world matrix (columns 0…3, xyz).
func places(_ s: BKScene, _ active: BKObject) -> [Float] {
    if s.mode == .edit {
        let m = active.modelMatrix
        return active.mesh.vertices.flatMap { v -> [Float] in
            let w = (m * SIMD4(v.position, 1)).xyz
            return [w.x, w.y, w.z]
        }
    }
    return s.objects.filter { s.selection.contains($0.id) }.flatMap { o -> [Float] in
        let m = o.modelMatrix
        return [m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz, m.columns.3.xyz].flatMap { [$0.x, $0.y, $0.z] }
    }
}

enum Drag { case axis(Int), plane(Int), screen }

/// A drag of the gizmo through the session, as the viewport makes it.
func drag(_ s: BKScene, _ mode: TransformGizmo.Mode, _ d: Drag)
    -> (TransformGizmo.Session, TransformGizmo.Result)? {
    guard let g = TransformGizmo.make(mode: mode, scene: s, options: options, camera: camera, size: size)
    else { return nil }
    let p = TransformGizmo.Projection(camera: camera, size: size)
    guard let c = p.project(g.origin) else { return nil }
    var a = CGPoint(x: c.x + 3, y: c.y + 2), b = CGPoint(x: c.x + 43, y: c.y - 23)
    let handle: TransformGizmo.Handle
    switch (mode, d) {
    case (.rotate, .axis(let k)):
        handle = .axis(k)
        a = CGPoint(x: c.x + 110, y: c.y)
        b = CGPoint(x: c.x + 110 * cos(0.7), y: c.y + 110 * sin(0.7))
    case (.rotate, _):
        handle = .screen
        a = CGPoint(x: c.x + 110, y: c.y)
        b = CGPoint(x: c.x + 110 * cos(-0.5), y: c.y + 110 * sin(-0.5))
    case (_, .axis(let k)):
        handle = .axis(k)
        guard let t = p.project(g.origin + g.axes[k] * g.radius) else { return nil }
        a = t
        let f: CGFloat = mode == .scale ? 1.5 : 1.7
        b = CGPoint(x: c.x + (t.x - c.x) * f, y: c.y + (t.y - c.y) * f)
    case (_, .plane(let k)):
        handle = .plane(k)
        let (j, l) = ((k + 1) % 3, (k + 2) % 3)
        guard let h = p.project(g.origin + (g.axes[j] + g.axes[l]) * (g.radius * 0.42)) else { return nil }
        a = h
        b = mode == .scale ? CGPoint(x: c.x + (h.x - c.x) * 1.4, y: c.y + (h.y - c.y) * 1.4)
                           : CGPoint(x: h.x + 37, y: h.y - 21)
    case (_, .screen):
        handle = .screen
        if mode == .scale { b = CGPoint(x: c.x + 3 * 1.3, y: c.y + 2 * 1.3); a = CGPoint(x: c.x + 3, y: c.y + 2) }
    }
    let session = TransformGizmo.beginSession(handle: handle, at: a, gizmo: g, scene: s, camera: camera,
                                              size: size, options: options)
    guard let raw = TransformGizmo.resolve(session, at: b) else { return nil }
    return (session, TransformGizmo.snapped(raw, session: session, at: b))
}

if args.count >= 4, args[1] == "dump" {
    let fixtures = load(args[2]) as! [String: [String: Any]]
    var cases: [[String: Any]] = []
    func record(_ fixture: String, _ o: String, _ label: String, _ op: LastOperator, _ expect: [Float],
                individual: Bool = false, first: LastOperator? = nil) {
        var entry: [String: Any] = ["fixture": fixture, "orient": o, "label": label,
                                    "python": BpyBridge.performBody(for: op, backup: false),
                                    "call": op.python, "expect": expect, "individual": individual]
        // A redo-panel change: what ran first, which the bridge rewinds
        // before running the change (`readjustThroughUndo`).
        if let first { entry["first"] = BpyBridge.performBody(for: first, backup: false) }
        cases.append(entry)
    }
    let drags: [(TransformGizmo.Mode, Drag, String)] = [
        (.translate, .axis(0), "Move X"), (.translate, .axis(1), "Move Y"), (.translate, .axis(2), "Move Z"),
        (.translate, .plane(2), "Move in the XY plane"), (.translate, .plane(0), "Move in the YZ plane"),
        (.translate, .screen, "Move in the view"),
        (.rotate, .axis(0), "Rotate X"), (.rotate, .axis(1), "Rotate Y"), (.rotate, .axis(2), "Rotate Z"),
        (.rotate, .screen, "Rotate in the view"),
        (.scale, .axis(0), "Scale X"), (.scale, .axis(2), "Scale Z"), (.scale, .plane(2), "Scale in the XY plane"),
        (.scale, .screen, "Scale all")]
    for name in fixtures.keys.sorted() {
        let f = fixtures[name]!
        for o in TransformOrientation.allCases {
            for (mode, d, label) in drags {
                let (s, active) = scene(f)
                s.orientation = orientation(f, o)
                guard let (session, result) = drag(s, mode, d) else {
                    print("  no gizmo to drag for \(name) \(o.label) \(label): its handle is edge-on"); continue
                }
                TransformGizmo.apply(result, session: session)
                let preview = places(s, active)
                record(name, o.bpyIdentifier, label, TransformGizmo.commitOperator(result, session: session), preview)
            }
        }
        // The redo panel, on one object: the Orientation switched to each of
        // the others (Blender works each out itself, View the view's), the
        // values typed, and in Edit Mode Proportional Editing turned on.
        guard name != "obj_pair" else { continue }
        for from in [TransformOrientation.normal, .local] {
            let (s, _) = scene(f)
            s.orientation = orientation(f, from)
            guard let (session, result) = drag(s, .translate, .axis(2)) else { continue }
            let op = TransformGizmo.commitOperator(result, session: session)
            let values = LastOperator.committedValues(op)!
            for to in TransformOrientation.allCases where to != from {
                var changed = op
                changed["orient_type"] = Double(to.rawValue)
                let m: simd_float3x3 = to == .view ? session.frame.viewAxes
                    : (orientation(f, to).axes ?? matrix_identity_float3x3)
                let (s2, active2) = scene(f)
                let expected = TransformOperation(kind: .translate(m * values),
                                                  pivot: .point(TransformGizmo.committedPivot(session)))
                apply(expected, s2, active2)
                record(name, to.bpyIdentifier, "redo: Move Z in \(from.label), then Orientation \(to.label)",
                       changed, places(s2, active2), first: op)
            }
            var typed = op
            typed["value.x"] = 0.5; typed["value.y"] = -0.25; typed["value.z"] = 0.75
            let (s3, active3) = scene(f)
            apply(TransformOperation(kind: .translate(session.frame.axes * SIMD3(0.5, -0.25, 0.75)),
                                     pivot: .point(TransformGizmo.committedPivot(session))), s3, active3)
            record(name, from.bpyIdentifier, "redo: Move X, Y and Z typed in \(from.label)", typed, places(s3, active3),
                   first: op)
        }
        if f["mode"] as? String == "EDIT" {
            // Proportional Editing turned on in the panel, against a drag that
            // had it on from the start — its preview is Blender's then.
            let (s, _) = scene(f)
            s.orientation = orientation(f, .normal)
            s.tools.falloff = .linear
            s.tools.size = 1.25
            guard let (session, result) = drag(s, .translate, .axis(2)) else { continue }
            var on = TransformGizmo.commitOperator(result, session: session)
            on["use_proportional_edit"] = 1
            let (s2, active2) = scene(f)
            s2.orientation = orientation(f, .normal)
            s2.tools.falloff = .linear
            s2.tools.size = 1.25
            s2.tools.proportionalEdit = true
            guard let (session2, result2) = drag(s2, .translate, .axis(2)) else { continue }
            TransformGizmo.apply(result2, session: session2)
            record(name, "NORMAL", "redo: Proportional Editing turned on (Linear, 1.25)", on, places(s2, active2),
                   first: TransformGizmo.commitOperator(result, session: session))
        }
    }
    // Individual Origins: two objects turned and scaled about their own
    // origins, in Global and in Normal (each object's own axes there).
    // Said, not trapped on, when the fixtures file has no pair (a fixtures
    // file of one's own, as round 4's review ran: two SIGTRAPs here).
    let pair = fixtures["obj_pair"]
    if pair == nil { dumpFailed("the fixtures have no obj_pair, so Individual Origins was not dragged") }
    for o in [TransformOrientation.global, .normal, .cursor] where pair != nil {
        for (mode, d, label) in [(TransformGizmo.Mode.rotate, Drag.axis(2), "Rotate Z"),
                                 (.scale, .axis(0), "Scale X")] {
            let (s, active) = scene(pair!)
            s.tools.pivot = .individualOrigins
            s.orientation = orientation(pair!, o)
            guard let (session, result) = drag(s, mode, d) else { continue }
            TransformGizmo.apply(result, session: session)
            record("obj_pair", o.bpyIdentifier, "Individual Origins: \(label)",
                   TransformGizmo.commitOperator(result, session: session), places(s, active), individual: true)
        }
    }
    // A tap read early: the viewport's tap handed to Blender by a read
    // (`captureWithSelection`, as Normal's refresh and the Sidebar make on
    // every tap), then a gizmo Move, then the redo panel's typed Move Z —
    // each source exactly as the bridge sends it, through a runtime that
    // answers as the app's undo history does. run_calls.py runs them in
    // order with the app's undo and holds the re-run to the tap.
    if fixtures["edit_sphere"] == nil { dumpFailed("the fixtures have no edit_sphere, so the tap read early was not run") }
    for byMenu in [false, true] {
    guard let f = fixtures["edit_sphere"] else { break }
    do {
        let (s, active) = scene(f)
        s.orientation = orientation(f, .global)
        let tapped = 12
        s.editSelection.vertices = [tapped]
        s.editSelection.edges = []
        s.editSelection.faces = []
        s.editSelection.history = [.vertex(tapped)]
        let recorder = HistoryRecorder()
        let session = BpySession(runtime: recorder)
        session.bind(scene: s, undo: UndoStack())
        let bridge = BpyBridge(session: session, scene: s, undo: UndoStack())
        // A step to begin from, as the app's session has before any tap;
        // then the tap, which nothing has told Blender of yet.
        bridge.run("pass", undo: "Edit Mode")
        s.editSelectionPending = true
        let early: String
        if byMenu {
            // The Orientation menu's setting carries the tap and records no
            // step; the mirror then reads the tap back and clears its flag.
            let from = recorder.sources.count
            bridge.run(OrientationBpy.set(.global))
            early = recorder.sources.dropFirst(from).first { $0.contains("set_tools(") } ?? ""
            s.editSelectionPending = false
        } else {
            _ = bridge.captureWithSelection(OrientationBpy.report)
            early = recorder.sources.last ?? ""
        }
        if let (gs, result) = drag(s, .translate, .axis(2)) {
            let from = recorder.sources.count
            TransformGizmo.commit(result, session: gs, bridge: bridge)
            let first = recorder.sources.dropFirst(from).first { $0.contains("bpy.ops.transform.translate(") }
            if var op = bridge.adjustable, let first {
                op["value.z"] = 0.5
                let values = LastOperator.committedValues(op)!
                let rerunFrom = recorder.sources.count
                let rerun = bridge.readjust(op)
                let python = recorder.sources.dropFirst(rerunFrom).first { $0.contains("bpy.ops.transform.translate(") }
                if rerun != nil, let python {
                    let (s2, active2) = scene(f)
                    s2.editSelection.vertices = [tapped]
                    apply(TransformOperation(kind: .translate(gs.frame.axes * values),
                                             pivot: .point(TransformGizmo.committedPivot(gs))), s2, active2)
                    let how = byMenu ? "a tap carried by the Orientation menu's setting" : "a tap read early"
                    cases.append(["fixture": "edit_sphere", "orient": "GLOBAL", "individual": false,
                                  "label": "\(how) (vertex \(tapped)), a Move, then the redo panel's Move Z 0.5",
                                  "early": early, "first": first, "python": python, "call": op.python,
                                  "expect": places(s2, active2),
                                  // What the bridge sent before round 4's review fixed it: the re-run
                                  // without the tap, which the read had cleared.
                                  "python_without_tap": BpyBridge.script(push: nil, discardBackup: false,
                                                                         body: BpyBridge.performBody(for: op, backup: false))])
                } else { dumpFailed("the tap read early: the redo panel did not re-run") }
            } else { dumpFailed("the tap read early: the Move did not open the redo panel") }
        }
        withExtendedLifetime(active) {}
    }
    }
    try! JSONSerialization.data(withJSONObject: cases).write(to: URL(fileURLWithPath: args[3]))
    print("  \(cases.count) drags and redo-panel changes from the Swift")
    exit(dumpFailures == 0 ? 0 : 1)
}

/// Applies an operation to the fixture's display cache, as the preview does.
func apply(_ op: TransformOperation, _ s: BKScene, _ active: BKObject) {
    if s.mode == .edit {
        let mesh = active.editCage
        let selected = s.editSelection.vertices
        var factors = [Float](repeating: 0, count: mesh.vertices.count)
        for i in selected where i < factors.count { factors[i] = 1 }
        let moved = op.apply(toVertices: mesh.vertices.map(\.position), factors: factors,
                             selected: selected, model: active.modelMatrix)
        var out = mesh
        for i in out.vertices.indices { out.vertices[i].position = moved[i] }
        active.installTransformed(out)
        return
    }
    for o in s.objects where s.selection.contains(o.id) {
        guard case .translate(let d) = op.kind else { continue }
        o.location += d
    }
}

if args.count >= 4, args[1] == "parse" {
    var failures = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "  " + detail))
        if !ok { failures += 1 }
    }
    // An earlier stage that failed leaves no file: said, not trapped on.
    guard let reportText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let stateText = try? String(contentsOfFile: args[3], encoding: .utf8) else {
        print("  FAIL  Blender wrote no reports or states for this stage to read (an earlier stage failed)")
        exit(1)
    }
    let reports = reportText.split(separator: "\n").map(String.init)
    var parsed = 0
    for line in reports where !line.isEmpty {
        guard let state = OrientationState.parse(line) else { check("report reads: \(line)", false); continue }
        let words = line.split(separator: " ")
        if line.contains(" none") {
            check("a report with no matrix reads as none: \(words[0])", state.axes == nil)
        } else {
            let numbers = words.suffix(9).compactMap { Float($0) }
            let a = state.axes!
            let read = [a.columns.0, a.columns.1, a.columns.2].flatMap { [$0.x, $0.y, $0.z] }
            let name = words.dropLast(9).joined(separator: " ")
            check("the report's nine numbers are the axes it said: \(name)",
                  zip(read, numbers).allSatisfy { abs($0 - $1) < 1e-6 }
                    && (state.type?.bpyIdentifier ?? state.customName) == name)
        }
        parsed += 1
    }
    check("every report read (\(parsed))", parsed == reports.filter { !$0.isEmpty }.count)
    let states = stateText.split(separator: "\n").map(String.init)
    for line in states where !line.isEmpty {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2, let data = parts[1].data(using: .utf8),
              let expected = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let state = EditItemState.parse(parts[1])
        if expected["mesh"] as? Bool != true {
            check("\(parts[0]): no mesh being edited reads as none", state == nil)
            continue
        }
        guard let state else { check("\(parts[0]): the state reads", false, parts[1]); continue }
        let tot = (expected["tot"] as! NSNumber).intValue, edges = (expected["edges"] as! NSNumber).intValue
        check("\(parts[0]): \(state.medianTitle) \(tot) vertices, \(edges) edges",
              state.vertices == tot && state.edges == edges
                && state.medianTitle == (tot == 1 ? "Vertex:" : "Median:"))
        if let m = expected["median"] as? [NSNumber], let median = state.median {
            check("\(parts[0]): the median reads", zip([median.x, median.y, median.z], m.map(\.floatValue))
                .allSatisfy { abs($0 - $1) < 1e-5 })
        }
        let labels = state.dataRows.map(\.label)
        let wantLabels = (tot > 0 ? [tot == 1 ? "Bevel Weight:" : "Mean Bevel Weight:",
                                     tot == 1 ? "Vertex Crease:" : "Mean Vertex Crease:"] : [])
            + (edges > 0 ? [edges == 1 ? "Bevel Weight:" : "Mean Bevel Weight:",
                            edges == 1 ? "Crease:" : "Mean Crease:"] : [])
        check("\(parts[0]): Blender's labels \(labels)", labels == wantLabels)
    }
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

print("usage: main dump <fixtures.json> <cases.json> | parse <reports.txt> <states.txt>")
exit(2)
