import Foundation
import CoreGraphics

// The Timeline as an animation editor: its keys selected, moved, copied and
// retimed, its markers, its view — the parts that need no interface, so
// tests/timeline runs them on the Mac.
//
// Blender does the editing (`_blenderkit_keys`, its own `action.*`, `marker.*`
// and `transform.transform` under the startup screen's Timeline). What lives
// here is what the interface decides before it asks: which column a finger is
// on, the frames a box spans, where a dragged key lands, how the numbers along
// the top read, where the markers' names go — and the Python each control
// sends, with the undo step Blender names after its operator.

// MARK: - Keys and markers

/// Blender's key types (`BEZT_KEYTYPE_*`), numbered as `foreach_get('type')`
/// reads them and `_blenderkit_anim.report_keys` packs them.
public enum KeyframeType: Int, CaseIterable, Sendable {
    case keyframe = 0, extreme = 1, breakdown = 2, jitter = 3, movingHold = 4, generated = 5

    /// R's menu, in the enum's order (`rna_enum_beztriple_keyframe_type_items`).
    public static let menuOrder: [KeyframeType] = [.keyframe, .breakdown, .movingHold, .extreme, .jitter, .generated]

    public var identifier: String {
        switch self {
        case .keyframe: return "KEYFRAME"
        case .extreme: return "EXTREME"
        case .breakdown: return "BREAKDOWN"
        case .jitter: return "JITTER"
        case .movingHold: return "MOVING_HOLD"
        case .generated: return "GENERATED"
        }
    }

    /// The enum item's name, as Blender 5.2.1 lists it.
    public var name: String {
        switch self {
        case .keyframe: return "Keyframe"
        case .extreme: return "Extreme"
        case .breakdown: return "Breakdown"
        case .jitter: return "Jitter"
        case .movingHold: return "Moving Hold"
        case .generated: return "Generated"
        }
    }

    /// How much bigger or smaller `draw_keyframe_shape` draws it
    /// (keyframes_draw.cc).
    public var size: CGFloat {
        switch self {
        case .keyframe: return 1
        case .extreme: return 1.2
        case .breakdown: return 0.85
        case .jitter: return 0.8
        case .movingHold: return 0.925
        case .generated: return 0.75
        }
    }
}

/// One of `scene.timeline_markers`.
public struct TimelineMarker: Equatable, Sendable {
    public var name: String
    public var frame: Int
    public var selected: Bool
    /// The camera Bind Camera to Markers bound it to.
    public var camera: String?

    public init(name: String, frame: Int, selected: Bool = false, camera: String? = nil) {
        self.name = name; self.frame = frame; self.selected = selected; self.camera = camera
    }

    /// What Blender writes beside it: a bound marker shows its camera's name
    /// (`draw_marker_name`).
    public var shownName: String { camera ?? name }
}

public extension BKScene {
    /// Where `screen.marker_jump` goes: the nearest marker after the frame,
    /// or before it; nil for Blender's "No more markers to jump to in this
    /// direction".
    func markerJumpTarget(next: Bool) -> Int? {
        let now = frameCurrent
        let frames = animation.markers.map(\.frame)
        return next ? frames.filter { $0 > now }.min() : frames.filter { $0 < now }.max()
    }

    /// The selected columns' frames, for Frame Selected.
    var selectedKeyFrames: [Float] { timelineKeys.filter(\.selected).map(\.frame) }
}

// MARK: - The view

/// Which frames the Timeline shows across its width, as Blender's View2D
/// `cur` does. Starts as Frame Scene Range; a pinch zooms it, a two-finger
/// drag pans it, Home frames every key.
public struct TimelineWindow: Equatable, Sendable {
    public var first: Double
    public var last: Double
    public var width: CGFloat

    /// The narrowest and widest a zoom may go, in frames.
    public static let minimumSpan: Double = 2
    public static let maximumSpan: Double = Double(FrameRange.maxFrame) * 2

    public init(first: Double, last: Double, width: CGFloat) {
        self.first = first
        self.last = max(last, first + 0.001)
        self.width = max(width, 1)
    }

    /// Frame Scene Range (`anim.scene_range_frame`): the range with Blender's
    /// margin either side (`ANIM_frame_range_view2d_add_xmargin`: four
    /// keyframes' width, 40 points, at most an eighth of the range).
    public init(range: ClosedRange<Int>, width: CGFloat) {
        self = Self.framing(Double(range.lowerBound), Double(range.upperBound), width: width)
    }

    public static func framing(_ lo: Double, _ hi: Double, width: CGFloat) -> TimelineWindow {
        let span = max(hi - lo, 0)
        let w = Double(max(width, 1))
        let margin = min(40 * span / w, 0.125 * span)
        var lo = lo - margin, hi = hi + margin
        if hi - lo < minimumSpan {
            let middle = (lo + hi) / 2
            lo = middle - minimumSpan / 2
            hi = middle + minimumSpan / 2
        }
        return TimelineWindow(first: lo, last: hi, width: width)
    }

    public var span: Double { last - first }
    public var pixelsPerFrame: Double { Double(width) / span }

    public func x(_ frame: Double) -> CGFloat {
        CGFloat((frame - first) / span) * width
    }

