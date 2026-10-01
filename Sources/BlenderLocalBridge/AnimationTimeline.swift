import Foundation
import Observation

// Animation as Blender does it, driven from the interface.
//
// Blender owns the animation: the keys, the frame range, the rate, the
// keying settings. `_blenderkit_anim` (Resources/python/site) reports them
// into the display cache after every full mirror, and changes the frame
// without one. This file is what the interface does with that: the timeline's
// summary of keys, the jumps, the frame range rules, playback, and the Python
// every button sends. None of it needs UIKit, so tests/animation runs it on
// the Mac.

// MARK: - What the timeline mirrors

/// One column of keys in the timeline's summary row: where it is, and whether
/// any key in it is selected, which Blender draws in `keyframe_selected`.
public struct TimelineKey: Equatable, Sendable {
    public var frame: Float
    public var selected: Bool

    public init(frame: Float, selected: Bool = false) {
        self.frame = frame
        self.selected = selected
    }

    /// `BEZT_BINARYSEARCH_THRESH`: Blender treats keys closer than a hundredth
    /// of a frame as one.
    public static let threshold: Float = 0.01

    /// Keys from several channels as the columns Blender's keylist makes of
    /// them: sorted, near-equal frames merged, selected if any merged key is.
    public static func merged(_ keys: [TimelineKey]) -> [TimelineKey] {
        var out: [TimelineKey] = []
        for key in keys.sorted(by: { $0.frame < $1.frame }) {
            if let last = out.last, key.frame - last.frame <= threshold {
                out[out.count - 1].selected = last.selected || key.selected
            } else {
                out.append(key)
            }
        }
        return out
    }
}

/// `scene.playback_loop_mode` — what playback does at the end of the range.
/// The order is the order `_blenderkit_anim.LOOP_MODES` numbers them in.
public enum PlaybackLoopMode: Int, CaseIterable, Sendable {
    case infinite, stopEndFrame, stopStartFrame, restore, bounce

    /// Blender 5.2.1's own labels for the enum items.
    public var label: String {
        switch self {
        case .infinite:       return "Infinite"
        case .stopEndFrame:   return "Stop at End Frame"
        case .stopStartFrame: return "Stop at Start Frame"
        case .restore:        return "Restore Frame"
        case .bounce:         return "Bounce"
        }
    }

    public var bpyName: String {
        switch self {
        case .infinite:       return "INFINITE"
        case .stopEndFrame:   return "STOP_END_FRAME"
        case .stopStartFrame: return "STOP_START_FRAME"
        case .restore:        return "RESTORE"
        case .bounce:         return "BOUNCE"
        }
    }
}

/// Something Blender reports to its status bar that nothing else would show
/// here — auto keying that could not key, above all.
public struct AnimationNotice: Equatable, Sendable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// The scene's animation settings, as Blender has them.
///
/// The defaults are Blender 5.2.1's factory settings, measured by
/// scripts/run-animation-blender-check.sh, so the simulator's shim starts
/// where a device does.
public struct SceneAnimation: Equatable, Sendable {
    /// `render.fps / render.fps_base`.
    public var fps: Double = 24
    /// `scene.frame_subframe`: a keyframe jump can land between frames.
    public var subframe: Float = 0
    public var usePreviewRange = false
    public var previewStart = 0
    public var previewEnd = 0
    /// `tool_settings.use_keyframe_insert_auto` — the record button.
    public var autoKey = false
    /// `tool_settings.auto_keying_mode == 'REPLACE_KEYS'`.
    public var autoKeyReplace = false
    /// `preferences.edit.use_keyframe_insert_available`: "Insert Keyframes only
    /// for properties that are already animated". On by default in 5.2.1.
    public var onlyInsertAvailable = true
    /// `scene.show_keys_from_selected_only` — the timeline's Only Show Selected.
    public var onlySelectedKeys = true
    public var loopMode: PlaybackLoopMode = .infinite
    /// Keys on the scene itself and its world, which the timeline always counts.
    public var sceneKeys: [TimelineKey] = []
    public var notice: AnimationNotice?
    /// Whether the 3D View shows its Timeline. The interface's own, and not
    /// mirrored: in Blender the layout of editors is the screen's business.
    public var showsTimeline = false

