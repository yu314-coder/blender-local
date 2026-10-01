import Foundation

/// Where the real module's undo history stands, as `_blenderkit_undo.state()`
/// reports it after every push, undo and redo.
///
/// The Python keeps the history — Blender's own undo stack where the probe
/// found it works, .blend checkpoints where it did not — and this is the part
/// the interface reads: whether Undo and Redo can be pressed, what they would
/// undo, which of the two ways the history is kept, and what it cost.
public struct BackendHistoryState: Decodable, Equatable, Sendable {
    public var undo: Bool
    public var redo: Bool
    public var undoLabel: String
    public var redoLabel: String
    /// `blender`, `checkpoint`, or `pending` until the probe has run.
    public var mode: String
    /// Why the mode is what it is: the probe's timings, or the error that made
    /// the history fall back to checkpoints.
    public var why: String
    public var steps: Int
    public var index: Int
    /// Milliseconds, by what they were spent on: `blender` for Blender's undo
    /// operators, `file` for a checkpoint written or loaded, `images` for
    /// images reloaded, `total` for the whole call.
    public var timing: [String: Double]

    enum CodingKeys: String, CodingKey {
        case undo, redo, mode, why, steps, index, timing
        case undoLabel = "undo_label", redoLabel = "redo_label"
    }

    public init(undo: Bool = false, redo: Bool = false, undoLabel: String = "",
                redoLabel: String = "", mode: String = "pending", why: String = "",
                steps: Int = 0, index: Int = -1, timing: [String: Double] = [:]) {
        self.undo = undo; self.redo = redo
        self.undoLabel = undoLabel; self.redoLabel = redoLabel
        self.mode = mode; self.why = why
        self.steps = steps; self.index = index; self.timing = timing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        undo = try c.decode(Bool.self, forKey: .undo)
        redo = try c.decode(Bool.self, forKey: .redo)
        undoLabel = try c.decodeIfPresent(String.self, forKey: .undoLabel) ?? ""
        redoLabel = try c.decodeIfPresent(String.self, forKey: .redoLabel) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "pending"
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? -1
        timing = try c.decodeIfPresent([String: Double].self, forKey: .timing) ?? [:]
    }

    /// The state from what the Python printed. Blender's operators may print
    /// informational lines before it, so the last line that decodes wins.
    public static func parse(_ text: String) -> BackendHistoryState? {
        for line in text.split(separator: "\n").reversed() {
            guard line.hasPrefix("{"), let data = String(line).data(using: .utf8),
                  let state = try? JSONDecoder().decode(BackendHistoryState.self, from: data)
            else { continue }
            return state
        }
        return nil
    }

    /// Whether Blender's own undo stack is keeping the history.
    public var usesBlenderUndo: Bool { mode == "blender" }

    /// One line for the log: which way the history is kept, and the cost of
    /// the call that produced this state.
    public func logLine(_ what: String) -> String {
        let costs = timing.keys.sorted().map { String(format: "%@ %.2f ms", $0, timing[$0]!) }
        return "[bk-undo] \(what) · \(mode) · step \(index + 1) of \(steps)"
            + (costs.isEmpty ? "" : " · " + costs.joined(separator: ", "))
    }
}

/// The Python the session sends to keep the history. In one place so the
/// Blender check (tests/undo/blender) runs exactly these strings.
public enum BackendHistoryPython {
    /// Records the scene as it is now as the step `label`; `replace` puts it
    /// in the place of the step on top.
    public static func push(root: String, label: String, replace: Bool,
                            forceCheckpoints: Bool) -> String {
        "import _blenderkit_undo as _bk_undo, json; print(json.dumps(_bk_undo.push("
            + "\(Bpy.quote(root)), \(Bpy.quote(label)), replace=\(replace ? "True" : "False"), "
            + "force_checkpoints=\(forceCheckpoints ? "True" : "False"))))"
    }

    /// Undo (-1) or redo (+1).
    public static func step(_ direction: Int) -> String {
        "import _blenderkit_undo as _bk_undo, json; print(json.dumps(_bk_undo.step(\(direction < 0 ? -1 : 1))))"
    }

    /// Undoes the step on top so the adjusted operator can take its place.
    public static let rewind =
        "import _blenderkit_undo as _bk_undo, json; print(json.dumps(_bk_undo.rewind()))"

    /// Back to the step `rewind` undid, when the re-run failed.
    public static let cancelRewind =
        "import _blenderkit_undo as _bk_undo, json; print(json.dumps(_bk_undo.cancel_rewind()))"

    /// Writes the crash-recovery file, printing how long it took.
    public static func autosave(path: String) -> String {
        "import _blenderkit_undo as _bk_undo; print(_bk_undo.autosave(\(Bpy.quote(path))))"
    }
}

/// When to write the crash-recovery file.
///
/// It used to be written on every undo step, because every step was a .blend
/// anyway. Steps are no longer files, so the autosave is its own write, and it
/// waits for the work to pause: two seconds after the last change, not while a
/// script runs, and at once when the app goes to the background.
public struct AutosavePolicy: Equatable, Sendable {
    public static let quiet: TimeInterval = 2.0

    /// The last change not yet written, if any.
    public private(set) var changedAt: Date?

    public init() {}

    public mutating func noteChange(at date: Date = Date()) { changedAt = date }
    public mutating func noteWritten() { changedAt = nil }

    public var isPending: Bool { changedAt != nil }

    /// What to do when the debounce timer fires.
    public enum Decision: Equatable, Sendable {
        /// Nothing changed since the last write.
        case nothing
        /// Changes are waiting but it is too soon, or a script is running:
        /// look again after this long.
        case wait(TimeInterval)
        case write
    }

    public func decide(at now: Date = Date(), running: Bool) -> Decision {
        guard let changedAt else { return .nothing }
        let waited = now.timeIntervalSince(changedAt)
        if waited < Self.quiet { return .wait(Self.quiet - waited) }
        if running { return .wait(Self.quiet) }
        return .write
    }
}
