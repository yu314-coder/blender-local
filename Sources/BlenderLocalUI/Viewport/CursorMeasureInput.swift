import SwiftUI
import MetalKit
import simd

/// A drag of the 3D cursor with the Cursor tool: where it began, what it may
/// snap to, and where the preview has it now (CursorTool.dragTarget).
struct CursorDrag {
    var start: SIMD3<Float>
    var current: SIMD3<Float>
    /// What the drag snaps to while snapping is on (the header's Snap, Ctrl
    /// inverting it as it is held — read on every move, as Blender's
    /// translate reads it); nil when there is nothing to snap to.
    var snap: GeometrySnap.Targets?
    var view: GeometrySnap.View
    /// Why the object being edited is left out of `snap`
    /// (`CursorTool.dragExcluded`), said in the drag's readout.
    var excludedReason: String?
}

/// A drag with the Measure tool: the ruler point it moves, and what it may
/// snap to (RulerTool.place).
struct RulerDrag {
    var drag: RulerTool.Drag
    var view: GeometrySnap.View
    var targets: GeometrySnap.Targets?
}

extension ViewportCamera {
    /// One of the six numpad views exactly, as `snap(to:)` leaves it: what
    /// Blender's RV3D_VIEW_IS_AXIS asks of the view (read by a cursor kept
    /// as Axis Angle). Any orbit leaves it, as Blender's view becomes User.
    var isAxisAligned: Bool {
        let half = Float.pi / 2
        if abs(elevation) == half { return azimuth == 0 }
        return elevation == 0 && [0, Float.pi, half, -half].contains(azimuth)
    }

    /// The view the Cursor tool's call carries.
    var cursorView: CursorTool.View {
        CursorTool.View(eye: eye, forward: simd_normalize(target - eye), up: trueUp, orthographic: isOrthographic,
                        center: target, axisAligned: isAxisAligned)
    }

    /// The view in a 3D View `size` points across, for the snap and the
    /// rulers.
    func snapView(_ size: CGSize) -> GeometrySnap.View {
        GeometrySnap.View(viewProjection: viewProjection(aspect: Float(size.width / max(size.height, 1))),
                          size: SIMD2(Float(size.width), Float(size.height)))
    }
}

extension MetalViewportView.Coordinator {

