import SwiftUI
import UIKit
import simd

// Blender's G, R and S: the selection moves, turns or scales as the pointer
// moves, from where it was when the key went down, until a click, Return or
// Space confirms and Escape or a right-click puts everything back
// (`transform.translate`, `rotate`, `resize` from the keymap, 5.2.1). X, Y and
// Z hold it to an axis, Shift with one to the plane across it, pressed again
// for the other orientation; numbers typed set it exactly; Shift held moves
// it a tenth as far (PRECISION). G, R or S during another starts that one
// over from where the selection was.
//
// These keys used to pick the Move, Rotate and Scale tools, which is not what
// they do in Blender: there the toolbar's tools are the gizmos, and the keys
// are the transform itself (the user: "go see how real blender be like").
//
// The drag is the gizmo's own (`TransformGizmo.Session`): the same preview,
// snapping, proportional editing and mirror, the same rollback, and the same
// commit — one operator the redo panel adjusts. Only what steers it differs.
// Without a pointer (a finger on an iPad) a drag anywhere steers it and a tap
// confirms; the bar over the 3D Viewport has X, Y, Z, Cancel and Confirm.

/// G, R or S as it runs: what was typed and pressed (`ModalTransformInput`),
/// where the pointer is, and the drag as it began.
struct ModalDrive {
    var input: ModalTransformInput
    /// The session as it began, unconstrained, in the scene's orientation:
    /// X, Y and Z retarget from it (`TransformGizmo.Session.retargeted`).
    var base: TransformGizmo.Session
    /// Where the transform is measured from.
    var start: CGPoint
    /// Where it is measured to: the pointer, or where a finger's drags have
    /// taken it. Shift moves it a tenth as far as the pointer moves.
    var pointer: CGPoint
    /// Begun with no pointer over the view (a menu row, a key with the
    /// pointer elsewhere): the first pointer to arrive is the start, so
    /// nothing jumps to it.
    var startPending: Bool
    var lastHover: CGPoint?
    /// A finger's drag: its translation last time.
    var dragLast: CGPoint = .zero
    /// Ctrl held: the magnet the other way round (SNAP_INV_ON), until it is
    /// let go (SNAP_INV_OFF). The on-screen Ctrl counts as held.
    var snapInverted = false
    /// G G in Edit Mode: Edge Slide or Vertex Slide (ModalSlide.swift).
    var slide: SlideDrive?
    /// Page Up or Page Down changed the proportional reach (`base` holds it).
    var resized = false
}

extension TransformGizmo.Mode {
    var modalMode: ModalTransformInput.Mode {
        switch self {
        case .translate: return .translate
        case .rotate:    return .rotate
        case .scale:     return .scale
        }
    }
}

extension MetalViewportView.Coordinator {

    /// The 3D View G, R and S act in: the one with the keyboard, else the
    /// one on screen with Blender's Tab (the Layout workspace's, not the
    /// Scripting tab's preview).
    static var forTransform: MetalViewportView.Coordinator? {
        let shown = live.allObjects.filter { c in
            guard let view = c.view else { return false }
            return view.window != nil && view.bounds.width > 0 && view.bounds.height > 0
        }
        return shown.first { $0.view?.isFirstResponder == true }
            ?? shown.first { $0.parent.onToggleEditing != nil }
            ?? shown.first
    }

    // MARK: beginning

    /// G, R or S: begins it, or during another switches to it.
    @discardableResult
    func beginModalTransform(_ mode: TransformGizmo.Mode) -> Bool {
        if modal != nil {
            modalSwitch(mode)
            return true
        }
        return startModal(mode, input: ModalTransformInput(mode: mode.modalMode),
                          start: nil, pointer: nil, lastHover: nil)
    }

    /// Ctrl+M, Interactive Mirror (`transform.mirror` from the keymap): the
    /// selection waits for X, Y or Z and flips along it about the pivot, a
    /// click or Return confirming. Run as a Scale's session that never
    /// follows the pointer (INPUT_NONE): a mirror is a scale by -1. Not
    /// during another transform, where Ctrl+M is no key of the modal map.
    @discardableResult
    func beginModalMirror() -> Bool {
        guard modal == nil else { return false }
        return startModal(.scale, input: ModalTransformInput(mode: .mirror),
                          start: nil, pointer: nil, lastHover: nil)
    }

    /// The drag begun from `start` (nil: the pointer's place, or a stand-in
    /// until one arrives).
    private func startModal(_ mode: TransformGizmo.Mode, input: ModalTransformInput, start: CGPoint?,
                            pointer: CGPoint?, lastHover: CGPoint?, snapInverted: Bool = false) -> Bool {
        guard let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0,
              gizmo == nil, regionGesture == nil, cursorDrag == nil, rulerDrag == nil,
              liveCamera == nil, !sculptInput.isStroking,
              parent.scene.mode == .object || parent.scene.mode == .edit
        else { return false }
        let size = view.bounds.size
        guard let g = TransformGizmo.make(mode: mode, scene: parent.scene, options: parent.options,
                                          camera: parent.camera, size: size)
        else {
            // Blender's does nothing with nothing to act on; a finger that
            // chose Move from a menu is told why.
            parent.bridge?.showReport(input.mode.label, parent.scene.mode == .edit
                ? "Nothing is selected. Select a vertex, an edge or a face first."
                : "Nothing is selected. Tap an object first.")
            return false
        }
        let projection = TransformGizmo.Projection(camera: parent.camera, size: size)
        let here = lastPointer.flatMap { view.bounds.contains($0) ? $0 : nil }
        let from = start ?? here ?? Self.standInStart(g, projection: projection, size: size)
        gizmo = TransformGizmo.beginSession(handle: .screen, at: from, gizmo: g, scene: parent.scene,
                                            camera: parent.camera, size: size, options: parent.options,
                                            wireframe: parent.shading == .wireframe,
                                            mirroring: input.mode == .mirror)
        gizmoResult = nil
        // A curve's or a lattice's points: Blender refused (the banner says
        // why) and there is nothing to steer.
        guard beginPointDragIfAny(), let base = gizmo else { return false }
        modal = ModalDrive(input: input, base: base, start: from, pointer: pointer ?? from,
                           startPending: start == nil && here == nil, lastHover: lastHover ?? here,
                           snapInverted: snapInverted || ScreenModifiers.shared.control)
        gizmo = base.invertingSnap(modal?.snapInverted ?? false)
        renderer?.gizmoHighlight = nil
        parent.scene.hoveredID = nil
        parent.scene.clearViewportDrag()
        if let mtk = view as? ViewportMTKView {
            mtk.modal = self
            mtk.takeKeyboard()
        }
        if input.constraint != .none { retargetModal() }
        modalUpdate(presenting: input.isTyping || (pointer.map { $0 != from } ?? false))
        return true
    }

