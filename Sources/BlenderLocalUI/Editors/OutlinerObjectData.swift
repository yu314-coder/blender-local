import SwiftUI

/// What Blender's Outliner nests under a camera or a light: its data-block,
/// with the icon Blender gives that data (`tree_element_get_icon_from_id` in
/// `outliner_draw.cc`). An empty has no data, so nothing.
///
/// It stands where a mesh object's mesh, modifier and material rows go — none
/// of which a camera or a light has.
struct OutlinerObjectData: View {
    var object: BKObject

    var body: some View {
        if let display = object.overlayDisplay, let name = display.dataName {
            HStack(spacing: 5) {
                Image(systemName: display.outlinerDataIcon)
                    .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
                Text(name)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(BTheme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 2 * 16 + 12)
            .frame(height: 20)
        }
    }
}