    public func frame(at x: CGFloat) -> Double {
        first + Double(x / width) * span
    }

    /// The whole frame nearest a point — a scrub snaps to frames.
    public func wholeFrame(at x: CGFloat) -> Int {
        Int(frame(at: x).rounded())
    }

    /// The same frames across another width, as a resized area keeps them.
    public func resized(to width: CGFloat) -> TimelineWindow {
        TimelineWindow(first: first, last: last, width: width)
    }

    /// A pinch: `scale` over 1 zooms in, about the point `x` stays under.
    public func zoomed(by scale: Double, about x: CGFloat) -> TimelineWindow {
        guard scale > 0, scale.isFinite else { return self }
        let anchor = frame(at: x)
        let newSpan = min(max(span / scale, Self.minimumSpan), Self.maximumSpan)
        let share = Double(x / width)
        let first = anchor - share * newSpan
        return TimelineWindow(first: first, last: first + newSpan, width: width)
    }

    /// A two-finger drag or a trackpad's scroll: the frames follow the
    /// fingers, `dx` points.
    public func panned(by dx: CGFloat) -> TimelineWindow {
        let frames = Double(dx) / pixelsPerFrame
        return TimelineWindow(first: first - frames, last: last - frames, width: width)
    }

    /// Go to Current Frame (`action.view_frame`, Numpad 0): the same span,
    /// centred on the frame (Preferences' View Frame default, Keep Range).
    public func centred(on frame: Double) -> TimelineWindow {
        TimelineWindow(first: frame - span / 2, last: frame + span / 2, width: width)
    }

    /// Frame All and Frame Selected (`actkeys_viewall`): the keys' extent
    /// with the margin; one key — less than a frame across — centred with
    /// the span kept. Frame All with no keys frames the scene's range
    /// (`get_keyframe_extents`); Frame Selected with none changes nothing.
    public func framingKeys(_ frames: [Float], sceneRange: ClosedRange<Int>?) -> TimelineWindow? {
        var lo: Double, hi: Double
        if let min = frames.min(), let max = frames.max() {
            lo = Double(min); hi = Double(max)
        } else if let sceneRange {
            lo = Double(sceneRange.lowerBound); hi = Double(sceneRange.upperBound)
        } else {
            return nil
        }
        if abs(hi - lo) < 1 {
            return TimelineWindow(first: lo - span / 2, last: hi + span / 2, width: width)
        }
        return Self.framing(lo, hi, width: width)
    }

    // MARK: the numbers along the top

    /// Frames between numbers (`calculate_grid_step`, view2d_draw.cc): from
    /// the scene's rate, halved and thirded down to whole frames while the
    /// numbers stay `minimumDistance` apart — 24, 12, 6, 2, 1 at 24 fps,
    /// doubling up — preferring a step of 2, which animators work on.
    public func step(base: Int, minimumDistance: Double) -> Int {
        TimelineGrid.step(base: base, pixelsPerFrame: pixelsPerFrame, minimumDistance: minimumDistance)
    }

    /// The numbered frames across the window.
    public func numbered(step: Int) -> [Int] {
        let step = max(step, 1)
        var frames: [Int] = []
        var f = Int((first / Double(step)).rounded(.up)) * step
        while Double(f) <= last, frames.count < 2000 {
            frames.append(f)
            f += step
        }
        return frames
    }
}

/// Blender's grid step for its time scales (view2d_draw.cc, 5.3).
public enum TimelineGrid {
    /// `get_divisor`: 2, 3 or 5, preferring one that leaves 2.
    public static func divisor(_ distance: Int) -> Int {
        let divisors = [2, 3, 5]
        var clean: [Bool] = []
        for d in divisors {
            let result = distance / d
            let exact = result * d == distance
            if exact && result == 2 { return d }
            clean.append(exact)
        }
        for (i, d) in divisors.enumerated() where clean[i] { return d }
        return distance
    }

    /// `calculate_grid_step`.
    public static func step(base: Int, pixelsPerFrame: Double, minimumDistance: Double) -> Int {
        guard pixelsPerFrame > 0, pixelsPerFrame.isFinite else { return 1 }
        var distance = max(base, 1)
        if pixelsPerFrame * Double(distance) > minimumDistance {
            while distance > 1 {
                let result = distance / divisor(distance)
                if pixelsPerFrame * Double(result) < minimumDistance { break }
                distance = result
            }
        } else {
            while pixelsPerFrame * Double(distance) < minimumDistance && distance < (1 << 30) {
                distance *= 2
            }
        }
        return max(distance, 1)
    }

    /// `U.v2d_min_gridsize`: 45 pixels.
    public static let minimumGridSize: Double = 45

    /// The least distance between numbers (`get_min_line_distance_x`): the
    /// wider of the grid's minimum and the widest label, from the window's
    /// two ends, plus 6 — at about 6 points a character here.
    public static func minimumDistance(labels: [String]) -> Double {
        let widest = labels.map { Double($0.count) * 6 }.max() ?? 0
        return max(minimumGridSize, widest + 6)
    }
}