    /// Where a drag with no pointer starts: off the pivot to its right, so a
    /// turn has an angle to measure and a scale a distance.
    private static func standInStart(_ g: TransformGizmo, projection: TransformGizmo.Projection,
                                     size: CGSize) -> CGPoint {
        let centre = projection.project(g.origin) ?? CGPoint(x: size.width / 2, y: size.height / 2)
        // A quarter of the view at most, so it stays on an iPhone's.
        let reach = min(120, size.width / 4)
        let x = centre.x + reach < size.width - 20 ? centre.x + reach : centre.x - reach
        return CGPoint(x: min(max(x, 20), size.width - 20), y: min(max(centre.y, 20), size.height - 20))
    }

    // MARK: steering

    /// The pointer over the view (nil: it left).
    func modalHover(at point: CGPoint?, modifiers: UIKeyModifierFlags) {
        guard var drive = modal else { return }
        guard let point else {
            drive.lastHover = nil
            modal = drive
            return
        }
        if drive.startPending {
            // The first pointer: the drag starts here.
            drive.startPending = false
            drive.start = point
            drive.pointer = point
            drive.lastHover = point
            drive.base = drive.base.retargeted(start: point)
            gizmo = gizmo?.retargeted(start: point)
            modal = drive
            modalUpdate(presenting: drive.input.isTyping)
            return
        }
        let held = ScreenModifiers.shared.merged(modifiers)
        if held.contains(.control) != drive.snapInverted {
            drive.snapInverted = held.contains(.control)
            gizmo = gizmo?.invertingSnap(drive.snapInverted)
        }
        if let last = drive.lastHover {
            let k: CGFloat = held.contains(.shift) ? 0.1 : 1
            drive.pointer.x += (point.x - last.x) * k
            drive.pointer.y += (point.y - last.y) * k
        }
        drive.lastHover = point
        modal = drive
        modalUpdate(presenting: true)
    }

    /// A finger's or a Pencil's drag while G, R or S runs: it moves the
    /// pointer the transform follows, from wherever it is. True when it took
    /// the gesture.
    func modalDrag(_ g: UIPanGestureRecognizer) -> Bool {
        guard var drive = modal, let view else { return false }
        let t = g.translation(in: view)
        switch g.state {
        case .began, .changed:
            if g.state == .began { drive.dragLast = .zero }
            let held = ScreenModifiers.shared.merged(g.modifierFlags)
            if held.contains(.control) != drive.snapInverted {
                drive.snapInverted = held.contains(.control)
                gizmo = gizmo?.invertingSnap(drive.snapInverted)
            }
            let k: CGFloat = held.contains(.shift) ? 0.1 : 1
            drive.pointer.x += (t.x - drive.dragLast.x) * k
            drive.pointer.y += (t.y - drive.dragLast.y) * k
            drive.dragLast = t
            drive.startPending = false
            modal = drive
            modalUpdate(presenting: true)
        default:
            drive.dragLast = .zero
            modal = drive
        }
        return true
    }

    /// A key of Blender's transform modal map (`ViewportMTKView.modalCommands`).
    func modalKey(_ token: String) {
        // Shift+B's box waiting or being drawn: Escape cancels it, and the
        // rest of the keys wait (ZoomRegion.swift).
        if zoomRegionPending || zoomRegionStart != nil {
            if token == "cancel" { endZoomRegion(nil) }
            return
        }
        guard modal != nil else { return }
        // Mirror changes into nothing else (`transform_mode_is_changeable`)
        // and takes no numbers.
        if modal?.input.mode == .mirror, ["g", "r", "s", "tab", "backspace"].contains(token) { return }
        switch token {
        case "confirm":   modalConfirm()
        case "cancel":    modalCancel()
        case "swallow":   break
        case "g":
            // G again during Move in a mesh's Edit Mode slides, and during a
            // slide goes back to Move (TFM_MODAL_TRANSLATE in transform.cc).
            switch modal?.input.mode {
            case .translate? where parent.scene.mode == .edit: modalSlide()
            case .edgeSlide?, .vertexSlide?:                   modalLeaveSlide()
            default:                                           modalSwitch(.translate)
            }
        case "r":
            // R again turns Rotate into Trackball and Trackball back into
            // Rotate (TFM_MODAL_ROTATE in transform.cc).
            switch modal?.input.mode {
            case .rotate?:    modalTrackball(true)
            case .trackball?: modalTrackball(false)
            default:          modalSwitch(.rotate)
            }
        case "s":         modalSwitch(.scale)
        case "propup":       modalProportionalSize(by: 1.1)
        case "propdown":     modalProportionalSize(by: 1 / 1.1)
        case "propup.fine":  modalProportionalSize(by: 1.01)
        case "propdown.fine": modalProportionalSize(by: 1 / 1.01)
        case "even", "flip", "clamp":
            // E, F and C mean something only while a slide runs.
            if modal?.slide != nil { slideToggle(token) }
        case "tab":
            modal?.input.nextValue()
            modalUpdate(presenting: true)
        case "backspace":
            modal?.input.backspace()
            modalUpdate(presenting: true)
        case "axis0", "axis1", "axis2":
            // The on-screen Shift counts as held, as it does for a tap.
            modalAxis(Int(String(token.last!))!, plane: ScreenModifiers.shared.shift)
        case "plane0", "plane1", "plane2":
            modalAxis(Int(String(token.last!))!, plane: true)
        default:
            guard token.count == 1, let c = token.first else { return }
            modal?.input.type(c)
            modalUpdate(presenting: true)
        }
    }

