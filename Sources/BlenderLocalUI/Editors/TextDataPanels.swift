import SwiftUI
import simd

/// A text object's Data tab (round 4, group 8): the Body Text field and
/// Blender's Shape, Geometry, Bevel, Transform, Alignment and Spacing rows,
/// each written through the bridge and shown as the mirror reads them back.
///
/// The body is `data.body`, written in Object Mode (`TextBpy.setBody`):
/// Blender's own Edit Mode on a text keeps an edit buffer that no Python can
/// read back (_blenderkit_text.py has the measurements), so the app types the
/// body here instead, and Tab on a text object opens this field.
struct TextDataPanels: View {
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject
    var settings: TextSettings

    var body: some View {
        BPanel("Body Text") {
            BodyTextField(bridge: bridge, object: object, current: settings.body)
            if let chars = settings.number("chars") {
                Text("\(Int(chars)) characters")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }
        }
        ForEach(["Shape", "Geometry", "Bevel", "Transform", "Alignment", "Spacing"], id: \.self) { panel in
            BPanel(panel) {
                ForEach(TextSettings.rows.filter { $0.panel == panel }, id: \.key) { row in
                    rowControl(row.key, row.label)
                }
            }
        }
    }

    @ViewBuilder
    private func rowControl(_ key: String, _ label: String) -> some View {
        if let choices = TextSettings.choices[key], let current = settings.values[key] {
            Menu {
                ForEach(choices, id: \.id) { choice in
                    Button(choice.label) { send(key, "'\(choice.id)'", undo: label) }
                }
            } label: {
                fieldRow(label, choices.first { $0.id == current }?.label ?? current)
            }
        } else if let value = settings.number(key) {
            let range = TextSettings.ranges[key] ?? -1e6...1e6
            TextNumberField(label: label, value: value,
                            step: TextSettings.integers.contains(key) ? 1 : 0.01,
                            unit: TextSettings.integers.contains(key) ? .count
                                : ["shear", "space_character", "space_word", "space_line"].contains(key)
                                    ? .none : .meters,
                            clamp: { min(max($0, range.lowerBound), range.upperBound) }) { v in
                send(key, TextBpy.python(key, v), undo: label)
            }
        }
    }

    private func send(_ key: String, _ python: String, undo: String) {
        bridge?.run(TextBpy.set(key, to: python, object: object.name), undo: undo)
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.text)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }
}

/// The Body Text field: what Blender holds, and while it is being typed in, a
/// draft. The edit ends as Blender's text fields end — the field losing focus
/// or Done — and only then is the body written, once, as one undo step.
/// Afterwards the field shows what came back.
struct BodyTextField: View {
    var bridge: BpyBridge?
    var object: BKObject
    /// The body Blender holds.
    var current: String
    var autofocus = false
    /// Called after the body was sent (the sheet closes then).
    var ended: (() -> Void)?
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: Binding(get: { draft ?? current }, set: { draft = $0 }))
                .font(BTheme.Font.mono(12))
                .frame(minHeight: 60, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .background(BTheme.field)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                .focused($focused)
                .accessibilityLabel("Body Text")
            if focused || draft != nil {
                Button("Done") { commit() }
                    .font(BTheme.Font.ui(11))
            }
        }
        .onChange(of: focused) { _, now in
            if !now { commit() }
        }
        .onAppear { if autofocus { focused = true } }
    }

    private func commit() {
        focused = false
        defer { ended?() }
        guard let text = NameDraft(text: draft).ending(over: current) else { draft = nil; return }
        bridge?.run(TextBpy.setBody(text, object: object.name), undo: TextBpy.bodyUndo)
        draft = nil
    }
}

/// The sheet Tab opens on a text object: its Body Text, focused.
struct BodyTextSheet: View {
    var scene: BKScene
    var bridge: BpyBridge?
    var object: BKObject
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(object.name).font(BTheme.Font.ui(13, weight: .medium)).foregroundStyle(BTheme.text)
            if case .text(let settings)? = object.dataSettings {
                BodyTextField(bridge: bridge, object: object, current: settings.body, autofocus: true,
                              ended: dismiss)
            } else {
                Text("Blender's text for \(object.name) has not arrived yet.")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
        }
        .padding(14)
        .frame(minWidth: 320)
        .background(BTheme.properties)
    }
}

private struct TextNumberField: View {
    let label: String
    let value: Float
    let step: Float
    let unit: BNumberField.Unit
    let clamp: (Float) -> Float
    let commit: (Float) -> Void
    @State private var draft: Float?

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? value }, set: { draft = clamp($0) }),
                     step: step, unit: unit,
                     commit: { v in
                         commit(clamp(v))
                         draft = nil
                     })
    }
}

