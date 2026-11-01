import Foundation
import simd

/// What a gizmo drag commits, as the values the redo panel shows.
///
/// A gizmo Move, Rotate or Scale used to go through `bridge.run(…, undo:)`,
/// which clears Adjust Last Operation: the one way to type an exact number in
/// Edit Mode — the transform's own Move X, Y and Z — never opened (round 3's
/// review, toolkit item 3). Now it is a `LastOperator` performed through the
/// bridge, so the panel opens on it and re-runs it by undoing and running
/// again, as Blender's does.
///
/// Its rows are the ones Blender's panel draws for these operators
/// (`transform_poll_property`, transform_ops.cc, and the operators' RNA read
/// in 5.2.1): Move X/Y/Z, Angle and Axis, or Scale X/Y/Z; Orientation; Mirror
/// Editing (in Edit Mode, the only mode it acts in); Proportional Editing,
/// and while it is on Proportional Falloff, Proportional Size and Connected.
/// Constraint Axis is not a row because Blender hides it whenever there is a
/// value — and for Move and Scale its exec ignores it, forcing all three axes
/// "so that the orientation is more intuitive in the Redo Panel"
/// (transform_generics.cc): the values say which way it moves. Projected (2D)
/// is not offered: it projects along the view of a 3D View region
/// (`set_prop_dist`), which a headless Blender has none of, so it would be a
/// switch that changes nothing.
public struct GizmoCommit: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `value`: the move in the orientation's axes (Blender's exec takes
        /// it as final: `global_dir = spacemtx · values`). `constraint` is the
        /// three-bool tuple the drag's handle makes, which Blender logs.
        case translate(values: SIMD3<Float>, constraint: String)
        /// The angle about the orientation's axis `axis` (0, 1, 2).
        case rotate(angle: Float, axis: Int)
        /// Factors along the orientation's axes.
        case resize(values: SIMD3<Float>, constraint: String)
    }

    public var kind: Kind
    /// Nil for a custom orientation, whose matrix goes alone (`orient_matrix`
    /// with no `orient_type` is CUSTOM_MATRIX, transform_generics.cc).
    public var orientation: TransformOrientation?
    /// The orientation's matrix as it is printed — what the preview used.
    public var axes: simd_float3x3
    /// The view's, for the panel's View row: Blender headless has no view to
    /// take it from (`rv3d` is null; View came out as Global).
    public var viewAxes: simd_float3x3
    public var editing: Bool
    /// `mirror=True` while editing a mesh with an axis of its symmetry on.
    /// The axes are not arguments: Blender reads them from the mesh, where
    /// the header's toggles wrote them (`SymmetryBpy`). Without it a headless
    /// Blender mirrors nothing (T_NO_MIRROR with no 3D View) — measured in
    /// 5.2.1, a translate moved 1 vertex with `use_mirror_x` on, and with it
    /// the vertex and its mirror image, to (-0.9, 0.7, 0.3) and (0.9, 0.7, 0.3).
    public var mirror: Bool
    public var proportional: ProportionalEdit?
    /// The scene's falloff, size and Connected Only, where the panel's rows
    /// start when proportional editing is off for this drag.
    public var proportionalDefaults: ProportionalEdit
    /// `center_override`, printed; nil for a move. Every pivot but Individual
    /// Origins sends one, Median Point included: measured in Blender 5.2.1
    /// headless with cubes at x = 0, 4 and 10, all five
    /// `transform_pivot_point` identifiers turned the selection about x = 5,
    /// the bounds centre — `initTransInfo` falls back to
    /// V3D_AROUND_CENTER_BOUNDS with no View3D to read `v3d->around` from —
    /// while the gizmo previews about the median, 4.667. In Edit Mode
    /// Individual Origins falls back to the gizmo's own pivot, which still
    /// has to be said.
    public var centre: SIMD3<Float>?
    /// Object Mode's Individual Origins: one call per object
    /// (`_blenderkit_tools.transform_individual`).
    public var individualOrigins: Bool
    /// Places a move's values are written to: 6 while it may snap to
    /// geometry, else 4 (`TransformGizmo.places`).
    public var places: Int
    /// Run after the call and kept out of the log: auto keying's report.
    public var afterward: String?

    public init(kind: Kind, orientation: TransformOrientation?, axes: simd_float3x3,
                viewAxes: simd_float3x3, editing: Bool, mirror: Bool = false,
                proportional: ProportionalEdit? = nil,
                proportionalDefaults: ProportionalEdit = ProportionalEdit(falloff: .smooth, size: 1),
                centre: SIMD3<Float>? = nil, individualOrigins: Bool = false,
                places: Int = 4, afterward: String? = nil) {
        self.kind = kind; self.orientation = orientation; self.axes = axes
        self.viewAxes = viewAxes; self.editing = editing; self.mirror = mirror
        self.proportional = proportional; self.proportionalDefaults = proportionalDefaults
        self.centre = centre; self.individualOrigins = individualOrigins
        self.places = places; self.afterward = afterward
    }

    /// The undo step and the panel's title: the operators' names, the steps
    /// Blender's history records for them (UndoStep).
    public var name: String {
        switch kind {
        case .translate: return UndoStep.move
        case .rotate:    return UndoStep.rotate
        case .resize:    return UndoStep.resize
        }
    }
}

