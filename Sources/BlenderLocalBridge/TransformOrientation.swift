import Foundation
import simd

/// Blender's transform orientations: the 3D View header's Orientation menu
/// (`scene.transform_orientation_slots[0].type`), which the gizmo's handles
/// follow and every Move, Rotate and Scale is measured in.
///
/// The names and their order are `TransformOrientationSlot.type`'s enum items,
/// read from 5.2.1's `bl_rna`: Global, Local, Normal, Gimbal, View, Cursor,
/// Parent. Until round 4 the only picker (ToolHeader's) was never on screen,
/// so every gizmo was Global (Local for a scale) whatever Blender held.
public enum TransformOrientation: Int, CaseIterable, Identifiable, Sendable {
    case global, local, normal, gimbal, view, cursor, parent

    public var id: Int { rawValue }

    public var bpyIdentifier: String {
        ["GLOBAL", "LOCAL", "NORMAL", "GIMBAL", "VIEW", "CURSOR", "PARENT"][rawValue]
    }

    /// The enum item's name, as the menu shows it.
    public var label: String {
        ["Global", "Local", "Normal", "Gimbal", "View", "Cursor", "Parent"][rawValue]
    }

    public init?(identifier: String) {
        guard let found = Self.allCases.first(where: { $0.bpyIdentifier == identifier }) else { return nil }
        self = found
    }

    /// Whether the axes turn with an object's transform — the active object's
    /// own, its parent's, its rotation channels — so that an animated one
    /// turns them as the frame changes: Local, Normal, Gimbal and Parent.
    /// Global, View and Cursor are the same at every frame.
    public var followsObject: Bool {
        switch self {
        case .local, .normal, .gimbal, .parent: return true
        case .global, .view, .cursor: return false
        }
    }

    /// Blender's icons for the items, as SF Symbols.
    public var icon: String {
        switch self {
        case .global: return "globe"
        case .local:  return "cube"
        case .normal: return "arrow.up.to.line"
        case .gimbal: return "gyroscope"
        case .view:   return "eye"
        case .cursor: return "scope"
        case .parent: return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Whether a drag in this orientation commits with `orient_type` alone,
    /// leaving Blender to work the matrix out, rather than with the matrix the
    /// gizmo was drawn on. Global is the identity either way. A Scale in Local
    /// goes bare: in Object Mode Blender scales each object along its own
    /// axes (`setLocalConstraint` → `setAxisMatrixConstraint`,
    /// transform_constraints.cc), which the preview does too, and a matrix
    /// would make them all the active object's (`orient_matrix_type ==
    /// orient_type` turns into CUSTOM_MATRIX). Every other drag goes with its
    /// matrix, so the axes it was previewed on are the axes it commits on —
    /// a Move in Local included, which with several objects then moves them
    /// all along the active object's axes as the gizmo shows, where
    /// Blender's own interactive Move would move each along its own. A
    /// Rotate in Local the same: every object turns about the active
    /// object's axis, where Blender's interactive Local Rotate
    /// (`setAxisMatrixConstraint`) turns each about its own. The preview
    /// shows what is committed in both.
    public func commitsBare(scaling: Bool) -> Bool {
        self == .global || (self == .local && scaling)
    }
}

/// The orientation Blender holds and its matrix, as `_blenderkit_orient`
/// reports them, for the gizmo to draw on.
public struct OrientationState: Equatable, Sendable {
    /// Nil for a custom orientation (one made with Create Orientation), whose
    /// name is `customName`.
    public var type: TransformOrientation?
    public var customName: String?
    /// Blender's matrix: X, Y and Z in world space, as columns. Nil for View,
    /// which the app's own view supplies, and when `unavailable` says why.
    public var axes: simd_float3x3?
    public var unavailable: String?

    public init(type: TransformOrientation?, customName: String? = nil,
                axes: simd_float3x3? = nil, unavailable: String? = nil) {
        self.type = type; self.customName = customName
        self.axes = axes; self.unavailable = unavailable
    }

    /// What the picker shows.
    public var label: String { type?.label ?? customName ?? "Custom" }

    /// `_blenderkit_orient.report()`'s line: the identifier, then nine numbers
    /// (X, Y, Z) or `none` and a reason. A custom orientation's identifier is
    /// its name, which may hold spaces, so the numbers are read from the end.
    ///
    /// The nine numbers are looked for first, so a custom orientation whose
    /// name holds " none" ("Pipe none") still reads as its matrix — it used
    /// to read as unavailable, with no gizmo (round 4's review). A line
    /// without them is `none`: after a built-in identifier when it starts
    /// with one, else after the first " none".
    public static func parse(_ line: String) -> OrientationState? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let words = text.split(separator: " ").map(String.init)
        if words.count >= 10 {
            let numbers = words.suffix(9).compactMap(Float.init)
            if numbers.count == 9 {
                guard numbers.allSatisfy(\.isFinite) else { return nil }
                let name = words.dropLast(9).joined(separator: " ")
                let axes = simd_float3x3(SIMD3(numbers[0], numbers[1], numbers[2]),
                                         SIMD3(numbers[3], numbers[4], numbers[5]),
                                         SIMD3(numbers[6], numbers[7], numbers[8]))
                let type = TransformOrientation(identifier: name)
                return OrientationState(type: type, customName: type == nil ? name : nil, axes: axes)
            }
        }
        let builtin = TransformOrientation.allCases.first {
            text == $0.bpyIdentifier + " none" || text.hasPrefix($0.bpyIdentifier + " none ")
        }
        let name: String
        let rest: Substring
        if let builtin {
            name = builtin.bpyIdentifier
            rest = text.dropFirst(name.count + " none".count)
        } else if let range = text.range(of: " none") {
            name = String(text[..<range.lowerBound])
            rest = text[range.upperBound...]
        } else {
            return nil
        }
        let why = rest.trimmingCharacters(in: .whitespaces)
        return OrientationState(type: builtin, customName: builtin == nil ? name : nil,
                                axes: nil, unavailable: why.isEmpty ? nil : why)
    }
}

/// The Python the Orientation menu and the gizmo send.
public enum OrientationBpy {