    /// Page Up and Page Down, the wheel and a trackpad's scroll while G, R or
    /// S runs with proportional editing on (Blender's PROPORTIONAL_SIZE_UP,
    /// _DOWN and PROPORTIONAL_SIZE, transform.cc): the reach times `factor`
    /// — 1.1 a step, 1.01 with Shift (precision), 1 + 0.005 a pixel of a
    /// trackpad's scroll — at most the view's clip end in perspective (1,000
    /// here) and within bpy's own range. The drag goes on from where it is,
    /// taken again with the new reach; the slides and Mirror have none.
    func modalProportionalSize(by factor: Float) {
        guard var drive = modal, drive.slide == nil, drive.input.mode != .mirror,
              let session = gizmo, session.points == nil, let p = session.proportional, let view else { return }
        let range = TransformToolSettings.sizeRange
        var size = p.size * factor
        size = min(size, parent.camera.isOrthographic ? range.upperBound : min(1000, range.upperBound))
        size = max(size, range.lowerBound)
        guard abs(size - p.size) > 1e-7 else { return }
        TransformGizmo.rollBack(session)
        let rebuilt = TransformGizmo.beginSession(handle: .screen, at: drive.start, gizmo: drive.base.gizmo,
                                                  scene: parent.scene, camera: parent.camera,
                                                  size: view.bounds.size, options: parent.options,
                                                  wireframe: parent.shading == .wireframe, proportionalSize: size)
        drive.base = rebuilt
        drive.resized = true
        modal = drive
        gizmo = rebuilt.invertingSnap(drive.snapInverted)
        if drive.input.constraint != .none { retargetModal() }
        modalUpdate(presenting: gizmoResult != nil || !drive.startPending || drive.input.isTyping)
    }

    /// Blender keeps the reach Page Up and Page Down gave a transform as the
    /// scene's Proportional Size, confirmed or not (`saveTransform`: "this
    /// value is being saved even if the operation is canceled").
    private func keepProportionalSize(_ drive: ModalDrive) {
        guard drive.resized, let size = drive.base.proportional?.size else { return }
        parent.bridge?.run(ToolsBpy.size(size))
    }

    /// Ctrl pressed or let go on a keyboard, with or without the pointer
    /// moving: the magnet turns the other way round while it is held.
    func modalControl(_ down: Bool) {
        guard var drive = modal else { return }
        let held = down || ScreenModifiers.shared.control
        guard held != drive.snapInverted else { return }
        drive.snapInverted = held
        modal = drive
        gizmo = gizmo?.invertingSnap(held)
        modalUpdate(presenting: !drive.startPending || drive.input.isTyping)
    }

    /// X, Y or Z, or Shift with one.
    func modalAxis(_ axis: Int, plane: Bool) {
        guard modal?.input.mode.takesConstraint == true else { return }
        modal?.input.press(axis: axis, plane: plane)
        retargetModal()
        modalUpdate(presenting: true)
    }

    /// The session held as the constraint says: its handle, and the axes of
    /// the orientation the constraint is in.
    private func retargetModal() {
        guard let drive = modal else { return }
        let base = drive.base
        defer { gizmo = gizmo?.invertingSnap(drive.snapInverted) }
        switch drive.input.constraint {
        case .none:
            gizmo = base
        case .axis(let i, let space), .plane(let i, let space):
            let (axes, orientation) = modalAxes(space, base: base)
            let g = TransformGizmo(mode: base.gizmo.mode, origin: base.gizmo.origin,
                                   axes: [axes.columns.0, axes.columns.1, axes.columns.2],
                                   radius: base.gizmo.radius)
            let frame = TransformGizmo.Frame(orientation: orientation, axes: OrientationBpy.printed(axes),
                                             viewAxes: base.frame.viewAxes)
            var handle: TransformGizmo.Handle
            if case .plane = drive.input.constraint { handle = .plane(i) } else { handle = .axis(i) }
            // A turn held to a plane turns about the plane's normal.
            if base.gizmo.mode == .rotate { handle = .axis(i) }
            gizmo = base.retargeted(handle: handle, gizmo: g, frame: frame)
        }
    }

    /// The scene's orientation, or the other one: Local when the scene's is
    /// Global, Global otherwise (`orient[O_SET]`).
    private func modalAxes(_ space: ModalTransformInput.Space,
                           base: TransformGizmo.Session) -> (simd_float3x3, TransformOrientation?) {
        let scene = simd_float3x3(base.gizmo.axes[0], base.gizmo.axes[1], base.gizmo.axes[2])
        switch space {
        case .scene:
            return (scene, base.frame.orientation)
        case .alternate:
            guard base.frame.orientation == .global else { return (matrix_identity_float3x3, .global) }
            let local = parent.scene.active.flatMap { OrientationBpy.localAxes($0.modelMatrix) }
            return (local ?? matrix_identity_float3x3, .local)
        }
    }