/// Use Timecode (`show_seconds`, Ctrl+T): frames as time, in Blender's
/// default Timecode Style, Minimal (`BLI_timecode_string_from_time`,
/// timecode.cc).
public enum Timecode {
    /// `brevity` 0 or less includes the frames after a "+"; above 0 rounds
    /// to whole seconds.
    public static func string(seconds timeSeconds: Double, fps: Double, brevity: Int) -> String {
        var time = Float(timeSeconds)
        var neg = ""
        if time < 0 {
            neg = "-"
            time = -time
        }
        var hours = 0, minutes = 0, seconds = 0, frames = 0
        if time >= 3600 {
            hours = Int(time) / 3600
            time = fmodf(time, 3600)
        }
        if time >= 60 {
            minutes = Int(time) / 60
            time = fmodf(time, 60)
        }
        if brevity <= 0 {
            seconds = Int(time)
            frames = Int(((Double(time) - Double(seconds)) * fps).rounded())
        } else {
            seconds = Int(time.rounded())
        }
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if brevity <= 0 {
            if hours != 0 { return "\(neg)\(two(hours)):\(two(minutes)):\(two(seconds))+\(two(frames))" }
            if minutes != 0 { return "\(neg)\(two(minutes)):\(two(seconds))+\(two(frames))" }
            return "\(neg)00:\(two(seconds))+\(two(frames))"
        }
        if hours != 0 { return "\(neg)\(two(hours)):\(two(minutes)):\(two(seconds))" }
        return "\(neg)\(two(minutes)):\(two(seconds))"
    }

    /// The playhead's box (`get_current_time_str`): always with the frames.
    public static func playhead(frame: Double, fps: Double) -> String {
        string(seconds: frame / max(fps, 0.001), fps: fps, brevity: -1)
    }

    /// A number along the top (`frame_to_time_string`): whole seconds when
    /// the numbers are a second or more apart, else with the frames.
    public static func label(frame: Double, step: Int, fps: Double) -> String {
        let brevity = Double(step) >= fps ? 1 : -1
        return string(seconds: frame / max(fps, 0.001), fps: fps, brevity: brevity)
    }
}

// MARK: - Fingers on the timeline

/// What is under a point of the timeline's body.
public enum TimelineHit {
    /// The column nearest `x` within `radius` points — a fingertip's reach
    /// where Blender's mouse has 7 pixels; the nearest wins when columns
    /// crowd together.
    public static func column(at x: CGFloat, in keys: [TimelineKey], window: TimelineWindow,
                              radius: CGFloat) -> TimelineKey? {
        var best: (key: TimelineKey, distance: CGFloat)?
        for key in keys {
            let d = abs(window.x(Double(key.frame)) - x)
            guard d <= radius else { continue }
            if best == nil || d < best!.distance { best = (key, d) }
        }
        return best?.key
    }

    /// The frames a box from `x0` to `x1` spans, either way round.
    public static func frames(from x0: CGFloat, to x1: CGFloat, window: TimelineWindow) -> (Double, Double) {
        let a = window.frame(at: x0), b = window.frame(at: x1)
        return (min(a, b), max(a, b))
    }

    /// The columns inside a frame range, as Blender's box takes a key
    /// (BEZT_OK_FRAMERANGE).
    public static func columns(in range: (Double, Double), of keys: [TimelineKey]) -> [TimelineKey] {
        keys.filter { Double($0.frame) >= range.0 && Double($0.frame) <= range.1 }
    }

    /// The marker under `x` (its index in the scene's list), nearest first.
    public static func marker(at x: CGFloat, in markers: [TimelineMarker], window: TimelineWindow,
                              radius: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, m) in markers.enumerated() {
            let d = abs(window.x(Double(m.frame)) - x)
            guard d <= radius else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// A drag counts as one once it has gone this far; until then a press
    /// is a tap (Blender's drag threshold, 3 pixels for a mouse, wider for a
    /// finger).
    public static let dragThreshold: CGFloat = 6
}

/// The scene's Snap for keys, as a drag previews it (`_blenderkit_keys.snap_state`).
public struct TimelineSnap: Equatable, Sendable {
    /// `tool_settings.use_snap_anim`, on in 5.2.1's factory settings.
    public var on = true
    /// `snap_anim_element`: FRAME by default.
    public var element = "FRAME"
    /// `use_snap_time_absolute`: each key onto a whole frame rather than the
    /// move by whole frames.
    public var absolute = false
    public var fps: Double = 24

    public init(on: Bool = true, element: String = "FRAME", absolute: Bool = false, fps: Double = 24) {
        self.on = on; self.element = element; self.absolute = absolute; self.fps = fps
    }