    public init() {}
}

// MARK: - Blender's frame rules

public enum FrameRange {
    /// `MINFRAME` and `MAXFRAME`.
    public static let minFrame = 0
    public static let maxFrame = 1_048_574
    /// `MINAFRAME`: the preview range may start before frame 0.
    public static let minPreviewFrame = -1_048_574

    /// `scene.frame_start = value`: clamped, and the end moves with it rather
    /// than being left before it. Measured in 5.2.1: a start of 300 against an
    /// end of 250 leaves both at 300.
    public static func settingStart(_ value: Int, end: Int) -> (start: Int, end: Int) {
        let start = min(max(value, minFrame), maxFrame)
        return (start, max(end, start))
    }

    /// `scene.frame_end = value`, the same rule the other way: an end of 10
    /// against a start of 20 leaves both at 10.
    public static func settingEnd(_ value: Int, start: Int) -> (start: Int, end: Int) {
        let end = min(max(value, minFrame), maxFrame)
        return (min(start, end), end)
    }

    /// `scene.frame_preview_start = value` while the preview range is on: the
    /// same rule as the scene range's, down to `MINAFRAME`. Measured in 5.2.1.
    public static func settingPreviewStart(_ value: Int, end: Int) -> (start: Int, end: Int) {
        let start = min(max(value, minPreviewFrame), maxFrame)
        return (start, max(end, start))
    }

    public static func settingPreviewEnd(_ value: Int, start: Int) -> (start: Int, end: Int) {
        let end = min(max(value, minPreviewFrame), maxFrame)
        return (min(start, end), end)
    }

    /// `scene.use_preview_range = True`: a preview range that was never set —
    /// both ends 0 — becomes the scene range, and one that was is kept.
    /// Measured in 5.2.1.
    public static func enablingPreview(start: Int, end: Int,
                                       sceneStart: Int, sceneEnd: Int) -> (start: Int, end: Int) {
        start == 0 && end == 0 ? (sceneStart, sceneEnd) : (start, end)
    }

    /// `scene.frame_current = value`. Blender refuses negative frames unless
    /// Allow Negative Frames is set, and the range does not bound it: frame
    /// 400 of a 250-frame scene is a frame like any other.
    public static func current(_ value: Int) -> Int {
        min(max(value, minFrame), maxFrame)
    }
}

public extension BKObject {
    /// Blender's keys on this object and its data, on a device; the shim's
    /// own keys in the simulator, where nothing is mirrored.
    var timelineKeys: [TimelineKey] {
        if let mirroredKeys { return mirroredKeys }
        return animation.keyedFrames.map { TimelineKey(frame: Float($0)) }
    }
}

public extension BKScene {
    /// Where playback runs and Jump to Endpoint lands: the preview range when
    /// one is in use, as Blender's `use_preview_range` says — "an alternative
    /// start/end frame range for animation playback".
    var playbackRange: ClosedRange<Int> {
        let (a, b) = animation.usePreviewRange
            ? (animation.previewStart, animation.previewEnd)
            : (frameStart, frameEnd)
        return min(a, b)...max(a, b)
    }

    /// `scene.frame_float`.
    var frameFloat: Float { Float(frameCurrent) + animation.subframe }

    /// The timeline's summary row, and exactly what the keyframe jumps step
    /// through, so the two cannot disagree.
    ///
    /// Measured against `screen.keyframe_jump` in Blender 5.2.1: with Only Show
    /// Selected on it counts every *selected* object — not just the active one
    /// — together with its data, and with it off, every object. The scene's
    /// own keys count either way.
    var timelineKeys: [TimelineKey] {
        var keys = animation.sceneKeys
        for object in objects where !animation.onlySelectedKeys || selection.contains(object.id) {
            keys += object.timelineKeys
        }
        return TimelineKey.merged(keys)
    }

