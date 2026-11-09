import SwiftUI
import UIKit

// The Timeline's hands: what a finger, the pointer and the keyboard do over
// its body, as Blender's Timeline (a Dope Sheet in Timeline mode) answers
// them — the scrubbing strip along the top scrubs, the keys below it are
// tapped, boxed and dragged, the markers along the bottom are tapped and
// dragged, a pinch and a two-finger drag zoom and pan.
//
// Live state — a drag's preview, a box, the view — is the interface's own
// (`TimelineViewState`), read by the small views that draw it, never by the
// workspace around them. Blender hears of a gesture once, when it lets go
// (`TimelineKeyEditor`).

/// What the Timeline draws that is not Blender's: the frames in view, the
/// area's own settings, and a gesture in progress.
@MainActor @Observable
final class TimelineViewState {
    /// The frames in view once zoomed, panned or framed; nil follows the
    /// scene's range (Frame Scene Range).
    var window: TimelineWindow?
    /// Use Timecode (`SpaceDopeSheetEditor.show_seconds`): an area setting,
    /// kept for the app as Blender keeps it with the screen.
    var showSeconds: Bool = UserDefaults.standard.bool(forKey: TimelineViewState.secondsKey) {
        didSet { UserDefaults.standard.set(showSeconds, forKey: Self.secondsKey) }
    }
    /// Show Markers (`show_markers`), on by default.
    var showMarkers: Bool = UserDefaults.standard.object(forKey: TimelineViewState.markersKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMarkers, forKey: Self.markersKey) }
    }
    /// A move, scale or marker drag in progress, drawn before Blender is told.
    var preview: Preview?
    /// A box being drawn across the keys, in points.
    var box: (CGFloat, CGFloat)?
    /// B pressed: the next drag draws a box even from a key.
    var boxArmed = false
    /// G, S and Shift+D's header line, as Blender's header shows it.
    var header: String?
    /// The Rename Marker field (F2).
    var renaming = false
    var renameText = ""
    /// A confirmation Blender asks for: X's Delete Keyframes, X over the markers.
    var confirm: Confirm?

    enum Preview: Equatable {
        case keys(raw: Double, duplicate: Bool, inverted: Bool)
        case scale(factor: Double, inverted: Bool)
        case markers(delta: Int, duplicate: Bool)
    }

    enum Confirm: Equatable {
        case deleteKeys, deleteMarkers

        /// Blender's own words (`actkeys_delete_invoke`, `ed_marker_delete_invoke`).
        var message: String {
            switch self {
            case .deleteKeys: return "Delete selected keyframes?"
            case .deleteMarkers: return "Delete selected markers?"
            }
        }
    }

    static let secondsKey = "timeline.useTimecode"
    static let markersKey = "timeline.showMarkers"

    /// The frames in view at a width.
    func shownWindow(for scene: BKScene, width: CGFloat) -> TimelineWindow {
        if let window { return window.resized(to: width) }
        return TimelineWindow(range: scene.frameStart...max(scene.frameEnd, scene.frameStart), width: width)
    }
}

/// The Timeline's controller: gestures, keys, menus and the modal moves, all
/// into `TimelineKeyEditor` and `TimelineDriver`.
@MainActor
final class TimelineController {
    let state = TimelineViewState()
    let editor = TimelineKeyEditor()
    private(set) weak var scene: BKScene?
    private(set) weak var session: BpySession?
    private(set) weak var driver: TimelineDriver?
    /// Opens one of Blender's menus over the workspace (LayoutWorkspace's
    /// pop-up overlay); nil closes it.
    var openMenu: ((PopupMenuModel?) -> Void)?
    /// The body's place in the workspace's overlay, and its size.
    var bodyOrigin: CGPoint = .zero
    var bodySize: CGSize = .zero
    weak var inputView: TimelineInputView?

    static let scrubHeight: CGFloat = 22
    static let keysHeight: CGFloat = 46
    static let markersHeight: CGFloat = 26
    /// How far from a diamond or a marker a fingertip still takes it.
    static let reach: CGFloat = 16

    init() {}

    func bind(scene: BKScene, session: BpySession, bridge: BpyBridge?, driver: TimelineDriver) {
        self.scene = scene
        self.session = session
        self.driver = driver
        editor.bind(scene: scene, session: session, bridge: bridge)
    }

    var window: TimelineWindow {
        guard let scene else { return TimelineWindow(first: 0, last: 250, width: max(bodySize.width, 1)) }
        return state.shownWindow(for: scene, width: max(bodySize.width, 1))
    }

    enum Region { case scrub, keys, markers }

    func region(at y: CGFloat) -> Region {
        if y < Self.scrubHeight { return .scrub }
        if state.showMarkers, y >= Self.scrubHeight + Self.keysHeight { return .markers }
        return .keys
    }

    /// The keys as drawn: the summary, with a move's preview applied.
    var keys: [TimelineKey] { scene?.timelineKeys ?? [] }