    /// `BK_KEYS_SNAP 1 FRAME 0 24.0`.
    public static func parse(_ text: String) -> TimelineSnap? {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("BK_KEYS_SNAP ") }) else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 5, let fps = Double(parts[4]) else { return nil }
        return TimelineSnap(on: parts[1] == "1", element: String(parts[2]), absolute: parts[3] == "1", fps: fps)
    }

    /// Whether a drag snaps: the scene's Snap, the other way round while Ctrl
    /// is held (Blender's Snap Invert).
    public func snapping(inverted: Bool) -> Bool { on != inverted }

    /// The move a drag of `raw` frames makes, as TIME_TRANSLATE snaps it:
    /// whole frames (or seconds) for the move; with Absolute Time Snap the
    /// keys snap one by one instead (`landing`).
    public func delta(_ raw: Double, inverted: Bool = false) -> Double {
        guard snapping(inverted: inverted), !absolute else { return raw }
        if element.contains("SECOND") {
            let unit = max(fps, 1)
            return (raw / unit).rounded() * unit
        }
        return raw.rounded()
    }

    /// Where a key at `frame` lands after a move of `raw` frames.
    public func landing(_ frame: Double, raw: Double, inverted: Bool = false) -> Double {
        if snapping(inverted: inverted), absolute {
            if element.contains("SECOND") {
                let unit = max(fps, 1)
                return ((frame + raw) / unit).rounded() * unit
            }
            return (frame + raw).rounded()
        }
        return frame + delta(raw, inverted: inverted)
    }

    /// Where a key lands under S, scaled `factor` about `pivot`.
    public func scaled(_ frame: Double, factor: Double, pivot: Double, inverted: Bool = false) -> Double {
        let raw = pivot + (frame - pivot) * factor
        return snapping(inverted: inverted) ? raw.rounded() : raw
    }
}

/// What a drag of the selected keys shows before it lets go: the selected
/// columns where they would land, and what stays behind (the unselected
/// columns, the unselected part of a partly selected one, and the
/// originals of a Duplicate).
public enum TimelinePreview {
    public static func moved(_ keys: [TimelineKey], raw: Double, snap: TimelineSnap, inverted: Bool,
                             duplicate: Bool) -> [TimelineKey] {
        var out: [TimelineKey] = []
        for key in keys {
            if key.selected {
                var moved = key
                moved.frame = Float(snap.landing(Double(key.frame), raw: raw, inverted: inverted))
                moved.partial = false
                out.append(moved)
                if key.partial || duplicate {
                    out.append(TimelineKey(frame: key.frame, selected: false, type: key.type))
                }
            } else {
                out.append(key)
            }
        }
        return out
    }

    public static func scaled(_ keys: [TimelineKey], factor: Double, pivot: Double, snap: TimelineSnap,
                              inverted: Bool) -> [TimelineKey] {
        keys.flatMap { key -> [TimelineKey] in
            guard key.selected else { return [key] }
            var moved = key
            moved.frame = Float(snap.scaled(Double(key.frame), factor: factor, pivot: pivot, inverted: inverted))
            moved.partial = false
            return key.partial ? [moved, TimelineKey(frame: key.frame, selected: false, type: key.type)] : [moved]
        }
    }
}

// MARK: - Markers as Blender draws them

public enum TimelineMarkerLayout {
    /// One marker as `ED_markers_draw` places it.
    public struct Placed: Equatable, Sendable {
        /// Its index in the scene's list.
        public var index: Int
        public var marker: TimelineMarker
        /// Selected, or the one the current frame is at or past (until the
        /// next): its name sits higher and is drawn last, unclipped.
        public var elevated: Bool
        /// Where a lower name must end: the next marker's frame.
        public var nameEnd: Double?
    }

    /// The markers sorted by frame (`markers_frame_sort`), each elevated or
    /// not, with the frame its name is clipped at.
    public static func place(_ markers: [TimelineMarker], current: Int) -> [Placed] {
        let sorted = markers.enumerated().sorted { a, b in
            a.element.frame != b.element.frame ? a.element.frame < b.element.frame : a.offset < b.offset
        }
        var out: [Placed] = []
        for (i, entry) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1].element.frame : nil
            let marker = entry.element
            let elevated = marker.selected || (current >= marker.frame && (next == nil || current < next!))
            out.append(Placed(index: entry.offset, marker: marker, elevated: elevated,
                              nameEnd: next.map(Double.init)))
        }
        // Elevated ones last, on top.
        return out.filter { !$0.elevated } + out.filter(\.elevated)
    }
}

// MARK: - What each control sends

/// A Timeline action, by Blender's operator, with what it is run with —
/// shared by the header's menus, the right-click menu, the keys and the
/// `-timeline-ops` launch hook.
public enum TimelineAction: Equatable, Sendable {
    case selectAll(String)
    case selectColumn(String)
    case selectLeftRight(String)
    case selectLinked, selectMore, selectLess
    case delete
    case clean(channels: Bool)
    case copy
    case paste(flipped: Bool)
    case snap(String)
    case mirror(String)
    case jumpToKeys
    case interpolation(String)
    case easing(String)
    case keyframeType(String)
    case handleType(String)
    case insert(String)
    case markerAdd
    case markerDelete
    case markerSelectAll(String)
    case markerSelectLeftRight(String)
    case markerCameraBind
    case lockMarkers(Bool)
}

public enum BpyKeys {
    static let module = "import _blenderkit_keys"

    /// What a selection prints when it changed nothing: no undo step then.
    public static let unchanged = "BK_KEYS_UNCHANGED"

    private static func command(_ call: String, _ body: String, undo: String?) -> BlenderCommand {
        BlenderCommand(call: call, body: module + "\n_blenderkit_keys." + body, undo: undo)
    }

    private static func bool(_ b: Bool) -> String { b ? "True" : "False" }

