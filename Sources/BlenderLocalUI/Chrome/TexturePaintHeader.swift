import SwiftUI
import UIKit

/// Blender's Texture Paint brush settings, in the tool row: the colour, then
/// Size and Strength each with its pressure toggle, then the blend mode and
/// the falloff — the order Blender's header draws them
/// (`brush_basic_texpaint_settings`). Blur and Smear move colour that is
/// already there, so, as in Blender, they have no colour and no blend.
///
/// Size is the unified brush size, shared by every brush, and the number
/// Blender's header shows: a diameter in the viewport's pixels. The rest belong
/// to the brush in hand, so switching from Draw to Smear shows Smear's strength.
struct TexturePaintHeader: View {
    var scene: BKScene
    var tool: ActiveTool

    private var paintTool: TexturePaintTool { tool.texturePaintTool ?? .draw }

    private var brush: Binding<TexturePaintBrush> {
        Binding(get: { scene.paint.texturePaint[paintTool] },
                set: { scene.paint.texturePaint[paintTool] = $0 })
    }

    var body: some View {
        HStack(spacing: 6) {
            if paintTool == .draw {
                colour
            }
            BNumberField("Size", value: Binding(
                get: { scene.paint.texturePaint.size },
                set: { scene.paint.texturePaint.size = max(1, min($0.rounded(), 2000)) }),
                step: 1, unit: .count)
                .frame(width: 104)
            pressure(brush.usePressureSize, label: "Size Pressure")
            BNumberField("Strength", value: Binding(
                get: { brush.wrappedValue.strength },
                set: { brush.wrappedValue.strength = max(0, min($0, 1)) }),
                step: 0.01)
                .frame(width: 118)
            pressure(brush.usePressureStrength, label: "Strength Pressure")
            if paintTool == .draw {
                blend
            }
            falloff
        }
        .foregroundStyle(BTheme.text)
    }

    private var colour: some View {
        ColorPicker("Color", selection: Binding(
            get: {
                let c = scene.paint.texturePaint.colour
                return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            },
            set: { value in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
                scene.paint.texturePaint.colour = SIMD3(Float(max(0, min(r, 1))),
                                                        Float(max(0, min(g, 1))),
                                                        Float(max(0, min(b, 1))))
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 34, height: 28)
            .accessibilityLabel("Brush Color")
    }

    /// Blender's pen icon beside a slider: whether Apple Pencil pressure
    /// scales it.
    private func pressure(_ isOn: Binding<Bool>, label: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: "applepencil")
                .font(.system(size: 12))
                .foregroundStyle(isOn.wrappedValue ? Color.white : BTheme.textDim)
                .frame(width: 26, height: 22)
                .background(isOn.wrappedValue ? BTheme.select : BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private var blend: some View {
        Menu {
            ForEach(BrushBlend.allCases) { mode in
                Button {
                    brush.wrappedValue.blend = mode
                } label: {
                    Label(mode.label, systemImage: brush.wrappedValue.blend == mode ? "checkmark" : "")
                }
            }
        } label: {
            chip("Blend", brush.wrappedValue.blend.label)
        }
    }

    private var falloff: some View {
        Menu {
            Button {
                brush.wrappedValue.falloff = TexturePaintBrush.essentials(paintTool).falloff
            } label: {
                Label("\(paintTool.blenderBrush) (default)",
                      systemImage: brush.wrappedValue.falloff == TexturePaintBrush.essentials(paintTool).falloff
                        ? "checkmark" : "")
            }
            Divider()
            ForEach(BrushFalloff.allCases) { preset in
                Button {
                    brush.wrappedValue.falloff = .preset(preset)
                } label: {
                    Label(preset.label, systemImage: brush.wrappedValue.falloff == .preset(preset) ? "checkmark" : "")
                }
            }
        } label: {
            chip("Falloff", brush.wrappedValue.falloff.label)
        }
    }

    private func chip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            Text(value).font(BTheme.Font.ui(11))
            Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(BTheme.textDim)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(BTheme.widget)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }
}
