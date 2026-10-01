import Foundation

/// Blender's "Adjust Last Operation" — the collapsed panel in the bottom-left
/// corner of the viewport, and F9.
///
/// It exists because the interesting parameters of an operator are the ones you
/// only know you wanted *after* seeing the result. You add a cylinder, look at
/// it, and want sixteen sides rather than thirty-two. Without the panel that
/// costs an undo, a re-open of the menu, and a re-type; with it, it costs a
/// drag.
///
/// Blender implements it by undoing the operator and executing it again with
/// the new arguments. This does the same thing, in the same order, for the same
/// reason: re-running is the only way the result can be exactly what typing
/// those arguments the first time would have produced. Anything cheaper —
/// scaling the mesh to fake a larger `size`, say — would drift from the Python
/// in the Info log, and the Info log is meant to *be* the action.
public struct LastOperator: Sendable, Equatable {

    /// One argument of the operator, as Blender's redo panel draws it: a label,
    /// a value you can scrub, and the range the value makes sense in.
    public struct Parameter: Identifiable, Sendable, Equatable {

        /// One item of a bpy enum. The identifier is what the operator takes;
        /// the label is what Blender writes in the interface, and the two are
        /// not the same word — `NGON` is shown as "N-Gon".
        public struct Option: Sendable, Equatable {
            public let identifier: String
            public let label: String
            public init(_ identifier: String, _ label: String) {
                self.identifier = identifier; self.label = label
            }
        }

        public enum Kind: Sendable, Equatable {
            case float
            case integer
            /// A bpy enum. `value` indexes into these; the Python is quoted.
            case choice([Option])
            /// Like `choice`, but the identifier *is* the Python and goes in
            /// unquoted: `dupli=True`, `axis=(0.0, 1.0, 0.0)`. Blender's
            /// operator arguments are not all enums, and a booolean or a
            /// vector written as `'True'` is a string that silently reads as
            /// true whatever it says.
            case literal([Option])
            /// A macro operator's sub-operator property, which Blender takes
            /// as a dictionary: `TRANSFORM_OT_shrink_fatten={"value": 0.2}`.
            /// Extrude is a macro — that is why it could not be adjusted
            /// before — and the associated value is the inner key.
            case nested(String)
            /// One axis of an argument Blender takes as a vector, shown as a
            /// field of its own and composed with its siblings into a single
            /// keyword. `mesh.spin` takes `center=(x, y, z)`; three loose
            /// `center_x=` keywords are not an argument it has. The associated
            /// values are the bpy keyword, the heading Blender's panel draws
            /// over the column ('Center', read from `bl_rna`), and which axis.
            /// `key` stays unique per axis, because it is the row's identity
            /// in the panel and in `subscript(key:)`.
            case component(keyword: String, heading: String, axis: Int)
        }

        public let key: String       // the bpy keyword: "vertices"
        public let label: String     // what Blender calls it: "Vertices"
        public let kind: Kind
        public var value: Double
        /// Blender's *soft* range — where the field scrubs comfortably. The
        /// hard range is wider, but nobody wants a 10-million-sided circle
        /// arriving from a stray finger.
        public let softMin: Double
        public let softMax: Double
        /// Metres (or counts) per point of drag.
        public let step: Double
        /// What the number is, and so how the field shows it: metres unless
        /// said otherwise, a count for an integer. Edge Slide, Edge Crease and
        /// Bevel Weight take a bare factor — Blender's panel draws "Factor
        /// 0.500" — and "0.500 m" would name a distance the operator does not
        /// move by.
        public let unit: NumberFieldUnit

        /// The row this one only matters beside, and the value it has to
        /// hold. The panel greys this row until it does, as Blender greys the
        /// Mirror modifier's Bisect Flip until its axis bisects; it stays
        /// editable, as a greyed row is in Blender. Nil for a row that always
        /// changes the result.
        public var activeWhen: Condition?

        public struct Condition: Sendable, Equatable {
            public let key: String
            public let value: Double
            public init(_ key: String, is value: Double) { self.key = key; self.value = value }
        }

        public var id: String { key }

        public init(key: String, label: String, kind: Kind, value: Double,
                    softMin: Double, softMax: Double, step: Double) {
            self.init(key: key, label: label, kind: kind, value: value,
                      softMin: softMin, softMax: softMax, step: step,
                      unit: kind == .integer ? .count : .meters)
        }

        /// Not an optional `unit` on the one initialiser: `unit: .none` would
        /// then be Optional's `.none` — the default, metres — and a factor
        /// field read "0.500 m" (measured, in tests/redo).
        public init(key: String, label: String, kind: Kind, value: Double,
                    softMin: Double, softMax: Double, step: Double,
                    unit: NumberFieldUnit) {
            self.key = key; self.label = label; self.kind = kind
            self.value = value
            self.softMin = softMin; self.softMax = softMax; self.step = step
            self.unit = unit
        }

        /// The value clamped and rounded to what this kind can actually hold,
        /// so an integer field never emits `vertices=31.7`.
        public var settled: Double {
            let clamped = min(max(value, softMin), softMax)
            switch kind {
            case .float:  return clamped
            case .integer, .choice, .literal: return (clamped).rounded()
            case .nested, .component: return clamped
            }
        }

        /// This argument as it appears inside the call.
        public var python: String {
            switch kind {
            case .float:
                return "\(key)=\(LastOperator.number(settled))"
            case .integer:
                return "\(key)=\(Int(settled))"
            case .choice(let options):
                let i = min(max(Int(settled), 0), options.count - 1)
                return "\(key)='\(options[i].identifier)'"
            case .literal(let options):
                let i = min(max(Int(settled), 0), options.count - 1)
                return "\(key)=\(options[i].identifier)"
            case .nested(let inner):
                return "\(key)={\"\(inner)\": \(LastOperator.number(settled))}"
            case .component:
                // Its share of the tuple, not an argument: `LastOperator.python`
                // places it inside the one keyword its group becomes.
                return LastOperator.number(settled)
            }
        }

        /// What the field shows. Counts and factors are bare; lengths carry
        /// Blender's `m`.
        public var display: String {
            switch kind {
            case .float, .nested, .component: return unit.format(Float(settled))
            case .integer: return String(Int(settled))
            case .choice(let options), .literal(let options):
                let i = min(max(Int(settled), 0), options.count - 1)
                return options[i].label
            }
        }

        /// `parameter`, greyed in the panel until `condition` holds.
        public static func dependent(_ parameter: Parameter, on condition: Condition) -> Parameter {
            var p = parameter
            p.activeWhen = condition
            return p
        }

        /// A vector argument as the three fields Blender's panel draws for it,
        /// keyed `keyword.x`, `.y`, `.z` and labelled X, Y, Z.
        public static func vector(_ keyword: String, _ heading: String, _ value: SIMD3<Double>,
                                  softMin: Double, softMax: Double,
                                  step: Double) -> [Parameter] {
            ["X", "Y", "Z"].enumerated().map { axis, label in
                Parameter(key: "\(keyword).\(label.lowercased())", label: label,
                          kind: .component(keyword: keyword, heading: heading, axis: axis),
                          value: value[axis], softMin: softMin, softMax: softMax, step: step)
            }
        }
    }

    /// How to get back to before the operator ran, which is the hard half of
    /// re-running it.
    ///
    /// Blender does this with its own undo stack, and so does BpyBridge now
    /// wherever Blender's undo keeps the history: `ed.undo_push()` creates the
    /// stack in background mode, and the undo operators' poll — a window and a
    /// screen in the context — passes on the bpy module's main thread. It fails
    /// on the script thread, which has neither; that refusal is what was
    /// measured here once. See `_blenderkit_undo`.
    ///
    /// These restorations remain for when that history is not in use — the
    /// .blend checkpoint fallback, and the simulator's shim. Without a way back,
    /// a second bevel simply bevels the bevel: 56 vertices, then 1944.
    public enum Restoration: Sendable, Equatable {
        /// Remove the object the operator made. What the Add operators need.
        case removeCreated
        /// Put the object's mesh back from a copy taken before the operator
        /// ran. What the mesh operators need, since they change geometry in
        /// place rather than making anything.
        ///
        /// The copy carries the selection with it, so the re-run acts on the
        /// same faces the first run did — that is a property of Blender's mesh
        /// datablock rather than something arranged here, and it is the reason
        /// this works at all.
        case restoreMesh
        /// No restoration: adjustable only while Blender's own undo keeps the
        /// history, which puts back everything the operator changed. Object ▸
        /// Parent, Clear Parent, Join, Duplicate Linked and Convert change
        /// relations and object types across the selection, which neither a
        /// removal nor a mesh backup can undo — re-running `parent_set` over
        /// its own result with Keep Transform toggled moves the child (measured
        /// in 5.2.1: 2.0 m with it off, 0 with it on, for a child whose old
        /// parent had moved). So without Blender's undo they simply run, and
        /// no panel opens (`BpyBridge.performBody`).
        case throughBlenderUndo
    }

    /// The datablock the mesh backup lives in. One operator is adjustable at a
    /// time, so one name is enough.
    public static let backupMesh = "_bk_redo"

    /// What the panel is titled and what the undo step is called: "Add Cube".
    public let name: String
    /// The operator itself: "bpy.ops.mesh.primitive_cube_add".
    public let call: String
    public var parameters: [Parameter]
    /// Drawn as Blender draws it, as a labelled XYZ triple rather than three
    /// unrelated numbers. Nil for operators that do not place anything.
    public var location: SIMD3<Double>?
    public let restoration: Restoration
    /// Whether the operator has to be in edit mode to run.
    public let needsEditMode: Bool
    /// Arguments the operator needs but the panel does not offer, such as
    /// Bisect's `plane_co`.
    ///
    /// `spin` is why this exists. Its `axis` is a vector, and the RNA reports
    /// only the scalar default of its components, so a call built from the
    /// parameter list alone omitted it entirely and Blender answered
    /// "Invalid/unset axis". The Blender-side check found that before any of it
    /// reached a screen. Spin's axis and centre have since become parameters.
    public var fixedArguments: [String] = []

    /// Statements run before the call, such as selecting what it acts on.
    /// Part of what is re-run and logged, because the call means nothing
    /// without them.
    public var lead: String?

    /// The object the operator made or changed, so re-running acts on the same
    /// one. Filled in after the run, because only Blender knows what it named
    /// the thing — or which one was active.
    public var subject: String?