public extension LastOperator {

    /// The labels and ranges Blender gives the rows.
    static let orientAxisOptions = [Parameter.Option("X", "X"), Parameter.Option("Y", "Y"),
                                    Parameter.Option("Z", "Z")]
    static let onOff = [Parameter.Option("False", "Off"), Parameter.Option("True", "On")]

    /// A gizmo drag's commit, adjustable in the redo panel.
    static func gizmo(_ c: GizmoCommit) -> LastOperator {
        var parameters: [Parameter] = []
        var fixed: [String] = []
        switch c.kind {
        case .translate(let values, let constraint):
            var rows = Parameter.vector("value", "Move", SIMD3<Double>(values),
                                        softMin: -100_000, softMax: 100_000, step: 0.01)
            for i in rows.indices { rows[i].places = c.places; rows[i].keepsZeros = true }
            parameters += rows
            fixed.append("constraint_axis=" + constraint)
        case .rotate(let angle, let axis):
            var value = Parameter(key: "value", label: "Angle", kind: .float, value: Double(angle),
                                  softMin: -4 * .pi, softMax: 4 * .pi, step: 0.005, unit: .degrees)
            value.keepsZeros = true
            parameters.append(value)
            parameters.append(Parameter(key: "orient_axis", label: "Axis", kind: .choice(orientAxisOptions),
                                        value: Double(min(max(axis, 0), 2)), softMin: 0, softMax: 2, step: 0.02))
        case .resize(let values, let constraint):
            var rows = Parameter.vector("value", "Scale", SIMD3<Double>(values),
                                        softMin: -10_000, softMax: 10_000, step: 0.005, unit: .none)
            for i in rows.indices { rows[i].keepsZeros = true }
            parameters += rows
            fixed.append("constraint_axis=" + constraint)
        }
        if let orientation = c.orientation {
            // Each choice carries what Blender needs to use it as the app
            // does: the drag's own orientation its matrix, View the view's,
            // the rest nothing — Blender works them out from the selection,
            // the cursor, the parent, as it does when its own redo panel
            // switches orientation (`orient_matrix_type` no longer matching).
            //
            // Except Normal in Edit Mode, which Blender's 3D View works out
            // with the pivot point (Active Element: the active element's
            // normal alone) and a headless Blender with the bounds centre
            // (the whole selection's): measured by round 4's review on a
            // cube with faces 1 and 5 selected, 5 active, the port's and the
            // 3D View's Z was (0.221, -0.480, 0.849) and the bare call's
            // (0.218, -0.255, 0.942). So it goes with the port's matrix,
            // worked out when the re-run runs — after the rewind and the
            // selection's push, on the mesh as the drag found it — as
            // Blender's own panel works it out then.
            var scaling = false
            if case .resize = c.kind { scaling = true }
            let options = TransformOrientation.allCases.map { o -> Parameter.Option in
                if o != orientation, o == .normal, c.editing {
                    return Parameter.Option(OrientationBpy.orientTypeWorkedOut(o), o.label)
                }
                let axes: simd_float3x3?
                if o == orientation {
                    axes = o.commitsBare(scaling: scaling) ? nil : c.axes
                } else {
                    axes = o == .view ? c.viewAxes : nil
                }
                return Parameter.Option(OrientationBpy.orientType(o, axes: axes), o.label)
            }
            parameters.append(Parameter(key: "orient_type", label: "Orientation", kind: .literal(options),
                                        value: Double(orientation.rawValue), softMin: 0,
                                        softMax: Double(TransformOrientation.allCases.count - 1), step: 0.02))
        } else {
            fixed.append("orient_matrix=" + OrientationBpy.literal(c.axes))
        }
        if c.editing {
            parameters.append(Parameter(key: "mirror", label: "Mirror Editing", kind: .literal(onOff),
                                        value: c.mirror ? 1 : 0, softMin: 0, softMax: 1, step: 0.02))
        }
        let shown = Parameter.Condition("use_proportional_edit", is: 1)
        let p = c.proportional ?? c.proportionalDefaults
        parameters.append(Parameter(key: "use_proportional_edit", label: "Proportional Editing",
                                    kind: .literal(onOff), value: c.proportional == nil ? 0 : 1,
                                    softMin: 0, softMax: 1, step: 0.02))
        let falloffs = MeshEditor.ProportionalFalloff.allCases
        var falloff = Parameter(key: "proportional_edit_falloff", label: "Proportional Falloff",
                                kind: .choice(falloffs.map { Parameter.Option($0.bpyIdentifier, $0.label) }),
                                value: Double(falloffs.firstIndex(of: p.falloff) ?? 0), softMin: 0,
                                softMax: Double(falloffs.count - 1), step: 0.02)
        falloff.shownWhen = shown
        // Unitless, as Blender's `proportional_size` is (PROP_NONE): it read
        // "0.700 m" with the default unit (round 4's review).
        var size = Parameter(key: "proportional_size", label: "Proportional Size", kind: .float,
                             value: Double(p.size), softMin: Double(TransformToolSettings.sizeRange.lowerBound),
                             softMax: Double(TransformToolSettings.sizeRange.upperBound), step: 0.01,
                             unit: .none)
        // Five places, as `ToolsBpy.size` and the drag's own preview have it.
        size.places = 5
        size.keepsZeros = true
        size.shownWhen = shown
        var connected = Parameter(key: "use_proportional_connected", label: "Connected", kind: .literal(onOff),
                                  value: p.connected ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
        connected.shownWhen = shown
        parameters += [falloff, size, connected]

        let call: String
        var lead: String?
        var leading: [String] = []
        if c.individualOrigins, case .translate = c.kind {
            call = "bpy.ops.transform.translate"
        } else if c.individualOrigins {
            // One operator per object about its own origin: no single
            // `center_override` says Individual Origins (ToolsBpy).
            call = "_blenderkit_tools.transform_individual"
            lead = "import _blenderkit_tools"
            if case .rotate = c.kind { leading = ["'ROTATE'"] } else { leading = ["'RESIZE'"] }
        } else {
            switch c.kind {
            case .translate: call = "bpy.ops.transform.translate"
            case .rotate:    call = "bpy.ops.transform.rotate"
            case .resize:    call = "bpy.ops.transform.resize"
            }
        }
        var moving = false
        if case .translate = c.kind { moving = true }
        // Not for a move: `transform.translate` has no `center_override`
        // (measured in 5.2.1), and every pivot moves a selection the same.
        if !c.individualOrigins, !moving, let centre = c.centre {
            fixed.append(String(format: "center_override=(%.4f, %.4f, %.4f)", centre.x, centre.y, centre.z))
        }
        var op = LastOperator(name: c.name, call: call, parameters: parameters,
                              restoration: .throughBlenderUndo, needsEditMode: c.editing)
        op.fixedArguments = fixed
        op.leadingArguments = leading
        op.lead = lead
        op.afterward = c.afterward
        return op
    }

    /// The values a gizmo commit carries, read back from the call as Blender
    /// will read them: what the preview applies, digit for digit.
    static func committedValues(_ op: LastOperator) -> SIMD3<Float>? {
        let rows = op.parameters.filter {
            if case .component(let keyword, _, _) = $0.kind { return keyword == "value" }
            return false
        }
        guard rows.count == 3 else { return nil }
        let numbers = rows.compactMap { Float($0.formatted) }
        return numbers.count == 3 ? SIMD3(numbers[0], numbers[1], numbers[2]) : nil
    }

    /// The angle a gizmo Rotate carries, as printed.
    static func committedAngle(_ op: LastOperator) -> Float? {
        op.parameters.first { $0.key == "value" && $0.kind == .float }.flatMap { Float($0.formatted) }
    }
}