    /// The menu's choice, written into Blender's slot. A setting: no undo
    /// step, as the header's other settings (ToolsBpy).
    public static func set(_ orientation: TransformOrientation) -> String {
        "import _blenderkit_tools\n_blenderkit_tools.set_tools(orientation='\(orientation.bpyIdentifier)')"
    }

    /// What `BpyBridge.orientationState()` asks: Blender's orientation and its
    /// matrix, worked out on the edit mesh as it is (the bridge hands the
    /// viewport's selection over first).
    public static let report = "import _blenderkit_orient\nprint(_blenderkit_orient.report())"

    /// A matrix as `orient_matrix` takes it — its rows are the axes, measured
    /// in 5.2.1 (rows (0,1,0), (-1,0,0), (0,0,1) with value=(1, 2, 3) moved a
    /// cube to (-2, 1, 3)) — at six places, as `viewRotationArguments` has
    /// always written the view's.
    public static func literal(_ axes: simd_float3x3) -> String {
        // Never `-0.000000`, which a component a hair below zero prints as.
        func n(_ x: Float) -> String { LastOperator.fixed(Double(x), places: 6) }
        func row(_ v: SIMD3<Float>) -> String { "(\(n(v.x)), \(n(v.y)), \(n(v.z)))" }
        return "(\(row(axes.columns.0)), \(row(axes.columns.1)), \(row(axes.columns.2)))"
    }

    /// The matrix as `literal` prints it, which is what Blender multiplies
    /// by: the preview uses these numbers, not the unrounded ones.
    public static func printed(_ axes: simd_float3x3) -> simd_float3x3 {
        func p(_ x: Float) -> Float { Float((Double(x) * 1_000_000).rounded() / 1_000_000) + 0 }
        func v(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p(c.x), p(c.y), p(c.z)) }
        return simd_float3x3(v(axes.columns.0), v(axes.columns.1), v(axes.columns.2))
    }

    /// `orient_type`'s value as the call carries it: the identifier alone
    /// when `axes` is nil, so that Blender works the matrix out itself, else
    /// the identifier with its matrix and `orient_matrix_type`, as Blender's
    /// own Info log writes them — and with the two types equal Blender uses
    /// the matrix as given ("Constraints are forced to use the custom matrix
    /// when redoing", transform_generics.cc).
    public static func orientType(_ orientation: TransformOrientation, axes: simd_float3x3?) -> String {
        let name = "'\(orientation.bpyIdentifier)'"
        guard let axes else { return name }
        return name + ", orient_matrix=" + literal(axes) + ", orient_matrix_type=" + name
    }

    /// Align View to Active's matrix, asked of Blender (`_blenderkit_orient.
    /// active_axes`): nine numbers, or "none".
    public static let activeAxes = "import _blenderkit_orient\n_blenderkit_orient.active_axes()"

    /// `activeAxes`' answer as world axes (columns), or nil.
    public static func parseAxes(_ answer: String) -> simd_float3x3? {
        let numbers = answer.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Float($0) }
        guard numbers.count == 9, numbers.allSatisfy(\.isFinite) else { return nil }
        return simd_float3x3(SIMD3(numbers[0], numbers[1], numbers[2]), SIMD3(numbers[3], numbers[4], numbers[5]),
                             SIMD3(numbers[6], numbers[7], numbers[8]))
    }

    /// `orient_type`'s value with the port's matrix for `orientation`, worked
    /// out by `_blenderkit_orient.redo_matrix` when the call runs — for a
    /// redo panel's choice that has to be computed on the rewound scene, as
    /// Blender's panel computes it then (TransformCommit, Normal in Edit
    /// Mode). Self-contained, as one argument's value has to be: the import
    /// is inside it. The module refuses in words where the port has no answer.
    public static func orientTypeWorkedOut(_ orientation: TransformOrientation) -> String {
        let name = "'\(orientation.bpyIdentifier)'"
        return name + ", orient_matrix=__import__('_blenderkit_orient').redo_matrix(" + name
            + "), orient_matrix_type=" + name
    }

    /// Blender's Local, worked out from the object's world matrix as
    /// `transform_orientations_create_from_axis` does: each axis normalised.
    /// The gizmo's fallback before `_blenderkit_orient` has answered.
    public static func localAxes(_ model: simd_float4x4) -> simd_float3x3? {
        let columns = [model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz]
        guard columns.allSatisfy({ simd_length($0) > 1e-12 }) else { return nil }
        return simd_float3x3(simd_normalize(columns[0]), simd_normalize(columns[1]), simd_normalize(columns[2]))
    }
}