    /// Where `screen.keyframe_jump` goes from the current frame, or nil when
    /// Blender would report "No more keyframes to jump to in this direction".
    func keyframeJumpTarget(next: Bool) -> Float? {
        let now = frameFloat
        let keys = timelineKeys
        // Within float rounding of the current frame is the current frame: a
        // jump that lands on a subframe must not find the same key again.
        let epsilon: Float = 0.001
        return next ? keys.first(where: { $0.frame > now + epsilon })?.frame
                    : keys.last(where: { $0.frame < now - epsilon })?.frame
    }
}

// MARK: - Playback

/// Where playback is, given the time.
///
/// Blender offers three sync modes. This is Frame Dropping — "Drop frames if
/// playback is too slow" — for every scene: the frame shown is the one real
/// time says, however many that skips, so a heavy scene stays on time rather
/// than slowing down. (Blender 5.2.1's factory scene is set to Play Every
/// Frame; the app does not follow that, by design.)
public struct PlaybackClock: Equatable, Sendable {
    public private(set) var reverse: Bool
    /// Where playback began, for Restore Frame and for Cancel.
    public let startedFrom: Int
    private var anchorTime: Double
    private var anchorFrame: Int

    public init(frame: Int, time: Double, reverse: Bool = false) {
        self.reverse = reverse
        startedFrom = frame
        anchorTime = time
        anchorFrame = frame
    }

    public enum Step: Equatable, Sendable {
        /// Keep playing, showing this frame.
        case frame(Int)
        /// Playback is over; leave the scene on this frame.
        case stop(Int)
    }

    /// Restarts the count from a frame, as a jump during playback does.
    public mutating func restart(at frame: Int, time: Double) {
        anchorFrame = frame
        anchorTime = time
    }

    public mutating func step(at time: Double, fps: Double,
                              range: ClosedRange<Int>, loop: PlaybackLoopMode) -> Step {
        // The epsilon keeps a tick that lands exactly on a frame boundary from
        // rounding down to the frame before it.
        let advance = max(0, Int(((time - anchorTime) * max(fps, 0.001) + 1e-6).rounded(.down)))
        let frame = reverse ? anchorFrame - advance : anchorFrame + advance

        if !reverse {
            if frame < range.lowerBound {
                // Started before the range: playback belongs inside it.
                restart(at: range.lowerBound, time: time)
                return .frame(range.lowerBound)
            }
            guard frame > range.upperBound else { return .frame(frame) }
            // "After the last frame…" — the playback_loop_mode descriptions.
            switch loop {
            case .infinite:
                restart(at: range.lowerBound, time: time)
                return .frame(range.lowerBound)
            case .stopEndFrame:   return .stop(range.upperBound)
            case .stopStartFrame: return .stop(range.lowerBound)
            case .restore:        return .stop(startedFrom)
            case .bounce:
                reverse = true
                restart(at: range.upperBound, time: time)
                return .frame(range.upperBound)
            }
        }

        if frame > range.upperBound {
            restart(at: range.upperBound, time: time)
            return .frame(range.upperBound)
        }
        guard frame < range.lowerBound else { return .frame(frame) }
        // The same, running backwards: the "last" frame is the first one.
        switch loop {
        case .infinite:
            restart(at: range.upperBound, time: time)
            return .frame(range.upperBound)
        case .stopEndFrame:   return .stop(range.lowerBound)
        case .stopStartFrame: return .stop(range.upperBound)
        case .restore:        return .stop(startedFrom)
        case .bounce:
            reverse = false
            restart(at: range.lowerBound, time: time)
            return .frame(range.lowerBound)
        }
    }
}

// MARK: - The Python the timeline sends

