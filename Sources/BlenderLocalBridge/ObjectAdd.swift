import Foundation
import simd

/// What Blender's Add menu makes besides meshes: `VIEW3D_MT_add`'s Curve,
/// Text, Empty, Light and Camera entries.
public enum ObjectAddition: Hashable, Sendable {
    case curve(CurveKind)
    case text
    case empty(EmptyDisplay.Kind)
    case light(LightDisplay.Kind)
    case camera
    /// `VIEW3D_MT_add`'s Lattice row: `object.add(type='LATTICE')`.
    case lattice

    /// `VIEW3D_MT_curve_add`'s first two rows, the Bézier ones. The NURBS
    /// rows, Empty Hair and Fur are not offered.
    public enum CurveKind: String, CaseIterable, Sendable {
        case bezier, circle

        /// The menu's own words for them.
        public var label: String { self == .bezier ? "Bézier" : "Circle" }
        public var icon: String { self == .bezier ? "scribble.variable" : "circle.dashed" }
    }

    /// The menu entry's text.
    public var label: String {
        switch self {
        case .curve(let kind): return kind.label
        case .text:            return "Text"
        case .empty(let kind): return kind.label
        case .light(let kind): return kind.label
        case .camera:          return "Camera"
        case .lattice:         return "Lattice"
        }
    }

    public var icon: String {
        switch self {
        case .curve(let kind): return kind.icon
        case .text:            return "textformat"
        case .empty(let kind): return kind.icon
        case .light(let kind): return kind.icon
        case .camera:          return "camera"
        case .lattice:         return "grid"
        }
    }

    /// The XYZ Euler angles of a rotation, chosen as Blender chooses them
    /// (`mat3_normalized_to_eul` in `blenlib/intern/math_rotation.cc`): of the
    /// two triples that give the rotation, the one with the smaller angles.
    public static func eulerXYZ(_ m: simd_float3x3) -> SIMD3<Float> {
        // Blender's mat[column][row] is simd's columns.column[row].
        let m00 = m.columns.0.x, m01 = m.columns.0.y, m02 = m.columns.0.z
        let m12 = m.columns.1.z, m11 = m.columns.1.y
        let m22 = m.columns.2.z, m21 = m.columns.2.y
        let cy = hypot(m00, m01)
        let first, second: SIMD3<Float>
        if cy > 16 * Float.ulpOfOne {
            first = SIMD3(atan2(m12, m22), atan2(-m02, cy), atan2(m01, m00))
            second = SIMD3(atan2(-m12, -m22), atan2(-m02, -cy), atan2(-m01, -m00))
        } else {
            first = SIMD3(atan2(-m21, m11), atan2(-m02, cy), 0)
            second = first
        }
        let size: (SIMD3<Float>) -> Float = { abs($0.x) + abs($0.y) + abs($0.z) }
        return size(first) > size(second) ? second : first
    }
}

public extension LastOperator {

    /// A curve, text, camera, light or empty, added the way Blender's Add menu
    /// adds one.
    ///
    /// Read out of `get_rna_type()` in Blender 5.2.1, as the primitives were:
    /// `light_add` and `empty_add` take Type and Radius, `camera_add` neither.
    ///
    /// Blender forces a camera added from the 3D View to face the way the view
    /// faces (`object_camera_add_exec` sets `align='VIEW'`), and its Info log
    /// then spells out the rotation. A Blender with no window has no view to
    /// align to and leaves the camera pointing at the floor, so the interface
    /// passes the view's rotation itself — `viewRotation`, the rotation whose
    /// axes are the view's right, up and back.
    ///
    /// The same function makes the first camera the scene's camera when the
    /// scene has none, which is what renders go through. A windowless Blender
    /// skips that too, so it follows the call.
    static func add(_ addition: ObjectAddition, at location: SIMD3<Float>,
                    viewRotation: simd_float3x3? = nil) -> LastOperator {
        let place = SIMD3<Double>(Double(location.x), Double(location.y), Double(location.z))
        let radius = Parameter(key: "radius", label: "Radius", kind: .float,
                               value: 1, softMin: 0.001, softMax: 100, step: 0.01)
        switch addition {
        case .curve(let kind):
            // Read out of `get_rna_type()` in 5.2.1: Radius, then the
            // placement every add takes. Blender names them "Add Bézier" and
            // "Add Bézier Circle", and the objects "BézierCurve" and
            // "BézierCircle". Neither is filled or bevelled, so each is a wire
            // (13 vertices and 12 edges, 48 and 48, measured), which the
            // mirror sends as edges.
            var op = LastOperator(
                name: kind == .bezier ? "Add Bézier" : "Add Bézier Circle",
                call: kind == .bezier ? "bpy.ops.curve.primitive_bezier_curve_add"
                                      : "bpy.ops.curve.primitive_bezier_circle_add",
                parameters: [radius], location: place, restoration: .removeCreated)
            // A curve's data-block lives in `bpy.data.curves`, which a re-run
            // has to empty the old one out of.
            op.dataCollection = "curves"
            return op

        case .text:
            // "Text" in the default font, filled: 177 vertices and 171 faces
            // (measured). Its body is Blender's text edit mode, which is typed
            // into a 3D View this app does not have.
            var op = LastOperator(name: "Add Text", call: "bpy.ops.object.text_add",
                                  parameters: [radius], location: place,
                                  restoration: .removeCreated)
            // A text object's data is a TextCurve, in `bpy.data.curves` too.
            op.dataCollection = "curves"
            return op

        case .lattice:
            return addLattice(at: location)

        case .camera:
            var op = LastOperator(name: "Add Camera", call: "bpy.ops.object.camera_add",
                                  parameters: [], location: place, restoration: .removeCreated)
            if let viewRotation {
                let e = ObjectAddition.eulerXYZ(viewRotation)
                op.fixedArguments = ["align='VIEW'",
                                     "rotation=(\(number(Double(e.x))), \(number(Double(e.y))), "
                                     + "\(number(Double(e.z))))"]
            }
            op.followUp = "if bpy.context.scene.camera is None: "
                + "bpy.context.scene.camera = bpy.context.object"
            op.dataCollection = "cameras"
            return op

        case .light(let kind):
            let kinds = LightDisplay.Kind.allCases
            let type = Parameter(key: "type", label: "Type",
                                 kind: .choice(kinds.map { Parameter.Option($0.rawValue, $0.label) }),
                                 value: Double(kinds.firstIndex(of: kind) ?? 0),
                                 softMin: 0, softMax: Double(kinds.count - 1), step: 0.02)
            var op = LastOperator(name: "Add Light", call: "bpy.ops.object.light_add",
                                  parameters: [type, radius], location: place,
                                  restoration: .removeCreated)
            op.dataCollection = "lights"
            return op

        case .empty(let kind):
            // The panel offers every display type, Image too, as Blender's does.
            let kinds = EmptyDisplay.Kind.allCases
            let type = Parameter(key: "type", label: "Type",
                                 kind: .choice(kinds.map { Parameter.Option($0.rawValue, $0.label) }),
                                 value: Double(kinds.firstIndex(of: kind) ?? 0),
                                 softMin: 0, softMax: Double(kinds.count - 1), step: 0.02)
            return LastOperator(name: "Add Empty", call: "bpy.ops.object.empty_add",
                                parameters: [type, radius], location: place,
                                restoration: .removeCreated)
        }
    }
}