    /// Rotate to Trackball or back: the same turn's session, unconstrained,
    /// measured from the same start (Blender restores the selection and
    /// starts the other mode, keeping where the pointer began).
    private func modalTrackball(_ on: Bool) {
        guard var drive = modal else { return }
        let shown = gizmoResult != nil
        drive.input.switchMode(on ? .trackball : .rotate)
        modal = drive
        gizmo = drive.base.invertingSnap(drive.snapInverted)
        modalUpdate(presenting: shown || !drive.startPending || drive.input.isTyping)
    }

    /// Trackball's two angles from the pointer, as Blender's INPUT_TRACKBALL
    /// reads them (transform_input.cc): 0.01 radians for each pixel the
    /// pointer has travelled, up and down about the view's horizontal axis
    /// and across about its vertical one.
    private func trackballAngles(_ drive: ModalDrive) -> SIMD2<Float> {
        let pixels = Float(view?.contentScaleFactor ?? 2)
        return SIMD2(Float(drive.pointer.y - drive.start.y), Float(drive.pointer.x - drive.start.x))
            * 0.01 * pixels
    }

    /// Trackball's turn: about the view's horizontal axis by the first angle
    /// and its vertical by the second (`applyTrackball`: the two matrices
    /// multiplied, horizontal first). One turn about one axis in the end, so
    /// it is previewed and committed as a turn about that axis.
    static func trackballResult(_ angles: SIMD2<Float>, session: TransformGizmo.Session) -> TransformGizmo.Result {
        let view = session.frame.viewAxes
        let q = simd_quatf(angle: angles.x, axis: simd_normalize(view.columns.0))
            * simd_quatf(angle: angles.y, axis: simd_normalize(view.columns.1))
        let angle = q.angle
        guard angle > 1e-7, angle.isFinite else {
            return .rotate(axis: simd_normalize(view.columns.2), angle: 0, axisIndex: nil)
        }
        return .rotate(axis: simd_normalize(q.axis), angle: angle, axisIndex: nil)
    }

    /// Blender's header for it: the two angles in degrees.
    static func trackballReadout(_ angles: SIMD2<Float>) -> String {
        String(format: "Trackball: %.2f° %.2f°", angles.x * 180 / .pi, angles.y * 180 / .pi)
    }

    /// G, R or S during another: everything back, and the new one from the
    /// same start.
    private func modalSwitch(_ mode: TransformGizmo.Mode) {
        guard let drive = modal, drive.base.gizmo.mode != mode || drive.input.mode != mode.modalMode else { return }
        discardModalSession()
        modal = nil
        var input = drive.input
        input.switchMode(mode.modalMode)
        let started = startModal(mode, input: input, start: drive.startPending ? nil : drive.start,
                                 pointer: drive.startPending ? nil : drive.pointer, lastHover: drive.lastHover,
                                 snapInverted: drive.snapInverted)
        if !started { finishModal() }
    }

    // MARK: showing

    /// The drag to the pointer, or what was typed, shown. `presenting` false
    /// shows only the header: nothing has moved yet, and a confirm then
    /// commits nothing.
    func modalUpdate(presenting: Bool) {
        if modal?.slide != nil {
            slideUpdate()
            return
        }
        if modal?.input.mode == .mirror {
            mirrorUpdate()
            return
        }
        guard let drive = modal, let session = gizmo else { return }
        if presenting, let values = drive.input.values {
            presentGizmo(Self.typedResult(values, input: drive.input, session: session),
                         target: nil, readout: Self.typedReadout(drive.input, session: session))
        } else if presenting, drive.input.mode == .trackball {
            // Increment snapping rounds each angle to Blender's 5°.
            var angles = trackballAngles(drive)
            if let snap = session.activeSnap { angles = SIMD2(snap.angle(angles.x), snap.angle(angles.y)) }
            presentGizmo(Self.trackballResult(angles, session: session), target: nil,
                         readout: Self.trackballReadout(angles))
        } else if presenting, let raw = TransformGizmo.resolve(session, at: drive.pointer) {
            let (result, target) = TransformGizmo.snapping(raw, session: session, at: drive.pointer)
            var readout = TransformGizmo.readout(result, session: session)
            if let target { readout += "  snap \(target.kind.label)" }
            presentGizmo(result, target: target, readout: readout)
        } else if gizmoResult == nil {
            parent.scene.transformReadout = Self.typedReadout(drive.input, session: session)
        }
        drawModalOverlay()
        ModalTransformState.shared.show(.init(mode: drive.input.mode, constraint: drive.input.constraint,
                                              typing: drive.input.isTyping,
                                              canSlide: drive.input.mode == .translate && drive.base.edit != nil
                                                  && parent.bridge?.usesRealBlender == true,
                                              proportional: session.proportional != nil && session.points == nil),
                                        owner: self)
    }

    /// Interactive Mirror as it stands: flipped along the constraint, or as
    /// it was with none, under Blender's header (`applyMirror`). The pointer
    /// plays no part.
    private func mirrorUpdate() {
        guard let drive = modal, let session = gizmo else { return }
        let space = (session.frame.orientation?.label ?? "custom").lowercased()
        let header = drive.input.mirrorHeader(space: space)
        if drive.input.constraint != .none || gizmoResult != nil {
            presentGizmo(.scale(drive.input.mirrorFactors), target: nil, readout: header)
        } else {
            parent.scene.transformReadout = header
        }
        drawModalOverlay()
        ModalTransformState.shared.show(.init(mode: .mirror, constraint: drive.input.constraint, typing: false),
                                        owner: self)
    }