    /// Where a column is drawn on the key row, for Test All Features and the
    /// launch hook to press on.
    func point(_ frame: Float) -> CGPoint {
        CGPoint(x: window.x(Double(frame)), y: Self.scrubHeight + Self.keysHeight / 2)
    }

    // MARK: - gestures

    private enum Mode { case pending, scrub, box, move, markerMove, ignored }

    private struct Press {
        var start: CGPoint
        var region: Region
        var column: TimelineKey?
        var marker: Int?
        var mode: Mode = .pending
    }

    private var press: Press?
    private var lastMarkerTap: (index: Int, time: TimeInterval)?

    private func shift(_ m: UIKeyModifierFlags) -> Bool { m.contains(.shift) }
    private func ctrl(_ m: UIKeyModifierFlags) -> Bool { m.contains(.control) }

    func pressBegan(at p: CGPoint, modifiers: UIKeyModifierFlags) {
        if modal != nil {
            // A drag during G, S or Shift+D drives it; lifting confirms.
            if modal?.startX == nil { modal?.startX = p.x }
            updateModal(x: p.x)
            press = Press(start: p, region: .keys, mode: .ignored)
            return
        }
        let region = region(at: p.y)
        var press = Press(start: p, region: region)
        switch region {
        case .scrub:
            press.mode = .scrub
            driver?.scrub(to: window.wholeFrame(at: p.x))
        case .keys:
            press.column = TimelineHit.column(at: p.x, in: keys, window: window, radius: Self.reach)
        case .markers:
            press.marker = TimelineHit.marker(at: p.x, in: scene?.animation.markers ?? [], window: window,
                                              radius: Self.reach)
        }
        self.press = press
    }

    func pressMoved(to p: CGPoint, modifiers: UIKeyModifierFlags) {
        if modal != nil {
            updateModal(x: p.x, inverted: ctrl(modifiers))
            return
        }
        guard var press else { return }
        defer { self.press = press }
        switch press.mode {
        case .scrub:
            driver?.scrub(to: window.wholeFrame(at: p.x))
        case .pending:
            guard hypot(p.x - press.start.x, p.y - press.start.y) >= TimelineHit.dragThreshold else { return }
            switch press.region {
            case .keys:
                if state.boxArmed || press.column == nil {
                    press.mode = .box
                    state.box = (press.start.x, p.x)
                } else if let column = press.column {
                    // Blender's press selects the key under it (unless it is
                    // selected already, `wait_to_deselect_others`), and the drag
                    // then moves the selection.
                    if !column.selected { editor.clickSelect(frame: column.frame, extend: shift(modifiers)) }
                    guard scene?.timelineKeys.contains(where: \.selected) == true else {
                        press.mode = .ignored
                        return
                    }
                    editor.refreshSnap()
                    press.mode = .move
                    state.preview = .keys(raw: 0, duplicate: false, inverted: ctrl(modifiers))
                }
            case .markers:
                guard let index = press.marker, let scene else {
                    press.mode = .ignored
                    return
                }
                if scene.animation.lockMarkers {
                    session?.note(LockedMarkers.message)
                    press.mode = .ignored
                    return
                }
                if !(scene.animation.markers.indices.contains(index) && scene.animation.markers[index].selected) {
                    editor.selectMarker(index: index, extend: shift(modifiers))
                }
                press.mode = .markerMove
                state.preview = .markers(delta: 0, duplicate: false)
            case .scrub:
                break
            }
            // Once more, now as what it has become.
            self.press = press
            pressMoved(to: p, modifiers: modifiers)
        case .box:
            state.box = (press.start.x, p.x)
        case .move:
            let raw = Double(p.x - press.start.x) / window.pixelsPerFrame
            state.preview = .keys(raw: raw, duplicate: false, inverted: ctrl(modifiers))
            state.header = moveHeader(raw: raw, inverted: ctrl(modifiers))
        case .markerMove:
            let delta = Int((Double(p.x - press.start.x) / window.pixelsPerFrame).rounded())
            state.preview = .markers(delta: delta, duplicate: false)
            state.header = markerHeader(delta)
        case .ignored:
            break
        }
    }

    func pressEnded(at p: CGPoint, modifiers: UIKeyModifierFlags) {
        if modal != nil {
            if let press, press.mode == .ignored { confirmModal() }
            press = nil
            return
        }
        guard let press else { return }
        self.press = nil
        switch press.mode {
        case .scrub:
            driver?.scrub(to: window.wholeFrame(at: p.x))
            driver?.flushPendingFrame()
        case .pending:
            tap(press, at: p, modifiers: modifiers)
        case .box:
            state.box = nil
            state.boxArmed = false
            let range = TimelineHit.frames(from: press.start.x, to: p.x, window: window)
            editor.boxSelect(range, mode: shift(modifiers) ? "ADD" : ctrl(modifiers) ? "SUB" : "SET")
        case .move:
            let raw = Double(p.x - press.start.x) / window.pixelsPerFrame
            state.preview = nil
            state.header = nil
            commitMove(raw: raw, inverted: ctrl(modifiers), duplicate: false)
        case .markerMove:
            let delta = Int((Double(p.x - press.start.x) / window.pixelsPerFrame).rounded())
            state.preview = nil
            state.header = nil
            if delta != 0 { editor.moveMarkers(by: delta, duplicate: false) }
        case .ignored:
            break
        }
    }

