import Foundation

// The Swift half of undo with the real module: reading the state the Python
// reports, and deciding when the crash-recovery file is written.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

print("Undo history state")

let printed = """
Info: Saved "3f2a.blend"
{"undo": true, "redo": false, "undo_label": "Add Cube", "redo_label": "", "mode": "blender", "why": "push 0.8 ms, undo and redo 2.2 ms", "steps": 3, "index": 2, "timing": {"blender": 0.38, "total": 0.4}}
"""
let state = BackendHistoryState.parse(printed)
check("the state is read past Blender's informational lines", state != nil)
check("undo and redo", state?.undo == true && state?.redo == false)
check("the label of the step Undo would undo", state?.undoLabel == "Add Cube", state?.undoLabel ?? "nil")
check("Blender's undo is in use", state?.usesBlenderUndo == true && state?.mode == "blender")
check("position and timing", state?.index == 2 && state?.steps == 3 && state?.timing["blender"] == 0.38)
check("a log line names the mode and every cost, in a stable order",
      state?.logLine("Add Cube") == "[bk-undo] Add Cube · blender · step 3 of 3 · blender 0.38 ms, total 0.40 ms",
      state?.logLine("Add Cube") ?? "nil")

let older = BackendHistoryState.parse(#"{"undo": false, "redo": true}"#)
check("a state with only undo and redo still reads, as the checkpoint history printed it",
      older?.undo == false && older?.redo == true && older?.mode == "pending" && older?.timing == [:])
check("output with no state in it reads as nothing", BackendHistoryState.parse("Traceback (most recent call last):\n  x") == nil)
let fallback = BackendHistoryState.parse(#"{"undo": true, "redo": true, "undo_label": "Move", "redo_label": "Bevel", "mode": "checkpoint", "why": "RuntimeError: no screen", "steps": 4, "index": 1, "timing": {"file": 12.5}}"#)
check("the fallback reads as not Blender's undo, with its reason",
      fallback?.usesBlenderUndo == false && fallback?.why == "RuntimeError: no screen" && fallback?.redoLabel == "Bevel")

print("\nWhen the recovery file is written")

let t0 = Date(timeIntervalSinceReferenceDate: 1000)
var policy = AutosavePolicy()
check("nothing changed: nothing to write", policy.decide(at: t0, running: false) == .nothing)
policy.noteChange(at: t0)
check("a change is pending", policy.isPending)
check("half a second later it waits out the rest of the quiet",
      policy.decide(at: t0.addingTimeInterval(0.5), running: false) == .wait(1.5),
      "\(policy.decide(at: t0.addingTimeInterval(0.5), running: false))")
check("two seconds of quiet: write", policy.decide(at: t0.addingTimeInterval(2), running: false) == .write)
check("but not while a script runs", policy.decide(at: t0.addingTimeInterval(5), running: true) == .wait(AutosavePolicy.quiet))
policy.noteChange(at: t0.addingTimeInterval(1.9))
check("another change restarts the quiet",
      policy.decide(at: t0.addingTimeInterval(2.5), running: false) == .wait(1.4000000000000001)
        || { if case .wait(let s) = policy.decide(at: t0.addingTimeInterval(2.5), running: false) { return abs(s - 1.4) < 1e-9 }; return false }())
policy.noteWritten()
check("once written, nothing is pending", !policy.isPending && policy.decide(at: t0.addingTimeInterval(9), running: false) == .nothing)

print("\nThe session and the redo panel against a device backend")

/// Answers the history's calls the way `_blenderkit_undo` does, keeping a
/// step count, and records everything sent in order.
final class HistoryRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var mode: String
    var sent: [String] = []
    var steps = 0
    var index = -1
    var rewindFails = false
    /// Set by a rewind: the push after it takes the undone step's place.
    var rewound = false
    var failing: (String) -> Bool = { _ in false }
    init(mode: String) { self.mode = mode }
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "history" }
    func state() -> [BpyLine] {
        [BpyLine(.output, #"{"undo": \#(index > 0), "redo": \#(index + 1 < steps), "undo_label": "Step", "redo_label": "", "mode": "\#(mode)", "why": "scripted", "steps": \#(steps), "index": \#(index), "timing": {"total": 0.5}}"#)]
    }
    func answer(_ source: String) -> [BpyLine] {
        sent.append(source)
        if failing(source) { return [BpyLine(.error, "RuntimeError: scripted failure")] }
        if source.contains("_bk_undo.push(") {
            // As `_blenderkit_undo.push`: a replace takes the current step's
            // place, and after a rewind the current step is the one before it.
            if !source.contains("replace=True") || index < 0 || rewound { index += 1 }
            rewound = false
            steps = index + 1
            return state()
        }
        if source.contains("_bk_undo.step(-1)") { index = max(0, index - 1); return state() }
        if source.contains("_bk_undo.step(1)") { index = min(steps - 1, index + 1); return state() }
        if source.contains("_bk_undo.rewind()") {
            if rewindFails || index == 0 { return [BpyLine(.error, "RuntimeError: There is no step before this one")] }
            index -= 1; rewound = true; return state()
        }
        if source.contains("_bk_undo.cancel_rewind()") {
            if rewound { index += 1; rewound = false }
            return state()
        }
        if source.contains("_bk_undo.autosave(") { return [BpyLine(.output, "12.5")] }
        if source.contains("print(_bk_adjustable)") { return [BpyLine(.output, "True"), BpyLine(.output, "Cylinder")] }
        if source.contains("objects.active.name") { return [BpyLine(.output, "Cylinder")] }
        return []
    }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] { answer(source) }
    func query(_ source: String, scene: BKScene) -> [BpyLine] { answer(source) }
}

func rig(_ runtime: BpyRuntime) -> (BKScene, UndoStack, BpySession, BpyBridge) {
    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    return (scene, undo, session, BpyBridge(session: session, scene: scene, undo: undo))
}

func index(of needle: String, in sent: [String], from: Int = 0) -> Int? {
    sent.indices.dropFirst(from).first { sent[$0].contains(needle) }
}

// The bridge holds its scene weakly, as it does in the app, so each block keeps
// the scene alive itself.
do {
    let device = HistoryRuntime(mode: "blender")
    let (scene, _, session, bridge) = rig(device)
    defer { withExtendedLifetime(scene) {} }
    let cylinder = LastOperator.add(.cylinder, at: .zero)
    bridge.perform(cylinder)
    let original = index(of: "\"Original\"", in: device.sent)
    let body = index(of: "primitive_cylinder_add(", in: device.sent)
    let step = index(of: "\"Add Cylinder\", replace=False", in: device.sent)
    check("the first action seeds the history before its body is built, then pushes its own step",
          original != nil && body != nil && step != nil && original! < body! && body! < step!,
          "\(device.sent)")
    check("the session knows Blender's undo keeps the history", session.backendUsesBlenderUndo)
    let meshOp = LastOperator.mesh(.bevel)
    bridge.perform(meshOp)
    check("a mesh operator takes no mesh backup with Blender's undo",
          device.sent.last { $0.contains("bpy.ops.mesh.bevel(") }.map { !$0.contains("_bk_redo") } == true)

    bridge.perform(cylinder)
    var eight = bridge.adjustable!
    eight["vertices"] = 8
    let from = device.sent.count
    let adjusted = bridge.readjust(eight, record: false)
    let rewind = index(of: "_bk_undo.rewind()", in: device.sent, from: from)
    let rerun = index(of: "vertices=8", in: device.sent, from: from)
    let replace = index(of: "\"Add Cylinder\", replace=True", in: device.sent, from: from)
    check("adjusting is rewind, re-run, push in that order",
          adjusted != nil && rewind != nil && rerun != nil && replace != nil && rewind! < rerun! && rerun! < replace!,
          "\(Array(device.sent[from...]))")
    check("the re-run runs the operator, not LastOperator's removal",
          rerun.map { !device.sent[$0].contains("bpy.data.objects.get(") } == true)
    check("and the history is as high as before", device.steps == 4 && session.backendCanUndo, "\(device.steps)")
    check("the redo panel stays up after its own adjustment", bridge.adjustable?["vertices"] == 8)
    let afterAdjust = device.sent.count
    bridge.recordAdjustment()
    check("the end of a drag writes nothing more", device.sent.count == afterAdjust,
          "\(Array(device.sent[afterAdjust...]))")

    device.failing = { $0.contains("vertices=12") }
    var twelve = bridge.adjustable!
    twelve["vertices"] = 12
    let failFrom = device.sent.count
    check("a re-run that fails is not adjusted", bridge.readjust(twelve) == nil)
    check("and goes back to the step it undid, pushing nothing",
          index(of: "_bk_undo.cancel_rewind()", in: device.sent, from: failFrom) != nil
            && index(of: "_bk_undo.push(", in: device.sent, from: failFrom) == nil
            && device.index == 3, "\(Array(device.sent[failFrom...]))")
    device.failing = { _ in false }

    device.rewindFails = true
    let rewindFrom = device.sent.count
    check("when there is nothing to go back to, nothing is run", bridge.readjust(twelve) == nil
          && index(of: "vertices=12", in: device.sent, from: rewindFrom) == nil)
    device.rewindFails = false

    session.performUndo()
    check("undo steps the history and reads what it can do next",
          device.sent.last == BackendHistoryPython.step(-1) && session.backendCanRedo)
    check("and an undo ends the redo panel", bridge.adjustable == nil)

    let writes = device.sent.filter { $0.contains("_bk_undo.autosave(") }.count
    check("no step writes the recovery file", writes == 0, "\(writes)")
    session.flushBackendAutosave()
    check("going to the background writes it once",
          device.sent.filter { $0.contains("_bk_undo.autosave(") }.count == 1)
    session.flushBackendAutosave()
    check("and not again with nothing new", device.sent.filter { $0.contains("_bk_undo.autosave(") }.count == 1)
}

do {
    let device = HistoryRuntime(mode: "checkpoint")
    let (scene, _, session, bridge) = rig(device)
    defer { withExtendedLifetime(scene) {} }
    bridge.perform(LastOperator.mesh(.bevel))
    check("with checkpoints a mesh operator still takes its backup",
          !session.backendUsesBlenderUndo
            && device.sent.last { $0.contains("bpy.ops.mesh.bevel(") }.map { $0.contains("_bk_redo") } == true)
    var wide = bridge.adjustable!
    wide["offset"] = 0.3
    let from = device.sent.count
    bridge.readjust(wide, record: false)
    check("and adjusting restores the mesh from it, without an undo",
          index(of: "_bk_undo.rewind()", in: device.sent, from: from) == nil
            && index(of: "bpy.data.meshes.get(\"_bk_redo\")", in: device.sent, from: from) != nil
            && index(of: "_bk_undo.push(", in: device.sent, from: from) == nil)
    bridge.recordAdjustment()
    check("writing the step once the drag ends", device.sent.last?.contains("replace=True") == true)
}

print("\nThe simulator's undo keeps a modified mesh's base, not its stack output")
do {
    // Round 2's review, through UndoStack: a cube with Mirror X and Clipping,
    // one vertex dragged, went 24 base / 48 shown after the drag, 24 / 48
    // after undo and 48 / 96 after redo, because the snapshot recorded the
    // stack's output and the restore ran the stack over it again. With a
    // Subdivision, 24 / 54 became 54 / 150.
    for (label, kinds) in [("Mirror X with Clipping", [ModifierKind.mirror]), ("a Subdivision", [.subdivision])] {
        let scene = BKScene(startupFile: false)
        scene.objects = []
        let cube = scene.add(.cube)
        cube.name = "Cube"
        cube.modifiers = kinds.map { kind in
            var m = Modifier(kind: kind)
            if kind == .mirror { m.mirrorClip = true }
            return m
        }
        let base = cube.evaluatedBase.vertices.count
        let shown = cube.mesh.vertices.count
        let undo = UndoStack()
        undo.push("Original", scene)
        // A drag's commit in the simulator: the cage moved and installed once.
        var cage = cube.editCage
        cage.vertices[0].position += SIMD3(0, 0, 0.25)
        cube.installTransformed(cage)
        undo.push("Move", scene)
        func counts() -> (Int, Int) {
            let o = scene.objects.first { $0.name == "Cube" }!
            return (o.evaluatedBase.vertices.count, o.mesh.vertices.count)
        }
        let afterDrag = counts()
        _ = undo.undo(into: scene)
        let afterUndo = counts()
        _ = undo.redo(into: scene)
        let afterRedo = counts()
        _ = undo.undo(into: scene); _ = undo.redo(into: scene)
        let twice = counts()
        check("\(label): \(base) base / \(shown) shown after the drag, an undo, a redo, and again",
              [afterDrag, afterUndo, afterRedo, twice].allSatisfy { $0 == (base, shown) },
              "\(afterDrag) \(afterUndo) \(afterRedo) \(twice)")
        let moved = scene.objects.first { $0.name == "Cube" }!.evaluatedBase.vertices[0].position
        check("\(label): and the redo brings the moved vertex back", abs(moved.z - (cage.vertices[0].position.z)) < 1e-6,
              "\(moved)")
    }
    // Blender's evaluated mesh, as the mirror installs it, comes back as one:
    // the stack is a description then, and must not run over it.
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let cube = scene.add(.cube)
    cube.name = "Cube"
    cube.modifiers = [Modifier(kind: .subdivision)]
    let evaluated = cube.mesh
    cube.setEvaluatedMesh(evaluated)
    let undo = UndoStack()
    undo.push("Original", scene)
    undo.push("Again", scene)
    _ = undo.undo(into: scene)
    let back = scene.objects.first { $0.name == "Cube" }!
    check("an evaluated mesh is restored as evaluated, the stack not run over it",
          back.meshIsEvaluated && back.mesh.vertices.count == evaluated.vertices.count,
          "\(back.mesh.vertices.count) for \(evaluated.vertices.count)")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