    /// A statement that belongs to the operation without belonging to the
    /// operator: what Blender's 3D View does around the call and a Blender with
    /// no window does not. It runs after the call and is logged with it,
    /// because it is part of what happened.
    public var followUp: String?

    /// A context manager the call runs inside, written `with <within>:`.
    ///
    /// For an operator whose poll wants a 3D View. A `lead` cannot supply one:
    /// `temp_override` only lasts as long as its block, and a view aimed
    /// before the call has to be put back after it whether or not the call
    /// worked — which is what the block is for.
    public var within: String?

    /// The `bpy.data` collection a re-run removes the made object's data-block
    /// from. `bpy.data.meshes.remove` refuses a camera or a light, so each add
    /// names its own.
    public var dataCollection = "meshes"

    /// What to say when Blender returns `{'CANCELLED'}`, raised in its place.
    ///
    /// Some operators refuse a selection without a word: measured in 5.2.1,
    /// `transform.edge_slide(value=0.5)` on a cube with everything selected,
    /// and `edge_crease` or `vert_slide` with nothing selected, each return
    /// CANCELLED and raise nothing. Blender says why on a status bar a bpy
    /// module has none of; here the call would read as done, push an undo
    /// step for nothing, and open a panel whose slider moves nothing.
    public var refusal: String?

    /// Whether the operator changes every selected object, not the active
    /// one alone. The mesh backup (`preamble`) copies the active object's
    /// mesh only, so on that path such an operator does not become adjustable
    /// while another mesh is selected. Measured in 5.2.1 following
    /// `rerunPython`: two UV spheres selected, Shade Smooth by Angle at 5°,
    /// then the active one's mesh put back and the call re-run at 60°. The
    /// active sphere had 0 sharp edges and the other kept its 864 — Keep
    /// Sharp Edges, on by default, keeps the first run's — while a fresh 60°
    /// run gives 0. The panel would have read 60° over a mesh holding 5°.
    /// Blender's own undo, where it keeps the history, puts every object
    /// back, so there the panel stays.
    public var actsOnSelection = false

    public init(name: String, call: String, parameters: [Parameter],
                location: SIMD3<Double>? = nil,
                restoration: Restoration = .removeCreated,
                needsEditMode: Bool = false,
                subject: String? = nil) {
        self.name = name; self.call = call; self.parameters = parameters
        self.location = location; self.restoration = restoration
        self.needsEditMode = needsEditMode; self.subject = subject
    }

    /// The single call, exactly as it goes into the Info log.
    public var python: String { assembled(refusing: false) }

    /// What the bridge runs: `python`, with `refusal` raised in place of a
    /// CANCELLED. The check is kept out of `python` for the reason
    /// `preamble` gives: Blender's Info log records
    /// `bpy.ops.transform.edge_slide(value=0.5, use_even=False, flipped=False)`,
    /// and the log carried `if 'CANCELLED' in …: raise …` in its place.
    public var executedPython: String { assembled(refusing: true) }

    private func assembled(refusing: Bool) -> String {
        // One keyword per parameter, except the components of a vector, which
        // become one keyword between them — at the position of the first, so
        // the call reads in the order the panel does. Skipped explicitly, not
        // filtered out afterwards by what they print, so a future kind that
        // prints nothing is not silently swallowed with them.
        var args: [String] = []
        var composed = Set<String>()
        for parameter in parameters {
            guard case .component(let keyword, _, _) = parameter.kind else {
                args.append(parameter.python)
                continue
            }
            // Once per group: Python refuses `center=` given twice.
            guard composed.insert(keyword).inserted else { continue }
            args.append(vectorArgument(keyword))
        }
        args += fixedArguments
        if let location {
            args.append("location=(\(Self.number(location.x)), "
                        + "\(Self.number(location.y)), \(Self.number(location.z)))")
        }
        var line = "\(call)(\(args.joined(separator: ", ")))"
        if refusing, let refusal {
            line = "if 'CANCELLED' in \(line):\n    raise RuntimeError(\(Bpy.quote(refusal)))"
        }
        if let within {
            // Every line of the call goes inside the block, not only the
            // first: with a refusal the call is two.
            line = "with \(within):\n"
                + line.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        }
        if let lead { line = filled(lead) + "\n" + line }
        guard let followUp else { return line }
        return line + "\n" + followUp
    }

    /// A lead's `@arg:<key>@`, replaced by that parameter's value as the call
    /// carries it (`'VERT'`, `True`), so a check made before the call
    /// answers for the redo panel's values and not the row's defaults: Edge
    /// Split's Type and Delete Loose's three switches change what there is
    /// to do. A key with no parameter is left as it is, and Python says so.
    private func filled(_ lead: String) -> String {
        guard lead.contains("@arg:") else { return lead }
        var out = lead
        for parameter in parameters {
            let token = "@arg:\(parameter.key)@"
            guard out.contains(token) else { continue }
            let python = parameter.python
            let value = python.hasPrefix(parameter.key + "=")
                ? String(python.dropFirst(parameter.key.count + 1)) : python
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }

    /// The bookkeeping that has to happen *before* the operator, so that
    /// re-running it later is possible.
    ///
    /// Kept out of `python` because it is not the action. Blender's Info log
    /// records `bpy.ops.mesh.inset(thickness=0.2)` and nothing else, and a log
    /// that is meant to be re-runnable as a script should not carry the
    /// interface's private scaffolding.
    public var preamble: String {
        switch restoration {
        case .removeCreated, .throughBlenderUndo:
            return ""
        case .restoreMesh:
            // `update_from_editmode` is not optional. In edit mode Blender
            // works on a BMesh and the mesh datablock behind it stays as it was
            // when edit mode was entered — so copying it without this captures
            // the mesh from before every edit made in this session. Measured:
            // 8 vertices copied where the object had 26. Adjusting a bevel
            // would then have thrown away the subdivide that came before it.
            // It returns False rather than raising outside edit mode.
            //
            // The mode switch at the end is not decoration either. A mesh
            // operator only runs in edit mode, and *Blender's* mode is not the
            // interface's — the same gap that made a drag snap back. The
            // re-run path had this from the start and the first run did not,
            // so the first press of Poke Faces answered "not in edit mode with
            // an active object" while every adjustment after it would have
            // worked.
            //
            // The raise is caught by `performBody`, which then leaves the
            // operator unadjustable (see `actsOnSelection`); it is not a
            // refusal of the operator.
            let others = actsOnSelection
                ? """
                  if any(o.type == 'MESH' and o != bpy.context.view_layer.objects.active
                         for o in bpy.context.selected_editable_objects):
                      raise RuntimeError('only the active mesh is backed up')

                  """
                : ""
            return others + """
            _s = bpy.context.view_layer.objects.active
            _b = bpy.data.meshes.get(\(Bpy.quote(Self.backupMesh)))
            if _b is not None:
                _b.use_fake_user = False
                if _b.users == 0:
                    bpy.data.meshes.remove(_b)
            _s.update_from_editmode()
            _b = _s.data.copy()
            _b.name = \(Bpy.quote(Self.backupMesh))
            _b.use_fake_user = True
            """
        }
    }

    /// What has to be true for the operator to run at all, as opposed to what
    /// makes it adjustable afterwards.
    ///
    /// Kept apart from the backup deliberately. A mesh operator only runs in
    /// edit mode, and *Blender's* mode is not the interface's — but taking a
    /// backup can fail on a backend whose meshes are not datablocks, and when
    /// the two were one block that failure took the mode switch with it. Every
    /// mesh operator then answered "not in edit mode with an active object",
    /// which is a confusing way for a backup to fail.
    /// The Blender mode this operator needs.
    ///
    /// Adds need object mode, and not as a nicety: `primitive_cube_add` called
    /// while Blender sits in sculpt mode **crashes Blender** — measured in
    /// 5.2.1, no traceback, the process goes. In edit mode it does something
    /// different but still wrong, adding the primitive into the mesh being
    /// edited rather than into the scene.
    public var requiredBlenderMode: String {
        needsEditMode ? "EDIT" : "OBJECT"
    }

    public var entryPython: String {
        // Asked for unconditionally and allowed to fail. Blender's `mode_set`
        // is a no-op when it is already in that mode, and reading `.mode`
        // first only adds a property that a backend might not have — which is
        // what happened: the guard threw, the switch never ran, and every mesh
        // operator reported that it was not in edit mode.
        //
        // Swallowing it is right for a mode Blender simply happens to be in
        // already, and wrong for one the active object does not have at all: a
        // light has no edit mode, so Subdivide swallowed the failure, stayed in
        // object mode and then failed its own poll — "context is incorrect",
        // which names neither the light nor the operator. Only the edit-mode
        // half is held to a mesh; adds need object mode, which everything has.
        let refusal = needsEditMode ? Bpy.needsAMesh(for: name) + "\n" : ""
        return refusal + """
        _bk_prev_mode = 'OBJECT'
        _bk_active = bpy.context.view_layer.objects.active
        if _bk_active is not None:
            _bk_prev_mode = getattr(_bk_active, "mode", "OBJECT")
        try:
            bpy.ops.object.mode_set(mode='\(requiredBlenderMode)')
        except Exception:
            pass
        """
    }

    /// Puts the mode back.
    ///
    /// Not optional, and the reason is a bug this had: entering edit mode and
    /// staying there leaves Blender in a mode where every object-mode operator
    /// fails its poll. The next script to call `bpy.ops.object.select_all`
    /// — which is the first line of anything that clears the scene — answered
    /// "context is incorrect", a long way from the mesh operator that actually
    /// caused it.
    public var exitPython: String {
        return """
        try:
            if _bk_prev_mode != '\(requiredBlenderMode)':
                bpy.ops.object.mode_set(mode=_bk_prev_mode)
        except Exception:
            pass
        """
    }

    /// Drops the backup. Run when the operator stops being the adjustable one,
    /// so a session does not carry a spare copy of every mesh ever edited.
    public static var discardBackup: String {
        """
        _b = bpy.data.meshes.get(\(Bpy.quote(backupMesh)))
        if _b is not None:
            _b.use_fake_user = False
            if _b.users == 0:
                bpy.data.meshes.remove(_b)
        """
    }

    /// The call, preceded by the removal of what the last one made.
    ///
    /// The mesh datablock goes too. Without that, removing the object frees the
    /// name `Cube` but leaves a mesh still called `Cube`, so the re-added
    /// object arrives holding a mesh named `Cube.001` — and after ten drags of
    /// a slider the file is carrying ten orphaned meshes and a counter that
    /// only goes up.
    public var rerunPython: String {
        let python = executedPython
        guard let subject else { return python }
        switch restoration {
        case .throughBlenderUndo:
            // Never adjusted this way: `performBody` leaves it unadjustable
            // when Blender's undo is not keeping the history, and with it the
            // bridge adjusts by undoing (`readjustThroughUndo`).
            return python
        case .removeCreated:
            return """
            _o = bpy.data.objects.get(\(Bpy.quote(subject)))
            if _o is not None:
                _d = _o.data
                bpy.data.objects.remove(_o, do_unlink=True)
                if _d is not None and _d.users == 0:
                    bpy.data.\(dataCollection).remove(_d)
            \(python)
            """

        case .restoreMesh:
            // The symmetry flags are carried over from the mesh being
            // replaced. The backup holds the ones from before the operator,
            // and an edit-mode toggle since then made no undo step
            // (SymmetryBpy.undoLabel), because Blender's edit-mesh undo leaves
            // them alone — so Blender's own redo keeps the current ones.
            // Without this, X turned off with the panel open read True again
            // on adjusting. Set only when they differ: the simulator's
            // stand-in raises on setting them, and reads False on both sides.
            //
            // The mode round-trip is not optional: a mesh datablock cannot be
            // swapped while the object is in edit mode. It ends where it
            // started, because the user ran this from edit mode and being
            // dropped into object mode by moving a slider would be its own bug.
            let body = needsEditMode
                ? """
                  bpy.ops.object.mode_set(mode='EDIT')
                  \(python)
                  """
                : python
            return """
            _o = bpy.data.objects.get(\(Bpy.quote(subject)))
            _b = bpy.data.meshes.get(\(Bpy.quote(Self.backupMesh)))
            if _o is not None and _b is not None:
                _m = _o.mode
                if _m != 'OBJECT':
                    bpy.ops.object.mode_set(mode='OBJECT')
                _old = _o.data
                _o.data = _b.copy()
                # The mesh's symmetry flags as they are now, not the backup's.
                for _p in ('use_mirror_x', 'use_mirror_y', 'use_mirror_z', 'use_mirror_topology'):
                    if getattr(_o.data, _p) != getattr(_old, _p):
                        setattr(_o.data, _p, getattr(_old, _p))
                if _old.users == 0:
                    bpy.data.meshes.remove(_old)
                \(body.split(separator: "\n").joined(separator: "\n    "))
                if _o.mode != _m:
                    bpy.ops.object.mode_set(mode=_m)
            """
        }
    }

    /// Every component of `keyword`, as the one argument they make. An axis
    /// nothing supplies reads 0; `Parameter.vector` always makes all three.
    private func vectorArgument(_ keyword: String) -> String {
        var slots = ["0", "0", "0"]
        for parameter in parameters {
            if case .component(let k, _, let axis) = parameter.kind, k == keyword,
               slots.indices.contains(axis) {
                slots[axis] = parameter.python
            }
        }
        return "\(keyword)=(\(slots.joined(separator: ", ")))"
    }

    /// A parameter by key, for tests and for the panel's bindings.
    /// Whether a row changes the result given the others' values: false
    /// greys it in the panel. See `Parameter.activeWhen`.
    public func isActive(_ parameter: Parameter) -> Bool {
        guard let condition = parameter.activeWhen else { return true }
        return self[condition.key] == condition.value
    }

    public subscript(key: String) -> Double? {
        get { parameters.first { $0.key == key }?.settled }
        set {
            guard let newValue, let i = parameters.firstIndex(where: { $0.key == key })
            else { return }
            parameters[i].value = newValue
        }
    }

    /// Trailing zeros are noise in a log line meant to be read.
    ///
    /// A value just below zero formats as `-0.0000`, and stripping the zeros
    /// off that leaves `-0` — valid Python, but it reads as a mistake in a log
    /// someone is meant to trust.
    static func number(_ v: Double) -> String {
        if abs(v) < 0.00005 { return "0" }
        let s = String(format: "%.4f", v)
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty || t == "-" ? "0" : t
    }
}

// MARK: - The catalogue

public extension LastOperator {