    func pressCancelled() {
        if let press, press.mode == .scrub { driver?.flushPendingFrame() }
        press = nil
        if modal == nil {
            state.preview = nil
            state.header = nil
        }
        state.box = nil
    }

    private func tap(_ press: Press, at p: CGPoint, modifiers: UIKeyModifierFlags) {
        switch press.region {
        case .keys:
            if ctrl(modifiers) && !modifiers.contains(.alternate) {
                // Ctrl+click: the keys on the clicked side of the current frame.
                editor.selectSide(of: window.frame(at: p.x), extend: shift(modifiers))
            } else {
                editor.clickSelect(frame: press.column?.frame, extend: shift(modifiers))
            }
        case .markers:
            let now = ProcessInfo.processInfo.systemUptime
            if let index = press.marker, let last = lastMarkerTap, last.index == index, now - last.time < 0.4 {
                // Blender's double-click on a marker: Rename Marker.
                lastMarkerTap = nil
                beginRename()
                return
            }
            lastMarkerTap = press.marker.map { ($0, now) }
            editor.selectMarker(index: press.marker ?? -1, extend: shift(modifiers))
        case .scrub:
            break
        }
    }

    /// A pinch: zoom about the fingers.
    func pinch(by scale: CGFloat, at x: CGFloat) {
        state.window = window.zoomed(by: Double(scale), about: x)
    }

    /// A two-finger drag.
    func pan(by dx: CGFloat) {
        state.window = window.panned(by: dx)
    }

    /// A trackpad's scroll or a mouse wheel: across pans, up and down zooms
    /// about the pointer, as Blender's wheel zooms its timeline.
    func scroll(dx: CGFloat, dy: CGFloat, at x: CGFloat) {
        if abs(dx) > abs(dy) {
            pan(by: dx)
        } else if dy != 0 {
            pinch(by: CGFloat(exp(Double(dy) * 0.01)), at: x)
        }
    }

    /// Where the pointer is over the body; nil once it has left.
    private(set) var pointer: CGPoint?

    func hover(at p: CGPoint?) {
        pointer = p
        if let p, modal != nil { updateModal(x: p.x) }
    }

    var pointerInMarkers: Bool {
        guard let pointer else { return false }
        return region(at: pointer.y) == .markers
    }

    /// A right-click or a long press: Blender's Dope Sheet context menu.
    func contextMenu(at p: CGPoint) {
        if modal != nil { cancelModal(); return }
        press = nil
        state.preview = nil
        state.box = nil
        popup("DOPESHEET_MT_context_menu", at: p)
    }

    // MARK: - G, S and Shift+D

    enum ModalKind: Equatable { case move, scale, duplicate, markerMove, markerDuplicate }

    struct Modal {
        var kind: ModalKind
        var startX: CGFloat?
        var x: CGFloat?
        var typed = ""
        var inverted = false
    }

    private(set) var modal: Modal?

    func beginModal(_ kind: ModalKind) {
        guard modal == nil, let scene, editor.isAvailable else { return }
        guard session?.usesRealBlender == true else {
            session?.note(TimelineKeyEditor.needsBlender)
            return
        }
        switch kind {
        case .move, .scale, .duplicate:
            guard scene.timelineKeys.contains(where: \.selected) else { return }
            editor.refreshSnap()
        case .markerMove, .markerDuplicate:
            guard scene.animation.markers.contains(where: \.selected) else { return }
            if scene.animation.lockMarkers {
                session?.note(LockedMarkers.message)
                return
            }
        }
        modal = Modal(kind: kind, startX: pointer?.x, x: pointer?.x)
        inputView?.takeKeyboard()
        refreshModal()
    }

    func updateModal(x: CGFloat, inverted: Bool? = nil) {
        guard var m = modal else { return }
        if m.startX == nil { m.startX = x }
        m.x = x
        if let inverted { m.inverted = inverted }
        modal = m
        refreshModal()
    }

    func modalControl(_ down: Bool) {
        guard var m = modal else { return }
        m.inverted = down
        modal = m
        refreshModal()
    }

    /// The modal's value: what was typed, else what the pointer says.
    private func modalValue(_ m: Modal) -> Double {
        if let typed = Double(m.typed), !m.typed.isEmpty { return typed }
        let w = window
        guard let start = m.startX, let x = m.x else { return m.kind == .scale ? 1 : 0 }
        switch m.kind {
        case .scale:
            // TIME_SCALE: the pointer's distance from the current frame over
            // where it began.
            let pivot = w.x(Double(scene?.frameCurrent ?? 0))
            let d0 = abs(start - pivot)
            return d0 < 1 ? 1 : Double(abs(x - pivot) / d0)
        default:
            return Double(x - start) / w.pixelsPerFrame
        }
    }

