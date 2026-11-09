import UIKit
import MetalKit
import simd

/// A Draw Mode stroke in progress in one 3D View: the Brush tool's samples,
/// drawn at once over the view (`ViewportRenderer.gpLiveStroke`) and written
/// to Blender in one call when the finger or Pencil lifts — one undo step,
/// "Grease Pencil Draw" — or the Erase tool's path, erased when it lifts.
final class GreasePencilStrokeInput {
    enum Kind { case draw, erase }

    private(set) var kind: Kind = .draw
    private(set) var isStroking = false
    /// The drag that touched down owns the stroke until it lifts.
    var owner: ObjectIdentifier?
    private(set) var samples: [GPSample] = []
    private var object = ""
    private var view = GPView(viewProjection: matrix_identity_float4x4, size: SIMD2(1, 1), forward: SIMD3(0, 1, 0))
    private var toWorld = matrix_identity_float4x4
    private var state = GPDrawState()
    private var placement = GreasePencilStroke.Placement(point: .zero, normal: SIMD3(0, 1, 0))
    private var colour = SIMD4<Float>(0, 0, 0, 1)
    /// Once a Pencil has drawn in this view, a finger navigates instead, as
    /// Blender's and every drawing app's touch conventions go.
    static var pencilSeen = false
    /// The eraser's circle and trail over the view.
    private var eraserLayer: CAShapeLayer?

    func begin(kind: Kind, object: BKObject, state: GPDrawState, view: GPView, colour: SIMD4<Float>) {
        self.kind = kind
        self.object = object.name
        self.view = view
        self.state = state
        self.colour = colour
        let layerMatrix = object.greasePencilInfo?.active?.matrix ?? matrix_identity_float4x4
        toWorld = object.modelMatrix * layerMatrix
        placement = GreasePencilStroke.placement(state, toWorld: toWorld, view: view)
        samples = []
        isStroking = true
    }

    /// One more sample; the live stroke's point for it, in the view's points.
    func add(_ point: CGPoint, pressure: Float) -> GreasePencilGeometry.Point? {
        guard isStroking else { return nil }
        let sample = GPSample(SIMD2(Float(point.x), Float(point.y)), pressure: pressure)
        if let last = samples.last, simd_distance(last.point, sample.point) < 0.5 { return nil }
        samples.append(sample)
        guard kind == .draw else { return nil }
        let brush = state.brush ?? GPBrush()
        let made = GreasePencilStroke.point(sample, brush: brush, placement: placement, toWorld: toWorld, view: view)
        let scale = simd_length(SIMD3(toWorld.columns.0.x, toWorld.columns.0.y, toWorld.columns.0.z))
        let perPoint = view.worldPerPoint(at: made.world)
        let radius = perPoint > 0 ? made.radius * scale / perPoint : 1
        return GreasePencilGeometry.Point(SIMD3(sample.point, 0), radius: radius,
                                          colour: SIMD4(colour.x, colour.y, colour.z, colour.w * made.opacity))
    }

    /// The stroke as Blender is handed it, or nil for none.
    func finish() -> (python: String, points: Int)? {
        defer { isStroking = false; samples = [] }
        guard isStroking, !samples.isEmpty else { return nil }
        switch kind {
        case .draw:
            let made = GreasePencilStroke.make(samples, state: state, toWorld: toWorld, view: view)
            guard !made.isEmpty else { return nil }
            return (GreasePencilStroke.python(object: object, points: made), made.count)
        case .erase:
            return nil
        }
    }

    /// The eraser's path, for `GreasePencilStroke.erasePython`.
    func erasePath() -> [SIMD2<Float>] {
        var path = samples.map(\.point)
        if path.count == 1 { path.append(path[0]) }
        return path
    }

    var gpView: GPView { view }
    var objectName: String { object }

    func cancel() {
        isStroking = false
        samples = []
        owner = nil
    }