    /// The parameters Blender's own add operators take, with Blender's own
    /// defaults and soft ranges.
    ///
    /// These are not invented: they were read out of `bpy.ops.mesh.*.get_rna_type()`
    /// in Blender 5.2.1, which is why a cone's radii are `radius1`/`radius2`
    /// rather than the `radius_bottom`/`radius_top` you would guess.
    static func add(_ kind: PrimitiveKind, at location: SIMD3<Float>) -> LastOperator {
        let fill = [Parameter.Option("NOTHING", "Nothing"),
                    Parameter.Option("NGON", "N-Gon"),
                    Parameter.Option("TRIFAN", "Triangle Fan")]
        let radius = Parameter(key: "radius", label: "Radius", kind: .float,
                               value: 1, softMin: 0.001, softMax: 100, step: 0.01)
        let size = Parameter(key: "size", label: "Size", kind: .float,
                             value: 2, softMin: 0.001, softMax: 100, step: 0.01)
        let depth = Parameter(key: "depth", label: "Depth", kind: .float,
                              value: 2, softMin: 0.001, softMax: 100, step: 0.01)
        let vertices = Parameter(key: "vertices", label: "Vertices", kind: .integer,
                                 value: 32, softMin: 3, softMax: 500, step: 0.2)

        let parameters: [Parameter]
        switch kind {
        case .plane, .cube, .monkey:
            parameters = [size]
        case .circle:
            parameters = [vertices, radius,
                          Parameter(key: "fill_type", label: "Fill Type",
                                    kind: .choice(fill), value: 0,
                                    softMin: 0, softMax: 2, step: 0.02)]
        case .uvSphere:
            parameters = [
                Parameter(key: "segments", label: "Segments", kind: .integer,
                          value: 32, softMin: 3, softMax: 500, step: 0.2),
                Parameter(key: "ring_count", label: "Rings", kind: .integer,
                          value: 16, softMin: 3, softMax: 500, step: 0.2),
                radius]
        case .icoSphere:
            parameters = [
                Parameter(key: "subdivisions", label: "Subdivisions", kind: .integer,
                          value: 2, softMin: 1, softMax: 8, step: 0.03),
                radius]
        case .cylinder:
            parameters = [vertices, radius, depth,
                          Parameter(key: "end_fill_type", label: "Cap Fill Type",
                                    kind: .choice(fill), value: 1,
                                    softMin: 0, softMax: 2, step: 0.02)]
        case .cone:
            parameters = [
                vertices,
                Parameter(key: "radius1", label: "Radius 1", kind: .float,
                          value: 1, softMin: 0, softMax: 100, step: 0.01),
                Parameter(key: "radius2", label: "Radius 2", kind: .float,
                          value: 0, softMin: 0, softMax: 100, step: 0.01),
                depth,
                Parameter(key: "end_fill_type", label: "Base Fill Type",
                          kind: .choice(fill), value: 1,
                          softMin: 0, softMax: 2, step: 0.02)]
        case .torus:
            parameters = [
                Parameter(key: "major_segments", label: "Major Segments", kind: .integer,
                          value: 48, softMin: 3, softMax: 256, step: 0.2),
                Parameter(key: "minor_segments", label: "Minor Segments", kind: .integer,
                          value: 12, softMin: 3, softMax: 256, step: 0.2),
                Parameter(key: "major_radius", label: "Major Radius", kind: .float,
                          value: 1, softMin: 0, softMax: 100, step: 0.01),
                Parameter(key: "minor_radius", label: "Minor Radius", kind: .float,
                          value: 0.25, softMin: 0, softMax: 100, step: 0.01)]
        case .grid:
            parameters = [
                Parameter(key: "x_subdivisions", label: "X Subdivisions", kind: .integer,
                          value: 10, softMin: 1, softMax: 1000, step: 0.2),
                Parameter(key: "y_subdivisions", label: "Y Subdivisions", kind: .integer,
                          value: 10, softMin: 1, softMax: 1000, step: 0.2),
                size]
        }

        return LastOperator(
            name: "Add \(kind.displayName)",
            call: "bpy.ops.mesh.primitive_\(kind.bpyPrimitive)_add",
            parameters: parameters,
            location: SIMD3<Double>(Double(location.x), Double(location.y),
                                    Double(location.z)),
            restoration: .removeCreated)
    }
}

// MARK: - The mesh operators

public extension LastOperator {

    /// The mesh operators worth adjusting, with Blender's own arguments,
    /// defaults and soft ranges — read out of `get_rna_type()` in 5.2.1 the
    /// same way the Add operators' were.
    ///
    /// These are the cases F9 was really made for. Nobody knows the right bevel
    /// width before seeing the bevel; you find out that two segments is too few
    /// by looking at two segments.
    ///
    /// Not every operator belongs here. `loopcut_slide` and `knife_tool` are
    /// modal — their arguments come from where the finger went, so there is
    /// nothing to re-run them with — and `extrude_region_move` carries a
    /// translation rather than a shape.
    enum Mesh: String, CaseIterable, Sendable {
        case bevel, inset, subdivide, loopCut, smooth, mergeByDistance, randomize
        case spin, solidify, wireframe, symmetrize, poke
        case shrinkFatten, pushPull, toSphere
        // The ones a modelling course teaches on day one, and which were
        // missing: extrude is the backbone of box modelling, bisect is the
        // cut Blender can make without a pointer, and the rest are the
        // clean-up half of the job — dissolving what a cut left behind,
        // closing a hole, getting the normals facing out.
        case extrude, bisect
        // Blender's Extrude menu has it after Extrude Faces Along Normals;
        // declared here so the Add Geometry group lists it beside Extrude.
        case extrudeIndividual
        case dissolveVerts, dissolveEdges, dissolveFaces
        case mergeAtCenter, bridgeEdgeLoops, gridFill, fillFace
        case recalculateNormals, flipNormals
        case triangulate, quadify
        // The edge tools, each measured working without a window in 5.2.1
        // (docs/blender-local.md, 2026-09-21). In Blender's own menu order,
        // which the Mesh menu keeps: Select ▸ Select Loops, then the Vertex
        // menu, then the Edge menu.
        case selectEdgeLoops, selectEdgeRings
        case connectVertexPath, slideVertices
        case edgeSlide, offsetEdgeSlide, bevelWeight, edgeCrease
        case markSeam, clearSeam, markSharp, clearSharp
        // Round 3: the rows Blender's menus have that were reachable only by
        // name through All Blender Tools. Each measured working headless in
        // 5.2.1 with the app's context (docs/blender-local.md, 2026-09-22,
        // "Join, Parent, Convert and the clean-up rows").
        case bevelVertices
        case splitSelection, edgeSplitEdges, edgeSplitVertices
        case unsubdivide, beautifyFaces
        case limitedDissolve, deleteLoose, fillHoles