    private func refreshModal() {
        guard let m = modal else { return }
        let value = modalValue(m)
        let typed = !m.typed.isEmpty
        // A typed value is not snapped, whatever Snap says.
        let inverted = typed ? editor.snap.on : m.inverted
        switch m.kind {
        case .move, .duplicate:
            state.preview = .keys(raw: value, duplicate: m.kind == .duplicate, inverted: inverted)
            state.header = typed ? "DeltaX: \(m.typed)" : moveHeader(raw: value, inverted: m.inverted)
        case .scale:
            state.preview = .scale(factor: value, inverted: inverted)
            state.header = "ScaleX: " + (typed ? m.typed : String(format: "%.4f", value))
        case .markerMove, .markerDuplicate:
            let delta = Int(value.rounded())
            state.preview = .markers(delta: delta, duplicate: m.kind == .markerDuplicate)
            state.header = markerHeader(delta)
        }
    }

    func confirmModal() {
        guard let m = modal else { return }
        let value = modalValue(m)
        let typed = !m.typed.isEmpty
        let inverted = typed ? editor.snap.on : m.inverted
        modal = nil
        state.preview = nil
        state.header = nil
        switch m.kind {
        case .move:
            commitMove(raw: value, inverted: inverted, duplicate: false)
        case .duplicate:
            commitMove(raw: value, inverted: inverted, duplicate: true)
        case .scale:
            if value != 1 { editor.scale(by: value, inverted: inverted) }
        case .markerMove:
            let d = Int(value.rounded())
            if d != 0 { editor.moveMarkers(by: d, duplicate: false) }
        case .markerDuplicate:
            editor.moveMarkers(by: Int(value.rounded()), duplicate: true)
        }
    }

    /// Esc and a right-click. Shift+D's copies stay where they were made, as
    /// Blender's macro leaves them.
    func cancelModal() {
        guard let m = modal else { return }
        modal = nil
        state.preview = nil
        state.header = nil
        switch m.kind {
        case .duplicate: editor.move(by: 0, duplicate: true)
        case .markerDuplicate: editor.moveMarkers(by: 0, duplicate: true)
        default: break
        }
    }

    private func commitMove(raw: Double, inverted: Bool, duplicate: Bool) {
        let snap = editor.snap
        // What the preview showed: snapped by whole frames, or each key
        // snapped (Absolute Time Snap) from the raw move, or — with Ctrl,
        // Blender's Snap Invert — the scene's Snap turned round for the move.
        let snapping = snap.snapping(inverted: inverted)
        let delta = snapping && !snap.absolute ? snap.delta(raw, inverted: inverted) : raw
        guard delta != 0 || duplicate || (snap.absolute && snapping) else { return }
        editor.move(by: delta, duplicate: duplicate, inverted: inverted)
    }

    /// Blender's header line during TIME_TRANSLATE (`headerTimeTranslate`).
    private func moveHeader(raw: Double, inverted: Bool) -> String {
        let snap = editor.snap
        let first = Double(keys.first(where: \.selected)?.frame ?? 0)
        let landed = snap.landing(first, raw: raw, inverted: inverted)
        let delta = landed - first
        if snap.snapping(inverted: inverted) {
            return String(format: "DeltaX: %.2f (%.4f)", delta, landed)
        }
        return String(format: "DeltaX: %.4f", delta)
    }

    /// `ed_marker_move_update_header`.
    private func markerHeader(_ delta: Int) -> String {
        let selected = scene?.animation.markers.filter(\.selected) ?? []
        if selected.count == 1 { return "Marker \(selected[0].frame + delta) offset \(delta)" }
        return "Marker offset \(delta)"
    }

    // MARK: - keys

