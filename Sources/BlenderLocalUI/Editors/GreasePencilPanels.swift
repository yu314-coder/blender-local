import SwiftUI
import simd

/// Blender's Object Data panels for a Grease Pencil object
/// (`properties_data_grease_pencil.py`, 5.2.1): Layers — the list, top layer
/// first, each with its Onion Skinning, Hide and Locked toggles; + (Add New
/// Layer), − (Remove Layer), the arrows (Reorder Layer); the active layer's
/// Opacity — then Onion Skinning and Settings.
///
/// Every value is Blender's as the mirror last read it (`greasePencilInfo`);
/// every control is one `bridge.run`, one undo step named as Blender names
/// it, and the mirror brings the change back.
struct GreasePencilDataPanels: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject

    @State private var opacityDraft: Float?
    @State private var onionDraft: Float?
    @State private var renaming: String?
    @State private var newName = ""

    private var info: GreasePencilInfo? { object.greasePencilInfo }

    var body: some View {
        if let info {
            layersPanel(info)
            onionPanel(info)
            BPanel("Settings") {
                picker("Stroke Depth Order", [("2D", "2D Layers"), ("3D", "3D Location")],
                       selected: info.depthOrder3D ? "3D" : "2D") { value in
                    run(GreasePencilBpy.onionSet(object.name, "stroke_depth_order", "'\(value)'"),
                        undo: "Stroke Depth Order")
                }
            }
        }
    }

    // MARK: Layers

    private func layersPanel(_ info: GreasePencilInfo) -> some View {
        BPanel("Layers") {
            VStack(spacing: 2) {
                // Blender lists the top layer first.
                ForEach(Array(info.layers.enumerated().reversed()), id: \.offset) { index, layer in
                    layerRow(layer, active: index == info.activeLayer)
                }
                if info.layers.isEmpty {
                    Text("No layers").font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 4) {
                iconButton("plus", "Add New Layer") {
                    run(GreasePencilBpy.layerAdd, undo: GreasePencilBpy.layerAddUndo)
                }
                iconButton("minus", "Remove Layer", enabled: info.active != nil) {
                    run(GreasePencilBpy.layerRemove, undo: GreasePencilBpy.layerRemoveUndo)
                }
                Spacer()
                iconButton("chevron.up", "Reorder Layer", enabled: info.active != nil) {
                    run(GreasePencilBpy.layerMove(up: true), undo: GreasePencilBpy.layerMoveUndo)
                }
                iconButton("chevron.down", "Reorder Layer", enabled: info.active != nil) {
                    run(GreasePencilBpy.layerMove(up: false), undo: GreasePencilBpy.layerMoveUndo)
                }
            }
            if let layer = info.active {
                BNumberField("Opacity", value: Binding(get: { opacityDraft ?? layer.opacity },
                                                       set: { opacityDraft = min(max($0, 0), 1) }),
                             step: 0.01,
                             commit: { value in
                                 opacityDraft = nil
                                 setLayer(layer, "opacity", String(format: "%.4g", value))
                             })
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("OK") {
                if let old = renaming, !newName.isEmpty, newName != old,
                   let layer = info.layers.first(where: { $0.name == old }) {
                    setLayer(layer, "name", Bpy.quote(newName))
                }
                renaming = nil
            }
        }
    }

    private func layerRow(_ layer: GPLayer, active: Bool) -> some View {
        HStack(spacing: 2) {
            Button {
                if !active {
                    run(GreasePencilBpy.layerActive(object.name, layer: layer.name),
                        undo: GreasePencilBpy.layerActiveUndo)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 12))
                    Text(layer.name).font(BTheme.Font.ui(13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(active ? Color.white : BTheme.text)
                .padding(.horizontal, 8)
                .frame(height: BTheme.Metric.touchField)
                .contentShape(Rectangle())
            }
            .contextMenu {
                Button("Rename") { newName = layer.name; renaming = layer.name }
            }
            .accessibilityLabel(layer.name)
            toggle(layer.onionSkinning ? "circle.dotted.circle" : "circle.dotted", "Onion Skinning", on: layer.onionSkinning) {
                setLayer(layer, "use_onion_skinning", layer.onionSkinning ? "False" : "True")
            }
            toggle(layer.hidden ? "eye.slash" : "eye", "Hide", on: !layer.hidden) {
                setLayer(layer, "hide", layer.hidden ? "False" : "True")
            }
            toggle(layer.locked ? "lock" : "lock.open", "Locked", on: !layer.locked) {
                setLayer(layer, "lock", layer.locked ? "False" : "True")
            }
        }
        .background(active ? BTheme.select : Color.clear, in: RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private func setLayer(_ layer: GPLayer, _ key: String, _ value: String) {
        run(GreasePencilBpy.layerSet(object.name, layer: layer.name, key, value),
            undo: GreasePencilBpy.layerUndo(key))
    }

    // MARK: Onion Skinning

    private func onionPanel(_ info: GreasePencilInfo) -> some View {
        let onion = info.onion
        let frames = onion.mode == "ABSOLUTE"
        return BPanel("Onion Skinning") {
            picker("Mode", GreasePencilBpy.onionModes, selected: onion.mode) { value in
                run(GreasePencilBpy.onionSet(object.name, "onion_mode", "'\(value)'"), undo: "Mode")
            }
            BNumberField("Opacity", value: Binding(get: { onionDraft ?? onion.factor },
                                                   set: { onionDraft = min(max($0, 0), 1) }),
                         step: 0.01,
                         commit: { value in
                             onionDraft = nil
                             run(GreasePencilBpy.onionSet(object.name, "onion_factor", String(format: "%.4g", value)),
                                 undo: "Opacity")
                         })
            picker("Filter by Type", GreasePencilBpy.onionFilters, selected: onion.filter) { value in
                run(GreasePencilBpy.onionSet(object.name, "onion_keyframe_type", "'\(value)'"), undo: "Filter by Type")
            }
            if onion.mode != "SELECTED" {
                stepper(frames ? "Frames Before" : "Keyframes Before", onion.before, key: "ghost_before_range")
                stepper(frames ? "Frames After" : "Keyframes After", onion.after, key: "ghost_after_range")
            }
            checkbox("Custom Colors", on: onion.customColours, key: "use_ghost_custom_colors")
            if onion.customColours {
                colourRow("Before", onion.beforeColour)
                colourRow("After", onion.afterColour)
            }
            checkbox("Fade", on: onion.fade, key: "use_onion_fade")
            checkbox("Show Start Frame", on: onion.loop, key: "use_onion_loop")
        }
    }

    private func stepper(_ label: String, _ value: Int, key: String) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            iconButton("minus", label, enabled: value > 0) {
                run(GreasePencilBpy.onionSet(object.name, key, "\(value - 1)"), undo: label)
            }
            Text("\(value)").font(BTheme.Font.ui(13)).frame(minWidth: 28)
            iconButton("plus", label, enabled: value < 120) {
                run(GreasePencilBpy.onionSet(object.name, key, "\(value + 1)"), undo: label)
            }
        }
    }

    private func checkbox(_ label: String, on: Bool, key: String) -> some View {
        Button {
            run(GreasePencilBpy.onionSet(object.name, key, on ? "False" : "True"), undo: label)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? BTheme.select : BTheme.textDim)
                Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                Spacer()
            }
            .frame(height: BTheme.Metric.touchField)
            .contentShape(Rectangle())
        }
    }

    /// A custom onion colour (scene-linear in Blender), shown as a swatch.
    private func colourRow(_ label: String, _ colour: SIMD3<Float>) -> some View {
        let shown = GreasePencilGeometry.display(colour)
        return HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: Double(shown.x), green: Double(shown.y), blue: Double(shown.z)))
                .frame(width: 60, height: 22)
        }
        .frame(height: BTheme.Metric.touchField)
    }

    // MARK: pieces

    private func picker(_ label: String, _ choices: [(String, String)], selected: String,
                        set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Menu {
                ForEach(choices, id: \.0) { value, title in
                    Button { if value != selected { set(value) } } label: {
                        if value == selected { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: {
                Text(choices.first { $0.0 == selected }?.1 ?? selected)
                    .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                    .padding(.horizontal, 8)
                    .frame(height: BTheme.Metric.touchField)
                    .background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }
        }
    }

    private func toggle(_ icon: String, _ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(on ? BTheme.text : BTheme.textDim)
                .frame(width: 40, height: BTheme.Metric.touchField)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
    }

    private func iconButton(_ icon: String, _ name: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: BTheme.Metric.touchField)
                .background(BTheme.widget, in: RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                .contentShape(Rectangle())
        }
        .disabled(!enabled || session.isRunning)
        .accessibilityLabel(name)
    }

    private func run(_ python: String, undo: String) {
        guard let bridge, !session.isRunning else { return }
        bridge.run(python, undo: undo)
    }
}

/// Blender's Material tab for a Grease Pencil object: its material slots,
/// each a swatch of its stroke colour and its name, the active one lit;
/// "+" makes a new material from a picked colour; the active one's Base
/// Color (the Stroke panel's colour).
struct GreasePencilMaterialPanels: View {
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject

    @State private var adding = false
    @State private var editing = false
    @State private var colour = Color(red: 0.1, green: 0.1, blue: 0.1)

    var body: some View {
        if let info = object.greasePencilInfo {
            BPanel("Grease Pencil Material Slots") {
                ForEach(Array(info.materials.enumerated()), id: \.offset) { index, material in
                    Button {
                        if index != info.activeMaterial {
                            run(GreasePencilBpy.materialActive(object.name, index: index),
                                undo: GreasePencilBpy.materialActiveUndo)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            swatch(material?.stroke)
                            Text(material?.name ?? "Empty").font(BTheme.Font.ui(13)).lineLimit(1)
                            Spacer()
                        }
                        .foregroundStyle(index == info.activeMaterial ? Color.white : BTheme.text)
                        .padding(.horizontal, 8)
                        .frame(height: BTheme.Metric.touchField)
                        .background(index == info.activeMaterial ? BTheme.select : Color.clear,
                                    in: RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                        .contentShape(Rectangle())
                    }
                }
                BButton("New Material", icon: "plus") { adding = true }
                    .popover(isPresented: $adding) {
                        colourChooser("New Material") {
                            run(GreasePencilBpy.materialAdd(object.name, colour: $0), undo: GreasePencilBpy.materialAddUndo)
                        }
                    }
            }
            if info.materials.indices.contains(info.activeMaterial), let material = info.materials[info.activeMaterial] {
                BPanel("Stroke") {
                    HStack {
                        Text("Base Color").font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                        Spacer()
                        Button { editing = true } label: { swatch(material.stroke).frame(width: 60) }
                            .accessibilityLabel("Base Color")
                            .popover(isPresented: $editing) {
                                colourChooser("Base Color") { picked in
                                    run(GreasePencilBpy.materialColour(object.name, index: info.activeMaterial,
                                                                      colour: SIMD4(picked, material.stroke.w)),
                                        undo: GreasePencilBpy.materialColourUndo)
                                }
                            }
                    }
                    .frame(height: BTheme.Metric.touchField)
                }
            }
        }
    }

    private func swatch(_ linear: SIMD4<Float>?) -> some View {
        let c = GreasePencilGeometry.display(SIMD3(linear?.x ?? 0, linear?.y ?? 0, linear?.z ?? 0))
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
            .frame(width: 28, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(BTheme.outline, lineWidth: 1))
    }

    private func colourChooser(_ title: String, apply: @escaping (SIMD3<Float>) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(BTheme.Font.ui(14, weight: .semibold))
            ColorPicker("Base Color", selection: $colour, supportsOpacity: false).font(BTheme.Font.ui(13))
            BButton(title, icon: "checkmark") {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(colour).getRed(&r, green: &g, blue: &b, alpha: &a)
                adding = false
                editing = false
                apply(SIMD3(Float(r), Float(g), Float(b)))
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func run(_ python: String, undo: String) {
        guard let bridge, !session.isRunning else { return }
        bridge.run(python, undo: undo)
    }
}