    private func pointer(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y)) }

    /// Why the Cursor tool cannot place here, or nil.
    private func cursorRefusal() -> String? {
        guard let bridge = parent.bridge else { return "The Cursor tool works through Blender, which is not running." }
        if !bridge.usesRealBlender {
            return "The Cursor tool works through Blender's own 3D cursor, which the simulator's stand-in does not "
                + "keep. Type the cursor's Location in the Sidebar's View tab instead."
        }
        return nil
    }

    // MARK: Cursor

    /// A tap with the Cursor tool: Blender's click, ported
    /// (`_blenderkit_cursor.place`), with the depth and the face the mirror
    /// has under `point`. No undo step, as Blender's `view3d.cursor3d` has
    /// none. Returns whether Blender took it.
    @discardableResult
    func cursorTap(at point: CGPoint, size: CGSize) -> Bool {
        let scene = parent.scene
        if let refusal = cursorRefusal() {
            parent.bridge?.showReport(ActiveTool.cursor.label, refusal)
            return false
        }
        guard let bridge = parent.bridge, size.width > 0, size.height > 0 else { return false }
        let camera = parent.camera
        let view = camera.snapView(size)
        guard let ray = CursorTool.ray(view, pointer(point)) else { return false }
        let forward = simd_normalize(camera.target - camera.eye)
        let depth = CursorTool.depthHit(objects: scene.objects, view: view, pointer: pointer(point), forward: forward)
        let surface = CursorTool.surfaceHit(objects: scene.objects, ray: ray)
        let edited = scene.mode == .edit ? scene.active : nil
        if let refusal = CursorTool.geometryRefusal(surface, orientation: scene.cursorState.orientation, edited: edited) {
            bridge.showReport(ActiveTool.cursor.label, refusal)
            return false
        }
        guard let python = CursorTool.placePython(view: camera.cursorView,
                                                  point: CursorTool.linePoint(ray, center: camera.target),
                                                  depth: depth, surface: surface) else { return false }
        return bridge.run(python).succeeded
    }

    /// A press that starts a drag with the Cursor tool. A Pencil's or a
    /// pointer's press is Blender's: it places the cursor, then the drag
    /// moves it (`km_3d_view_tool_cursor`: cursor3d on press, then a
    /// translate of the cursor on the drag). A finger's moves the cursor only
    /// from on it — within a fingertip of where it is drawn — so a one-finger
    /// drag elsewhere still orbits, as with the transform tools.
    func beginCursorDrag(at point: CGPoint, size: CGSize, places: Bool, modifiers: UIKeyModifierFlags) -> Bool {
        guard parent.tool == .cursor, parent.scene.mode == .object || parent.scene.mode == .edit,
              size.width > 0, size.height > 0 else { return false }
        let scene = parent.scene
        let view = parent.camera.snapView(size)
        if places {
            guard cursorTap(at: point, size: size) else { return false }
        } else {
            guard cursorRefusal() == nil, let s = view.project(scene.cursor),
                  simd_distance(s, pointer(point)) <= GeometrySnap.radius else { return false }
        }
        // Snapping as Blender's translate snaps, to the header's Snap Target
        // elements, on every object (CTX_CURSOR excludes none) — but the one
        // being edited where Blender's snap meets a mesh of it the mirror
        // does not hold (the cursor transform snaps to the final geometry,
        // `CursorTool.dragExcluded`). Built whether or not snapping is on at
        // the press: Ctrl turns it on and off as the drag goes.
        let excluded = CursorTool.dragExcluded(edited: scene.mode == .edit ? scene.active : nil)
        let targets = GeometrySnap.Targets(objects: scene.objects, view: view, elements: scene.tools.elements,
                                           excludedObjects: excluded.ids, occlusion: !parent.options.xray)
        cursorDrag = CursorDrag(start: scene.cursor, current: scene.cursor,
                                snap: targets.isEmpty ? nil : targets, view: view, excludedReason: excluded.reason)
        scene.cursorPreview = scene.cursor
        return true
    }

    func updateCursorDrag(to point: CGPoint, modifiers: UIKeyModifierFlags = []) {
        guard var drag = cursorDrag else { return }
        let camera = parent.camera
        // The header's Snap, inverted while Ctrl is held, read on this move.
        let snapping = parent.scene.tools.useSnap != modifiers.contains(.control)
        guard let moved = CursorTool.dragTarget(start: drag.start, pointer: pointer(point), view: drag.view,
                                                eye: camera.eye, forward: simd_normalize(camera.target - camera.eye),
                                                orthographic: camera.isOrthographic,
                                                snap: snapping ? drag.snap : nil) else { return }
        drag.current = moved.location
        cursorDrag = drag
        parent.scene.cursorPreview = moved.location
        let d = moved.location - drag.start
        var readout = String(format: "Move  %.4f, %.4f, %.4f", d.x, d.y, d.z)
            + (moved.hit.map { "  snapped to \($0.kind.label)" } ?? "")
        if snapping, let note = CursorTool.snapNote(elements: parent.scene.tools.elements) { readout += "  " + note }
        if snapping, let why = drag.excludedReason { readout += "  " + why }
        parent.scene.transformReadout = readout
    }

    /// The drag's end: Blender's own `transform.translate` of the cursor, by
    /// what the preview showed, as the step "Move" (Blender's).
    func endCursorDrag(cancelled: Bool = false) {
        guard let drag = cursorDrag else { return }
        cursorDrag = nil
        parent.scene.transformReadout = nil
        defer { parent.scene.cursorPreview = nil }
        guard !cancelled, simd_distance(drag.start, drag.current) > 0,
              let python = CursorTool.dragPython(from: drag.start, to: drag.current) else { return }
        parent.bridge?.run(python, undo: CursorTool.dragUndo)
    }

    // MARK: Measure

    /// What the ruler snaps to now: Blender's snap cursor's elements, nothing
    /// of the object being edited while a modifier rebuilds what is drawn of
    /// it (RulerTool.excluded).
    private func rulerTargets(_ view: GeometrySnap.View) -> GeometrySnap.Targets? {
        let scene = parent.scene
        let edited = scene.mode == .edit ? scene.active : nil
        let targets = GeometrySnap.Targets(objects: scene.objects, view: view,
                                           elements: RulerTool.elements(snapTool: scene.snapElementsTool,
                                                                        scene: scene.tools.elements),
                                           excludedObjects: RulerTool.excluded(scene.objects, edited: edited).ids,
                                           occlusion: !parent.options.xray, radius: RulerTool.snapDistance)
        return targets.isEmpty ? nil : targets
    }

    /// Whether the ruler snaps on this move: the header's Snap, inverted while
    /// Ctrl is held, as Blender's snap cursor reads it.
    private func rulerSnapping(_ modifiers: UIKeyModifierFlags) -> Bool {
        parent.scene.tools.useSnap != modifiers.contains(.control)
    }

    /// A press with the Measure tool: a ruler's end taken, an angle point put
    /// on a ruler's line, or a new ruler started (RulerTool.begin).
    func beginRulerDrag(at point: CGPoint, size: CGSize, modifiers: UIKeyModifierFlags) -> Bool {
        guard parent.tool == .measure, size.width > 0, size.height > 0 else { return false }
        let scene = parent.scene
        let camera = parent.camera
        let view = camera.snapView(size)
        let snapping = rulerSnapping(modifiers)
        let targets = rulerTargets(view)
        let forward = simd_normalize(camera.target - camera.eye)
        var rulers = scene.rulers
        guard let drag = RulerTool.begin(&rulers, at: pointer(point), project: { view.project($0) },
                                         placeNew: { p in
            RulerTool.place(pointer: p, depth: .zero, snap: snapping ? targets : nil, cursor: scene.cursor,
                            view: view, eye: camera.eye, forward: forward,
                            orthographic: camera.isOrthographic)?.point
        }) else { return false }
        scene.rulers = rulers
        scene.activeRuler = drag.ruler
        rulerDrag = RulerDrag(drag: drag, view: view, targets: targets)
        // An angle point is put under the pointer at once, unsnapped
        // (`gizmo_ruler_invoke`'s own move).
        if drag.fresh { updateRulerDrag(to: point, modifiers: modifiers) }
        return true
    }

    func updateRulerDrag(to point: CGPoint, modifiers: UIKeyModifierFlags) {
        guard var state = rulerDrag, state.drag.ruler < parent.scene.rulers.count else { return }
        let camera = parent.camera
        let snap = state.drag.fresh || !rulerSnapping(modifiers) ? nil : state.targets
        guard let placed = RulerTool.place(pointer: pointer(point), depth: state.drag.start, snap: snap,
                                           cursor: parent.scene.cursor, view: state.view, eye: camera.eye,
                                           forward: simd_normalize(camera.target - camera.eye),
                                           orthographic: camera.isOrthographic) else { return }
        parent.scene.rulers[state.drag.ruler].points[state.drag.point] = placed.point
        if state.drag.point != 1, !parent.scene.rulers[state.drag.ruler].usesAngle {
            parent.scene.rulers[state.drag.ruler].points[1] =
                (parent.scene.rulers[state.drag.ruler].points[0] + parent.scene.rulers[state.drag.ruler].points[2]) / 2
        }
        state.drag.fresh = false
        rulerDrag = state
        parent.scene.transformReadout = RulerTool.label + "  "
            + parent.scene.rulers[state.drag.ruler].text(units: parent.scene.units)
            + (placed.hit.map { "  snapped to \($0.kind.label)" } ?? "")
    }

    func endRulerDrag() {
        rulerDrag = nil
        parent.scene.transformReadout = nil
    }

    /// A tap with the Measure tool: the ruler under it becomes the active one
    /// (Ruler Remove's); a tap on nothing leaves it (`RulerTool.tap`).
    func rulerTap(at point: CGPoint, size: CGSize) {
        let view = parent.camera.snapView(size)
        var rulers = parent.scene.rulers
        let active = RulerTool.tap(&rulers, active: parent.scene.activeRuler, at: pointer(point),
                                   project: { view.project($0) })
        if rulers != parent.scene.rulers { parent.scene.rulers = rulers }
        if active != parent.scene.activeRuler { parent.scene.activeRuler = active }
    }
}