    /// One of the Timeline's keys, by its token (TimelineInputView's table).
    /// False when it is not the Timeline's to answer.
    @discardableResult
    func key(_ token: String) -> Bool {
        if modal != nil { return modalKey(token) }
        let markers = pointerInMarkers
        switch token {
        case "select.all": perform(markers ? .markerSelectAll("SELECT") : .selectAll("SELECT"))
        case "select.none": perform(markers ? .markerSelectAll("DESELECT") : .selectAll("DESELECT"))
        case "select.invert": perform(markers ? .markerSelectAll("INVERT") : .selectAll("INVERT"))
        case "select.before": perform(markers ? .markerSelectLeftRight("LEFT") : .selectLeftRight("LEFT"))
        case "select.after": perform(markers ? .markerSelectLeftRight("RIGHT") : .selectLeftRight("RIGHT"))
        case "select.columns": perform(.selectColumn("KEYS"))
        case "select.column_cfra": perform(.selectColumn("CFRA"))
        case "select.columns_markers": perform(.selectColumn("MARKERS_COLUMN"))
        case "select.between_markers": perform(.selectColumn("MARKERS_BETWEEN"))
        case "select.linked": perform(.selectLinked)
        case "select.more": perform(.selectMore)
        case "select.less": perform(.selectLess)
        case "select.box": state.boxArmed = true
        case "move": beginModal(markers ? .markerMove : .move)
        case "scale": beginModal(.scale)
        case "duplicate": beginModal(markers ? .markerDuplicate : .duplicate)
        case "delete.menu":
            if markers { askDeleteMarkers() } else { popup("DOPESHEET_MT_delete", at: pointer) }
        case "delete": perform(markers ? .markerDelete : .delete)
        case "copy": perform(.copy)
        case "paste": perform(.paste(flipped: false))
        case "paste.flipped": perform(.paste(flipped: true))
        case "snap.pie": popup("DOPESHEET_MT_snap_pie", at: pointer, pie: true)
        case "jump": perform(.jumpToKeys)
        case "mirror.menu": popup("action.mirror", at: pointer)
        case "interpolation.menu": popup("action.interpolation_type", at: pointer)
        case "easing.menu": popup("action.easing_type", at: pointer)
        case "type.menu": popup("action.keyframe_type", at: pointer)
        case "handle.menu": popup("action.handle_type", at: pointer)
        case "context.menu": popup("DOPESHEET_MT_context_menu", at: pointer)
        case "insert": perform(.insert("ALL"))
        case "marker.add": perform(.markerAdd)
        case "marker.rename": beginRename()
        case "marker.camera": perform(.markerCameraBind)
        case "timecode": state.showSeconds.toggle()
        case "view.all": interface("view.frame_all")
        case "view.current": interface("view.frame_current")
        case "view.selected": interface("view.frame_selected")
        case "zoom.in": pinch(by: 1.25, at: pointer?.x ?? bodySize.width / 2)
        case "zoom.out": pinch(by: 0.8, at: pointer?.x ?? bodySize.width / 2)
        case "cancel":
            if state.boxArmed { state.boxArmed = false } else { return false }
        case "swallow": break
        default: return false
        }
        return true
    }

    private func modalKey(_ token: String) -> Bool {
        guard var m = modal else { return false }
        switch token {
        case "confirm": confirmModal()
        case "cancel": cancelModal()
        case "backspace":
            if !m.typed.isEmpty { m.typed.removeLast() }
            modal = m
            refreshModal()
        case "minus":
            m.typed = m.typed.hasPrefix("-") ? String(m.typed.dropFirst()) : "-" + m.typed
            modal = m
            refreshModal()
        case "period":
            if !m.typed.contains(".") { m.typed += m.typed.isEmpty ? "0." : "." }
            modal = m
            refreshModal()
        default:
            if token.hasPrefix("digit:") {
                m.typed += token.dropFirst("digit:".count)
                modal = m
                refreshModal()
            }
        }
        return true
    }

    // MARK: - menus and actions

    var isAvailable: Bool { editor.isAvailable }

    func perform(_ action: TimelineAction) {
        editor.perform(action)
    }

    func askDeleteMarkers() {
        guard scene?.animation.markers.contains(where: \.selected) == true else { return }
        state.confirm = .deleteMarkers
    }

    func beginRename() {
        guard let scene else { return }
        if scene.animation.lockMarkers {
            session?.note(LockedMarkers.message)
            return
        }
        guard let marker = editor.renamedMarker else { return }
        state.renameText = marker.name
        state.renaming = true
    }

    func commitRename() {
        state.renaming = false
        guard editor.renamedMarker?.name != state.renameText else { return }
        editor.renameMarker(state.renameText)
    }

    func confirmed(_ confirm: TimelineViewState.Confirm) {
        state.confirm = nil
        switch confirm {
        case .deleteKeys: perform(.delete)
        case .deleteMarkers: perform(.markerDelete)
        }
    }

    /// Whether a toggle row is on.
    func checked(_ name: String) -> Bool {
        switch name {
        case "view.show_markers": return state.showMarkers
        case "view.use_timecode": return state.showSeconds
        case "view.only_selected": return scene?.animation.onlySelectedKeys ?? false
        case "marker.lock": return scene?.animation.lockMarkers ?? false
        default: return false
        }
    }

    func isToggle(_ name: String) -> Bool {
        ["view.show_markers", "view.use_timecode", "view.only_selected", "marker.lock"].contains(name)
    }