    private static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%.4f", value)
    }

    /// A tap on a column (`action.clickselect`): Shift extends, and a tap on
    /// none of them (`frame` nil) deselects every key.
    public static func clickSelect(frame: Float?, extend: Bool) -> BlenderCommand {
        let call = extend ? "bpy.ops.action.clickselect(extend=True)"
                          : "bpy.ops.action.clickselect(deselect_all=True)"
        let at = frame.map { String(format: "%.4f", Double($0)) } ?? "float('nan')"
        return command(call, "click_select(\(at), extend=\(bool(extend)))", undo: "Select Keyframes")
    }

    /// A box across the keys (`action.select_box`): SET, ADD with Shift,
    /// SUB with Ctrl.
    public static func boxSelect(from first: Double, to last: Double, mode: String) -> BlenderCommand {
        command("bpy.ops.action.select_box(mode='\(mode)')",
                "box_select(\(String(format: "%.4f", first)), \(String(format: "%.4f", last)), mode='\(mode)')",
                undo: "Box Select")
    }

    /// Before and After Current Frame, and Ctrl+click's side of it
    /// (`action.select_leftright`); Shift extends.
    public static func selectLeftRight(_ mode: String, extend: Bool) -> BlenderCommand {
        command("bpy.ops.action.select_leftright(mode='\(mode)', extend=\(bool(extend)))",
                "select_leftright('\(mode)', extend=\(bool(extend)))", undo: "Select Left/Right")
    }

    /// G and a drag (`transform.transform`, TIME_TRANSLATE), by `delta`
    /// frames — or Shift+D's copies moved (`action.duplicate_move`). `snap`
    /// turns the scene's Snap round for the move (Ctrl held, Blender's Snap
    /// Invert); nil leaves it as the scene has it.
    public static func move(by delta: Double, duplicate: Bool, snap: Bool? = nil) -> BlenderCommand {
        let d = number(delta)
        let s = snap.map { ", snap=\(bool($0))" } ?? ""
        if duplicate {
            return command("bpy.ops.action.duplicate_move(TRANSFORM_OT_transform={'value': (\(d), 0, 0, 0)})",
                           "duplicate_move(\(d)\(s))", undo: "Duplicate")
        }
        return command("bpy.ops.transform.transform(mode='TIME_TRANSLATE', value=(\(d), 0, 0, 0))",
                       "move(\(d)\(s))", undo: "Transform")
    }

    /// S (`transform.transform`, TIME_SCALE) about the current frame.
    public static func scale(by factor: Double, snap: Bool? = nil) -> BlenderCommand {
        let f = String(format: "%.4f", factor)
        let s = snap.map { ", snap=\(bool($0))" } ?? ""
        return command("bpy.ops.transform.transform(mode='TIME_SCALE', value=(\(f), 0, 0, 0))",
                       "scale(\(f)\(s))", undo: "Transform")
    }

    /// A marker tapped (`marker.select`): `index` in the scene's list, -1 for
    /// a tap beside every marker.
    public static func markerSelect(index: Int, extend: Bool) -> BlenderCommand {
        command(extend ? "bpy.ops.marker.select(extend=True)" : "bpy.ops.marker.select()",
                "marker_select(\(index), extend=\(bool(extend)))", undo: "Select Time Marker")
    }

    /// G over the markers and a marker dragged (`marker.move`), or Shift+D's
    /// copies (`marker.duplicate`).
    public static func markerMove(by frames: Int, duplicate: Bool) -> BlenderCommand {
        duplicate
            ? command("bpy.ops.marker.duplicate(frames=\(frames))", "marker_duplicate(\(frames))",
                      undo: "Duplicate Time Marker")
            : command("bpy.ops.marker.move(frames=\(frames))", "marker_move(\(frames))", undo: "Move Time Marker")
    }

    /// F2's Rename Marker (`marker.rename`), the first selected marker.
    public static func markerRename(_ name: String) -> BlenderCommand {
        command("bpy.ops.marker.rename(name=\(Bpy.quote(name)))", "marker_rename(\(Bpy.quote(name)))",
                undo: "Rename Marker")
    }

    /// Whether an action changes nothing the 3D View draws — what is
    /// selected, a marker added — and so needs no mirroring pass
    /// (`BpyBridge.runWithoutMirror`; `_blenderkit_keys` reports to the
    /// timeline itself). A marker moved or deleted can change which camera a
    /// bound marker makes the scene's, so those take the pass.
    public static func isSelection(_ action: TimelineAction) -> Bool {
        switch action {
        case .selectAll, .selectColumn, .selectLeftRight, .selectLinked, .selectMore, .selectLess,
             .markerSelectAll, .markerSelectLeftRight, .lockMarkers, .markerAdd:
            return true
        default:
            return false
        }
    }

    /// Every other action: the operator's call for the Info log, what runs,
    /// and the undo step Blender names after the operator (nil for Copy
    /// Keyframes' clipboard, which changes nothing to undo).
    public static func command(for action: TimelineAction) -> BlenderCommand {
        switch action {
        case .selectAll(let a):
            return command("bpy.ops.action.select_all(action='\(a)')", "select_all('\(a)')", undo: "Select All")
        case .selectColumn(let m):
            return command("bpy.ops.action.select_column(mode='\(m)')", "select_column('\(m)')", undo: "Select All")
        case .selectLeftRight(let m):
            return selectLeftRight(m, extend: false)
        case .selectLinked:
            return command("bpy.ops.action.select_linked()", "select_linked()", undo: "Select Linked")
        case .selectMore:
            return command("bpy.ops.action.select_more()", "select_more()", undo: "Select More")
        case .selectLess:
            return command("bpy.ops.action.select_less()", "select_less()", undo: "Select Less")
        case .delete:
            return command("bpy.ops.action.delete()", "delete()", undo: "Delete Keyframes")
        case .clean(let channels):
            return command("bpy.ops.action.clean(channels=\(bool(channels)))", "clean(\(bool(channels)))",
                           undo: "Clean Keyframes")
        case .copy:
            return command("bpy.ops.action.copy()", "copy()", undo: "Copy Keyframes")
        case .paste(let flipped):
            return command(flipped ? "bpy.ops.action.paste(flipped=True)" : "bpy.ops.action.paste()",
                           "paste(flipped=\(bool(flipped)))", undo: "Paste Keyframes")
        case .snap(let t):
            return command("bpy.ops.action.snap(type='\(t)')", "snap('\(t)')", undo: "Snap Keys")
        case .mirror(let t):
            return command("bpy.ops.action.mirror(type='\(t)')", "mirror('\(t)')", undo: "Mirror Keys")
        case .jumpToKeys:
            return command("bpy.ops.action.frame_jump()", "frame_jump()", undo: "Jump to Keyframes")
        case .interpolation(let t):
            return command("bpy.ops.action.interpolation_type(type='\(t)')", "interpolation('\(t)')",
                           undo: "Set Keyframe Interpolation")
        case .easing(let t):
            return command("bpy.ops.action.easing_type(type='\(t)')", "easing('\(t)')",
                           undo: "Set Keyframe Easing Type")
        case .keyframeType(let t):
            return command("bpy.ops.action.keyframe_type(type='\(t)')", "keyframe_type('\(t)')",
                           undo: "Set Keyframe Type")
        case .handleType(let t):
            return command("bpy.ops.action.handle_type(type='\(t)')", "handle_type('\(t)')",
                           undo: "Set Keyframe Handle Type")
        case .insert(let t):
            return command("bpy.ops.action.keyframe_insert(type='\(t)')", "insert('\(t)')", undo: "Insert Keyframes")
        case .markerAdd:
            return command("bpy.ops.marker.add()", "marker_add()", undo: "Add Time Marker")
        case .markerDelete:
            return command("bpy.ops.marker.delete()", "marker_delete()", undo: "Delete Markers")
        case .markerSelectAll(let a):
            return command("bpy.ops.marker.select_all(action='\(a)')", "marker_select_all('\(a)')",
                           undo: "(De)select all Markers")
        case .markerSelectLeftRight(let m):
            return command("bpy.ops.marker.select_leftright(mode='\(m)')", "marker_select_leftright('\(m)')",
                           undo: "Select Markers Before/After Current Frame")
        case .markerCameraBind:
            return command("bpy.ops.marker.camera_bind()", "marker_camera_bind()", undo: "Bind Camera to Markers")
        case .lockMarkers(let on):
            return command("bpy.context.scene.tool_settings.lock_markers = \(bool(on))",
                           "set_lock_markers(\(bool(on)))", undo: "Lock Markers")
        }
    }

    /// What a drag asks before it starts: the scene's Snap and rate.
    public static let snapState = module + "\n_blenderkit_keys.snap_state()"
}