        public var displayName: String {
            switch self {
            case .bevel:           return "Bevel"
            case .inset:           return "Inset Faces"
            case .subdivide:       return "Subdivide"
            case .loopCut:         return "Loop Cut"
            case .smooth:          return "Smooth"
            case .mergeByDistance: return "Merge by Distance"
            case .randomize:       return "Randomize"
            case .spin:            return "Spin"
            case .solidify:        return "Solidify"
            case .wireframe:       return "Wireframe"
            case .symmetrize:      return "Symmetrize"
            case .poke:            return "Poke Faces"
            case .shrinkFatten:    return "Shrink/Fatten"
            case .pushPull:        return "Push/Pull"
            case .toSphere:        return "To Sphere"
            case .extrude:            return "Extrude"
            case .bisect:             return "Bisect"
            case .dissolveVerts:      return "Dissolve Vertices"
            case .dissolveEdges:      return "Dissolve Edges"
            case .dissolveFaces:      return "Dissolve Faces"
            case .mergeAtCenter:      return "Merge at Center"
            case .bridgeEdgeLoops:    return "Bridge Edge Loops"
            case .gridFill:           return "Grid Fill"
            case .fillFace:           return "New Face from Edges"
            case .recalculateNormals: return "Recalculate Normals"
            case .flipNormals:        return "Flip Normals"
            case .triangulate:        return "Triangulate Faces"
            case .quadify:            return "Tris to Quads"
            // Blender's menu labels, except the two selections: the label is
            // also the undo step and the panel's title, and "Edge Loops" alone
            // reads as a thing rather than something that was done.
            case .selectEdgeLoops:    return "Select Edge Loops"
            case .selectEdgeRings:    return "Select Edge Rings"
            case .connectVertexPath:  return "Connect Vertex Path"
            case .slideVertices:      return "Slide Vertices"
            case .edgeSlide:          return "Edge Slide"
            case .offsetEdgeSlide:    return "Offset Edge Slide"
            case .bevelWeight:        return "Edge Bevel Weight"
            case .edgeCrease:         return "Edge Crease"
            case .markSeam:           return "Mark Seam"
            case .clearSeam:          return "Clear Seam"
            case .markSharp:          return "Mark Sharp"
            case .clearSharp:         return "Clear Sharp"
            // The operator's own name, which is the undo step and the panel's
            // title: Bevel Vertices is `mesh.bevel`, and Blender's panel over
            // it reads "Bevel", with Affect set to Vertices.
            case .bevelVertices:      return "Bevel"
            case .extrudeIndividual:  return "Extrude Individual Faces"
            case .splitSelection:     return "Split"
            case .edgeSplitEdges, .edgeSplitVertices: return "Edge Split"
            case .unsubdivide:        return "Un-Subdivide"
            case .beautifyFaces:      return "Beautify Faces"
            case .limitedDissolve:    return "Limited Dissolve"
            case .deleteLoose:        return "Delete Loose"
            case .fillHoles:          return "Fill Holes"
            }
        }

        /// What the Mesh menu's row says, where that is not the operator's
        /// name: Blender's own labels, `VIEW3D_MT_edit_mesh_vertices`'s "Bevel
        /// Vertices" and `VIEW3D_MT_edit_mesh_split`'s "Selection" and its
        /// `edge_split` types (space_view3d.py, 5.2.1).
        public var menuLabel: String {
            switch self {
            case .bevelVertices:      return "Bevel Vertices"
            case .splitSelection:     return "Selection"
            case .edgeSplitEdges:     return "Faces by Edges"
            case .edgeSplitVertices:  return "Faces & Edges by Vertices"
            default:                  return displayName
            }
        }

        /// Blender's Mesh menu is nested, and for the same reason: a flat
        /// list of forty-odd operators is a list nobody reads. The groups are
        /// Blender's own headings — Select Loops is its Select menu's, Vertex
        /// and Edge are the menus beside Mesh in its header — in the order its
        /// header reads left to right.
        public enum Group: String, CaseIterable, Sendable {
            case selectLoops = "Select Loops"
            case build = "Add Geometry"
            // Blender's Mesh ▸ Split: Selection, then `edge_split`'s two types.
            case split = "Split"
            case cut = "Cut and Divide"
            case vertex = "Vertex"
            case edge = "Edge"
            case cleanUp = "Clean Up"
            case fill = "Fill"
            case normals = "Normals"
            case deform = "Deform"
        }

        /// Whether the Mesh menu offers it only in Edit Mode.
        ///
        /// The menu runs a mesh operator from Object Mode by switching into
        /// Edit Mode around it, and it acts on the selection the mesh last
        /// stored — every element, on a new primitive. For these the whole
        /// effect is that selection or an edge flag, and outside Edit Mode the
        /// app draws neither. Measured in 5.2.1 with the `performBody` the
        /// bridge sends: on a fresh cube from Object Mode, Mark Seam marked
        /// 12 of 12 edges and Edge Crease at 0.5 creased all 12, with nothing
        /// on screen to say so. They are Edit Mode menu items in Blender too
        /// (Select ▸ Select Loops, and the Edge menu).
        public var editModeOnly: Bool {
            switch self {
            case .selectEdgeLoops, .selectEdgeRings, .markSeam, .clearSeam,
                 .markSharp, .clearSharp, .edgeCrease, .bevelWeight:
                return true
            default:
                return false
            }
        }

        public var group: Group {
            switch self {
            case .selectEdgeLoops, .selectEdgeRings:                     return .selectLoops
            case .extrude, .extrudeIndividual, .inset, .bevel, .spin,
                 .solidify, .wireframe:                                  return .build
            case .splitSelection, .edgeSplitEdges, .edgeSplitVertices:   return .split
            case .subdivide, .loopCut, .bisect, .poke:                   return .cut
            case .connectVertexPath, .slideVertices, .bevelVertices:     return .vertex
            case .edgeSlide, .offsetEdgeSlide, .bevelWeight, .edgeCrease,
                 .markSeam, .clearSeam, .markSharp, .clearSharp,
                 .unsubdivide:                                           return .edge
            case .mergeAtCenter, .mergeByDistance, .dissolveVerts,
                 .dissolveEdges, .dissolveFaces, .triangulate, .quadify,
                 .limitedDissolve, .deleteLoose, .fillHoles:             return .cleanUp
            case .fillFace, .gridFill, .bridgeEdgeLoops, .beautifyFaces: return .fill
            case .recalculateNormals, .flipNormals:                      return .normals
            case .smooth, .randomize, .shrinkFatten, .pushPull,
                 .toSphere, .symmetrize:                                 return .deform
            }
        }

        var call: String {
            switch self {
            case .bevel:           return "bpy.ops.mesh.bevel"
            case .inset:           return "bpy.ops.mesh.inset"
            case .subdivide:       return "bpy.ops.mesh.subdivide"
            case .loopCut:         return "bpy.ops.mesh.subdivide_edgering"
            case .smooth:          return "bpy.ops.mesh.vertices_smooth"
            case .mergeByDistance: return "bpy.ops.mesh.remove_doubles"
            case .randomize:       return "bpy.ops.transform.vertex_random"
            case .spin:            return "bpy.ops.mesh.spin"
            case .solidify:        return "bpy.ops.mesh.solidify"
            case .wireframe:       return "bpy.ops.mesh.wireframe"
            case .symmetrize:      return "bpy.ops.mesh.symmetrize"
            case .poke:            return "bpy.ops.mesh.poke"
            case .shrinkFatten:    return "bpy.ops.transform.shrink_fatten"
            case .pushPull:        return "bpy.ops.transform.push_pull"
            case .toSphere:        return "bpy.ops.transform.tosphere"
            // Extrude is a macro operator: the extrude and the move that
            // follows it are one undo step and one call, and the move's
            // arguments arrive as a dictionary under the sub-operator's name.
            case .extrude:            return "bpy.ops.mesh.extrude_region_shrink_fatten"
            case .bisect:             return "bpy.ops.mesh.bisect"
            case .dissolveVerts:      return "bpy.ops.mesh.dissolve_verts"
            case .dissolveEdges:      return "bpy.ops.mesh.dissolve_edges"
            case .dissolveFaces:      return "bpy.ops.mesh.dissolve_faces"
            case .mergeAtCenter:      return "bpy.ops.mesh.merge"
            case .bridgeEdgeLoops:    return "bpy.ops.mesh.bridge_edge_loops"
            case .gridFill:           return "bpy.ops.mesh.fill_grid"
            case .fillFace:           return "bpy.ops.mesh.edge_face_add"
            case .recalculateNormals: return "bpy.ops.mesh.normals_make_consistent"
            case .flipNormals:        return "bpy.ops.mesh.flip_normals"
            case .triangulate:        return "bpy.ops.mesh.quads_convert_to_tris"
            case .quadify:            return "bpy.ops.mesh.tris_convert_to_quads"
            // `mesh.loop_multi_select` is what older scripts call; 5.2.1 has
            // no such operator (its RNA lookup fails), and its Select Loops
            // menu calls these two.
            case .selectEdgeLoops:    return "bpy.ops.mesh.select_edge_loop_multi"
            case .selectEdgeRings:    return "bpy.ops.mesh.select_edge_ring_multi"
            case .connectVertexPath:  return "bpy.ops.mesh.vert_connect_path"
            case .slideVertices:      return "bpy.ops.transform.vert_slide"
            case .edgeSlide:          return "bpy.ops.transform.edge_slide"
            // A macro, like Extrude: the offset loops, then an edge slide
            // of them, one call and one undo step.
            case .offsetEdgeSlide:    return "bpy.ops.mesh.offset_edge_loops_slide"
            case .bevelWeight:        return "bpy.ops.transform.edge_bevelweight"
            case .edgeCrease:         return "bpy.ops.transform.edge_crease"
            case .markSeam, .clearSeam:   return "bpy.ops.mesh.mark_seam"
            case .markSharp, .clearSharp: return "bpy.ops.mesh.mark_sharp"
            case .bevelVertices:      return "bpy.ops.mesh.bevel"
            // A macro like Extrude: each face extruded on its own, then a
            // Shrink/Fatten of all of them along their normals.
            case .extrudeIndividual:  return "bpy.ops.mesh.extrude_faces_move"
            case .splitSelection:     return "bpy.ops.mesh.split"
            case .edgeSplitEdges, .edgeSplitVertices: return "bpy.ops.mesh.edge_split"
            case .unsubdivide:        return "bpy.ops.mesh.unsubdivide"
            case .beautifyFaces:      return "bpy.ops.mesh.beautify_fill"
            case .limitedDissolve:    return "bpy.ops.mesh.dissolve_limited"
            case .deleteLoose:        return "bpy.ops.mesh.delete_loose"
            case .fillHoles:          return "bpy.ops.mesh.fill_holes"
            }
        }

