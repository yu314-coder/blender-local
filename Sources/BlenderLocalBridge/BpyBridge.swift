import Foundation
import Observation

/// The single way the interface changes anything.
///
/// Blender Local used to keep its own scene in Swift and treat `bpy` as a
/// façade over it: a button mutated `BKScene`, and the Python was written to
/// the Info log afterwards as a description of what had already happened. That
/// meant every operator had to be reimplemented — bevel, loop cut, boolean,
/// modifiers, the lot — and each reimplementation was an approximation of the
/// real thing.
///
/// The direction is inverted now. **bpy owns the scene.** A button sends
/// Python, Blender performs it, and the viewport shows what came back. The
/// Python in the Info log is no longer a description of the action; it *is* the
/// action, which is why the two can never disagree.
///
/// `BKScene` survives as the display cache the Metal viewport reads — filled by
/// `_blenderkit_sync` from the evaluated depsgraph after every command. Nothing
/// in the interface should write to it directly any more.
@Observable
public final class BpyBridge {

    /// The outcome of one command, so a caller can react without re-parsing
    /// the console.
    public struct Outcome {
        public let python: String
        public let succeeded: Bool
        /// The last line of the traceback — the part naming what went wrong.
        public let error: String?
        public let objectsBefore: Int
        public let objectsAfter: Int
    }

    /// Something that went wrong, said where the reader is looking.
    ///
    /// Blender puts an operator's failure in the status bar, under the pointer.
    /// The interface used to put it only in the Scripting tab's console — a
    /// different tab — so from the 3D View a failed Bevel was indistinguishable
    /// from a Bevel button that did nothing.
    public struct Report: Equatable, Identifiable, Sendable {
        public let id: Int
        /// What was being done: the undo name, or the operator's own name.
        public let operation: String
        /// The exception's message, without the `RuntimeError: Error:` that
        /// Blender puts in front of every operator report.
        public let message: String
    }

    @ObservationIgnored private let session: BpySession
    @ObservationIgnored private weak var scene: BKScene?
    @ObservationIgnored private weak var undo: UndoStack?

    /// Whether a script is running, during which the bridge runs nothing.
    public var isRunningScript: Bool { session.isRunning }

    /// The last command's outcome, for anything that wants to show it.
    public private(set) var lastOutcome: Outcome?

    /// The failure the interface should show, until it is dismissed or
    /// replaced. Internal bookkeeping runs never set it; anything the reader
    /// asked for does.
    public private(set) var report: Report?
    @ObservationIgnored private var reportCount = 0

    /// The operator the redo panel can re-run with different arguments —
    /// Blender's "Adjust Last Operation" — while it is still the last thing
    /// that happened. Nil otherwise, which is most of the time.
    ///
    /// "Still the last thing" is checked against the undo history rather than
    /// trusted. An Undo — from the keyboard, the top bar, anywhere — used to
    /// leave the panel up, and adjusting it then re-ran the operator on top of
    /// the restored scene and wrote the result over the undo step: the state
    /// from before the operator was simply gone. Blender hides the panel after
    /// an undo for the same reason.
    public var adjustable: LastOperator? {
        guard let remembered, rememberedMark == historyMark else { return nil }
        return remembered
    }
    private var remembered: LastOperator?
    private var rememberedMark: String?
    /// Whether the remembered operator is adjusted the way Blender's redo panel
    /// does it — undo, run again, push — rather than through its
    /// `LastOperator.Restoration`. Settled when it was performed, by whether
    /// Blender's undo was keeping the history then.
    @ObservationIgnored private var rememberedByUndo = false
    /// The edit selection handed to Blender in the remembered operator's own
    /// evaluation. It is not in the undo step before the operator, so running
    /// the operator again from that step has to hand it over again.
    ///
    /// The same holds for the object selection an object-mode operator ran
    /// on. A tap in Object Mode (`select`) changes Blender's selection without
    /// an undo step, and the rewind restores the step's own selection, so a
    /// re-run acted on the objects selected before the taps. Measured in
    /// desktop 5.2.1 through `_blenderkit_undo`: B tapped with C active after
    /// the last step, Parent, then Keep Transform in the panel, parented B to
    /// the object active at that step instead of C
    /// (scripts/run-objectops-blender-check.sh). So the selection the operator
    /// ran on goes back first, too (`Bpy.objectSelection`).
    @ObservationIgnored private var rememberedPush: String?

    /// Bumped whenever a *different* operator becomes the adjustable one.
    ///
    /// Adjusting does not bump it. The redo panel needs to tell "the user added
    /// a second cube" from "the user is dragging the first cube's Size", and
    /// the two are indistinguishable by name, by operator, or by arguments.
    public private(set) var adjustableGeneration = 0

    public init(session: BpySession, scene: BKScene, undo: UndoStack) {
        self.session = session
        self.scene = scene
        self.undo = undo
    }

    /// Where the undo history stands. Anything that moves it — a new step, an
    /// undo, a redo, a script — changes this, and an adjustable operator is
    /// only adjustable while it has not moved.
    private var historyMark: String {
        if session.usesRealBlender { return "r\(session.backendRevision)" }
        guard let undo else { return "" }
        return "s\(undo.canRedo ? 1 : 0)|\(undo.undoName ?? "")"
    }

    // MARK: running

    /// Runs one operator.
    ///
    /// `label` names the undo step, as Blender names it after the operator. A
    /// nil label means the command changes nothing worth undoing — a selection
    /// change, a mode switch, a viewport query.
    ///
    /// `setup` runs first, in the same evaluation, and is not logged: the
    /// scaffolding an operator needs rather than the operator itself.
    @discardableResult
    public func run(_ python: String, undo label: String? = nil,
                    quiet: Bool = false, setup: String? = nil) -> Outcome {
        // In the mode it needs, and back to the one it found.
        //
        // Every menu action lands here, and before this each assumed a mode:
        // measured in Blender 5.2.1, all nineteen of them — select, delete,
        // extrude, normals, UV unwrap — failed their poll in two of the three
        // modes a session can be in. The log still gets the bare operator,
        // not the bracketing, because the log is the action.
        //
        // Only when there is Python to run the bracketing. The command-subset
        // fallback — what answers when embedded Python fails to start — reads
        // one line at a time and has no modes, so there the wrapper turned
        // every working menu action into a failure.
        var parts: [String] = []
        if session.isRealRuntime {
            if let setup, !setup.isEmpty { parts.append(setup) }
            parts.append(BpyModeGuard.wrap(python))
        } else {
            parts.append(python)
        }
        parts += Bpy.autoKeying(after: python, scene: scene, interpreter: session.isRealRuntime)
        return execute(parts.joined(separator: "\n"), as: python, undo: label,
                       quiet: quiet, replacesAdjustable: label != nil)
    }

    /// Runs several statements as one operator — one undo step, one log entry.
    @discardableResult
    public func run(_ lines: [String], undo label: String? = nil) -> Outcome {
        run(lines.joined(separator: "\n"), undo: label)
    }

    /// Runs `body` and logs `call`, the operator it is built around: one
    /// undo step, a failure on the banner. For a call held to conditions
    /// Blender does not say in words — measured in 5.2.1, `curve.cyclic_toggle`
    /// with no point selected returns CANCELLED and `curve.subdivide` FINISHED,
    /// both silently, and through `run` each read as done and pushed an undo
    /// step for nothing (`PointsBpy.Command.executed`). The Info log still gets
    /// the bare call, as `LastOperator.refusal` keeps it.
    @discardableResult
    public func run(_ call: String, undo label: String?, executing body: String) -> Outcome {
        guard session.isRealRuntime else { return run(call, undo: label) }
        // A change with no undo step (a tool setting, which Blender's undo
        // does not take back) is not an operator: the redo panel stays.
        return execute(body, as: call, undo: label, quiet: false, replacesAdjustable: label != nil)
    }

    /// Everything a command costs, in one evaluation.
    ///
    /// One evaluation is one mirroring pass, and a mirroring pass walks every
    /// object's evaluated mesh. A mesh operator used to take five — backup,
    /// mode, operator, mode back, backup discarded — so a Bevel on a heavy
    /// scene paid for reading the whole scene back five times.
    private func execute(_ body: String, as python: String, undo label: String?,
                         quiet: Bool, replacesAdjustable: Bool) -> Outcome {
        guard let scene else {
            return Outcome(python: python, succeeded: false,
                           error: "no scene bound", objectsBefore: 0, objectsAfter: 0)
        }
        // Nothing may run while a script is running.
        //
        // The interface stays live during a run — the run loop is pumped so
        // the console fills and the clock moves — which means a button can be
        // pressed mid-script. Letting that through would start a second
        // execution inside the first one, on the same interpreter and the same
        // scene, from inside a pump nested in the first run's stack. Blender
        // avoids the question by freezing; this keeps the window alive and
        // refuses the input instead.
        guard !session.isRunning else {
            let message = "A script is running."
            if label != nil || !quiet {
                reportFailure(label ?? Self.operationName(for: python), message)
            }
            return Outcome(python: python, succeeded: false, error: message,
                           objectsBefore: scene.objects.count,
                           objectsAfter: scene.objects.count)
        }
        // Nor while a sculpt stroke is streaming into Blender: every chunk
        // rewinds the undo step on top, and a step pushed between chunks would
        // be the one rewound (BpySession.sculptStrokeOpen). Nor under a drag
        // of a curve's or a lattice's points, whose frames each put the points
        // back and move them again (BpySession.pointDragOpen) — its own commit
        // closes the hold before it runs.
        if let message = session.gestureHold {
            if label != nil || !quiet {
                reportFailure(label ?? Self.operationName(for: python), message)
            }
            return Outcome(python: python, succeeded: false, error: message,
                           objectsBefore: scene.objects.count,
                           objectsAfter: scene.objects.count)
        }
        if label != nil { session.prepareBackendChange() }
        let before = scene.objects.count

        // A new undoable change replaces the redo panel's operation, so its
        // mesh backup goes now — before the checkpoint below can save a copy.
        let discard = replacesAdjustable && session.isRealRuntime
            && remembered?.restoration == .restoreMesh
        // What was tapped since Blender last reported its selection. Blender's
        // operators act on Blender's selection, and nothing else tells it.
        let push = session.usesRealBlender ? pendingEditSelectionPush() : nil
        let source = Self.script(push: push, discardBackup: discard, body: body)

        // The runtime mirrors bpy back into the display cache as part of
        // evaluating, so by the time this returns the viewport is current.
        let lines = session.evaluate(source, scene: scene)
        if push != nil { scene.editSelectionPending = false }
        let error = lines.last { $0.kind == .error }?.text
            .trimmingCharacters(in: .whitespaces)

        let outcome = Outcome(python: python, succeeded: error == nil, error: error,
                              objectsBefore: before, objectsAfter: scene.objects.count)
        lastOutcome = outcome

        // Blender's Info editor lists the operator that ran. It is the same
        // string that ran, not a reconstruction of it.
        if !quiet { session.logOperator(python, output: lines) }
        if replacesAdjustable { forgetAdjustable() }
        if outcome.succeeded, let label {
            if session.usesRealBlender { session.recordBackendChange(label) }
            else { undo?.push(label, scene); session.autosave?.schedule(scene) }
        } else if let error, label != nil || !quiet {
            reportFailure(label ?? Self.operationName(for: python), error)
        }
        // Blender's status bar shows an operator's warnings; called from
        // Python they are only printed. Unwrap's "failed to solve 1 of 7
        // island(s)" is one: the operator answers FINISHED, and the warning
        // never left the console (round 2's review).
        if outcome.succeeded, label != nil || !quiet,
           let warning = Self.blenderWarning(in: lines) {
            reportFailure(label ?? Self.operationName(for: python), warning)
        }
        return outcome
    }