/// Everything here is a string Blender runs, the same way `Bpy` is.
///
/// `bpy.ops.anim.keyframe_insert` and `keyframe_delete_v3d` cannot be among
/// them: both poll with `modify_key_op_poll`, which needs `CTX_wm_area`
/// (keyframing.cc), and the bpy module on an iPad has no area. So the keying
/// goes through `_blenderkit_anim`, which does what those operators do and is
/// held against them in tests/animation/blender/verify.py.
public enum BpyAnimation {
    public static let insertKeyframe = "import _blenderkit_anim\n_blenderkit_anim.keyframe_insert()"
    public static let deleteKeyframe = "import _blenderkit_anim\n_blenderkit_anim.keyframe_delete_v3d()"
    /// Blender's operator names, which are what it names the undo steps.
    public static let insertUndoName = "Insert Keyframe"
    public static let deleteUndoName = "Delete Keyframe"
    /// `delete_key_v3d_invoke`'s confirmation, word for word.
    public static let deleteConfirmation = "Delete keyframes from selected objects?"

    /// What a frame change prints when the viewport's object list has to be
    /// rebuilt — keyed visibility — rather than just moved.
    public static let fullMirrorMarker = "BK_ANIM_FULL_MIRROR"

    /// The whole mirroring pass, asked for as a question. Sent as a command it
    /// would count as a change to the scene, and the redo panel would close.
    public static let fullMirror = "import _blenderkit_sync as _bk_sync\n_bk_sync.sync()"

    public static func frameSet(_ frame: Int, subframe: Float = 0) -> String {
        "import _blenderkit_anim\n_blenderkit_anim.frame_set(\(frame), \(Double(subframe)))"
    }

    public static func setFrameStart(_ value: Int) -> String {
        "bpy.context.scene.frame_start = \(value)"
    }

    public static func setFrameEnd(_ value: Int) -> String {
        "bpy.context.scene.frame_end = \(value)"
    }

    public static func setPreviewStart(_ value: Int) -> String {
        "bpy.context.scene.frame_preview_start = \(value)"
    }

    public static func setPreviewEnd(_ value: Int) -> String {
        "bpy.context.scene.frame_preview_end = \(value)"
    }

    public static func setUsePreviewRange(_ on: Bool) -> String {
        "bpy.context.scene.use_preview_range = \(on ? "True" : "False")"
    }

    public static func setOnlySelectedKeys(_ on: Bool) -> String {
        "bpy.context.scene.show_keys_from_selected_only = \(on ? "True" : "False")"
    }

    public static func setLoopMode(_ mode: PlaybackLoopMode) -> String {
        "bpy.context.scene.playback_loop_mode = '\(mode.bpyName)'"
    }

    /// The record button and its popover. Through the module rather than as
    /// bare RNA, because "Only Insert Available" is a preference in Blender and
    /// a Python-side setting in the shim.
    public static func setAutoKeying(on: Bool? = nil, replace: Bool? = nil,
                                     onlyAvailable: Bool? = nil) -> String {
        func flag(_ name: String, _ value: Bool?) -> String? {
            value.map { "\(name)=\($0 ? "True" : "False")" }
        }
        let arguments = [flag("on", on), flag("replace", replace), flag("only_available", onlyAvailable)]
            .compactMap { $0 }.joined(separator: ", ")
        return "import _blenderkit_anim\n_blenderkit_anim.set_auto_keying(\(arguments))"
    }

    /// Which of the gizmo's transforms a command is, as Blender's transform
    /// modes name them, or nil for anything else.
    public static func transformMode(of python: String) -> String? {
        let lines = python.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, let line = lines.first else { return nil }
        if line.hasPrefix("bpy.ops.transform.translate(") { return "TRANSLATE" }
        if line.hasPrefix("bpy.ops.transform.rotate(") { return "ROTATE" }
        if line.hasPrefix("bpy.ops.transform.resize(") { return "RESIZE" }
        return nil
    }

    public static func afterTransform(_ mode: String) -> String {
        "import _blenderkit_anim\n_blenderkit_anim.after_transform('\(mode)')"
    }
}

public extension Bpy {
    /// What auto keying adds to a gizmo transform, in the transform's own
    /// evaluation — one undo step, one mirror.
    ///
    /// On a device Blender keys inside `bpy.ops.transform.*` itself (measured
    /// headless in 5.2.1); the follow-up only says why nothing was keyed when
    /// "Only Insert Available" stopped it, which Blender reports to a window
    /// manager nobody can see here. In the simulator the follow-up does the
    /// keying, because the shim's transforms do not.
    ///
    /// Empty when auto keying is off, so every other command is sent exactly
    /// as it was.
    static func autoKeying(after python: String, scene: BKScene?, interpreter: Bool) -> [String] {
        guard interpreter, let scene, scene.animation.autoKey,
              let mode = BpyAnimation.transformMode(of: python) else { return [] }
        return [BpyAnimation.afterTransform(mode)]
    }
}

