import UIKit
import MetalKit
import simd

/// A stroke with Blender's own sculpt brush, in progress in one viewport.
///
/// The points go to `bpy.ops.sculpt.brush_stroke` in chunks while the finger
/// moves (`BpyBridge.sculptChunk`), each one replaying the stroke so far as one
/// of Blender's strokes and mirroring the object back, so the 3D View shows
/// Blender's result as it happens and what is kept when the finger lifts is
/// what was shown. When a chunk goes is `SculptStreamPolicy`'s decision.
final class SculptStrokeInput {
    /// Touching Blender's brush: from touch down to lift.
    private(set) var isStroking = false
    /// The touch came down and Blender refused the stroke: the rest of the
    /// touch does nothing, rather than asking again on every move.
    private(set) var isRefused = false
    private var pending: [SculptPoint] = []
    private var policy = SculptStreamPolicy()
    private var started: CFTimeInterval = 0
    private weak var bridge: BpyBridge?
    /// What each chunk cost, for the log line when the stroke ends.
    private(set) var results: [SculptChunkResult] = []
    private(set) var wallMs: [Double] = []
    private(set) var lastEnd: SculptStrokeEnd?
    /// What ending the stroke cost: on a Multires level, where the stroke is
    /// made when it ends, Blender's stroke and the level read back.
    private(set) var endMs: Double = 0
    /// The drag that touched down in Sculpt Mode: it owns everything from
    /// touch down to lift, the stroke and whatever is left of the drag after
    /// the stroke ends. Nil between drags.
    var owner: ObjectIdentifier?

    deinit {
        // A view torn down under a stroke (its workspace closed) ends it, so
        // the session is not left holding every command for a stroke whose
        // lift will never come. What it made is kept, as one step.
        if isStroking, Thread.isMainThread { _ = bridge?.sculptEnd() }
        cursor?.removeFromSuperlayer()
    }

    /// Starts a stroke. False, with Blender's reason on the banner, when it
    /// refused.
    func begin(object: String, camera: ViewportCamera, viewSize: CGSize, mode: SculptStrokeMode,
               bridge: BpyBridge) -> Bool {
        results = []; wallMs = []; pending = []; lastEnd = nil
        policy = SculptStreamPolicy()
        started = CACurrentMediaTime()
        self.bridge = bridge
        let camera = SculptCamera(target: camera.target, distance: camera.distance,
                                  azimuth: camera.azimuth, elevation: camera.elevation,
                                  fovY: camera.fovY, orthographic: camera.isOrthographic,
                                  near: camera.near, far: camera.far)
        guard bridge.sculptBegin(object: object, camera: camera,
                                 viewWidth: Float(viewSize.width), viewHeight: Float(viewSize.height),
                                 mode: mode) != nil
        else {
            isRefused = true
            return false
        }
        isStroking = true
        isRefused = false
        return true
    }

    /// One more point of the stroke, in the 3D View's points.
    func add(_ point: CGPoint, pressure: Float) {
        guard isStroking else { return }
        let now = CACurrentMediaTime()
        pending.append(SculptPoint(x: Float(point.x), y: Float(point.y),
                                   pressure: pressure, time: now - started))
        if policy.shouldSend(at: now, pending: pending.count) { send(at: now) }
    }

    /// Sends what is waiting. False when Blender refused it, which ends the
    /// stroke: what it made so far is kept.
    @discardableResult
    private func send(at now: CFTimeInterval) -> Bool {
        guard let bridge, !pending.isEmpty else { return true }
        let points = pending
        pending = []
        let before = CACurrentMediaTime()
        let result = bridge.sculptChunk(points)
        let cost = CACurrentMediaTime() - before
        policy.sent(at: now, cost: cost)
        wallMs.append(cost * 1000)
        guard let result else {
            _ = finish()
            isRefused = true
            return false
        }
        results.append(result)
        return true
    }