/// What the Measure tool's bar, the keyboard and the DEBUG hook share.
enum MeasureActions {
    /// Ruler Remove: the active ruler goes, or its angle when its angle point
    /// was the part last pressed (Blender's X and Delete with the Measure
    /// tool, `view3d.ruler_remove`; `RulerTool.remove`).
    static func remove(_ scene: BKScene) {
        var rulers = scene.rulers
        var active = scene.activeRuler
        RulerTool.remove(&rulers, active: &active)
        if rulers != scene.rulers { scene.rulers = rulers }
        if active != scene.activeRuler { scene.activeRuler = active }
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
    /// `-measure-ops <tokens>`: the Cursor tool, the Measure tool and Edit
    /// Mode's overlays, driven through the calls a finger and a Pencil make —
    /// `cursorTap`, `beginCursorDrag` / `updateCursorDrag` / `endCursorDrag`,
    /// `beginRulerDrag` / `updateRulerDrag` / `endRulerDrag`, `rulerTap` and
    /// `MeasureActions` — so what is tested is the tools' own path to Blender.
    /// Tokens, separated by `|`:
    ///
    /// - `tool:cursor`, `tool:measure`, `tool:select` — the tool in hand;
    /// - `depth:on|off`, `orient:NONE|VIEW|XFORM|GEOM` — the Cursor's bar;
    /// - `snap:on|off` — the header's Snap; `ctrl:on|off` — Ctrl held;
    /// - `tap:<p>`; `drag:<p>><p>[><p>…]` a finger's drag, `pencil:<p>><p>…`
    ///   a Pencil's, `<p>` a fraction of the view `x,y` or a place `@x,y,z`,
    ///   `^<p>` reached with Ctrl held;
    /// - `remove` — Ruler Remove; `py:<base64>` — a line of Python; `cap:<base64>`
    ///   — what a script prints, read without a step; `glyph` — the 3D
    ///   cursor's axes as the renderer draws them (CursorGlyph);
    /// - `ortho:on|off`, `view:top|front|…|orbit:<az>,<el>,<dist>`;
    /// - `undo`, `redo`, `state`, `pause:<seconds>`.
    ///
    /// After every token it prints Blender's cursor (location, rotation,
    /// mode), the mirror's, the Cursor tool's settings as Blender holds them,
    /// the rulers and their text, and the overlays' statistics and labels.
    func measureLaunchIfRequested(tries: Int = 120) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let spec = value("-measure-ops") else { return }
        guard tries > 0 else { print("[bk] measure-ops: never ready"); fflush(stdout); return }
        guard let view, view.bounds.width > 0, let bridge = parent.bridge, !bridge.isRunningScript,
              bridge.usesRealBlender
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.measureLaunchIfRequested(tries: tries - 1) }
            return
        }
        let tokens = spec.split(separator: "|").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.measureToken(tokens, 0, tool: nil, ctrl: false, view: view, bridge: bridge)
        }
    }

    private func measurePoint(_ text: String, size: CGSize) -> CGPoint? {
        if text == "@cursor" {
            let vp = parent.camera.viewProjection(aspect: Float(size.width / size.height))
            return BoxSelect.project(parent.scene.cursor, viewProjection: vp, size: size)
        }
        if text.hasPrefix("@") {
            let xyz = text.dropFirst().split(separator: ",").compactMap { Float($0) }
            guard xyz.count == 3 else { return nil }
            let vp = parent.camera.viewProjection(aspect: Float(size.width / size.height))
            return BoxSelect.project(SIMD3(xyz[0], xyz[1], xyz[2]), viewProjection: vp, size: size)
        }
        let xy = text.split(separator: ",").compactMap { Double($0) }
        return xy.count == 2 ? CGPoint(x: CGFloat(xy[0]) * size.width, y: CGFloat(xy[1]) * size.height) : nil
    }

    private func measureState(_ bridge: BpyBridge, size: CGSize) -> String {
        let scene = parent.scene
        let blender = bridge.capture("""
            _bk_c = bpy.context.scene.cursor
            print('loc=%.6f,%.6f,%.6f mode=%s euler=%.6f,%.6f,%.6f quat=%.6f,%.6f,%.6f,%.6f axisangle=%.6f,%.6f,%.6f,%.6f' % (tuple(_bk_c.location) + (_bk_c.rotation_mode,) + tuple(_bk_c.rotation_euler) + tuple(_bk_c.rotation_quaternion) + tuple(_bk_c.rotation_axis_angle)))
            """) ?? "?"
        let s = scene.cursorState
        var out = "Blender cursor \(blender); mirror loc \(scene.cursor), Surface Project \(s.surfaceProject), "
            + "Orientation \(s.orientation.label), mode \(s.rotationMode)"
        if !scene.rulers.isEmpty {
            out += "; rulers " + scene.rulers.enumerated().map { i, r in
                let p = r.points.map { String(format: "(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) }
                return "#\(i)\(i == scene.activeRuler ? "*" : "") \(r.usesAngle ? "angle" : "length") "
                    + "\(r.usesAngle ? p.joined(separator: " ") : p[0] + " " + p[2]) = \(r.text(units: scene.units))"
            }.joined(separator: "; ")
        }
        if scene.mode == .edit, let check = bridge.capture("""
            import bmesh
            _bk_b = bmesh.from_edit_mesh(bpy.context.object.data)
            print('bmesh: %d/%d/%d selected %d/%d/%d; lengths %s' % (len(_bk_b.verts), len(_bk_b.edges), len(_bk_b.faces), sum(v.select for v in _bk_b.verts), sum(e.select for e in _bk_b.edges), sum(f.select for f in _bk_b.faces), sorted(round(e.calc_length(), 4) for e in _bk_b.edges if e.select)[:6]))
            """) {
            out += "; " + check
        }
        if let m = scene.editMeasurements {
            if let st = m.statistics { out += "; Statistics " + st.rows.map { "\($0.label) \($0.value)" }.joined(separator: ", ") }
            let labels = m.labels(units: scene.units, viewProjection: parent.camera.viewProjection(aspect: Float(size.width / size.height)),
                                  overlays: parent.options.measure)
            out += "; \(labels.count) labels: " + labels.prefix(8).map { "\($0.kind) \($0.text)" }.joined(separator: ", ")
            if let cage = m.cage { out += "; cage \(cage)" }
            if let note = m.thinningNote { out += "; note: \(note)" }
        }
        out += "; banner: " + (bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")
        return out
    }

    private func measureToken(_ tokens: [String], _ index: Int, tool picked: ActiveTool?, ctrl: Bool,
                              view: MTKView, bridge: BpyBridge) {
        guard index < tokens.count else { print("[bk] measure-ops: done"); fflush(stdout); return }
        let token = tokens[index]
        var picked = picked
        var ctrl = ctrl
        if let picked { parent.tool = picked }
        let size = view.bounds.size
        let modifiers: UIKeyModifierFlags = ctrl ? .control : []
        var said = ""
        var delay = 0.6
        switch token {
        case _ where token.hasPrefix("pause:"):
            delay = Double(token.dropFirst("pause:".count)) ?? 0.5
            said = "waiting \(delay) s"
        case _ where token.hasPrefix("tool:"):
            if let t = ActiveTool(rawValue: String(token.dropFirst("tool:".count))) {
                parent.tool = t
                picked = t
                said = "tool \(t.label)"
            }
        case "depth:on", "depth:off":
            bridge.run(CursorTool.settingsPython(surfaceProject: token == "depth:on"))
            said = "Surface Project \(token == "depth:on" ? "on" : "off")"
        case _ where token.hasPrefix("orient:"):
            if let o = CursorTool.Orientation(rawValue: String(token.dropFirst("orient:".count))) {
                bridge.run(CursorTool.settingsPython(orientation: o))
                said = "Orientation \(o.label)"
            }
        case "snap:on", "snap:off":
            bridge.run(ToolsBpy.useSnap(token == "snap:on"))
            said = "Snap \(token == "snap:on" ? "on" : "off")"
        case "ctrl:on", "ctrl:off":
            ctrl = token == "ctrl:on"
            said = "Ctrl \(ctrl ? "held" : "up")"
        case "ortho:on", "ortho:off":
            parent.camera.isOrthographic = token == "ortho:on"
            said = parent.camera.isOrthographic ? "orthographic" : "perspective"
        case _ where token.hasPrefix("view:"):
            let name = String(token.dropFirst("view:".count))
            if let viewpoint = ViewportCamera.Viewpoint(rawValue: name) {
                parent.camera.snap(to: viewpoint)
                said = "view \(name), axis aligned \(parent.camera.isAxisAligned)"
            } else if name.hasPrefix("orbit:") {
                let v = name.dropFirst("orbit:".count).split(separator: ",").compactMap { Float($0) }
                if v.count == 3 {
                    var camera = ViewportCamera()
                    camera.azimuth = v[0] * .pi / 180
                    camera.elevation = v[1] * .pi / 180
                    camera.distance = v[2]
                    parent.camera = camera
                    said = "orbit \(v)"
                }
            }
            said += String(format: "; eye (%.4f, %.4f, %.4f) target (%.4f, %.4f, %.4f)", parent.camera.eye.x,
                           parent.camera.eye.y, parent.camera.eye.z, parent.camera.target.x,
                           parent.camera.target.y, parent.camera.target.z)
        case _ where token.hasPrefix("tap:"):
            guard let p = measurePoint(String(token.dropFirst("tap:".count)), size: size) else { said = "bad point"; break }
            if parent.tool == .measure {
                rulerTap(at: p, size: size)
                said = "ruler tap: active \(parent.scene.activeRuler.map(String.init) ?? "none")"
            } else {
                let ok = cursorTap(at: p, size: size)
                said = "cursor tap at (\(Int(p.x)), \(Int(p.y))) " + (ok ? "placed" : "REFUSED")
                    + "; call: " + (bridge.lastOutcome?.python.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "-")
            }
        case _ where token.hasPrefix("drag:") || token.hasPrefix("pencil:"):
            let pencil = token.hasPrefix("pencil:")
            // A point written `^…` is reached with Ctrl held down (pressed or
            // released mid-drag, as a keyboard's is); the rest with Ctrl as
            // the `ctrl:` token left it.
            let parts = token.split(separator: ":", maxSplits: 1)[1].split(separator: ">").map(String.init)
            let steps: [(point: CGPoint, modifiers: UIKeyModifierFlags)] = parts.compactMap { part in
                let held = part.hasPrefix("^")
                guard let p = measurePoint(held ? String(part.dropFirst()) : part, size: size) else { return nil }
                return (p, held ? modifiers.union(.control) : modifiers)
            }
            let points = steps.map(\.point)
            guard points.count >= 2 else { said = "bad drag"; break }
            var began = false
            if parent.tool == .measure {
                began = beginRulerDrag(at: points[0], size: size, modifiers: steps[0].modifiers)
                if began {
                    for step in steps.dropFirst() { updateRulerDrag(to: step.point, modifiers: step.modifiers) }
                    said = "ruler drag: " + (parent.scene.transformReadout ?? "")
                    endRulerDrag()
                }
            } else {
                began = beginCursorDrag(at: points[0], size: size, places: pencil, modifiers: steps[0].modifiers)
                if began {
                    for step in steps.dropFirst() {
                        updateCursorDrag(to: step.point, modifiers: step.modifiers)
                        print("[bk]   step\(step.modifiers.contains(.control) ? " (Ctrl)" : ""): "
                              + (parent.scene.transformReadout ?? ""))
                    }
                    said = "cursor drag: " + (parent.scene.transformReadout ?? "") + String(
                        format: "; preview (%.6f, %.6f, %.6f)", parent.scene.cursorPreview?.x ?? .nan,
                        parent.scene.cursorPreview?.y ?? .nan, parent.scene.cursorPreview?.z ?? .nan)
                    endCursorDrag()
                    said += "; commit: " + (bridge.lastOutcome?.python ?? "-")
                }
            }
            if !began { said = "the drag did not start (an orbit)" }
        case "global:on", "global:off":
            // The Sidebar's Global / Local, which the overlays read too.
            UserDefaults.standard.set(token == "global:off", forKey: "bl_sidebar_item_local")
            said = token == "global:on" ? "Global" : "Local"
        case "remove":
            MeasureActions.remove(parent.scene)
            said = "Ruler Remove: \(parent.scene.rulers.count) left"
        case _ where token.hasPrefix("py:"):
            if let data = Data(base64Encoded: String(token.dropFirst(3))), let code = String(data: data, encoding: .utf8) {
                let outcome = bridge.run(code)
                said = outcome.succeeded ? "ran" : "FAILED \(outcome.error ?? "")"
            }
        case _ where token.hasPrefix("cap:"):
            // What a script prints, read without a step (Blender's own state).
            if let data = Data(base64Encoded: String(token.dropFirst(4))), let code = String(data: data, encoding: .utf8) {
                said = "printed: " + (bridge.capture(code)?.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "nil")
            }
        case "glyph":
            // The 3D cursor's lines as the renderer draws them (CursorGlyph):
            // its X axis's outer end, from the cursor, and the rotation used.
            let view = OverlayView(camera: parent.camera, size: size)
            let lines = CursorGlyph.lines(location: parent.scene.cursorPreview ?? parent.scene.cursor,
                                          rotation: CursorGlyph.rotation(parent.scene.cursorState), view: view)
            let c = parent.scene.cursor
            func axis(_ i: Int) -> String {
                guard lines.count > 8 * i else { return "-" }
                let d = simd_normalize(lines[8 * i].position - c)
                return String(format: "(%.4f, %.4f, %.4f)", d.x, d.y, d.z)
            }
            let q = parent.scene.cursorState.rotation
            said = "cursor drawn with X \(axis(0)) Y \(axis(1)) Z \(axis(2)), "
                + String(format: "rotation (w %.4f, x %.4f, y %.4f, z %.4f), %d vertices", q.real, q.imag.x, q.imag.y,
                         q.imag.z, lines.count)
        case "undo": bridge.debugSession.performUndo(); said = "undo"
        case "redo": bridge.debugSession.performRedo(); said = "redo"
        case "state": break
        default: said = "no such token"
        }
        print("[bk] measure-ops \(token): \(said)")
        // The overlays' read waits for the workspace's refresh; give it a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            print("[bk]   \(self.measureState(bridge, size: size))")
            fflush(stdout)
            self.measureToken(tokens, index + 1, tool: picked, ctrl: ctrl, view: view, bridge: bridge)
        }
    }
}
#endif
