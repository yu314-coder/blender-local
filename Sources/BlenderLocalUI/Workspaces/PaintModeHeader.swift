import SwiftUI

/// Blender's tool header for its own Weight Paint and Vertex Paint: the brush,
/// the toolbar's Brush, Blur, Average and Smear, then what Blender's header
/// draws for them (`brush_shared_settings` in properties_paint_common.py,
/// 5.2.1): Blend, Weight (Weight Paint) or the colour (Vertex Paint), Size
/// and Strength.
///
/// Every control writes through `bridge.run` into Blender (`PaintModeBpy`),
/// and every value shown is Blender's, read back (`BpyBridge.paintState`)
/// whenever the history moves or a control here writes — a control never
/// shows a value Blender does not hold. The app's own Swift paint settings
/// (`BKScene.paint`) are the simulator's stand-in's and are not shown here.
struct PaintModeHeader: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    @State private var brushes: [String] = []
    /// Size, Strength and Weight while they are dragged; Blender's once written.
    @State private var sizeDraft: Float?
    @State private var strengthDraft: Float?
    @State private var weightDraft: Float?
    /// The colour while the picker moves; sent once it rests, so a drag
    /// across the picker is not a mirroring pass per sample.
    @State private var colourDraft: Color?
    @State private var colourSend: Task<Void, Never>?

    private var state: PaintModeState? { scene.paintBlender }
    private var weightMode: Bool { scene.mode == .weightPaint }

    var body: some View {
        HStack(spacing: 8) {
            brushMenu
            toolButtons
            if let blend = state?.blend, let blends = state?.blends,
               !weightMode || state?.brushType == "DRAW" {
                blendMenu(blend, blends)
            }
            if weightMode, let weight = state?.weight {
                BNumberField("Weight", value: Binding(get: { weightDraft ?? Float(weight) },
                                                      set: { weightDraft = min(max($0, 0), 1) }),
                             step: 0.01,
                             commit: { value in
                                 run(PaintModeBpy.setWeight(value))
                                 weightDraft = nil
                             })
                    .frame(width: 118)
            }
            if !weightMode, state?.color != nil {
                ColorPicker("", selection: colourBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30, height: 22)
                    .accessibilityLabel("Color")
            }
            if let size = state?.size {
                BNumberField("Size", value: Binding(get: { sizeDraft ?? Float(size) },
                                                    set: { sizeDraft = max(1, $0) }),
                             step: 1, unit: .pixels,
                             commit: { value in
                                 run(PaintModeBpy.setSize(Int(value.rounded())))
                                 sizeDraft = nil
                             })
                    .frame(width: 118)
            }
            if let strength = state?.strength {
                BNumberField("Strength", value: Binding(get: { strengthDraft ?? Float(strength) },
                                                        set: { strengthDraft = min(max($0, 0), 1) }),
                             step: 0.005,
                             commit: { value in
                                 run(PaintModeBpy.setStrength(value))
                                 strengthDraft = nil
                             })
                    .frame(width: 132)
            }
            if weightMode, let group = state?.group {
                Text(state?.groupLocked == true ? "\(group) (locked)" : group)
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    .lineLimit(1)
            }
        }
        // The brushes are the mode's own Essentials file.
        .task(id: scene.mode) {
            brushes = bridge?.paintBrushes() ?? []
            refresh()
        }
        // Blender's values, again whenever the history moves: a stroke, an
        // Undo, a script.
        .task(id: session.backendRevision) { refresh() }
    }

    private func refresh() {
        scene.paintBlender = bridge?.paintState()
    }

    private func run(_ python: String, undo: String? = nil) {
        // Not while a stroke is down: its chunks rewind the step on top of
        // Blender's stack (BpySession.sculptStrokeOpen). The bridge refuses it
        // too, in words; here nothing is sent at all.
        guard let bridge, !session.isRunning, !session.sculptStrokeOpen else { return }
        bridge.run(python, undo: undo)
        refresh()
    }

    @ViewBuilder
    private func checkRow(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Blender's Essentials brushes for the mode, as its asset shelf offers
    /// them, with the one Blender has checked.
    private var brushMenu: some View {
        Menu {
            if state?.essentials == false || brushes.isEmpty {
                Text("Blender's Essentials brushes are not in this build")
            }
            ForEach(brushes, id: \.self) { name in
                Button { run(PaintModeBpy.activate(name)) } label: {
                    checkRow(name, checked: state?.brush == name)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed")
                Text(state?.brush ?? "No Brush").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    /// Blender's toolbar for the two modes, lit where Blender's brush is.
    private var toolButtons: some View {
        HStack(spacing: 1) {
            ForEach(PaintTool.allCases, id: \.self) { tool in
                let on = state?.paintTool == tool
                Button { run(PaintModeBpy.setTool(tool)) } label: {
                    Text(tool.label)
                        .font(BTheme.Font.ui(11))
                        .foregroundStyle(on ? .white : BTheme.textDim)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(on ? BTheme.select : BTheme.widget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.label)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private func blendMenu(_ blend: String, _ blends: [[String]]) -> some View {
        Menu {
            ForEach(blends, id: \.self) { pair in
                if pair.count == 2 {
                    Button { run(PaintModeBpy.setBlend(pair[0])) } label: {
                        checkRow(pair[1], checked: pair[0] == blend)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Blend").font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                Text(blends.first { $0.first == blend }?.last ?? blend).font(BTheme.Font.ui(11))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
    }

    /// Blender's colour in sRGB, as Blender's own colour picker shows it:
    /// Blender holds the brush's scene linear (5.2.1's `Brush.color` is
    /// subtype COLOR), and `_blenderkit_vwpaint` converts both ways, so the
    /// swatch is the colour a stroke paints. This used to send the picker's
    /// sRGB as the linear value: 0.5 grey painted sRGB 0.737 (round 4's
    /// review). A change is sent once the picker has rested for a moment.
    private var colourBinding: Binding<Color> {
        Binding(
            get: {
                if let colourDraft { return colourDraft }
                let c = state?.color ?? [1, 1, 1]
                return Color(.sRGB, red: c.count > 0 ? c[0] : 1, green: c.count > 1 ? c[1] : 1,
                             blue: c.count > 2 ? c[2] : 1, opacity: 1)
            },
            set: { new in
                colourDraft = new
                colourSend?.cancel()
                colourSend = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    let rgb = UIColor(new).cgColor.converted(
                        to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
                        .components ?? [1, 1, 1, 1]
                    run(PaintModeBpy.setColor(SIMD3(Float(rgb[0]), Float(rgb.count > 2 ? rgb[1] : rgb[0]),
                                                    Float(rgb.count > 2 ? rgb[2] : rgb[0]))))
                    colourDraft = nil
                }
            })
    }
}