/// An empty's Data tab: Blender's Empty panel — Display As and Size, and for
/// an image empty its Offset, Depth, Side, Show In and Opacity — and the
/// Image panel's name (round 4, group 8). Every row is Blender's property,
/// sent through the bridge, shown as the mirror reads it back.
struct EmptyDataPanels: View {
    var bridge: BpyBridge?
    var object: BKObject
    var display: EmptyDisplay

    var body: some View {
        BPanel("Empty") {
            Menu {
                ForEach(EmptyDisplay.Kind.allCases, id: \.self) { kind in
                    Button(kind.label) {
                        run(ReferenceImages.setEmpty("empty_display_type", to: "'\(kind.rawValue)'",
                                                     object: object.name), undo: "Display As")
                    }
                }
            } label: {
                row("Display As", display.kind.label)
            }
            EmptyNumberField(label: "Size", value: display.size, step: 0.01, unit: .meters,
                             clamp: { max($0, 0) }) { v in
                run(ReferenceImages.setEmpty("empty_display_size", to: String(format: "%.6g", Double(v)),
                                             object: object.name), undo: "Size")
            }
            if display.kind == .image {
                EmptyNumberField(label: "Offset X", value: display.imageOffset.x, step: 0.01, unit: .none,
                                 clamp: { $0 }) { v in
                    image("empty_image_offset_x", String(format: "%.6g", Double(v)), undo: "Offset X")
                }
                EmptyNumberField(label: "Y", value: display.imageOffset.y, step: 0.01, unit: .none,
                                 clamp: { $0 }) { v in
                    image("empty_image_offset_y", String(format: "%.6g", Double(v)), undo: "Y")
                }
                segmented("Depth", EmptyDisplay.Depth.allCases.map { ($0.rawValue, $0.label) },
                          selected: display.depth.rawValue, key: "empty_image_depth")
                    // Blender greys Depth out with In Front on, which draws it
                    // over everything whatever Depth says.
                    .disabled(display.inFront)
                    .opacity(display.inFront ? 0.5 : 1)
                segmented("Side", EmptyDisplay.Side.allCases.map { ($0.rawValue, $0.label) },
                          selected: display.side.rawValue, key: "empty_image_side")
                Text("Show In").font(BTheme.Font.ui(10, weight: .medium)).foregroundStyle(BTheme.textDim)
                flag("Orthographic", on: display.showOrthographic, key: "show_empty_image_orthographic")
                flag("Perspective", on: display.showPerspective, key: "show_empty_image_perspective")
                flag("Only Axis Aligned", on: display.onlyAxisAligned, key: "show_empty_image_only_axis_aligned")
                flag("Opacity", on: display.useAlpha, key: "use_empty_image_alpha", undo: "Use Alpha")
                EmptyNumberField(label: "Opacity", value: display.color.w, step: 0.01, unit: .none,
                                 clamp: { min(max($0, 0), 1) }) { v in
                    image("opacity", String(format: "%.6g", Double(v)), undo: "Color")
                }
                .opacity(display.useAlpha ? 1 : 0.5)
            }
        }
        if display.kind == .image {
            BPanel("Image") {
                row("Image", display.imageName.isEmpty ? "None" : display.imageName)
                if !display.imageName.isEmpty && !display.imageHasData {
                    Text("Blender could not read this file as an image: only its frame is drawn")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func run(_ python: String, undo: String) {
        bridge?.run(python, undo: undo)
    }

    private func image(_ key: String, _ python: String, undo: String) {
        run(ReferenceImages.set(key, to: python, object: object.name), undo: undo)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.text).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private func segmented(_ label: String, _ choices: [(String, String)], selected: String,
                           key: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            ForEach(choices, id: \.0) { id, name in
                Button { if id != selected { image(key, "'\(id)'", undo: label) } } label: {
                    Text(name).font(BTheme.Font.ui(11))
                        .foregroundStyle(id == selected ? Color.white : BTheme.textDim)
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(id == selected ? BTheme.select : BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 22)
    }

    /// `undo` is the property's own name where Blender's row draws no text
    /// (Opacity's checkbox is `use_empty_image_alpha`, "Use Alpha").
    private func flag(_ label: String, on: Bool, key: String, undo: String? = nil) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { image(key, $0 ? "True" : "False", undo: undo ?? label) }))
                .labelsHidden()
                .scaleEffect(0.7)
        }
        .frame(height: 22)
    }
}

private struct EmptyNumberField: View {
    let label: String
    let value: Float
    let step: Float
    let unit: BNumberField.Unit
    let clamp: (Float) -> Float
    let commit: (Float) -> Void
    @State private var draft: Float?

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? value }, set: { draft = clamp($0) }),
                     step: step, unit: unit,
                     commit: { v in
                         commit(clamp(v))
                         draft = nil
                     })
    }
}