    /// The last operator warning in a command's output, as Blender writes a
    /// report when Python calls the operator (`BPy_reports_write_stdout`:
    /// "Warning: " and the text).
    public static func blenderWarning(in lines: [BpyLine]) -> String? {
        for line in lines.reversed() where line.kind == .output {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Warning: "), text.count > "Warning: ".count {
                return String(text.dropFirst("Warning: ".count))
            }
        }
        return nil
    }

    /// The source one command sends: the selection Blender has not been told
    /// about, the backup nobody needs any more, then the command.
    public static func script(push: String?, discardBackup: Bool, body: String) -> String {
        var parts: [String] = []
        if discardBackup { parts.append(LastOperator.discardBackup) }
        if let push, !push.isEmpty { parts.append(push) }
        parts.append(body)
        return parts.joined(separator: "\n")
    }

    /// What a tap sends: the selection change, in the mode it needs, and a
    /// mirror of the selection alone.
    public static func selectionScript(_ python: String) -> String {
        BpyModeGuard.wrap(python)
            + "\nimport _blenderkit_sync as _bk_sync\n_bk_sync.sync_selection()"
    }

    // MARK: failures

    private func reportFailure(_ operation: String, _ error: String) {
        reportCount &+= 1
        report = Report(id: reportCount, operation: operation,
                        message: Self.readable(error))
    }

    /// Takes the report down, if it is still the one on screen.
    public func dismissReport(_ id: Int) {
        if report?.id == id { report = nil }
    }

    /// A report Blender makes outside any one command's failure — auto keying
    /// that could not key, which Blender puts in its status bar — shown where
    /// a failed command's report is.
    public func showReport(_ operation: String, _ message: String) {
        reportFailure(operation, message)
    }

    /// What Blender's status bar would say: the message, without the
    /// exception machinery in front of it.
    public static func readable(_ error: String) -> String {
        var text = error.trimmingCharacters(in: .whitespaces)
        for prefix in ["RuntimeError: ", "Error: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text.isEmpty ? error : text
    }

    /// "bpy.ops.mesh.select_all(…)" reads as "Select All".
    static func operationName(for python: String) -> String {
        let call = python.split(separator: "(").first.map(String.init) ?? python
        guard call.hasPrefix("bpy.ops."), let name = call.split(separator: ".").last
        else { return "Operation" }
        return name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: adjustable operators

    /// Forgets the adjustable operator. Its backup, if it has one, is dropped
    /// by the next command that replaces it, in that command's own evaluation.
    private func forgetAdjustable() {
        guard remembered != nil else { return }
        remembered = nil
        rememberedMark = nil
        rememberedByUndo = false
        rememberedPush = nil
        adjustableGeneration &+= 1
    }

    private func remember(_ op: LastOperator) {
        remembered = op
        rememberedMark = historyMark
        adjustableGeneration &+= 1
    }

    /// A selection made in the viewport. In Blender a click is an operator of
    /// its own, and it replaces the redo panel's.
    public func noteSelectionChanged() {
        forgetAdjustable()
    }

    /// Runs an operator and remembers how to run it again.
    ///
    /// The name of what it made has to be read back rather than guessed:
    /// asking for a cube gets you `Cube`, or `Cube.001`, or — if the user
    /// renamed the first one — `Cube` again. Only Blender knows.
    @discardableResult
    public func perform(_ op: LastOperator) -> Outcome {
        var op = op
        let outcome: Outcome
        // Which history is in use has to be known before the body is built:
        // with Blender's undo the way back is an undo, and a mesh backup would
        // only be one more copy of the mesh in every undo step.
        if !session.isRunning { session.prepareBackendChange() }
        let byUndo = session.usesRealBlender && session.backendUsesBlenderUndo
        let push = session.usesRealBlender ? pendingEditSelectionPush() : nil
        // Read before the operator changes it: what it is about to act on.
        let selection = session.usesRealBlender && !op.needsEditMode
            ? scene.map(Bpy.objectSelection(of:)) : nil
        if session.isRealRuntime {
            outcome = execute(Self.performBody(for: op, backup: !byUndo), as: op.python,
                              undo: op.name, quiet: true, replacesAdjustable: true)
        } else {
            // The command subset reads one line at a time: no modes, no
            // backups, only the operator.
            outcome = execute(op.executedPython, as: op.python, undo: op.name,
                              quiet: true, replacesAdjustable: true)
        }
        session.logOperator(op.python,
                            output: outcome.error.map { [BpyLine(.error, $0)] } ?? [])
        guard outcome.succeeded else { return outcome }

        if session.isRealRuntime {
            // One question, asked without a mirroring pass: did the backup
            // take, and what did Blender call the object.
            guard let answer = capture("print(_bk_adjustable)\n"
                                       + "print(bpy.context.view_layer.objects.active.name)")
            else { return outcome }
            let lines = answer.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // When the backup failed the operator still ran; it simply does
            // not become adjustable, which is the truth rather than a panel
            // whose sliders would compound on their own output. The simulator's
            // shim is one such backend: its meshes are proxies, not datablocks.
            guard lines.count >= 2, lines[lines.count - 2] == "True" else { return outcome }
            op.subject = lines[lines.count - 1]
        } else {
            // The command subset and the simulator's stand-in keep no
            // Blender undo, which is the only way back from these.
            guard op.restoration != .throughBlenderUndo else { return outcome }
            op.subject = capture("print(bpy.context.view_layer.objects.active.name)")
        }
        remember(op)
        rememberedByUndo = byUndo
        rememberedPush = Self.rerunLead(selection: selection, editPush: push)
        return outcome
    }

    /// What a re-run through undo hands Blender before the operator: the
    /// object selection it ran on, then the edit selection pushed with it —
    /// neither is in the undo step it goes back to.
    public static func rerunLead(selection: String?, editPush: String?) -> String? {
        let parts = [selection, editPush].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// One mesh or add operator, as a single block of Python: into the mode it
    /// needs, the backup that makes it adjustable, the operator, and back to
    /// the mode it found — whether or not the operator worked.
    ///
    /// The backup comes after the mode switch, not before: in edit mode the
    /// mesh datablock only holds the selection once `update_from_editmode` has
    /// written it, and the backup has to carry the selection the operator acts
    /// on, or adjusting it afterwards would act on some other one.
    ///
    /// A backup that fails leaves `_bk_adjustable` False and the operator still
    /// runs.
    ///
    /// `backup: false` leaves the mesh backup out: with Blender's undo keeping
    /// the history, the way back to before the operator is an undo.
    public static func performBody(for op: LastOperator, backup: Bool = true) -> String {
        var lines = ["_bk_adjustable = False", op.entryPython, "try:"]
        switch (op.restoration, backup) {
        case (.removeCreated, _), (.restoreMesh, false), (.throughBlenderUndo, false):
            lines.append("    _bk_adjustable = True")
        case (.throughBlenderUndo, true):
            // Nothing but Blender's undo can put it back, and that is not
            // keeping the history: it runs, and no panel opens for it.
            break
        case (.restoreMesh, true):
            lines += ["    try:",
                      indent(op.preamble, by: 8),
                      "        _bk_adjustable = True",
                      "    except Exception:",
                      "        pass"]
        }
        lines += [indent(op.executedPython, by: 4),
                  "finally:",
                  indent(op.exitPython, by: 4)]
        return lines.joined(separator: "\n")
    }

    static func indent(_ text: String, by count: Int) -> String {
        let pad = String(repeating: " ", count: count)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }

    /// Re-runs the remembered operator with changed arguments.
    ///
    /// Quiet, and it replaces the undo step rather than pushing a new one:
    /// dragging a slider is one edit to one operation, not forty operations.
    /// That is Blender's behaviour too — after adjusting, a single undo takes
    /// you to before the add, not back through every value you passed on the
    /// way.
    ///
    /// `record: false` re-runs without writing the undo step, for the frames of
    /// a drag; `recordAdjustment()` writes it once the drag ends. On device the
    /// step is a whole `.blend` file, and writing one per frame of a slider is
    /// most of what made the panel lag.
    ///
    /// Returns the operator with its `subject` refreshed, which the caller must
    /// keep: the next adjustment has to remove *this* object, and it is not
    /// necessarily named what the last one was.
    @discardableResult
    public func readjust(_ op: LastOperator, record: Bool = true) -> LastOperator? {
        guard adjustable != nil else { return nil }
        if rememberedByUndo { return readjustThroughUndo(op) }
        var op = op
        let outcome = execute(op.rerunPython, as: op.python, undo: nil, quiet: true,
                              replacesAdjustable: false)
        guard outcome.succeeded else {
            reportFailure(op.name, outcome.error ?? "It could not be run again.")
            return nil
        }
        // Only an operator that made something can have named something new.
        // A mesh operator changed the object it was given, and re-reading the
        // active object would hand back whatever the mode round-trip left
        // active — which on a bad day is not the object being edited.
        if op.restoration == .removeCreated {
            op.subject = capture("print(bpy.context.view_layer.objects.active.name)")
        }
        remembered = op
        session.replaceLastOperator(op.python)
        if record { writeAdjustment(op) }
        rememberedMark = historyMark
        return op
    }

    /// Blender's redo panel: undo the operator, run it again with the new
    /// arguments, and let the new step take the undone one's place — so the
    /// result is exactly what running it with those arguments the first time
    /// would have made, with nothing for a restoration to miss.
    ///
    /// Every re-run is recorded, drag or not: a push is a fraction of a
    /// millisecond, and the next frame's undo needs the step to go back from.
    private func readjustThroughUndo(_ op: LastOperator) -> LastOperator? {
        var op = op
        guard session.rewindBackendStep() else {
            reportFailure(op.name, "Blender's undo could not go back to before it, so it cannot be run again.")
            return nil
        }
        let body = Self.script(push: rememberedPush, discardBackup: false,
                               body: Self.performBody(for: op, backup: false))
        let outcome = execute(body, as: op.python, undo: nil, quiet: true, replacesAdjustable: false)
        guard outcome.succeeded else {
            // Back to the step the rewind undid — the last adjustment that
            // worked — rather than leaving the operator undone.
            session.cancelBackendRewind()
            reportFailure(op.name, outcome.error ?? "It could not be run again.")
            return nil
        }
        if op.restoration == .removeCreated {
            op.subject = capture("print(bpy.context.view_layer.objects.active.name)")
        }
        remembered = op
        session.replaceLastOperator(op.python)
        session.recordBackendChange(op.name, replace: true)
        rememberedMark = historyMark
        return op
    }

    /// Writes the adjusted operation over its undo step. Nothing to do when
    /// Blender's undo adjusts it: every re-run already replaced the step.
    public func recordAdjustment() {
        guard let op = adjustable, !rememberedByUndo else { return }
        writeAdjustment(op)
        rememberedMark = historyMark
    }

    private func writeAdjustment(_ op: LastOperator) {
        guard let scene else { return }
        if session.usesRealBlender { session.recordBackendChange(op.name, replace: true) }
        else { undo?.replaceTop(op.name, scene); session.autosave?.schedule(scene) }
    }

    // MARK: selection

    /// Runs a selection change and mirrors only the selection.
    ///
    /// A full mirroring pass re-reads every mesh in the scene, which is the
    /// right price after an operator and far too high for a tap that changed a
    /// few flags. Blender's own selection still changes — it is what a
    /// following Move acts on — so this is still bpy, just without the scene
    /// read-back.
    @discardableResult
    public func select(_ python: String) -> Outcome {
        guard session.usesRealBlender, let scene, !session.isRunning, session.gestureHold == nil else {
            return run(python)
        }
        forgetAdjustable()
        let before = scene.objects.count
        let consoleBefore = session.console.count
        let answer = session.capture(Self.selectionScript(python))
        var error: String?
        if answer == nil {
            error = session.console.dropFirst(consoleBefore)
                .last { $0.kind == .error }?.text
                .trimmingCharacters(in: .whitespaces) ?? "The selection did not change."
        }
        let outcome = Outcome(python: python, succeeded: error == nil, error: error,
                              objectsBefore: before, objectsAfter: scene.objects.count)
        lastOutcome = outcome
        session.logOperator(python, output: error.map { [BpyLine(.error, $0)] } ?? [])
        if let error { reportFailure("Select", error) }
        return outcome
    }

    /// Whether commands reach the real Blender, whose edit mesh a selection
    /// can be pushed into and read back from. False on the simulator's
    /// stand-in, which reads the interface's selection instead.
    public var usesRealBlender: Bool { session.usesRealBlender }

    /// The Python that hands the viewport's edit selection to Blender, when
    /// the viewport has one Blender has not been told about.
    private func pendingEditSelectionPush() -> String? {
        // Not onto a curve or a lattice: their points are selected in Blender
        // as they are tapped (`PointsBpy.select`), and the mesh push run on
        // one fails the command it precedes (5.2.1: "expected 'Mesh' type
        // found 'Curve' instead").
        guard let scene, scene.editSelectionPending, scene.mode == .edit,
              let object = scene.active, !object.editsPoints else { return nil }
        return Bpy.pushEditSelection(scene.editSelection, mode: scene.selectMode, of: object)
    }

    // MARK: reading back

    /// Asks bpy a question and returns what it printed, trimmed.
    ///
    /// Used where the interface needs a value Blender owns — a modifier list, a
    /// material name — rather than one the display cache happens to carry.
    public func query(_ expression: String) -> String? {
        capture("print(\(expression))")
    }

    /// Runs code purely to read its output back.
    ///
    /// Nothing is logged and no undo step is recorded: this is the interface
    /// asking Blender about itself, not the user performing an action.
    public func capture(_ python: String) -> String? {
        guard scene != nil, !session.isRunning else { return nil }
        return session.capture(python)
    }

    // MARK: sculpting

    /// Whether strokes in Sculpt Mode go to Blender's own brushes. False on
    /// the simulator's stand-in, whose Swift brushes are an approximation.
    public var sculptsInBlender: Bool { session.usesRealBlender }

    #if DEBUG
    /// The session, for the DEBUG launch hooks that press Undo and Redo the
    /// way the top bar does (`-sculpt-undo`).
    public var debugSession: BpySession { session }
    #endif

    /// A drag of a curve's or a lattice's points, from `beginPointDrag` to its
    /// commit or cancel (ControlPoints.swift). While it is open the session
    /// runs nothing else (`BpySession.pointDragOpen`).
    public internal(set) var pointDragOpen: Bool {
        get { session.pointDragOpen }
        set { session.pointDragOpen = newValue }
    }

    /// The stroke in progress, from `sculptBegin` to `sculptEnd`. While it is
    /// open the session runs nothing else (`BpySession.sculptStrokeOpen`).
    public private(set) var sculptStrokeActive = false {
        didSet { session.sculptStrokeOpen = sculptStrokeActive }
    }

    /// Starts a stroke on `object` with Blender's brush, the view aimed where
    /// the 3D View's camera looks. Nil, with the reason on the banner, when
    /// Blender refuses — no mesh in Sculpt Mode, no brush, no undo or GPU.
    ///
    /// No mirroring pass: each chunk mirrors the one object it changed
    /// (`_blenderkit_sculpt._mirror`), and the history's step is written when
    /// the stroke ends, as the steps Blender pushed for it.
    public func sculptBegin(object: String, camera: SculptCamera, viewWidth: Float,
                            viewHeight: Float, mode: SculptStrokeMode) -> SculptStrokeStart? {
        guard scene != nil else { return nil }
        guard session.usesRealBlender else { return nil }
        guard !session.isRunning else {
            reportFailure("Sculpt Stroke", "A script is running.")
            return nil
        }
        // A stroke whose end never came — its gesture went away without
        // ending — is ended and recorded first, so its steps are a history
        // step of their own rather than stranded under this one.
        if sculptStrokeActive { sculptEnd() }
        forgetAdjustable()
        // The history's first step is pushed here if it has none yet, before
        // the stroke counts Blender's steps from where the stack stands.
        session.prepareBackendChange()
        guard let text = sculptCapture(SculptBpy.begin(object: object, camera: camera,
                                                         viewWidth: viewWidth, viewHeight: viewHeight,
                                                         mode: mode), failing: "Sculpt Stroke"),
              let start = SculptJSON.last(SculptStrokeStart.self, in: text)
        else { return nil }
        sculptStrokeActive = true
        return start
    }

    /// Streams the stroke's next points. Nil when Blender refused them, and
    /// the stroke should end.
    public func sculptChunk(_ points: [SculptPoint]) -> SculptChunkResult? {
        guard sculptStrokeActive, !points.isEmpty else { return nil }
        guard let text = sculptCapture(SculptBpy.chunk(points), failing: "Sculpt Stroke") else { return nil }
        return SculptJSON.last(SculptChunkResult.self, in: text)
    }

    /// Ends the stroke. What it made is one step of the history, as deep as
    /// the steps Blender pushed for it, so one Undo takes it all back.
    @discardableResult
    public func sculptEnd(label: String = "Sculpt Stroke") -> SculptStrokeEnd? {
        guard sculptStrokeActive else { return nil }
        // Open until Blender has ended it, and closed before the history
        // records it: the record is a push the open stroke would refuse.
        let text = sculptCapture(SculptBpy.end, failing: label)
        sculptStrokeActive = false
        guard let text, let end = SculptJSON.last(SculptStrokeEnd.self, in: text) else { return nil }
        // A stroke gathered for the lift (a Multires level) that could not be
        // made then: what Blender said, where the reader is looking.
        if let refused = end.refused { reportFailure(label, refused) }
        if end.pushed > 0 {
            session.logOperator("# \(label): \(end.dabs) dabs of Blender's brush in \(end.chunks) "
                                + "chunk\(end.chunks == 1 ? "" : "s") (_blenderkit_sculpt)", output: [])
            session.recordBackendChange(label)
        }
        return end
    }

    /// Blender's sculpt settings, read without a mirroring pass.
    public func sculptState() -> SculptState? {
        guard session.usesRealBlender, let text = capture(SculptBpy.stateQuery) else { return nil }
        return SculptState.parse(text)
    }

    /// Blender's Essentials sculpt brushes.
    public func sculptBrushes() -> [String] {
        guard session.usesRealBlender, let text = capture(SculptBpy.brushesQuery) else { return [] }
        return SculptJSON.last([String].self, in: text) ?? []
    }

    /// Runs Python purely for what it prints, as `capture` does, and puts a
    /// failure on the banner under `operation` — Blender's own words for it.
    /// A curve's or a lattice's drag previews through this every frame.
    public func captureReporting(_ python: String, failing operation: String) -> String? {
        guard scene != nil, !session.isRunning else { return nil }
        return sculptCapture(python, failing: operation)
    }

    /// Runs one piece of the stroke's Python purely for what it prints,
    /// reporting a failure on the banner.
    private func sculptCapture(_ python: String, failing operation: String) -> String? {
        let consoleBefore = session.console.count
        guard let text = session.capture(python) else {
            let error = session.console.dropFirst(consoleBefore).last { $0.kind == .error }?.text
                .trimmingCharacters(in: .whitespaces) ?? "Blender did not answer."
            reportFailure(operation, error)
            return nil
        }
        return text
    }

    // MARK: texture paint

    /// Keeps a texture-paint stroke, as one undo step.
    ///
    /// The stroke is already on screen: it was painted into the viewport's
    /// images as it happened. On device `python` writes those pixels into
    /// Blender's images and packs them, and a checkpoint records the step.
    /// Unlike `run` there is no mirroring pass afterwards — the write changes
    /// no geometry, and re-reading every mesh of a heavy scene at the end of
    /// each stroke would be the slowest part of painting. With the simulator's
    /// shim the viewport's images are the scene, and only the step is kept.
    @discardableResult
    public func keepTexturePaint(_ python: String, undo label: String = TexturePaintBpy.undoName) -> Bool {
        guard let scene else { return false }
        guard !session.isRunning else {
            reportFailure(label, "A script is running.")
            return false
        }
        forgetAdjustable()
        guard session.usesRealBlender else {
            undo?.push(label, scene)
            session.autosave?.schedule(scene)
            return true
        }
        session.prepareBackendChange()
        let consoleBefore = session.console.count
        guard session.capture(python) != nil else {
            let error = session.console.dropFirst(consoleBefore).last { $0.kind == .error }?.text
                .trimmingCharacters(in: .whitespaces) ?? "The stroke could not be written into Blender."
            reportFailure(label, error)
            return false
        }
        session.logOperator(python, output: [])
        session.recordBackendChange(label)
        return true
    }

    /// Entering Texture Paint on an object: Blender's Add Simple UVs and Add
    /// Paint Slot where it lacks a UV map or an image, in one evaluation, so
    /// the mirroring pass hands the viewport what they made. One undo step,
    /// named after the operator that made the image — and none when there was
    /// nothing to make. Returns the names of the operators that ran.
    @discardableResult
    public func enterTexturePaint(object name: String) -> [String] {
        guard let scene, !session.isRunning else { return [] }
        forgetAdjustable()
        guard session.isRealRuntime else {
            // The command subset has no Python to run the stand-in through.
            guard let object = scene.objects.first(where: { $0.name == name }) else { return [] }
            let made = TexturePaintImages.prepareShim(object, in: scene, width: 1024, height: 1024)
            if let label = TexturePaintBpy.undoName(for: made) { undo?.push(label, scene) }
            return made
        }
        session.prepareBackendChange()
        let lines = session.evaluate(TexturePaintBpy.enter(object: name), scene: scene)
        if let error = lines.last(where: { $0.kind == .error })?.text
            .trimmingCharacters(in: .whitespaces) {
            reportFailure("Texture Paint", error)
            return []
        }
        // Read back rather than printed, which would put it in the console.
        let made = (session.capture(TexturePaintBpy.madeQuery) ?? "")
            .split(separator: "\n").map(String.init)
        guard let label = TexturePaintBpy.undoName(for: made) else { return [] }
        if session.usesRealBlender { session.recordBackendChange(label) }
        else { undo?.push(label, scene); session.autosave?.schedule(scene) }
        return made
    }
}

/// The Python for the operations the interface offers.
///
/// Everything here is a string that Blender runs — there is no Swift
/// implementation behind any of it. That is the point: `bpy.ops.mesh.bevel`
/// works because it is Blender's bevel, not an approximation of it.
public enum Bpy {

    // MARK: objects

    /// Blender logs an add with all of its arguments spelled out, not just the
    /// location, so that copying the line out of the Info log reproduces the
    /// object exactly. Deriving this from the same description the redo panel
    /// edits is what keeps the two from drifting apart.
    public static func addPrimitive(_ kind: PrimitiveKind, at location: SIMD3<Float>) -> String {
        LastOperator.add(kind, at: location).python
    }

    public static let deleteSelected = "bpy.ops.object.delete(use_global=False)"
    public static let duplicate = "bpy.ops.object.duplicate_move()"
    /// Shift+D in a mesh's Edit Mode: the selected elements, as Blender's own
    /// does there, left selected in place for the gizmo to move. Measured in
    /// 5.2.1 with the app's context: a cube with one face selected went from
    /// 8/12/6 to 12/16/7 vertices/edges/faces and stayed one object. The
    /// object Duplicate run from Edit Mode had made Cube.001 instead (round
    /// 3's review).
    public static let duplicateElements = "bpy.ops.mesh.duplicate_move()"
    public static let selectAll = "bpy.ops.object.select_all(action='SELECT')"
    public static let deselectAll = "bpy.ops.object.select_all(action='DESELECT')"
    public static let invertSelection = "bpy.ops.object.select_all(action='INVERT')"

    /// Into one of Blender's modes, refusing in a sentence what it cannot do.
    ///
    /// Only a mesh has an edit, sculpt or paint mode. Asking for one with a
    /// light active gets `mode_set` an enum it does not have, and Blender says
    /// so in its own words:
    ///
    ///     TypeError: Converting py args to operator properties:
    ///     enum "EDIT" not found in ('OBJECT')
    ///
    /// which tells someone holding a tablet nothing about the light they have
    /// selected. Object mode is never refused: it is the way back.
    ///
    /// Edit Mode is a curve's and a lattice's too: Blender edits them by their
    /// control points, which the 3D View draws and moves
    /// (ControlPoints.swift). The sculpt and paint modes stay a mesh's.
    public static func setMode(_ mode: InteractionMode) -> String {
        guard mode != .object else { return "bpy.ops.object.mode_set(mode='OBJECT')" }
        return (mode == .edit ? needsEditable(for: mode.label) : needsAMesh(for: mode.label))
            + "\nbpy.ops.object.mode_set(mode='\(mode.bpyMode)')"
    }

    /// Tab: out of edit mode if Blender is in it, into it otherwise.
    ///
    /// Decided by Blender's mode, read at the moment of pressing, not by what
    /// the interface last showed — the two disagreeing is how Tab once kept
    /// asking for the edit mode Blender was already in. Leaving is always
    /// allowed, so only the way in is held to a mesh.
    public static let toggleEditMode = """
    if getattr(bpy.context.view_layer.objects.active, 'mode', 'OBJECT') == 'EDIT':
        bpy.ops.object.mode_set(mode='OBJECT')
    else:
    \(needsEditable(for: "Edit Mode").split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        bpy.ops.object.mode_set(mode='EDIT')
    """

    /// The lines that refuse Edit Mode for an object this app cannot edit:
    /// anything but a mesh, a curve or a lattice. A text object has a Blender
    /// Edit Mode too, but it is typed into, and a surface's points are a grid
    /// this app does not draw — so both are refused in a sentence rather than
    /// left in a mode with nothing on screen to edit.
    public static func needsEditable(for what: String) -> String {
        """
        _bk_o = bpy.context.view_layer.objects.active
        if _bk_o is None:
            raise RuntimeError(\(quote(what)) + " needs an object. Select a mesh, a curve or a lattice first.")
        if _bk_o.type not in ('MESH', 'CURVE', 'LATTICE'):
            raise RuntimeError(\(quote(what)) + " works on meshes, curves and lattices here, and " + _bk_o.name + " is "
                               + {'LIGHT': 'a light', 'CAMERA': 'a camera', 'EMPTY': 'an empty',
                                  'SURFACE': 'a surface', 'FONT': 'a text object',
                                  'ARMATURE': 'an armature', 'META': 'a metaball', 'VOLUME': 'a volume',
                                  'SPEAKER': 'a speaker', 'POINTCLOUD': 'a point cloud',
                                  'LIGHT_PROBE': 'a light probe', 'GPENCIL': 'a grease pencil object',
                                  'GREASEPENCIL': 'a grease pencil object',
                                  }.get(_bk_o.type, 'a ' + _bk_o.type.lower())
                               + ".")
        """
    }

    /// The lines that refuse a mode the active object cannot be in.
    ///
    /// Named with the article, so the sentence reads: "Edit Mode works on
    /// meshes, and Sun is a light. Select a mesh first."
    public static func needsAMesh(for what: String) -> String {
        """
        _bk_o = bpy.context.view_layer.objects.active
        if _bk_o is None:
            raise RuntimeError(\(quote(what)) + " needs an object. Select a mesh first.")
        if _bk_o.type != 'MESH':
            raise RuntimeError(\(quote(what)) + " works on meshes, and " + _bk_o.name + " is "
                               + {'LIGHT': 'a light', 'CAMERA': 'a camera', 'EMPTY': 'an empty',
                                  'CURVE': 'a curve', 'SURFACE': 'a surface', 'FONT': 'a text object',
                                  'ARMATURE': 'an armature', 'LATTICE': 'a lattice',
                                  'META': 'a metaball', 'VOLUME': 'a volume', 'SPEAKER': 'a speaker',
                                  'POINTCLOUD': 'a point cloud', 'LIGHT_PROBE': 'a light probe',
                                  'GPENCIL': 'a grease pencil object',
                                  'GREASEPENCIL': 'a grease pencil object',
                                  }.get(_bk_o.type, 'a ' + _bk_o.type.lower())
                               + ". Select a mesh first.")
        """
    }

    /// Back to object mode from a sculpt or paint mode Blender is really in —
    /// one a script put it in. The interface's own painting leaves Blender in
    /// object mode, so usually this finds nothing to do; its Sculpt Mode is
    /// Blender's own and is left with `SculptBpy.leave`, as an undo step.
    public static let leaveBrushMode = """
    _bk_o = bpy.context.view_layer.objects.active
    if _bk_o is not None and _bk_o.mode not in ('OBJECT', 'EDIT'):
        bpy.ops.object.mode_set(mode='OBJECT')
    """

    /// Select All, Deselect All and Invert act on objects in object mode and
    /// on mesh elements while editing, as Blender's do.
    public static func selectAll(editing: Bool) -> String {
        editing ? selectAllMesh : selectAll
    }
    public static func deselectAll(editing: Bool) -> String {
        editing ? deselectAllMesh : deselectAll
    }
    public static func invertSelection(editing: Bool) -> String {
        editing ? invertMesh : invertSelection
    }

    /// Delete: objects in object mode; while editing, the elements of the
    /// select mode in use — the entry Blender's Delete menu would put first
    /// for that mode.
    public static func deleteSelection(editing: Bool, mode: MeshSelectMode) -> String {
        guard editing else { return deleteSelected }
        return deleteMesh(mode.bpyType)
    }

    /// The Python that puts back the object selection and the active object
    /// the mirror holds — Blender's own, read back after every command and
    /// every tap. For a redo-panel re-run (`BpyBridge.rerunLead`): a tap is
    /// not an undo step, so the step a re-run goes back to has the selection
    /// from before it.
    ///
    /// Left alone while the active object is in Edit Mode, where the object
    /// selection is not what a tap changes. Only what differs is written.
    public static func objectSelection(of scene: BKScene) -> String {
        let names = scene.objects.filter { scene.selection.contains($0.id) }.map(\.name)
        return objectSelection(names, active: scene.active?.name)
    }

    public static func objectSelection(_ selected: [String], active: String?) -> String {
        let names = selected.map { quote($0) }.joined(separator: ", ")
        let target = active.map { "bpy.data.objects.get(\(quote($0)))" } ?? "None"
        return """
        if getattr(bpy.context.view_layer.objects.active, 'mode', 'OBJECT') == 'OBJECT':
            _bk_keep = set([\(names)])
            for _bk_o in bpy.context.view_layer.objects:
                if _bk_o.select_get() != (_bk_o.name in _bk_keep):
                    try:
                        _bk_o.select_set(_bk_o.name in _bk_keep)
                    except RuntimeError:
                        pass
            if bpy.context.view_layer.objects.active != \(target):
                bpy.context.view_layer.objects.active = \(target)
        """
    }

    public static func select(_ name: String, only: Bool = true) -> String {
        var lines: [String] = []
        if only { lines.append(deselectAll) }
        lines.append("bpy.data.objects[\(quote(name))].select_set(True)")
        lines.append("bpy.context.view_layer.objects.active = bpy.data.objects[\(quote(name))]")
        return lines.joined(separator: "\n")
    }

    public static func setLocation(_ name: String, _ v: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[%@].location = (%.4f, %.4f, %.4f)",
               quote(name), v.x, v.y, v.z)
    }

    public static func setRotation(_ name: String, _ v: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[%@].rotation_euler = (%.4f, %.4f, %.4f)",
               quote(name), v.x, v.y, v.z)
    }

    public static func setScale(_ name: String, _ v: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[%@].scale = (%.4f, %.4f, %.4f)",
               quote(name), v.x, v.y, v.z)
    }

    public static func rename(_ name: String, to wanted: String) -> String {
        "bpy.data.objects[\(quote(name))].name = \(quote(wanted))"
    }

    /// The Outliner's eye: Blender's view-layer flag, the one H and Alt+H
    /// change. The eye used to write `hide_viewport`, which H never sets, so
    /// an object hidden with H showed a closed eye that could not open it.
    /// Measured in 5.2.1: `hide_set(True)` also deselects, and a hidden
    /// object refuses `select_set(True)`.
    public static func setHidden(_ name: String, _ hidden: Bool) -> String {
        "bpy.data.objects[\(quote(name))].hide_set(\(hidden ? "True" : "False"))"
    }

    /// Disable in Viewports, Blender's `hide_viewport` — Object Properties'
    /// Show In Viewports, and the Outliner's monitor. Show Hidden Objects does
    /// not undo it (measured: CANCELLED, the object stays off).
    ///
    /// An object in Sculpt Mode or a paint mode is taken out of it first.
    /// Blender will not take a disabled object out of those modes ("Cannot
    /// edit hidden object"), and it stops evaluating it while its sculpt
    /// session still points at the last evaluation. Measured in the app: a
    /// cube on a Multires level, put in Sculpt Mode through F3 and then
    /// disabled here, took the app down on the next mirroring pass, in
    /// `ed.flush_edits` → `multires_flush_sculpt_updates` →
    /// `subdiv::face_ptex_offset_get` with a null Subdiv. Edit Mode is left
    /// alone: Blender keeps editing a hidden object there.
    public static func setDisabledInViewports(_ name: String, _ disabled: Bool) -> String {
        let set = "bpy.data.objects[\(quote(name))].hide_viewport = \(disabled ? "True" : "False")"
        guard disabled else { return set }
        return """
        _bk_o = bpy.data.objects[\(quote(name))]
        if _bk_o.mode not in ('OBJECT', 'EDIT') and bpy.context.view_layer.objects.active == _bk_o:
            bpy.ops.object.mode_set(mode='OBJECT')
        \(set)
        """
    }

    // MARK: show and hide

    /// Object ▸ Show/Hide and edit mode's Mesh ▸ Show/Hide, Blender's
    /// VIEW3D_MT_object_showhide and VIEW3D_MT_edit_mesh_showhide.
    public enum ShowHide: CaseIterable, Sendable {
        case reveal, hideSelected, hideUnselected

        /// Blender's labels: the object menu's first row is the operator's
        /// own name, edit mode's is `mesh.reveal`'s.
        public func label(editing: Bool) -> String {
            switch self {
            case .reveal:         return editing ? "Reveal Hidden" : "Show Hidden Objects"
            case .hideSelected:   return "Hide Selected"
            case .hideUnselected: return "Hide Unselected"
            }
        }

        /// The undo step, named as Blender names it: after the operator, which
        /// for both object-mode hides is "Hide Objects".
        public func undoName(editing: Bool) -> String {
            switch (self, editing) {
            case (.reveal, false): return "Show Hidden Objects"
            case (.reveal, true):  return "Reveal Hidden"
            case (_, false):       return "Hide Objects"
            case (_, true):        return "Hide Selected"
            }
        }
    }

    /// What each row sends. Objects go through `object.hide_view_set` and
    /// `hide_view_clear`, inside the 3D View their poll wants
    /// (`_blenderkit_context.temp_override_view3d`); mesh elements through
    /// `mesh.hide` and `mesh.reveal`, which poll without one.
    ///
    /// Each refuses in words when there is nothing to do. Measured in 5.2.1:
    /// Hide with nothing selected and Show Hidden with nothing hidden both
    /// return CANCELLED and raise nothing, and so does `mesh.hide` with no
    /// element selected. `mesh.reveal` with nothing hidden returns FINISHED,
    /// having done what it was asked.
    public static func showHide(_ what: ShowHide, editing: Bool) -> String {
        let label = what.label(editing: editing)
        if editing {
            switch what {
            case .reveal:
                return "bpy.ops.mesh.reveal(select=True)"
            case .hideSelected, .hideUnselected:
                let unselected = what == .hideUnselected
                let refusal = unselected
                    ? "Hide Unselected: every element is selected, so there is nothing else to hide"
                    : "Hide Selected: select what to hide first"
                return """
                if 'CANCELLED' in bpy.ops.mesh.hide(unselected=\(unselected ? "True" : "False")):
                    raise RuntimeError(\(quote(refusal)))
                """
            }
        }
        let call: String
        let refusal: String
        switch what {
        case .reveal:
            call = "bpy.ops.object.hide_view_clear(select=True)"
            refusal = "Show Hidden Objects: nothing is hidden. An object turned off with "
                + "Disable in Viewports comes back from the Outliner"
        case .hideSelected:
            call = "bpy.ops.object.hide_view_set(unselected=False)"
            refusal = "Hide Selected: select an object to hide first"
        case .hideUnselected:
            call = "bpy.ops.object.hide_view_set(unselected=True)"
            refusal = "Hide Unselected: every object shown is selected"
        }
        return """
        import _blenderkit_context
        with _blenderkit_context.temp_override_view3d(\(quote(label))):
            if 'CANCELLED' in \(call):
                raise RuntimeError(\(quote(refusal)))
        """
    }

    // MARK: separate

    /// Mesh ▸ Separate, Blender's `mesh.separate` enum in its menu's order.
    public enum SeparateType: String, CaseIterable, Sendable {
        case selected = "SELECTED", material = "MATERIAL", loose = "LOOSE"

        /// Blender's enum labels, which its P menu lists.
        public var label: String {
            switch self {
            case .selected: return "Selection"
            case .material: return "By Material"
            case .loose:    return "By Loose Parts"
            }
        }
    }

    /// Splits the mesh being edited into new objects.
    ///
    /// Measured in 5.2.1: the new objects arrive in object mode and selected,
    /// the edited one stays active and in edit mode, and all of them reach the
    /// Outliner through the next mirroring pass like any other object.
    /// Selection with nothing selected raises "Nothing selected" itself; By
    /// Loose Parts on a mesh in one piece and By Material with fewer than two
    /// materials in use return CANCELLED and raise nothing, so those say why.
    public static func separate(_ type: SeparateType) -> String {
        let call = "bpy.ops.mesh.separate(type='\(type.rawValue)')"
        switch type {
        case .selected:
            return call
        case .material:
            return """
            if 'CANCELLED' in \(call):
                raise RuntimeError('Separate by Material: every face has the same material')
            """
        case .loose:
            return """
            if 'CANCELLED' in \(call):
                raise RuntimeError('Separate by Loose Parts: the mesh is all one piece')
            """
        }
    }

    public static func setHideRender(_ name: String, _ hidden: Bool) -> String {
        "bpy.data.objects[\(quote(name))].hide_render = \(hidden ? "True" : "False")"
    }

    // MARK: transforms

    public static func translate(_ delta: SIMD3<Float>, constraint: String? = nil) -> String {
        var call = String(format: "value=(%.4f, %.4f, %.4f)", delta.x, delta.y, delta.z)
        if let constraint { call += ", constraint_axis=\(constraint), orient_type='GLOBAL'" }
        return "bpy.ops.transform.translate(\(call))"
    }

    public static func rotate(_ angle: Float, axis: String) -> String {
        String(format: "bpy.ops.transform.rotate(value=%.4f, orient_axis='%@')", angle, axis)
    }

    public static func resize(_ factors: SIMD3<Float>) -> String {
        String(format: "bpy.ops.transform.resize(value=(%.4f, %.4f, %.4f))",
               factors.x, factors.y, factors.z)
    }

    // MARK: origin and applied transforms

    /// `bpy.ops.object.origin_set`'s five types, with Blender's own names.
    ///
    /// `GEOMETRY_ORIGIN` and `ORIGIN_GEOMETRY` are one word apart and do
    /// opposite things, and `GEOMETRY_ORIGIN` is the RNA default — which is
    /// why `type=` is written out every time rather than left off. Measured in
    /// Blender 5.2.1 on a cube at (1,0,0) with one vertex 30 units out along
    /// X: `GEOMETRY_ORIGIN` left `location` at (1,0,0) and moved the vertices
    /// (the first went to x=-4.333); `ORIGIN_GEOMETRY` moved `location` to
    /// (4.333,0,0) and left the shape on screen where it was.
    public enum Origin: String, CaseIterable, Identifiable, Sendable {
        case geometryToOrigin  = "GEOMETRY_ORIGIN"
        case originToGeometry  = "ORIGIN_GEOMETRY"
        case cursor            = "ORIGIN_CURSOR"
        case centerOfMass      = "ORIGIN_CENTER_OF_MASS"
        case centerOfVolume    = "ORIGIN_CENTER_OF_VOLUME"

        public var id: String { rawValue }

        /// The RNA `name`, read out of Blender 5.2.1 rather than paraphrased,
        /// so someone who knows Blender's menu finds the row they expect.
        public var title: String {
            switch self {
            case .geometryToOrigin: return "Geometry to Origin"
            case .originToGeometry: return "Origin to Geometry"
            case .cursor:           return "Origin to 3D Cursor"
            case .centerOfMass:     return "Origin to Center of Mass (Surface)"
            case .centerOfVolume:   return "Origin to Center of Mass (Volume)"
            }
        }

        /// Whether `center=` changes the result. Measured on the same
        /// stray-vertex mesh: the two geometry types gave x=4.333 for
        /// `MEDIAN` and x=15.5 for `BOUNDS`, while `ORIGIN_CURSOR`,
        /// `ORIGIN_CENTER_OF_MASS` and `ORIGIN_CENTER_OF_VOLUME` gave
        /// identical locations and identical vertex coordinates for both.
        /// Writing an argument into the Info log that provably does nothing is
        /// the opposite of what the log is for.
        public var usesCenter: Bool {
            self == .geometryToOrigin || self == .originToGeometry
        }
    }

    public enum OriginCenter: String, Sendable {
        case median = "MEDIAN"
        case bounds = "BOUNDS"
    }

    /// One row of the Set Origin menu: a type, and the `center` it runs with.
    public struct OriginChoice: Identifiable, Sendable {
        public let type: Origin
        public let center: OriginCenter

        public init(_ type: Origin, _ center: OriginCenter = .median) {
            self.type = type
            self.center = center
        }

        public var id: String { type.rawValue + "|" + center.rawValue }
        public var title: String { center == .bounds ? type.title + " (Bounds)" : type.title }
    }

    /// Blender's `VIEW3D_MT_object_set_origin`, in the RNA's order, plus the
    /// one row Blender does not have: Blender reaches `center='BOUNDS'`
    /// through the redo panel, and these operators deliberately get none here
    /// (see `LastOperator`), so the variant needs a row of its own.
    public static let originMenu: [OriginChoice] = [
        OriginChoice(.geometryToOrigin),
        OriginChoice(.originToGeometry),
        OriginChoice(.originToGeometry, .bounds),
        OriginChoice(.cursor),
        OriginChoice(.centerOfMass),
        OriginChoice(.centerOfVolume),
    ]

    public static func originSet(_ type: Origin, center: OriginCenter = .median) -> String {
        var arguments = "type='\(type.rawValue)'"
        if type.usesCenter { arguments += ", center='\(center.rawValue)'" }
        return "bpy.ops.object.origin_set(\(arguments))"
    }

    /// The rows of Blender's Ctrl+A menu this offers.
    public enum AppliedTransform: String, CaseIterable, Identifiable, Sendable {
        case all, location, rotation, scale

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all:      return "All Transforms"
            case .location: return "Location"
            case .rotation: return "Rotation"
            case .scale:    return "Scale"
            }
        }

        public var channels: (location: Bool, rotation: Bool, scale: Bool) {
            switch self {
            case .all:      return (true, true, true)
            case .location: return (true, false, false)
            case .rotation: return (false, true, false)
            case .scale:    return (false, false, true)
            }
        }

        /// The undo step's name: the operator's own label, which is what
        /// Blender's Undo History shows for every row of this menu. Read out
        /// of 5.2.1 — `transform_apply.get_rna_type().name` is
        /// "Apply Object Transform", whichever channels were baked.
        public var undoName: String { Bpy.applyReach.undoName }
    }

    /// `bpy.ops.object.transform_apply`, with **all three keywords always
    /// written out**.
    ///
    /// `location`, `rotation` and `scale` all default to `True` in the RNA, so
    /// naming only the one wanted bakes everything. Measured in 5.2.1 on a
    /// cube at (1,2,3), rotation (0.3,0,0), scale (1,2,3):
    /// `transform_apply(scale=True)` came back location (0,0,0), rotation
    /// (0,0,0), scale (1,1,1) — the origin dragged to the world centre and the
    /// rotation gone. Spelled out in full it came back location (1,2,3),
    /// rotation (0.3,0,0), scale (1,1,1), which is what Apply Scale means.
    ///
    /// Apply Scale is the one that matters most, because an unapplied
    /// non-uniform scale silently distorts every modifier measured in metres.
    /// Measured: a cube scaled (1,1,4) with a Bevel modifier of width 0.1 had
    /// an evaluated world-space bevel of 0.1 along X and 0.4 along Z (the top
    /// face's ring sat at z=3.6 instead of 3.9). After Apply Scale both read
    /// 0.1 and the ring sat at 3.9.
    ///
    /// The other three properties are left at their defaults on purpose.
    /// `properties` and `corrective_flip_normals` default `True` and changing
    /// either is a behaviour change nobody asked for; `isolate_users` defaults
    /// `False`, and setting it `True` would quietly make single-user copies of
    /// shared mesh data. A shared mesh instead raises a sentence the banner can
    /// show — measured: `Cannot apply to a multi user: Object "Cube.001",
    /// Mesh "Cube", aborting`.
    ///
    /// Not handled, because Blender does not handle it either: applying a
    /// channel that is keyframed bakes the geometry and then has the F-curve
    /// put the old value straight back on the next frame change, doubling the
    /// transform. Blender emits no warning, and the timeline mirror carries
    /// only frame numbers, so nothing here can tell that a channel is keyed.
    public static func applyTransform(location: Bool, rotation: Bool, scale: Bool) -> String {
        func flag(_ on: Bool) -> String { on ? "True" : "False" }
        return "bpy.ops.object.transform_apply(location=\(flag(location)), "
            + "rotation=\(flag(rotation)), scale=\(flag(scale)))"
    }

    public static func applyTransform(_ what: AppliedTransform) -> String {
        let channels = what.channels
        return applyTransform(location: channels.location,
                              rotation: channels.rotation,
                              scale: channels.scale)
    }

    /// Which selected objects an object-level operator acts on at all, and
    /// the refusal it needs when there are none.
    ///
    /// Neither operator raises on a type it cannot handle — it reports to a
    /// status bar this app has none of. Measured in 5.2.1, one object of each
    /// type at (1,2,3) turned 0.3 and scaled 2: `origin_set` on an empty, a
    /// camera, any light, a speaker, a light probe or a volume returned
    /// `{'FINISHED'}` and left `location` where it was; `transform_apply` on a
    /// camera, a point, sun or spot light, a speaker, a light probe or a volume
    /// returned `{'CANCELLED'}` and changed nothing; both return `{'CANCELLED'}`
    /// with nothing selected. Without a refusal `bridge.run` would report
    /// success and push an undo step for nothing.
    ///
    /// Everything else was measured to be acted on: meshes, curves, surfaces,
    /// text, metaballs, armatures, lattices, hair curves, point clouds and
    /// Grease Pencil, by both operators. So was an area light by
    /// `transform_apply`, which bakes the scale into its size (scale 2 made
    /// size 1 into 2) — which is why the rule reads a light's kind and not
    /// only its type: a type list cannot say "lights, except area lights".
    ///
    /// What these operators refuse *in words* is left to them. Text can only
    /// have its scale applied and so can an area light; both raise that
    /// sentence, naming the object, for Apply All, Location or Rotation, and a
    /// mixed selection is refused whole (measured: a scaled cube beside a text
    /// object kept its scale). The banner shows Blender's sentence, which is
    /// more exact than any greyed row could be.
    public struct ObjectReach: Sendable {
        /// What the menus call the operator, for the refusal.
        public let name: String
        /// The operator's own label — the undo step's name.
        public let undoName: String
        /// The types it does nothing to, in the order the refusal lists them.
        public let ignoredTypes: [String]
        /// The light kinds it does act on, although `LIGHT` is ignored.
        public let lightKinds: Set<String>
        /// Whether an empty that instances a collection is acted on, although
        /// `EMPTY` is ignored — the same kind of exception as an area light,
        /// and one a type list cannot say either.
        public var collectionInstances = false

        /// Whether the operator acts on an object of this type. A light whose
        /// kind is not known, or an empty not known to instance a collection
        /// or not, is counted as acted on: the menu may not grey a row out on
        /// a guess, and the guard below reads the real object.
        public func acts(onType type: String, lightKind: String?, instancesCollection: Bool?) -> Bool {
            if !ignoredTypes.contains(type) { return true }
            if type == "EMPTY", collectionInstances { return instancesCollection ?? true }
            guard type == "LIGHT", !lightKinds.isEmpty else { return false }
            return lightKind.map(lightKinds.contains) ?? true
        }

        /// The refusal, run through `run(_:undo:setup:)`'s `setup:` and never
        /// concatenated onto the operator: `BpyModeGuard.requiredMode` only
        /// brackets a string whose *first* line begins with `bpy.ops.`, so
        /// putting this in front would silently drop the OBJECT-mode bracket
        /// both operators need — measured, `origin_set` from edit mode raises
        /// `Operation cannot be performed in edit mode` and `transform_apply`
        /// fails its poll.
        ///
        /// It names what is selected, as Blender's own refusals name the
        /// object ("Text objects can only have their scale applied: "Text"").
        public var guardPython: String {
            let types = ignoredTypes.map { "'\($0)'" }.joined(separator: ", ")
            // `{}` would be a dict; membership still works, but say what is meant.
            let kinds = lightKinds.isEmpty ? "set()"
                : "{" + lightKinds.sorted().map { "'\($0)'" }.joined(separator: ", ") + "}"
            let what = Bpy.quote(name)
            let refusal = Bpy.quote(name + " does nothing to " + refusedNouns + ": ")
            // getattr: the simulator's shim has no instancing to read.
            let instances = !collectionInstances ? "" : """

                    or (_bk_o.type == 'EMPTY' and getattr(_bk_o, 'instance_type', 'NONE') == 'COLLECTION'
                        and getattr(_bk_o, 'instance_collection', None) is not None)
            """
            return """
            _bk_skip = {\(types)}
            _bk_kinds = \(kinds)
            _bk_sel = list(bpy.context.selected_objects)
            if not _bk_sel:
                raise RuntimeError(\(what) + " needs a selected object.")
            if not [_bk_o for _bk_o in _bk_sel if _bk_o.type not in _bk_skip
                    or (_bk_o.type == 'LIGHT' and _bk_o.data.type in _bk_kinds)\(instances)]:
                raise RuntimeError(\(refusal) + ", ".join('"%s"' % _bk_o.name for _bk_o in _bk_sel[:3])
                                   + (" and %d more" % (len(_bk_sel) - 3) if len(_bk_sel) > 3 else ""))
            """
        }

        /// "empties, cameras, lights, …" — every ignored type, in words, with
        /// a light narrowed to the kinds that are ignored.
        var refusedNouns: String {
            let nouns = ignoredTypes.map { type -> String in
                if type == "LIGHT", !lightKinds.isEmpty {
                    let ignored = LightDisplay.Kind.allCases.map(\.rawValue)
                        .filter { !lightKinds.contains($0) }.map { $0.lowercased() }
                    return Self.list(ignored, "and") + " lights"
                }
                if type == "EMPTY", collectionInstances {
                    return "empties that instance no collection"
                }
                return Self.plural[type] ?? type.lowercased()
            }
            return Self.list(nouns, "or")
        }

        private static let plural: [String: String] = [
            "EMPTY": "empties", "CAMERA": "cameras", "LIGHT": "lights", "SPEAKER": "speakers",
            "LIGHT_PROBE": "light probes", "VOLUME": "volumes",
        ]

        private static func list(_ words: [String], _ conjunction: String) -> String {
            guard words.count > 1 else { return words.first ?? "" }
            return words.dropLast().joined(separator: ", ") + " " + conjunction + " " + words.last!
        }
    }

    /// `origin_set`: no light of any kind, and no empty but one that
    /// instances a collection. That one it moves (measured in 5.2.1: an empty
    /// at (1,2,3) instancing a one-triangle collection went to the cursor
    /// under ORIGIN_CURSOR and to (4, 5.5, 3) under ORIGIN_GEOMETRY, the
    /// collection's instance offset following; Geometry to Origin moved the
    /// offset alone) — provided there is a collection: `instance_type`
    /// COLLECTION with none set, or a collection under `instance_type` NONE,
    /// stayed where it was under all six rows.
    public static let originReach = ObjectReach(
        name: "Set Origin", undoName: "Set Origin",
        ignoredTypes: ["EMPTY", "CAMERA", "LIGHT", "SPEAKER", "LIGHT_PROBE", "VOLUME"],
        lightKinds: [], collectionInstances: true)

    /// `transform_apply`: an empty *is* acted on, baking the scale into
    /// `empty_display_size` (measured: scale (1,2,3) made display size 1 into
    /// 3, the largest factor), and so is an area light.
    public static let applyReach = ObjectReach(
        name: "Apply Transform", undoName: "Apply Object Transform",
        ignoredTypes: ["CAMERA", "LIGHT", "SPEAKER", "LIGHT_PROBE", "VOLUME"],
        lightKinds: ["AREA"])

    // MARK: mesh editing — every one of these is Blender's own operator

    public static let extrudeRegion = "bpy.ops.mesh.extrude_region_move()"
    public static let extrudeIndividual = "bpy.ops.mesh.extrude_faces_move()"
    public static func inset(_ thickness: Float) -> String {
        String(format: "bpy.ops.mesh.inset(thickness=%.4f)", thickness)
    }
    public static func bevel(_ offset: Float, segments: Int) -> String {
        String(format: "bpy.ops.mesh.bevel(offset=%.4f, segments=%d)", offset, segments)
    }
    public static func subdivide(_ cuts: Int) -> String {
        "bpy.ops.mesh.subdivide(number_cuts=\(cuts))"
    }
    public static let poke = "bpy.ops.mesh.poke()"
    public static let triangulate = "bpy.ops.mesh.quads_convert_to_tris()"
    public static let trisToQuads = "bpy.ops.mesh.tris_convert_to_quads()"
    public static let flipNormals = "bpy.ops.mesh.flip_normals()"
    public static let recalcNormals = "bpy.ops.mesh.normals_make_consistent(inside=False)"
    public static func mergeByDistance(_ threshold: Float) -> String {
        String(format: "bpy.ops.mesh.remove_doubles(threshold=%.5f)", threshold)
    }
    public static func deleteMesh(_ type: String) -> String {
        "bpy.ops.mesh.delete(type='\(type)')"
    }
    public static let selectAllMesh = "bpy.ops.mesh.select_all(action='SELECT')"
    public static let deselectAllMesh = "bpy.ops.mesh.select_all(action='DESELECT')"
    public static let invertMesh = "bpy.ops.mesh.select_all(action='INVERT')"
    public static let selectLinked = "bpy.ops.mesh.select_linked()"
    public static let selectMore = "bpy.ops.mesh.select_more()"
    public static let selectLess = "bpy.ops.mesh.select_less()"

    /// `bpy.ops.mesh.select_mode`, which takes VERT, EDGE or FACE — it used to
    /// be sent `VERTEX`, which Blender rejects.
    public static func meshSelectMode(_ mode: MeshSelectMode) -> String {
        "bpy.ops.mesh.select_mode(type='\(mode.bpyType)')"
    }

    /// The vertex / edge / face buttons in Blender's edit-mode header set this
    /// property; it needs no poll, so it works from any mode.
    public static func setSelectMode(_ mode: MeshSelectMode) -> String {
        "bpy.context.scene.tool_settings.mesh_select_mode = \(mode.blenderFlags)"
    }

    // MARK: shading and material

    /// `bpy.ops.object.shade_smooth()` / `shade_flat()`.
    ///
    /// Blender puts these on the Object menu and on the right-click menu, and
    /// they are the difference between a subdivided sphere that reads as a
    /// shape and one that reads as facets. They operate on the selection and
    /// need no window, so they work from the same place every other object
    /// operator here does.
    public static let shadeSmooth = "bpy.ops.object.shade_smooth()"
    public static let shadeFlat   = "bpy.ops.object.shade_flat()"

    /// Give the object a material of its own and set what it shades with.
    ///
    /// `object.color` — which is what the Material tab used to set — is a
    /// viewport display property. Cycles does not read it unless the material
    /// asks for it through an Object Info node, so a coloured scene rendered
    /// entirely grey. This writes the Principled BSDF's Base Color, Metallic
    /// and Roughness, which every renderer reads.
    ///
    /// The material is per object and named after it, because a material made
    /// by `new()` is shared the moment a second object is given the same one,
    /// and colouring one part would then colour every part made from the same
    /// primitive.
    public static func setMaterial(_ name: String, baseColor: SIMD4<Float>,
                                   metallic: Float, roughness: Float) -> String {
        let material = "\(name) Material"
        return """
        _o = bpy.data.objects[\(quote(name))]
        _m = bpy.data.materials.get(\(quote(material))) or bpy.data.materials.new(\(quote(material)))
        _m.use_nodes = True
        _b = _m.node_tree.nodes.get("Principled BSDF")
        if _b is not None:
            _b.inputs["Base Color"].default_value = \(baseColorTuple(baseColor))
            _b.inputs["Metallic"].default_value = \(String(format: "%.3f", metallic))
            _b.inputs["Roughness"].default_value = \(String(format: "%.3f", roughness))
        _m.diffuse_color = \(baseColorTuple(baseColor))
        if _o.data.materials:
            _o.data.materials[0] = _m
        else:
            _o.data.materials.append(_m)
        _o.color = \(baseColorTuple(baseColor))
        """
    }

    /// sRGB in, linear out.
    ///
    /// The colour picker hands back sRGB components — that is what a hex like
    /// `4E6B3A` means — and every colour Blender shades with is linear. Writing
    /// the sRGB number straight into Base Color makes everything render lighter
    /// and flatter than the colour that was picked: 0x4E is 0.306 as sRGB and
    /// 0.074 as linear, which is more than a factor of four of green.
    private static func baseColorTuple(_ c: SIMD4<Float>) -> String {
        String(format: "(%.4f, %.4f, %.4f, 1.0)",
               linear(c.x), linear(c.y), linear(c.z))
    }

    /// The sRGB transfer function, inverted — the same curve Blender's own
    /// `srgb_to_linearrgb` uses, so a hex typed here and the same hex typed
    /// into Blender give the same render.
    private static func linear(_ s: Float) -> Float {
        s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    // MARK: modifiers

    public static func addModifier(_ type: String) -> String {
        "bpy.ops.object.modifier_add(type='\(type)')"
    }

    /// What Add Modifier sends for `kind` on an object showing `mesh`.
    ///
    /// A Remesh arrives in VOXEL mode at 0.1, whatever the object's size, and
    /// evaluates at once: a 100 m cube would be about 6 million vertices, and
    /// past about 130 m the mirror's 10,000,000-vertex limit. So on an object
    /// large enough for 0.1 to be under the row's own floor
    /// (`ModifierStack.remeshVoxelFloor`), the floor is set in the same
    /// evaluation — `modifiers.active` is the one just added, measured even
    /// ahead of a modifier pinned to last.
    public static func addModifier(_ kind: ModifierKind, on mesh: MeshData) -> [String] {
        var lines = [addModifier(kind.bpyType)]
        if kind == .remesh {
            let floor = ModifierStack.remeshVoxelFloor(for: mesh)
            if floor > Modifier(kind: .remesh).voxelSize {
                lines.append(String(format: "bpy.context.object.modifiers.active.voxel_size = %.6f",
                                    floor))
            }
        }
        return lines
    }
    /// Apply, on any row. A bare call, so `BpyModeGuard` runs it in object
    /// mode (measured in 5.2.1: from edit mode its poll refuses with "This
    /// modifier operation is not allowed from Edit mode"). Every refusal
    /// Blender has for it raises — "Modifier is disabled, skipping apply" for
    /// a Lattice with no lattice, "Multires modifier returned error, skipping
    /// apply" under a Multires — so nothing here needs to add one.
    public static func applyModifier(_ name: String) -> String {
        "bpy.ops.object.modifier_apply(modifier=\(quote(name)))"
    }

    /// Move Up / Move Down on any row.
    ///
    /// Blender refuses some moves by returning CANCELLED with a warning a
    /// bpy module never shows (measured in 5.2.1): "Cannot move above a
    /// modifier requiring original data" (anything but a pure deform above a
    /// Multires or a Soft Body), "Cannot move beyond a non-deforming
    /// modifier" (either of those below one that makes geometry), and past
    /// either end of the stack. Multires and Soft Body are the two types that
    /// carry `eModifierTypeFlag_RequiresOriginalData` in Blender's source; the
    /// refusal names both, because a Subdivision under a Soft Body is refused
    /// with no Multires in the stack (round 3's review). The app would report
    /// success and the row would not move, so the refusal is raised in words.
    /// Not a bare call: the move works in any mode, and the mode guard would
    /// take edit mode down and up for nothing.
    public static func moveModifier(_ name: String, up: Bool) -> String {
        let direction = up ? "up" : "down"
        let rule = up
            ? "A modifier that is not a pure deform cannot move above a Multiresolution or a Soft Body, "
            : "A Multiresolution or a Soft Body cannot move below a modifier that is not a pure deform, "
        let refusal = "Move \(up ? "Up" : "Down"): Blender keeps \"\(name)\" where it is. "
            + rule + "and nothing moves past either end of the stack"
        return """
        if 'CANCELLED' in bpy.ops.object.modifier_move_\(direction)(modifier=\(quote(name))):
            raise RuntimeError(\(quote(refusal)))
        """
    }

    /// Multiresolution's four operators, as its panel in Blender offers them.
    public enum MultiresOperation: String, CaseIterable, Sendable {
        case subdivide, unsubdivide, deleteHigher, applyBase

        /// The button's label, and the undo step's, as Blender names them.
        public var label: String {
            switch self {
            case .subdivide:    return "Subdivide"
            case .unsubdivide:  return "Unsubdivide"
            case .deleteHigher: return "Delete Higher"
            case .applyBase:    return "Apply Base"
            }
        }
    }

    /// One of Multires's operators on the modifier `name` of the active object,
    /// through `_blenderkit_multires.run`, which takes the object to Object
    /// Mode and back, and refuses in words when it cannot.
    ///
    /// Not a bare operator any more, and not left to `BpyModeGuard`. The guard
    /// swallows a `mode_set` Blender refuses: an object in Sculpt Mode with
    /// Disable in Viewports on stays in Sculpt Mode ("Cannot edit hidden
    /// object"), and the operator then ran there. Measured in desktop 5.2.1:
    /// Apply Base in Sculpt Mode pushes a sculpt undo step, and with no undo
    /// stack (after a file load, or under the checkpoint history) that
    /// segfaults in `sculpt_paint::undo::push_begin_ex`; in Edit Mode Apply
    /// Base segfaults in `multires_reshape_create_subdiv`. In Object Mode all
    /// four run with or without an undo stack. The module checks the mode it
    /// reached before anything runs, keeps Blender's own Sculpt Mode meaning
    /// for the levels, and refuses a Subdivide whose new level would pass its
    /// vertex budget (each press multiplies the geometry by four; a cube's
    /// tenth is 6,291,458 vertices and 1.65 GB over the scene). The module has the
    /// measurements.
    ///
    /// Unsubdivide on a mesh that is not a subdivided grid raises "No valid
    /// subdivisions found to rebuild a lower level" itself, and each press
    /// rebuilds one level (a cube subdivided twice, 98 vertices: 26 and one
    /// level, then the 8-vertex cube and two). Delete Higher removes the
    /// levels above the one Blender shows — the viewport level, or the sculpt
    /// level in Sculpt Mode — and Apply Base reshapes the base mesh toward the
    /// subdivided one (a 2 m cube at one level: corners from 1.0 to 0.944).
    public static func multires(_ op: MultiresOperation, _ name: String) -> String {
        "import _blenderkit_multires\n_blenderkit_multires.run(\(quote(op.rawValue)), \(quote(name)))"
    }
    public static func removeModifier(_ name: String) -> String {
        "bpy.ops.object.modifier_remove(modifier=\(quote(name)))"
    }
    /// The data path the Every Property browser opens a modifier row at —
    /// how a kind with no settings rows here gets its settings changed. The
    /// browser's `resolve` takes a quoted name in brackets, whatever the name
    /// holds (the modifier check opens one named `a;b|c=d%e`).
    public static func modifierDataPath(_ modifier: String) -> String {
        "bpy.context.object.modifiers[\(quote(modifier))]"
    }
    public static func setModifierProperty(_ modifier: String, _ key: String,
                                           _ value: String) -> String {
        "bpy.context.object.modifiers[\(quote(modifier))].\(key) = \(value)"
    }

    /// Refuses, before the line after it sets anything, a Subdivision level or
    /// Array count whose mesh would pass the app's vertex budget or the memory
    /// left (`_blenderkit_multires.check_setting`). The simulator's stand-in
    /// has no budget to keep, and the call returns there.
    public static func checkModifierSetting(_ modifier: String, _ key: String,
                                            _ value: String) -> String {
        "__import__('_blenderkit_multires').check_setting(\(quote(modifier)), \(quote(key)), \(value))"
    }

    /// Every setting a modifier row can change, as Blender's own property
    /// names, one line per setting. A row sends only the lines that differ
    /// (`modifierEdit`); this is the whole list, so there is one place to be
    /// right about what each setting is called.
    ///
    /// The rows used to write to the display cache and log a comment, so on
    /// the real backend a Subdivision stayed at level 1 and an Array at two
    /// copies however the panel was set — the same defect the Transform fields
    /// and the Material tab had, in a third place.
    public static func modifierSettings(_ m: Modifier) -> [String] {
        let name = m.name
        func set(_ key: String, _ value: String) -> String {
            setModifierProperty(name, key, value)
        }
        func f(_ v: Float) -> String { String(format: "%.4f", v) }
        func py(_ b: Bool) -> String { b ? "True" : "False" }
        switch m.kind {
        case .subdivision:
            // Blender keeps viewport and render levels apart; a level set in
            // the panel that a render ignores is a trap. The check rides first
            // and changes with the level, so `modifierEdit` sends it with
            // every new level: the stepper had no size check, and each level
            // is four times the mesh (round 3's review).
            return [checkModifierSetting(name, "levels", "\(m.levels)"),
                    set("levels", "\(m.levels)"), set("render_levels", "\(m.levels)")]
        case .array:
            return [checkModifierSetting(name, "count", "\(m.count)"),
                    set("count", "\(m.count)"),
                    set("relative_offset_displace",
                        "(\(f(m.relativeOffset.x)), \(f(m.relativeOffset.y)), \(f(m.relativeOffset.z)))")]
        case .mirror:
            // One assignment of all three (Blender takes the tuple, measured),
            // which the simulator's modifiers can take too: they have no
            // `use_axis` to index into. Bisect and Flip are the same kind of
            // triple (`use_bisect_axis = (True, False, False)` measured
            // accepted in 5.2.1).
            //
            // The merge distance goes at six places, Blender's own precision
            // for it: four would send 0.00005 as 0.0001, and the distance is
            // also how close to the plane Clipping pins a vertex.
            return [set("use_axis", "(\(py(m.mirrorX)), \(py(m.mirrorY)), \(py(m.mirrorZ)))"),
                    set("use_bisect_axis",
                        "(\(py(m.bisectX)), \(py(m.bisectY)), \(py(m.bisectZ)))"),
                    set("use_bisect_flip_axis",
                        "(\(py(m.bisectFlipX)), \(py(m.bisectFlipY)), \(py(m.bisectFlipZ)))"),
                    set("use_clip", py(m.mirrorClip)),
                    set("use_mirror_merge", py(m.mirrorMerge)),
                    set("merge_threshold", String(format: "%.6f", m.mergeThreshold))]
        case .solidify:  return [set("thickness", f(m.thickness))]
        case .smooth:    return [set("factor", f(m.factor)), set("iterations", "\(m.iterations)")]
        case .cast:      return [set("factor", f(m.factor))]
        case .simpleDeform:
            return [set("deform_method", quote(m.deformMode.bpyValue)),
                    set("angle", f(m.angle)),
                    set("deform_axis", quote(["X", "Y", "Z"][min(max(m.axis, 0), 2)]))]
        case .displace:  return [set("strength", f(m.thickness))]
        case .wave:
            return [set("height", f(m.thickness)),
                    set("use_x", py(m.waveX)), set("use_y", py(m.waveY))]
        case .bevel:     return [set("width", f(m.thickness)), set("segments", "\(m.segments)")]
        case .boolean:
            var lines = [set("operation", quote(m.booleanOperation.bpyValue))]
            if !m.targetName.isEmpty {
                lines.append(set("object", "bpy.data.objects[\(quote(m.targetName))]"))
            }
            return lines
        case .shrinkwrap:
            var lines = [set("wrap_method", quote(m.wrapMethod.bpyValue)),
                         set("offset", f(m.thickness))]
            if !m.targetName.isEmpty {
                // `target`, not `object`. Measured: `ShrinkwrapModifier.object`
                // does not exist and assigning it raises AttributeError, which
                // would take the rest of this batch down with it. Last in the
                // list for the same reason Boolean's pointer is: a backend
                // that cannot take an object pointer has already had the
                // settings above it by the time this line fails.
                lines.append(set("target", "bpy.data.objects[\(quote(m.targetName))]"))
            }
            return lines
        case .screw:
            // render_steps alongside steps, the same split Subdivision has:
            // a viewport value a render would otherwise ignore.
            return [set("angle", f(m.angle)),
                    set("steps", "\(m.count)"),
                    set("render_steps", "\(m.count)"),
                    set("screw_offset", f(m.thickness)),
                    set("axis", quote(["X", "Y", "Z"][min(max(m.axis, 0), 2)]))]
        case .decimate:
            // The type as the modifier holds it. The row's Ratio edit switches
            // it to COLLAPSE, since `ratio` is inert in UNSUBDIV and DISSOLVE,
            // and so that change is one of the lines an edit sends.
            return [set("decimate_type", quote(m.decimateType)), set("ratio", f(m.ratio))]
        case .remesh:
            return [set("mode", quote(m.remeshMode.bpyValue)),
                    // Six places, not four: the floor for a 2 m object is
                    // 0.0078125, which "%.4f" sends as 0.0078, 0.2% finer
                    // than the floor; six places are within 0.01% of it.
                    set("voxel_size", String(format: "%.6f", m.voxelSize)),
                    set("octree_depth", "\(m.octreeDepth)")]
        case .geometryNodes:
            // Smooth by Angle's two inputs, through the mirror's own helper:
            // 5.2.1 keeps them at `properties.inputs.<id>.value`, refuses the
            // `modifier["Input_1"]` older scripts use, and re-evaluates
            // nothing until `update_tag()` (all three measured). Any other
            // group's inputs are not known here, so nothing is sent for them.
            guard m.smoothByAngle else { return [] }
            func input(_ label: String, _ value: String) -> String {
                "__import__('_blenderkit_sync').set_node_input(bpy.context.object, "
                    + "\(quote(name)), \(quote(label)), \(value))"
            }
            return [input("Angle", f(m.angle)), input("Ignore Sharpness", py(m.ignoreSharpness))]
        case .weightedNormal:
            // `weight` is an integer from 1 to 100 in RNA; `thresh` at four
            // places, Blender's own display precision being two.
            return [set("mode", quote(m.weightMode.bpyValue)),
                    set("weight", "\(m.weight)"),
                    set("thresh", f(m.threshold)),
                    set("keep_sharp", py(m.keepSharp)),
                    set("use_face_influence", py(m.faceInfluence))]
        case .multires:
            // The three levels. `total_levels` is read-only; the Subdivide,
            // Unsubdivide and Delete Higher operators change it
            // (`Bpy.multires`).
            return [set("levels", "\(m.levels)"),
                    set("sculpt_levels", "\(m.sculptLevels)"),
                    set("render_levels", "\(m.renderLevels)")]
        case .edgeSplit:
            return [set("split_angle", f(m.angle)),
                    set("use_edge_angle", py(m.edgeSplitAngle)),
                    set("use_edge_sharp", py(m.edgeSplitSharp))]
        case .laplacianSmooth:
            return [set("iterations", "\(m.iterations)"),
                    set("lambda_factor", f(m.lambdaFactor)),
                    set("lambda_border", f(m.lambdaBorder)),
                    set("use_x", py(m.smoothX)), set("use_y", py(m.smoothY)),
                    set("use_z", py(m.smoothZ)),
                    set("use_volume_preserve", py(m.preserveVolume)),
                    set("use_normalized", py(m.normalized))]
        case .correctiveSmooth:
            return [set("factor", f(m.factor)),
                    set("iterations", "\(m.iterations)"),
                    set("scale", f(m.smoothScale)),
                    set("smooth_type", quote(m.smoothType.bpyValue)),
                    set("use_only_smooth", py(m.onlySmooth)),
                    set("use_pin_boundary", py(m.pinBoundary))]
        case .lattice:
            // The pointer last, as Boolean's is: a backend that cannot take
            // it has had the strength by the time the line fails.
            // None when nothing is picked, so the picker's None reaches
            // Blender: without it a wrong lattice could be replaced but never
            // cleared (round 3's review). An edit of the strength alone sends
            // nothing more, since both sides of `modifierEdit` carry it.
            return [set("strength", f(m.thickness)),
                    set("object", m.targetName.isEmpty
                        ? "None" : "bpy.data.objects[\(quote(m.targetName))]")]
        case .weld, .triangulate, .other:
            // Nothing the row can change beyond the two switches every row
            // has (`modifierVisibility`).
            return []
        }
    }

    /// The two switches every modifier row has, whatever its kind: Blender's
    /// `show_viewport` and `show_render`.
    public static func modifierVisibility(_ m: Modifier) -> [String] {
        func py(_ b: Bool) -> String { b ? "True" : "False" }
        return [setModifierProperty(m.name, "show_viewport", py(m.showInViewport)),
                setModifierProperty(m.name, "show_render", py(m.showInRender))]
    }

    /// What a modifier row sends to change `current` — the modifier as the
    /// mirror last reported it — into `changed`: the settings that differ,
    /// and nothing else.
    ///
    /// The whole set used to go with every edit, after the row had already
    /// written the new value into the display cache. So a rejected edit went
    /// on showing the rejected value, and one setting Blender refused poisoned
    /// every later edit of the others: a Shrinkwrap whose target had been
    /// deleted resent `target = bpy.data.objects["…"]` with each Offset change
    /// and failed each time on the KeyError. Now the row writes nothing
    /// itself — what it shows is what the mirror brings back — and an edit
    /// carries only its own change. An empty list means nothing changed.
    public static func modifierEdit(from current: Modifier, to changed: Modifier) -> [String] {
        let before = Set(modifierVisibility(current) + modifierSettings(current)
                         + modifierVertexGroup(current))
        return (modifierVisibility(changed) + modifierSettings(changed) + modifierVertexGroup(changed))
            .filter { !before.contains($0) }
    }

    /// The Vertex Group field and its Invert, for the kinds that take one
    /// (`ModifierKind.takesVertexGroup`). Apart from `modifierSettings`
    /// because only the real backend has vertex groups: the simulator's
    /// stand-in has none, its rows do not offer the field, and the settings
    /// it is checked against (run-modifier-shim-tests.sh) stay the ones it
    /// takes. Blender clears a name that is not a group of the object
    /// (measured), so a stale name comes back as "" rather than failing.
    public static func modifierVertexGroup(_ m: Modifier) -> [String] {
        guard m.kind.takesVertexGroup else { return [] }
        return [setModifierProperty(m.name, "vertex_group", quote(m.vertexGroup)),
                setModifierProperty(m.name, "invert_vertex_group", m.invertVertexGroup ? "True" : "False")]
    }

    /// Tell Blender which vertices are selected, by where they are.
    ///
    /// The fallback for a mesh whose vertices the viewport cannot name by
    /// index — one drawn through a modifier that changes its topology.
    ///
    /// The tolerance is 1e-4 of a Blender unit: a tenth of a millimetre at
    /// Blender's default scale, far below anything two distinct vertices of the
    /// same mesh would be apart, and far above the error of a round trip
    /// through a float.
    public static func selectVertices(of object: String,
                                      at positions: [SIMD3<Float>]) -> String {
        let points = positions.map {
            String(format: "(%.6f, %.6f, %.6f)", $0.x, $0.y, $0.z)
        }.joined(separator: ", ")
        return """
        import bmesh
        from mathutils import Vector
        _o = bpy.data.objects[\(quote(object))]
        bpy.context.view_layer.objects.active = _o
        if _o.mode != 'EDIT':
            bpy.ops.object.mode_set(mode='EDIT')
        _bm = bmesh.from_edit_mesh(_o.data)
        _bm.verts.ensure_lookup_table()
        for _v in _bm.verts:
            _v.select = False
        for _v in _bm.verts:
            for _p in [\(points)]:
                if (_v.co - Vector(_p)).length < 1e-4:
                    _v.select = True
                    break
        _bm.select_flush(True)
        bmesh.update_edit_mesh(_o.data)
        """
    }

    /// The viewport's edit selection, handed to Blender.
    ///
    /// By index when the viewport's mesh is Blender's mesh — the mirror says
    /// so by recording the object's `editTopology` — and by position when it
    /// is not. Faces go over as Blender's polygons, not the viewport's
    /// triangles: a quad is two triangles here and one face there, and a
    /// face selected by three of its four corners is not selected at all.
    public static func pushEditSelection(_ selection: EditSelection, mode: MeshSelectMode,
                                         of object: BKObject) -> String {
        let mesh = object.mesh
        guard let topology = object.editTopology,
              topology.vertexCount == mesh.vertices.count,
              topology.trianglePolygons.count * 3 == mesh.indices.count
        else {
            let points = selection.vertices.sorted()
                .filter { $0 < mesh.vertices.count }
                .map { mesh.vertices[$0].position }
            return selectVertices(of: object.name, at: points)
        }
        switch mode {
        case .vertex:
            return pushEditSelection(object: object.name, mode: .vertex,
                                     vertices: selection.vertices.sorted()
                                        .filter { $0 < topology.vertexCount },
                                     vertexCount: topology.vertexCount,
                                     polygonCount: topology.polygonCount)
        case .edge:
            let pairs = selection.edges.sorted().compactMap { e -> (Int, Int)? in
                let base = e * 2
                guard base + 1 < mesh.edges.count else { return nil }
                return (Int(mesh.edges[base]), Int(mesh.edges[base + 1]))
            }
            return pushEditSelection(object: object.name, mode: .edge, edges: pairs,
                                     vertexCount: topology.vertexCount,
                                     polygonCount: topology.polygonCount)
        case .face:
            let polygons = Set(selection.faces.compactMap { f -> Int? in
                f < topology.trianglePolygons.count ? Int(topology.trianglePolygons[f]) : nil
            }).sorted()
            return pushEditSelection(object: object.name, mode: .face, polygons: polygons,
                                     vertexCount: topology.vertexCount,
                                     polygonCount: topology.polygonCount)
        }
    }

    /// The same, from Blender's own indices.
    ///
    /// The counts are the mesh the indices were read from. If Blender's mesh no
    /// longer has them, the indices name other elements, and acting on those
    /// would be worse than refusing — so it refuses, with a message.
    public static func pushEditSelection(object name: String, mode: MeshSelectMode,
                                         vertices: [Int] = [], edges: [(Int, Int)] = [],
                                         polygons: [Int] = [],
                                         vertexCount: Int, polygonCount: Int) -> String {
        var lines = [
            "import bmesh",
            "_bk_o = bpy.data.objects[\(quote(name))]",
            "if _bk_o.mode != 'EDIT':",
            "    bpy.context.view_layer.objects.active = _bk_o",
            "    bpy.ops.object.mode_set(mode='EDIT')",
            setSelectMode(mode),
            "_bk_bm = bmesh.from_edit_mesh(_bk_o.data)",
            "_bk_bm.verts.ensure_lookup_table()",
            "_bk_bm.edges.ensure_lookup_table()",
            "_bk_bm.faces.ensure_lookup_table()",
            "if len(_bk_bm.verts) != \(vertexCount) or len(_bk_bm.faces) != \(polygonCount):",
            "    raise RuntimeError(\"The mesh changed after the viewport last drew it. Select again.\")",
            "for _bk_seq in (_bk_bm.faces, _bk_bm.edges, _bk_bm.verts):",
            "    for _bk_e in _bk_seq:",
            "        _bk_e.select = False",
        ]
        let verts = vertices.filter { $0 >= 0 && $0 < vertexCount }
        if vertexCount > 0 && Set(verts).count == vertexCount {
            lines += ["for _bk_v in _bk_bm.verts:", "    _bk_v.select = True"]
        } else if !verts.isEmpty {
            lines += ["for _bk_i in [\(verts.map(String.init).joined(separator: ", "))]:",
                      "    _bk_bm.verts[_bk_i].select = True"]
        }
        let pairs = edges.filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 < vertexCount && $0.1 < vertexCount }
        if !pairs.isEmpty {
            lines += ["for _bk_a, _bk_b in [\(pairs.map { "(\($0.0), \($0.1))" }.joined(separator: ", "))]:",
                      "    _bk_e = _bk_bm.edges.get((_bk_bm.verts[_bk_a], _bk_bm.verts[_bk_b]))",
                      "    if _bk_e is not None:",
                      "        _bk_e.select_set(True)"]
        }
        let faces = polygons.filter { $0 >= 0 && $0 < polygonCount }
        if polygonCount > 0 && Set(faces).count == polygonCount {
            lines += ["for _bk_f in _bk_bm.faces:", "    _bk_f.select_set(True)"]
        } else if !faces.isEmpty {
            lines += ["for _bk_i in [\(faces.map(String.init).joined(separator: ", "))]:",
                      "    _bk_bm.faces[_bk_i].select_set(True)"]
        }
        lines += ["_bk_bm.select_flush_mode()", "bmesh.update_edit_mesh(_bk_o.data)"]
        return lines.joined(separator: "\n")
    }

    // MARK: sculpting

    /// Writes a sculpt stroke into Blender's mesh.
    ///
    /// No longer sent by Sculpt Mode, whose strokes are Blender's own brushes
    /// now (`SculptBpy`, `BpyBridge.sculptBegin`); kept for scripts' sake and
    /// held to Blender by run-3dview-blender-check.sh.
    ///
    /// The stroke was painted onto the display cache, which is what the
    /// viewport shows and what the next mirroring pass overwrites with
    /// Blender's mesh — so without this every stroke vanished at the next tap.
    ///
    /// The positions come from the display cache through `mesh_arrays`, so no
    /// vertex data travels as source text. Without modifiers they are the mesh
    /// and are written as they are. Through a deforming modifier the viewport
    /// shows the deformed mesh, so what is written is the stroke's movement —
    /// shown minus what Blender evaluated before it — added to the base. A
    /// modifier that changes the vertex count leaves nothing to line the two
    /// up by, and that is refused with a message rather than guessed.
    public static func writeSculpt(of name: String) -> String {
        let quoted = quote(name)
        return """
        from array import array as _bk_array
        import _blenderkit
        _bk_o = bpy.data.objects[\(quoted)]
        if _bk_o.mode == 'EDIT':
            raise RuntimeError("Sculpt Stroke: " + _bk_o.name + " is in Edit Mode.")
        _bk_me = _bk_o.data
        _bk_n = len(_bk_me.vertices)
        _bk_shown = _bk_array('f')
        _bk_shown.frombytes(_blenderkit.mesh_arrays(_bk_o.name)[0])
        _bk_changed = RuntimeError("Sculpt Stroke: a modifier on " + _bk_o.name + " changes its vertex count, so the stroke cannot be kept. Apply or disable the modifier first.")
        if len(_bk_shown) != 3 * _bk_n:
            raise _bk_changed
        if not any(_bk_m.show_viewport for _bk_m in _bk_o.modifiers):
            _bk_me.vertices.foreach_set('co', _bk_shown)
        else:
            _bk_eo = _bk_o.evaluated_get(bpy.context.evaluated_depsgraph_get())
            _bk_ev = _bk_eo.to_mesh()
            try:
                if len(_bk_ev.vertices) != _bk_n:
                    raise _bk_changed
                _bk_was = _bk_array('f', [0.0]) * (3 * _bk_n)
                _bk_ev.vertices.foreach_get('co', _bk_was)
            finally:
                _bk_eo.to_mesh_clear()
            _bk_co = _bk_array('f', [0.0]) * (3 * _bk_n)
            _bk_me.vertices.foreach_get('co', _bk_co)
            for _bk_i in range(3 * _bk_n):
                _bk_co[_bk_i] += _bk_shown[_bk_i] - _bk_was[_bk_i]
            _bk_me.vertices.foreach_set('co', _bk_co)
        _bk_me.update()
        """
    }

    // MARK: UV

    /// One row of the UV Editor's UV menu. See `UVOperator`.
    public static func uv(_ op: UVOperator) -> String { op.python }

    // MARK: helpers

    /// A Python string literal, with quotes and backslashes escaped — object
    /// names come from the user and can contain either.
    public static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(s), as: UTF8.self)
    }
}