// MARK: - The menus, by Blender's names

/// One row of a Timeline menu, as Blender 5.2.1 draws it.
public struct TimelineMenuRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case action(TimelineAction)
        /// Something the interface does itself: a modal move, a prompt, a
        /// view change, a toggle of the area's own.
        case interface(String)
        /// Another menu, by its `bl_idname` or the operator its enum lists.
        case submenu(String)
        /// Blender's row, not in the app: greyed.
        case unavailable
        case separator
        case heading
    }

    public var title: String
    public var key: String?
    public var kind: Kind

    public init(_ title: String, key: String? = nil, _ kind: Kind) {
        self.title = title; self.key = key; self.kind = kind
    }

    public static let separator = TimelineMenuRow("", .separator)
}

public enum TimelineMenus {
    private typealias R = TimelineMenuRow

    /// The title a menu opens with: its `bl_label`, or for an operator's enum
    /// the operator's name (`WM_menu_invoke`).
    public static func title(_ id: String) -> String {
        switch id {
        case "TIME_MT_view": return "View"
        case "DOPESHEET_MT_select", "NLA_MT_marker_select": return "Select"
        case "DOPESHEET_MT_marker": return "Marker"
        case "DOPESHEET_MT_key": return "Key"
        case "DOPESHEET_MT_key_transform": return "Transform"
        case "DOPESHEET_MT_context_menu": return "Dope Sheet"
        case "DOPESHEET_MT_delete": return "Delete"
        case "DOPESHEET_MT_snap_pie": return "Snap"
        case "action.snap": return "Snap Keys"
        case "action.mirror": return "Mirror Keys"
        case "action.interpolation_type": return "Set Keyframe Interpolation"
        case "action.easing_type": return "Set Keyframe Easing Type"
        case "action.keyframe_type": return "Set Keyframe Type"
        case "action.handle_type": return "Set Keyframe Handle Type"
        default: return id
        }
    }

