import SwiftUI
import UIKit
import MetalKit
import simd

/// The 3D View's own functions Test All Features needs, which live in its
/// private state: the toolbar's tool (`choose`, which also takes Blender into
/// Sculpt Mode and the paint modes), the mode menu's Weight Paint and Vertex
/// Paint rows, and Viewport Shading and X-Ray. `LayoutWorkspace` hands them
/// over while it is on screen (`FeatureTestDoor.hold`). Everything else the
/// test runs through the bridge-level calls those functions wrap.
struct FeatureTestLayoutDoor {
    /// The 3D View's camera, which its one-finger, two-finger and pinch
    /// gestures move (the root view's, through the view's binding). Read and
    /// set here rather than handed to the test's sheet as a binding, which
    /// would redraw the sheet at every frame of a drag.
    var camera: () -> ViewportCamera
    var setCamera: (ViewportCamera) -> Void
    var choose: (ActiveTool) -> Void
    var enterPaintMode: (InteractionMode) -> Void
    var setShading: (ViewportShading) -> Void
    var shading: () -> ViewportShading
    var setXRay: (Bool) -> Void
    var tool: () -> ActiveTool
}

enum FeatureTestDoor {
    /// The Layout tab's 3D View, while it is on screen.
    nonisolated(unsafe) static var layout: FeatureTestLayoutDoor?
    nonisolated(unsafe) private static var holder: UUID?

    /// Holds `door` out for as long as the calling task runs (the view's
    /// `.task`, cancelled when it leaves the screen).
    static func hold(_ door: FeatureTestLayoutDoor) async {
        let token = UUID()
        layout = door
        holder = token
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        if holder == token { layout = nil; holder = nil }
    }
}

/// What the Test All Features sheet shows of a run.
@Observable
final class FeatureTestRun {
    var running = false
    var index = 0
    var total = 0
    var current = ""
    var results: [FeatureTest.Result] = []
    var notTested: [(name: String, reason: String)] = []
    var summary: String?
    var restored: String?
    var refusal: String?
    var report: URL?
    var text = ""

    func start() {
        running = true
        index = 0
        total = 0
        current = "Saving your scene"
        results = []
        notTested = []
        summary = nil
        restored = nil
        refusal = nil
        report = nil
        text = ""
    }

