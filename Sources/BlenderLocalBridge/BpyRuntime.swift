import Foundation
import simd
import Observation

/// One line of interpreter output.
public struct BpyLine: Identifiable, Sendable {
    public enum Kind: Sendable { case input, output, error, info }
    public let id = UUID()
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

/// What a `bpy` interpreter has to provide. The Scripting tab talks only to
/// this, so swapping the stand-in below for the real embedded interpreter is a
/// one-line change at the call site.
public protocol BpyRuntime: AnyObject {
    /// A real CPython interpreter, as opposed to the command-subset fallback.
    var isReal: Bool { get }
    /// Blender's own module, as opposed to the bundled shim.
    ///
    /// Distinct from `isReal`, and the distinction matters: the interpreter is
    /// real in the simulator too, but the module backing `bpy` there is the
    /// shim. Conflating the two put "Blender bpy" on screen while the console
    /// banner said "shim" two inches below it.
    var usesRealBlender: Bool { get }
    /// Seconds the last evaluate spent mirroring bpy into the display cache.
    var lastSyncDuration: TimeInterval { get }

    /// The real attributes of a dotted path, asked of the interpreter itself
    /// rather than looked up in a table someone typed out, each with whether it
    /// can be called — so an operator is offered as `bevel()` and a property as
    /// `location`.
    ///
    /// Nil when there is no interpreter to ask, or the path does not resolve —
    /// the caller falls back to what it knows statically.
    func introspect(_ path: String) -> [(name: String, callable: Bool)]?
    var versionBanner: String { get }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine]
    func query(_ source: String, scene: BKScene) -> [BpyLine]
    func requestInterrupt()
}

public extension BpyRuntime {
    func requestInterrupt() {}
    func query(_ source: String, scene: BKScene) -> [BpyLine] { evaluate(source, scene: scene) }
}

/// Translates Tools-tab actions into the Python that performs the same thing.
///
/// Blender's Info editor logs the operator call behind every click; reproducing
/// that is what ties the two tabs together — a user works with the tools, then
/// reads back the script.
public enum BpyCommands {

    public static func add(_ kind: PrimitiveKind, at loc: SIMD3<Float>) -> String {
        let l = String(format: "(%.4f, %.4f, %.4f)", loc.x, loc.y, loc.z)
        switch kind {
        case .uvSphere:
            return "\(kind.bpyOperator)(radius=1.0, enter_editmode=False, align='WORLD', location=\(l))"
        case .torus:
            return "\(kind.bpyOperator)(align='WORLD', location=\(l), major_radius=1.0, minor_radius=0.25)"
        case .cube:
            return "\(kind.bpyOperator)(size=2.0, enter_editmode=False, align='WORLD', location=\(l))"
        default:
            return "\(kind.bpyOperator)(enter_editmode=False, align='WORLD', location=\(l))"
        }
    }

    public static let delete    = "bpy.ops.object.delete(use_global=False)"
    public static let duplicate = "bpy.ops.object.duplicate_move()"
    public static let selectAll = "bpy.ops.object.select_all(action='SELECT')"
    public static let deselect  = "bpy.ops.object.select_all(action='DESELECT')"

    public static func setLocation(_ name: String, _ v: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[\"%@\"].location = (%.4f, %.4f, %.4f)", name, v.x, v.y, v.z)
    }
    public static func setRotation(_ name: String, _ v: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[\"%@\"].rotation_euler = (%.4f, %.4f, %.4f)", name, v.x, v.y, v.z)
    }
    public static func setScale(_ name: String, _ v: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[\"%@\"].scale = (%.4f, %.4f, %.4f)", name, v.x, v.y, v.z)
    }
}

/// A stand-in interpreter that understands a small, explicit subset of `bpy`
/// and applies it to the live scene.
///
/// **This is not Python.** It exists so the Scripting tab is usable — and so
/// both tabs drive one scene — before the real `bpy` from python-ios-lib is
/// linked in. Anything outside the subset reports an honest error rather than
/// pretending to have run. `isReal` is false so the UI can say so plainly.
public final class StubBpyRuntime: BpyRuntime {
    /// Set when this is standing in for an embedded interpreter that failed to
    /// start, so the console can say why instead of silently degrading.
    private let fallbackReason: String?

    public init(fallbackReason: String? = nil) {
        self.fallbackReason = fallbackReason
    }

    public let isReal = false
    /// The stub has no bpy at all, real or shim.
    public let usesRealBlender = false
    public let lastSyncDuration: TimeInterval = 0

    /// The command subset has no objects to look inside.
    public func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    public var versionBanner: String {
        let preamble = fallbackReason.map {
            "Embedded Python did not start: \($0)\nFalling back to the command subset.\n"
        } ?? ""
        return preamble + """
        Blender Local console — command subset, not a Python interpreter.
        Recognised: bpy.ops.mesh.primitive_*_add, bpy.ops.object.{delete,duplicate_move,select_all},
        bpy.data.objects["name"].{location,rotation_euler,scale}, and print().
        The real bpy interpreter is not linked yet; see docs/bpy-embedding.md.
        """
    }