        /// Whether Blender's own run of it mirrors across the mesh's X / Y / Z
        /// symmetry: the transform operators among these, which take
        /// `mirror`. Measured in 5.2.1 on an 8 × 8 grid with `use_mirror_x`
        /// on and 9 vertices selected on the +X side, each with and without
        /// `mirror=True`: Shrink/Fatten moved 18 and 9, Push/Pull 16 and 8,
        /// To Sphere 16 and 8, Slide Vertices 18 and 9, Edge Slide (a column)
        /// 18 and 9. Not the extrude macros — Blender's own definitions pin
        /// their move's `mirror` to False (mesh_ops.cc) — nor Offset Edge
        /// Slide, whose new loops have no mirror image to move (measured:
        /// 18 new vertices, all on +X, either way). Smooth Vertices mirrors
        /// across X by itself, from the flag, and needs nothing (measured: 2
        /// vertices moved with the flag on, 1 with it off).
        public var honoursMeshSymmetry: Bool {
            switch self {
            case .shrinkFatten, .pushPull, .toSphere, .slideVertices, .edgeSlide: return true
            default: return false
            }
        }

        /// Spin's axis and centre are parameters, and Bisect's `plane_co` is
        /// added in `mesh(_:spinningAround:)`, where the object's origin is
        /// known. Mark and Clear are one operator each in Blender, told apart
        /// by `clear` — hidden from its redo panel, so not a field here
        /// either, and written out both ways as Blender's Info log writes it.
        var fixedArguments: [String] {
            switch self {
            case .markSeam, .markSharp:   return ["clear=False"]
            case .clearSeam, .clearSharp: return ["clear=True"]
            default:                      return []
            }
        }

        /// The words for an operator that returns CANCELLED without raising
        /// (`LastOperator.refusal`). Each of these was measured doing exactly
        /// that in 5.2.1: the slides with nothing selected or with a selection
        /// that is not a loop (a whole cube), Crease and Bevel Weight with no
        /// edge selected.
        var refusal: String? {
            switch self {
            case .edgeSlide:
                return "Edge Slide cannot slide this selection: select an edge, "
                    + "or a loop of edges (Select Loops > Select Edge Loops)"
            case .offsetEdgeSlide:
                return "Offset Edge Slide adds loops beside the selected edges: select an edge first"
            case .slideVertices:
                return "Slide Vertices slides the selected vertices along their edges: select a vertex first"
            case .edgeCrease:
                return "Edge Crease sets the crease of the selected edges: select an edge first"
            case .bevelWeight:
                return "Edge Bevel Weight sets the bevel weight of the selected edges: select an edge first"
            // Measured in 5.2.1 on a cube with nothing selected: CANCELLED,
            // raising nothing, with Affect on Edges and on Vertices alike.
            case .bevel, .bevelVertices:
                return "Bevel bevels the selected edges, or the selected vertices with Affect set "
                    + "to Vertices: select some first"
            default:
                return nil
            }
        }

        /// Every mesh in Edit Mode, as `_bk_meshes`: what Blender's mesh
        /// operators act on (`objects_in_mode_unique_data`), the active
        /// object's alone where the context has no such member (the
        /// simulator's stand-in).
        static let editMeshes = """
        _bk_meshes = [_bk_o.data for _bk_o in (getattr(bpy.context, 'objects_in_mode_unique_data', None)
                                               or [bpy.context.object])
                      if _bk_o is not None and _bk_o.type == 'MESH']
        """

        /// Blender's Loop Cut and Slide is modal: the cut goes through the
        /// edge under the pointer, and without a window `loopcut_slide`
        /// returns CANCELLED and `loopcut` crashes (Blender 5.2.1, measured).
        /// The same cut without a pointer: the ring through the selected edges,
        /// subdivided. A cube with one edge selected goes from 8 vertices to 12.
        var lead: String? {
            switch self {
            case .loopCut:
                return """
                bpy.ops.mesh.select_edge_ring_multi()
                if bpy.context.object.data.total_edge_sel == 0:
                    raise RuntimeError('Loop Cut cuts across the selected edges: select an edge first')
                """
            // These return FINISHED having done nothing when nothing they act
            // on is selected (measured in 5.2.1), so the refusal has to come
            // first: afterwards there is nothing to tell the two apart.
            // `total_edge_sel` reads the edit-mode selection as it stands, not
            // the mesh as edit mode found it (measured: 1, then 4 after a loop
            // select on a 4 × 4 grid, with no `update_from_editmode`).
            case .selectEdgeLoops, .selectEdgeRings, .markSeam, .clearSeam, .markSharp, .clearSharp:
                let verb: String
                switch self {
                case .selectEdgeLoops, .selectEdgeRings: verb = "runs through the selected edges"
                case .markSeam, .markSharp:              verb = "marks the selected edges"
                default:                                 verb = "clears the selected edges"
                }
                return """
                if bpy.context.object.data.total_edge_sel == 0:
                    raise RuntimeError('\(displayName) \(verb): select an edge first')
                """
            // Two vertices are joined whatever order they were picked in; any
            // other number needs Blender's selection history, and Blender
            // answers "Invalid selection order" without one — for a single
            // vertex too, which is a confusing way to say "pick another".
            // With none selected it returns FINISHED having done nothing.
            // The viewport's selection reaches Blender without an order, so
            // three or more are left to Blender's own words
            // (edbm_vert_connect_path_exec: a pair ignores the order).
            case .connectVertexPath:
                return """
                if bpy.context.object.data.total_vert_sel < 2:
                    raise RuntimeError('Connect Vertex Path joins selected vertices: select two')
                """
            // Each of these returns FINISHED having changed nothing when
            // nothing it acts on is selected (measured in 5.2.1 on a 7 × 7
            // grid and a cube, nothing selected: Limited Dissolve, Fill
            // Holes, Split, Edge Split, Un-Subdivide, Beautify Faces and
            // Extrude Individual Faces all kept 49 or 8 vertices), so the
            // refusal comes first, before Blender changes anything. Only an
            // empty selection is refused: a selection these rows have nothing
            // to do with (Fill Holes on a closed cube, Limited Dissolve on a
            // cube, Beautify Faces on quads) still returns FINISHED with
            // nothing changed, as in Blender.
            //
            // Every mesh in Edit Mode counts, not only the active one: each of
            // these acts on all of them (measured in 5.2.1, two 7 × 7 grids in
            // Edit Mode, the active one with nothing selected: Limited Dissolve
            // took the other 49 → 4, Un-Subdivide 49 → 22, Edge Split 49 →
            // 144, Extrude Individual 49 → 193), and reading the active mesh
            // alone refused all four.
            case .limitedDissolve, .splitSelection, .unsubdivide:
                let what: String
                switch self {
                case .limitedDissolve: what = "dissolves the selected geometry flat where it can"
                case .splitSelection:  what = "disconnects the selected geometry from the rest"
                default:               what = "reverses a subdivision of the selected geometry"
                }
                return Self.editMeshes + """

                if not any(_bk_me.total_vert_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(displayName) \(what): select something first')
                """
            // Faces & Edges by Vertices splits at the selected vertices, and
            // needs no edge: measured in 5.2.1 on a 7 × 7 grid with one inner
            // vertex selected (no edge), type='VERT' split 49 → 52 and
            // type='EDGE' changed nothing. The type is the panel's, so the
            // check follows the field (`@arg:type@`).
            case .edgeSplitEdges, .edgeSplitVertices:
                return Self.editMeshes + """

                if @arg:type@ == 'VERT':
                    if not any(_bk_me.total_vert_sel for _bk_me in _bk_meshes):
                        raise RuntimeError('\(displayName) splits the mesh at the selected vertices: select a vertex first')
                elif not any(_bk_me.total_edge_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(displayName) splits the mesh along the selected edges: select an edge first')
                """
            case .fillHoles:
                return Self.editMeshes + """

                if not any(_bk_me.total_edge_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(displayName) fills the holes the selected edges go round: select an edge first')
                """
            case .beautifyFaces, .extrudeIndividual:
                let what = self == .beautifyFaces
                    ? "turns the edges between the selected triangles"
                    : "extrudes each selected face on its own"
                return Self.editMeshes + """

                if not any(_bk_me.total_face_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(displayName) \(what): select a face first')
                """
            // Delete Loose with nothing it removes in the selection still
            // returns FINISHED, and deselects everything on the way
            // ("Removed: 0 vertices, 0 edges, 0 faces", measured on a whole
            // cube), so what it would remove is looked for first, with the
            // panel's own switches (`@arg:…@`): a selected vertex in no edge
            // with Vertices on, a selected edge in no face with Edges on, a
            // selected face whose every edge is on the boundary with Faces on
            // — `edbm_delete_loose_exec`'s three tests. Without the switches a
            // lone face passed with Faces off (the default) and Blender then
            // removed nothing and cleared the selection (measured). Each `any`
            // stops at the first loose element. bmesh is Blender's own: the
            // simulator's stand-in has none, and says so.
            case .deleteLoose:
                // A loop rather than a helper function: a name the lead
                // defines is not visible inside a nested scope when the
                // interpreter runs it with separate globals and locals.
                return """
                try:
                    import bmesh
                except ImportError:
                    raise RuntimeError('Delete Loose needs Blender itself to find what is loose: '
                                       'the simulator has no bmesh') from None
                """ + "\n" + Self.editMeshes + """

                _bk_found = False
                for _bk_me in _bk_meshes:
                    _bk_bm = bmesh.from_edit_mesh(_bk_me)
                    if ((@arg:use_verts@ and any(v.select and not v.link_edges for v in _bk_bm.verts))
                            or (@arg:use_edges@ and any(e.select and not e.link_faces for e in _bk_bm.edges))
                            or (@arg:use_faces@ and any(f.select and all(len(e.link_faces) == 1 for e in f.edges)
                                                       for f in _bk_bm.faces))):
                        _bk_found = True
                        break
                if not _bk_found:
                    raise RuntimeError('Delete Loose removes what is selected and loose (vertices in no edge, '
                                       'edges in no face, faces on their own, as its switches say): '
                                       'nothing selected is loose')
                """
            default:
                return nil
            }
        }