// MARK: - The timeline's controller

/// Frame changes, playback and keying, from the timeline, the 3D View's keys
/// and the menu bar alike.
@Observable
public final class TimelineDriver {

    /// Whether playback is running, and which way. Kept apart from the clock,
    /// which changes on every refresh: observing that would redraw everything
    /// that shows a play button sixty times a second.
    public private(set) var isPlaying = false
    public private(set) var isPlayingReverse = false

    @ObservationIgnored private var clock: PlaybackClock?
    @ObservationIgnored public private(set) weak var scene: BKScene?
    @ObservationIgnored public private(set) weak var session: BpySession?
    @ObservationIgnored public private(set) weak var bridge: BpyBridge?

    /// Runs a block on the next turn of the main run loop. Tests replace it.
    @ObservationIgnored public var schedule: (@escaping () -> Void) -> Void = {
        DispatchQueue.main.async(execute: $0)
    }
    /// Seconds on a monotonic clock. Tests replace it.
    @ObservationIgnored public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    @ObservationIgnored private var pending: (frame: Int, subframe: Float)?
    @ObservationIgnored private var flushScheduled = false
    /// How many frame changes were sent, for the tests.
    @ObservationIgnored public private(set) var framesSent = 0

    public init() {}

    public func bind(scene: BKScene, session: BpySession, bridge: BpyBridge?) {
        self.scene = scene
        self.session = session
        self.bridge = bridge
    }

    /// Nothing may reach the interpreter while a script holds it.
    public var isAvailable: Bool { session.map { !$0.isRunning } ?? false }

    // MARK: frames

    /// Changes the frame now.
    ///
    /// `scene.frame_set`, and then only what the frame changed comes back:
    /// matrices for what moved, meshes for what deformed. It used to be a
    /// whole mirroring pass per frame — every mesh in the scene re-read and
    /// compared — which is what made playback a slideshow.
    @discardableResult
    public func setFrame(_ frame: Int, subframe: Float = 0) -> Bool {
        guard let scene, let session, !session.isRunning else { return false }
        let target = FrameRange.current(frame)
        framesSent += 1
        guard session.isRealRuntime else {
            // The command subset has no Python, and the Swift model is the
            // scene: setting the frame evaluates its animation.
            scene.animation.subframe = 0
            scene.frameCurrent = target
            return true
        }
        guard let answer = session.capture(BpyAnimation.frameSet(target, subframe: subframe)) else {
            // The traceback is in the console; playback must not repeat it
            // sixty times a second.
            stopPlayback()
            return false
        }
        if answer.contains(BpyAnimation.fullMirrorMarker) {
            _ = session.capture(BpyAnimation.fullMirror)
        }
        return true
    }

    /// Changes the frame on the next turn of the run loop, keeping only the
    /// latest request: a scrub moves faster than a heavy scene evaluates, and
    /// the frames in between are not worth waiting for.
    public func requestFrame(_ frame: Int, subframe: Float = 0) {
        pending = (frame, subframe)
        guard !flushScheduled else { return }
        flushScheduled = true
        schedule { [weak self] in self?.flushPendingFrame() }
    }

    public func flushPendingFrame() {
        flushScheduled = false
        guard let request = pending else { return }
        pending = nil
        setFrame(request.frame, subframe: request.subframe)
    }

    /// A drag along the timeline. Playback carries on from wherever the drag
    /// puts the playhead, as it does when scrubbing in Blender while playing.
    public func scrub(to frame: Int) {
        let target = FrameRange.current(frame)
        if clock != nil { clock?.restart(at: target, time: now()) }
        requestFrame(target)
    }