    /// What typed numbers amount to: metres along the constraint's axes (X,
    /// Y, Z globally with none), degrees about its axis (the view's with
    /// none), factors along its axes.
    static func typedResult(_ values: [Double], input: ModalTransformInput,
                            session: TransformGizmo.Session) -> TransformGizmo.Result {
        let g = session.gizmo
        let free = input.constraint.freeAxes
        switch input.mode {
        case .translate:
            var d = SIMD3<Float>.zero
            if input.constraint == .none {
                d = SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
            } else {
                for (k, axis) in free.enumerated() where k < values.count { d += g.axes[axis] * Float(values[k]) }
            }
            return .translate(d)
        case .rotate:
            let angle = Float(values[0]) * .pi / 180
            switch input.constraint {
            case .none:
                return .rotate(axis: simd_normalize(session.eye - g.origin), angle: angle, axisIndex: nil)
            case .axis(let i, _), .plane(let i, _):
                return .rotate(axis: g.axes[i], angle: angle, axisIndex: i)
            }
        case .scale:
            var f = SIMD3<Float>(repeating: 1)
            for (k, axis) in free.enumerated() where k < values.count { f[axis] = Float(values[k]) }
            return .scale(f)
        case .trackball:
            let a = SIMD2(Float(values[0]), Float(values.count > 1 ? values[1] : 0)) * .pi / 180
            return trackballResult(a, session: session)
        case .edgeSlide, .vertexSlide:
            // The slides are not a turn, a move or a scale of the session
            // (ModalSlide.swift shows them).
            return .translate(.zero)
        case .mirror:
            return .scale(input.mirrorFactors)
        }
    }

    /// The header while nothing has moved or a number is being typed, in
    /// the gizmo readout's words.
    static func typedReadout(_ input: ModalTransformInput, session: TransformGizmo.Session) -> String {
        let names = ["X", "Y", "Z"]
        let space = (session.frame.orientation?.label ?? "custom").lowercased()
        let shown = input.shownValues
        let held: String
        switch input.constraint {
        case .none:
            held = input.mode == .rotate ? "view" : (input.isTyping && input.mode == .translate ? "global" : "")
        case .axis(let i, _):
            held = input.mode == .rotate ? "around \(space) \(names[i])" : "along \(space) \(names[i])"
        case .plane(let i, _):
            held = input.mode == .rotate ? "around \(space) \(names[i])"
                : "in \(space) " + input.constraint.freeAxes.map { names[$0] }.joined() + " plane"
        }
        let lead: String
        switch input.mode {
        case .translate:   lead = "D:"
        case .rotate:      lead = "Rot:"
        case .scale:       lead = "S:"
        case .trackball:   lead = "Trackball:"
        case .edgeSlide:   lead = "Edge Slide:"
        case .vertexSlide: lead = "Vertex Slide:"
        case .mirror:      return input.mirrorHeader(space: space)
        }
        let values = shown.isEmpty ? input.mode.label : "\(lead) " + shown.joined(separator: " | ")
            + (input.mode == .rotate || input.mode == .trackball ? "°" : "")
        return held.isEmpty ? values : "\(values)  \(held)"
    }