    public func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        var out: [BpyLine] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            out += evaluateLine(line, scene: scene)
        }
        return out
    }

    private func evaluateLine(_ line: String, scene: BKScene) -> [BpyLine] {
        if line == "import bpy" || line.hasPrefix("import ") || line.hasPrefix("from ") {
            return []   // accepted silently, as Python would
        }

        if let r = matchRedoRemoval(line, scene: scene)  { return r }
        if let r = matchPrimitiveAdd(line, scene: scene) { return r }
        if let r = matchObjectOp(line, scene: scene)     { return r }
        if let r = matchProperty(line, scene: scene)     { return r }
        if let r = matchPrint(line, scene: scene)        { return r }

        return [BpyLine(.error, "Not in the recognised subset: \(line)")]
    }

    // MARK: subset matchers

    private func matchPrimitiveAdd(_ line: String, scene: BKScene) -> [BpyLine]? {
        for kind in PrimitiveKind.allCases where line.hasPrefix(kind.bpyOperator) {
            let loc = parseTuple(line, key: "location") ?? .zero
            let obj = scene.add(kind, at: loc)
            // The size and segment counts are honoured, not just the location.
            // Blender's own add operators take them, and the redo panel exists
            // to change them — a panel whose sliders moved nothing here would
            // be worse than no panel.
            let args = parseNumericArguments(line)
            if !args.isEmpty {
                obj.setMirroredMesh(MeshBuilder.make(kind, arguments: args))
            }
            return [BpyLine(.output, "{'FINISHED'}"),
                    BpyLine(.info, "Added \(obj.name)")]
        }
        return nil
    }

    /// The one thing the subset knows that is not a single call: the removal
    /// the redo panel emits before re-running an operator.
    ///
    /// Adjusting the last operation means undoing it and doing it again, and
    /// the undo half is four lines of Python with a temporary in it. The subset
    /// recognises those four lines *as the idiom the panel emits* — it is still
    /// not an interpreter, and it does not evaluate the conditions. Anything
    /// that only looks like them is rejected the way anything else outside the
    /// subset is.
    private func matchRedoRemoval(_ line: String, scene: BKScene) -> [BpyLine]? {
        if line.hasPrefix("_o = bpy.data.objects.get(\""), line.hasSuffix("\")") {
            let inner = line.dropFirst("_o = bpy.data.objects.get(\"".count).dropLast(2)
            pendingRemoval = scene.objects.first { $0.name == String(inner) }
            return []
        }
        switch line {
        case "if _o is not None:", "_d = _o.data",
             "if _d is not None and _d.users == 0:", "bpy.data.meshes.remove(_d)":
            // The shim has no mesh datablocks to orphan, so the cleanup the
            // real module needs is a no-op here rather than a pretence.
            return []
        case "bpy.data.objects.remove(_o, do_unlink=True)":
            guard let doomed = pendingRemoval else { return [] }
            pendingRemoval = nil
            scene.objects.removeAll { $0 === doomed }
            scene.selection.remove(doomed.id)
            if scene.activeID == doomed.id { scene.activeID = nil }
            return []
        default:
            return nil
        }
    }

    /// The object `_o` refers to between the `get` and the `remove`.
    private var pendingRemoval: BKObject?

    private func matchObjectOp(_ line: String, scene: BKScene) -> [BpyLine]? {
        if line.hasPrefix("bpy.ops.object.delete") {
            let n = scene.selection.count
            scene.deleteSelection()
            return [BpyLine(.output, "{'FINISHED'}"), BpyLine(.info, "Deleted \(n) object(s)")]
        }
        if line.hasPrefix("bpy.ops.object.duplicate_move") {
            let made = scene.duplicateSelection()
            return [BpyLine(.output, "{'FINISHED'}"), BpyLine(.info, "Duplicated \(made.count) object(s)")]
        }
        if line.hasPrefix("bpy.ops.object.select_all") {
            if line.contains("DESELECT") {
                scene.deselectAll()
            } else {
                scene.selection = Set(scene.objects.map(\.id))
                scene.activeID = scene.objects.last?.id
            }
            return [BpyLine(.output, "{'FINISHED'}")]
        }
        return nil
    }

    private func matchProperty(_ line: String, scene: BKScene) -> [BpyLine]? {
        // bpy.data.objects["Cube"].location = (1, 2, 3)
        guard line.hasPrefix("bpy.data.objects["),
              let nameStart = line.firstIndex(of: "\""),
              let nameEnd = line[line.index(after: nameStart)...].firstIndex(of: "\"")
        else { return nil }

        let name = String(line[line.index(after: nameStart)..<nameEnd])
        guard let obj = scene.objects.first(where: { $0.name == name }) else {
            return [BpyLine(.error, "KeyError: bpy_prop_collection[key]: key \"\(name)\" not found")]
        }
        guard let eq = line.firstIndex(of: "="),
              let value = parseTupleLiteral(String(line[line.index(after: eq)...]))
        else { return [BpyLine(.error, "Could not parse the assigned value: \(line)")] }

        let prop = line[nameEnd...]
        if prop.contains(".location")            { obj.location = value }
        else if prop.contains(".rotation_euler") { obj.rotation = value }
        else if prop.contains(".scale")          { obj.scale = value }
        else { return [BpyLine(.error, "Unsupported property in: \(line)")] }
        return []
    }

    private func matchPrint(_ line: String, scene: BKScene) -> [BpyLine]? {
        guard line.hasPrefix("print(") , line.hasSuffix(")") else { return nil }
        var inner = String(line.dropFirst(6).dropLast())
        inner = inner.trimmingCharacters(in: .whitespaces)
        // The subset does model an active object, so this one expression is
        // answered rather than echoed. Echoing it would hand the caller the
        // string "bpy.context…" as if it were an object's name, and the redo
        // panel would then try to remove an object by that name and quietly
        // leave the real one behind on every adjustment.
        if inner == "bpy.context.view_layer.objects.active.name" {
            guard let name = scene.active?.name else {
                return [BpyLine(.error, "AttributeError: 'NoneType' object has no attribute 'name'")]
            }
            return [BpyLine(.output, name)]
        }
        if inner.count >= 2, (inner.first == "\"" || inner.first == "'"), inner.last == inner.first {
            inner = String(inner.dropFirst().dropLast())
        }
        return [BpyLine(.output, inner)]
    }

    // MARK: parsing

    /// The numeric keyword arguments of a call: `vertices=6, radius=1.5` reads
    /// as two numbers. Tuples and quoted enums are skipped — this is for the
    /// scalars the primitives are built from.
    private func parseNumericArguments(_ line: String) -> [String: Double] {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"),
              open < close else { return [:] }
        var out: [String: Double] = [:]
        var depth = 0
        var field = ""
        func take(_ s: String) {
            let parts = s.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let number = Double(value) else { return }
            out[key] = number
        }
        for c in line[line.index(after: open)..<close] {
            if c == "(" || c == "[" { depth += 1 }
            if c == ")" || c == "]" { depth -= 1 }
            if c == "," && depth == 0 { take(field); field = ""; continue }
            field.append(c)
        }
        take(field)
        return out
    }

    private func parseTuple(_ line: String, key: String) -> SIMD3<Float>? {
        guard let r = line.range(of: "\(key)=") else { return nil }
        return parseTupleLiteral(String(line[r.upperBound...]))
    }

    private func parseTupleLiteral(_ s: String) -> SIMD3<Float>? {
        guard let open = s.firstIndex(where: { $0 == "(" || $0 == "[" }),
              let close = s[open...].firstIndex(where: { $0 == ")" || $0 == "]" })
        else { return nil }
        let nums = s[s.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 3 else { return nil }
        return SIMD3(nums[0], nums[1], nums[2])
    }
}