    /// Ends the stroke: the rest goes to Blender, and the history records it
    /// as one step.
    @discardableResult
    func finish() -> SculptStrokeEnd? {
        guard isStroking else {
            isRefused = false
            return nil
        }
        if !pending.isEmpty { send(at: CACurrentMediaTime()) }
        guard isStroking else { return lastEnd }
        isStroking = false
        let ending = CACurrentMediaTime()
        lastEnd = bridge?.sculptEnd()
        endMs = (CACurrentMediaTime() - ending) * 1000
        return lastEnd
    }

    /// A refused touch has lifted: the next one may try again.
    func reset() {
        isRefused = false
    }

    /// Blender's brush circle under the finger: Blender's Size, a diameter
    /// in its region's pixels, drawn in the 3D View's points at the scale the
    /// stroke is sent at (`SculptState.regionScale`).
    private var cursor: CAShapeLayer?

    func showCursor(at point: CGPoint, diameter: CGFloat, in view: UIView) {
        let layer = cursor ?? {
            let made = CAShapeLayer()
            made.fillColor = UIColor.clear.cgColor
            made.strokeColor = UIColor.white.withAlphaComponent(0.75).cgColor
            made.lineWidth = 1
            view.layer.addSublayer(made)
            cursor = made
            return made
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = UIBezierPath(ovalIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                                 width: diameter, height: diameter)).cgPath
        CATransaction.commit()
    }

    func hideCursor() {
        cursor?.removeFromSuperlayer()
        cursor = nil
    }
}

/// Where a drag that may be sculpting has got to.
enum SculptDragPhase {
    case began(touchedDown: CGPoint)
    case changed, ended, cancelled
}

extension MetalViewportView.Coordinator {

    /// Whether drags and taps in this view sculpt with Blender's brush: Sculpt
    /// Mode with the real Blender behind the bridge.
    var sculptsInBlender: Bool {
        parent.scene.mode == .sculpt && parent.bridge?.sculptsInBlender == true
    }

    /// A finger or Pencil drag in Blender's Sculpt Mode: the whole stroke, from
    /// touch down to lift. Returns false, having done nothing, otherwise.
    func handleBlenderSculpt(_ g: UIPanGestureRecognizer, pressure: Float) -> Bool {
        guard let view else { return false }
        let phase: SculptDragPhase
        switch g.state {
        case .began:
            // A pan is recognised only once the touch has travelled a little;
            // the stroke starts where it came down, as Blender's does.
            let now = g.location(in: view)
            let travelled = g.translation(in: view)
            phase = .began(touchedDown: CGPoint(x: now.x - travelled.x, y: now.y - travelled.y))
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return sculptInput.owner != nil || sculptsInBlender
        }
        return sculptDrag(phase, at: g.location(in: view), pressure: pressure,
                          owner: ObjectIdentifier(g), in: view)
    }

    /// One moment of a drag that may be sculpting: what `handleBlenderSculpt`
    /// sends for a finger or the Pencil, and the DEBUG hooks for theirs.
    ///
    /// The drag that touched down in Sculpt Mode owns the stroke until it
    /// lifts, whatever happens meanwhile. It used to be asked again on every
    /// move whether the scene was in Sculpt Mode, and when it no longer was —
    /// Sculpt Mode left under the finger — the stroke was never ended: two-
    /// finger pan, pinch and scroll stayed held for a stroke still "in
    /// progress", the brush circle stayed on screen, the rest of the drag
    /// orbited the view, and the stroke's undo steps were never recorded
    /// (round 1's review of sculpting). Now a stroke whose mode has gone ends
    /// at once, kept, and the rest of its drag does nothing. A second drag
    /// while one is down (a finger during a Pencil stroke) does nothing too.
    func sculptDrag(_ phase: SculptDragPhase, at point: CGPoint, pressure: Float,
                    owner: ObjectIdentifier, in view: MTKView) -> Bool {
        if let current = sculptInput.owner {
            guard current == owner else { return true }
            switch phase {
            case .began, .changed:
                if sculptInput.isStroking && !sculptsInBlender {
                    endBlenderSculpt(keepingDrag: true)
                } else {
                    sculptInput.add(point, pressure: pressure)
                    showSculptCursor(at: point, in: view)
                }
            case .ended:
                if sculptsInBlender { sculptInput.add(point, pressure: pressure) }
                endBlenderSculpt()
            case .cancelled:
                // Interrupted, but what it sculpted still happened, and is kept.
                endBlenderSculpt()
            }
            return true
        }
        guard sculptsInBlender else { return false }
        if case .began(let touchedDown) = phase {
            sculptInput.owner = owner
            beginBlenderSculpt(at: touchedDown, in: view, pressure: pressure)
            sculptInput.add(point, pressure: pressure)
            showSculptCursor(at: point, in: view)
        }
        // The rest of a drag that began before Sculpt Mode is held, as it was.
        return true
    }

