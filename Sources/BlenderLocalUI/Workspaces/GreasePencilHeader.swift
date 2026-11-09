import SwiftUI
import simd

/// Blender's Draw Mode tool header, for a Grease Pencil object: with the
/// Brush tool the brush (the Essentials Grease Pencil Draw brushes), the
/// colour — the object's material slots as swatches, and a new material from
/// a colour — the active layer, Size and Strength with their pressure
/// toggles, and Additive Drawing; with Erase the eraser's Mode, Size and
/// Active Layer.
///
/// Every value shown is Blender's, read back (`BpyBridge.greasePencilState`,
/// the object's `greasePencilInfo`) whenever the history moves; each control
/// writes through `bridge.run`, a number field once when its drag ends.
struct GreasePencilHeader: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var tool: ActiveTool

    @State private var brushes: [String] = []
    @State private var sizeDraft: Float?
    @State private var strengthDraft: Float?
    @State private var eraserDraft: Float?
    @State private var showColour = false
    @State private var newColour = Color(red: 0.1, green: 0.1, blue: 0.1)

    private var state: GPDrawState? { scene.greasePencilDraw }
    private var info: GreasePencilInfo? { scene.active?.greasePencilInfo }

    var body: some View {
        HStack(spacing: 8) {
            if tool == .gpErase {
                eraserControls
            } else {
                brushMenu
                swatches
                layerMenu
                sizeField
                strengthField
                additiveToggle
            }
        }
        .task { brushes = bridge?.greasePencilBrushes() ?? [] }
        .task(id: session.backendRevision) { refresh() }
    }

    private func refresh() {
        let next = bridge?.greasePencilState()
        if next != scene.greasePencilDraw { scene.greasePencilDraw = next }
    }

    private func run(_ python: String, undo: String? = nil) {
        guard let bridge, !session.isRunning else { return }
        bridge.run(python, undo: undo)
        refresh()
    }

    // MARK: the brush

    /// The Draw brushes of Blender's Essentials library (the asset shelf's
    /// Grease Pencil Draw catalogue); the eraser, fill and tint brushes
    /// belong to their own tools.
    private var drawBrushes: [String] {
        brushes.filter { !$0.hasPrefix("Eraser") && $0 != "Fill" && $0 != "Tint" }
    }

    private var brushMenu: some View {
        Menu {
            if drawBrushes.isEmpty { Text("Blender's Essentials brushes are not in this build") }
            ForEach(drawBrushes, id: \.self) { name in
                Button { run(GreasePencilBpy.activate(name)) } label: {
                    if state?.brush?.name == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip")
                Text(state?.brush?.name ?? "No Brush").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    // MARK: colour: the material slots

    /// The object's Grease Pencil materials as swatches of their stroke
    /// colour, the active slot ringed; a tap makes a slot the active one,
    /// which is what new strokes are drawn with. "+" makes a new material
    /// from a picked colour.
    private var swatches: some View {
        HStack(spacing: 4) {
            if let object = scene.active, let info {
                ForEach(Array(info.materials.enumerated()), id: \.offset) { index, material in
                    if let material {
                        Button {
                            if index != info.activeMaterial {
                                run(GreasePencilBpy.materialActive(object.name, index: index),
                                    undo: GreasePencilBpy.materialActiveUndo)
                            }
                        } label: {
                            swatch(material, active: index == info.activeMaterial)
                        }
                        .accessibilityLabel(material.name)
                    }
                }
                Button { showColour = true } label: {
                    Image(systemName: "plus")
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("New Material")
                .popover(isPresented: $showColour) { newMaterial(object.name).padding(14) }
            }
        }
    }

    private func swatch(_ material: GPMaterial, active: Bool) -> some View {
        let shown = GreasePencilGeometry.display(SIMD3(material.stroke.x, material.stroke.y, material.stroke.z))
        return Circle()
            .fill(Color(red: Double(shown.x), green: Double(shown.y), blue: Double(shown.z)))
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(active ? Color.white : BTheme.outline, lineWidth: active ? 2.5 : 1))
            .frame(width: 32, height: 40)
            .contentShape(Rectangle())
    }

    private func newMaterial(_ object: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Material").font(BTheme.Font.ui(14, weight: .semibold))
            ColorPicker("Base Color", selection: $newColour, supportsOpacity: false)
                .font(BTheme.Font.ui(13))
            BButton("New Material", icon: "plus") {
                let c = UIColor(newColour)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                showColour = false
                run(GreasePencilBpy.materialAdd(object, colour: SIMD3(Float(r), Float(g), Float(b))),
                    undo: GreasePencilBpy.materialAddUndo)
            }
        }
        .frame(width: 260)
    }

    // MARK: the layer

    /// The active layer, and the others to make active: Blender's Draw Mode
    /// header has the layer's popover here.
    private var layerMenu: some View {
        Menu {
            if let object = scene.active, let info {
                ForEach(Array(info.layers.enumerated().reversed()), id: \.offset) { index, layer in
                    Button {
                        if index != info.activeLayer {
                            run(GreasePencilBpy.layerActive(object.name, layer: layer.name),
                                undo: GreasePencilBpy.layerActiveUndo)
                        }
                    } label: {
                        if index == info.activeLayer { Label(layer.name, systemImage: "checkmark") }
                        else { Text(layer.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                Text(info?.active?.name ?? "No Layer").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    // MARK: Size and Strength

    @ViewBuilder private var sizeField: some View {
        if let brush = state?.brush {
            HStack(spacing: 2) {
                if brush.sceneUnit {
                    // Blender's header shows Unprojected Size as Size when
                    // the brush's Size Unit is Scene, as the Pencil's is.
                    BNumberField("Size", value: Binding(get: { sizeDraft ?? brush.unprojectedSize },
                                                        set: { sizeDraft = max(0.001, $0) }),
                                 step: 0.001, unit: .meters,
                                 commit: { value in
                                     run(GreasePencilBpy.setBrush("unprojected_size", String(format: "%.6g", value)))
                                     sizeDraft = nil
                                 })
                        .frame(width: 128)
                } else {
                    BNumberField("Size", value: Binding(get: { sizeDraft ?? brush.size },
                                                        set: { sizeDraft = max(1, $0) }),
                                 step: 1, unit: .pixels,
                                 commit: { value in
                                     run(GreasePencilBpy.setBrush("size", "\(Int(value.rounded()))"))
                                     sizeDraft = nil
                                 })
                        .frame(width: 118)
                }
                pressureToggle("Size Pressure", on: brush.usePressureSize, key: "use_pressure_size")
            }
        }
    }

    @ViewBuilder private var strengthField: some View {
        if let brush = state?.brush {
            HStack(spacing: 2) {
                BNumberField("Strength", value: Binding(get: { strengthDraft ?? brush.strength },
                                                        set: { strengthDraft = min(max($0, 0), 1) }),
                             step: 0.005,
                             commit: { value in
                                 run(GreasePencilBpy.setBrush("strength", String(format: "%.4g", value)))
                                 strengthDraft = nil
                             })
                    .frame(width: 132)
                pressureToggle("Strength Pressure", on: brush.usePressureStrength, key: "use_pressure_strength")
            }
        }
    }

    /// A brush setting's pressure toggle, Blender's pen icon beside it.
    private func pressureToggle(_ name: String, on: Bool, key: String) -> some View {
        Button { run(GreasePencilBpy.setBrush(key, on ? "False" : "True")) } label: {
            Image(systemName: on ? "hand.point.up.left.fill" : "hand.point.up.left")
                .foregroundStyle(on ? Color.white : BTheme.textDim)
                .frame(width: 36, height: 40)
                .background(on ? BTheme.select.opacity(0.7) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
    }

    /// Additive Drawing: a new keyframe starts as a copy of the one before.
    private var additiveToggle: some View {
        let on = state?.additive == true
        return Button {
            run(GreasePencilBpy.setTool("use_gpencil_draw_additive", !on))
        } label: {
            Label("Additive Drawing", systemImage: on ? "square.filled.on.square" : "square.on.square")
                .foregroundStyle(on ? Color.white : BTheme.text)
                .padding(.horizontal, 10).frame(height: 40)
                .background(on ? BTheme.select : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
    }

    // MARK: Erase

    private var eraserControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(GPEraserMode.allCases, id: \.self) { mode in
                    let on = scene.greasePencilEraser.mode == mode
                    Button { scene.greasePencilEraser.mode = mode } label: {
                        Text(mode.label)
                            .foregroundStyle(on ? Color.white : BTheme.text)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(on ? BTheme.select : BTheme.widget)
                            .contentShape(Rectangle())
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            BNumberField("Size", value: Binding(get: { eraserDraft ?? scene.greasePencilEraser.size },
                                                set: { eraserDraft = min(max($0, 2), 500) }),
                         step: 1, unit: .pixels,
                         commit: { value in
                             scene.greasePencilEraser.size = value.rounded()
                             eraserDraft = nil
                         })
                .frame(width: 118)
            let only = scene.greasePencilEraser.activeLayerOnly
            Button { scene.greasePencilEraser.activeLayerOnly.toggle() } label: {
                Label("Active Layer", systemImage: only ? "checkmark.square.fill" : "square")
                    .padding(.horizontal, 10).frame(height: 40)
                    .contentShape(Rectangle())
            }
        }
    }
}
