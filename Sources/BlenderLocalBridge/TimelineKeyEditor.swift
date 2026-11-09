import Foundation

/// The Timeline's key and marker editing, from its gestures, menus and keys
/// alike: each action as the Python `BpyKeys` builds, sent the way it needs —
/// a selection without the mirroring pass, an edit through it — one undo
/// step each, named after Blender's operator.
///
/// It holds no animation state: Blender owns the keys and markers, the mirror
/// brings them back, and the interface draws them. The live state of a drag
/// is the interface's own until it lets go.
public final class TimelineKeyEditor {
    public private(set) weak var scene: BKScene?
    public private(set) weak var session: BpySession?
    public private(set) weak var bridge: BpyBridge?

    /// The scene's Snap for keys, read as a drag starts (`refreshSnap`).
    public private(set) var snap = TimelineSnap()

    /// What the last action sent, for the tests and the launch hook.
    public private(set) var lastCommand: BlenderCommand?

    /// Said where Blender cannot be reached: the simulator's stand-in has no
    /// Timeline and no operators.
    public static let needsBlender = "The Timeline's keys and markers are edited by Blender, "
        + "which the simulator's stand-in does not have"

    public init() {}

    public func bind(scene: BKScene, session: BpySession, bridge: BpyBridge?) {
        self.scene = scene
        self.session = session
        self.bridge = bridge
        snap.fps = scene.animation.fps
    }

    /// Nothing may reach Blender while a script holds it.
    public var isAvailable: Bool {
        guard let session, bridge != nil else { return false }
        return !session.isRunning
    }

    private func ready() -> BpyBridge? {
        guard let session, let bridge, !session.isRunning else { return nil }
        guard session.usesRealBlender else {
            session.note(Self.needsBlender)
            return nil
        }
        return bridge
    }

    @discardableResult
    private func send(_ command: BlenderCommand, mirror: Bool) -> Bool {
        guard let bridge = ready() else { return false }
        lastCommand = command
        let outcome = mirror ? bridge.run(command) : bridge.runWithoutMirror(command)
        return outcome.succeeded
    }

    // MARK: selection by pointer

    /// A tap on a column, or beside every column (`frame` nil).
    @discardableResult
    public func clickSelect(frame: Float?, extend: Bool) -> Bool {
        send(BpyKeys.clickSelect(frame: frame, extend: extend), mirror: false)
    }

    /// A box from one frame to another.
    @discardableResult
    public func boxSelect(_ range: (Double, Double), mode: String) -> Bool {
        send(BpyKeys.boxSelect(from: range.0, to: range.1, mode: mode), mirror: false)
    }

    /// Ctrl+click (`action.select_leftright`, CHECK): every key on the
    /// clicked side of the current frame.
    @discardableResult
    public func selectSide(of frame: Double, extend: Bool) -> Bool {
        guard let scene else { return false }
        let mode = frame < Double(scene.frameCurrent) ? "LEFT" : "RIGHT"
        return send(BpyKeys.selectLeftRight(mode, extend: extend), mirror: false)
    }

    /// A tap on a marker (`index` in the scene's list), or beside every
    /// marker (-1).
    @discardableResult
    public func selectMarker(index: Int, extend: Bool) -> Bool {
        send(BpyKeys.markerSelect(index: index, extend: extend), mirror: false)
    }

    // MARK: everything else

    /// A menu row's or a key's action.
    @discardableResult
    public func perform(_ action: TimelineAction) -> Bool {
        let command = BpyKeys.command(for: action)
        // Copy Keyframes changes nothing the 3D View draws.
        let mirror = !(BpyKeys.isSelection(action) || action == .copy)
        return send(command, mirror: mirror)
    }

    /// G or a drag let go: the selected keys moved `delta` frames, or
    /// Shift+D's copies.
    ///
    /// `inverted`: Ctrl was held, Blender's Snap Invert — the scene's Snap
    /// turned round for this move.
    @discardableResult
    public func move(by delta: Double, duplicate: Bool, inverted: Bool = false) -> Bool {
        send(BpyKeys.move(by: delta, duplicate: duplicate, snap: inverted ? !snap.on : nil), mirror: true)
    }

    /// S let go.
    @discardableResult
    public func scale(by factor: Double, inverted: Bool = false) -> Bool {
        send(BpyKeys.scale(by: factor, snap: inverted ? !snap.on : nil), mirror: true)
    }

    /// A marker drag or G over the markers let go.
    @discardableResult
    public func moveMarkers(by frames: Int, duplicate: Bool) -> Bool {
        send(BpyKeys.markerMove(by: frames, duplicate: duplicate), mirror: true)
    }

    /// F2's field committed.
    @discardableResult
    public func renameMarker(_ name: String) -> Bool {
        send(BpyKeys.markerRename(name), mirror: false)
    }

    /// The scene's Snap, asked as a drag starts so its preview lands where
    /// Blender will put the keys. Kept as it was when Blender cannot answer.
    public func refreshSnap() {
        guard let session, session.usesRealBlender, !session.isRunning,
              let answer = session.capture(BpyKeys.snapState),
              let parsed = TimelineSnap.parse(answer) else {
            if let scene { snap.fps = scene.animation.fps }
            return
        }
        snap = parsed
    }

    /// The first selected marker, which Rename Marker renames
    /// (TOPBAR_PT_name_marker).
    public var renamedMarker: TimelineMarker? {
        scene?.animation.markers.first(where: \.selected)
    }
}