    func showEraser(at point: CGPoint, diameter: CGFloat, in host: UIView) {
        let layer = eraserLayer ?? {
            let made = CAShapeLayer()
            made.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
            made.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            made.lineWidth = 1
            host.layer.addSublayer(made)
            eraserLayer = made
            return made
        }()
        let path = UIBezierPath()
        // Where it has been, so what will go is in sight, then the circle.
        let trail = samples.map { CGPoint(x: CGFloat($0.point.x), y: CGFloat($0.point.y)) }
        for (i, p) in trail.enumerated() {
            path.append(UIBezierPath(ovalIn: CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2,
                                                    width: diameter, height: diameter)))
            if i > 400 { break }
        }
        path.append(UIBezierPath(ovalIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                                width: diameter, height: diameter)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = path.cgPath
        CATransaction.commit()
    }

    func hideEraser() {
        eraserLayer?.removeFromSuperlayer()
        eraserLayer = nil
    }

    deinit { eraserLayer?.removeFromSuperlayer() }
}

extension MetalViewportView.Coordinator {

    /// Draw Mode with the Brush or Erase tool (`builtin.brush`, labelled Brush in
    /// 5.2.1, and `builtin_brush.Erase`), on a Grease Pencil object, with
    /// the real Blender behind the bridge.
    var drawsGreasePencil: Bool {
        parent.scene.mode == .drawGreasePencil
            && (parent.tool == .gpDraw || parent.tool == .gpErase)
            && parent.scene.active?.isGreasePencil == true
            && parent.bridge != nil
    }

    /// A drag in Draw Mode: the whole stroke, from touch down to lift.
    /// `pencil`: the Apple Pencil's own drag; a finger's draws only until a
    /// Pencil has been used in the view, and then navigates.
    func handleGreasePencil(_ g: UIPanGestureRecognizer, pressure: Float, pencil: Bool) -> Bool {
        guard let view else { return false }
        if pencil { GreasePencilStrokeInput.pencilSeen = true }
        if let owner = gpInput.owner {
            guard owner == ObjectIdentifier(g) else { return true }
        } else {
            guard drawsGreasePencil, g.state == .began else { return false }
            // A finger navigates once a Pencil has drawn in the view.
            if !pencil, GreasePencilStrokeInput.pencilSeen, isDirectTouch(g) { return false }
        }
        switch g.state {
        case .began:
            let now = g.location(in: view)
            let travelled = g.translation(in: view)
            let down = CGPoint(x: now.x - travelled.x, y: now.y - travelled.y)
            // Ctrl held: the stroke erases, as Blender's Ctrl+drag in Draw
            // Mode (`brush_toggle='ERASE'`, its Brush Stroke keymap).
            let ctrl = ScreenModifiers.shared.merged(g.modifierFlags).contains(.control)
            guard beginGreasePencil(at: down, in: view, pressure: pressure, erasing: ctrl ? true : nil) else {
                // Refused: the rest of the drag does nothing.
                gpInput.owner = ObjectIdentifier(g)
                return true
            }
            gpInput.owner = ObjectIdentifier(g)
            addGreasePencil(now, pressure: pressure, in: view)
        case .changed:
            addGreasePencil(g.location(in: view), pressure: pressure, in: view)
        case .ended:
            addGreasePencil(g.location(in: view), pressure: pressure, in: view)
            endGreasePencil(in: view)
        default:
            // Interrupted by the system: what was drawn still happened.
            endGreasePencil(in: view)
        }
        return true
    }

    /// Whether the drag is a finger on the glass (not a mouse or trackpad).
    private func isDirectTouch(_ g: UIGestureRecognizer) -> Bool {
        // UIKit does not say which kind a pan's touches were; the watcher saw
        // them come down.
        touchWatcher?.lastTouchType == .direct
    }

    /// The Pencil's tap: a dot in Draw Mode.
    @objc func handlePencilTap(_ g: UITapGestureRecognizer) {
        guard let view else { return }
        GreasePencilStrokeInput.pencilSeen = true
        _ = greasePencilTap(at: g.location(in: view))
    }