    /// A row the interface answers itself.
    func interface(_ name: String) {
        guard let scene else { return }
        let w = window
        switch name {
        case "view.frame_all":
            state.window = w.framingKeys(scene.timelineKeys.map(\.frame),
                                         sceneRange: scene.frameStart...max(scene.frameEnd, scene.frameStart))
        case "view.frame_selected":
            if let framed = w.framingKeys(scene.selectedKeyFrames, sceneRange: nil) { state.window = framed }
        case "view.frame_range":
            let range = scene.playbackRange
            state.window = range == scene.frameStart...max(scene.frameEnd, scene.frameStart) ? nil
                : TimelineWindow(range: range, width: w.width)
        case "view.frame_current":
            state.window = w.centred(on: Double(scene.frameFloat))
        case "view.show_markers": state.showMarkers.toggle()
        case "view.use_timecode": state.showSeconds.toggle()
        case "view.only_selected": driver?.setOnlySelectedKeys(!scene.animation.onlySelectedKeys)
        case "select.box": state.boxArmed = true
        case "marker.lock": perform(.lockMarkers(!scene.animation.lockMarkers))
        case "marker.jump_previous", "marker.jump_next":
            let next = name == "marker.jump_next"
            if let frame = scene.markerJumpTarget(next: next) {
                driver?.setFrame(frame)
            } else {
                // screen.marker_jump's own report.
                session?.note("No more markers to jump to in this direction")
            }
        case "marker.move": beginModal(.markerMove)
        case "marker.duplicate": beginModal(.markerDuplicate)
        case "marker.rename": beginRename()
        case "marker.delete": askDeleteMarkers()
        case "key.move": beginModal(.move)
        case "key.scale": beginModal(.scale)
        case "key.duplicate": beginModal(.duplicate)
        case "key.delete_confirm":
            if scene.timelineKeys.contains(where: \.selected) { state.confirm = .deleteKeys }
        default: break
        }
    }

    /// One of Blender's menus at a point of the body (the pointer's, else the
    /// middle), drawn by the workspace's pop-up overlay.
    func popup(_ id: String, at point: CGPoint?, pie: Bool = false) {
        let local = point ?? CGPoint(x: bodySize.width / 2, y: bodySize.height / 2)
        var anchor = CGPoint(x: bodyOrigin.x + local.x, y: bodyOrigin.y + local.y)
        if pie {
            // The Timeline sits at the foot of the window: a pie round a
            // point in it is lifted until its lowest item fits, as Blender
            // keeps a pie inside its window.
            anchor.y = min(anchor.y, bodyOrigin.y + bodySize.height - 140)
        }
        var model = PopupMenuModel(name: id, title: TimelineMenus.title(id), anchor: anchor, items: items(id))
        model.pie = pie
        openMenu?(model)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-timeline-ops") {
            print("[bk] timeline menu " + model.dump().replacingOccurrences(of: "\n", with: "\n[bk] timeline menu "))
            fflush(stdout)
        }
        #endif
    }

    func items(_ id: String) -> [PopupItem] {
        let preview = scene?.animation.usePreviewRange ?? false
        let available = isAvailable && session?.usesRealBlender == true
        return TimelineMenus.rows(id, usePreviewRange: preview).map { row -> PopupItem in
            switch row.kind {
            case .separator: return .separator
            case .heading: return .heading(row.title)
            case .unavailable: return .action(row.title, key: row.key, enabled: false) {}
            case .submenu(let sub): return .submenu(row.title, enabled: available) { [weak self] in self?.items(sub) ?? [] }
            case .action(let action):
                return .action(row.title, key: row.key, enabled: available) { [weak self] in self?.perform(action) }
            case .interface(let name):
                return .action(row.title, key: row.key, checked: isToggle(name) && checked(name)) { [weak self] in
                    self?.interface(name)
                }
            }
        }
    }

    /// The Timeline put away: a move in progress is cancelled, and the 3D
    /// View has the keyboard again.
    func closed() {
        if modal != nil { cancelModal() }
        press = nil
        state.preview = nil
        state.box = nil
        inputView?.giveKeyboardBack()
    }
}

enum LockedMarkers {
    /// TOPBAR_PT_name_marker's words.
    static let message = "Markers are locked"
}

// MARK: - The body's touches, pointer and keys

/// The UIKit view over the Timeline's body that takes its gestures and, while
/// the Timeline is the editor in use, the keyboard.
struct TimelineInputLayer: UIViewRepresentable {
    let controller: TimelineController

    func makeUIView(context: Context) -> TimelineInputView {
        let view = TimelineInputView()
        view.controller = controller
        controller.inputView = view
        view.install()
        return view
    }

    func updateUIView(_ view: TimelineInputView, context: Context) {
        view.controller = controller
    }
}

final class TimelineInputView: UIView, UIGestureRecognizerDelegate {
    weak var controller: TimelineController?
    private var press: UILongPressGestureRecognizer!
    private var hold: UILongPressGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var twoFinger: UIPanGestureRecognizer!
    private var scroll: UIPanGestureRecognizer!
    private var lastPinch: CGFloat = 1
    private var lastPan: CGPoint = .zero
    private var lastScroll: CGPoint = .zero
    /// The long press opened the context menu: the press it began as does
    /// nothing more.
    private var held = false