    /// Blender's lines while G, R or S runs: the constraint's axis through
    /// the pivot in its colour (both axes of a plane), and for a turn or a
    /// scale a dashed line from the pivot to the pointer, with a ring where
    /// a finger has taken the pointer.
    private func drawModalOverlay() {
        guard let view, let drive = modal, let session = gizmo else { return }
        let layer: CAShapeLayer
        if let modalLayer {
            layer = modalLayer
        } else {
            layer = CAShapeLayer()
            // The axis runs on past the view's edges; the header is not
            // the view's to draw on.
            layer.masksToBounds = true
            view.layer.addSublayer(layer)
            modalLayer = layer
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = view.bounds
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let p = session.projection
        let g = session.gizmo
        var lines: [Int] = []
        switch drive.input.constraint {
        case .none: break
        case .axis(let i, _): lines = [i]
        case .plane(let i, _): lines = g.mode == .rotate ? [i] : drive.input.constraint.freeAxes
        }
        for i in lines {
            guard let (a, b) = Self.axisLine(g.origin, g.axes[i], length: g.radius * 40, projection: p) else { continue }
            let path = CGMutablePath()
            path.addLines(between: [a, b])
            let line = CAShapeLayer()
            line.path = path
            let c = TransformGizmo.axisColours[i]
            line.strokeColor = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 0.9).cgColor
            line.lineWidth = 1.5
            layer.addSublayer(line)
        }
        if g.mode != .translate, drive.input.mode != .mirror, let centre = p.project(g.origin) {
            let path = CGMutablePath()
            path.addLines(between: [centre, drive.pointer])
            let dash = CAShapeLayer()
            dash.path = path
            dash.strokeColor = UIColor(white: 0.1, alpha: 0.9).cgColor
            dash.lineWidth = 1
            dash.lineDashPattern = [4, 4]
            layer.addSublayer(dash)
            let light = CAShapeLayer()
            light.path = path
            light.strokeColor = UIColor(white: 0.95, alpha: 0.9).cgColor
            light.lineWidth = 1
            light.lineDashPattern = [4, 4]
            light.lineDashPhase = 4
            layer.addSublayer(light)
        }
        // Proportional editing's reach (`drawPropCircle`): a circle of the
        // Proportional Size about the pivot, square to the view, drawn twice
        // as Blender draws it — 3 pixels in the grid's colour darkened, then
        // 1 pixel lightened.
        if let reach = session.proportional?.size, drive.slide == nil, let centre = p.project(g.origin),
           let edge = p.project(g.origin + simd_normalize(session.frame.viewAxes.columns.0) * reach) {
            let r = hypot(edge.x - centre.x, edge.y - centre.y)
            if r.isFinite, r > 0.5, r < 100_000 {
                let path = CGPath(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r),
                                  transform: nil)
                for (width, white) in [(CGFloat(3), CGFloat(0.27)), (1, 0.41)] {
                    let ring = CAShapeLayer()
                    ring.path = path
                    ring.fillColor = nil
                    ring.strokeColor = UIColor(white: white, alpha: 1).cgColor
                    ring.lineWidth = width
                    layer.addSublayer(ring)
                }
            }
        }
        // No pointer over the view: show where the drags have taken it.
        if drive.lastHover == nil, g.mode != .translate, drive.input.mode != .mirror {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: drive.pointer.x - 7, y: drive.pointer.y - 7, width: 14, height: 14),
                               transform: nil)
            ring.fillColor = nil
            ring.strokeColor = UIColor(white: 0.95, alpha: 0.9).cgColor
            ring.lineWidth = 1.5
            layer.addSublayer(ring)
        }
        CATransaction.commit()
    }

    /// An axis through `origin` as far as it can be drawn: shortened until
    /// both ends are in front of the eye.
    static func axisLine(_ origin: SIMD3<Float>, _ axis: SIMD3<Float>, length: Float,
                         projection p: TransformGizmo.Projection) -> (CGPoint, CGPoint)? {
        var l = length
        for _ in 0..<8 {
            if let a = p.project(origin - axis * l), let b = p.project(origin + axis * l) { return (a, b) }
            l /= 4
        }
        return nil
    }

    // MARK: ending

    /// A click, a tap, Return or Space: the transform performed through
    /// Blender as the gizmo's release performs it — one step, adjustable.
    func modalConfirm() {
        guard let drive = modal else { return }
        // The selection changed while it ran (the view's update may not
        // have run since): nothing is committed, and the banner says why.
        modalGuard()
        guard modal != nil else {
            parent.bridge?.showReport(drive.input.mode.label,
                                      "The selection changed while \(drive.input.mode.label) ran, so nothing was changed.")
            return
        }
        // After the commit: the transform's own call carries its size, and
        // the scene's follows it, as `saveTransform` writes it.
        defer { keepProportionalSize(drive) }
        if drive.slide != nil {
            slideConfirm()
            finishModal()
            return
        }
        if drive.input.mode == .mirror {
            mirrorConfirm(drive)
            finishModal()
            return
        }
        endGizmo()
        finishModal()
    }

    /// Ctrl+M confirmed: Blender's `transform.mirror`, one step the redo
    /// panel adjusts. With no axis chosen nothing flipped, and nothing is
    /// sent. A curve's or a lattice's points, which Blender previewed as a
    /// scale by -1, commit that scale.
    private func mirrorConfirm(_ drive: ModalDrive) {
        guard drive.input.constraint != .none else {
            discardModalSession()
            return
        }
        if gizmo?.points != nil {
            endGizmo()
            return
        }
        endConstrainedDrag()
        defer {
            gizmo = nil
            gizmoResult = nil
            renderer?.gizmoHighlight = nil
            parent.scene.transformReadout = nil
            showSnapMarker(nil, projection: nil)
        }
        guard let session = gizmo, let bridge = parent.bridge else { return }
        TransformGizmo.commitMirror(drive.input.mirrorFactors, session: session, bridge: bridge)
    }

    /// Escape or a right-click: everything back where it was, no step.
    func modalCancel() {
        guard let drive = modal else { return }
        discardModalSession()
        keepProportionalSize(drive)
        finishModal()
    }

    /// What the transform acts on changed under it — the Outliner, the
    /// Select menu, the mode menu: Blender's own takes all input while it
    /// runs, so nothing can; here the commit would act on the new selection
    /// while the preview moved the old, so it is cancelled. Called from the
    /// view's update, which reads what it compares.
    func modalGuard() {
        guard let drive = modal else { return }
        let scene = parent.scene
        let base = drive.base
        let changed: Bool
        // Compared as `beginSession` took them: the vertices the cage has,
        // the selected objects that are visible.
        if let edit = base.edit {
            let count = edit.mesh.vertices.count
            changed = scene.mode != .edit || scene.active?.id != edit.object.id
                || scene.editSelection.vertices.filter({ $0 < count }) != edit.vertices
        } else if let points = base.points {
            changed = scene.mode != .edit || scene.active?.id != points.object.id
        } else {
            let moving = Set(scene.objects.lazy.filter { scene.selection.contains($0.id) && $0.visible }.map(\.id))
            changed = scene.mode != .object || moving != Set(base.snapshot.map(\.object.id))
        }
        if changed {
            discardModalSession()
            finishModal()
        }
    }

    /// The drag's preview put back, and Blender's previews let go.
    private func discardModalSession() {
        endConstrainedDrag()
        if let session = gizmo {
            if session.points != nil {
                parent.bridge?.cancelPointDrag()
            } else {
                TransformGizmo.rollBack(session)
            }
        }
        gizmo = nil
        gizmoResult = nil
        renderer?.gizmoHighlight = nil
        parent.scene.transformReadout = nil
        showSnapMarker(nil, projection: nil)
    }

    private func finishModal() {
        modal = nil
        modalLayer?.removeFromSuperlayer()
        modalLayer = nil
        (view as? ViewportMTKView)?.modal = nil
        ModalTransformState.shared.end(owner: self)
    }
}

/// G, R or S as the interface shows it: the bar over the 3D Viewport and the
/// status row read it; the bar's buttons reach the 3D View running it.
@MainActor @Observable
final class ModalTransformState {
    static let shared = ModalTransformState()

    struct Shown: Equatable {
        var mode: ModalTransformInput.Mode
        var constraint: ModalTransformInput.Constraint
        var typing: Bool
        /// A Move in a mesh's Edit Mode, which G turns into Edge Slide.
        var canSlide = false
        /// A slide's E, F and C: Even, Flipped, Clamp.
        var even = false
        var flipped = false
        var clamp = true
        /// Proportional editing is on: Page Up and Page Down size its reach.
        var proportional = false
    }

    private(set) var shown: Shown?
    @ObservationIgnored private weak var owner: MetalViewportView.Coordinator?

    func show(_ shown: Shown, owner: MetalViewportView.Coordinator) {
        self.owner = owner
        if self.shown != shown { self.shown = shown }
    }