    /// A tap in Blender's Sculpt Mode: one dab, a stroke of its own — not
    /// while a drag's stroke is down, which owns Blender until it lifts.
    func tapBlenderSculpt(at point: CGPoint, in view: MTKView) -> Bool {
        if sculptInput.owner != nil { return true }
        guard sculptsInBlender else { return false }
        beginBlenderSculpt(at: point, in: view, pressure: 1)
        endBlenderSculpt()
        return true
    }

    func beginBlenderSculpt(at point: CGPoint, in view: MTKView, pressure: Float) {
        guard let bridge = parent.bridge, let object = parent.scene.active else { return }
        let mode: SculptStrokeMode = parent.scene.sculpt.invert ? .invert : .normal
        guard sculptInput.begin(object: object.name, camera: parent.camera,
                                viewSize: view.bounds.size, mode: mode, bridge: bridge) else { return }
        parent.scene.beginViewportDrag(.brush,
            "Sculpt  \(parent.scene.sculptBlender?.brush ?? "Brush")")
        sculptInput.add(point, pressure: pressure)
    }

    private func showSculptCursor(at point: CGPoint, in view: UIView) {
        guard sculptInput.isStroking, let state = parent.scene.sculptBlender, let size = state.size else { return }
        let scale = state.regionScale(viewWidth: Float(view.bounds.width), viewHeight: Float(view.bounds.height))
        sculptInput.showCursor(at: point, diameter: CGFloat(Float(size) / scale), in: view)
    }

    /// Ends the stroke, kept. `keepingDrag`: the drag goes on, owning the
    /// view until it lifts, with nothing left to do.
    func endBlenderSculpt(keepingDrag: Bool = false) {
        if !keepingDrag { sculptInput.owner = nil }
        sculptInput.hideCursor()
        parent.scene.endViewportDrag(.brush)
        guard let end = sculptInput.finish() else {
            sculptInput.reset()
            return
        }
        sculptInput.reset()
        let wall = sculptInput.wallMs
        let chunks = sculptInput.results
        // One line per stroke, for measuring what a chunk costs on device:
        // Blender's stroke and mirror inside the chunk, and the whole call.
        let median = { (v: [Double]) -> Double in v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        print(String(format: "[bk-sculpt] %@ %@: %ld chunks, %ld dabs, %ld undo steps (%@), %ld cut(s); "
                     + "chunk ms median %.1f max %.1f (Blender stroke %.1f, mirror %.1f); "
                     + "end %.1f ms (Blender stroke %.1f, mirror %.1f)",
                     end.strategy, parent.scene.sculptBlender?.brush ?? "?", end.chunks, end.dabs,
                     end.pushed, end.counted ? "counted on Blender's stack" : "counted by chunk",
                     end.cuts, median(wall), wall.max() ?? 0,
                     median(chunks.map(\.strokeMs)), median(chunks.map(\.mirrorMs)),
                     sculptInput.endMs, end.strategy == "deferred" ? end.strokeMs.last ?? 0 : 0,
                     end.strategy == "deferred" ? end.mirrorMs.last ?? 0 : 0))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sculpt-stroke") {
            print("[bk-sculpt] chunks (dabs replayed, applied, undo ms, run ms, mirror ms): " + chunks.map {
                String(format: "%ld %@ %.1f %.1f %.1f", $0.dabs, $0.applied ? "y" : "n",
                       $0.undoMs ?? 0, $0.runMs ?? 0, $0.mirrorMs)
            }.joined(separator: " | "))
        }
        #endif
        fflush(stdout)
    }

