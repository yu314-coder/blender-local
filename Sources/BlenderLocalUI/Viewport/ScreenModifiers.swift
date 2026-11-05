import SwiftUI
import UIKit

/// Shift, Ctrl and Alt on the screen, for a finger with no keyboard: Blender's
/// iPad design puts them in a wheel over the 3D View ("Wheel menu window
/// overlay (Ctrl/Cmd, Shift, Alt, …)", code.blender.org, "Beyond Mouse &
/// Keyboard"); here they sit at the foot of the toolbar. Each stays on, lit,
/// until it is tapped off, as the pick bar's Toggle Selection does, and while
/// it is on every gesture in the 3D View reads as if the key were held:
/// Shift-tap adds to the selection, Alt-tap selects a loop, Ctrl-tap a
/// shortest path, a Shift-drag extends a box, as Blender's keys do.
@Observable
final class ScreenModifiers {
    static let shared = ScreenModifiers()

    var shift = false
    var control = false
    var alt = false

    /// The keys held on the screen, as a keyboard reports them.
    var flags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if shift { flags.insert(.shift) }
        if control { flags.insert(.control) }
        if alt { flags.insert(.alternate) }
        return flags
    }

    /// A gesture's keys with the screen's added.
    func merged(_ keys: UIKeyModifierFlags) -> UIKeyModifierFlags { keys.union(flags) }
}

/// The toolbar's Shift, Ctrl and Alt (`ScreenModifiers`).
struct ScreenModifierKeys: View {
    @Bindable var keys = ScreenModifiers.shared

    var body: some View {
        VStack(spacing: 4) {
            key("Shift", isOn: $keys.shift)
            key("Ctrl", isOn: $keys.control)
            key("Alt", isOn: $keys.alt)
        }
    }

    private func key(_ name: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Color.white : BTheme.text)
                .frame(width: 56, height: 36)
                .background(isOn.wrappedValue ? BTheme.select : BTheme.widget.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(name)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}