    func end(owner: MetalViewportView.Coordinator) {
        guard self.owner === owner else { return }
        self.owner = nil
        shown = nil
    }

    /// The bar's X, Y and Z: with the on-screen Shift on, the plane across.
    func axis(_ i: Int) { owner?.modalAxis(i, plane: ScreenModifiers.shared.shift) }
    func confirm() { owner?.modalConfirm() }
    func cancel() { owner?.modalCancel() }
    /// The bar's Trackball and Rotate: R pressed again.
    func toggleTrackball() { owner?.modalKey("r") }
    /// The bar's Edge Slide and Move: G pressed again.
    func toggleSlide() { owner?.modalKey("g") }
    /// The bar's Even, Flipped and Clamp during a slide: E, F and C.
    func slideOption(_ token: String) { owner?.modalKey(token) }

    /// G, R or S from a key or a menu row (Object ▸ Transform, Mesh ▸
    /// Transform): in the 3D View that has the keyboard.
    static func begin(_ mode: TransformGizmo.Mode) {
        MetalViewportView.Coordinator.forTransform?.beginModalTransform(mode)
    }

    /// Ctrl+M from a key or Mirror ▸ Interactive Mirror.
    static func beginMirror() {
        MetalViewportView.Coordinator.forTransform?.beginModalMirror()
    }
}

/// The bar over the 3D Viewport while G, R or S runs, for a finger with no
/// keyboard: the transform's name, X, Y and Z (the plane across one with the
/// on-screen Shift on, as Shift+X), Cancel and Confirm. A drag anywhere in the
/// view steers it and a tap confirms; the status row says so.
struct ModalTransformBar: View {
    var state = ModalTransformState.shared

    var body: some View {
        if let shown = state.shown {
            // An iPhone's 3D Viewport is narrower than the whole bar: its
            // name goes, then the buttons' words.
            ViewThatFits(in: .horizontal) {
                bar(shown, named: true, worded: true)
                bar(shown, named: false, worded: true)
                bar(shown, named: false, worded: false)
            }
            .padding(.horizontal, 8)
        }
    }