    func finish(_ url: URL?) {
        running = false
        report = url
        text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

/// Test All Features' driver: each feature of `FeatureTest.inventory` through
/// the Swift its control calls, measured as a user feels it.
///
/// On the main thread, as the controls run, with the run loop free between
/// features — and between the moments of a drag, which are paced at 60 Hz as
/// a finger's are — so the 3D View draws as it would for a person. A feature
/// is timed from its call to the first frame the 3D View began after it
/// (`FrameClock`), and the longest the main thread took to answer meanwhile is
/// its stall (`MainThreadWatchdog`).
///
/// The scene is the test's own: `BpySession.beginFeatureTest` saves the
/// user's and opens Blender's startup file, `endFeatureTest` puts it back.
@MainActor
final class FeatureTestRunner {
    let scene: BKScene
    let session: BpySession
    let bridge: BpyBridge
    let workspace: Binding<Workspace>
    let cycles: Bool
    let run: FeatureTestRun

    init(scene: BKScene, session: BpySession, bridge: BpyBridge,
         workspace: Binding<Workspace>, cycles: Bool, run: FeatureTestRun) {
        self.scene = scene
        self.session = session
        self.bridge = bridge
        self.workspace = workspace
        self.cycles = cycles
        self.run = run
    }

    /// A feature that did not do what its control does: said in the report.
    struct Failure: Error { let detail: String }
    /// A feature this device or build cannot run: listed as not tested.
    struct Skip: Error { let reason: String }

    /// What a feature measured.
    struct Measured {
        var stall: TimeInterval = 0
        var seconds: TimeInterval = 0
        var frames: FeatureTest.FrameStats?
        var peak: UInt64?
        var detail = ""
        var failure: String?
        var progressShown = false
        /// For playback, a frame at the scene's frame rate
        /// (`FeatureTest.rate`'s `pace`).
        var pace: TimeInterval?
    }

    /// The objects the run made, by the names Blender gave them.
    private var names: [String: String] = [:]
    private let watchdog = MainThreadWatchdog.shared
    private var temporary: URL { FileManager.default.temporaryDirectory }

    // MARK: The run

    /// Runs every feature and returns the report, or nil when it could not
    /// make one.
    func runAll(about: [(String, String)]) async -> URL? {
        let url = FeatureTest.folder.appendingPathComponent(FeatureTest.reportName())
        let report = FeatureTest.Report(url: url, about: about)
        report.running = "Saving your scene"
        guard report.write() else {
            run.refusal = "The report could not be written in Documents/Self-Test."
            return nil
        }
        let began = CACurrentMediaTime()
        let runStarted = Date()
        let memoryBefore = MemoryFootprint.now()
        let planned = FeatureTest.planned(cycles: cycles)
        var notTested = FeatureTest.notPlanned(cycles: cycles)
        run.total = planned.count

        let start = session.beginFeatureTest()
        guard start.started else {
            let why = start.refusal ?? "it did not start"
            run.refusal = "Test All Features did not run: \(why)."
            report.running = nil
            report.notes.append("not run: " + why)
            report.total = CACurrentMediaTime() - began
            report.summary = "Summary:  not run"
            report.write()
            return url
        }
        report.about.append(("Blender", start.blender))
        report.notes.append("your scene (\(start.objects) object\(start.objects == 1 ? "" : "s"), "
                            + "\(start.vertices) vertices) was saved and is opened again at the end")
        if !cycles { report.notes.append("Cycles was left out (its switch was off)") }
        watchdog.start()
        defer { watchdog.stop() }
        if workspace.wrappedValue != .layout { workspace.wrappedValue = .layout }
        _ = await waitForLayout()

        for (offset, entry) in planned.enumerated() {
            #if DEBUG
            // `-feature-test-only a,b,…`: those features alone, in the list's
            // order — name the ones a feature builds on too (`anim.scrub`
            // wants `sculpt.voxel_remesh` and `anim.insert_keyframe`).
            if let only = FeatureTestLaunch.only, !only.contains(entry.key) { continue }
            #endif
            let index = offset + 1
            run.index = index
            run.current = entry.name
            report.running = entry.name
            report.write()
            await settle()
            var measured: Measured
            do {
                measured = try await perform(entry)
            } catch let skip as Skip {
                notTested.append((entry.name, skip.reason))
                run.notTested = notTested
                report.running = nil
                report.write()
                continue
            } catch let failure as Failure {
                measured = Measured(failure: failure.detail)
            } catch {
                measured = Measured(failure: "\(error)")
            }
            // A stroke a failed feature left open would hold every command
            // after it.
            closeGestures()
            let rating = FeatureTest.rate(kind: entry.kind ?? .command, stall: measured.stall,
                                          frames: measured.frames, failed: measured.failure != nil,
                                          seconds: measured.seconds, progressShown: measured.progressShown,
                                          pace: measured.pace)
            let result = FeatureTest.Result(index: index, rating: rating, stall: measured.stall,
                                            seconds: measured.seconds, frames: measured.frames,
                                            peak: measured.peak, name: entry.name,
                                            detail: measured.failure ?? measured.detail)
            report.running = nil
            report.record(result)
            report.write()
            run.results.append(result)
            #if DEBUG
            if FeatureTestLaunch.requested {
                print("[bk-featuretest] " + FeatureTest.line(result))
                fflush(stdout)
            }
            #endif
        }

        // The user's scene back.
        await settle()
        closeGestures()
        if workspace.wrappedValue != .layout { workspace.wrappedValue = .layout }
        run.current = "Opening your scene again"
        report.running = "Your scene, opened again"
        report.write()
        let restored = session.endFeatureTest()
        run.restored = (restored.restored ? "Your scene came back: " : "Your scene did NOT come back exactly: ")
            + restored.detail
        report.notes.append("your scene, opened again: " + (restored.restored ? "" : "DIFFERS: ") + restored.detail)
        removePictures(since: runStarted)
        if let before = memoryBefore, let after = MemoryFootprint.now() {
            report.memory = "peak \(MemoryFootprint.megabytes(max(before.peak, after.peak))) over the app's life; "
                + "\(MemoryFootprint.megabytes(before.current)) before the test, "
                + "\(MemoryFootprint.megabytes(after.current)) after"
        }
        report.running = nil
        report.notTested = notTested
        report.total = CACurrentMediaTime() - began
        report.summary = FeatureTest.summary(report.results, notTested: notTested.count, seconds: report.total ?? 0)
        report.write()
        run.notTested = notTested
        run.summary = report.summary.map { String($0.dropFirst("Summary:  ".count)) }
        return url
    }

    // MARK: Measuring

    /// Until no script runs and nothing is held, and the 3D View has drawn a
    /// frame since: what the last feature left is not the next one's cost.
    private func settle() async {
        var waited = 0
        while (session.isRunning || session.gestureHold != nil) && waited < 600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        _ = await FrameClock.shared.frame(after: CACurrentMediaTime(), timeout: 0.5)
        _ = await FrameClock.shared.frame(after: CACurrentMediaTime(), timeout: 0.5)
        if let id = bridge.report?.id { bridge.dismissReport(id) }
    }

    /// The banner's words, when a new one went up since `before`.
    private func banner(since before: Int?) -> String? {
        guard let report = bridge.report, report.id != before else { return nil }
        return "the banner said: \(report.operation): \(report.message)"
    }

    /// A tap: `body` is the call its control makes; the time runs to the
    /// first frame begun after it returned.
    private func command(_ body: () throws -> String) async -> Measured {
        let reportBefore = bridge.report?.id
        let mirrorBefore = session.lastMirrorDuration
        watchdog.begin()
        let t0 = CACurrentMediaTime()
        var detail = ""
        var failure: String?
        do { detail = try body() } catch let f as Failure { failure = f.detail } catch { failure = "\(error)" }
        let t1 = CACurrentMediaTime()
        let shown = await FrameClock.shared.frame(after: t1)
        let window = watchdog.end()
        if failure == nil, let said = banner(since: reportBefore) { failure = said }
        if shown == nil { detail += detail.isEmpty ? "no frame drawn" : "; no frame drawn" }
        // Where a slow call's time went: the mirror pass after Blender's
        // work, when the call ran one.
        let mirror = session.lastMirrorDuration
        if t1 - t0 >= FeatureTest.smoothStall, mirror > 0.005, mirror != mirrorBefore, mirror <= t1 - t0 {
            detail += String(format: "; the mirror pass %.0f ms of it", mirror * 1000)
        }
        // The call held the main thread from start to end, which the
        // watchdog, asking every 16 ms, can miss when it is short.
        return Measured(stall: max(window.stall, t1 - t0), seconds: (shown ?? t1) - t0, peak: window.peak,
                        detail: detail, failure: failure)
    }

    /// A long job: `body` runs it to its end (a script on its own thread, a
    /// render, Image to 3D) and says whether progress was on screen meanwhile.
    private func long(_ body: () async throws -> (detail: String, progress: Bool)) async -> Measured {
        let reportBefore = bridge.report?.id
        watchdog.begin()
        let t0 = CACurrentMediaTime()
        var detail = ""
        var progress = false
        var failure: String?
        do { (detail, progress) = try await body() } catch let f as Failure { failure = f.detail }
        catch { failure = error.localizedDescription }
        let t1 = CACurrentMediaTime()
        let shown = await FrameClock.shared.frame(after: t1)
        let window = watchdog.end()
        if failure == nil, let said = banner(since: reportBefore) { failure = said }
        return Measured(stall: window.stall, seconds: (shown ?? t1) - t0, peak: window.peak,
                        detail: detail + (progress ? "" : "; no progress shown while it ran"),
                        failure: failure, progressShown: progress)
    }

    /// A long job the main thread runs from start to end — a save, an
    /// export, a file opened: measured as a tap is, its call the stall, and
    /// held to it as a long job is. Nothing on screen moves while it runs.
    private func longSync(_ body: () throws -> String) async -> Measured {
        var m = await command(body)
        m.detail += "; no progress shown while it ran"
        return m
    }

    /// A drag, a stroke or playback: `begin` is the touch coming down,
    /// `step` each moment at 60 Hz with how far along it is (0 to 1), `end`
    /// the lift. The steps are paced by the clock, not counted: when the main
    /// thread is held, the next moment is where the finger is by then, as a
    /// coalesced touch is.
    private func continuous(seconds: TimeInterval = FeatureTest.strokeSeconds,
                            begin: () throws -> Void, step: (Double) throws -> Void,
                            end: () throws -> String) async -> Measured {
        let reportBefore = bridge.report?.id
        FrameClock.shared.startRecording()
        watchdog.begin()
        let t0 = CACurrentMediaTime()
        var failure: String?
        var detail = ""
        // The longest single call of the drag: each holds the main thread.
        var held: TimeInterval = 0
        func timed<T>(_ call: () throws -> T) rethrows -> T {
            let from = CACurrentMediaTime()
            defer { held = max(held, CACurrentMediaTime() - from) }
            return try call()
        }
        do {
            try timed(begin)
            var tick = 1
            while true {
                let due = t0 + Double(tick) / 60
                let wait = due - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } else { await Task.yield() }
                let elapsed = CACurrentMediaTime() - t0
                let progress = min(1, elapsed / seconds)
                try timed { try step(progress) }
                if progress >= 1 { break }
                tick = max(tick + 1, Int((elapsed * 60).rounded(.up)))
            }
            detail = try timed(end)
        } catch let f as Failure {
            failure = f.detail
            detail = (try? end()) ?? ""
        } catch {
            failure = "\(error)"
        }
        let t1 = CACurrentMediaTime()
        let shown = await FrameClock.shared.frame(after: t1)
        let window = watchdog.end()
        let frames = FrameClock.shared.stopRecording()
        if failure == nil, let said = banner(since: reportBefore) { failure = said }
        let times = FeatureTest.frameTimes(began: frames.began, presented: frames.presented)
        return Measured(stall: max(window.stall, held), seconds: (shown ?? t1) - t0,
                        frames: FeatureTest.frameStats(times), peak: window.peak,
                        detail: detail + String(format: "; its longest call %.0f ms", held * 1000)
                            + Self.encodeNote(frames.encoding)
                            + (frames.began.count < 3 ? "; the 3D View drew no frames"
                                          : times == frames.presented ? "; frame times as presented"
                                          : "; frame times as drawn"),
                        failure: failure)
    }

    /// What the 3D View's own frames cost the main thread while they were
    /// recorded: a slow drag whose calls are short is slow in the drawing.
    private static func encodeNote(_ encoding: [CFTimeInterval]) -> String {
        guard !encoding.isEmpty else { return "" }
        let sorted = encoding.sorted()
        return String(format: "; a frame's encoding %.1f ms median, %.1f ms worst",
                      sorted[sorted.count / 2] * 1000, sorted.last! * 1000)
    }

    // MARK: Helpers

    /// The 3D View's camera (`FeatureTestLayoutDoor.camera`).
    private var view3D: ViewportCamera {
        get { FeatureTestDoor.layout?.camera() ?? ViewportCamera() }
        set { FeatureTestDoor.layout?.setCamera(newValue) }
    }

    /// The 3D View on screen, whose gesture handler the taps, drags and
    /// strokes go through.
    private func viewport() throws -> (MetalViewportView.Coordinator, MTKView) {
        guard let c = MetalViewportView.Coordinator.onScreen, let view = c.view else {
            throw Failure(detail: "no 3D View with Blender on screen")
        }
        return (c, view)
    }

    private func door() throws -> FeatureTestLayoutDoor {
        guard let door = FeatureTestDoor.layout else { throw Failure(detail: "the Layout tab is not on screen") }
        return door
    }

    /// Until the Layout tab's 3D View is on screen with its functions handed
    /// over; false after three seconds.
    @discardableResult
    private func waitForLayout() async -> Bool {
        for _ in 0..<60 {
            if FeatureTestDoor.layout != nil, MetalViewportView.Coordinator.onScreen != nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// The outcome's error as a failure.
    @discardableResult
    private func need(_ outcome: BpyBridge.Outcome, _ what: String = "") throws -> BpyBridge.Outcome {
        guard outcome.succeeded else {
            throw Failure(detail: (what.isEmpty ? "" : what + ": ") + BpyBridge.readable(outcome.error ?? "failed"))
        }
        return outcome
    }

    private func object(_ key: String) -> BKObject? {
        names[key].flatMap { name in scene.objects.first { $0.name == name } }
    }

    private func verts(_ obj: BKObject?) -> String {
        guard let obj else { return "nothing" }
        return "\(obj.name), \(FeatureTest.number(obj.mesh.vertices.count)) vertices drawn"
    }

    /// A tap on the object in the Outliner, which makes it alone selected and
    /// active.
    private func selectOnly(_ name: String) throws {
        try need(bridge.run(Bpy.objectSelection([name], active: name), undo: nil), "selecting \(name)")
    }

    /// Out of Edit Mode, Sculpt Mode and the paint modes, as the mode menu's
    /// Object Mode row leaves each.
    private func objectMode() throws {
        switch scene.mode {
        case .object: break
        case .edit: try need(bridge.run(Bpy.setMode(.object), undo: UndoStep.editMode), "leaving Edit Mode")
        default: try door().choose(.select)
        }
        if let door = FeatureTestDoor.layout, door.tool() != .select { door.choose(.select) }
    }

    /// The toolbar's tool, and the 3D View told at once (its next update
    /// would tell it too).
    private func tool(_ t: ActiveTool) throws {
        try door().choose(t)
        try viewport().0.parent.tool = t
    }

    /// The large sphere, made if a feature before did not make it.
    private func sphere() throws -> BKObject {
        if let found = object("sphere") { return found }
        try objectMode()
        try need(bridge.perform(LastOperator.add(.uvSphere, at: scene.cursor)), "Add UV Sphere")
        guard var op = bridge.adjustable else { throw Failure(detail: "Add UV Sphere left no redo panel") }
        op["segments"] = Double(FeatureTest.sphereSegments)
        op["ring_count"] = Double(FeatureTest.sphereRings)
        guard bridge.readjust(op) != nil, let made = scene.active else {
            throw Failure(detail: "the redo panel did not make the large sphere")
        }
        names["sphere"] = made.name
        return made
    }

    /// The large sphere alone selected, in Object Mode, framed.
    private func onSphere() throws -> BKObject {
        try objectMode()
        let s = try sphere()
        try selectOnly(s.name)
        view3D.frameSelected(in: scene)
        return s
    }

    /// A cube of its own at `location`, kept under `key`.
    private func cube(_ key: String, at location: SIMD3<Float>) throws -> BKObject {
        if let found = object(key) { return found }
        try objectMode()
        try need(bridge.perform(LastOperator.add(.cube, at: location)), "Add Cube")
        guard let made = scene.active else { throw Failure(detail: "Add Cube made nothing") }
        names[key] = made.name
        return made
    }

    /// The cube the Edit Mode features work on, in Edit Mode.
    private func editing(_ key: String = "work", at location: SIMD3<Float> = SIMD3(-5, 0, 0)) throws -> BKObject {
        if let obj = object(key), scene.mode == .edit, scene.active === obj { return obj }
        let obj = try cube(key, at: location)
        try objectMode()
        try selectOnly(obj.name)
        view3D.frameSelected(in: scene)
        try need(bridge.run(Bpy.setMode(.edit), undo: UndoStep.editMode), "Edit Mode")
        return obj
    }

    /// A Select menu row, as `LayoutWorkspace.select` sends it.
    @discardableResult
    private func selectRow(_ token: String) throws -> BpyBridge.Outcome {
        guard let command = SelectMenu.Command(token: token) else { throw Failure(detail: "no Select row \(token)") }
        let c = view3D
        let view = SelectMenu.ViewDirection(forward: simd_normalize(c.target - c.eye), up: c.trueUp)
        switch command.action(editing: scene.mode == .edit, view: view, selectMode: scene.selectMode) {
        case .run(let python, let undo): return try need(bridge.run(python, undo: undo))
        case .perform(let op): return try need(bridge.perform(op))
        }
    }

    /// A Mesh menu row, as the menu sends it.
    private func meshRow(_ op: LastOperator.Mesh) throws -> String {
        let c = view3D
        let pointer = MeshPointer(eye: c.eye, forward: simd_normalize(c.target - c.eye), up: c.trueUp,
                                  orthographic: c.isOrthographic, cursor: scene.cursor)
        let before = scene.active?.mesh.vertices.count ?? 0
        try need(bridge.perform(LastOperator.mesh(op, spinningAround: scene.active?.location,
                                                  symmetry: scene.active?.symmetry, pointer: pointer)))
        return "\(scene.active?.name ?? "?"): \(FeatureTest.number(before)) -> "
            + "\(FeatureTest.number(scene.active?.mesh.vertices.count ?? 0)) vertices drawn"
    }

    /// Where a point of the scene is in the 3D View, in its points.
    private func project(_ world: SIMD3<Float>) throws -> CGPoint {
        let (c, view) = try viewport()
        guard let p = TransformGizmo.Projection(camera: c.parent.camera, size: view.bounds.size).project(world)
        else { throw Failure(detail: "the point is behind the view") }
        return p
    }

    /// The object's world-space point at `local`.
    private func world(_ obj: BKObject, _ local: SIMD3<Float>) -> SIMD3<Float> {
        let p = obj.modelMatrix * SIMD4(local, 1)
        return SIMD3(p.x, p.y, p.z) / p.w
    }

    /// A stroke across the middle of the view, through the gesture handler's
    /// own calls (`sculptDrag`), for Sculpt Mode, Weight Paint and Vertex
    /// Paint.
    private func stroke(_ what: String) async throws -> Measured {
        let (c, view) = try viewport()
        let b = view.bounds
        let span = min(b.width, b.height) * 0.22
        let from = CGPoint(x: b.midX - span, y: b.midY - span * 0.25)
        let to = CGPoint(x: b.midX + span, y: b.midY + span * 0.25)
        func at(_ p: Double) -> CGPoint {
            // Across and back down a little, as a hand moves.
            CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p + sin(p * .pi) * span * 0.3)
        }
        let owner = ObjectIdentifier(self)
        return await continuous(begin: {
            guard c.sculptDrag(.began(touchedDown: from), at: from, pressure: 1, owner: owner, in: view),
                  c.sculptInput.isStroking else {
                throw Failure(detail: "the stroke did not start" + (bridge.report.map { ": \($0.message)" } ?? ""))
            }
        }, step: { p in
            _ = c.sculptDrag(p >= 1 ? .ended : .changed, at: at(p), pressure: 1, owner: owner, in: view)
        }, end: {
            let chunks = c.sculptInput.wallMs
            let median = chunks.isEmpty ? 0 : chunks.sorted()[chunks.count / 2]
            guard let end = c.sculptInput.lastEnd, end.dabs > 0 else {
                throw Failure(detail: "\(what): Blender laid no dab"
                              + (c.sculptInput.lastEnd?.refused.map { " (\($0))" } ?? ""))
            }
            return "\(what) on \(verts(scene.active)): \(end.dabs) dabs in \(chunks.count) chunks, a chunk's call "
                + String(format: "%.0f ms median, %.0f ms worst; the lift %.0f ms",
                         median, chunks.max() ?? 0, c.sculptInput.endMs)
        })
    }

    /// Ends whatever a failed feature left open: a stroke, a drag of points
    /// or a constrained drag.
    private func closeGestures() {
        if let (c, view) = try? viewport() {
            if c.sculptInput.owner != nil {
                _ = c.sculptDrag(.cancelled, at: .zero, pressure: 1, owner: ObjectIdentifier(self), in: view)
            }
            if scene.mode == .texturePaint { c.featureTexturePaint(.cancelled, at: .zero) }
        }
        if session.sculptStrokeOpen { _ = bridge.sculptEnd() }
        if session.pointDragOpen { bridge.cancelPointDrag() }
        if session.constrainedDragOpen { bridge.endConstrainedDrag() }
    }

    /// Until a script or a render on the script thread has ended; whether
    /// `progress` was seen meanwhile.
    private func untilIdle(progress: () -> Bool = { false }, limit: TimeInterval = 600) async -> Bool {
        let started = CACurrentMediaTime()
        var seen = false
        while session.isRunning && CACurrentMediaTime() - started < limit {
            if progress() { seen = true }
            _ = await FrameClock.shared.frame(after: CACurrentMediaTime(), timeout: 0.1)
        }
        return seen || progress()
    }

    /// A picture to hand Add ▸ Image and Image to 3D: a lit disc on white,
    /// made here, so the test reads no file of the user's.
    private func picture(size: CGFloat = 384) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let colours = [UIColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1).cgColor,
                           UIColor(red: 0.5, green: 0.15, blue: 0.05, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1])!
            let disc = CGRect(x: size * 0.18, y: size * 0.18, width: size * 0.64, height: size * 0.64)
            context.cgContext.addEllipse(in: disc)
            context.cgContext.clip()
            context.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: size * 0.4, y: size * 0.4),
                                                 startRadius: 0, endCenter: CGPoint(x: size / 2, y: size / 2),
                                                 endRadius: size * 0.34, options: [.drawsAfterEndLocation])
        }
    }

    /// The copies Add ▸ Image ▸ Reference kept of the test's picture
    /// (`ReferenceImages.store`), whose scratch scene is gone: made since the
    /// run began, under the name the test gave its picture.
    private func removePictures(since start: Date) {
        let folder = ReferenceImages.folder
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in files where url.lastPathComponent.hasPrefix("Test All Features") {
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if made >= start.addingTimeInterval(-1) { discard(url) }
        }
    }

    /// Removes a file the test made in the temporary folder.
    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: The features

    /// One feature, by its inventory key: what its control calls, measured.
    /// tests/featuretest holds every key that runs to a case here.
    private func perform(_ entry: FeatureTest.Entry) async throws -> Measured {
        switch entry.key {
        case "workspace.scripting":
            return await command {
                // The top bar's tab.
                workspace.wrappedValue = .scripting
                return "the Scripting tab's first frame"
            }
        case "workspace.layout":
            let m = await command {
                workspace.wrappedValue = .layout
                return "the Layout tab's 3D View's first frame"
            }
            guard await waitForLayout() else { throw Failure(detail: "the Layout tab's 3D View did not come back") }
            return m

        case "file.new":
            try objectMode()
            return await command {
                // File ▸ New ▸ General (`FileMenu.newScene`).
                try need(bridge.run(Bpy.newScene))
                names = [:]
                return "Blender's startup file: " + scene.objects.map(\.name).joined(separator: ", ")
            }

        case let key where key.hasPrefix("add.") && PrimitiveKind(rawValue: String(key.dropFirst(4))) != nil:
            let kind = PrimitiveKind(rawValue: String(key.dropFirst(4)))!
            try objectMode()
            return await command {
                // The Add menu's row.
                try need(bridge.perform(LastOperator.add(kind, at: scene.cursor)))
                return verts(scene.active)
            }
        case "add.curve", "add.text", "add.empty", "add.light", "add.camera", "add.lattice":
            let addition: ObjectAddition = ["add.curve": .curve(.bezier), "add.text": .text,
                                            "add.empty": .empty(.plainAxes), "add.light": .light(.point),
                                            "add.camera": .camera, "add.lattice": .lattice][entry.key]!
            try objectMode()
            return await command {
                try need(bridge.add(addition, at: scene.cursor, view: view3D))
                return "\(scene.active?.name ?? "?") (\(scene.active?.blenderType ?? "?"))"
            }
        case "add.reference":
            try objectMode()
            let data = picture()
            return await command {
                // Add ▸ Image ▸ Reference, with the picture the picker hands over.
                try need(bridge.addReferenceImage(.reference, data: data, name: "Test All Features.png",
                                                  at: scene.cursor, view: view3D))
                return "\(scene.active?.name ?? "?"), a \(data.count / 1024) KB picture"
            }
        case "select.all_objects":
            try objectMode()
            return await command {
                try selectRow("all")
                return "\(scene.selection.count) of \(scene.objects.count) objects selected"
            }
        case "object.delete":
            try objectMode()
            if scene.selection.isEmpty { try selectRow("all") }
            let count = scene.selection.count
            return await command {
                // Object ▸ Delete (`LayoutWorkspace.deleteSelected`).
                try need(bridge.run(Bpy.deleteSelection(editing: false, mode: scene.selectMode), undo: UndoStep.delete))
                return "\(count) objects deleted; \(scene.objects.count) left"
            }

        case "redo.uv_sphere":
            try objectMode()
            try need(bridge.perform(LastOperator.add(.uvSphere, at: scene.cursor)), "Add UV Sphere")
            guard var op = bridge.adjustable else { throw Failure(detail: "Add UV Sphere left no redo panel") }
            op["segments"] = Double(FeatureTest.sphereSegments)
            op["ring_count"] = Double(FeatureTest.sphereRings)
            return await command {
                // A typed value in the redo panel (`AdjustLastOperation`).
                guard bridge.readjust(op) != nil, let made = scene.active else {
                    throw Failure(detail: "the redo panel's change was refused")
                }
                names["sphere"] = made.name
                return "Segments \(FeatureTest.sphereSegments), Rings \(FeatureTest.sphereRings): " + verts(made)
            }

        case "view.frame_all":
            _ = try sphere()
            return await command {
                view3D.frameAll(scene.objects)
                return "\(scene.objects.count) objects framed"
            }
        case "view.orbit":
            _ = try onSphere()
            let (coordinator, _) = try viewport()
            var last = 0.0
            return await continuous(begin: {}, step: { p in
                // A finger across 360 points and down 120, through the
                // camera drag `handleOrbit` makes.
                let dx = Float((p - last) * 360), dy = Float((p - last) * 120)
                last = p
                coordinator.moveCamera(.orbit, readout: MetalViewportView.Coordinator.orbitReadout) {
                    $0.orbit(dx: dx * 0.008, dy: dy * 0.008)
                }
            }, end: {
                coordinator.endCameraMove(.orbit)
                return "around \(verts(object("sphere")))"
            })
        case "view.pan":
            _ = try onSphere()
            let (coordinator, _) = try viewport()
            var last = 0.0
            return await continuous(begin: {}, step: { p in
                let dx = Float((p - last) * 240), dy = Float((p - last) * -90)
                last = p
                coordinator.moveCamera(.pan, readout: { _ in "Pan" }) { $0.pan(dx: dx, dy: dy) }
            }, end: {
                coordinator.endCameraMove(.pan)
                view3D.frameSelected(in: scene)
                return "across \(verts(object("sphere")))"
            })
        case "view.zoom":
            _ = try onSphere()
            let (coordinator, _) = try viewport()
            let start = view3D.distance
            return await continuous(begin: {}, step: { p in
                // Fingers apart to twice their distance, and back, as
                // `handlePinch` turns them.
                let scale = Float(1 + sin(p * .pi))
                let distance = min(max(start / scale, 0.4), 500)
                coordinator.moveCamera(.zoom, readout: MetalViewportView.Coordinator.zoomReadout) {
                    $0.distance = distance
                }
            }, end: {
                coordinator.endCameraMove(.zoom)
                return "in to half the distance and out, on \(verts(object("sphere")))"
            })
        case "view.wireframe", "view.material", "view.solid":
            let shading: ViewportShading = ["view.wireframe": .wireframe, "view.material": .material,
                                            "view.solid": .solid][entry.key]!
            _ = try sphere()
            let door = try door()
            return await command {
                // The Viewport Shading menu's row.
                door.setShading(shading)
                return "the 3D View in \(shading)"
            }
        case "view.xray":
            let door = try door()
            let m = await command {
                door.setXRay(true)
                return "X-Ray on"
            }
            door.setXRay(false)
            return m
        case "view.perspective":
            let m = await command {
                view3D.isOrthographic.toggle()
                return view3D.isOrthographic ? "orthographic" : "perspective"
            }
            view3D.isOrthographic = false
            return m

        case "select.tap_object":
            let s = try onSphere()
            try tool(.select)
            try need(bridge.run(Bpy.deselectAll(editing: false), undo: SelectMenu.selectAllUndo))
            await settle()
            let (c, _) = try viewport()
            let point = try project(world(s, .zero))
            return await command {
                c.tap(at: point, modifiers: [])
                guard scene.active?.name == s.name, scene.selection.contains(s.id) else {
                    throw Failure(detail: "the tap at (\(Int(point.x)), \(Int(point.y))) did not select \(s.name)")
                }
                return "\(s.name) selected"
            }
        case "tool.move", "tool.rotate", "tool.scale":
            let s = try onSphere()
            let (t, mode, amount): (ActiveTool, TransformGizmo.Mode, Float) =
                entry.key == "tool.move" ? (.move, .translate, 1.0)
                : entry.key == "tool.rotate" ? (.rotate, .rotate, 30) : (.scale, .scale, 1.25)
            try tool(t)
            await settle()
            let (c, _) = try viewport()
            let generation = bridge.adjustableGeneration
            var points: (from: CGPoint, to: CGPoint)?
            return await continuous(seconds: 1.0, begin: {
                points = c.featureGizmoBegin(mode: mode, handle: .axis(0), amount: amount)
                guard points != nil else { throw Failure(detail: "no gizmo to drag on \(s.name)") }
            }, step: { p in
                guard let points else { return }
                c.featureGizmoMove(to: CGPoint(x: points.from.x + (points.to.x - points.from.x) * p,
                                               y: points.from.y + (points.to.y - points.from.y) * p))
            }, end: {
                guard c.featureGizmoEnd() else { throw Failure(detail: "the drag gave nothing to commit") }
                guard bridge.adjustableGeneration != generation, let op = bridge.adjustable else {
                    throw Failure(detail: "the commit left no redo panel: "
                                  + (bridge.lastOutcome?.error ?? "no outcome"))
                }
                return "\(op.name) of \(verts(s)), committed as one step"
            })

        case "edit.undo", "edit.redo":
            try objectMode()
            let undoing = entry.key == "edit.undo"
            guard undoing ? session.backendCanUndo : session.backendCanRedo else {
                throw Failure(detail: undoing ? "nothing to undo" : "nothing to redo")
            }
            let label = undoing ? session.backendHistory.undoLabel : session.backendHistory.redoLabel
            return await command {
                // The top bar's buttons.
                if undoing { session.performUndo() } else { session.performRedo() }
                return "\(undoing ? "Undo" : "Redo") \(label), with \(verts(object("sphere"))) in the scene; "
                    + "the history kept by \(session.backendHistory.mode)"
            }

        case "properties.location":
            let s = try onSphere()
            let drag = TransformFieldDrag()
            let value = s.location.x + 0.5
            return await command {
                // The field's typed value, then the commit (`ObjectTransformFields`).
                drag.change(.location, axis: 0, to: value, of: s, in: scene, bridge: bridge)
                guard let outcome = drag.commit(.location, bridge: bridge) else {
                    throw Failure(detail: "nothing to commit")
                }
                try need(outcome)
                return String(format: "%@'s Location X to %.2f m", s.name, value)
            }
        case "object.shade_smooth", "object.shade_flat":
            let smooth = entry.key == "object.shade_smooth"
            let s = try onSphere()
            return await command {
                try need(bridge.run(smooth ? Bpy.shadeSmooth : Bpy.shadeFlat,
                                    undo: smooth ? UndoStep.shadeSmooth : UndoStep.shadeFlat))
                return verts(s)
            }
        case "object.shade_auto_smooth":
            let s = try onSphere()
            session.probeEssentialsLibrary()
            guard session.essentialsLibrary == true else {
                throw Skip(reason: "greyed out: this build's Blender has no Essentials library, which it takes "
                           + "its node group from")
            }
            return await command {
                try need(bridge.perform(LastOperator.shadeAutoSmooth()))
                return verts(s)
            }
        case "object.duplicate":
            let s = try onSphere()
            let m = await command {
                // Object ▸ Duplicate Objects, in Object Mode (`duplicateSelected`).
                try need(bridge.run(Bpy.duplicate, undo: UndoStep.duplicateObjects))
                return "\(s.name) copied: \(verts(scene.active))"
            }
            if scene.active?.name != s.name {
                try? need(bridge.run(Bpy.deleteSelection(editing: false, mode: scene.selectMode), undo: UndoStep.delete))
            }
            return m
        case "object.set_origin":
            let s = try onSphere()
            return await command {
                try need(bridge.setOrigin(Bpy.OriginChoice(.originToGeometry)))
                return s.name
            }
        case "object.apply_scale":
            let s = try onSphere()
            return await command {
                try need(bridge.applyTransform(.scale))
                return String(format: "%@ at scale %.2f, applied", s.name, s.scale.x)
            }
        case "object.hide", "object.reveal":
            let what: Bpy.ShowHide = entry.key == "object.hide" ? .hideSelected : .reveal
            let s = try onSphere()
            return await command {
                try need(bridge.run(Bpy.showHide(what, editing: false), undo: what.undoName(editing: false)))
                return "\(what.label(editing: false)): \(s.name)"
            }
        case "view.local_view":
            let s = try onSphere()
            let m = await command {
                try need(bridge.run(LocalViewBpy.toggle))
                return "\(s.name) alone in Local View"
            }
            if scene.localView != nil { try? need(bridge.run(LocalViewBpy.toggle)) }
            return m
        case "object.snap_cursor":
            let s = try onSphere()
            let m = await command {
                try need(bridge.run(ToolsBpy.snap(.cursorToSelection, increment: 0.25),
                                    undo: SnapAction.cursorToSelection.undoName))
                return String(format: "the 3D cursor to %@ (%.2f, %.2f, %.2f)", s.name,
                              scene.cursor.x, scene.cursor.y, scene.cursor.z)
            }
            try? need(bridge.run(ToolsBpy.snap(.cursorToCenter, increment: 0.25), undo: SnapAction.cursorToCenter.undoName))
            return m
        case "tool.cursor":
            let s = try onSphere()
            try tool(.cursor)
            await settle()
            let (c, view) = try viewport()
            let point = try project(world(s, .zero))
            let m = await command {
                guard c.cursorTap(at: point, size: view.bounds.size) else {
                    throw Failure(detail: "the tap placed nothing")
                }
                return String(format: "the 3D cursor on %@'s surface at (%.2f, %.2f, %.2f)", s.name,
                              scene.cursor.x, scene.cursor.y, scene.cursor.z)
            }
            try? need(bridge.run(ToolsBpy.snap(.cursorToCenter, increment: 0.25), undo: SnapAction.cursorToCenter.undoName))
            try tool(.select)
            return m
        case "tool.measure":
            let s = try onSphere()
            try tool(.measure)
            await settle()
            let (c, view) = try viewport()
            let a = try project(world(s, SIMD3(-1, 0, 0))), b = try project(world(s, SIMD3(1, 0, 0)))
            let m = await continuous(seconds: 0.75, begin: {
                guard c.beginRulerDrag(at: a, size: view.bounds.size, modifiers: []) else {
                    throw Failure(detail: "the drag made no ruler")
                }
            }, step: { p in
                c.updateRulerDrag(to: CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p), modifiers: [])
            }, end: {
                c.endRulerDrag()
                guard !scene.rulers.isEmpty else { throw Failure(detail: "no ruler was kept") }
                return "a ruler across \(s.name)"
            })
            MeasureActions.remove(scene)
            try tool(.select)
            return m

        case "object.parent":
            let s = try onSphere()
            let child = try cube("child", at: SIMD3(3, 0, 0))
            try need(bridge.run(Bpy.objectSelection([child.name, s.name], active: s.name), undo: nil))
            return await command {
                try need(bridge.perform(LastOperator.parent(keepTransform: false)))
                return "\(child.name) parented to \(s.name)"
            }
        case "object.clear_parent":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            try objectMode()
            try selectOnly(child.name)
            return await command {
                try need(bridge.perform(LastOperator.clearParent(.clear)))
                return "\(child.name)'s parent cleared"
            }
        case "object.join":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            let other = try cube("joined", at: SIMD3(3, 3, 0))
            try objectMode()
            try need(bridge.run(Bpy.objectSelection([other.name, child.name], active: child.name), undo: nil))
            return await command {
                try need(bridge.perform(LastOperator.join()))
                names["joined"] = nil
                return "\(other.name) joined into \(verts(scene.active))"
            }
        case "object.convert":
            try objectMode()
            try need(bridge.add(.text, at: SIMD3(0, -3, 0), view: view3D), "Add Text")
            guard let text = scene.active else { throw Failure(detail: "Add Text made nothing") }
            return await command {
                try need(bridge.perform(LastOperator.convert(to: .mesh)))
                return "\(text.name) to a mesh: \(verts(scene.active))"
            }
        case "object.move_to_collection":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            try objectMode()
            try selectOnly(child.name)
            guard let root = scene.collections?.sceneCollection else { throw Failure(detail: "no collections read") }
            return await command {
                try need(bridge.run(CollectionsBpy.move(to: root.uid, link: false, newCollection: "Test Collection")))
                return "\(child.name) into a new collection; \(scene.collections?.entries.count ?? 0) collections"
            }

        case "outliner.select":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            try objectMode()
            return await command {
                try need(bridge.select(Bpy.select(child.name)))
                return "\(child.name) selected"
            }
        case "outliner.hide":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            let m = await command {
                try need(bridge.run(Bpy.setHidden(child.name, true), undo: "Hide in Viewport"))
                return "\(child.name) hidden"
            }
            try? need(bridge.run(Bpy.setHidden(child.name, false), undo: "Hide in Viewport"))
            return m
        case "outliner.rename":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            return await command {
                try need(bridge.run(Bpy.rename(child.name, to: "Test Cube"), undo: "Rename"))
                names["child"] = scene.objects.first { $0.name.hasPrefix("Test Cube") }?.name
                return "\(names["child"] ?? "?")"
            }

        case "properties.material":
            let s = try onSphere()
            return await command {
                try need(bridge.run([Bpy.setMaterial(s.name, baseColor: SIMD4(0.8, 0.35, 0.2, 1),
                                                     metallic: 0, roughness: 0.5)], undo: "Set Material"))
                return "\(s.name)'s Base Color"
            }
        case "modifier.add":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            try objectMode()
            try selectOnly(child.name)
            guard let row = ModifierCatalog.rows(for: child.blenderType).first(where: { $0.type == "SUBSURF" }) else {
                throw Failure(detail: "Add Modifier offers no Subdivision Surface on \(child.name)")
            }
            return await command {
                try need(bridge.run(Bpy.addModifierRow(row, on: child.mesh), undo: UndoStep.addModifier))
                return "\(row.label) on \(verts(child))"
            }
        case "modifier.edit":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            guard let m = child.modifiers.first(where: { $0.blenderType == "SUBSURF" }) else {
                throw Failure(detail: "no Subdivision Surface row on \(child.name)")
            }
            var changed = m
            changed.levels = 3
            return await command {
                try need(bridge.run(Bpy.modifierEdit(from: m, to: changed), undo: "Edit Modifier"))
                return "Levels Viewport \(m.levels) to 3: \(verts(child))"
            }
        case "modifier.apply":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            guard let m = child.modifiers.first(where: { $0.blenderType == "SUBSURF" }),
                  let apply = ModifierRowAction.apply.command(for: m, in: child.modifiers) else {
                throw Failure(detail: "no Subdivision Surface row to apply on \(child.name)")
            }
            return await command {
                try need(bridge.run(apply.lines, undo: apply.undo))
                return "\(m.name) applied: \(verts(child))"
            }
        case "constraint.add":
            let child = try cube("child", at: SIMD3(3, 0, 0))
            return await command {
                try need(bridge.run(ConstraintsBpy.add("COPY_LOCATION", to: child.name)))
                return "Copy Location on \(child.name)"
            }
        case "camera.lens":
            try objectMode()
            if object("camera") == nil {
                // The Render panel's own Add Camera: aimed as the view looks.
                try need(bridge.add(.camera, at: view3D.eye, view: view3D), "Add Camera")
                names["camera"] = scene.active?.name
            }
            guard let cam = object("camera") else { throw Failure(detail: "no camera") }
            if scene.sceneCamera == nil { try need(bridge.run(Bpy.setSceneCamera(cam.name), undo: "Set Active Object as Camera")) }
            return await command {
                try need(bridge.run(Bpy.setObjectData(cam.name, "lens", 35), undo: "Focal Length"))
                return "\(cam.name)'s Focal Length to 35 mm"
            }
        case "light.power":
            try objectMode()
            if object("light") == nil {
                try need(bridge.add(.light(.point), at: SIMD3(4, -4, 6), view: nil), "Add Light")
                names["light"] = scene.active?.name
            }
            guard let light = object("light") else { throw Failure(detail: "no light") }
            return await command {
                try need(bridge.run(Bpy.setObjectData(light.name, "energy", 1000), undo: "Power"))
                return "\(light.name)'s Power to 1000 W"
            }

        case "mode.edit_large":
            let s = try onSphere()
            return await command {
                // The header's Edit Mode (`setEditing(true)`).
                try need(bridge.run(Bpy.setMode(.edit), undo: UndoStep.editMode))
                guard scene.mode == .edit else { throw Failure(detail: "Blender stayed in \(scene.mode.label)") }
                return verts(s)
            }
        case "mode.object_large":
            let s = try sphere()
            if scene.mode != .edit || scene.active !== s {
                try objectMode()
                try selectOnly(s.name)
                try need(bridge.run(Bpy.setMode(.edit), undo: UndoStep.editMode))
            }
            return await command {
                try need(bridge.run(Bpy.setMode(.object), undo: UndoStep.editMode))
                return verts(s)
            }
        case "edit.select_edge", "edit.select_face", "edit.select_vertex":
            let mode: MeshSelectMode = ["edit.select_edge": .edge, "edit.select_face": .face,
                                        "edit.select_vertex": .vertex][entry.key]!
            let obj = try editing()
            if scene.selectMode == mode {
                let other: MeshSelectMode = mode == .vertex ? .edge : .vertex
                try need(bridge.run(Bpy.setSelectMode(other)))
                scene.selectMode = other
            }
            return await command {
                // The header's Vertex, Edge and Face buttons (`setSelectMode`).
                try need(bridge.run(Bpy.setSelectMode(mode)))
                scene.selectMode = mode
                return "\(mode) select on \(verts(obj))"
            }
        case "select.all_elements", "select.none", "select.invert":
            let token = ["select.all_elements": "all", "select.none": "none", "select.invert": "invert"][entry.key]!
            let obj = try editing()
            return await command {
                try selectRow(token)
                return verts(obj)
            }
        case "mesh.subdivide", "mesh.extrude", "mesh.inset", "mesh.bevel", "mesh.merge_by_distance":
            let op: LastOperator.Mesh = ["mesh.subdivide": .subdivide, "mesh.extrude": .extrude, "mesh.inset": .inset,
                                         "mesh.bevel": .bevel, "mesh.merge_by_distance": .mergeByDistance][entry.key]!
            _ = try editing()
            if entry.key == "mesh.subdivide" || entry.key == "mesh.merge_by_distance" { try selectRow("all") }
            return await command { try meshRow(op) }
        case "select.tap_vertex":
            let obj = try editing()
            try tool(.select)
            await settle()
            let (c, _) = try viewport()
            let eye = view3D.eye
            guard let nearest = obj.mesh.vertices.map({ world(obj, $0.position) })
                .min(by: { simd_distance($0, eye) < simd_distance($1, eye) }) else {
                throw Failure(detail: "\(obj.name) has no vertices")
            }
            let point = try project(nearest)
            return await command {
                c.tap(at: point, modifiers: [])
                guard !scene.editSelection.isEmpty else {
                    throw Failure(detail: "the tap at (\(Int(point.x)), \(Int(point.y))) selected nothing")
                }
                return "\(scene.editSelection.vertices.count) vertex selected on \(obj.name)"
            }
        case "mesh.delete_vertices":
            _ = try editing()
            if scene.editSelection.isEmpty { throw Failure(detail: "nothing selected to delete") }
            return await command { try meshRow(.deleteVertices) }
        case "select.box":
            let obj = try editing()
            try tool(.boxSelect)
            await settle()
            let (c, view) = try viewport()
            let b = view.bounds
            let a = CGPoint(x: b.midX - b.width * 0.2, y: b.midY - b.height * 0.2)
            let z = CGPoint(x: b.midX + b.width * 0.2, y: b.midY + b.height * 0.2)
            let m = await continuous(seconds: 0.75, begin: {
                guard c.beginRegion(at: a, modifiers: []) else { throw Failure(detail: "the drag drew no box") }
            }, step: { p in
                c.extendRegion(to: CGPoint(x: a.x + (z.x - a.x) * p, y: a.y + (z.y - a.y) * p))
            }, end: {
                guard c.finishRegion(in: view) != nil else { throw Failure(detail: "the box selected nothing") }
                return "a box over the middle of \(verts(obj))"
            })
            try tool(.select)
            return m
        case "select.more", "select.linked":
            let obj = try editing()
            if scene.editSelection.isEmpty, scene.active?.mesh.vertices.isEmpty == false {
                try selectRow("all")
                try selectRow("invert")
            }
            return await command {
                try selectRow(entry.key == "select.more" ? "more" : "linked")
                return verts(obj)
            }
        case "tool.loop_cut", "tool.knife":
            let key = entry.key == "tool.loop_cut" ? "loopcut" : "knifecube"
            let obj = try editing(key, at: entry.key == "tool.loop_cut" ? SIMD3(0, 6, 0) : SIMD3(0, -6, 0))
            try tool(entry.key == "tool.loop_cut" ? .loopCut : .knife)
            await settle()
            let (c, view) = try viewport()
            let size = view.bounds.size
            let toEye = simd_normalize(view3D.eye - obj.location)
            if entry.key == "tool.loop_cut" {
                // The middle of the cube's edge that faces the view most.
                let mids: [SIMD3<Float>] = [SIMD3(1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, 1, 0), SIMD3(-1, -1, 0),
                                            SIMD3(1, 0, 1), SIMD3(1, 0, -1), SIMD3(-1, 0, 1), SIMD3(-1, 0, -1),
                                            SIMD3(0, 1, 1), SIMD3(0, 1, -1), SIMD3(0, -1, 1), SIMD3(0, -1, -1)]
                let mid = mids.max { simd_dot(simd_normalize($0), toEye) < simd_dot(simd_normalize($1), toEye) }!
                let point = try project(world(obj, mid))
                let before = obj.mesh.vertices.count
                let m = await command {
                    // A finger has no hover: its first tap shows the ring.
                    _ = c.loopCutTap(at: point, size: size)
                    guard let op = c.loopCutTap(at: point, size: size) else {
                        throw Failure(detail: "the second tap cut nothing"
                                      + (c.loopCutRefusal.map { ": \($0)" } ?? ""))
                    }
                    return "\(op.name) on \(obj.name): \(before) -> \(obj.mesh.vertices.count) vertices drawn"
                }
                try tool(.select)
                return m
            }
            // Across the face that faces the view most.
            let normals: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
                                           SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
            let n = normals.max { simd_dot($0, toEye) < simd_dot($1, toEye) }!
            let u: SIMD3<Float> = abs(n.x) > 0.5 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let p1 = try project(world(obj, n - u * 0.8)), p2 = try project(world(obj, n + u * 0.8))
            let before = obj.mesh.vertices.count
            let m = await command {
                guard c.knifeTap(at: p1, size: size), c.knifeTap(at: p2, size: size) else {
                    throw Failure(detail: "a tap was not taken")
                }
                guard let op = CutToolActions.knifeDone(scene: scene, camera: c.parent.camera, bridge: bridge) else {
                    throw Failure(detail: "Confirm cut nothing")
                }
                return "\(op.name) on \(obj.name): \(before) -> \(obj.mesh.vertices.count) vertices drawn"
            }
            try tool(.select)
            return m

        case "mode.vertex_paint", "mode.weight_paint":
            let mode: InteractionMode = entry.key == "mode.vertex_paint" ? .vertexPaint : .weightPaint
            let s = try onSphere()
            let door = try door()
            return await command {
                // The mode menu's row (`enterPaintMode`).
                door.enterPaintMode(mode)
                guard scene.mode == mode else { throw Failure(detail: "Blender stayed in \(scene.mode.label)") }
                return verts(s)
            }
        case "paint.vertex", "paint.weight":
            let mode: InteractionMode = entry.key == "paint.vertex" ? .vertexPaint : .weightPaint
            if scene.mode != mode { _ = try onSphere(); try door().enterPaintMode(mode) }
            guard scene.mode == mode else { throw Failure(detail: "not in \(mode.label)") }
            if scene.paintBlender == nil { scene.paintBlender = bridge.paintState() }
            await settle()
            let m = try await stroke(mode.label)
            try objectMode()
            return m
        case "mode.texture_paint":
            let s = try onSphere()
            let door = try door()
            let reportBefore = bridge.report?.id
            watchdog.begin()
            let t0 = CACurrentMediaTime()
            // The Paint row's Brush: Texture Paint, whose setup the 3D View
            // runs as the mode changes (`TexturePaintSetup.prepare`).
            door.choose(.paintDraw)
            var ready = s.paintTarget != nil
            while !ready && CACurrentMediaTime() - t0 < 30 {
                _ = await FrameClock.shared.frame(after: CACurrentMediaTime(), timeout: 0.2)
                ready = s.paintTarget != nil
            }
            let t1 = CACurrentMediaTime()
            let shown = await FrameClock.shared.frame(after: t1)
            let window = watchdog.end()
            let failure = !ready ? "no image to paint after 30 s (mode \(scene.mode.label))" : banner(since: reportBefore)
            return Measured(stall: window.stall, seconds: (shown ?? t1) - t0, peak: window.peak,
                            detail: "\(verts(s)): UVs and an image to paint", failure: failure)
        case "paint.texture":
            let s = try sphere()
            if scene.mode != .texturePaint {
                _ = try onSphere()
                try door().choose(.paintDraw)
                for _ in 0..<150 where s.paintTarget == nil {
                    _ = await FrameClock.shared.frame(after: CACurrentMediaTime(), timeout: 0.2)
                }
            }
            guard scene.mode == .texturePaint, s.paintTarget != nil else { throw Failure(detail: "no image to paint") }
            await settle()
            let (c, view) = try viewport()
            let b = view.bounds
            let span = min(b.width, b.height) * 0.22
            let from = CGPoint(x: b.midX - span, y: b.midY), to = CGPoint(x: b.midX + span, y: b.midY + span * 0.2)
            var texels = 0
            let m = await continuous(begin: {
                c.featureTexturePaint(.began(touchedDown: from), at: from)
            }, step: { p in
                let point = CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
                if p >= 1 { texels = c.texturePaintTexels }
                c.featureTexturePaint(p >= 1 ? .ended : .changed, at: point)
            }, end: {
                guard texels > 0 else { throw Failure(detail: "the stroke painted nothing") }
                return "\(FeatureTest.number(texels)) texels painted on \(s.name), kept in Blender at the lift"
            })
            try objectMode()
            return m

        case "mode.sculpt":
            let s = try onSphere()
            let door = try door()
            return await command {
                // The Sculpt menu's Sculpt Mode (`choose(.sculptDraw)`).
                door.choose(.sculptDraw)
                guard scene.mode == .sculpt else { throw Failure(detail: "Blender stayed in \(scene.mode.label)") }
                return verts(s)
            }
        case "sculpt.draw":
            if scene.mode != .sculpt { _ = try onSphere(); try door().choose(.sculptDraw) }
            guard scene.mode == .sculpt else { throw Failure(detail: "not in Sculpt Mode") }
            if scene.sculptBlender == nil { scene.sculptBlender = bridge.sculptState() }
            await settle()
            return try await stroke("Draw")
        case "sculpt.mask_fill":
            guard scene.mode == .sculpt else { throw Failure(detail: "not in Sculpt Mode") }
            let m = await command {
                try need(bridge.run(SculptBpy.mask(.fill), undo: SculptBpy.maskUndo))
                return verts(scene.active)
            }
            try? need(bridge.run(SculptBpy.mask(.clear), undo: SculptBpy.maskUndo))
            return m
        case "sculpt.voxel_remesh":
            guard scene.mode == .sculpt, let s = scene.active else { throw Failure(detail: "not in Sculpt Mode") }
            let before = s.mesh.vertices.count
            return await command {
                try need(bridge.run(SculptBpy.voxelRemesh, undo: SculptBpy.voxelRemeshUndo))
                return "\(s.name): \(FeatureTest.number(before)) -> \(FeatureTest.number(s.mesh.vertices.count)) vertices"
            }
        case "mode.object_from_sculpt":
            guard scene.mode == .sculpt else { throw Failure(detail: "not in Sculpt Mode") }
            let door = try door()
            return await command {
                door.choose(.select)
                guard scene.mode == .object else { throw Failure(detail: "Blender stayed in \(scene.mode.label)") }
                return "back in Object Mode"
            }

        case "anim.insert_keyframe":
            let s = try onSphere()
            let driver = timeline()
            driver.setFrame(1)
            let m = await command {
                // The Timeline's Insert Keyframe (and I).
                driver.insertKeyframe()
                try need(bridge.lastOutcome ?? BpyBridge.Outcome(python: "", succeeded: false, error: "no outcome",
                                                                  objectsBefore: 0, objectsAfter: 0))
                return "\(s.name) keyed at frame 1"
            }
            // A second key, two seconds on and two metres up, for Play.
            driver.setFrame(49)
            try? need(bridge.run(Bpy.translate(SIMD3(0, 0, 2)), undo: UndoStep.move))
            driver.insertKeyframe()
            driver.setFrame(1)
            return m
        case "anim.play":
            let s = try onSphere()
            let driver = timeline()
            let ticker = PlaybackTicker()
            let shown = scene.animation.showsTimeline
            scene.animation.showsTimeline = true
            driver.setFrame(1)
            await settle()
            var first = 0
            var m = await continuous(seconds: 2, begin: {
                first = scene.frameCurrent
                // The Play button: the driver's clock, and the display link
                // that asks it for a frame at every refresh.
                driver.play()
                ticker.start(driver)
            }, step: { _ in }, end: {
                driver.pause()
                ticker.stop()
                return "frames \(first) to \(scene.frameCurrent) with \(verts(s)) keyed"
            })
            scene.animation.showsTimeline = shown
            // Held to the scene's own frame rate, which Play keeps.
            m.pace = 1 / max(scene.animation.fps, 1)
            return m
        case "anim.scrub":
            let s = try onSphere()
            let driver = timeline()
            return await continuous(seconds: 1, begin: {}, step: { p in
                driver.scrub(to: 1 + Int((p * 48).rounded()))
            }, end: {
                driver.flushPendingFrame()
                return "frames 1 to 49 with \(verts(s)) keyed"
            })

        case "script.run":
            try objectMode()
            let source = "import bpy\nfor i in range(20):\n"
                + "    bpy.ops.mesh.primitive_cube_add(size=0.4, location=(i * 0.5 - 5, 8, 0))\n"
            return await long {
                // The Text Editor's Run Script (`ScriptingWorkspace.run`).
                session.runScript(source, scene: scene)
                let progress = await untilIdle(progress: { session.isRunning })
                if let error = session.lastRun?.error { throw Failure(detail: error) }
                return ("a 3-line script adding 20 cubes; " + (session.lastRun?.summary ?? ""), progress)
            }
        case "console.python", "console.shell":
            let line = entry.key == "console.python" ? "len(bpy.data.objects)" : "ls"
            let before = session.console.count
            // Timed to the console's answer: the line runs on the script
            // thread, and the prompt is busy until it has printed.
            // What the terminal is handed as the line runs, kept as well.
            let terminal = session.onConsoleOutput
            var printed = ""
            session.onConsoleOutput = { chunk in printed += chunk; terminal?(chunk) }
            defer { session.onConsoleOutput = terminal }
            return await long {
                // A line typed at the console's prompt, and Return.
                session.runConsole(line, scene: scene)
                let answer = await consoleAnswer(after: before)
                let shown = printed.split(separator: "\n").count
                return ("`\(line)`" + answer + (shown > 0 ? "; the terminal was handed \(shown) line"
                                                 + (shown == 1 ? "" : "s") : ""), true)
            }
        case "opsearch.run":
            try objectMode()
            return await command {
                // Operator Search's Run, on Add Cube with its defaults.
                try need(bridge.run(OperatorCatalogue.runCommand(path: "mesh.primitive_cube_add", json: "{}"),
                                    undo: "Add Cube"))
                return "mesh.primitive_cube_add: \(verts(scene.active))"
            }

        case "render.eevee", "render.cycles":
            let cyclesRender = entry.key == "render.cycles"
            try objectMode()
            if scene.sceneCamera == nil {
                try need(bridge.add(.camera, at: view3D.eye, view: view3D), "Add Camera")
            }
            let output = temporary.appendingPathComponent("feature-test-render.png")
            let progressFile = temporary.appendingPathComponent("feature-test-render-progress.txt")
            let device = temporary.appendingPathComponent("feature-test-render-device.txt")
            for url in [output, progressFile, device] { discard(url) }
            let size = cyclesRender ? (160, 90) : (480, 270)
            let request = RenderRequest(engine: cyclesRender ? .cycles : .eevee, quality: .draft,
                                        width: size.0, height: size.1, source: .sceneCamera, output: output.path,
                                        deviceReport: device.path, progressReport: progressFile.path)
            let m = await long {
                // The Render panel's Render (`RenderingWorkspace.render`).
                session.runScript(request.python, scene: scene)
                let progress = await untilIdle(progress: {
                    FileManager.default.fileExists(atPath: progressFile.path)
                })
                if let error = session.lastRun?.error { throw Failure(detail: error) }
                guard let bytes = try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int,
                      bytes > 0 else { throw Failure(detail: "no picture was written") }
                let used = (try? String(contentsOf: device, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                return ("\(request.engine.rawValue) \(size.0) × \(size.1) at Draft on \(used); "
                        + "\(bytes / 1024) KB written", progress)
            }
            for url in [output, progressFile, device] { discard(url) }
            return m

        case "image3d.relief":
            try objectMode()
            let data = picture(size: 512)
            return await long {
                // The sheet's Create, for Relief (`ImageToModelSheet.create`).
                let prepared = try await ImageToModelImport.prepare(data: data, fileName: "Test All Features.png")
                let made = try await ImageToModelImport.createRelief(prepared, cutOut: true,
                                                                    options: ImageToModel.Options(detail: 96),
                                                                    bridge: bridge, session: session, scene: scene)
                return ("\(made.name) from a \(prepared.image.width) × \(prepared.image.height) picture: "
                        + verts(scene.active), true)
            }

        case "file.pack":
            let before = session.console.count
            return await command {
                // File ▸ External Data ▸ Pack Resources.
                session.submit("bpy.ops.file.pack_all()", scene: scene)
                if let error = session.console.dropFirst(before).last(where: { $0.kind == .error }) {
                    throw Failure(detail: error.text)
                }
                return "\(scene.objects.count) objects; the images packed into the scene"
            }
        case "file.autosave":
            let url = temporary.appendingPathComponent("feature-test-autosave.blend")
            let m = await longSync {
                // What the app writes two seconds after the work pauses, and
                // as it goes to the background — here to a file of the test's.
                guard let written = session.capture(BackendHistoryPython.autosave(path: url.path)) else {
                    throw Failure(detail: "Blender could not write it")
                }
                return "\(fileSize(url)) written in \(written.split(separator: "\n").last ?? "?") ms"
            }
            discard(url)
            return m
        case "file.save":
            let url = temporary.appendingPathComponent("feature-test-save.blend")
            discard(url)
            return await longSync {
                // File ▸ Save (`FileMenu.save`), to the test's own file.
                session.saveDocument(url, scene: scene)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw Failure(detail: "nothing was written")
                }
                return "\(scene.objects.count) objects, \(fileSize(url))"
            }
        case "file.export":
            let url = temporary.appendingPathComponent("feature-test-export.glb")
            discard(url)
            return await longSync {
                // File ▸ Export ▸ glTF 2.0's row (`FileMenu.exportModel`).
                guard let made = session.exportModel("export_scene.gltf", ext: "glb", name: "feature-test-export",
                                                     in: temporary) else {
                    throw Failure(detail: "Blender wrote no file")
                }
                return "\(scene.objects.count) objects, \(fileSize(made))"
            }
        case "file.import":
            let url = temporary.appendingPathComponent("feature-test-export.glb")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure(detail: "no exported file to import")
            }
            let op = "import_scene.gltf"
            let before = scene.objects.count
            let m = await longSync {
                // File ▸ Import ▸ glTF 2.0's row (`FileMenu.importModel`).
                try need(bridge.run(BpySession.importPython(op, from: url.path), undo: BpySession.importUndo(op)))
                return "\(before) -> \(scene.objects.count) objects"
            }
            discard(url)
            return m
        case "file.open":
            let url = temporary.appendingPathComponent("feature-test-save.blend")
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(detail: "no saved file to open") }
            try objectMode()
            let before = session.console.count
            let m = await longSync {
                // File ▸ Open… with a .blend picked (`session.openDocument`).
                session.openDocument(url, scene: scene)
                if let error = session.console.dropFirst(before).last(where: { $0.kind == .error }) {
                    throw Failure(detail: error.text)
                }
                return "\(scene.objects.count) objects"
            }
            names = [:]
            discard(url)
            return m

        default:
            throw Failure(detail: "Test All Features has no step for \(entry.key)")
        }
    }

    /// A timeline driver bound as the Timeline's own is (`AnimationDock`).
    private var driver: TimelineDriver?
    private func timeline() -> TimelineDriver {
        if let driver { return driver }
        let made = TimelineDriver()
        made.bind(scene: scene, session: session, bridge: bridge)
        driver = made
        return made
    }

    /// What the console printed for a line, once it has finished.
    private func consoleAnswer(after before: Int) async -> String {
        _ = await untilIdle()
        let lines = session.console.dropFirst(before).filter { $0.kind != .input }.map(\.text)
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "; printed nothing"
        }
        return "; printed \(lines.count) line\(lines.count == 1 ? "" : "s"), the last \"\(last.prefix(60))\""
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return bytes >= 1_048_576 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(bytes / 1024) KB"
    }
}

#if DEBUG
/// DEBUG `-feature-test`: Preferences opened at launch, Test All Features
/// pressed, and its Run pressed; each result printed as it ends, and the
/// report's path at the end (`[bk-featuretest] ended: …`). For a Mac whose
/// screen cannot be clicked. Once per launch.
enum FeatureTestLaunch {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-feature-test") }
    /// `-feature-test-cycles` turns the Cycles switch on.
    static var cycles: Bool { ProcessInfo.processInfo.arguments.contains("-feature-test-cycles") }
    /// `-feature-test-only key,key,…`: run only these features (keys as in
    /// `FeatureTest.entries`); nil runs them all.
    static var only: Set<String>? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-feature-test-only"), i + 1 < args.count else { return nil }
        return Set(args[i + 1].split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
    }
    static var opened = false
    static var ran = false
}
#endif