    /// A tap in Draw Mode: a dot with the Brush, an erase with Erase.
    func greasePencilTap(at point: CGPoint) -> Bool {
        guard drawsGreasePencil, let view, gpInput.owner == nil else { return false }
        if GreasePencilStrokeInput.pencilSeen, touchWatcher?.lastTouchType == .direct { return false }
        guard beginGreasePencil(at: point, in: view, pressure: 1) else { return true }
        addGreasePencil(point, pressure: 1, in: view)
        endGreasePencil(in: view)
        return true
    }

    /// `erasing`: the Erase tool's stroke whatever the tool in hand (the
    /// DEBUG hook's); nil asks the tool.
    @discardableResult
    func beginGreasePencil(at point: CGPoint, in view: UIView, pressure: Float, erasing: Bool? = nil) -> Bool {
        guard let object = parent.scene.active, object.isGreasePencil, let bridge = parent.bridge,
              let info = object.greasePencilInfo else { return false }
        let erasing = erasing ?? (parent.tool == .gpErase)
        // Blender's own refusals, before anything is drawn.
        if !erasing {
            guard let layer = info.active else {
                bridge.showReport(GreasePencilBpy.strokeUndo, "No active Grease Pencil layer")
                return false
            }
            if layer.locked || layer.hidden {
                bridge.showReport(GreasePencilBpy.strokeUndo, "Active layer is locked or hidden")
                return false
            }
        }
        if parent.scene.greasePencilDraw == nil { parent.scene.greasePencilDraw = bridge.greasePencilState() }
        let state = parent.scene.greasePencilDraw ?? GPDrawState()
        let size = view.bounds.size
        let camera = currentCamera
        let gpView = GPView(viewProjection: camera.viewProjection(aspect: Float(size.width / max(size.height, 1))),
                            size: SIMD2(Float(size.width), Float(size.height)),
                            forward: camera.target - camera.eye)
        var colour = SIMD4<Float>(0, 0, 0, 1)
        if info.materials.indices.contains(info.activeMaterial), let material = info.materials[info.activeMaterial] {
            let layer = info.active ?? GPLayer(name: "")
            colour = GreasePencilGeometry.strokeColour(material: material, vertexColour: nil, opacity: 1, layer: layer)
        }
        gpInput.begin(kind: erasing ? .erase : .draw, object: object, state: state, view: gpView, colour: colour)
        parent.scene.beginViewportDrag(.brush, erasing ? "Erase" : (state.brush?.name ?? "Brush"))
        return true
    }

    func addGreasePencil(_ point: CGPoint, pressure: Float, in view: UIView) {
        guard gpInput.isStroking else { return }
        let made = gpInput.add(point, pressure: pressure)
        if gpInput.kind == .erase {
            gpInput.showEraser(at: point, diameter: CGFloat(parent.scene.greasePencilEraser.size), in: view)
            return
        }
        if let made { renderer?.gpLiveStroke.points.append(made) }
    }

