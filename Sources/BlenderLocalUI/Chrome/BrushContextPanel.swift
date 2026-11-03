import SwiftUI

/// What a right-click opens in Sculpt Mode, Vertex Paint and Weight Paint:
/// Blender's brush panel (`VIEW3D_PT_sculpt_context_menu`,
/// `VIEW3D_PT_paint_vertex_context_menu`, `VIEW3D_PT_paint_weight_context_menu`)
/// — the brush, its Weight in Weight Paint, Radius and Strength, under
/// the labels the panel gives them — at the pointer, as a pop-up of fields.
///
/// The fields send what the mode's header sends (`SculptBpy`, `PaintModeBpy`)
/// and read Blender's values back after, so the header and this agree.
struct BrushContextPanel: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    @State private var size: Float?
    @State private var strength: Float?
    @State private var weight: Float?

    private var sculpting: Bool { scene.mode == .sculpt }
    private var weightMode: Bool { scene.mode == .weightPaint }

    /// The panel's label, Blender's `bl_label`.
    static func title(for mode: InteractionMode) -> String? {
        switch mode {
        case .sculpt:      return "Sculpt"
        case .vertexPaint: return "Vertex Paint"
        case .weightPaint: return "Weights"
        default:           return nil
        }
    }

    var body: some View {
        let brush = sculpting ? scene.sculptBlender?.brush : scene.paintBlender?.brush
        let current = sculpting
            ? (size: scene.sculptBlender?.size, strength: scene.sculptBlender?.strength, weight: Double?.none)
            : (size: scene.paintBlender?.size, strength: scene.paintBlender?.strength,
               weight: weightMode ? scene.paintBlender?.weight : nil)
        VStack(alignment: .leading, spacing: 6) {
            if let brush {
                Label(brush, systemImage: "paintbrush.pointed")
                    .font(BTheme.Font.ui(12))
                    .foregroundStyle(BTheme.textDim)
            }
            if let value = current.weight {
                BNumberField("Weight", value: Binding(get: { weight ?? Float(value) },
                                                      set: { weight = min(max($0, 0), 1) }),
                             step: 0.01,
                             commit: { send(PaintModeBpy.setWeight($0)); weight = nil })
            }
            if let value = current.size {
                BNumberField("Radius", value: Binding(get: { size ?? Float(value) },
                                                      set: { size = max(1, $0) }),
                             step: 1, unit: .pixels,
                             commit: { v in
                                 let px = Int(v.rounded())
                                 send(sculpting ? SculptBpy.setSize(px) : PaintModeBpy.setSize(px))
                                 size = nil
                             })
            }
            if let value = current.strength {
                BNumberField("Strength", value: Binding(get: { strength ?? Float(value) },
                                                        set: { strength = min(max($0, 0), 1) }),
                             step: 0.005,
                             commit: { v in
                                 send(sculpting ? SculptBpy.setStrength(v) : PaintModeBpy.setStrength(v))
                                 strength = nil
                             })
            }
            if current.size == nil && current.strength == nil {
                Text("Blender has no brush to show here")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
        }
        .frame(width: 230)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Not while a stroke is down, as the header's fields (its chunks rewind
    /// Blender's step); then Blender's values read back.
    private func send(_ python: String) {
        guard let bridge, !session.isRunning, !session.sculptStrokeOpen else { return }
        bridge.run(python)
        if sculpting { scene.sculptBlender = bridge.sculptState() } else { scene.paintBlender = bridge.paintState() }
    }
}