    #if DEBUG
    /// `-sculpt-stroke`: one stroke across the active object in Blender's
    /// Sculpt Mode, fed at 60 points a second through `beginBlenderSculpt`,
    /// `SculptStrokeInput.add` and `endBlenderSculpt` — the calls a finger's
    /// drag makes — once a `-eval64` script has finished. `-sculpt-brush <name>`
    /// picks a brush first, through the header's call; `-sculpt-stroke-points
    /// <n>` (default 60) and `-sculpt-stroke-span <fraction of the view's
    /// width>` (default 0.3) shape it; `-sculpt-undo` then undoes and redoes
    /// it through the top bar's calls, printing what each left.
    func sculptLaunchStrokeIfRequested(tries: Int = 120) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-sculpt-stroke") else { return }
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard tries > 0 else {
            print("[bk] sculpt-stroke: never reached Blender's Sculpt Mode with an object")
            fflush(stdout)
            return
        }
        // The sculpt header fills `sculptBlender` from Blender once it is on
        // screen, which is what the hook waits for: the header's own read.
        guard let view, view.bounds.width > 0, let bridge = parent.bridge,
              !bridge.isRunningScript, parent.scene.mode == .sculpt,
              let object = parent.scene.active, parent.scene.sculptBlender != nil
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.sculptLaunchStrokeIfRequested(tries: tries - 1)
            }
            return
        }
        // `-sculpt-ops a,b,...`: the header's operations first, each sent as
        // SculptHeader sends it — `dyntopo-on`, `dyntopo-off`, `remesh`,
        // `voxel-<size>`, `multires`, `mask-fill`, `mask-invert`, `mask-clear`,
        // `facesets-loose`, `facesets-from-mask`, `size-<px>`, `strength-<v>`.
        for op in (value("-sculpt-ops") ?? "").split(separator: ",").map(String.init) {
            let command: (String, String?)?
            switch op {
            case "dyntopo-on":         command = (SculptBpy.dyntopo(true), SculptBpy.dyntopoUndo)
            case "dyntopo-off":        command = (SculptBpy.dyntopo(false), SculptBpy.dyntopoUndo)
            case "remesh":             command = (SculptBpy.voxelRemesh, SculptBpy.voxelRemeshUndo)
            case "multires":           command = (SculptBpy.multiresSubdivide, SculptBpy.multiresSubdivideUndo)
            case "mask-fill":          command = (SculptBpy.mask(.fill), SculptBpy.maskUndo)
            case "mask-invert":        command = (SculptBpy.mask(.invert), SculptBpy.maskUndo)
            case "mask-clear":         command = (SculptBpy.mask(.clear), SculptBpy.maskUndo)
            case "facesets-loose":     command = (SculptBpy.faceSetsInit(.looseParts), SculptBpy.faceSetsInitUndo)
            case "facesets-from-mask": command = (SculptBpy.faceSetFromMask, SculptBpy.faceSetFromMaskUndo)
            default:
                if op.hasPrefix("voxel-"), let v = Float(op.dropFirst(6)) {
                    command = (SculptBpy.setVoxelSize(v), nil)
                } else if op.hasPrefix("size-"), let v = Int(op.dropFirst(5)) {
                    command = (SculptBpy.setSize(v), nil)
                } else if op.hasPrefix("strength-"), let v = Float(op.dropFirst(9)) {
                    command = (SculptBpy.setStrength(v), nil)
                } else {
                    command = nil
                }
            }
            guard let command else { print("[bk] sculpt-op \(op): unknown"); continue }
            let outcome = bridge.run(command.0, undo: command.1)
            let state = bridge.sculptState()
            print("[bk] sculpt-op \(op): " + (outcome.succeeded ? "ran" : "REFUSED: \(outcome.error ?? "")")
                  + "; Blender: \(state?.vertices ?? -1) verts, dyntopo \(state?.dyntopo ?? false), "
                  + "masked \(state?.masked ?? -1), face sets \(state?.faceSets ?? -1), "
                  + "multires \(state?.multires.map { "\($0.totalLevels) levels" } ?? "none"), "
                  + "size \(state?.size ?? -1), strength \(state?.strength ?? -1); "
                  + "\(parent.scene.active?.mesh.vertices.count ?? -1) verts drawn")
            fflush(stdout)
        }
        if let brush = value("-sculpt-brush") {
            let outcome = bridge.run(SculptBpy.activate(brush))
            print("[bk] sculpt-stroke: brush \(brush) "
                  + (outcome.succeeded ? "active" : "REFUSED: \(outcome.error ?? "")"))
        }
        // The header reads Blender again when the history's revision moves,
        // in a task of its own: the stroke waits for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.sculptLaunchStroke(object: object, view: view, bridge: bridge)
        }
    }

    private func sculptLaunchStroke(object: BKObject, view: MTKView, bridge: BpyBridge) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        print("[bk] sculpt-stroke: the header shows \(parent.scene.sculptBlender?.brush ?? "?"), "
              + "size \(parent.scene.sculptBlender?.size ?? -1) px, strength "
              + "\(parent.scene.sculptBlender?.strength ?? -1), as it read them from Blender")
        guard !args.contains("-sculpt-header-only") else { fflush(stdout); return }
        // Frame Selected first, as a reader would before sculpting: the view
        // at launch frames the whole scene, where a 100 px brush covers the
        // dinosaur's whole body.
        if !args.contains("-sculpt-no-frame") { _ = parent.camera.frameSelected(in: parent.scene) }
        let count = Int(value("-sculpt-stroke-points") ?? "") ?? 60
        let span = CGFloat(Double(value("-sculpt-stroke-span") ?? "") ?? 0.3)
        // Across the middle of the object as the 3D View shows it.
        let bounds = view.bounds
        let world = object.worldBounds
        let centre = (world.min + world.max) / 2
        let clip = parent.camera.viewProjection(aspect: Float(bounds.width / bounds.height))
            * SIMD4(centre, 1)
        let screen = CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * bounds.width,
                             y: CGFloat((1 - clip.y / clip.w) / 2) * bounds.height)
        let from = CGPoint(x: screen.x - bounds.width * span / 2, y: screen.y)
        let to = CGPoint(x: screen.x + bounds.width * span / 2, y: screen.y + bounds.height * 0.02)
        let before = object.mesh.vertices.map(\.position)
        print("[bk] sculpt-stroke: \(object.name), \(before.count) verts drawn, brush "
              + "\(parent.scene.sculptBlender?.brush ?? "?") of \(bridge.sculptBrushes().count) Essentials, "
              + "size \(parent.scene.sculptBlender?.size ?? -1) px, Blender's undo stack "
              + "\(parent.scene.sculptBlender?.undoStack.map(String.init) ?? "unreadable"), "
              + "from \(from) to \(to), \(count) points, in a \(bounds.width) x \(bounds.height) view; "
              + "camera target \(parent.camera.target) distance \(parent.camera.distance) "
              + "azimuth \(parent.camera.azimuth) elevation \(parent.camera.elevation) ortho \(parent.camera.isOrthographic)")
        fflush(stdout)
        // Fed through `sculptDrag`, the state machine a finger's drag runs,
        // with a drag of its own to own the stroke.
        let drag = ObjectIdentifier(self)
        _ = sculptDrag(.began(touchedDown: from), at: from, pressure: 1, owner: drag, in: view)
        guard sculptInput.isStroking else {
            print("[bk] sculpt-stroke: REFUSED — banner: "
                  + (bridge.report.map { "\($0.operation): \($0.message)" } ?? "none"))
            _ = sculptDrag(.ended, at: from, pressure: 1, owner: drag, in: view)
            fflush(stdout)
            return
        }
        // `-sculpt-midstroke <what>`: half way through the stroke, what a
        // reader could do with the other hand — `undo` (the top bar's Undo),
        // `mask` (the header's Mask ▸ Fill), `leave` (Leave Sculpt Mode) — or
        // `mode`, the interface's mode leaving Sculpt Mode under the finger
        // without any of the app's controls, as a mirror report would. Prints
        // what each left: refused or not, the history, the drag's state.
        let midstroke = value("-sculpt-midstroke")
        var step = 1
        var historyBefore = ""
        func next() {
            guard step <= count else {
                let azimuth = parent.camera.azimuth
                _ = sculptDrag(.ended, at: to, pressure: 1, owner: drag, in: view)
                report(before: before, object: object, label: "after the stroke")
                if midstroke != nil {
                    print("[bk] sculpt-midstroke after the lift: stroking \(sculptInput.isStroking), "
                          + "drag owned \(sculptInput.owner != nil), bridge stroke \(bridge.sculptStrokeActive), "
                          + "session held \(parent.bridge?.debugSession.sculptStrokeOpen ?? true), "
                          + "camera azimuth moved \(parent.camera.azimuth != azimuth), "
                          + "history \(historyBefore) -> undo '\(parent.bridge?.debugSession.backendHistory.undoLabel ?? "?")'")
                    let open = bridge.capture("import _blenderkit_sculpt\nprint(_blenderkit_sculpt._stroke is None)")
                    print("[bk] sculpt-midstroke: Blender's stroke closed \(open ?? "?")")
                }
                if args.contains("-sculpt-undo") { undoAndRedo(before: before, object: object) }
                print("[bk] sculpt-stroke done")
                fflush(stdout)
                return
            }
            if step == count / 2, let midstroke { interrupt(midstroke, bridge: bridge) }
            if step == count / 2 - 1 {
                historyBefore = "'\(parent.bridge?.debugSession.backendHistory.undoLabel ?? "?")'"
            }
            let t = CGFloat(step) / CGFloat(count)
            let azimuth = parent.camera.azimuth
            _ = sculptDrag(.changed, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                           pressure: 1, owner: drag, in: view)
            if midstroke == "mode", step > count / 2, parent.camera.azimuth != azimuth {
                print("[bk] sculpt-midstroke: the rest of the drag ORBITED the view")
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { next() }
    }

    private func interrupt(_ what: String, bridge: BpyBridge) {
        guard let session = parent.bridge?.debugSession else { return }
        let before = session.backendHistory.undoLabel
        bridge.dismissReport(bridge.report?.id ?? -1)
        switch what {
        case "undo":
            session.performUndo()
        case "mask":
            bridge.run(SculptBpy.mask(.fill), undo: SculptBpy.maskUndo)
        case "leave":
            bridge.run(SculptBpy.leave, undo: SculptBpy.modeUndo)
        case "mode":
            parent.scene.setMode(.object)
        default:
            print("[bk] sculpt-midstroke \(what): unknown")
        }
        print("[bk] sculpt-midstroke \(what): stroking \(sculptInput.isStroking), history '\(before)' -> "
              + "'\(session.backendHistory.undoLabel)', banner: "
              + (bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")
              + ", console: \(session.console.last?.text ?? "")")
        fflush(stdout)
    }

    /// How far the drawn mesh moved from `before`, the mirror's copy of
    /// Blender's evaluated mesh.
    private func report(before: [SIMD3<Float>], object: BKObject, label: String) {
        let now = object.mesh.vertices.map(\.position)
        func box(_ v: [SIMD3<Float>]) -> String {
            let lo = v.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
            let hi = v.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
            return String(format: "(%.3f %.3f %.3f)-(%.3f %.3f %.3f)", lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
        }
        print("[bk] sculpt-stroke \(label): local bounds before \(box(before)), now \(box(now)); "
              + "the viewport draws a mask on \(object.drawnSculptMask?.filter { $0 > 0 }.count ?? 0) verts")
        guard now.count == before.count else {
            print("[bk] sculpt-stroke \(label): \(before.count) -> \(now.count) verts drawn")
            return
        }
        var moved = 0
        var most: Float = 0
        for (a, b) in zip(before, now) {
            let d = simd_distance(a, b)
            if d > 1e-6 { moved += 1 }
            most = max(most, d)
        }
        // Dynamic topology gives its vertices back in another order after an
        // Undo, so a mesh that moved by index is compared as a set as well.
        let key = { (p: SIMD3<Float>) -> [Float] in [p.x, p.y, p.z] }
        let sortedBefore = before.map(key).sorted { $0.lexicographicallyPrecedes($1) }
        let sortedNow = now.map(key).sorted { $0.lexicographicallyPrecedes($1) }
        let asSet = zip(sortedBefore, sortedNow).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
        print(String(format: "[bk] sculpt-stroke %@: %ld of %ld drawn verts of %@ moved, at most %.4f; "
                     + "as a set of positions, at most %.4f apart",
                     label, moved, now.count, object.name, most, asSet))
        fflush(stdout)
    }

    /// `-standin-dab <n>`: in a 3D View that cannot reach Blender's brush
    /// (no bridge: the Scripting tab's), once the scene is in Sculpt Mode
    /// with an object, `n` taps through `standInSculptTap` — what a tap
    /// calls — and `n` dabs through `sculptDab`, what a drag calls on every
    /// move, at the object's centre on screen. Prints what each left drawn.
    func standInDabLaunchIfRequested(tries: Int = 120) {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-standin-dab") else { return }
        let count = flag + 1 < args.count ? Int(args[flag + 1]) ?? 4 : 4
        guard tries > 0 else {
            print("[bk] standin-dab: never reached Sculpt Mode with an object in a view without the bridge")
            fflush(stdout)
            return
        }
        guard let view, view.bounds.width > 0, !sculptsInBlender, parent.bridge == nil,
              parent.scene.mode == .sculpt, let object = parent.scene.active
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.standInDabLaunchIfRequested(tries: tries - 1)
            }
            return
        }
        let bounds = view.bounds
        let world = object.worldBounds
        let clip = parent.camera.viewProjection(aspect: Float(bounds.width / bounds.height))
            * SIMD4((world.min + world.max) / 2, 1)
        let point = CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * bounds.width,
                            y: CGFloat((1 - clip.y / clip.w) / 2) * bounds.height)
        let start = object.mesh.vertices.count
        print("[bk] standin-dab: \(object.name), \(start) verts drawn, evaluated \(object.meshIsEvaluated), "
              + "modifiers \(object.modifiers.map(\.kind.rawValue)), at \(point) in \(bounds.size)")
        var taps: [String] = []
        for _ in 0..<count {
            let installed = standInSculptTap(at: point, in: view)
            taps.append("\(installed ? "dab" : "refused") \(object.mesh.vertices.count)")
        }
        var drags: [String] = []
        for i in 0..<count {
            let installed = sculptDab(at: CGPoint(x: point.x + CGFloat(i), y: point.y), in: view,
                                      delta: SIMD2(1, 0))
            drags.append("\(installed ? "dab" : "refused") \(object.mesh.vertices.count)")
        }
        print("[bk] standin-dab taps: " + taps.joined(separator: ", "))
        print("[bk] standin-dab drag moves: " + drags.joined(separator: ", "))
        print("[bk] standin-dab done: \(start) -> \(object.mesh.vertices.count) verts drawn")
        fflush(stdout)
    }

    private func undoAndRedo(before: [SIMD3<Float>], object: BKObject) {
        guard let session = parent.bridge?.debugSession else { return }
        session.performUndo()
        let target = parent.scene.objects.first { $0.name == object.name } ?? object
        report(before: before, object: target, label: "after Undo (from the start)")
        print("[bk] sculpt-stroke: after Undo Blender is in \(parent.scene.mode.bpyMode)")
        session.performRedo()
        let again = parent.scene.objects.first { $0.name == object.name } ?? object
        report(before: before, object: again, label: "after Redo (from the start)")
    }
    #endif
}
