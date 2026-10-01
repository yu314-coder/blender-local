import Foundation

/// Blender's viewport shading modes. Only the two Blender Local actually renders
/// are selectable; the others are listed so the header matches Blender's, and
/// are shown disabled rather than switching to nothing.
enum ViewportShading: String, CaseIterable, Identifiable {
    case wireframe, solid, material, rendered

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .wireframe: return "circle.dotted"
        case .solid:     return "circle.fill"
        case .material:  return "circle.lefthalf.filled"
        case .rendered:  return "sun.max.fill"
        }
    }

    var label: String {
        switch self {
        case .wireframe: return "Wireframe"
        case .solid:     return "Solid"
        case .material:  return "Material Preview"
        case .rendered:  return "Rendered"
        }
    }

    /// Rendered needs a render engine with lights and shadows; that does not
    /// exist here, so it stays disabled rather than switching to nothing.
    var isImplemented: Bool {
        self != .rendered
    }
}
