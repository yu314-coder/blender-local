import SwiftUI

/// The vertical icon strip down the left of Blender's Properties editor.
///
/// Blender shows all thirteen tabs whether or not they apply. Eight of them
/// have nothing behind them here, and eight dimmed icons in a 34-point column
/// are eight things to squint at and rule out. Only the five that open
/// something are listed, which leaves room to name them — on a tablet there is
/// no hover to reveal what an icon means.
enum PropertiesTab: String, CaseIterable, Identifiable {
    case tool, render, output, viewLayer, scene, world
    case object, modifiers, particles, physics, constraints, data, material

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tool:        return "Tool"
        case .render:      return "Render"
        case .output:      return "Output"
        case .viewLayer:   return "View Layer"
        case .scene:       return "Scene"
        case .world:       return "World"
        case .object:      return "Object"
        case .modifiers:   return "Modifiers"
        case .particles:   return "Particles"
        case .physics:     return "Physics"
        case .constraints: return "Constraints"
        case .data:        return "Object Data"
        case .material:    return "Material"
        }
    }

    /// Short enough to sit under the icon in a 46-point column.
    var shortLabel: String {
        switch self {
        case .data: return "Data"
        case .material: return "Mat"
        case .modifiers: return "Mods"
        default: return label
        }
    }

    var icon: String {
        switch self {
        case .tool:        return "wrench.adjustable"
        case .render:      return "camera.aperture"
        case .output:      return "printer"
        case .viewLayer:   return "square.3.layers.3d"
        case .scene:       return "cone"
        case .world:       return "globe.americas"
        case .object:      return "square.on.square"
        case .modifiers:   return "wrench.and.screwdriver"
        case .particles:   return "sparkles"
        case .physics:     return "atom"
        case .constraints: return "link"
        case .data:        return "triangle"
        case .material:    return "circle.righthalf.filled"
        }
    }

    /// Blender's tab accent colours: object-level tabs are orange, data green,
    /// material red, scene tabs neutral.
    var accent: Color {
        switch self {
        case .object, .modifiers, .constraints, .physics, .particles: return BTheme.active
        case .data:      return Color(hex: 0x7BC629)
        case .material:  return Color(hex: 0xE5486A)
        default:         return BTheme.textDim
        }
    }

    var isImplemented: Bool {
        switch self {
        case .object, .modifiers, .data, .material, .scene: return true
        default: return false
        }
    }

    /// Tabs that only make sense with something selected.
    var needsActiveObject: Bool {
        switch self {
        case .object, .modifiers, .data, .material, .constraints, .physics, .particles:
            return true
        default:
            return false
        }
    }
}

struct PropertiesTabColumn: View {
    @Binding var selection: PropertiesTab
    var hasActiveObject: Bool

    private var tabs: [PropertiesTab] { PropertiesTab.allCases.filter(\.isImplemented) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let enabled = !tab.needsActiveObject || hasActiveObject
                    Button {
                        if enabled { selection = tab }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                            Text(tab.shortLabel)
                                .font(BTheme.Font.ui(8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selection == tab ? tab.accent
                                         : tab.accent.opacity(enabled ? 0.6 : 0.25))
                        .frame(width: 46, height: 36)
                        .background(selection == tab ? BTheme.properties : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .disabled(!enabled)
                    .accessibilityLabel(tab.label)
                    .help(tab.label)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
        }
        .frame(width: 52)
        .background(BTheme.outliner)
    }
}