    /// Every menu the Timeline offers, by id.
    public static let ids = ["TIME_MT_view", "DOPESHEET_MT_select", "DOPESHEET_MT_marker", "NLA_MT_marker_select",
                             "DOPESHEET_MT_key", "DOPESHEET_MT_key_transform", "DOPESHEET_MT_context_menu",
                             "DOPESHEET_MT_delete", "DOPESHEET_MT_snap_pie", "action.snap", "action.mirror",
                             "action.interpolation_type", "action.easing_type", "action.keyframe_type",
                             "action.handle_type"]

    /// `rna_enum_beztriple_interpolation_mode_items`, headings and all.
    public static let interpolationItems: [(String, String, String?)] = [
        ("", "Interpolation", nil),
        ("CONSTANT", "Constant", "IPO_CONSTANT"), ("LINEAR", "Linear", "IPO_LINEAR"),
        ("BEZIER", "Bézier", "IPO_BEZIER"),
        ("", "Easing (by strength)", nil),
        ("SINE", "Sinusoidal", "IPO_SINE"), ("QUAD", "Quadratic", "IPO_QUAD"), ("CUBIC", "Cubic", "IPO_CUBIC"),
        ("QUART", "Quartic", "IPO_QUART"), ("QUINT", "Quintic", "IPO_QUINT"),
        ("EXPO", "Exponential", "IPO_EXPO"), ("CIRC", "Circular", "IPO_CIRC"),
        ("", "Dynamic Effects", nil),
        ("BACK", "Back", "IPO_BACK"), ("BOUNCE", "Bounce", "IPO_BOUNCE"), ("ELASTIC", "Elastic", "IPO_ELASTIC"),
    ]
    public static let easingItems = [("AUTO", "Automatic Easing"), ("EASE_IN", "Ease In"),
                                     ("EASE_OUT", "Ease Out"), ("EASE_IN_OUT", "Ease In and Out")]
    public static let handleItems = [("FREE", "Free"), ("ALIGNED", "Aligned"), ("VECTOR", "Vector"),
                                     ("AUTO", "Automatic"), ("AUTO_CLAMPED", "Auto Clamped")]
    public static let snapItems = [("CFRA", "Selection to Current Frame"), ("NEAREST_FRAME", "Selection to Nearest Frame"),
                                   ("NEAREST_SECOND", "Selection to Nearest Second"),
                                   ("NEAREST_MARKER", "Selection to Nearest Marker")]
    public static let mirrorItems = [("CFRA", "By Times Over Current Frame"),
                                     ("MARKER", "By Times Over First Selected Marker"),
                                     ("XAXIS", "By Values Over Zero Value")]

