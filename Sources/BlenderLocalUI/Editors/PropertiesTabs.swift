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
        case .data:        return "Data"
        case .material:    return "Material"
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
        // Constraints since round 4, group 7: Blender's Object Constraints.
        // Render, Output and World since November 9 (RenderPropertiesTabs.swift).
        case .render, .output, .scene, .world,
             .object, .modifiers, .constraints, .data, .material: return true
        default: return false
        }
    }

    /// The scene's tabs, above Blender's line: not about the active object.
    var isSceneTab: Bool {
        switch self {
        case .tool, .render, .output, .viewLayer, .scene, .world: return true
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

/// The tabs, down the editor's left side.
///
/// Lit as the toolbar and the Sidebar light theirs — filled, in white — so
/// which one is open reads at a glance: the open tab was a faint background a
/// shade off the column's, the others the same icons at 60 % (the user,
/// November 5: "make the side tab … easier to use"). Each a finger's size,
/// its name under it at a readable size, and a line under the scene tabs
/// where Blender groups them.
struct PropertiesTabColumn: View {
    @Binding var selection: PropertiesTab
    var hasActiveObject: Bool

    private var tabs: [PropertiesTab] { PropertiesTab.allCases.filter(\.isImplemented) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(tabs) { tab in
                    // Blender's order puts the scene's tabs first, then the
                    // object's; a line between the two, as Blender draws one.
                    if tab == .object { Rectangle().fill(BTheme.outline).frame(width: 40, height: 1).padding(.vertical, 2) }
                    tabButton(tab)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .frame(width: 76)
        .background(BTheme.outliner)
    }

    private func tabButton(_ tab: PropertiesTab) -> some View {
        let enabled = !tab.needsActiveObject || hasActiveObject
        let open = selection == tab
        return Button {
            if enabled { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(open ? Color.white : tab.accent.opacity(enabled ? 1 : 0.35))
                // Blender's tab names (`SpaceProperties.context`, 5.2.1),
                // whole: "Mods" and "Mat" were the app's.
                Text(tab.label)
                    .font(BTheme.Font.ui(11, weight: open ? .semibold : .regular))
                    .foregroundStyle(open ? Color.white : BTheme.text.opacity(enabled ? 0.9 : 0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 68, height: 56)
            .background(open ? BTheme.select : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(open ? .isSelected : [])
        .help(enabled ? tab.label : "\(tab.label): select an object first")
    }
}