    func install() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        press = UILongPressGestureRecognizer(target: self, action: #selector(onPress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.numberOfTouchesRequired = 1
        press.delegate = self
        addGestureRecognizer(press)

        hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = TimelineHit.dragThreshold
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                  NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hold.delegate = self
        addGestureRecognizer(hold)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        twoFinger = UIPanGestureRecognizer(target: self, action: #selector(onTwoFinger(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(onSecondary(_:)))
        secondary.buttonMaskRequired = .secondary
        addGestureRecognizer(secondary)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair: Set<ObjectIdentifier> = [ObjectIdentifier(g), ObjectIdentifier(other)]
        let zoom: Set<ObjectIdentifier> = [ObjectIdentifier(pinch), ObjectIdentifier(twoFinger)]
        let holdPress: Set<ObjectIdentifier> = [ObjectIdentifier(press), ObjectIdentifier(hold)]
        return pair == zoom || pair == holdPress
    }

    private func modifiers(_ g: UIGestureRecognizer) -> UIKeyModifierFlags {
        ScreenModifiers.shared.merged(g.modifierFlags)
    }

    @objc private func onPress(_ g: UILongPressGestureRecognizer) {
        guard let controller else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            held = false
            takeKeyboard()
            controller.pressBegan(at: p, modifiers: modifiers(g))
        case .changed:
            if !held { controller.pressMoved(to: p, modifiers: modifiers(g)) }
        case .ended:
            if held { held = false } else { controller.pressEnded(at: p, modifiers: modifiers(g)) }
        case .cancelled, .failed:
            held = false
            controller.pressCancelled()
        default:
            break
        }
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let controller else { return }
        held = true
        controller.pressCancelled()
        controller.contextMenu(at: g.location(in: self))
    }