    /// `screen.frame_offset` — the arrow keys. Not bounded by the range.
    public func offset(_ delta: Int) {
        guard let scene else { return }
        move(to: scene.frameCurrent + delta)
    }

    /// `screen.frame_jump`, to the preview range when one is set.
    public func jumpToEndpoint(end: Bool) {
        guard let scene else { return }
        let range = scene.playbackRange
        move(to: end ? range.upperBound : range.lowerBound)
    }

    /// `screen.keyframe_jump`. False when there is nothing that way.
    @discardableResult
    public func jumpToKeyframe(next: Bool) -> Bool {
        guard let scene, let target = scene.keyframeJumpTarget(next: next) else { return false }
        let whole = target.rounded(.down)
        move(to: Int(whole), subframe: target - whole)
        return true
    }

    private func move(to frame: Int, subframe: Float = 0) {
        let target = FrameRange.current(frame)
        if clock != nil { clock?.restart(at: target, time: now()) }
        setFrame(target, subframe: subframe)
    }

    // MARK: playback

    /// `screen.animation_play`.
    public func play(reverse: Bool = false) {
        guard let scene, isAvailable else { return }
        clock = PlaybackClock(frame: scene.frameCurrent, time: now(), reverse: reverse)
        isPlaying = true
        isPlayingReverse = reverse
    }

    /// `screen.animation_pause`: "stopping at the current frame".
    public func pause() {
        stopPlayback()
    }

    /// `screen.animation_cancel`: "returning to the original frame" — Esc.
    public func cancel() {
        guard let started = clock?.startedFrom else { return }
        stopPlayback()
        setFrame(started)
    }

    /// The play button, which Blender's header turns into Pause while playing.
    public func togglePlay(reverse: Bool = false) {
        if isPlaying { pause() } else { play(reverse: reverse) }
    }

    private func stopPlayback() {
        clock = nil
        if isPlaying { isPlaying = false }
        if isPlayingReverse { isPlayingReverse = false }
    }

    /// One display refresh while playing.
    public func tick() {
        guard var running = clock, let scene else { return }
        guard isAvailable else { stopPlayback(); return }
        let step = running.step(at: now(), fps: scene.animation.fps,
                                range: scene.playbackRange, loop: scene.animation.loopMode)
        switch step {
        case .frame(let frame):
            clock = running
            if running.reverse != isPlayingReverse { isPlayingReverse = running.reverse }
            // A drag in progress is previewing on the objects the frame would
            // move; the clock keeps running, and the frames it passes are
            // dropped until the drag lets go.
            guard scene.transformReadout == nil else { return }
            if frame != scene.frameCurrent || scene.animation.subframe != 0 {
                setFrame(frame)
            }
        case .stop(let frame):
            stopPlayback()
            if frame != scene.frameCurrent { setFrame(frame) }
        }
    }

    // MARK: keys

    /// I — Blender's default channels on the selection, as one undo step.
    public func insertKeyframe() {
        guard let scene, let session, !session.isRunning else { return }
        if session.isRealRuntime {
            bridge?.run(BpyAnimation.insertKeyframe, undo: BpyAnimation.insertUndoName)
        } else if scene.insertKeyframe() > 0 {
            session.log("bpy.ops.anim.keyframe_insert()")
        }
    }

    /// Alt I — the selection's keys on this frame, as one undo step.
    public func deleteKeyframe() {
        guard let scene, let session, !session.isRunning else { return }
        if session.isRealRuntime {
            bridge?.run(BpyAnimation.deleteKeyframe, undo: BpyAnimation.deleteUndoName)
        } else if scene.deleteKeyframe() > 0 {
            session.log("bpy.ops.anim.keyframe_delete_v3d()")
        }
    }

    // MARK: settings

    /// The Start field. Blender's own rules apply, so the value shown at once
    /// is the value Blender keeps; the mirror confirms it. The undo steps are
    /// named as Blender names them: after the property.
    public func setFrameStart(_ value: Int) {
        guard let scene, let session, !session.isRunning else { return }
        let range = FrameRange.settingStart(value, end: scene.frameEnd)
        if session.isRealRuntime { bridge?.run(BpyAnimation.setFrameStart(range.start), undo: "Start Frame") }
        apply(range, to: scene)
    }

