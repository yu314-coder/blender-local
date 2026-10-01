import SwiftUI

/// Blender's ID datablock selector — the control it uses for Scene, View Layer,
/// materials, meshes and everything else with a name.
///
/// Structure, left to right: a browse well with the datatype icon and a
/// chevron, the name field, then the action buttons. Blender greys the unlink
/// "X" when the datablock cannot be unlinked, which is the case for the only
/// scene in a file.
struct BDatablockSelector: View {
    var icon: String
    var name: String
    /// Blender shows a pin on the Scene selector but not on View Layer.
    var showsPin: Bool = false
    var browse: [String] = []

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                if browse.isEmpty {
                    Text("Only one \(name.lowercased())").disabled(true)
                } else {
                    ForEach(browse, id: \.self) { Text($0) }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: icon).font(.system(size: 10))
                    Image(systemName: "chevron.down").font(.system(size: 6))
                }
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(BTheme.topbar)
            }

            Text(name)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 10)
                .frame(minWidth: 74, alignment: .leading)
                .frame(height: 24)
                .background(BTheme.fieldTopbar)

            if showsPin {
                action("pin", enabled: true)
            }
            action("doc.on.doc", enabled: true)
            // Unlink is unavailable with a single datablock, as in Blender.
            action("xmark", enabled: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        .overlay {
            RoundedRectangle(cornerRadius: BTheme.Metric.corner)
                .strokeBorder(BTheme.outline.opacity(0.6), lineWidth: BTheme.Metric.hairline)
        }
    }

    @ViewBuilder
    private func action(_ icon: String, enabled: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundStyle(enabled ? BTheme.text : Color(hex: 0x353535))
            .frame(width: 22, height: 24)
            .background(BTheme.fieldTopbar)
    }
}