/// The console's scrollback plus the Info log, both of which Blender keeps
/// across the session.
@Observable
public final class BpySession {
    public var console: [BpyLine] = []
    /// True while a script is executing.
    ///
    /// The run loop is pumped during a run so live output can be drawn, and
    /// pumping means a tap can arrive mid-script. Without this a second Run
    /// would re-enter the interpreter on top of the first.
    public private(set) var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning {
                // A run that did not say what it is came from the editor.
                if runKind == nil { runKind = .script }
            } else {
                lastRunKind = runKind
                runKind = nil
            }
        }
    }

    /// A sculpt stroke is streaming into Blender, from `BpyBridge.sculptBegin`
    /// to `sculptEnd`. Each of its chunks rewinds the undo step on top of
    /// Blender's stack, taking it for its own, so nothing else may push, undo
    /// or run until it ends: measured in desktop 5.2.1 with the app's modules,
    /// an Undo between two chunks left the history two steps back while it
    /// read one, and a Mask ▸ Fill between two chunks was listed in the
    /// history and then undone by the next chunk. Blender's own modal stroke
    /// holds every other key the same way while the brush is down.
    public internal(set) var sculptStrokeOpen = false
    /// What the reader is told when something waits for the stroke.
    public static let strokeOpenMessage = "A sculpt stroke is in progress. Lift the finger or Pencil first."

    /// A curve's or a lattice's points are being dragged, from
    /// `BpyBridge.beginPointDrag` to its commit or cancel. Every frame puts
    /// the points back where the drag found them and runs the move again, so
    /// nothing else may run, undo or redo until the finger lifts: measured in
    /// 5.2.1 with the app's own frame strings, an Undo between two frames put
    /// Blender back in Object Mode, the next frames moved the whole object to
    /// z 0.4, 0.9 and 1.5 while the gesture showed one knot moving, and the
    /// release left it at 2.1. Blender's modal transform holds every other key
    /// the same way while it runs.
    public internal(set) var pointDragOpen = false
    public static let pointDragOpenMessage = "Points are being moved. Lift the finger first."

    /// What holds every other command while a gesture streams into Blender,
    /// in the words the reader is told; nil when nothing does.
    public var gestureHold: String? {
        if sculptStrokeOpen { return Self.strokeOpenMessage }
        if pointDragOpen { return Self.pointDragOpenMessage }
        return nil
    }

    /// How long the run in flight has been going, updated as the interface is
    /// given its turns. Something observable has to move or a run-loop turn
    /// draws nothing: the console only changes when the script prints, and the
    /// whole point is to look alive when it is not printing.
    public private(set) var runElapsed: TimeInterval = 0
    /// Mirrors Blender's Info editor: the Python for every action taken in the
    /// Tools tab.
    public var infoLog: [String] = []
    public var history: [String] = []
    /// What the last Run Script did. The Text Editor shows this as a banner:
    /// pressing Run used to change nothing you were looking at, because the
    /// only evidence was a few lines in a console pane on the far side of the
    /// screen.
    public var lastRun: RunOutcome?

    /// What a run is: a script from the editor, or a line from the console.
    ///
    /// Both hold the interpreter, so one flag says a run is in flight; this says
    /// which, because only a script's outcome belongs to the editor. A console
    /// statement that raises must not put an error card beside a script it has
    /// nothing to do with.
    public enum RunKind: Sendable { case script, console }
    /// The kind of the run in flight; nil when nothing runs.
    public private(set) var runKind: RunKind?
    /// The kind of the run that finished last.
    public private(set) var lastRunKind: RunKind?
    /// A console run's output as it is written, for the terminal to draw.
    /// Called on the main thread.
    @ObservationIgnored public var onConsoleOutput: ((String) -> Void)?
    /// Called when Stop is asked for, so the terminal can end a command that is
    /// waiting for keys, which the interpreter's own interrupt cannot reach.
    @ObservationIgnored public var onStop: (() -> Void)?
    /// Where the last console run's output sits in `console`. The terminal drew
    /// it as it was written, and must not print it a second time.
    @ObservationIgnored public private(set) var lastConsoleOutput: Range<Int>?

    public struct RunOutcome: Equatable {
        public let lines: Int
        public let duration: TimeInterval
        /// How much of `duration` was spent mirroring bpy back into the display
        /// cache rather than running the script.
        ///
        /// Worth separating: with the real module every object is walked, its
        /// evaluated mesh built and its arrays copied out, and on a heavy scene
        /// that can dwarf the script. Without the split, a slow Run is just
        /// "slow" and there is nothing to act on.
        public var syncDuration: TimeInterval = 0
        /// The last line of the traceback — the part that names what went
        /// wrong, which is the part worth putting on screen.
        public let error: String?
        /// The line of the *script* the traceback blamed, 1-based.
        ///
        /// A traceback names several frames — the failing line inside manim,
        /// the shim, the script. Only the script's own frames are addressable
        /// in the editor, and they are the ones the reader can act on, so the
        /// deepest `File "<string>", line N` wins: that is the innermost frame
        /// still inside the buffer they are looking at.
        public var errorLine: Int?
        public let objectsBefore: Int
        public let objectsAfter: Int
        public var succeeded: Bool { error == nil }

        /// The traceback's frames that are in the script, innermost first: the
        /// line that raised, then each line that called into it. Empty for a
        /// clean run, and for an error raised outside any script frame.
        public var frames: [ScriptFrame] = []

        public struct ScriptFrame: Equatable, Hashable, Codable, Sendable {
            public let line: Int
            /// The function the line is in — `<module>` at the top level, and
            /// empty for a syntax error, which names a line but no function.
            public let function: String
            public init(line: Int, function: String) {
                self.line = line
                self.function = function
            }
        }

        /// The exception's name — `RuntimeError` from
        /// `RuntimeError: Operator … failed` — or nil when the error is a
        /// sentence rather than an exception, like "Nothing to run".
        public var errorName: String? {
            guard let error else { return nil }
            let head = error.range(of: ": ").map { error[..<$0.lowerBound] } ?? error[...]
            let isName = !head.isEmpty
                && head.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            return isName ? String(head) : nil
        }

        /// What the exception says, without its name; nil when it says nothing.
        public var errorMessage: String? {
            guard let error else { return nil }
            guard let name = errorName else { return error }
            var rest = error.dropFirst(name.count)
            if rest.hasPrefix(": ") { rest = rest.dropFirst(2) }
            return rest.isEmpty ? nil : String(rest)
        }

        /// Every script frame in a traceback, innermost first.
        ///
        /// The same rule as `scriptLine`: only `<string>` frames are the buffer
        /// in the editor, so library frames are skipped rather than offered as
        /// places to jump to.
        public static func scriptFrames(inTraceback text: String) -> [ScriptFrame] {
            var found: [ScriptFrame] = []
            for line in text.split(separator: "\n") {
                guard line.contains("File \"<string>\"") else { continue }
                guard let marker = line.range(of: "line ") else { continue }
                let digits = line[marker.upperBound...].prefix { $0.isNumber }
                guard let n = Int(digits), n > 0 else { continue }
                let function = line.range(of: ", in ", range: marker.upperBound..<line.endIndex)
                    .map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                found.append(ScriptFrame(line: n, function: function))
            }
            return found.reversed()
        }

        /// The script line a traceback blames, if any.
        ///
        /// Python writes frames outermost-first, so the last match is the
        /// innermost — the line that actually raised rather than the line that
        /// called it. `<string>` is what the runner compiles the buffer as;
        /// frames from real files are somebody else's code and cannot be shown
        /// in this editor.
        public static func scriptLine(inTraceback text: String) -> Int? {
            var found: Int?
            for line in text.split(separator: "\n") {
                guard line.contains("File \"<string>\"") else { continue }
                guard let marker = line.range(of: "line ") else { continue }
                let rest = line[marker.upperBound...]
                let digits = rest.prefix { $0.isNumber }
                if let n = Int(digits), n > 0 { found = n }
            }
            return found
        }

        /// One line, in the past tense, of what just happened.
        public var summary: String {
            if let error { return error }
            // Only worth mentioning when it is a real share of the time.
            let syncNote = syncDuration > 0.05 && syncDuration > duration * 0.25
                ? String(format: " (%.0f%% viewport sync)", syncDuration / max(duration, 0.001) * 100)
                : ""
            return "Ran \(lines) line\(lines == 1 ? "" : "s") in \(timing)\(syncNote) · \(objects)"
        }

        /// The line that closes a run in the console.
        ///
        /// For a clean run that is the summary. For a failed one it cannot be:
        /// the summary is the error, and the traceback directly above already
        /// ends with that exact line, so the console printed it twice. What the
        /// traceback does not say is where the run stopped and what it left
        /// behind — a half-cleared scene is worth knowing about.
        public var consoleLine: String {
            guard error != nil else { return summary }
            let place = errorLine.map { " at line \($0)" } ?? ""
            return "Stopped\(place) after \(timing) · \(objects)"
        }

        /// How long the run took, written the way the summary writes it — the
        /// top bar shows it beside the line count.
        public var timing: String {
            let ms = duration * 1000
            return ms < 1 ? "<1 ms" : (ms < 1000 ? String(format: "%.0f ms", ms)
                                                 : String(format: "%.2f s", duration))
        }

        private var objects: String {
            let delta = objectsAfter - objectsBefore
            switch delta {
            case 0:    return "\(objectsAfter) object\(objectsAfter == 1 ? "" : "s")"
            case 1...: return "+\(delta) object\(delta == 1 ? "" : "s"), \(objectsAfter) total"
            default:   return "\(-delta) removed, \(objectsAfter) total"
            }
        }
    }

    private let runtime: BpyRuntime
    public var isRealRuntime: Bool { runtime.isReal }
    /// Whether `bpy` is Blender's module or the bundled shim.
    public var usesRealBlender: Bool { runtime.usesRealBlender }

    /// Bound once by the app so every logged operator can push an undo step.
    /// Blender's granularity is one step per operator, and since every action
    /// already reports itself here, this is exactly the right hook.
    @ObservationIgnored public private(set) weak var boundScene: BKScene?
    @ObservationIgnored public private(set) var undo: UndoStack?

    public init(runtime: BpyRuntime = StubBpyRuntime()) {
        self.runtime = runtime
        console = runtime.versionBanner
            .split(separator: "\n")
            .map { BpyLine(.info, String($0)) }
    }

    public func bind(scene: BKScene, undo: UndoStack) {
        self.boundScene = scene
        self.undo = undo
        undo.seed(scene)
    }

    /// Turns an operator call into the short label Blender shows in Edit >
    /// Undo, e.g. `bpy.ops.mesh.primitive_cube_add(...)` becomes "Add Cube".
    static func undoLabel(for python: String) -> String {
        let call = python.split(separator: "(").first.map(String.init) ?? python
        if call.hasPrefix("bpy.ops.mesh.primitive_"), call.hasSuffix("_add") {
            let middle = call
                .replacingOccurrences(of: "bpy.ops.mesh.primitive_", with: "")
                .replacingOccurrences(of: "_add", with: "")
            return "Add " + middle.split(separator: "_")
                .map(\.capitalized).joined(separator: " ")
        }
        if call.hasPrefix("bpy.ops.") {
            return call.dropFirst("bpy.ops.".count)
                .split(separator: ".").last
                .map { $0.split(separator: "_").map(\.capitalized).joined(separator: " ") }
                ?? "Operator"
        }
        if call.contains(".location")       { return "Move" }
        if call.contains(".rotation_euler") { return "Rotate" }
        if call.contains(".scale")          { return "Resize" }
        return "Edit"
    }

    private func pushUndo(_ label: String) {
        guard let boundScene, let undo else { return }
        if usesRealBlender { recordBackendChange(label); return }
        undo.push(label, boundScene)
        // Every real action passes through here, which makes it the one place
        // that knows the scene has changed in a way worth keeping.
        autosave?.schedule(boundScene)
    }

    /// A line from the console — a shell command or Python — run the way a
    /// script runs: on the interpreter's thread, streaming, so a long one can be
    /// watched and stopped and a full-screen one can draw.
    ///
    /// Output goes to `onConsoleOutput` as it is written. When the run ends it
    /// is recorded in `console`, less the stretches a full-screen command drew,
    /// and `lastConsoleOutput` says where, so the terminal does not print what
    /// it has already drawn.
    public func runConsole(_ input: String, scene: BKScene, columns: Int = 80, rows: Int = 24) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isRunning else {
            console.append(BpyLine(.error, "A script is running."))
            return
        }
        if let held = gestureHold {
            console.append(BpyLine(.error, held))
            return
        }
        history.append(input)
        for (index, l) in input.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            console.append(BpyLine(.input, "\(index == 0 ? ">>>" : "...") \(l)"))
        }
        let source: String
        let changesScene: Bool
        switch ConsoleShell.route(input) {
        case .shell(let command):
            source = ConsoleShell.source(for: command, columns: columns, rows: rows)
            changesScene = ConsoleShell.touchesScene(command)
        case .python(let code):
            source = code
            changesScene = true
        }
        if changesScene { prepareBackendChange() }
        if Self.runsOffMainThread, !ScriptThread.needsMainThread(source) {
            startGPUOnMainThread(before: source, scene: scene)
        }

        runKind = .console
        isRunning = true
        runElapsed = 0
        ConsoleStream.runStarted = Date()
        let emit = onConsoleOutput
        // Hopped to the main thread asynchronously, never `sync`: a script
        // thread waiting on main while main runs a pump is the deadlock
        // `bk_console_emit` already warns about.
        ConsoleStream.sink = { chunk in
            DispatchQueue.main.async { emit?(chunk) }
        }
        // Listing a directory does not touch the scene, and mirroring the
        // whole scene back into the viewport after it would be wasted work.
        let runtime = self.runtime
        let evaluate: () -> [BpyLine] = changesScene
            ? { runtime.evaluate(source, scene: scene) }
            : { runtime.query(source, scene: scene) }

        let done: ([BpyLine]) -> Void = { [weak self] output in
            guard let self else { return }
            ConsoleStream.sink = nil
            ConsoleStream.runStarted = nil
            self.runElapsed = 0
            let failed = output.contains { $0.kind == .error }
            var lines = ConsoleShell.recordable(output.map(\.text).joined(separator: "\n"))
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.last?.isEmpty == true { lines.removeLast() }
            let start = self.console.count
            self.console += lines.map { BpyLine(failed ? .error : .output, $0) }
            self.lastConsoleOutput = start..<self.console.count
            self.isRunning = false
            if changesScene { self.pushUndo("Console Command") }
        }

        if Self.runsOffMainThread, !ScriptThread.needsMainThread(source) {
            let ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let from = ConsoleStream.runStarted else { return }
                self.runElapsed = (Date().timeIntervalSince(from) * 10).rounded(.down) / 10
            }
            Self.scriptQueue.async {
                let output = evaluate()
                // Queued behind every chunk the run emitted, so the last of
                // the output is drawn before the run is called finished.
                DispatchQueue.main.async {
                    ticker.invalidate()
                    done(output)
                }
            }
        } else {
            ConsoleStream.pump()
            let heartbeat = ConsoleStream.startHeartbeat()
            let output = evaluate()
            heartbeat.cancel()
            DispatchQueue.main.async { done(output) }
        }
    }

    public func submit(_ source: String, scene: BKScene) {
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // The console is reachable while a script runs, because the interface
        // no longer freezes during one. Entering a second statement would run
        // it inside the first, nested in the pump that drew the prompt.
        guard !isRunning else {
            console.append(BpyLine(.error, "A script is running."))
            return
        }
        if let held = gestureHold {
            console.append(BpyLine(.error, held))
            return
        }
        prepareBackendChange()
        history.append(source)
        // Written the way Python's prompt shows a block: `>>>` for the first
        // line, `...` for the lines that continue it.
        for (index, l) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            console.append(BpyLine(.input, "\(index == 0 ? ">>>" : "...") \(l)"))
        }
        console += runtime.evaluate(source, scene: scene)
        pushUndo(source.contains("\n") ? "Run Script" : "Console Command")
    }

    /// How many lines Python will see in `source`.
    ///
    /// Not `split(separator: "\n")` on the string: a Swift `Character` is a
    /// whole grapheme, and `\r\n` is one grapheme, so every Windows line ending
    /// was invisible to the count while Python still broke lines there. The
    /// header then announced fewer lines than the traceback went on to number.
    static func lineCount(of source: String) -> Int {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Running a whole script, as opposed to typing one line at a time.
    ///
    /// Blender's Text Editor does not echo the script into the console, and
    /// neither does this: thirteen echoed lines bury the one line of output
    /// that says what happened. Instead the run is announced, the output
    /// follows, and the outcome is reported back for the editor's banner.
    public func runScript(_ source: String, scene: BKScene) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastRun = RunOutcome(lines: 0, duration: 0, error: "Nothing to run — the editor is empty.",
                                 objectsBefore: scene.objects.count, objectsAfter: scene.objects.count)
            return
        }
        guard !isRunning else {
            lastRun = RunOutcome(lines: 0, duration: 0,
                                 error: "A script is already running.",
                                 objectsBefore: scene.objects.count,
                                 objectsAfter: scene.objects.count)
            return
        }
        if let held = gestureHold {
            lastRun = RunOutcome(lines: 0, duration: 0, error: held,
                                 objectsBefore: scene.objects.count,
                                 objectsAfter: scene.objects.count)
            return
        }
        prepareBackendChange()
        history.append(source)
        let lines = Self.lineCount(of: source)
        let before = scene.objects.count
        console.append(BpyLine(.info, "--- Run Script · \(lines) lines ---"))

        // Start from object mode, and say so when that meant changing it.
        //
        // Blender's mode is global and outlives the tab you set it in. Leaving
        // the 3D View mid-edit and pressing Run here meant the first line of
        // anything that clears a scene — `bpy.ops.object.select_all` — failed
        // its poll, reporting "context is incorrect" about a mode the reader
        // set in a different workspace some time ago. A script that wants edit
        // mode asks for it, the way it would in Blender.
        if let note = returnToObjectMode() {
            console.append(BpyLine(.info, note))
        }
        // Said here, before the stream starts: the finished run replaces
        // everything from `streamStart` on with its classified output.
        let offMainThread = Self.runsOffMainThread && !ScriptThread.needsMainThread(source)
        if Self.runsOffMainThread && !offMainThread {
            console.append(BpyLine(.info, ScriptThread.note(for: source)))
        }
        if offMainThread { startGPUOnMainThread(before: source, scene: scene) }

        // Take output as it is written rather than in one lump at the end.
        // Chunks are not lines: `print` writes the text and the newline
        // separately, and a partial line has to join the one before it rather
        // than start its own.
        isRunning = true
        // Where the streamed lines start, so they can be replaced afterwards.
        let streamStart = console.count
        // The chunks arrive on whichever thread the script is running on, and
        // `console` is observable state the interface is reading. Splitting
        // lines is done where the chunk lands; only the append crosses over.
        let carrier = LineCarrier()
        ConsoleStream.sink = { [weak self] chunk in
            guard let self else { return }
            let ready = carrier.take(chunk)
            guard !ready.isEmpty else { return }
            onMain { for line in ready { self.console.append(BpyLine(.output, line)) } }
        }

        // Something for the interface to show while nothing is being printed.
        runElapsed = 0
        if offMainThread {
            runOffMainThread(source, scene: scene, lines: lines,
                             before: before, streamStart: streamStart)
            return
        }
        // Only when the number on screen would actually change. `runElapsed`
        // is @Observable, so every assignment invalidates the status bar; at
        // twenty pumps a second that is twenty redraws to move a figure shown
        // to one decimal place, and the redraws come out of the script's time.
        ConsoleStream.tick = { [weak self] in
            guard let self, let started = ConsoleStream.runStarted else { return }
            let now = (Date().timeIntervalSince(started) * 10).rounded(.down) / 10
            if now != self.runElapsed { self.runElapsed = now }
        }

        // Draw before blocking.
        //
        // Everything above this line only *appends* — the header, the running
        // flag. SwiftUI does not redraw until the main run loop gets a turn,
        // and the next thing that happens is a synchronous `evaluate` that
        // holds the main thread for as long as the script takes. Without this
        // turn the header, the spinner and the disabled Run button all appear
        // at the same instant the script finishes, so a three-second script is
        // three seconds of an interface that looks hung and then catches up.
        // Measured: 1.2s into a 3s run, the console still showed only the
        // startup banner.
        ConsoleStream.pump()

        let started = Date()
        ConsoleStream.runStarted = started
        let heartbeat = ConsoleStream.startHeartbeat()
        let output = runtime.evaluate(source, scene: scene)
        heartbeat.cancel()
        let elapsed = Date().timeIntervalSince(started)
        ConsoleStream.sink = nil
        ConsoleStream.tick = nil
        ConsoleStream.runStarted = nil
        isRunning = false
        runElapsed = 0
        finish(output, source: source, lines: lines, elapsed: elapsed,
               before: before, streamStart: streamStart, scene: scene)
    }

    /// Everything that happens once a script has finished, whichever thread it
    /// ran on. Always called on the main thread.
    private func finish(_ output: [BpyLine], source: String, lines: Int,
                        elapsed: TimeInterval, before: Int, streamStart: Int,
                        scene: BKScene) {
        // `evaluate` hands back the same text it streamed, so appending it as
        // well would double every line. What the return adds is the *kind* —
        // which lines were errors, and so which are red — so the streamed
        // copies are replaced by the classified ones rather than joined by
        // them. Replacing rather than never streaming keeps the point of the
        // exercise: the lines were on screen while the script ran.
        if console.count > streamStart {
            console.removeSubrange(streamStart..<console.count)
        }
        console += output

        // The last error line is the `SomeError: message` one; earlier lines
        // are the traceback frames.
        let error = output.last { $0.kind == .error }?.text
            .trimmingCharacters(in: .whitespaces)
        var outcome = RunOutcome(lines: lines, duration: elapsed, error: error,
                                 objectsBefore: before, objectsAfter: scene.objects.count)
        outcome.syncDuration = runtime.lastSyncDuration
        // Which line to point at. Read from the whole traceback, not just the
        // last line — the last line names the exception, the frames above it
        // name where.
        if error != nil {
            let traceback = output.map(\.text).joined(separator: "\n")
            outcome.errorLine = RunOutcome.scriptLine(inTraceback: traceback)
            // Every script frame, not just the innermost, for the card the
            // editor opens under the failing line.
            outcome.frames = RunOutcome.scriptFrames(inTraceback: traceback)
        }
        lastRun = outcome
        console.append(BpyLine(error == nil ? .info : .error, outcome.consoleLine))
        pushUndo("Run Script")
    }

    public func stopScript() {
        guard isRunning else { return }
        runtime.requestInterrupt()
        // The interrupt fires between bytecodes; a console command blocked
        // reading keys runs none until its input ends.
        onStop?()
        note("Stop requested. Python stops at the next trace boundary; native Blender work must return first.")
    }

    public private(set) var backendCanUndo = false
    public private(set) var backendCanRedo = false
    public private(set) var backendRevision = 0
    /// What `_blenderkit_undo` last reported: the labels, which way the history
    /// is kept, and what the last push, undo or redo cost.
    public private(set) var backendHistory = BackendHistoryState()
    /// Whether Blender's own undo stack keeps the history, rather than .blend
    /// checkpoints. Settled by the probe when the first step is recorded.
    public var backendUsesBlenderUndo: Bool { backendHistory.usesBlenderUndo }
    private var backendSeeded = false

    /// Whether Blender's Essentials asset library is installed, which Shade
    /// Auto Smooth takes its node group from; nil until asked. The bpy staged
    /// into the device app ships without it, so there the operator fails
    /// every time (`_blenderkit_context.essentials_available` has what was
    /// measured) and its rows are greyed out instead.
    public private(set) var essentialsLibrary: Bool?

    /// Asks Blender once, from a view's task: a menu's body cannot run Python.
    /// Left unanswered while a script runs, for the next task to ask.
    public func probeEssentialsLibrary() {
        guard essentialsLibrary == nil, !isRunning else { return }
        // The command subset has no bpy, and would answer the probe with an
        // error in the console every time it was asked.
        guard isRealRuntime else { essentialsLibrary = false; return }
        guard let answer = capture(Self.essentialsProbe) else { return }
        let last = answer.split(separator: "\n").last.map(String.init)
        if last == "True" { essentialsLibrary = true } else if last == "False" { essentialsLibrary = false }
    }

    public static let essentialsProbe =
        "import _blenderkit_context\nprint(_blenderkit_context.essentials_available())"

    /// Whether Blender's GPU module has been started here, on the main thread.
    @ObservationIgnored private var gpuStartedOnMainThread = false

    /// Starts Blender's GPU module on the main thread before a script that may
    /// start it runs on the script thread.
    ///
    /// Whichever thread starts it keeps it: `WM_init_gpu` makes its context
    /// there and releases it there, and `gpu.init()` afterwards returns at
    /// once because the module is up. So an Eevee or Solid render from the
    /// Render panel — a script-thread run by default — left the main thread
    /// with no GPU context, and Knife Project, which aims Blender's view on the
    /// main thread through that module, refused for the rest of the session.
    /// Measured in desktop Blender 5.2.1: started on the main thread first, an
    /// Eevee render on a worker thread and then a Knife Project cut both work;
    /// with the render first on the worker, desktop Blender aborts, so that
    /// order cannot be run there at all (scripts/run-redo-blender-check.sh).
    /// Asked once per session, and only of a script that could need it.
    private func startGPUOnMainThread(before source: String, scene: BKScene) {
        guard usesRealBlender, !gpuStartedOnMainThread, ScriptThread.mayStartGPU(source)
        else { return }
        gpuStartedOnMainThread = true
        _ = runtime.query(ScriptThread.gpuStart, scene: scene)
    }
    @ObservationIgnored private var loggedHistoryMode = ""
    @ObservationIgnored private var autosavePolicy = AutosavePolicy()
    @ObservationIgnored private var autosaveCheck: DispatchWorkItem?

    public func capture(_ source: String) -> String? {
        guard !isRunning, let boundScene else { return nil }
        let lines = runtime.query(source, scene: boundScene)
        if lines.contains(where: { $0.kind == .error }) {
            console += lines
            return nil
        }
        return lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func prepareBackendChange() {
        guard usesRealBlender, !backendSeeded else { return }
        record("Original", replace: false, changed: false)
    }

    /// Where the history writes .blend files, when it needs them: every step in
    /// the checkpoint fallback, and with Blender's undo only around a file load.
    static var historyRoot: String {
        SceneDocument.documentsURL.appendingPathComponent(".blender-history").path
    }

    /// The file the app recovers from on launch; RootView opens it.
    public static var recoveryURL: URL {
        SceneDocument.documentsURL.appendingPathComponent("autosave.blend")
    }

    /// Debug builds accept `-undo-checkpoints`, which keeps the history in .blend
    /// checkpoints even where Blender's undo works — the fallback, on demand.
    static var forcesCheckpoints: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-undo-checkpoints")
        #else
        return false
        #endif
    }

    /// Records the scene as it is now as one undo step called `label`.
    ///
    /// On the main thread, as every caller already is: the bpy module's main
    /// thread has the window and screen Blender's undo operators poll for, and
    /// the script thread has neither (see `_blenderkit_undo._context`).
    ///
    /// `replace` makes the step take the place of the one on top — adjusting the
    /// last operation.
    public func recordBackendChange(_ label: String, replace: Bool = false) {
        record(label, replace: replace, changed: true)
    }

    private func record(_ label: String, replace: Bool, changed: Bool) {
        guard usesRealBlender, !isRunning else { return }
        let started = Date()
        let code = BackendHistoryPython.push(root: Self.historyRoot, label: label, replace: replace,
                                             forceCheckpoints: Self.forcesCheckpoints)
        guard let value = capture(code) else { return }
        applyBackendHistory(value, what: label, started: started)
        backendSeeded = true
        backendRevision &+= 1
        // The seed is the scene as it was loaded, which the recovery file
        // already is or does not need to be.
        if changed { noteBackendChange() }
    }

    private func applyBackendHistory(_ text: String, what: String, started: Date,
                                     mirror: TimeInterval = 0) {
        guard let state = BackendHistoryState.parse(text) else { return }
        backendHistory = state
        backendCanUndo = state.undo
        backendCanRedo = state.redo
        if state.mode != loggedHistoryMode, state.mode != "pending" {
            loggedHistoryMode = state.mode
            print(state.usesBlenderUndo
                  ? "[bk-undo] undo history: Blender's undo system (\(state.why))"
                  : "[bk-undo] undo history: .blend checkpoints (\(state.why))")
            fflush(stdout)
        }
        #if DEBUG
        print(state.logLine(what)
              + String(format: " · mirror %.2f ms · round trip %.2f ms",
                       mirror * 1000, Date().timeIntervalSince(started) * 1000))
        fflush(stdout)
        #endif
    }

    private func stepBackendHistory(_ direction: Int) {
        guard let boundScene else { return }
        let verb = direction < 0 ? "Undo" : "Redo"
        let name = direction < 0 ? backendHistory.undoLabel : backendHistory.redoLabel
        let started = Date()
        let output = runtime.evaluate(BackendHistoryPython.step(direction), scene: boundScene)
        if output.contains(where: { $0.kind == .error }) { console += output; return }
        applyBackendHistory(output.filter { $0.kind == .output }.map(\.text).joined(separator: "\n"),
                            what: verb, started: started, mirror: runtime.lastSyncDuration)
        backendRevision &+= 1
        noteBackendChange()
        note((name.isEmpty ? verb : "\(verb) \(name)")
             + ". Reacquire Python variables that referenced old Blender datablocks.")
    }

    /// Undoes the step on top so that the next `recordBackendChange(_:replace:)`
    /// takes its place: how Blender's redo panel adjusts an operator — undo it,
    /// run it again, push. Only with Blender's undo, where that costs a few
    /// milliseconds rather than a file load. No mirroring pass: the re-run
    /// that follows makes one.
    ///
    /// False when there is no step to go back to, and nothing changed.
    public func rewindBackendStep() -> Bool {
        guard usesRealBlender, backendUsesBlenderUndo, !isRunning, let boundScene else { return false }
        let started = Date()
        let output = runtime.query(BackendHistoryPython.rewind, scene: boundScene)
        guard !output.contains(where: { $0.kind == .error }) else { return false }
        applyBackendHistory(output.map(\.text).joined(separator: "\n"), what: "Rewind", started: started)
        return true
    }

    /// The re-run after `rewindBackendStep` failed: back to the step it undid.
    public func cancelBackendRewind() {
        guard usesRealBlender, !isRunning, let boundScene else { return }
        let started = Date()
        let output = runtime.evaluate(BackendHistoryPython.cancelRewind, scene: boundScene)
        applyBackendHistory(output.filter { $0.kind == .output }.map(\.text).joined(separator: "\n"),
                            what: "Cancel rewind", started: started, mirror: runtime.lastSyncDuration)
        backendRevision &+= 1
    }

    // MARK: crash recovery

    /// Something changed that the recovery file does not have yet.
    ///
    /// Undo steps used to be .blend files, and the newest was linked into place
    /// as `autosave.blend` — which put a whole-scene write in every step. The
    /// steps are Blender's undo now, so the recovery file is written on its own:
    /// two seconds after the work pauses, never under a running script, and at
    /// once when the app goes to the background (`flushBackendAutosave`).
    private func noteBackendChange() {
        guard usesRealBlender else { return }
        autosavePolicy.noteChange()
        scheduleAutosaveCheck(after: AutosavePolicy.quiet)
    }

    private func scheduleAutosaveCheck(after delay: TimeInterval) {
        autosaveCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosaveIfQuiet() }
        autosaveCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func autosaveIfQuiet() {
        // Not under a stroke either: the write would hold the stroke's chunks
        // for as long as it takes, and the stroke's end schedules it again.
        switch autosavePolicy.decide(running: isRunning || gestureHold != nil) {
        case .nothing: return
        case .wait(let seconds): scheduleAutosaveCheck(after: seconds)
        case .write: writeBackendAutosave()
        }
    }

    /// Writes the recovery file now, if anything is waiting to be written — the
    /// app is going to the background. Not while a script runs: the script's
    /// thread has bpy, and it will be written once the run ends.
    public func flushBackendAutosave() {
        guard usesRealBlender, autosavePolicy.isPending, !isRunning else { return }
        autosaveCheck?.cancel()
        writeBackendAutosave()
    }

    private func writeBackendAutosave() {
        guard let written = capture(BackendHistoryPython.autosave(path: Self.recoveryURL.path)) else {
            return
        }
        autosavePolicy.noteWritten()
        #if DEBUG
        print("[bk-undo] autosave.blend written in \(written.split(separator: "\n").last ?? "?") ms")
        fflush(stdout)
        #endif
    }

    public func openDocument(_ url: URL, scene: BKScene) {
        guard !isRunning else { return }
        if let held = gestureHold { note(held); return }
        if usesRealBlender {
            guard url.pathExtension == "blend" else { note("Open a .blend file with the Blender backend."); return }
            submit("bpy.ops.wm.open_mainfile(filepath=\(Bpy.quote(url.path)), load_ui=False)", scene: scene)
        } else {
            do { try SceneDocument.read(url, into: scene) }
            catch { note("Open failed: \(error.localizedDescription)") }
        }
    }

    public func saveDocument(_ url: URL, scene: BKScene) {
        guard !isRunning else { return }
        if usesRealBlender {
            let result = capture("import bpy; print(bpy.ops.wm.save_as_mainfile(filepath=\(Bpy.quote(url.path)), copy=True, check_existing=False))")
            note(result?.contains("FINISHED") == true ? "Saved \(url.lastPathComponent)" : "Blender could not save the document. See console.")
        } else {
            do { try SceneDocument.write(scene, to: url); note("Saved \(url.lastPathComponent)") }
            catch { note("Save failed: \(error.localizedDescription)") }
        }
    }

    /// Put Blender back in object mode before a run, returning a line to log
    /// if it actually had to change anything.
    ///
    /// Quiet and best-effort: there may be no active object, and on the command
    /// subset there is no mode to set.
    private func returnToObjectMode() -> String? {
        guard let boundScene else { return nil }
        let before = runtime.introspect("")  // cheap liveness check; nil on the subset
        guard before != nil else { return nil }
        let mode = capture("print(getattr(bpy.context.view_layer.objects.active, 'mode', 'OBJECT'))")
        guard let mode, mode != "OBJECT", !mode.isEmpty else { return nil }
        _ = runtime.evaluate("""
        try:
            bpy.ops.object.mode_set(mode='OBJECT')
        except Exception:
            pass
        """, scene: boundScene)
        return "Left \(mode.lowercased()) mode so the script starts from object mode."
    }

    /// What the interpreter says a dotted path has on it, for completion.
    public func introspect(_ path: String) -> [(name: String, callable: Bool)]? {
        guard !isRunning else { return nil }
        return runtime.introspect(path)
    }

    /// Whether a script runs on its own thread.
    ///
    /// It should. A bpy build script spends most of its time inside Blender's
    /// C, where the run-loop pump cannot reach — there is no bytecode boundary
    /// to run it at — so the main thread is genuinely blocked for as long as
    /// the script takes. iOS says so out loud: a 268-line bike script showed
    /// the system's hang indicator reading 631 ms.
    ///
    /// It is a setting because Blender's own documentation says the Python API
    /// is not thread safe and should be called from the main thread. That rule
    /// is about *concurrent* access, and here exactly one thread ever touches
    /// bpy — but Blender's GPU and window-system code does assert things about
    /// which thread it is on, and a script that renders may find out. If that
    /// happens on a device, this can be turned off without a new build.
    public static var runsOffMainThread: Bool {
        get { UserDefaults.standard.object(forKey: offMainThreadKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: offMainThreadKey) }
    }
    /// The defaults key behind `runsOffMainThread`, for `@AppStorage`: the
    /// toggles in the Scripting tab's Options menu and the Script menu both
    /// read it, and a plain binding would not show a change made by the other.
    /// Its default, `true`, has to match the one above.
    public static let offMainThreadKey = "bl_script_off_main_thread"

    /// The one thread that runs scripts. One, and always the same one, because
    /// bpy tolerates being spoken to from a thread that is not the main one far
    /// better than it tolerates being spoken to from two.
    @ObservationIgnored private static let scriptQueue =
        DispatchQueue(label: "bk.python.script", qos: .userInitiated)

    private func runOffMainThread(_ source: String, scene: BKScene, lines: Int,
                                  before: Int, streamStart: Int) {
        // No heartbeat here. It exists to beg the interpreter for a turn on the
        // main thread; when the script is not on the main thread there is
        // nothing to beg for, and the pending calls would only cost the script
        // time.
        let started = Date()
        ConsoleStream.runStarted = started
        // A timer on the main thread now, rather than a pump from inside the
        // interpreter: the main thread is free, so it can simply tick.
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let from = ConsoleStream.runStarted else { return }
            self.runElapsed = (Date().timeIntervalSince(from) * 10).rounded(.down) / 10
        }

        Self.scriptQueue.async { [weak self] in
            guard let self else { return }
            let output = self.runtime.evaluate(source, scene: scene)
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                ticker.invalidate()
                ConsoleStream.sink = nil
                ConsoleStream.tick = nil
                ConsoleStream.runStarted = nil
                self.isRunning = false
                self.runElapsed = 0
                self.finish(output, source: source, lines: lines, elapsed: elapsed,
                            before: before, streamStart: streamStart, scene: scene)
            }
        }
    }

    /// Where the scene is kept as the work happens. Set by the app.
    @ObservationIgnored public var autosave: Autosave?

    /// Called by the Tools tab so a UI action shows up as Python, the way
    /// Blender's Info editor does — and records one undo step for it.
    public func log(_ python: String) {
        infoLog.append(python)
        pushUndo(Self.undoLabel(for: python))
    }

    /// Runs one statement on behalf of the interface.
    ///
    /// Unlike `submit`, this does not echo the source into the console: an
    /// operator the user invoked by tapping a button does not need reading back
    /// at them. Its output and any traceback still appear, because those are
    /// things they did not already know.
    public func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        let output = runtime.evaluate(source, scene: scene)
        console += output.filter { $0.kind != .input }
        if usesRealBlender { backendRevision &+= 1 }
        return output
    }

    /// Records an operator that actually ran, and surfaces any error.
    ///
    /// The Info log holds the Python that *was executed*, not a reconstruction
    /// of what a button did — so the log and the scene cannot drift apart.
    public func logOperator(_ python: String, output: [BpyLine]) {
        let before = infoLog.count
        for line in python.split(separator: "\n") where !line.isEmpty {
            infoLog.append(String(line))
        }
        if let failure = output.last(where: { $0.kind == .error }) {
            infoLog.append("# \(failure.text.trimmingCharacters(in: .whitespaces))")
        }
        lastOperatorLines = infoLog.count - before
    }

    /// How many lines the entry on the end of the Info log occupies, so that
    /// adjusting the last operation can rewrite it rather than append beside
    /// it.
    @ObservationIgnored private var lastOperatorLines = 0

    /// Rewrites the last logged operator in place.
    ///
    /// Blender's Info log holds one line per operation, and adjusting an
    /// operation updates that line — it does not add forty more as a slider
    /// passes through forty values. Anyone reading the log back is reading a
    /// script; a script that adds one cube forty times is not the one they
    /// performed.
    public func replaceLastOperator(_ python: String) {
        if lastOperatorLines > 0, infoLog.count >= lastOperatorLines {
            infoLog.removeLast(lastOperatorLines)
        }
        logOperator(python, output: [])
    }

    /// Undo and redo, reported into the console the way Blender reports them
    /// in the status bar.
    public func performUndo() {
        guard !isRunning else { return }
        if let held = gestureHold { note(held); return }
        if usesRealBlender { stepBackendHistory(-1); return }
        guard let boundScene, let undo, let name = undo.undo(into: boundScene) else { return }
        console.append(BpyLine(.info, "Undo: \(name)"))
    }

    public func performRedo() {
        guard !isRunning else { return }
        if let held = gestureHold { note(held); return }
        if usesRealBlender { stepBackendHistory(1); return }
        guard let boundScene, let undo, let name = undo.redo(into: boundScene) else { return }
        console.append(BpyLine(.info, "Redo: \(name)"))
    }

    /// A one-line message from the interface itself, not from Python.
    public func note(_ text: String) {
        console.append(BpyLine(.info, text))
    }

    public func clearConsole() {
        console = runtime.versionBanner.split(separator: "\n").map { BpyLine(.info, String($0)) }
    }
}