    public func setFrameEnd(_ value: Int) {
        guard let scene, let session, !session.isRunning else { return }
        let range = FrameRange.settingEnd(value, start: scene.frameStart)
        if session.isRealRuntime { bridge?.run(BpyAnimation.setFrameEnd(range.end), undo: "End Frame") }
        apply(range, to: scene)
    }

    private func apply(_ range: (start: Int, end: Int), to scene: BKScene) {
        if scene.frameStart != range.start { scene.frameStart = range.start }
        if scene.frameEnd != range.end { scene.frameEnd = range.end }
    }

    public func setPreviewStart(_ value: Int) {
        guard let scene, let session, !session.isRunning else { return }
        let range = FrameRange.settingPreviewStart(value, end: scene.animation.previewEnd)
        if session.isRealRuntime {
            bridge?.run(BpyAnimation.setPreviewStart(range.start), undo: "Preview Range Start Frame")
        }
        applyPreview(range, to: scene)
    }

    public func setPreviewEnd(_ value: Int) {
        guard let scene, let session, !session.isRunning else { return }
        let range = FrameRange.settingPreviewEnd(value, start: scene.animation.previewStart)
        if session.isRealRuntime {
            bridge?.run(BpyAnimation.setPreviewEnd(range.end), undo: "Preview Range End Frame")
        }
        applyPreview(range, to: scene)
    }

    /// The preview-range toggle. Switched on with no preview range set, it
    /// takes the scene range, as Blender's does.
    public func setUsePreviewRange(_ on: Bool) {
        guard let scene, let session, !session.isRunning else { return }
        if session.isRealRuntime { bridge?.run(BpyAnimation.setUsePreviewRange(on), undo: "Use Preview Range") }
        var a = scene.animation
        if on {
            let seeded = FrameRange.enablingPreview(start: a.previewStart, end: a.previewEnd,
                                                    sceneStart: scene.frameStart, sceneEnd: scene.frameEnd)
            a.previewStart = seeded.start
            a.previewEnd = seeded.end
        }
        a.usePreviewRange = on
        if a != scene.animation { scene.animation = a }
    }

    private func applyPreview(_ range: (start: Int, end: Int), to scene: BKScene) {
        var a = scene.animation
        a.previewStart = range.start
        a.previewEnd = range.end
        if a != scene.animation { scene.animation = a }
    }

    public func setAutoKeying(_ on: Bool) {
        guard let scene, let session, !session.isRunning else { return }
        scene.animation.autoKey = on
        if session.isRealRuntime { _ = session.capture(BpyAnimation.setAutoKeying(on: on)) }
    }

    public func setAutoKeyingReplace(_ replace: Bool) {
        guard let scene, let session, !session.isRunning else { return }
        scene.animation.autoKeyReplace = replace
        if session.isRealRuntime { _ = session.capture(BpyAnimation.setAutoKeying(replace: replace)) }
    }

    public func setOnlyInsertAvailable(_ on: Bool) {
        guard let scene, let session, !session.isRunning else { return }
        scene.animation.onlyInsertAvailable = on
        if session.isRealRuntime { _ = session.capture(BpyAnimation.setAutoKeying(onlyAvailable: on)) }
    }

    public func setOnlySelectedKeys(_ on: Bool) {
        guard let scene, let session, !session.isRunning else { return }
        scene.animation.onlySelectedKeys = on
        if session.isRealRuntime { _ = session.capture(BpyAnimation.setOnlySelectedKeys(on)) }
    }

    public func setLoopMode(_ mode: PlaybackLoopMode) {
        guard let scene, let session, !session.isRunning else { return }
        scene.animation.loopMode = mode
        if session.isRealRuntime { _ = session.capture(BpyAnimation.setLoopMode(mode)) }
    }

    public func dismissNotice(_ id: Int) {
        guard let scene, scene.animation.notice?.id == id else { return }
        scene.animation.notice = nil
    }
}
