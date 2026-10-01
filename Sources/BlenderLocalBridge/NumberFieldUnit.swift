import Foundation

/// What a number field's value means, and how it reads and writes as text.
///
/// Blender labels its number fields with a unit — metres for distance,
/// degrees for rotation, bare for a factor — and a field can be dragged to
/// scrub or tapped to type. Both directions of that text live here rather
/// than in the view, so they can be checked without a screen.
public enum NumberFieldUnit: Sendable {
    case none, meters, degrees, percent
    /// A whole number of things — vertices, segments, subdivisions.
    case count
    /// A distance too small for three places: Mirror's merge distance, 0.001
    /// by default, which Blender's field shows to six. At three, 0.0005 read
    /// "0.001" — a value Blender did not hold.
    case fineMeters
    /// Pixels, whole: a sculpt brush's Size, which Blender measures across
    /// the view it strokes in.
    case pixels
    /// A small length in an object's own units, which its scale makes differ
    /// from the scene's metres: a mesh's voxel size, which Voxel Remesh
    /// measures in the mesh's units (voxel_remesh_exec), shown to six places
    /// as `fineMeters` is, without a unit it does not have.
    case fine

    /// The value as the field shows it at rest.
    public func format(_ value: Float) -> String {
        switch self {
        case .none:    return String(format: "%.3f", value)
        case .meters:  return String(format: "%.3f m", value)
        case .degrees: return String(format: "%.1f°", value * 180 / .pi)
        case .percent: return String(format: "%.0f%%", value * 100)
        case .count:   return String(Int(value.rounded()))
        case .pixels:  return String(Int(value.rounded())) + " px"
        case .fineMeters:
            return Self.sixPlaces(value) + " m"
        case .fine:
            return Self.sixPlaces(value)
        }
    }

    /// The value as a number to edit: no unit, and no trailing zeros to
    /// delete before typing. A rotation is shown in degrees, so it is typed
    /// in degrees too.
    public func editable(_ value: Float) -> String {
        switch self {
        case .count, .pixels: return String(Int(value.rounded()))
        case .degrees: return Self.plain(value * 180 / .pi)
        case .percent: return Self.plain(value * 100)
        // Six significant digits, not `plain`'s four places, which would
        // round the distance being edited.
        case .fineMeters, .fine: return String(format: "%g", Double(value))
        default:       return Self.plain(value)
        }
    }

    /// What was typed, back as a value — with the unit's own suffix, a comma
    /// for a decimal point, or stray spaces all accepted. Nil when it is not
    /// a number, so the field keeps what it had rather than reading as zero.
    public func typed(_ text: String) -> Float? {
        var cleaned = text.replacingOccurrences(of: ",", with: ".")
        if case .pixels = self { cleaned = cleaned.replacingOccurrences(of: "px", with: "") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n°%m"))
        guard let number = Float(cleaned), number.isFinite else { return nil }
        switch self {
        case .degrees: return number * .pi / 180
        case .percent: return number / 100
        case .count, .pixels: return number.rounded()
        default:       return number
        }
    }

    /// Six places, with the zeros past the third dropped.
    private static func sixPlaces(_ value: Float) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."),
              text.distance(from: dot, to: text.endIndex) > 4 {
            text.removeLast()
        }
        return text
    }

    /// Four decimal places at most, and none of them trailing zeros.
    private static func plain(_ value: Float) -> String {
        String(format: "%g", (Double(value) * 10000).rounded() / 10000)
    }
}