        var parameters: [Parameter] {
            switch self {
            case .bevel, .bevelVertices:
                // Blender's own default width is 0, which bevels nothing. The
                // interface has always passed a visible one; that stays the
                // starting point, and the panel is how it gets changed.
                //
                // Affect first, where Blender's panel draws it
                // (`edbm_bevel_ui`). Vertices rounds each selected corner
                // off without touching the edges between them: measured in
                // 5.2.1, a whole cube at width 0.1 and 2 segments came out
                // with 56 vertices and 30 faces on Vertices, 56 and 54 on
                // Edges, and one corner alone 14 and 9 — where Edges, given
                // only that corner, changed nothing.
                return [
                    Parameter(key: "affect", label: "Affect",
                              kind: .choice([Parameter.Option("VERTICES", "Vertices"),
                                             Parameter.Option("EDGES", "Edges")]),
                              value: self == .bevelVertices ? 0 : 1, softMin: 0, softMax: 1, step: 0.02),
                    Parameter(key: "offset", label: "Width", kind: .float,
                              value: 0.1, softMin: 0, softMax: 100, step: 0.002),
                    Parameter(key: "segments", label: "Segments", kind: .integer,
                              value: 2, softMin: 1, softMax: 100, step: 0.05),
                    Parameter(key: "profile", label: "Profile", kind: .float,
                              value: 0.5, softMin: 0, softMax: 1, step: 0.004)]
            case .inset:
                return [
                    Parameter(key: "thickness", label: "Thickness", kind: .float,
                              value: 0.3, softMin: 0, softMax: 1, step: 0.004),
                    Parameter(key: "depth", label: "Depth", kind: .float,
                              value: 0, softMin: -10, softMax: 10, step: 0.01),
                    // Each face inset on its own rather than the selection as
                    // one region, after Depth as in Blender's panel. Measured
                    // in 5.2.1: a whole cube inset as a region is a closed
                    // region with no border and stays 8 vertices; Individual
                    // gives 32 and 30 faces. Four faces of a 7 × 7 grid: 57
                    // vertices as a region, 65 individually.
                    Parameter(key: "use_individual", label: "Individual",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .subdivide:
                return [
                    Parameter(key: "number_cuts", label: "Number of Cuts", kind: .integer,
                              value: 1, softMin: 1, softMax: 10, step: 0.03),
                    Parameter(key: "smoothness", label: "Smoothness", kind: .float,
                              value: 0, softMin: 0, softMax: 1, step: 0.004)]
            case .loopCut:
                return [
                    Parameter(key: "number_cuts", label: "Number of Cuts", kind: .integer,
                              value: 1, softMin: 1, softMax: 64, step: 0.05),
                    Parameter(key: "smoothness", label: "Smoothness", kind: .float,
                              value: 0, softMin: 0, softMax: 2, step: 0.004),
                    Parameter(key: "interpolation", label: "Interpolation",
                              kind: .choice([Parameter.Option("LINEAR", "Linear"),
                                             Parameter.Option("PATH", "Blend Path"),
                                             Parameter.Option("SURFACE", "Blend Surface")]),
                              value: 0, softMin: 0, softMax: 2, step: 0.02)]
            case .smooth:
                return [
                    Parameter(key: "factor", label: "Smoothing", kind: .float,
                              value: 0.5, softMin: 0, softMax: 1, step: 0.004),
                    Parameter(key: "repeat", label: "Repeat", kind: .integer,
                              value: 1, softMin: 1, softMax: 100, step: 0.05)]
            case .mergeByDistance:
                return [
                    Parameter(key: "threshold", label: "Merge Distance", kind: .float,
                              value: 0.0001, softMin: 0.00001, softMax: 10, step: 0.0005)]
            case .randomize:
                return [
                    Parameter(key: "offset", label: "Amount", kind: .float,
                              value: 0.08, softMin: -10, softMax: 10, step: 0.002),
                    Parameter(key: "uniform", label: "Uniform", kind: .float,
                              value: 0, softMin: 0, softMax: 1, step: 0.004),
                    Parameter(key: "normal", label: "Normal", kind: .float,
                              value: 0, softMin: 0, softMax: 1, step: 0.004),
                    Parameter(key: "seed", label: "Random Seed", kind: .integer,
                              value: 0, softMin: 0, softMax: 50, step: 0.05)]

            // Blender's own defaults from here, except where they do nothing
            // visible: `solidify` and `wireframe` both default to a hundredth
            // of a unit, which on a two-metre cube is a result you have to go
            // looking for. The panel is how it gets changed either way, but the
            // first press should show you what the tool does.
            case .spin:
                return [
                    Parameter(key: "steps", label: "Steps", kind: .integer,
                              value: 12, softMin: 0, softMax: 1000, step: 0.1),
                    Parameter(key: "angle", label: "Angle", kind: .float,
                              value: 2 * .pi, softMin: -2 * .pi, softMax: 2 * .pi,
                              step: 0.01),
                    // Blender's own Spin has both of these and they are what
                    // makes it a modelling tool rather than a lathe. With
                    // Duplicates on it copies the selection instead of
                    // sweeping a surface through it, which is how a wheel gets
                    // spokes, a chainring gets teeth and a hub gets a bolt
                    // circle — one operator instead of one object per spoke.
                    Parameter(key: "dupli", label: "Use Duplicates",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02),
                    // The axis a lathe would use is Z; the axis a wheel turns
                    // on is whichever one points through it.
                    Parameter(key: "axis", label: "Axis",
                              kind: .literal([Parameter.Option("(1.0, 0.0, 0.0)", "X"),
                                              Parameter.Option("(0.0, 1.0, 0.0)", "Y"),
                                              Parameter.Option("(0.0, 0.0, 1.0)", "Z")]),
                              value: 2, softMin: 0, softMax: 2, step: 0.02)]
                    // Where it turns. The object's origin is right for spokes,
                    // whose geometry sits on the hub, and wrong for anything
                    // that orbits a point it does not sit on: gear teeth, a
                    // bolt circle, tyre tread. `mesh(_:spinningAround:)` seeds
                    // it with the origin. Last, so every other field keeps its
                    // place and `center=` stays the call's final argument.
                    // Measured in 5.2.1: the soft range is ±10000, and a cube
                    // at (5,0,0) spun with center=(7,0,0) left every copy 2.0
                    // from (7,0,0) — the point is global, not an offset.
                    // Not `axis` as well, by symmetry: three scrub fields can
                    // reach (0,0,0), which Blender refuses as an unset axis.
                    + Parameter.vector("center", "Center", .zero,
                                       softMin: -10000, softMax: 10000, step: 0.01)
            case .extrude, .extrudeIndividual:
                // Blender's own Extrude Faces Along Normals, and Extrude
                // Individual Faces. A positive offset moves the new geometry
                // out along the face normals. Measured in 5.2.1 on a cube's
                // top face (z = 1): 0.2 left it at z = 1.2 through either
                // macro, -0.2 at z = 0.8 — so the -0.2 Extrude started at
                // until 2026-09-22 pushed the first press into the cube.
                return [
                    Parameter(key: "TRANSFORM_OT_shrink_fatten",
                              label: "Offset", kind: .nested("value"),
                              value: 0.2, softMin: -10, softMax: 10, step: 0.004)]
            case .bisect:
                return [
                    Parameter(key: "plane_no", label: "Axis",
                              kind: .literal([Parameter.Option("(1.0, 0.0, 0.0)", "X"),
                                              Parameter.Option("(0.0, 1.0, 0.0)", "Y"),
                                              Parameter.Option("(0.0, 0.0, 1.0)", "Z")]),
                              value: 2, softMin: 0, softMax: 2, step: 0.02),
                    Parameter(key: "clear_inner", label: "Clear Inner",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02),
                    Parameter(key: "clear_outer", label: "Clear Outer",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .mergeAtCenter:
                return [
                    Parameter(key: "type", label: "Merge",
                              kind: .choice([Parameter.Option("CENTER", "At Center"),
                                             Parameter.Option("COLLAPSE", "Collapse")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .bridgeEdgeLoops:
                return [
                    Parameter(key: "number_cuts", label: "Number of Cuts", kind: .integer,
                              value: 0, softMin: 0, softMax: 64, step: 0.05),
                    Parameter(key: "smoothness", label: "Smoothness", kind: .float,
                              value: 1, softMin: 0, softMax: 2, step: 0.004)]
            case .gridFill:
                return [
                    Parameter(key: "span", label: "Span", kind: .integer,
                              value: 1, softMin: 1, softMax: 100, step: 0.05),
                    Parameter(key: "offset", label: "Offset", kind: .integer,
                              value: 0, softMin: -100, softMax: 100, step: 0.05)]
            case .recalculateNormals:
                return [
                    Parameter(key: "inside", label: "Facing",
                              kind: .literal([Parameter.Option("False", "Outside"),
                                              Parameter.Option("True", "Inside")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .quadify:
                return [
                    Parameter(key: "face_threshold", label: "Max Face Angle", kind: .float,
                              value: 0.698, softMin: 0, softMax: 3.142, step: 0.01),
                    Parameter(key: "shape_threshold", label: "Max Shape Angle", kind: .float,
                              value: 0.698, softMin: 0, softMax: 3.142, step: 0.01)]
            case .dissolveVerts, .dissolveEdges, .dissolveFaces,
                 .fillFace, .flipNormals, .triangulate:
                // Nothing to adjust: they either did the thing or they did not.
                return []
            case .solidify:
                return [
                    Parameter(key: "thickness", label: "Thickness", kind: .float,
                              value: 0.1, softMin: -10, softMax: 10, step: 0.004)]
            case .wireframe:
                return [
                    Parameter(key: "thickness", label: "Thickness", kind: .float,
                              value: 0.05, softMin: 0, softMax: 1, step: 0.002),
                    Parameter(key: "offset", label: "Offset", kind: .float,
                              value: 0.01, softMin: 0, softMax: 10, step: 0.004)]
            case .symmetrize:
                return [
                    Parameter(key: "direction", label: "Direction",
                              kind: .choice([Parameter.Option("NEGATIVE_X", "-X to +X"),
                                             Parameter.Option("POSITIVE_X", "+X to -X"),
                                             Parameter.Option("NEGATIVE_Y", "-Y to +Y"),
                                             Parameter.Option("POSITIVE_Y", "+Y to -Y"),
                                             Parameter.Option("NEGATIVE_Z", "-Z to +Z"),
                                             Parameter.Option("POSITIVE_Z", "+Z to -Z")]),
                              value: 0, softMin: 0, softMax: 5, step: 0.02),
                    Parameter(key: "threshold", label: "Threshold", kind: .float,
                              value: 0.0001, softMin: 0.00001, softMax: 0.1, step: 0.0004)]
            case .poke:
                return [
                    Parameter(key: "offset", label: "Poke Offset", kind: .float,
                              value: 0, softMin: -10, softMax: 10, step: 0.006),
                    Parameter(key: "center_mode", label: "Poke Center",
                              kind: .choice([Parameter.Option("MEDIAN_WEIGHTED", "Weighted Median"),
                                             Parameter.Option("MEDIAN", "Median"),
                                             Parameter.Option("BOUNDS", "Bounds")]),
                              value: 0, softMin: 0, softMax: 2, step: 0.02)]

            // Blender's own names and ranges. Its defaults are all 0, which
            // moves nothing; these start where the result can be seen.
            case .shrinkFatten:
                return [
                    Parameter(key: "value", label: "Offset", kind: .float,
                              value: 0.1, softMin: -10, softMax: 10, step: 0.002)]
            case .pushPull:
                return [
                    Parameter(key: "value", label: "Distance", kind: .float,
                              value: 0.2, softMin: -10, softMax: 10, step: 0.002)]
            case .toSphere:
                return [
                    Parameter(key: "value", label: "Factor", kind: .float,
                              value: 1, softMin: 0, softMax: 1, step: 0.004)]

            // The edge tools. Blender's defaults for these are all 0, which
            // slides nothing and creases nothing, so as above they start where
            // the result shows. Every value is a factor, not a length.
            case .connectVertexPath, .markSeam, .clearSeam, .markSharp, .clearSharp:
                return []
            // Delimit: where a loop or ring stops. Blender takes a set of
            // flags — `delimit_edge_loop` defaults to {OUTER_CORNERS, NGONS},
            // `delimit_edge_ring` to {NGONS} (5.2.1's RNA) — and draws a
            // toggle per flag. Offered here as Blender's default with Seam,
            // Sharp or both added, each keeping the default flags: they are
            // the pair to Mark Seam and Mark Sharp beside them. Measured in
            // 5.2.1 on a 10 × 10 grid, one edge of the middle row picked and
            // the edge three along from it marked: the loop took all 10 edges,
            // and 7 with that edge's flag in the set; a ring with a rung
            // marked took 11, and 8. The other flag in the set changed
            // nothing.
            case .selectEdgeLoops, .selectEdgeRings:
                let key = self == .selectEdgeLoops ? "delimit_edge_loop" : "delimit_edge_ring"
                let base = self == .selectEdgeLoops ? "'NGONS', 'OUTER_CORNERS'" : "'NGONS'"
                return [
                    Parameter(key: key, label: "Delimit",
                              kind: .literal([Parameter.Option("{\(base)}", "Default"),
                                              Parameter.Option("{\(base), 'SEAM'}", "Seam"),
                                              Parameter.Option("{\(base), 'SHARP'}", "Sharp"),
                                              Parameter.Option("{\(base), 'SEAM', 'SHARP'}",
                                                               "Seam and Sharp")]),
                              value: 0, softMin: 0, softMax: 3, step: 0.02)]
            case .edgeSlide:
                // A fraction of the way to the neighbouring loop, its sign
                // choosing the side: measured on a 10 × 10 grid, value 0.5
                // moved an 11-vertex loop 0.1 of a 0.2 spacing, -0.25 moved
                // it 0.05 the other way. Clamp is Blender's default and keeps
                // it on the faces beside it; ±1 is as far as it goes.
                return [
                    Parameter(key: "value", label: "Factor", kind: .float,
                              value: 0.5, softMin: -1, softMax: 1, step: 0.004, unit: .none),
                    // Even gives the loop the shape of a neighbouring loop,
                    // and Flipped picks which neighbour that is — so Flipped
                    // does nothing without Even. Measured in 5.2.1 on a grid
                    // whose next row is tilted: Flipped alone gave exactly the
                    // default result at +0.5 and -0.5, and changed it at both
                    // once Even was on. Its row is greyed until then.
                    Parameter(key: "use_even", label: "Even",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02),
                    Parameter.dependent(
                        Parameter(key: "flipped", label: "Flipped",
                                  kind: .literal([Parameter.Option("False", "Off"),
                                                  Parameter.Option("True", "On")]),
                                  value: 0, softMin: 0, softMax: 1, step: 0.02),
                        on: .init("use_even", is: 1))]
            case .slideVertices:
                return [
                    // 0 to 1, not Blender's soft -1 to 1: with Clamp on, its
                    // default, a negative value moved nothing (measured, -0.5
                    // on a grid vertex). 0.5 moved it half an edge, 0.1 of 0.2.
                    Parameter(key: "value", label: "Factor", kind: .float,
                              value: 0.5, softMin: 0, softMax: 1, step: 0.004, unit: .none),
                    // Which edge it slides along. Blender picks the edge
                    // nearest the pointer; without one it takes `direction`, a
                    // hidden world-space vector, and slides along the edge
                    // pointing most nearly that way. Measured: on a grid,
                    // (0, 1, 0) slid +Y and (-1, 0, 0) slid -X; with the grid
                    // turned 90° about Z, (0, 1, 0) slid along its local +X —
                    // world +Y. Not given at all, it took an edge of its own.
                    Parameter(key: "direction", label: "Direction",
                              kind: .literal([Parameter.Option("(1.0, 0.0, 0.0)", "+X"),
                                              Parameter.Option("(-1.0, 0.0, 0.0)", "-X"),
                                              Parameter.Option("(0.0, 1.0, 0.0)", "+Y"),
                                              Parameter.Option("(0.0, -1.0, 0.0)", "-Y"),
                                              Parameter.Option("(0.0, 0.0, 1.0)", "+Z"),
                                              Parameter.Option("(0.0, 0.0, -1.0)", "-Z")]),
                              value: 0, softMin: 0, softMax: 5, step: 0.02)]
            case .offsetEdgeSlide:
                // The new loops' place between the selection and its
                // neighbours. Measured on a 10 × 10 grid: 0.5 put them at
                // ±0.1 of a 0.2 spacing, 1 on the neighbours, and 0 or any
                // negative value on the selected loop itself — coincident
                // vertices, which is why it does not start there.
                return [
                    Parameter(key: "TRANSFORM_OT_edge_slide", label: "Factor",
                              kind: .nested("value"),
                              value: 0.5, softMin: 0, softMax: 1, step: 0.004, unit: .none)]
            case .edgeCrease, .bevelWeight:
                // Added to what the edge had and held to 0...1 (measured:
                // 0.5, then 0.3, read 0.8; another 0.5 read 1; -0.25 then
                // read 0.75), so a negative value takes weight away. 1 is
                // what a modeller types for a hard subdivision edge.
                return [
                    Parameter(key: "value", label: "Factor", kind: .float,
                              value: 1, softMin: -1, softMax: 1, step: 0.004, unit: .none)]

            // Round 3's rows. Names, defaults and soft ranges are 5.2.1's RNA
            // (`get_rna_type()`), and each count below was measured there.
            case .splitSelection:
                // No properties: four faces of a 7 × 7 grid split off as
                // their own island, 49 vertices to 54.
                return []
            case .edgeSplitEdges, .edgeSplitVertices:
                // A whole 7 × 7 grid: 49 vertices to 144 either way; four of
                // its faces alone, 49 to 61 by edges.
                return [
                    Parameter(key: "type", label: "Type",
                              kind: .choice([Parameter.Option("EDGE", "Faces by Edges"),
                                             Parameter.Option("VERT", "Faces & Edges by Vertices")]),
                              value: self == .edgeSplitVertices ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)]
            case .unsubdivide:
                // A 7 × 7 grid: 49 vertices to 22 at 2, 28 at 1.
                return [
                    Parameter(key: "iterations", label: "Iterations", kind: .integer,
                              value: 2, softMin: 1, softMax: 100, step: 0.05)]
            case .beautifyFaces:
                // It turns edges and never adds any: on a wavy 6 × 6 grid
                // triangulated the fixed way it turned 18 of 120 edges, and
                // on one triangulated by Beauty none.
                return [
                    Parameter(key: "angle_limit", label: "Max Angle", kind: .float,
                              value: .pi, softMin: 0, softMax: .pi, step: 0.005, unit: .degrees)]
            case .limitedDissolve:
                // A flat 7 × 7 grid dissolves to its 4 corners and one face.
                // Delimit (Normal by default) is left at Blender's default.
                return [
                    Parameter(key: "angle_limit", label: "Max Angle", kind: .float,
                              value: 5 * .pi / 180, softMin: 0, softMax: .pi, step: 0.005, unit: .degrees),
                    Parameter(key: "use_dissolve_boundaries", label: "All Boundaries",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .deleteLoose:
                // A cube with a loose edge and a loose vertex: 11 vertices
                // to 8 ("Removed: 3 vertices, 1 edges, 0 faces").
                func toggle(_ key: String, _ label: String, _ on: Bool) -> Parameter {
                    Parameter(key: key, label: label,
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: on ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
                }
                return [toggle("use_verts", "Vertices", true), toggle("use_edges", "Edges", true),
                        toggle("use_faces", "Faces", false)]
            case .fillHoles:
                // A cube missing a face: filled at 4 and at 0 (any number of
                // sides), left open at 3.
                return [
                    Parameter(key: "sides", label: "Sides", kind: .integer,
                              value: 4, softMin: 0, softMax: 100, step: 0.05)]
            }
        }
    }

    static func mesh(_ op: Mesh) -> LastOperator {
        mesh(op, spinningAround: nil)
    }

    /// `origin` is the edited object's world position, which is where Spin
    /// turns until its panel says otherwise. `mesh.spin` measures `center` in
    /// global space, so a wheel built at y = 7 spun around the world origin
    /// and left the scene.
    ///
    /// `symmetry` is the edited mesh's, as the mirror holds it — nil when no
    /// mesh is being edited. An operator that honours it in Blender
    /// (`honoursMeshSymmetry`) is sent `mirror=True` whenever a mesh is, axis
    /// on or not, as Blender's own 3D View runs it: there `initTransInfo`
    /// leaves mirroring on for an edit mesh and `saveTransform` stores
    /// `mirror=True` (transform.cc), so a redo reads the mesh's flags as they
    /// are then. A headless Blender mirrors only when told (T_NO_MIRROR with
    /// no 3D View), and with every axis off `mirror=True` mirrors nothing
    /// (the axes are the mesh's, transform_convert.cc). Sent only with an axis
    /// on, X turned on with the redo panel open was not mirrored on adjusting.
    static func mesh(_ op: Mesh, spinningAround origin: SIMD3<Float>?,
                     symmetry: MeshSymmetry? = nil) -> LastOperator {
        var made = LastOperator(name: op.displayName, call: op.call,
                                parameters: op.parameters, location: nil,
                                restoration: .restoreMesh, needsEditMode: true)
        made.fixedArguments = op.fixedArguments
        if op.honoursMeshSymmetry, symmetry != nil {
            made.fixedArguments.append("mirror=True")
        }
        made.refusal = op.refusal
        let c = origin ?? .zero
        if op == .spin {
            made["center.x"] = Double(c.x)
            made["center.y"] = Double(c.y)
            made["center.z"] = Double(c.z)
        }
        // Bisect cuts along a plane, and a plane needs a point as well as a
        // normal. Blender's own comes from where the line was drawn; here it
        // is the object's origin, so the cut goes through the middle of the
        // thing being cut rather than through the world origin.
        if op == .bisect {
            made.fixedArguments.append(
                "plane_co=(\(number(Double(c.x))), \(number(Double(c.y))), \(number(Double(c.z))))")
        }
        made.lead = op.lead
        return made
    }
}

// MARK: - Object operators

public extension LastOperator {

    /// Object ▸ Shade Auto Smooth: Blender's "Smooth by Angle" Geometry Nodes
    /// modifier on each selected object, faces smooth and edges sharp past
    /// the angle. Measured in 5.2.1: FINISHED in under 0.04 s, one modifier
    /// named "Smooth by Angle" whose Angle input is the operator's `angle`;
    /// run again on an object that has it, it sets that angle rather than
    /// adding a second (asked for 60 degrees, the input read 60).
    ///
    /// The node group comes from Blender's Essentials asset library, which the
    /// bpy staged into this app does not ship, and without it the operator
    /// fails with "No asset found at path". `needs_essentials` says that in
    /// words, and names Shade Smooth by Angle, which needs no library.
    static func shadeAutoSmooth() -> LastOperator {
        var op = LastOperator(name: "Shade Auto Smooth", call: "bpy.ops.object.shade_auto_smooth",
                              parameters: [smoothingAngle], restoration: .restoreMesh)
        // It acts on the selection, and with no mesh selected — the active
        // one deselected, which is what H leaves — it returns FINISHED having
        // added no modifier and smoothed no face (5.2.1, measured; with only
        // a camera selected too, after a warning that it takes no modifiers).
        // So the refusal comes first: afterwards the two cannot be told apart.
        op.lead = Bpy.needsAMesh(for: "Shade Auto Smooth") + "\n" + Self.needsSelectedMesh("Shade Auto Smooth")
            + "\nimport _blenderkit_context"
        op.within = "_blenderkit_context.needs_essentials('Shade Auto Smooth', "
            + "'Shade Smooth by Angle does the same once, without a modifier.')"
        return op
    }

    /// Shade Smooth by Angle: the same result as Auto Smooth, written into the
    /// mesh once — sharp edges marked past the angle, every face smooth — with
    /// no modifier and no asset library. Blender's own operator, in its F3
    /// search rather than its menus.
    static func shadeSmoothByAngle() -> LastOperator {
        var op = LastOperator(
            name: "Shade Smooth by Angle", call: "bpy.ops.object.shade_smooth_by_angle",
            parameters: [
                smoothingAngle,
                Parameter(key: "keep_sharp_edges", label: "Keep Sharp Edges",
                          kind: .literal([Parameter.Option("False", "Off"),
                                          Parameter.Option("True", "On")]),
                          value: 1, softMin: 0, softMax: 1, step: 0.02)],
            restoration: .restoreMesh)
        op.lead = Bpy.needsAMesh(for: "Shade Smooth by Angle")
        // With no mesh selected it returns CANCELLED and raises nothing
        // (5.2.1: the active sphere deselected, and a camera alone selected).
        op.refusal = "Shade Smooth by Angle acts on the selected meshes, and none is selected. "
            + "Select a mesh first."
        op.actsOnSelection = true
        return op
    }

    /// Refuses an object operator that acts on the selection when no mesh
    /// is selected; the active object can be a mesh that is not.
    private static func needsSelectedMesh(_ what: String) -> String {
        """
        if not any(o.type == 'MESH' for o in bpy.context.selected_editable_objects):
            raise RuntimeError(\(Bpy.quote(what + " acts on the selected meshes, and none is selected. Select a mesh first.")))
        """
    }

    /// Blender's 30 degrees, its range 0 to 180, in degrees on the field.
    private static var smoothingAngle: Parameter {
        Parameter(key: "angle", label: "Angle", kind: .float,
                  value: 30 * .pi / 180, softMin: 0, softMax: .pi, step: 0.005,
                  unit: .degrees)
    }

    /// QuadriFlow Remesh, which Blender keeps under Object Data ▸ Remesh:
    /// the active mesh rebuilt as quads, aiming at a number of faces.
    ///
    /// Measured in 5.2.1 headless, every face a quad: a UV sphere at the
    /// default 4000 gave 4091 in 0.97 s, at 1000 gave 1064 in 0.18 s; a cube
    /// at 1000 gave 1014, Suzanne 999, a torus at 2000 gave 1719. Object mode
    /// only (its poll is False in edit mode), meshes only, the active object
    /// only. A modifier on it stays and applies over the new surface.
    ///
    /// Mode is pinned to FACES: RATIO asked for 0.5 of a 512-face sphere gave
    /// the same 4091 faces as the default, so a Ratio field would move nothing.
    static func quadriflowRemesh() -> LastOperator {
        func toggle(_ key: String, _ label: String, _ on: Bool) -> Parameter {
            Parameter(key: key, label: label,
                      kind: .literal([Parameter.Option("False", "Off"),
                                      Parameter.Option("True", "On")]),
                      value: on ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
        }
        var op = LastOperator(
            name: "QuadriFlow Remesh", call: "bpy.ops.object.quadriflow_remesh",
            parameters: [
                Parameter(key: "target_faces", label: "Number of Faces", kind: .integer,
                          value: 4000, softMin: 10, softMax: 50000, step: 10),
                toggle("use_mesh_symmetry", "Use Mesh Symmetry", true),
                toggle("use_preserve_sharp", "Preserve Sharp", false),
                toggle("use_preserve_boundary", "Preserve Mesh Boundary", false),
                toggle("smooth_normals", "Smooth Normals", false),
                Parameter(key: "seed", label: "Seed", kind: .integer,
                          value: 0, softMin: 0, softMax: 255, step: 0.1)],
            restoration: .restoreMesh)
        op.fixedArguments = ["mode='FACES'"]
        op.lead = Bpy.needsAMesh(for: "QuadriFlow Remesh")
        // Blender refuses a mesh that is not manifold with a warning and
        // `{'CANCELLED'}`, raising nothing (5.2.1: the app's own Add ▸ Circle,
        // 32 vertices and no face, and a cube with one face flipped; an open
        // grid is accepted). Its test (`mesh_is_manifold_consistent`) fails
        // on an edge with no face or with more than two, a face flipped
        // against its neighbour, or an edge of zero length. Without this the
        // refusal read as done: an undo step and a Number of Faces that moved
        // nothing. Its other failure, "Remeshing failed", is an error Blender
        // raises itself.
        op.refusal = "QuadriFlow Remesh needs a manifold mesh with consistent normals: "
            + "every edge in one or two faces, neighbouring faces pointing the same way, "
            + "and no edge of zero length. A wire such as Add ▸ Circle has no faces to remesh."
        return op
    }
}

// MARK: - Knife Project

public extension LastOperator {

    /// Blender's Knife Project: the outline of another object, cut into the
    /// mesh being edited.
    ///
    /// Blender projects it along the 3D View's line of sight. There is no view
    /// to look along here, so `_blenderkit_knife.projecting` aims Blender's own
    /// — orthographic, along the cutter's normal, toward the mesh — for the
    /// duration of the call, and puts it back. Measured in 5.2.1 headless, a
    /// 32-sided circle cut a plane and each face of a cube with every new
    /// vertex on the circle to within 1e-6; the rest of what was measured is
    /// in that module's docstring. `knife_tool`, the drawn knife, is still
    /// modal and still refuses.
    ///
    /// Cut Through is the one property Blender's own redo panel offers for it,
    /// and the only argument the operator takes.
    static func knifeProject(cutter: String) -> LastOperator {
        var made = LastOperator(
            name: "Knife Project", call: "bpy.ops.mesh.knife_project",
            parameters: [
                Parameter(key: "cut_through", label: "Cut Through",
                          kind: .literal([Parameter.Option("False", "Off"),
                                          Parameter.Option("True", "On")]),
                          value: 0, softMin: 0, softMax: 1, step: 0.02)],
            restoration: .restoreMesh, needsEditMode: true)
        made.lead = "import _blenderkit_knife"
        made.within = "_blenderkit_knife.projecting(\(Bpy.quote(cutter)))"
        return made
    }
}
