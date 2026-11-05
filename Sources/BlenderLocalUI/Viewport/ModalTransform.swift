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

    /// The drag begun from `start` (nil: the pointer's place, or a stand-in
    /// until one arrives).
    private func startModal(_ mode: TransformGizmo.Mode, input: ModalTransformInput, start: CGPoint?,
                            pointer: CGPoint?, lastHover: CGPoint?) -> Bool {
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
                                            wireframe: parent.shading == .wireframe)
        gizmoResult = nil
        // A curve's or a lattice's points: Blender refused (the banner says
        // why) and there is nothing to steer.
        guard beginPointDragIfAny(), let base = gizmo else { return false }
        modal = ModalDrive(input: input, base: base, start: from, pointer: pointer ?? from,
                           startPending: start == nil && here == nil, lastHover: lastHover ?? here)
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
        if let last = drive.lastHover {
            let k: CGFloat = ScreenModifiers.shared.merged(modifiers).contains(.shift) ? 0.1 : 1
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
            let k: CGFloat = ScreenModifiers.shared.merged(g.modifierFlags).contains(.shift) ? 0.1 : 1
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
        guard modal != nil else { return }
        switch token {
        case "confirm":   modalConfirm()
        case "cancel":    modalCancel()
        case "swallow":   break
        case "g":         modalSwitch(.translate)
        case "r":         modalSwitch(.rotate)
        case "s":         modalSwitch(.scale)
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

    /// X, Y or Z, or Shift with one.
    func modalAxis(_ axis: Int, plane: Bool) {
        guard modal != nil else { return }
        modal?.input.press(axis: axis, plane: plane)
        retargetModal()
        modalUpdate(presenting: true)
    }

    /// The session held as the constraint says: its handle, and the axes of
    /// the orientation the constraint is in.
    private func retargetModal() {
        guard let drive = modal else { return }
        let base = drive.base
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

    /// G, R or S during another: everything back, and the new one from the
    /// same start.
    private func modalSwitch(_ mode: TransformGizmo.Mode) {
        guard let drive = modal, drive.base.gizmo.mode != mode else { return }
        discardModalSession()
        modal = nil
        var input = drive.input
        input.switchMode(mode.modalMode)
        let started = startModal(mode, input: input, start: drive.startPending ? nil : drive.start,
                                 pointer: drive.startPending ? nil : drive.pointer, lastHover: drive.lastHover)
        if !started { finishModal() }
    }

    // MARK: showing

    /// The drag to the pointer, or what was typed, shown. `presenting` false
    /// shows only the header: nothing has moved yet, and a confirm then
    /// commits nothing.
    func modalUpdate(presenting: Bool) {
        guard let drive = modal, let session = gizmo else { return }
        if presenting, let values = drive.input.values {
            presentGizmo(Self.typedResult(values, input: drive.input, session: session),
                         target: nil, readout: Self.typedReadout(drive.input, session: session))
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
                                              typing: drive.input.isTyping), owner: self)
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
        case .translate: lead = "D:"
        case .rotate:    lead = "Rot:"
        case .scale:     lead = "S:"
        }
        let values = shown.isEmpty ? input.mode.label : "\(lead) " + shown.joined(separator: " | ")
            + (input.mode == .rotate ? "°" : "")
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
        if g.mode != .translate, let centre = p.project(g.origin) {
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
        // No pointer over the view: show where the drags have taken it.
        if drive.lastHover == nil, g.mode != .translate {
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
        endGizmo()
        finishModal()
    }

    /// Escape or a right-click: everything back where it was, no step.
    func modalCancel() {
        guard modal != nil else { return }
        discardModalSession()
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

    /// G, R or S from a key or a menu row (Object ▸ Transform, Mesh ▸
    /// Transform): in the 3D View that has the keyboard.
    static func begin(_ mode: TransformGizmo.Mode) {
        MetalViewportView.Coordinator.forTransform?.beginModalTransform(mode)
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
            ForEach(0..<3, id: \.self) { i in axisButton(i, shown: shown) }
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

    private func barButton(_ title: String, icon: String, worded: Bool, prominent: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                if worded { Text(title).font(BTheme.Font.ui(13)) }
            }
            .padding(.horizontal, worded ? 10 : 0)
            .frame(minWidth: 40, minHeight: 36)
            .foregroundStyle(prominent ? Color.white : BTheme.text)
            .background(prominent ? BTheme.active : BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
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
        } else {
            line += " running=none"
        }
        line += " readout=\"\(parent.scene.transformReadout ?? "")\""
        line += " bar=\(ModalTransformState.shared.shown.map { "\($0.mode.label)" } ?? "none")"
        line += " firstResponderModal=\((view as? ViewportMTKView)?.modal != nil)"
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