    func endGreasePencil(in view: UIView) {
        gpInput.owner = nil
        parent.scene.endViewportDrag(.brush)
        guard gpInput.isStroking, let bridge = parent.bridge else {
            gpInput.cancel()
            renderer?.gpLiveStroke = GPLiveStroke()
            return
        }
        if gpInput.kind == .erase {
            let eraser = parent.scene.greasePencilEraser
            let python = GreasePencilStroke.erasePython(object: gpInput.objectName, view: gpInput.gpView,
                                                        path: gpInput.erasePath(), radius: eraser.size / 2,
                                                        mode: eraser.mode.rawValue, strength: eraser.strength,
                                                        activeLayerOnly: eraser.activeLayerOnly)
            gpInput.cancel()
            gpInput.hideEraser()
            bridge.run(python, undo: GreasePencilBpy.strokeUndo)
            return
        }
        let began = CACurrentMediaTime()
        let finished = gpInput.finish()
        if let finished {
            bridge.run(finished.python, undo: GreasePencilBpy.strokeUndo)
            print(String(format: "[bk-gpencil] stroke of %ld points written in %.1f ms", finished.points,
                         (CACurrentMediaTime() - began) * 1000))
        }
        // After the mirror has the stroke, so nothing blinks out between.
        renderer?.gpLiveStroke = GPLiveStroke()
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
    /// `-draw-ops a,b,…`: Draw Mode driven as a finger drives it, once the
    /// scene is up (and a `-eval64` script has run), each step after the last:
    ///
    /// * `add-blank`, `add-stroke`, `add-monkey` — Add ▸ Grease Pencil, at the
    ///   3D cursor, through the Add menu's call;
    /// * `front` — the view to Front (Numpad 1), orthographic as Blender's;
    ///   `persp` — back to perspective;
    /// * `draw-mode`, `object-mode` — the mode menu's rows;
    /// * `stroke-wave`, `stroke-circle`, `stroke-zigzag`, `stroke-dot`,
    ///   `stroke-line` — a stroke fed at 60 samples a second through
    ///   `beginGreasePencil`, `addGreasePencil`, `endGreasePencil`, the
    ///   calls a drag makes, pressure rising from 0.4 to 1;
    ///   `stroke-…@x,y` puts its centre at that share of the view;
    /// * `erase-dissolve`, `erase-point`, `erase-stroke` — the Erase tool's
    ///   mode, then a horizontal swipe across the middle;
    /// * `frame-N` — the frame, as the timeline sets it; `autokey-on|off`,
    ///   `additive-on|off`; `layer-add`; `onion-off`;
    /// * `tap-x,y` — a tap at that share of the view (Object Mode selects);
    /// * `report` — what the mirror holds; `wait` — half a second.
    ///
    /// Prints `[bk] draw-ops: done` at the end (apprun.sh's end marker).
    func drawOpsLaunchIfRequested(tries: Int = 160) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-draw-ops"), i + 1 < args.count else { return }
        guard tries > 0 else { print("[bk] draw-ops: the scene never came up"); fflush(stdout); return }
        guard let view, view.bounds.width > 0, let bridge = parent.bridge, !bridge.isRunningScript,
              parent.scene.objects.count > 0
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.drawOpsLaunchIfRequested(tries: tries - 1) }
            return
        }
        // After `-eval64`, which runs at +1 s.
        let tokens = args[i + 1].split(separator: ",").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.drawOp(tokens, 0) }
    }

    private func drawOp(_ tokens: [String], _ index: Int) {
        guard index < tokens.count else {
            print("[bk] draw-ops: done"); fflush(stdout); return
        }
        let next = { (delay: Double) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.drawOp(tokens, index + 1) }
        }
        guard let view, let bridge = parent.bridge else { return }
        let op = tokens[index]
        let size = view.bounds.size
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: fx * size.width, y: fy * size.height) }
        print("[bk] draw-op \(op)"); fflush(stdout)
        if op.hasPrefix("add-") {
            let kind: ObjectAddition.GreasePencilKind = op == "add-blank" ? .blank : (op == "add-stroke" ? .stroke : .monkey)
            let outcome = bridge.add(.greasePencil(kind), at: parent.scene.cursor, view: currentCamera)
            print("[bk] draw-op \(op): " + (outcome.succeeded ? "added \(parent.scene.active?.name ?? "?")"
                                             : "REFUSED: \(outcome.error ?? "")"))
            next(0.6)
        } else if op == "front" || op == "persp" {
            var camera = parent.camera
            if op == "front" { camera.snap(to: .front) } else { camera.isOrthographic = false }
            parent.camera = camera
            next(0.4)
        } else if op == "draw-mode" || op == "object-mode" {
            let outcome = bridge.run(op == "draw-mode" ? GreasePencilBpy.enter : GreasePencilBpy.leave,
                                     undo: GreasePencilBpy.modeUndo)
            print("[bk] draw-op \(op): " + (outcome.succeeded ? "mode \(parent.scene.mode.label)" : "REFUSED: \(outcome.error ?? "")"))
            parent.scene.greasePencilDraw = bridge.greasePencilState()
            next(0.8)
        } else if op.hasPrefix("stroke-") || op.hasPrefix("erase-") {
            let erasing = op.hasPrefix("erase-")
            var shape = String(op.dropFirst(erasing ? 6 : 7))
            var centre = CGPoint(x: 0.5, y: 0.5)
            if let a = shape.firstIndex(of: "@") {
                let xy = shape[shape.index(after: a)...].split(separator: ";").first.map(String.init) ?? ""
                let parts = xy.split(separator: "_").compactMap { Double($0) }
                if parts.count == 2 { centre = CGPoint(x: parts[0], y: parts[1]) }
                shape = String(shape[..<a])
            }
            if erasing {
                parent.scene.greasePencilEraser.mode = shape == "point" ? .point : (shape == "stroke" ? .stroke : .dissolve)
            }
            let path = Self.debugPath(erasing ? "line" : shape, centre: centre, size: size)
            debugStroke(path, erasing: erasing, view: view) { next(0.8) }
        } else if op.hasPrefix("frame-"), let frame = Int(op.dropFirst(6)) {
            let outcome = bridge.run("import _blenderkit_anim\n_blenderkit_anim.frame_set(\(frame))")
            print("[bk] draw-op \(op): " + (outcome.succeeded ? "frame \(parent.scene.frameCurrent)" : "REFUSED: \(outcome.error ?? "")"))
            next(0.6)
        } else if op.hasPrefix("autokey-") || op.hasPrefix("additive-") {
            let on = op.hasSuffix("-on")
            let key = op.hasPrefix("autokey-") ? "use_keyframe_insert_auto" : "use_gpencil_draw_additive"
            bridge.run(GreasePencilBpy.setTool(key, on))
            parent.scene.greasePencilDraw = bridge.greasePencilState()
            next(0.4)
        } else if op == "layer-add" {
            let outcome = bridge.run(GreasePencilBpy.layerAdd, undo: GreasePencilBpy.layerAddUndo)
            print("[bk] draw-op \(op): " + (outcome.succeeded ? "ran" : "REFUSED: \(outcome.error ?? "")"))
            next(0.6)
        } else if op == "onion-off" {
            if let name = parent.scene.active?.name {
                for layer in parent.scene.active?.greasePencilInfo?.layers ?? [] {
                    bridge.run(GreasePencilBpy.layerSet(name, layer: layer.name, "use_onion_skinning", "False"),
                               undo: "Onion Skinning")
                }
            }
            next(0.4)
        } else if op.hasPrefix("tap-") {
            let parts = op.dropFirst(4).split(separator: "_").compactMap { Double($0) }
            if parts.count == 2 { tap(at: at(parts[0], parts[1]), modifiers: []) }
            print("[bk] draw-op \(op): active \(parent.scene.active?.name ?? "none"), "
                  + "selected \(parent.scene.selection.count)")
            next(0.6)
        } else if op == "report" {
            debugReport()
            next(0.2)
        } else if op.hasPrefix("shot-") {
            // The 3D View's frame as drawn (`captureFrame`), into the app's
            // temporary folder as gp-<name>.png.
            if let frame = renderer?.captureFrame() {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gp-\(op.dropFirst(5)).png")
                Self.writePNG(frame.rgba, width: frame.width, height: frame.height, to: url)
                print("[bk] draw-op \(op): \(url.path)")
            }
            next(0.2)
        } else if op == "wait" {
            next(0.5)
        } else if op.hasPrefix("hold-"), let seconds = Double(op.dropFirst(5)) {
            // Time for a window screenshot (apprun.sh's SHOT_AT).
            next(seconds)
        } else {
            print("[bk] draw-op \(op): unknown")
            next(0.1)
        }
    }

    static func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) {
        var bytes = rgba
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return }
        try? UIImage(cgImage: image).pngData()?.write(to: url)
    }

    /// A stroke's samples in the view's points.
    static func debugPath(_ shape: String, centre: CGPoint, size: CGSize) -> [CGPoint] {
        let cx = centre.x * size.width, cy = centre.y * size.height
        let r = min(size.width, size.height) * 0.18
        var out: [CGPoint] = []
        switch shape {
        case "circle":
            for k in 0...72 {
                let t = CGFloat(k) / 72 * 2 * .pi
                out.append(CGPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
            }
        case "zigzag":
            for k in 0...60 {
                let t = CGFloat(k) / 60
                let tooth = abs((t * 6).truncatingRemainder(dividingBy: 2) - 1)
                out.append(CGPoint(x: cx - r * 1.4 + t * r * 2.8, y: cy - r * 0.5 + tooth * r))
            }
        case "dot":
            out = [CGPoint(x: cx, y: cy)]
        case "line":
            for k in 0...60 { out.append(CGPoint(x: cx - r * 1.6 + CGFloat(k) / 60 * r * 3.2, y: cy)) }
        default:  // wave
            for k in 0...90 {
                let t = CGFloat(k) / 90
                out.append(CGPoint(x: cx - r * 1.5 + t * r * 3, y: cy + sin(t * 2 * .pi * 1.5) * r * 0.5))
            }
        }
        return out
    }

    private func debugStroke(_ path: [CGPoint], erasing: Bool, view: UIView, done: @escaping () -> Void) {
        guard let first = path.first else { done(); return }
        let began = CACurrentMediaTime()
        // The 3D View's frames while the stroke is drawn, as Test All
        // Features reads a drag's.
        FrameClock.shared.startRecording()
        guard beginGreasePencil(at: first, in: view, pressure: 0.4, erasing: erasing) else {
            print("[bk] draw-op stroke: refused"); fflush(stdout)
            done(); return
        }
        var k = 0
        func step() {
            k += 1
            if k < path.count {
                let pressure = Float(0.4 + 0.6 * Double(k) / Double(max(path.count - 1, 1)))
                addGreasePencil(path[k], pressure: pressure, in: view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { step() }
                return
            }
            let frames = FrameClock.shared.stopRecording()
            let stats = FeatureTest.frameStats(FeatureTest.frameTimes(began: frames.began, presented: frames.presented))
            let encoding = frames.encoding.sorted()
            let ending = CACurrentMediaTime()
            endGreasePencil(in: view)
            print(String(format: "[bk] draw-op stroke: %ld samples over %.2f s, lift to mirrored %.1f ms; "
                         + "%ld frames, median %.1f ms, 95th %.1f ms, worst %.1f ms; encoding median %.2f ms",
                         path.count, ending - began, (CACurrentMediaTime() - ending) * 1000,
                         stats?.count ?? 0, (stats?.median ?? 0) * 1000, (stats?.p95 ?? 0) * 1000,
                         (stats?.worst ?? 0) * 1000, (encoding.isEmpty ? 0 : encoding[encoding.count / 2]) * 1000))
            debugReport()
            done()
        }
        step()
    }

    private func debugReport() {
        guard let object = parent.scene.active else { print("[bk] draw report: no active object"); return }
        let info = object.greasePencilInfo
        let blocks = object.greasePencilDrawings?.blocks ?? []
        let layers = (info?.layers ?? []).map { layer in
            "\(layer.name)[\(layer.keyframes.map { String($0.frame) }.joined(separator: " "))]@\(layer.frameInEffect.map(String.init) ?? "-")"
                + (layer.hidden ? " hidden" : "") + (layer.locked ? " locked" : "")
        }
        let ghosts = blocks.filter { $0.onion != 0 }.map { "\($0.onion):\($0.frame ?? 0)" }
        print("[bk] draw report: \(object.name) mode \(parent.scene.mode.label), frame \(parent.scene.frameCurrent), "
              + "layers \(layers.joined(separator: ", ")), active \(info?.active?.name ?? "none"), "
              + "\(info?.pointCount ?? 0) points in \(info?.strokeCount ?? 0) strokes, ghosts [\(ghosts.joined(separator: " "))], "
              + "material \(info?.activeMaterial ?? -1) of \(info?.materials.count ?? 0), "
              + "keys \(object.timelineKeys.map { String(Int($0.frame)) }.joined(separator: " "))")
        fflush(stdout)
    }
}
#endif