    public static func rows(_ id: String, usePreviewRange: Bool = false) -> [TimelineMenuRow] {
        switch id {
        case "TIME_MT_view":
            return [R("Adjust Last Operation", .unavailable), R("Channels", .unavailable), .separator,
                    R("Frame All", key: "Home", .interface("view.frame_all")),
                    R(usePreviewRange ? "Frame Preview Range" : "Frame Scene Range", .interface("view.frame_range")),
                    R("Go to Current Frame", key: "Numpad 0", .interface("view.frame_current")), .separator,
                    R("Show Markers", .interface("view.show_markers")),
                    R("Use Timecode", key: "Ctrl T", .interface("view.use_timecode")),
                    R("Sync Visible Range", .unavailable), .separator,
                    R("Only Show Selected", .interface("view.only_selected")),
                    R("Only Show Errors", .unavailable)]
        case "DOPESHEET_MT_select":
            return [R("All", key: "A", .action(.selectAll("SELECT"))),
                    R("None", key: "Alt A", .action(.selectAll("DESELECT"))),
                    R("Invert", key: "Ctrl I", .action(.selectAll("INVERT"))), .separator,
                    R("Box Select", key: "B", .interface("select.box")),
                    R("Box Select (Axis Range)", key: "Alt B", .interface("select.box")),
                    R("Circle Select", key: "C", .unavailable), R("Lasso Select", .unavailable), .separator,
                    R("More", key: "Ctrl Numpad +", .action(.selectMore)),
                    R("Less", key: "Ctrl Numpad -", .action(.selectLess)), .separator,
                    R("Select Linked", key: "L", .action(.selectLinked)),
                    R("Select by Type", .unavailable), .separator,
                    R("Columns on Selected Keys", key: "K", .action(.selectColumn("KEYS"))),
                    R("Column on Current Frame", key: "Ctrl K", .action(.selectColumn("CFRA"))),
                    R("Columns on Selected Markers", key: "Shift K", .action(.selectColumn("MARKERS_COLUMN"))),
                    R("Between Selected Markers", key: "Alt K", .action(.selectColumn("MARKERS_BETWEEN"))),
                    .separator,
                    R("Before Current Frame", key: "[", .action(.selectLeftRight("LEFT"))),
                    R("After Current Frame", key: "]", .action(.selectLeftRight("RIGHT")))]
        case "DOPESHEET_MT_marker":
            return [R("Lock Markers", .interface("marker.lock")), .separator,
                    R("Jump to Previous Marker", .interface("marker.jump_previous")),
                    R("Jump to Next Marker", .interface("marker.jump_next")), .separator,
                    R("Bind Camera to Markers", key: "Ctrl B", .action(.markerCameraBind)), .separator,
                    R("Select", .submenu("NLA_MT_marker_select")), .separator,
                    R("Move Marker", key: "G", .interface("marker.move")),
                    R("Rename Marker", key: "F2", .interface("marker.rename")), .separator,
                    R("Delete Marker", key: "X", .interface("marker.delete")),
                    R("Duplicate Marker to Scene", .unavailable),
                    R("Duplicate Marker", key: "Shift D", .interface("marker.duplicate")),
                    R("Add Marker", key: "M", .action(.markerAdd)),
                    R("Sync Markers", .unavailable)]
        case "NLA_MT_marker_select":
            return [R("All", key: "A", .action(.markerSelectAll("SELECT"))),
                    R("None", key: "Alt A", .action(.markerSelectAll("DESELECT"))),
                    R("Invert", key: "Ctrl I", .action(.markerSelectAll("INVERT"))), .separator,
                    R("Before Current Frame", key: "[", .action(.markerSelectLeftRight("LEFT"))),
                    R("After Current Frame", key: "]", .action(.markerSelectLeftRight("RIGHT")))]
        case "DOPESHEET_MT_key":
            return [R("Transform", .submenu("DOPESHEET_MT_key_transform")),
                    R("Snap", .submenu("action.snap")), R("Mirror", .submenu("action.mirror")), .separator,
                    R("Jump to Selected", key: "Ctrl G", .action(.jumpToKeys)), .separator,
                    R("Insert Keyframes", key: "I", .action(.insert("ALL"))),
                    R("Copy Keyframes", key: "Ctrl C", .action(.copy)),
                    R("Paste Keyframes", key: "Ctrl V", .action(.paste(flipped: false))),
                    R("Paste Flipped", key: "Shift Ctrl V", .action(.paste(flipped: true))),
                    R("Duplicate", key: "Shift D", .interface("key.duplicate")),
                    R("Delete Keyframes", key: "Delete", .interface("key.delete_confirm")), .separator,
                    R("Keyframe Type", key: "R", .submenu("action.keyframe_type")),
                    R("Handle Type", key: "V", .submenu("action.handle_type")),
                    R("Interpolation Mode", key: "T", .submenu("action.interpolation_type")),
                    R("Easing Mode", key: "Ctrl E", .submenu("action.easing_type")), .separator,
                    R("Clean Keyframes", .action(.clean(channels: false))),
                    R("Bake Keyframes", .unavailable), .separator,
                    R("Discontinuity (Euler) Filter", .unavailable)]
        case "DOPESHEET_MT_key_transform":
            return [R("Move", key: "G", .interface("key.move")), R("Extend", key: "E", .unavailable),
                    R("Slide", key: "Shift T", .unavailable), R("Scale", key: "S", .interface("key.scale"))]
        case "DOPESHEET_MT_context_menu":
            return [R("Copy", key: "Ctrl C", .action(.copy)),
                    R("Paste", key: "Ctrl V", .action(.paste(flipped: false))),
                    R("Paste Flipped", key: "Shift Ctrl V", .action(.paste(flipped: true))), .separator,
                    R("Keyframe Type", key: "R", .submenu("action.keyframe_type")),
                    R("Handle Type", key: "V", .submenu("action.handle_type")),
                    R("Interpolation Mode", key: "T", .submenu("action.interpolation_type")),
                    R("Easing Mode", key: "Ctrl E", .submenu("action.easing_type")), .separator,
                    R("Insert Keyframes", key: "I", .action(.insert("SEL"))),
                    R("Duplicate", key: "Shift D", .interface("key.duplicate")),
                    R("Delete Keyframes", key: "Delete", .action(.delete)), .separator,
                    R("Mirror", key: "Ctrl M", .submenu("action.mirror")),
                    R("Snap", key: "Shift S", .submenu("action.snap"))]
        case "DOPESHEET_MT_delete":
            return [R("Delete Keyframes", .interface("key.delete_confirm")), .separator,
                    R("Clean Keyframes", .action(.clean(channels: false))),
                    R("Clean Channels", .action(.clean(channels: true)))]
        case "DOPESHEET_MT_snap_pie":
            return snapItems.map { R($0.1, .action(.snap($0.0))) }
        case "action.snap":
            return snapItems.map { R($0.1, .action(.snap($0.0))) }
        case "action.mirror":
            return mirrorItems.map { R($0.1, .action(.mirror($0.0))) }
        case "action.interpolation_type":
            return interpolationItems.map { item in
                item.0.isEmpty ? R(item.1, .heading) : R(item.1, .action(.interpolation(item.0)))
            }
        case "action.easing_type":
            return easingItems.map { R($0.1, .action(.easing($0.0))) }
        case "action.keyframe_type":
            return KeyframeType.menuOrder.map { R($0.name, .action(.keyframeType($0.identifier))) }
        case "action.handle_type":
            return handleItems.map { R($0.1, .action(.handleType($0.0))) }
        default:
            return []
        }
    }
}