    @objc private func onSecondary(_ g: UITapGestureRecognizer) {
        takeKeyboard()
        controller?.contextMenu(at: g.location(in: self))
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            lastPinch = 1
        case .changed:
            let step = g.scale / max(lastPinch, 0.0001)
            lastPinch = g.scale
            controller?.pinch(by: step, at: g.location(in: self).x)
        default:
            break
        }
    }

    @objc private func onTwoFinger(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastPan = .zero
        case .changed:
            let t = g.translation(in: self)
            controller?.pan(by: t.x - lastPan.x)
            lastPan = t
        default:
            break
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastScroll = .zero
        case .changed:
            let t = g.translation(in: self)
            controller?.scroll(dx: t.x - lastScroll.x, dy: t.y - lastScroll.y, at: g.location(in: self).x)
            lastScroll = t
        default:
            break
        }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            // The pointer over the Timeline gives it the keys, as Blender's go
            // to the editor under the mouse — but not out of a field being
            // typed into.
            if g.state == .began, !TextEntryFocus.shared.isEditing { takeKeyboard() }
            controller?.hover(at: g.location(in: self))
        case .ended, .cancelled:
            controller?.hover(at: nil)
            if controller?.modal == nil { giveKeyboardBack() }
        default:
            break
        }
    }

    // MARK: the keyboard

    override var canBecomeFirstResponder: Bool { window != nil }

    func takeKeyboard() {
        guard window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    /// The 3D View's keys again, as Blender's go to the editor under the
    /// pointer.
    func giveKeyboardBack() {
        guard isFirstResponder else { return }
        if let window, let viewport = Self.find(ViewportMTKView.self, in: window) {
            viewport.takeKeyboard()
        }
        if isFirstResponder { resignFirstResponder() }
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, isFirstResponder { resignFirstResponder() }
    }

    /// Blender's Dope Sheet, Markers and Animation keymaps (blender_default.py,
    /// 5.2.1), with a Mac's ⌘ twin for each Ctrl key. Over the markers row the
    /// keys they share — A, Alt+A, Ctrl+I, [ and ], G, Shift+D, X, Delete —
    /// act on the markers (`TimelineController.key`). The other letters and
    /// the digits are swallowed while the Timeline has the keyboard, so none
    /// of them reaches the 3D View behind it.
    private static let table: [(String, UIKeyModifierFlags, String)] = {
        var keys: [(String, UIKeyModifierFlags, String)] = [
            ("a", [], "select.all"), ("a", .alternate, "select.none"),
            ("i", .control, "select.invert"), ("i", .command, "select.invert"),
            ("[", [], "select.before"), ("]", [], "select.after"),
            ("k", [], "select.columns"), ("k", .control, "select.column_cfra"), ("k", .command, "select.column_cfra"),
            ("k", .shift, "select.columns_markers"), ("k", .alternate, "select.between_markers"),
            ("l", [], "select.linked"), ("b", [], "select.box"),
            ("=", .control, "select.more"), ("-", .control, "select.less"),
            ("g", [], "move"), ("s", [], "scale"), ("d", .shift, "duplicate"),
            ("x", [], "delete.menu"), (UIKeyCommand.inputDelete, [], "delete"),
            ("c", .control, "copy"), ("c", .command, "copy"),
            ("v", .control, "paste"), ("v", .command, "paste"),
            ("v", [.control, .shift], "paste.flipped"), ("v", [.command, .shift], "paste.flipped"),
            ("s", .shift, "snap.pie"), ("g", .control, "jump"), ("g", .command, "jump"),
            ("m", .control, "mirror.menu"),
            ("t", [], "interpolation.menu"), ("e", .control, "easing.menu"), ("e", .command, "easing.menu"),
            ("r", [], "type.menu"), ("v", [], "handle.menu"), ("w", [], "context.menu"),
            ("i", [], "insert"), ("m", [], "marker.add"), (UIKeyCommand.f2, [], "marker.rename"),
            ("b", .control, "marker.camera"), ("b", .command, "marker.camera"),
            ("t", .control, "timecode"), ("t", .command, "timecode"),
            (UIKeyCommand.inputHome, [], "view.all"),
            ("=", [], "zoom.in"), ("-", [], "zoom.out"),
            (UIKeyCommand.inputEscape, [], "cancel"),
            // Blender's Ctrl+Z and Shift+Ctrl+Z work over every editor: the 3D
            // View's own (`ViewportKeymap`), which only its view carries.
            ("z", .control, "undo"), ("z", [.control, .shift], "redo"),
        ]
        let taken = Set(keys.map { "\($0.0)|\($0.1.rawValue)" })
        for c in "abcdefghijklmnopqrstuvwxyz0123456789,./\\;'`" {
            for flags: UIKeyModifierFlags in [[], .shift] where !taken.contains("\(c)|\(flags.rawValue)") {
                keys.append((String(c), flags, "swallow"))
            }
        }
        keys.append(("\t", [], "swallow"))
        return keys
    }()

    private static let commands: [UIKeyCommand] = table.map { input, flags, token in
        let command = UIKeyCommand(title: "", action: #selector(keyPressed(_:)), input: input,
                                   modifierFlags: flags, propertyList: token)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    /// G, S and Shift+D running: Blender's transform modal map — Return,
    /// Space and Enter confirm, Escape cancels, the digits, minus, point and
    /// Backspace type a value.
    private static let modalCommands: [UIKeyCommand] = {
        var keys: [(String, UIKeyModifierFlags, String)] = [
            ("\r", [], "confirm"), (" ", [], "confirm"), (UIKeyCommand.inputEscape, [], "cancel"),
            (UIKeyCommand.inputDelete, [], "backspace"), ("-", [], "minus"), (".", [], "period"),
        ]
        for digit in 0...9 { keys.append(("\(digit)", [], "digit:\(digit)")) }
        // The rest of the letters do nothing while it runs.
        for c in "abcdefghijklmnopqrstuvwxyz" { keys.append((String(c), [], "swallow")) }
        return keys.map { input, flags, token in
            let command = UIKeyCommand(title: "", action: #selector(keyPressed(_:)), input: input,
                                       modifierFlags: flags, propertyList: token)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }()

    override var keyCommands: [UIKeyCommand]? {
        controller?.modal != nil ? Self.modalCommands : Self.commands
    }

    @objc private func keyPressed(_ sender: UIKeyCommand) {
        guard let token = sender.propertyList as? String else { return }
        if token == "undo" || token == "redo" {
            // Undo is the scene's, which the 3D View's keys carry.
            let chord = token == "undo" ? "ctrl+z" : "shift+ctrl+z"
            if let window, let keys = Self.find(ViewportMTKView.self, in: window)?.viewKeys, keys.canPress(chord) {
                keys.press(chord)
            }
            return
        }
        controller?.key(token)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(keyPressed(_:)) {
            // Escape is the Timeline's only while it has something to cancel;
            // otherwise it stops playback, as the Animation menu has it.
            if let token = (sender as? UIKeyCommand)?.propertyList as? String, token == "cancel" {
                return controller?.modal != nil || controller?.state.boxArmed == true
            }
            return controller != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// The numpad's 0 and period (Go to Current Frame, Frame Selected), told
    /// by their key codes as the 3D View tells its numpad; and Ctrl held
    /// during G, S or Shift+D, which inverts snapping.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = presses
        for press in presses {
            guard let key = press.key else { continue }
            if key.keyCode == .keyboardLeftControl || key.keyCode == .keyboardRightControl {
                controller?.modalControl(true)
            }
            if key.modifierFlags.contains(.numericPad), controller?.modal == nil {
                if key.keyCode == .keypad0 {
                    controller?.key("view.current")
                    rest.remove(press)
                } else if key.keyCode == .keypadPeriod {
                    controller?.key("view.selected")
                    rest.remove(press)
                }
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let code = press.key?.keyCode, code == .keyboardLeftControl || code == .keyboardRightControl {
                controller?.modalControl(false)
            }
        }
        super.pressesEnded(presses, with: event)
    }
}