    private func bar(_ shown: Shown, named: Bool, worded: Bool) -> some View {
        HStack(spacing: 6) {
            if named {
                Text(shown.mode.label)
                    .font(BTheme.Font.ui(13, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            if shown.mode.takesConstraint {
                ForEach(0..<3, id: \.self) { i in axisButton(i, shown: shown) }
            }
            // R again and G again, for a finger with no keyboard: Blender's
            // names for what they turn it into.
            switch shown.mode {
            case .rotate:
                barButton("Trackball", icon: "rotate.3d", worded: worded) { state.toggleTrackball() }
            case .trackball:
                barButton("Rotate", icon: "arrow.clockwise", worded: worded) { state.toggleTrackball() }
            case .translate where shown.canSlide:
                barButton("Edge Slide", icon: "arrow.left.and.right.square", worded: worded) { state.toggleSlide() }
            case .edgeSlide, .vertexSlide:
                barButton("Move", icon: "arrow.up.and.down.and.arrow.left.and.right", worded: worded) {
                    state.toggleSlide()
                }
                barButton("Even", icon: "equal.square", worded: worded, lit: shown.even) { state.slideOption("even") }
                barButton("Flipped", icon: "arrow.left.arrow.right", worded: worded, lit: shown.flipped) {
                    state.slideOption("flip")
                }
                barButton("Clamp", icon: "arrow.right.to.line", worded: worded, lit: shown.clamp) {
                    state.slideOption("clamp")
                }
            default:
                EmptyView()
            }
            Divider().frame(height: 26)
            barButton("Cancel", icon: "xmark", worded: worded) { state.cancel() }
            barButton("Confirm", icon: "checkmark", worded: worded, prominent: true) { state.confirm() }
        }
        .padding(6)
        .background(BTheme.header.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BTheme.textDim.opacity(0.35), lineWidth: 1))
        .fixedSize()
    }

    private func axisButton(_ i: Int, shown: Shown) -> some View {
        let c = TransformGizmo.axisColours[i]
        let colour = Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        let held = shown.constraint.letter == i
        var plane = false
        if case .plane = shown.constraint { plane = true }
        return Button { state.axis(i) } label: {
            Text(["X", "Y", "Z"][i])
                .font(BTheme.Font.ui(14, weight: .semibold))
                .foregroundStyle(held && !plane ? Color.white : colour)
                .frame(width: 40, height: 36)
                .background(held && !plane ? colour : BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                .overlay(RoundedRectangle(cornerRadius: BTheme.Metric.corner)
                    .stroke(colour, lineWidth: held && plane ? 2 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(held ? (plane ? "\(["X", "Y", "Z"][i]) plane, on" : "\(["X", "Y", "Z"][i]) axis, on")
                                 : "\(["X", "Y", "Z"][i]) axis")
    }

    private typealias Shown = ModalTransformState.Shown

    /// `lit`: an option that is on, blue as Blender draws a toggle that is.
    private func barButton(_ title: String, icon: String, worded: Bool, prominent: Bool = false, lit: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                if worded { Text(title).font(BTheme.Font.ui(13)) }
            }
            .padding(.horizontal, worded ? 10 : 0)
            .frame(minWidth: 40, minHeight: 36)
            .foregroundStyle(prominent || lit ? Color.white : BTheme.text)
            .background(prominent ? BTheme.active : lit ? PopupMenuOverlay.highlight : BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
    /// `ctrl:down` / `ctrl:up` press and let go of Ctrl.
    /// `-modal-ops "g|hover:400,300|key:axis0|key:2|key:confirm|dump"`: G, R
    /// and S driven through the calls the keys, the pointer and a finger
    /// make — `beginModalTransform`, `modalHover`, a drag's pointer step,
    /// `modalKey` — once Blender is ready and, with `-modal-wait <name>`,
    /// that object is active. `dump` prints the transform's state and the
    /// selection as the mirror has it; `wait:<ms>` waits; `drag:dx,dy` is a
    /// finger's drag; `bar:x|confirm|cancel` the bar's buttons.
    func modalLaunchIfRequested(tries: Int = 160) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let spec = value("-modal-ops") else { return }
        guard tries > 0 else { print("[bk] modal-ops: never ready"); fflush(stdout); return }
        let waitFor = value("-modal-wait")
        guard let view, view.bounds.width > 0, let bridge = parent.bridge, !bridge.isRunningScript,
              waitFor.map({ name in parent.scene.active?.name == name }) ?? true
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.modalLaunchIfRequested(tries: tries - 1) }
            return
        }
        let tokens = spec.split(separator: "|").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.modalToken(tokens, 0) }
    }

    private func modalToken(_ tokens: [String], _ i: Int) {
        guard i < tokens.count else {
            print("[bk] modal-ops: done")
            fflush(stdout)
            return
        }
        let token = tokens[i]
        let (verb, rest) = token.firstIndex(of: ":").map { (String(token[..<$0]), String(token[token.index(after: $0)...])) }
            ?? (token, "")
        let numbers = rest.split(separator: ",").compactMap { Double($0) }
        var delay = 0.15
        switch verb {
        case "g": beginModalTransform(.translate)
        case "r": beginModalTransform(.rotate)
        case "s": beginModalTransform(.scale)
        case "m": beginModalMirror()
        case "hover":
            if numbers.count == 2 {
                let point = CGPoint(x: numbers[0], y: numbers[1])
                lastPointer = point
                if modal != nil { modalHover(at: point, modifiers: []) }
            }
        case "leave":
            lastPointer = nil
            if modal != nil { modalHover(at: nil, modifiers: []) }
        case "drag":
            if var drive = modal, numbers.count == 2 {
                drive.pointer.x += numbers[0]
                drive.pointer.y += numbers[1]
                drive.startPending = false
                modal = drive
                modalUpdate(presenting: true)
            }
        case "key": modalKey(rest)
        case "ctrl":
            // Ctrl's press and release from a keyboard (SNAP_INV_ON / OFF).
            modalControl(rest == "down")
        case "bar":
            switch rest {
            case "confirm": ModalTransformState.shared.confirm()
            case "cancel":  ModalTransformState.shared.cancel()
            default:        ModalTransformState.shared.axis(Int(rest) ?? 0)
            }
        case "clearsel":
            // The selection changed under it, as an Outliner tap would.
            parent.scene.selection = []
        case "tab":
            // Blender's Tab: in and out of Edit Mode.
            parent.onToggleEditing?()
            delay = 2.0
        case "wait": delay = (numbers.first ?? 500) / 1000
        case "run":
            // Python (base64) run as a script line is, the mirror following.
            if let data = Data(base64Encoded: rest), let python = String(data: data, encoding: .utf8) {
                parent.bridge?.run(python, undo: "Test Setup")
            }
            delay = 2.0
        case "dump": modalDump(rest)
        default: print("[bk] modal-ops: unknown \(token)")
        }
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.modalToken(tokens, i + 1) }
    }

    private func modalDump(_ label: String) {
        func f(_ v: SIMD3<Float>) -> String { String(format: "(%.4f, %.4f, %.4f)", v.x, v.y, v.z) }
        var line = "[bk] modal-dump \(label):"
        if let drive = modal {
            line += " running=\(drive.input.mode.label) constraint=\(drive.input.constraint)"
            line += " typing=\(drive.input.isTyping) pending=\(drive.startPending)"
            line += " snapInverted=\(drive.snapInverted)"
            let view = drive.base.frame.viewAxes
            line += " right=\(f(view.columns.0)) up=\(f(view.columns.1))"
            if let slide = drive.slide {
                line += String(format: " slide=%@ factor=%.4f ends=%d even=%d flipped=%d clamp=%d exact=%d",
                               "\(slide.kind)", slide.factor, slide.ends.count, slide.even ? 1 : 0,
                               slide.flipped ? 1 : 0, slide.clamp ? 1 : 0, slide.exact?.count ?? -1)
                if let exact = slide.exact, let first = exact.keys.min(), let p = exact[first] {
                    line += " exact[\(first)]=\(f(p))"
                }
                if let d = slide.direction { line += " direction=\(f(d))" }
            }
        } else {
            line += " running=none"
        }
        line += " readout=\"\(parent.scene.transformReadout ?? "")\""
        line += " bar=\(ModalTransformState.shared.shown.map { "\($0.mode.label)" } ?? "none")"
        line += " firstResponderModal=\((view as? ViewportMTKView)?.modal != nil)"
        line += " propSize=\(gizmo?.proportional.map { String($0.size) } ?? "off") sceneSize=\(parent.scene.tools.size)"
        print(line)
        for obj in parent.scene.objects where parent.scene.selection.contains(obj.id) {
            let deg = obj.rotation * 180 / .pi
            print("[bk] modal-dump   \(obj.name) loc=\(f(obj.location)) rot°=\(f(deg)) scale=\(f(obj.scale))")
        }
        if parent.scene.mode == .edit, let obj = parent.scene.active {
            let m = obj.modelMatrix
            let cage = obj.editCage.vertices
            let picked = parent.scene.editSelection.vertices.filter { $0 < cage.count }
            if !picked.isEmpty {
                let sum = picked.reduce(SIMD3<Float>.zero) { $0 + (m * SIMD4(cage[$1].position, 1)).xyz }
                print("[bk] modal-dump   edit \(picked.count) selected, centre=\(f(sum / Float(picked.count)))")
            }
        }
        if let op = parent.bridge?.repeatable { print("[bk] modal-dump   last=\(op.python)") }
    }
}
#endif
