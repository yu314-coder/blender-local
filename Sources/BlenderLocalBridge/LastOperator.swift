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
            /// One item of an argument Blender takes as a set of flags (an
            /// enum flag, `delimit={'SEAM', 'SHARP'}`), shown as a toggle of
            /// its own under the heading Blender's panel draws over the row
            /// ('Delimit'), as Blender draws a toggle button per item, and
            /// composed with its siblings into the one keyword: the set of
            /// the items that are on, or `set()`. `value` is 0 or 1.
            case flag(keyword: String, heading: String, identifier: String)
            /// One axis of an argument Blender takes as a vector of booleans,
            /// `constraint_axis=(True, False, False)`, drawn as a toggle of its
            /// own under the heading Blender's panel draws ('Constraint Axis')
            /// and composed with its siblings into the one keyword, as a
            /// `component` is. `value` is 0 or 1.
            case toggle(keyword: String, heading: String, axis: Int)
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
            /// Active while the other row does *not* hold `value`. (Loop Cut
            /// and Slide's Falloff used it at Smoothness 0, where it changes
            /// nothing; Blender's panel greys it there all the same, so it no
            /// longer does: round 4's review of Loop Cut.)
            public var negated = false
            public init(_ key: String, is value: Double) { self.key = key; self.value = value }
            public init(_ key: String, isNot value: Double) {
                self.key = key; self.value = value; self.negated = true
            }
        }

        public var id: String { key }

        /// The macro sub-operator this argument belongs to, when the call
        /// takes it inside that sub-operator's dictionary:
        /// `MESH_OT_loopcut={"number_cuts": 2, "smoothness": 0, ...}`. Every
        /// argument of one sub-operator becomes one keyword between them, as
        /// a vector's components do (`LastOperator.python`); one per argument
        /// would give Python `MESH_OT_loopcut=` twice, which it refuses. Nil
        /// for an argument of the operator itself.
        public var member: String?

        /// How many places the call carries the number to, and whether it
        /// keeps trailing zeros. Four, trimmed, for most operators, as
        /// Blender's Info log writes them. A gizmo's Move keeps six while it
        /// can snap to geometry (`TransformGizmo.places`), and Proportional
        /// Size five: what the preview ran is what the call says, digit for
        /// digit, and four places put a snapped vertex up to 5e-5 beside its
        /// target. The gizmo's values keep their zeros, as its log always has
        /// (`value=(0.5000, 0.0000, 0.0000)`).
        public var places = 4
        public var keepsZeros = false

        /// The row this one is drawn only beside: while the other row does
        /// not hold the value, Blender's panel leaves this one out, rather
        /// than greying it (`activeWhen`). Blender's transform operators hide
        /// Proportional Falloff, Size, Connected and Projected (2D) while
        /// Proportional Editing is off (`transform_poll_property`,
        /// transform_ops.cc). The argument is still sent.
        public var shownWhen: Condition?

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
            case .integer, .choice, .literal, .flag, .toggle: return (clamped).rounded()
            case .nested, .component: return clamped
            }
        }

        /// This argument as it appears inside the call — inside its
        /// sub-operator's dictionary, `"number_cuts": 2`, for a `member`.
        public var python: String {
            if member != nil { return "\"\(key)\": \(literal)" }
            switch kind {
            case .float:
                return "\(key)=\(formatted)"
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
                return formatted
            case .flag(_, _, let identifier):
                // Its share of the set, the same way.
                return settled != 0 ? "'\(identifier)'" : ""
            case .toggle:
                // Its share of the tuple, as a component's.
                return settled != 0 ? "True" : "False"
            }
        }

        /// The value alone, as the call carries it: `2`, `0.5`, `'LINEAR'`,
        /// `True`. What a lead's `@arg:<key>@` is replaced with.
        public var literal: String {
            switch kind {
            case .float, .component:
                return formatted
            case .integer:
                return String(Int(settled))
            case .choice(let options):
                let i = min(max(Int(settled), 0), options.count - 1)
                return "'\(options[i].identifier)'"
            case .literal(let options):
                let i = min(max(Int(settled), 0), options.count - 1)
                return options[i].identifier
            case .nested(let inner):
                return "{\"\(inner)\": \(LastOperator.number(settled))}"
            case .flag, .toggle:
                return settled != 0 ? "True" : "False"
            }
        }

        /// The number as the call carries it, at this row's precision.
        var formatted: String {
            keepsZeros ? LastOperator.fixed(settled, places: places)
                       : LastOperator.number(settled, places: places)
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
            case .flag, .toggle: return settled != 0 ? "On" : "Off"
            }
        }

        /// The items of an enum-flag argument, one toggle each, keyed
        /// `keyword.IDENTIFIER` and labelled as Blender labels the item; those
        /// in `on` start on (Blender's default set).
        public static func flags(_ keyword: String, _ heading: String,
                                 _ items: [(identifier: String, label: String)],
                                 on: Set<String>) -> [Parameter] {
            items.map { item in
                Parameter(key: "\(keyword).\(item.identifier)", label: item.label,
                          kind: .flag(keyword: keyword, heading: heading, identifier: item.identifier),
                          value: on.contains(item.identifier) ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
            }
        }

        /// The keyword this row is one axis of, for a vector of numbers
        /// (`component`) or of booleans (`toggle`); nil otherwise.
        public var vectorKeyword: String? {
            switch kind {
            case .component(let keyword, _, _), .toggle(let keyword, _, _): return keyword
            default: return nil
            }
        }

        /// A vector of booleans as the three toggles Blender's panel draws
        /// for it — Mirror's Constraint Axis — keyed `keyword.x`, `.y`, `.z`
        /// and labelled X, Y, Z.
        public static func toggles(_ keyword: String, _ heading: String, _ on: [Bool]) -> [Parameter] {
            ["X", "Y", "Z"].enumerated().map { axis, label in
                Parameter(key: "\(keyword).\(label.lowercased())", label: label,
                          kind: .toggle(keyword: keyword, heading: heading, axis: axis),
                          value: on.indices.contains(axis) && on[axis] ? 1 : 0,
                          softMin: 0, softMax: 1, step: 0.02)
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
                                  step: Double, unit: NumberFieldUnit = .meters) -> [Parameter] {
            ["X", "Y", "Z"].enumerated().map { axis, label in
                Parameter(key: "\(keyword).\(label.lowercased())", label: label,
                          kind: .component(keyword: keyword, heading: heading, axis: axis),
                          value: value[axis], softMin: softMin, softMax: softMax, step: step,
                          unit: unit)
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

    /// Positional arguments, written before every keyword: the kind of
    /// transform `_blenderkit_tools.transform_individual('ROTATE', …)` runs.
    public var leadingArguments: [String] = []

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

    /// What to say when Blender returns FINISHED having changed nothing — no
    /// vertex, edge or face added, removed or moved in the mesh being edited
    /// (`_blenderkit_loopcut.edit_state`) — raised in its place. Like
    /// `refusal`, kept out of the Info log's line.
    public var unchanged: String?

    /// What to say when Blender returns FINISHED having changed no selection
    /// flag and not the selection order on the meshes being edited
    /// (`_blenderkit_select.refuse_unchanged_selection`), raised in its place.
    /// Select Next Element and Select Previous Element answer FINISHED with
    /// nothing to walk from, their "Selection pair not found" a report a bpy
    /// module cannot read (measured in 5.2.1). Kept out of the Info log's
    /// line, like `refusal`.
    public var unchangedSelection: String?

    /// A statement of the app's own run after the call and kept out of the
    /// Info log's line, like `refusal`: auto keying's word on what it could
    /// not key after a gizmo transform (`Bpy.autoKeying`), which `bridge.run`
    /// used to add the same way. Re-run with the call by the redo panel.
    public var afterward: String?

    /// A context manager of `_blenderkit_select` the call runs inside that
    /// is the app's guard and not part of the action — the Object Mode
    /// Select rows' `object_select`, which refuses first what needs an active
    /// object and puts back what a CANCELLED changed on the way. Kept out of
    /// the Info log's line, like `refusal`: the log reads
    /// `bpy.ops.object.select_linked(extend=False, type='MATERIAL')`.
    public var guardWithin: String?

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

    /// Arguments of a macro's sub-operator the panel does not offer, written
    /// into that sub-operator's dictionary after the panel's own (`Parameter.member`):
    /// Loop Cut and Slide's `"edge_index"` and `"object_index"`, which name
    /// the edge that was picked and are hidden in Blender's panel too.
    public var memberArguments: [String: [String]] = [:]

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
        var args: [String] = leadingArguments
        var composed = Set<String>()
        for parameter in parameters {
            if let member = parameter.member {
                // Once per sub-operator, like a vector's components.
                guard composed.insert("member:" + member).inserted else { continue }
                args.append(memberArgument(member))
                continue
            }
            if case .flag(let keyword, _, _) = parameter.kind {
                guard composed.insert("flag:" + keyword).inserted else { continue }
                args.append(flagArgument(keyword))
                continue
            }
            guard let keyword = parameter.vectorKeyword else {
                args.append(parameter.python)
                continue
            }
            // Once per group: Python refuses `center=` given twice.
            guard composed.insert(keyword).inserted else { continue }
            args.append(vectorArgument(keyword))
        }
        // A sub-operator whose every argument is fixed.
        for member in memberArguments.keys.sorted() where !composed.contains("member:" + member) {
            args.append(memberArgument(member))
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
        if refusing, let unchanged {
            // Counts, positions and edges (`edit_state`): a row may move
            // vertices or turn edges and add none.
            line = "import _blenderkit_loopcut as _bk_lc\n_bk_counts = _bk_lc.edit_state()\n" + line
                + "\nif _bk_lc.edit_state() == _bk_counts:\n    raise RuntimeError(\(Bpy.quote(unchanged)))"
        }
        if refusing, let guardWithin {
            line = "import _blenderkit_select\nwith _blenderkit_select.\(guardWithin):\n"
                + line.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        }
        if refusing, let unchangedSelection {
            line = "with _bk_select.refuse_unchanged_selection(\(Bpy.quote(unchangedSelection))):\n"
                + line.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
            line = "import _blenderkit_select as _bk_select\n" + line
        }
        if let within {
            // Every line of the call goes inside the block, not only the
            // first: with a refusal the call is two.
            line = "with \(within):\n"
                + line.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        }
        if let lead { line = filled(lead) + "\n" + line }
        if refusing, let afterward { line += "\n" + afterward }
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
            let value = parameter.member != nil ? parameter.literal
                : python.hasPrefix(parameter.key + "=")
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

    /// Every argument of the macro sub-operator `member`, as the one
    /// dictionary it takes: the panel's rows in their order, then
    /// `memberArguments`.
    private func memberArgument(_ member: String) -> String {
        // A vector of a sub-operator — Extrude Manifold's and Extend
        // Vertices' Move, `TRANSFORM_OT_translate={"value": (0, 0, 0.2)}` —
        // is one entry of the dictionary, as a vector of the operator itself
        // is one keyword (`vectorArgument`).
        var entries: [String] = []
        var composed = Set<String>()
        for parameter in parameters where parameter.member == member {
            guard let keyword = parameter.vectorKeyword else {
                entries.append(parameter.python)
                continue
            }
            guard composed.insert(keyword).inserted else { continue }
            entries.append("\"\(keyword)\": \(vectorTuple(keyword, member: member))")
        }
        entries += memberArguments[member] ?? []
        return "\(member)={\(entries.joined(separator: ", "))}"
    }

    /// Every item of the enum flag `keyword` that is on, as the one set they
    /// make — `set()` when none is, which is how Python writes an empty set.
    private func flagArgument(_ keyword: String) -> String {
        let on = parameters.compactMap { parameter -> String? in
            guard case .flag(let k, _, _) = parameter.kind, k == keyword else { return nil }
            let item = parameter.python
            return item.isEmpty ? nil : item
        }
        return on.isEmpty ? "\(keyword)=set()" : "\(keyword)={\(on.joined(separator: ", "))}"
    }

    /// Every component of `keyword`, as the one argument they make. An axis
    /// nothing supplies reads 0; `Parameter.vector` always makes all three.
    private func vectorArgument(_ keyword: String) -> String {
        "\(keyword)=\(vectorTuple(keyword, member: nil))"
    }

    /// The components of `keyword` belonging to `member` (nil: the operator's
    /// own), as the tuple they make. An axis no row supplies is 0: Extrude
    /// Manifold's Move is constrained to its normal's Z and offers that one.
    private func vectorTuple(_ keyword: String, member: String?) -> String {
        // A vector of booleans (`.toggle`) reads False where no row supplies it.
        let switches = parameters.contains {
            if case .toggle(let k, _, _) = $0.kind { return k == keyword && $0.member == member }
            return false
        }
        var slots = Array(repeating: switches ? "False" : "0", count: 3)
        for parameter in parameters where parameter.member == member {
            if case .component(let k, _, let axis) = parameter.kind, k == keyword,
               slots.indices.contains(axis) {
                slots[axis] = parameter.formatted
            }
            if case .toggle(let k, _, let axis) = parameter.kind, k == keyword,
               slots.indices.contains(axis) {
                slots[axis] = parameter.literal
            }
        }
        return "(\(slots.joined(separator: ", ")))"
    }

    /// A parameter by key, for tests and for the panel's bindings.
    /// Whether a row changes the result given the others' values: false
    /// greys it in the panel. See `Parameter.activeWhen`.
    public func isActive(_ parameter: Parameter) -> Bool {
        guard let condition = parameter.activeWhen else { return true }
        return (self[condition.key] == condition.value) != condition.negated
    }

    /// Whether Blender's panel draws the row given the others' values. See
    /// `Parameter.shownWhen`.
    public func isShown(_ parameter: Parameter) -> Bool {
        guard let condition = parameter.shownWhen else { return true }
        return (self[condition.key] == condition.value) != condition.negated
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
    static func number(_ v: Double, places: Int = 4) -> String {
        if abs(v) < 0.5 * pow(10, -Double(places)) { return "0" }
        let s = String(format: "%.\(places)f", v)
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty || t == "-" ? "0" : t
    }
}

public extension LastOperator {
    /// `%.<places>f`, zeros kept, and never `-0.0000`: what the gizmo's
    /// calls have always printed.
    static func fixed(_ v: Double, places: Int) -> String {
        let s = String(format: "%.\(places)f", v)
        return s.hasPrefix("-") && Double(s) == 0 ? String(s.dropFirst()) : s
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
    /// Not every operator belongs here. Loop Cut and Slide and the Knife are
    /// tools: their arguments come from where the pointer went — the edge,
    /// the path — so they are made where the picking is
    /// (`LastOperator.loopCutAndSlide`, `.knife`, CutTools.swift) and their
    /// panels re-run them on that same edge or path. `extrude_region_move`
    /// carries a translation rather than a shape.
    enum Mesh: String, CaseIterable, Sendable {
        case bevel, inset, subdivide, subdivideEdgeRing, smooth, mergeByDistance, randomize
        case spin, solidify, wireframe, symmetrize, poke
        case shrinkFatten, pushPull, toSphere
        // The ones a modelling course teaches on day one, and which were
        // missing: extrude is the backbone of box modelling, bisect is the
        // cut Blender can make without a pointer, and the rest are the
        // clean-up half of the job — dissolving what a cut left behind,
        // closing a hole, getting the normals facing out.
        case extrude, bisect
        // Blender's Extrude menu has it after Extrude Faces Along Normals
        // (`Group.rows` holds each menu's order).
        case extrudeIndividual
        case dissolveVerts, dissolveEdges, dissolveFaces
        case mergeAtCenter, bridgeEdgeLoops, gridFill, fillFace
        case recalculateNormals, flipNormals
        // Mesh ▸ Shading's first two rows (VIEW3D_MT_edit_mesh_shading):
        // the selected faces drawn smooth or flat, the face-by-face version
        // of Object ▸ Shade Smooth and Shade Flat. Measured in 5.2.1
        // without a window: one face of a cube smooth, the rest left alone.
        case shadeSmoothFaces, shadeFlatFaces
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
        // name through the Operator Search. Each measured working headless in
        // 5.2.1 with the app's context (docs/blender-local.md, 2026-09-22,
        // "Join, Parent, Convert and the clean-up rows").
        case bevelVertices
        case splitSelection, edgeSplitEdges, edgeSplitVertices
        case unsubdivide, beautifyFaces
        case limitedDissolve, deleteLoose, fillHoles
        // Round 4, group 6: the rest of the rows round 3's review found only
        // the Operator Search reached (critic section 4, items 9 and 14),
        // each measured in desktop 5.2.1 with the app's context
        // (docs/blender-local.md, 2026-10-19). Merge's other four types.
        case mergeAtCursor, mergeCollapse, mergeAtFirst, mergeAtLast
        // Delete's: `mesh.delete` by type, then Collapse Edges & Faces and
        // Edge Loops.
        case deleteVertices, deleteEdges, deleteFaces, deleteEdgesFaces, deleteOnlyFaces
        case collapseEdgesFaces, deleteEdgeLoops
        // Vertex: Connect Vertex Pairs, Rip Vertices and Extend (from the 3D
        // cursor, `MeshPointer`), Smooth Vertices (Laplacian).
        case connectVertexPairs, ripVerticesExtend, smoothLaplacian
        // Edge: Rotate Edge CW and CCW.
        case rotateEdgeCW, rotateEdgeCCW
        // Face: Intersect (Knife), Intersect (Boolean), Weld Edges into Faces.
        case intersectKnife, intersectBoolean, weldEdgesIntoFaces
        // The Mesh menu's own rows: Convex Hull, Snap to Symmetry.
        case convexHull, symmetrySnap
        // Normals: Recalculate Inside, Set from Faces, Point to Target…,
        // Average ▸ (its three types), Smooth Vectors.
        case recalculateInside, setNormalsFromFaces, pointNormals
        case averageCustomNormal, averageFaceArea, averageCornerAngle, smoothNormals
        // Extrude: Extrude Manifold.
        case extrudeManifold

        /// The operator's own name — `get_rna_type().name` in 5.2.1 — which is
        /// what Blender's Adjust Last Operation panel is titled and what its
        /// undo history calls the step (measured: an operator called with its
        /// undo on pushes a step of exactly this name; docs/blender-names.md).
        /// A macro is named as a macro: Extrude is Blender's "Extrude Region
        /// and Shrink/Fatten", and Clear Seam is `mark_seam(clear=True)`, so
        /// its step is "Mark Seam", as in Blender.
        public var displayName: String {
            switch self {
            case .bevel:           return "Bevel"
            case .inset:           return "Inset Faces"
            case .subdivide:       return "Subdivide"
            case .subdivideEdgeRing: return "Subdivide Edge-Ring"
            case .smooth:          return "Smooth Vertices"
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
            case .extrude:            return "Extrude Region and Shrink/Fatten"
            case .bisect:             return "Bisect"
            case .dissolveVerts:      return "Dissolve Vertices"
            case .dissolveEdges:      return "Dissolve Edges"
            case .dissolveFaces:      return "Dissolve Faces"
            case .mergeAtCenter:      return "Merge"
            case .bridgeEdgeLoops:    return "Bridge Edge Loops"
            case .gridFill:           return "Grid Fill"
            case .fillFace:           return "Make Edge/Face"
            case .recalculateNormals: return "Recalculate Normals"
            case .flipNormals:        return "Flip Normals"
            case .shadeSmoothFaces:   return "Shade Smooth"
            case .shadeFlatFaces:     return "Shade Flat"
            case .triangulate:        return "Triangulate Faces"
            case .quadify:            return "Triangles to Quads"
            case .selectEdgeLoops:    return "Multi Select Edge Loops"
            case .selectEdgeRings:    return "Multi Select Edge Rings"
            case .connectVertexPath:  return "Vertex Connect Path"
            case .slideVertices:      return "Vertex Slide"
            case .edgeSlide:          return "Edge Slide"
            case .offsetEdgeSlide:    return "Offset Edge Slide"
            case .bevelWeight:        return "Edge Bevel Weight"
            case .edgeCrease:         return "Edge Crease"
            case .markSeam, .clearSeam:   return "Mark Seam"
            case .markSharp, .clearSharp: return "Mark Sharp"
            // Bevel Vertices is `mesh.bevel`, and Blender's panel over it
            // reads "Bevel", with Affect set to Vertices.
            case .bevelVertices:      return "Bevel"
            case .extrudeIndividual:  return "Extrude Individual Faces and Move"
            case .splitSelection:     return "Split"
            case .edgeSplitEdges, .edgeSplitVertices: return "Edge Split"
            case .unsubdivide:        return "Un-Subdivide"
            case .beautifyFaces:      return "Beautify Faces"
            case .limitedDissolve:    return "Limited Dissolve"
            case .deleteLoose:        return "Delete Loose"
            case .fillHoles:          return "Fill Holes"
            // `get_rna_type().name` in 5.2.1 (and in the 5.3 source the app's
            // bpy is built from): one Merge for its five types, one Delete for
            // its five, and the macros by their own names.
            case .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast: return "Merge"
            case .deleteVertices, .deleteEdges, .deleteFaces, .deleteEdgesFaces, .deleteOnlyFaces:
                return "Delete"
            case .collapseEdgesFaces: return "Collapse Edges & Faces"
            case .deleteEdgeLoops:    return "Delete Edge Loop"
            case .connectVertexPairs: return "Vertex Connect"
            case .ripVerticesExtend:  return "Extend Vertices"
            case .smoothLaplacian:    return "Laplacian Smooth Vertices"
            case .rotateEdgeCW, .rotateEdgeCCW: return "Rotate Selected Edge"
            case .intersectKnife:     return "Intersect (Knife)"
            case .intersectBoolean:   return "Intersect (Boolean)"
            case .weldEdgesIntoFaces: return "Weld Edges into Faces"
            case .convexHull:         return "Convex Hull"
            case .symmetrySnap:       return "Snap to Symmetry"
            case .recalculateInside:  return "Recalculate Normals"
            case .setNormalsFromFaces: return "Set Normals from Faces"
            case .pointNormals:       return "Point Normals to Target"
            case .averageCustomNormal, .averageFaceArea, .averageCornerAngle: return "Average Normals"
            case .smoothNormals:      return "Smooth Normals Vectors"
            case .extrudeManifold:    return "Extrude Manifold"
            }
        }

        /// What the row says in the menu: the label Blender's own menu gives
        /// it (space_view3d.py, 5.2.1; tests/names/reference), which is often
        /// not the operator's name — Bevel Edges and Bevel Vertices are both
        /// `mesh.bevel`, and Select ▸ Select Loops ▸ Edge Loops is
        /// `select_edge_loop_multi`.
        public var menuLabel: String {
            switch self {
            case .bevel:              return "Bevel Edges"
            case .mergeByDistance:    return "By Distance"
            case .solidify:           return "Solidify Faces"
            case .extrude:            return "Extrude Faces Along Normals"
            case .mergeAtCenter:      return "At Center"
            case .fillFace:           return "New Edge/Face from Vertices"
            case .recalculateNormals: return "Recalculate Outside"
            case .flipNormals:        return "Flip"
            case .shadeSmoothFaces:   return "Smooth Faces"
            case .shadeFlatFaces:     return "Flat Faces"
            case .selectEdgeLoops:    return "Edge Loops"
            case .selectEdgeRings:    return "Edge Rings"
            case .connectVertexPath:  return "Connect Vertex Path"
            case .slideVertices:      return "Slide Vertices"
            case .clearSeam:          return "Clear Seam"
            case .clearSharp:         return "Clear Sharp"
            case .bevelVertices:      return "Bevel Vertices"
            case .extrudeIndividual:  return "Extrude Individual Faces"
            case .splitSelection:     return "Selection"
            case .edgeSplitEdges:     return "Faces by Edges"
            case .edgeSplitVertices:  return "Faces & Edges by Vertices"
            case .mergeAtCursor:      return "At Cursor"
            case .mergeCollapse:      return "Collapse"
            case .mergeAtFirst:       return "At First"
            case .mergeAtLast:        return "At Last"
            case .deleteVertices:     return "Vertices"
            case .deleteEdges:        return "Edges"
            case .deleteFaces:        return "Faces"
            case .deleteEdgesFaces:   return "Only Edges & Faces"
            case .deleteOnlyFaces:    return "Only Faces"
            case .deleteEdgeLoops:    return "Edge Loops"
            case .connectVertexPairs: return "Connect Vertex Pairs"
            case .ripVerticesExtend:  return "Rip Vertices and Extend"
            case .smoothLaplacian:    return "Smooth Vertices (Laplacian)"
            case .rotateEdgeCW:       return "Rotate Edge CW"
            case .rotateEdgeCCW:      return "Rotate Edge CCW"
            case .recalculateInside:  return "Recalculate Inside"
            case .setNormalsFromFaces: return "Set from Faces"
            // Blender draws "...", the platform "…" (docs/blender-names.md).
            case .pointNormals:       return "Point to Target…"
            case .averageCustomNormal: return "Custom Normal"
            case .averageFaceArea:    return "Face Area"
            case .averageCornerAngle: return "Corner Angle"
            case .smoothNormals:      return "Smooth Vectors"
            default:                  return displayName
            }
        }

        /// The row as a sentence names it: its menu label, with the menu in
        /// front where the label alone says too little ("Split ▸ Selection",
        /// "Select Loops ▸ Edge Loops").
        public var rowName: String {
            switch self {
            case .selectEdgeLoops, .selectEdgeRings, .splitSelection, .edgeSplitEdges,
                 .edgeSplitVertices, .mergeAtCenter, .mergeByDistance, .flipNormals, .recalculateNormals,
                 .shadeSmoothFaces, .shadeFlatFaces,
                 .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast,
                 .deleteVertices, .deleteEdges, .deleteFaces, .deleteEdgesFaces, .deleteOnlyFaces,
                 .deleteEdgeLoops, .recalculateInside, .setNormalsFromFaces, .smoothNormals,
                 .averageCustomNormal, .averageFaceArea, .averageCornerAngle:
                return group.rawValue + " ▸ " + menuLabel
            default:
                return menuLabel
            }
        }

        /// The 3D View bar's buttons for the four operations a mesh edit is
        /// mostly made of: Blender's toolbar names where its toolbar has the
        /// tool (Extrude Along Normals, Bevel, Inset Faces), the menu's
        /// otherwise.
        public var toolLabel: String {
            switch self {
            case .extrude: return "Extrude Along Normals"
            case .bevel:   return "Bevel"
            default:       return menuLabel
            }
        }

        /// The app's Mesh menu, made of Blender's own menus: its Mesh menu's
        /// submenus (Transform, Extrude, Merge, Split, Normals, Clean Up,
        /// Delete) and rows (Bisect, Knife Project, Symmetrize), its Select ▸
        /// Select Loops, and the Vertex, Edge and Face menus Blender keeps
        /// beside Mesh in its header — named as Blender names them, each row
        /// where Blender has it. Before round 4 these were the app's own
        /// headings (Add Geometry, Cut and Divide, Fill, Deform), which a
        /// reader who knows Blender's menus could not find their way in.
        public enum Group: String, CaseIterable, Sendable {
            case selectLoops = "Select Loops"
            case transform = "Transform"
            case extrude = "Extrude"
            case merge = "Merge"
            case split = "Split"
            /// Rows of Blender's Mesh menu itself, drawn in place rather than
            /// as a submenu.
            case mesh = "Mesh"
            case normals = "Normals"
            case shading = "Shading"
            /// Normals ▸ Average, a submenu of Normals in Blender
            /// (VIEW3D_MT_edit_mesh_normals_average), drawn inside it after
            /// Point to Target… (`parent`, `after`).
            case average = "Average"
            case cleanUp = "Clean Up"
            case delete = "Delete"
            case vertex = "Vertex"
            case edge = "Edge"
            case face = "Face"

            /// Whether its rows sit in the Mesh menu itself.
            public var isInline: Bool { self == .mesh }

            /// The group whose menu this one is a submenu of, drawn there
            /// after the row `after` rather than in the Mesh menu itself.
            public var parent: Group? { self == .average ? .normals : nil }
            public var after: Mesh? { self == .average ? .pointNormals : nil }

            /// Its rows in Blender's order (space_view3d.py, 5.2.1). Limited
            /// Dissolve is in two, as in Blender: Clean Up and Delete.
            public var rows: [Mesh] {
                switch self {
                case .selectLoops: return [.selectEdgeLoops, .selectEdgeRings]
                case .transform:   return [.toSphere, .pushPull, .shrinkFatten, .randomize]
                case .extrude:     return [.extrude, .extrudeIndividual, .extrudeManifold, .spin]
                case .merge:       return [.mergeAtCenter, .mergeAtCursor, .mergeCollapse, .mergeAtFirst,
                                           .mergeAtLast, .mergeByDistance]
                case .split:       return [.splitSelection, .edgeSplitEdges, .edgeSplitVertices]
                case .mesh:        return [.bisect, .convexHull, .symmetrize, .symmetrySnap]
                case .normals:     return [.flipNormals, .recalculateNormals, .recalculateInside,
                                           .setNormalsFromFaces, .pointNormals, .smoothNormals]
                case .average:     return [.averageCustomNormal, .averageFaceArea, .averageCornerAngle]
                case .shading:     return [.shadeSmoothFaces, .shadeFlatFaces]
                case .cleanUp:     return [.deleteLoose, .limitedDissolve, .fillHoles]
                case .delete:      return [.deleteVertices, .deleteEdges, .deleteFaces, .deleteEdgesFaces,
                                           .deleteOnlyFaces, .dissolveVerts, .dissolveEdges, .dissolveFaces,
                                           .limitedDissolve, .collapseEdgesFaces, .deleteEdgeLoops]
                case .vertex:      return [.bevelVertices, .fillFace, .connectVertexPath, .connectVertexPairs,
                                           .ripVerticesExtend, .slideVertices, .smooth, .smoothLaplacian]
                case .edge:        return [.bevel, .bridgeEdgeLoops, .subdivide, .subdivideEdgeRing, .unsubdivide,
                                           .rotateEdgeCW, .rotateEdgeCCW,
                                           .edgeSlide, .offsetEdgeSlide, .bevelWeight, .edgeCrease,
                                           .markSeam, .clearSeam, .markSharp, .clearSharp]
                case .face:        return [.inset, .poke, .triangulate, .quadify, .solidify, .wireframe,
                                           .gridFill, .beautifyFaces, .intersectKnife, .intersectBoolean,
                                           .weldEdgesIntoFaces]
                }
            }
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
        ///
        /// Round 4's rows (group 6) are Edit Mode rows too, as Blender's menus
        /// offer them: each acts on a selection Object Mode does not draw,
        /// and run there on the stored one — every element of a new
        /// primitive — Delete ▸ Vertices or Merge would take the whole mesh,
        /// and Intersect (Boolean) with nothing unselected empties it
        /// (measured in 5.2.1: a whole cube selected, 8/12/6 → 0/0/0).
        public var editModeOnly: Bool {
            switch self {
            case .selectEdgeLoops, .selectEdgeRings, .markSeam, .clearSeam,
                 .markSharp, .clearSharp, .edgeCrease, .bevelWeight:
                return true
            default:
                return Self.roundFourRows.contains(self)
            }
        }

        /// The rows round 4's group 6 added (docs/blender-local.md, 2026-10-19),
        /// but Recalculate Inside, which is Recalculate Outside's operator and
        /// runs from Object Mode as that row always has.
        static let roundFourRows: Set<Mesh> = [
            .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast,
            .deleteVertices, .deleteEdges, .deleteFaces, .deleteEdgesFaces, .deleteOnlyFaces,
            .collapseEdgesFaces, .deleteEdgeLoops, .connectVertexPairs, .ripVerticesExtend, .smoothLaplacian,
            .rotateEdgeCW, .rotateEdgeCCW, .intersectKnife, .intersectBoolean, .weldEdgesIntoFaces,
            .convexHull, .symmetrySnap, .setNormalsFromFaces, .pointNormals,
            .averageCustomNormal, .averageFaceArea, .averageCornerAngle, .smoothNormals, .extrudeManifold]

        /// The menu it is in: the one group whose `rows` hold it.
        public var group: Group {
            Group.allCases.first { $0.rows.contains(self) } ?? .mesh
        }

        var call: String {
            switch self {
            case .bevel:           return "bpy.ops.mesh.bevel"
            case .inset:           return "bpy.ops.mesh.inset"
            case .subdivide:       return "bpy.ops.mesh.subdivide"
            case .subdivideEdgeRing: return "bpy.ops.mesh.subdivide_edgering"
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
            case .shadeSmoothFaces:   return "bpy.ops.mesh.faces_shade_smooth"
            case .shadeFlatFaces:     return "bpy.ops.mesh.faces_shade_flat"
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
            case .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast: return "bpy.ops.mesh.merge"
            case .deleteVertices, .deleteEdges, .deleteFaces, .deleteEdgesFaces, .deleteOnlyFaces:
                return "bpy.ops.mesh.delete"
            case .collapseEdgesFaces: return "bpy.ops.mesh.edge_collapse"
            case .deleteEdgeLoops:    return "bpy.ops.mesh.delete_edgeloop"
            case .connectVertexPairs: return "bpy.ops.mesh.vert_connect"
            // A macro: Extend Vertices, then a Move of what it made, which a
            // pointer drags in Blender and the redo panel's Move sets here.
            case .ripVerticesExtend:  return "bpy.ops.mesh.rip_edge_move"
            case .smoothLaplacian:    return "bpy.ops.mesh.vertices_smooth_laplacian"
            case .rotateEdgeCW, .rotateEdgeCCW: return "bpy.ops.mesh.edge_rotate"
            case .intersectKnife:     return "bpy.ops.mesh.intersect"
            case .intersectBoolean:   return "bpy.ops.mesh.intersect_boolean"
            case .weldEdgesIntoFaces: return "bpy.ops.mesh.face_split_by_edges"
            case .convexHull:         return "bpy.ops.mesh.convex_hull"
            case .symmetrySnap:       return "bpy.ops.mesh.symmetry_snap"
            case .recalculateInside:  return "bpy.ops.mesh.normals_make_consistent"
            case .setNormalsFromFaces: return "bpy.ops.mesh.set_normals_from_faces"
            case .pointNormals:       return "bpy.ops.mesh.point_normals"
            case .averageCustomNormal, .averageFaceArea, .averageCornerAngle: return "bpy.ops.mesh.average_normals"
            case .smoothNormals:      return "bpy.ops.mesh.smooth_normals"
            // A macro: Extrude Region with Dissolve Orthogonal Edges, then a
            // Move along the normal that merges and splits where it crosses
            // the mesh (mesh_ops.cc; what Blender's Extrude Manifold tool and
            // `view3d.edit_mesh_extrude_manifold_normal` call). Measured in
            // 5.2.1: a cube's top face at +0.5 left 8/12/6, the cube 0.5
            // taller — the side faces dissolved into the old ones, as in
            // Blender — and at -0.5 0.5 shorter.
            case .extrudeManifold:    return "bpy.ops.mesh.extrude_manifold"
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
            // Delete's type is hidden in its redo panel (5.2.1's RNA:
            // PROP_HIDDEN), so it is not a field here either.
            case .deleteVertices:   return ["type='VERT'"]
            case .deleteEdges:      return ["type='EDGE'"]
            case .deleteFaces:      return ["type='FACE'"]
            case .deleteEdgesFaces: return ["type='EDGE_FACE'"]
            case .deleteOnlyFaces:  return ["type='ONLY_FACE'"]
            default:                      return []
            }
        }

        /// What a macro row's sub-operators are given that its panel does
        /// not offer (`LastOperator.memberArguments`).
        var memberArguments: [String: [String]] {
            switch self {
            // As `view3d.edit_mesh_extrude_manifold_normal` (the Extrude
            // menu's row) calls it: Dissolve Orthogonal Edges, and the Move
            // in the Normal orientation constrained to its Z. The macro's
            // own definition (mesh_ops.cc) sets the rest — no mirroring, no
            // proportional editing, Auto Merge & Split — so they are not sent.
            case .extrudeManifold:
                return ["MESH_OT_extrude_region": ["\"use_normal_flip\": False", "\"use_dissolve_ortho_edges\": True"],
                        "TRANSFORM_OT_translate": ["\"orient_type\": 'NORMAL'",
                                                   "\"constraint_axis\": (False, False, True)"]]
            default:
                return [:]
            }
        }

        /// The words for an operator that returns FINISHED having changed
        /// nothing (`LastOperator.unchanged`).
        var unchanged: String? {
            switch self {
            case .subdivideEdgeRing:
                return "Subdivide Edge-Ring found no quads between the selected edges to cut across: "
                    + "select edges of one edge ring (Select ▸ Select Loops ▸ Edge Rings), or use the Loop Cut tool"
            // Each of these returns FINISHED having changed nothing when the
            // selection is not one it acts on (measured in 5.2.1 on a cube:
            // Collapse with one vertex or two unjoined ones, Edge Loops with
            // nothing selected, Connect Vertex Pairs with a whole cube or an
            // edge's two ends, Weld with no loose edge across a face, Extend
            // with a whole cube — every vertex with three selected edges).
            // No field of theirs changes whether they act, so nothing is lost
            // by having no panel then.
            case .collapseEdgesFaces:
                return "Collapse Edges & Faces merges each selected edge, or face, into one vertex, and nothing "
                    + "selected is an edge or a face: select an edge first"
            case .deleteEdgeLoops:
                return "Delete ▸ Edge Loops removes the selected edge loops, and found none to remove: "
                    + "select a loop of edges (Select ▸ Select Loops ▸ Edge Loops)"
            case .connectVertexPairs:
                return "Connect Vertex Pairs joins selected vertices that share a face and are not joined yet, "
                    + "and found no such pair: select vertices across a face"
            case .weldEdgesIntoFaces:
                return "Weld Edges into Faces splits the selected faces along the selected loose edges lying "
                    + "on them, and none of the selected edges is loose on a selected face"
            case .ripVerticesExtend:
                return "Rip Vertices and Extend extends each selected vertex along one of its edges, and could "
                    + "extend none: a vertex with two or more of its edges selected is left as it is"
            // Measured in 5.2.1 with the rows' calls on a cube: FINISHED and
            // nothing changed for Collapse on two corners no edge joins (the
            // other types merge them), and for At Cursor only when the one
            // vertex is at the cursor already; `check_merge` refuses fewer
            // than two otherwise. The panel's Type can change, so the words
            // cover both.
            case .mergeAtCenter, .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast:
                return "Merge changed nothing: Collapse merges selected vertices that selected edges join, and "
                    + "none of these are joined; At Cursor moves a vertex that is at the 3D cursor already"
            // FINISHED and nothing moved on one cube corner, and on a whole
            // cube (measured in 5.2.1, the row's call).
            case .smoothLaplacian:
                return "Smooth Vertices (Laplacian) moved no vertex: with these settings Blender found nothing "
                    + "to smooth in the selection (one vertex, or a shape as even as a cube)"
            default:
                return nil
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
                    + "or a loop of edges (Select ▸ Select Loops ▸ Edge Loops)"
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
            // Measured in 5.2.1 on a cube: CANCELLED, raising nothing, for
            // each type with nothing of its kind selected — Vertices with
            // none, Edges, Only Edges & Faces with no edge (one vertex, or two
            // unjoined), Faces and Only Faces with no face.
            case .deleteVertices:
                return "Delete ▸ Vertices removes the selected vertices and what uses them: select a vertex first"
            case .deleteEdges:
                return "Delete ▸ Edges removes the selected edges and the faces using them: select an edge first"
            case .deleteFaces:
                return "Delete ▸ Faces removes the selected faces: select a face first"
            case .deleteEdgesFaces:
                return "Delete ▸ Only Edges & Faces removes the selected edges and faces and keeps their vertices: "
                    + "select an edge first"
            case .deleteOnlyFaces:
                return "Delete ▸ Only Faces removes the selected faces and keeps their edges: select a face first"
            // CANCELLED with nothing selected, or one vertex (measured).
            case .connectVertexPairs:
                return "Connect Vertex Pairs joins selected vertices that share a face: select two or more"
            case .smoothLaplacian:
                return "Smooth Vertices (Laplacian) smooths the selected vertices: select some first"
            case .symmetrySnap:
                return "Snap to Symmetry moves the selected vertices onto their mirror images: select some first"
            case .pointNormals:
                return "Point to Target… points the custom normals of the selected vertices at the Target: "
                    + "select some first"
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

        /// Blender's Subdivide Edge-Ring (Edge menu) cuts across the quads
        /// between the selected edges of an edge ring, and nothing else: this
        /// row used to be called Loop Cut and selected the whole ring first,
        /// which no row of Blender's does. Measured in 5.2.1 on a cube: one
        /// edge selected, or two that share a corner, FINISHED with nothing
        /// changed; two edges across a face, at one cut 8/12/6 → 10/15/7, at
        /// Blender's default of ten 28/42/16 (scripts/run-cuttools-blender-check.sh).
        /// With fewer than two edges selected it is refused first, the cuts
        /// are priced against the vertex budget
        /// (`_blenderkit_loopcut.check_edgering`), and a run that changed
        /// nothing is said (`unchanged`). Blender's Loop Cut is the toolbar's
        /// tool now (CutTools.swift).
        var lead: String? {
            switch self {
            case .subdivideEdgeRing:
                return """
                if bpy.context.object.data.total_edge_sel < 2:
                    raise RuntimeError('Subdivide Edge-Ring cuts across the quads between the selected edges of '
                                       'an edge ring: select two or more (Select ▸ Select Loops ▸ Edge Rings '
                                       'selects a whole ring), or use the Loop Cut tool')
                import _blenderkit_loopcut
                _blenderkit_loopcut.check_edgering(@arg:number_cuts@)
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
                    raise RuntimeError('\(rowName) \(verb): select an edge first')
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
                    raise RuntimeError('\(rowName) \(what): select something first')
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
                        raise RuntimeError('\(rowName) splits the mesh at the selected vertices: select a vertex first')
                elif not any(_bk_me.total_edge_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(rowName) splits the mesh along the selected edges: select an edge first')
                """
            case .fillHoles:
                return Self.editMeshes + """

                if not any(_bk_me.total_edge_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(rowName) fills the holes the selected edges go round: select an edge first')
                """
            case .beautifyFaces, .extrudeIndividual:
                let what = self == .beautifyFaces
                    ? "turns the edges between the selected triangles"
                    : "extrudes each selected face on its own"
                return Self.editMeshes + """

                if not any(_bk_me.total_face_sel for _bk_me in _bk_meshes):
                    raise RuntimeError('\(rowName) \(what): select a face first')
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
            // Merge with the panel's Type (`@arg:type@`): At First and At
            // Last need Blender's selection order, and every type but At
            // Cursor needs two vertices to do anything
            // (`_blenderkit_meshmenu.check_merge` has the measurements).
            case .mergeAtCenter, .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast:
                return "import _blenderkit_meshmenu\n_blenderkit_meshmenu.check_merge(@arg:type@)"
            // These return FINISHED having changed nothing with nothing they
            // act on selected (measured in 5.2.1 on a cube with nothing
            // selected, and with a vertex or an edge where they want faces).
            // Only the empty selection is refused: what else they find to do
            // depends on fields their panel has — Intersect (Knife)'s Source,
            // Intersect (Boolean)'s Self Intersection, Convex Hull's switches.
            case .collapseEdgesFaces, .deleteEdgeLoops, .ripVerticesExtend, .convexHull,
                 .intersectKnife, .intersectBoolean, .weldEdgesIntoFaces, .setNormalsFromFaces,
                 .averageCustomNormal, .averageFaceArea, .averageCornerAngle, .smoothNormals, .extrudeManifold:
                let need: (verts: Int, edges: Int, faces: Int, sentence: String)
                switch self {
                case .collapseEdgesFaces:
                    need = (0, 1, 0, "Collapse Edges & Faces merges each selected edge, or face, into one vertex: "
                                + "select an edge first")
                case .deleteEdgeLoops:
                    need = (0, 1, 0, "Delete ▸ Edge Loops removes the selected edge loops: select a loop of edges "
                                + "(Select ▸ Select Loops ▸ Edge Loops)")
                // What `edbm_rip_edge_exec` does (editmesh_rip_edge.cc): each
                // selected vertex's edge that points most toward the pointer's
                // line — here through the 3D cursor — is split at the vertex,
                // so the new vertex starts on the old one; the macro's Move
                // (the panel's) then moves it. Measured in desktop 5.2.1 with
                // this call on a cube's corner (1, -1, 1), the cursor at (2,
                // -1, 2.5): 8 → 9 vertices, the new one at (1, -1, 1) on the
                // edge toward (1, 1, 1); nothing moved toward the cursor, which
                // these words used to promise (round 4's review).
                case .ripVerticesExtend:
                    need = (1, 0, 0, "Rip Vertices and Extend splits a new vertex off each selected vertex, on its "
                                + "edge pointing most toward the 3D cursor, to be moved by the panel's Move: "
                                + "select a vertex first")
                case .convexHull:
                    // Three points make the smallest hull, a triangle.
                    need = (3, 0, 0, "Convex Hull wraps the selected vertices in a hull: select at least three")
                case .intersectKnife:
                    need = (0, 0, 1, "Intersect (Knife) cuts where the selected faces cross the others, or each "
                                + "other: select faces first")
                case .intersectBoolean:
                    need = (0, 0, 1, "Intersect (Boolean) cuts the unselected faces with the selected ones: "
                                + "select the faces to cut with first")
                // It splits only selected faces, along selected loose edges
                // (`edbm_face_split_by_edges_exec` skips a mesh with no face
                // or no edge selected): measured in 5.2.1, a loose diagonal
                // alone selected changed nothing; with the faces, it split.
                case .weldEdgesIntoFaces:
                    need = (0, 1, 1, "Weld Edges into Faces splits the selected faces along the selected loose "
                                + "edges lying on them: select the faces and the edges")
                case .setNormalsFromFaces:
                    need = (0, 0, 1, "Set from Faces sets the custom normals of the selected faces to the faces' "
                                + "own: select a face first")
                case .smoothNormals:
                    need = (1, 0, 0, "Smooth Vectors smooths the custom normals of the selected vertices: "
                                + "select some first")
                // It acts on what is selected, faces or not: measured in 5.2.1
                // with this row's call on a cube, one edge 8/12/6 → 10/15/7
                // and one vertex → 9/13/6 (round 4's review).
                case .extrudeManifold:
                    need = (1, 0, 0, "Extrude Manifold extrudes the selected faces, edges or vertices: "
                                + "select some first")
                default:
                    need = (1, 0, 0, "Average ▸ \(menuLabel) averages the custom normals of the selected "
                                + "vertices: select some first")
                }
                let required = "import _blenderkit_meshmenu\n_blenderkit_meshmenu.require(\(Bpy.quote(displayName)), "
                    + "verts=\(need.verts), edges=\(need.edges), faces=\(need.faces), "
                    + "sentence=\(Bpy.quote(need.sentence)))"
                // Cutting the unselected faces with the selected ones needs
                // an unselected face. Measured in 5.2.1 with these rows' calls
                // on a whole cube selected: Intersect (Knife) answered
                // FINISHED with nothing changed, and Intersect (Boolean)
                // emptied the mesh, 8/12/6 → 0/0/0 (round 4's review; Blender
                // does the same). Not with Self Intersect, or Boolean's Self
                // Intersection, which cut the selection with itself (a Self
                // Union of two whole cubes is a use of it; Difference there
                // empties the mesh in Blender too, 16/24/12 → 0/0/0, so the
                // refusal does not point at it).
                switch self {
                case .intersectKnife:
                    return required + "\nif @arg:mode@ == 'SELECT_UNSELECT':\n"
                        + "    _blenderkit_meshmenu.require_unselected_faces(\(Bpy.quote(displayName)), "
                        + Bpy.quote("Intersect (Knife) with Source Selected/Unselected cuts the unselected faces "
                                    + "where the selected ones cross them, and every face is selected: deselect "
                                    + "the faces to cut, or set Source to Self Intersect") + ")"
                case .intersectBoolean:
                    return required + "\nif not @arg:use_self@:\n"
                        + "    _blenderkit_meshmenu.require_unselected_faces(\(Bpy.quote(displayName)), "
                        + Bpy.quote("Intersect (Boolean) cuts the unselected faces with the selected ones, and "
                                    + "every face is selected, which Blender would leave as no mesh at all: "
                                    + "deselect the faces to cut") + ")"
                default:
                    return required
                }
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
            // Blender's own panel, read from 5.2.1's RNA: its five rows in
            // its order and its defaults — 10 cuts (soft 1 to 64), Blend
            // Path, Smoothness 1 (a bare number, soft 0 to 2), Profile
            // Factor 0 (soft -2 to 2), Profile Shape Smooth. Round 4's review
            // found the row sending the old Loop Cut row's 1 cut, Linear and
            // Smoothness 0 under Subdivide Edge-Ring's name. Ten cuts are
            // priced against the vertex budget first (`lead`).
            case .subdivideEdgeRing:
                return [
                    Parameter(key: "number_cuts", label: "Number of Cuts", kind: .integer,
                              value: 10, softMin: 1, softMax: 64, step: 0.05),
                    Parameter(key: "interpolation", label: "Interpolation",
                              kind: .choice([Parameter.Option("LINEAR", "Linear"),
                                             Parameter.Option("PATH", "Blend Path"),
                                             Parameter.Option("SURFACE", "Blend Surface")]),
                              value: 1, softMin: 0, softMax: 2, step: 0.02),
                    Parameter(key: "smoothness", label: "Smoothness", kind: .float,
                              value: 1, softMin: 0, softMax: 2, step: 0.004, unit: .none),
                    Parameter(key: "profile_shape_factor", label: "Profile Factor", kind: .float,
                              value: 0, softMin: -2, softMax: 2, step: 0.004, unit: .none),
                    Parameter(key: "profile_shape", label: "Profile Shape",
                              kind: .choice([Parameter.Option("SMOOTH", "Smooth"),
                                             Parameter.Option("SPHERE", "Sphere"),
                                             Parameter.Option("ROOT", "Root"),
                                             Parameter.Option("INVERSE_SQUARE", "Inverse Square"),
                                             Parameter.Option("SHARP", "Sharp"),
                                             Parameter.Option("LINEAR", "Linear")]),
                              value: 0, softMin: 0, softMax: 5, step: 0.02)]
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
                    // Blender's Plane Normal (`plane_no`), a vector; the row
                    // offers its three axes.
                    Parameter(key: "plane_no", label: "Plane Normal",
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
                // Type, in its enum's order, and UVs (5.2.1's RNA; it was
                // labelled Merge here, with two of the five types). Blender's
                // panel offers At First and At Last only when the selection
                // order allows them (`merge_type_itemf`); here they are always
                // offered and refused in words when it does not
                // (`_blenderkit_meshmenu.check_merge`).
                return [
                    Parameter(key: "type", label: "Type",
                              kind: .choice([Parameter.Option("CENTER", "At Center"),
                                             Parameter.Option("CURSOR", "At Cursor"),
                                             Parameter.Option("COLLAPSE", "Collapse"),
                                             Parameter.Option("FIRST", "At First"),
                                             Parameter.Option("LAST", "At Last")]),
                              value: 0, softMin: 0, softMax: 4, step: 0.02),
                    Self.toggle("uvs", "UVs", false)]
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
                // Blender's checkbox, Inside (5.2.1's RNA); Recalculate
                // Outside and Recalculate Inside are its two rows.
                return [Self.toggle("inside", "Inside", false)]
            case .quadify:
                return [
                    Parameter(key: "face_threshold", label: "Max Face Angle", kind: .float,
                              value: 0.698, softMin: 0, softMax: 3.142, step: 0.01),
                    Parameter(key: "shape_threshold", label: "Max Shape Angle", kind: .float,
                              value: 0.698, softMin: 0, softMax: 3.142, step: 0.01)]
            case .dissolveVerts, .dissolveEdges, .dissolveFaces,
                 .fillFace, .flipNormals, .triangulate, .shadeSmoothFaces, .shadeFlatFaces:
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
                    // The properties' names: Delimit and Edge Ring Delimit
                    // (desktop 5.2.1's RNA).
                    Parameter(key: key, label: self == .selectEdgeLoops ? "Delimit" : "Edge Ring Delimit",
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
                    // once Even was on. Its row is live all the same, as in
                    // Blender's panel: TRANSFORM_OT_edge_slide has no `ui`
                    // callback and `transform_poll_property` no rule for
                    // `flipped` (transform_ops.cc), the rule Loop Cut's panel
                    // follows (CutTools.swift).
                    Parameter(key: "use_even", label: "Even",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02),
                    Parameter(key: "flipped", label: "Flipped",
                              kind: .literal([Parameter.Option("False", "Off"),
                                              Parameter.Option("True", "On")]),
                              value: 0, softMin: 0, softMax: 1, step: 0.02)]
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
                    // Named as its property is: Slide Direction.
                    Parameter(key: "direction", label: "Slide Direction",
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

            // Round 4, group 6. Every label, default and soft range below is
            // 5.2.1's RNA (`get_rna_type()`), each property also in the 5.3
            // source the app's bpy is built from; the rows each panel hides
            // are the ones its `ui` callback hides (named per row).
            case .mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast:
                return Self.mergeAtCenter.parameters.map { p in
                    guard p.key == "type" else { return p }
                    var q = p
                    q.value = Double([Mesh.mergeAtCursor, .mergeCollapse, .mergeAtFirst, .mergeAtLast]
                        .firstIndex(of: self)! + 1)
                    return q
                }
            case .deleteVertices, .deleteEdges, .deleteFaces, .deleteEdgesFaces, .deleteOnlyFaces,
                 .collapseEdgesFaces, .connectVertexPairs, .weldEdgesIntoFaces:
                // No properties, or only the hidden Type.
                return []
            case .deleteEdgeLoops:
                return [Self.toggle("use_face_split", "Face Split", true)]
            case .ripVerticesExtend:
                // The Move the macro's translate makes, which a pointer drags
                // in Blender; 0 is a click that does not drag, and leaves the
                // new vertex on the old one.
                return Parameter.vector("value", "Move", .zero, softMin: -100, softMax: 100, step: 0.01)
                    .map { var p = $0; p.member = "TRANSFORM_OT_translate"; return p }
            case .smoothLaplacian:
                return [
                    Parameter(key: "repeat", label: "Number of iterations to smooth the mesh", kind: .integer,
                              value: 1, softMin: 1, softMax: 200, step: 0.05),
                    // Seven places: Blender's border factor is 5e-5, which
                    // four places would send as 0.0001.
                    {
                        var p = Parameter(key: "lambda_factor", label: "Lambda factor", kind: .float,
                                          value: 1, softMin: 1e-7, softMax: 1000, step: 0.01, unit: .none)
                        p.places = 7
                        return p
                    }(),
                    {
                        var p = Parameter(key: "lambda_border", label: "Lambda factor in border", kind: .float,
                                          value: 5e-5, softMin: 1e-7, softMax: 1000, step: 0.001, unit: .none)
                        p.places = 7
                        return p
                    }(),
                    Self.toggle("use_x", "Smooth X Axis", true),
                    Self.toggle("use_y", "Smooth Y Axis", true),
                    Self.toggle("use_z", "Smooth Z Axis", true),
                    Self.toggle("preserve_volume", "Preserve Volume", true)]
            case .rotateEdgeCW, .rotateEdgeCCW:
                return [Self.toggle("use_ccw", "Counter Clockwise", self == .rotateEdgeCCW)]
            case .intersectKnife:
                // `edbm_intersect_ui`: Source, Separate Mode, Solver, and the
                // Merge Threshold only for the Float solver.
                return [
                    Parameter(key: "mode", label: "Source",
                              kind: .choice([Parameter.Option("SELECT", "Self Intersect"),
                                             Parameter.Option("SELECT_UNSELECT", "Selected/Unselected")]),
                              value: 1, softMin: 0, softMax: 1, step: 0.02),
                    Parameter(key: "separate_mode", label: "Separate Mode",
                              kind: .choice([Parameter.Option("ALL", "All"), Parameter.Option("CUT", "Cut"),
                                             Parameter.Option("NONE", "Merge")]),
                              value: 1, softMin: 0, softMax: 2, step: 0.02),
                    Self.solver,
                    Self.mergeThreshold]
            case .intersectBoolean:
                // `edbm_intersect_boolean_ui`: Boolean Operation, Solver,
                // Swap, Self Intersection, and the Merge Threshold for Float.
                return [
                    Parameter(key: "operation", label: "Boolean Operation",
                              kind: .choice([Parameter.Option("INTERSECT", "Intersect"),
                                             Parameter.Option("UNION", "Union"),
                                             Parameter.Option("DIFFERENCE", "Difference")]),
                              value: 2, softMin: 0, softMax: 2, step: 0.02),
                    Self.solver,
                    Self.toggle("use_swap", "Swap", false),
                    Self.toggle("use_self", "Self Intersection", false),
                    Self.mergeThreshold]
            case .convexHull:
                // No `ui` callback: Blender's panel draws every property.
                return [
                    Self.toggle("delete_unused", "Delete Unused", true),
                    Self.toggle("use_existing_faces", "Use Existing Faces", true),
                    Self.toggle("make_holes", "Make Holes", false),
                    Self.toggle("join_triangles", "Join Triangles", true),
                    Parameter(key: "face_threshold", label: "Max Face Angle", kind: .float,
                              value: 40 * .pi / 180, softMin: 0, softMax: .pi, step: 0.005, unit: .degrees),
                    Parameter(key: "shape_threshold", label: "Max Shape Angle", kind: .float,
                              value: 40 * .pi / 180, softMin: 0, softMax: .pi, step: 0.005, unit: .degrees),
                    Parameter(key: "topology_influence", label: "Topology Influence", kind: .float,
                              value: 0, softMin: 0, softMax: 2, step: 0.004, unit: .none),
                    Self.toggle("uvs", "Compare UVs", false),
                    Self.toggle("vcols", "Compare Color Attributes", false),
                    Self.toggle("seam", "Compare Seam", false),
                    Self.toggle("sharp", "Compare Sharp", false),
                    Self.toggle("materials", "Compare Materials", false),
                    Self.toggle("deselect_joined", "Deselect Joined", false)]
            case .symmetrySnap:
                return [
                    Self.symmetryDirection,
                    Parameter(key: "threshold", label: "Threshold", kind: .float,
                              value: 0.05, softMin: 0.0001, softMax: 1, step: 0.002),
                    Parameter(key: "factor", label: "Factor", kind: .float,
                              value: 0.5, softMin: 0, softMax: 1, step: 0.004, unit: .none),
                    Self.toggle("use_center", "Center", true),
                    Self.toggle("use_topology", "Topology Mirror", false)]
            case .setNormalsFromFaces:
                return [Self.toggle("keep_sharp", "Keep Sharp Edges", false)]
            case .pointNormals:
                // `edbm_point_normals_ui`: every property but the hidden Mode
                // (the exec ignores it), Spherize Strength only with Spherize.
                // Target starts at the 3D cursor (`mesh(_:…)`), where Blender's
                // modal tool's "Use 3D Cursor" puts it.
                return [Self.toggle("invert", "Invert", false), Self.toggle("align", "Align", false)]
                    + Parameter.vector("target_location", "Target", .zero, softMin: -1000, softMax: 1000, step: 0.01)
                    + [Self.toggle("spherize", "Spherize", false),
                       {
                           var p = Parameter(key: "spherize_strength", label: "Spherize Strength", kind: .float,
                                             value: 0.1, softMin: 0, softMax: 1, step: 0.004, unit: .none)
                           p.shownWhen = .init("spherize", is: 1)
                           return p
                       }()]
            case .averageCustomNormal, .averageFaceArea, .averageCornerAngle:
                // `average_normals_draw_check_prop`: Weight and Threshold
                // only for Face Area and Corner Angle.
                let type = [Mesh.averageCustomNormal, .averageFaceArea, .averageCornerAngle].firstIndex(of: self)!
                var weight = Parameter(key: "weight", label: "Weight", kind: .integer,
                                       value: 50, softMin: 1, softMax: 100, step: 0.2)
                var threshold = Parameter(key: "threshold", label: "Threshold", kind: .float,
                                          value: 0.01, softMin: 0, softMax: 5, step: 0.002, unit: .none)
                weight.shownWhen = .init("average_type", isNot: 0)
                threshold.shownWhen = .init("average_type", isNot: 0)
                return [
                    Parameter(key: "average_type", label: "Type",
                              kind: .choice([Parameter.Option("CUSTOM_NORMAL", "Custom Normal"),
                                             Parameter.Option("FACE_AREA", "Face Area"),
                                             Parameter.Option("CORNER_ANGLE", "Corner Angle")]),
                              value: Double(type), softMin: 0, softMax: 2, step: 0.02),
                    weight, threshold]
            case .smoothNormals:
                return [Parameter(key: "factor", label: "Factor", kind: .float,
                                  value: 0.5, softMin: 0, softMax: 1, step: 0.004, unit: .none)]
            case .recalculateInside:
                return Self.recalculateNormals.parameters.map { var p = $0; p.value = 1; return p }
            case .extrudeManifold:
                // The Move along the normal, constrained to its Z (the menu's
                // call), so Z is the one field that moves anything; it starts
                // where the result shows, as Extrude Faces Along Normals' does.
                var z = Parameter(key: "value.z", label: "Z",
                                  kind: .component(keyword: "value", heading: "Move", axis: 2),
                                  value: 0.2, softMin: -10, softMax: 10, step: 0.004)
                z.member = "TRANSFORM_OT_translate"
                return [z]
            }
        }

        /// An on/off argument, as Blender's panel draws a checkbox.
        static func toggle(_ key: String, _ label: String, _ on: Bool) -> Parameter {
            Parameter(key: key, label: label,
                      kind: .literal([Parameter.Option("False", "Off"), Parameter.Option("True", "On")]),
                      value: on ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
        }

        /// The Intersect operators' Solver, Exact by default.
        static var solver: Parameter {
            Parameter(key: "solver", label: "Solver",
                      kind: .choice([Parameter.Option("FLOAT", "Float"), Parameter.Option("EXACT", "Exact")]),
                      value: 1, softMin: 0, softMax: 1, step: 0.02)
        }

        /// Their Merge Threshold, which their panels draw for the Float
        /// solver only (`if (!use_exact)`).
        static var mergeThreshold: Parameter {
            var p = Parameter(key: "threshold", label: "Merge Threshold", kind: .float,
                              value: 1e-6, softMin: 0, softMax: 0.001, step: 0.0001)
            p.places = 7
            p.shownWhen = .init("solver", is: 0)
            return p
        }

        /// Symmetrize's and Snap to Symmetry's Direction.
        static var symmetryDirection: Parameter {
            Parameter(key: "direction", label: "Direction",
                      kind: .choice([Parameter.Option("NEGATIVE_X", "-X to +X"),
                                     Parameter.Option("POSITIVE_X", "+X to -X"),
                                     Parameter.Option("NEGATIVE_Y", "-Y to +Y"),
                                     Parameter.Option("POSITIVE_Y", "+Y to -Y"),
                                     Parameter.Option("NEGATIVE_Z", "-Z to +Z"),
                                     Parameter.Option("POSITIVE_Z", "+Z to -Z")]),
                      value: 0, softMin: 0, softMax: 5, step: 0.02)
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
    ///
    /// `pointer` is the app's view and the 3D cursor, for the rows Blender
    /// runs at the pointer (`MeshPointer`): Rip Vertices and Extend's ray, and
    /// Point to Target…'s Target, which starts at the cursor. Nil is a view
    /// from the front onto a cursor at the origin, for the catalogue's tests;
    /// the menu always passes its own.
    static func mesh(_ op: Mesh, spinningAround origin: SIMD3<Float>?,
                     symmetry: MeshSymmetry? = nil, pointer: MeshPointer? = nil) -> LastOperator {
        var made = LastOperator(name: op.displayName, call: op.call,
                                parameters: op.parameters, location: nil,
                                restoration: .restoreMesh, needsEditMode: true)
        made.fixedArguments = op.fixedArguments
        made.memberArguments = op.memberArguments
        let pointer = pointer ?? .front
        if op == .pointNormals {
            made["target_location.x"] = Double(pointer.cursor.x)
            made["target_location.y"] = Double(pointer.cursor.y)
            made["target_location.z"] = Double(pointer.cursor.z)
        }
        if op.honoursMeshSymmetry, symmetry != nil {
            made.fixedArguments.append("mirror=True")
        }
        made.refusal = op.refusal
        made.unchanged = op.unchanged
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
        if op == .ripVerticesExtend {
            // `rip_edge`'s exec takes the ray its invoke makes from the
            // pointer; here the pointer is over Blender's 3D cursor in the
            // app's view (`_blenderkit_meshmenu.pointer_ray`, read from
            // Blender's cursor when it runs). Its poll wants a 3D View
            // (EDBM_view3d_poll): the borrowed one, the call with its undo
            // off, as every call under it is (`refuse_undo_in_area`).
            made.lead = (made.lead.map { $0 + "\n" } ?? "") + """
                import _blenderkit_context
                _bk_ray = _blenderkit_meshmenu.pointer_ray(\(pointer.pythonArguments(up: false)))
                """
            made.memberArguments["MESH_OT_rip_edge"] = ["\"location\": _bk_ray[0]", "\"direction\": _bk_ray[1]"]
            made.within = "_blenderkit_context.temp_override_view3d('Rip Vertices and Extend')"
        }
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
    /// modal and refuses without a pointer; the toolbar's Knife cuts along a
    /// drawn path through this same operator (`LastOperator.knife`).
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
