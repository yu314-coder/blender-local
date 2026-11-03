import SwiftUI

/// Blender's Edit ▸ Operator Search: every operator, by its name.
///
/// This is what lets the rest of the interface stay small. A menu tree can only
/// offer what somebody wrote a menu item for; this offers whatever the module
/// has, because the list comes from `dir(bpy.ops.*)` rather than from Swift.
/// On device that means every Blender operator is two taps away, including the
/// hundreds no menu here will ever mention.
struct OperatorSearch: View {
    var catalogue: OperatorCatalogue
    var bridge: BpyBridge?
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var category = "All"
    @State private var selected: OperatorCatalogue.Entry?
    @FocusState private var focused: Bool

    private var results: [OperatorCatalogue.Entry] {
        Array(catalogue.search(text, limit: catalogue.entries.count)
            .filter { category == "All" || $0.category == category }.prefix(100))
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            HStack {
                Picker("Category", selection: $category) {
                    // Each category is a `bpy.ops` module; the list is of
                    // operators, as Blender's Operator Search calls them.
                    Text("All Operators").tag("All")
                    ForEach(Array(Set(catalogue.entries.map(\.category))).sorted(), id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
                Spacer()
                Text("\(catalogue.entries.count) operators").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12)
            Divider().overlay(BTheme.outline)
            list
        }
        .frame(width: 420, height: 460)
        .background(BTheme.header)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BTheme.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .sheet(item: $selected) { entry in
            BlenderOperatorForm(entry: entry, bridge: bridge)
        }
        .onAppear {
            if let bridge { catalogue.load(using: bridge) }
            focused = true
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(BTheme.textDim)
            TextField("Search operators", text: $text)
                .textFieldStyle(.plain)
                .font(BTheme.Font.ui(13))
                .foregroundStyle(BTheme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .onSubmit { if let first = results.first { run(first) } }
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(BTheme.textDim)
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight)
            // Esc closes it, as it closes Blender's F3 search.
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder
    private var list: some View {
        if !catalogue.loaded {
            centred("Asking the backend what it can do…")
        } else if results.isEmpty {
            centred(text.isEmpty ? "No operators" : "Nothing matches “\(text)”")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { entry in
                        Button { run(entry) } label: {
                            HStack(spacing: 8) {
                                Text(entry.label)
                                    .font(BTheme.Font.ui(12))
                                    .foregroundStyle(BTheme.text)
                                Spacer()
                                Text(entry.path)
                                    .font(BTheme.Font.mono(10))
                                    .foregroundStyle(BTheme.textDim)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                .hoverEffect(.highlight)
                    }
                }
            }
        }
    }

    private func centred(_ s: String) -> some View {
        VStack {
            Spacer()
            Text(s).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Runs the operator with no arguments, as Blender's search does — the
    /// operator's own defaults apply, and its redo panel is where you would
    /// change them.
    private func run(_ entry: OperatorCatalogue.Entry) {
        selected = entry
    }
}

struct BlenderRNAInfo: Decodable {
    struct Option: Decodable, Identifiable { let id: String; let name: String }
    struct Property: Decodable, Identifiable {
        let id: String
        let name: String
        let description: String
        let kind: String
        let value: String
        let options: [Option]
        let editable: Bool
        let array: Bool
        let enumFlag: Bool
        /// How Blender draws it (`_blenderkit_sync.property_info`): its subtype
        /// (Translation, Euler, Color, Percentage…), its unit, an array's
        /// length, a number's range and precision, a pointer's datablock type
        /// and the name of the one it holds.
        let subtype: String?
        let unit: String?
        let arrayLength: Int?
        let softMin: Double?
        let softMax: Double?
        let hardMin: Double?
        let hardMax: Double?
        let precision: Int?
        let typeName: String?
        let valueName: String?
        /// "ID" for what every datablock has (Fake User, Library…), drawn
        /// after the datablock's own settings.
        let group: String?
    }
    /// A row that opens another page: a pointer, a collection, or a
    /// collection's item — with what it leads to.
    struct Child: Decodable, Identifiable {
        let name: String
        let path: String
        var id: String { path }
        let identifier: String?
        /// POINTER, COLLECTION or ITEM.
        let kind: String?
        let description: String?
        let typeName: String?
        let count: Int?
        /// The datablock or struct a pointer leads to, by its name.
        let detail: String?
        let group: String?
    }
    /// One step of the path back to where the browser was opened.
    struct Crumb: Decodable, Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }
    let title: String
    let description: String
    let available: Bool
    let properties: [Property]
    let children: [Child]
    /// For an operator: the mode `run_operator` switches Blender to before it
    /// runs it (object.* in Object Mode, mesh.* and uv.* in Edit Mode), when
    /// that is not the mode Blender is in — then `available` is not Blender's
    /// answer yet, because its poll is only asked there, when Run is pressed.
    let mode: String?
    let currentMode: String?
    /// Why the search will not run this operator at all: one measured to
    /// crash or hang Blender in the app's context (`_blenderkit_context.
    /// UNSAFE_OPERATORS`, the table script lines are refused by too), or
    /// one that works at the mouse pointer in a 3D View, whose poll fails in
    /// the search's context — the sentence names the Mesh menu row that does
    /// the same toward the 3D cursor where there is one (`_POINTER_OPERATORS`).
    let refused: String?
    /// A Data API page's: Blender's name for what it shows (Object, Bevel
    /// Modifier, Render Data), its description, the path's steps, and why
    /// there is nothing to show (no active object).
    let typeName: String?
    let typeDescription: String?
    let crumbs: [Crumb]?
    let missing: String?

    static func read(_ call: String, bridge: BpyBridge?) -> Self? {
        guard let result = bridge?.capture("import _blenderkit_sync as _bkui; import json; print(json.dumps(\(call)))"),
              let line = result.split(separator: "\n").last,
              let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// A property's value as the readers send it: JSON text.
enum RNAJSON {
    static func decode(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
    static func encode(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
    static func number(_ text: String) -> Double? { (decode(text) as? NSNumber)?.doubleValue }
    static func numbers(_ text: String) -> [Double] { (decode(text) as? [NSNumber])?.map(\.doubleValue) ?? [] }
    static func bools(_ text: String) -> [Bool] { (decode(text) as? [Bool]) ?? [] }
    static func string(_ text: String) -> String? { decode(text) as? String }
    static func strings(_ text: String) -> [String] { (decode(text) as? [String]) ?? [] }
}

/// A property as Blender's Data API draws it: its name (the identifier small
/// under it), then its value as the widget Blender gives that kind — a
/// checkbox, a menu of the enum's items, a number in its unit, X/Y/Z fields
/// for a vector, a swatch for a color, a text field — greyed when Blender
/// will not let it be set. `json` is the value as the readers send it, and
/// `commit` gets the new one, once, when a field is finished with.
struct DataAPIRow: View {
    let property: BlenderRNAInfo.Property
    let json: String
    var commit: (String) -> Void
    /// Opens what a pointer holds (its › button).
    var open: (() -> Void)? = nil
    /// The data path a long press copies.
    var dataPath: String? = nil

    private var p: BlenderRNAInfo.Property { property }
    private var count: Int { p.arrayLength ?? RNAJSON.numbers(json).count }
    /// Drawn under the name rather than beside it: vectors, colors' channels,
    /// sliders.
    private var stacked: Bool {
        (p.array && (p.kind == "FLOAT" || p.kind == "INT") && count > 1) || hasSlider
    }
    private var hasSlider: Bool {
        guard p.editable, !p.array, p.kind == "FLOAT" || p.kind == "INT",
              let lo = p.softMin, let hi = p.softMax, hi > lo else { return false }
        return p.subtype == "FACTOR" || p.subtype == "PERCENTAGE"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name)
                        .font(BTheme.Font.ui(13))
                        .foregroundStyle(p.editable ? BTheme.text : BTheme.textDim)
                    Text(p.id)
                        .font(BTheme.Font.mono(10))
                        .foregroundStyle(BTheme.textDim)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if !stacked { inline }
                if let open {
                    Button(action: open) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(p.name)")
                }
            }
            if stacked { below }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .contextMenu {
            if let dataPath {
                Button("Copy Data Path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = dataPath + "." + p.id
                }
            }
            if !p.description.isEmpty { Text(p.description) }
        }
    }

    // MARK: beside the name

    @ViewBuilder private var inline: some View {
        switch p.kind {
        case "BOOLEAN" where !p.array:
            Toggle("", isOn: Binding(get: { RNAJSON.decode(json) as? Bool ?? false },
                                     set: { commit($0 ? "true" : "false") }))
                .labelsHidden()
                .disabled(!p.editable)
        case "BOOLEAN":
            boolArray
        case "ENUM" where p.enumFlag:
            flagMenu
        case "ENUM":
            enumMenu
        case "POINTER":
            pointerMenu
        case "STRING":
            if p.editable {
                DataAPITextField(text: RNAJSON.string(json) ?? "") { commit(RNAJSON.encode($0)) }
            } else {
                Text(RNAJSON.string(json) ?? "").font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                    .lineLimit(2)
            }
        case "INT", "FLOAT":
            if let v = RNAJSON.number(json) {
                if p.editable {
                    DataAPINumberField(value: v, property: p) { commit(RNAJSON.encode($0)) }
                } else {
                    Text(DataAPIFormat.format(v, kind: p.kind, unit: p.unit, subtype: p.subtype, precision: p.precision))
                        .font(BTheme.Font.mono(13)).foregroundStyle(BTheme.textDim)
                }
            } else if p.array {
                Text("\(count) values").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
            }
        default:
            Text(json).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.textDim).lineLimit(1)
        }
    }

    // MARK: under the name

    @ViewBuilder private var below: some View {
        if hasSlider, let v = RNAJSON.number(json), let lo = p.softMin, let hi = p.softMax {
            DataAPISlider(value: v, range: lo...hi, property: p) { commit(RNAJSON.encode($0)) }
        } else {
            let values = RNAJSON.numbers(json)
            let labels = DataAPIFormat.componentLabels(subtype: p.subtype, count: values.count)
            VStack(alignment: .leading, spacing: 6) {
                if DataAPIFormat.isColor(subtype: p.subtype, count: values.count), p.editable {
                    DataAPIColorSwatch(values: values) { commit(RNAJSON.encode($0)) }
                }
                if values.count <= 4 {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        component(i, v, label: labels[i], values: values)
                    }
                } else if values.count <= 16 {
                    // A matrix: its rows, four (or three) fields to a row.
                    let side = values.count == 9 ? 3 : 4
                    ForEach(0..<(values.count / side), id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(0..<side, id: \.self) { col in
                                let i = row * side + col
                                component(i, values[i], label: nil, values: values)
                            }
                        }
                    }
                } else {
                    Text("\(values.count) values").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                }
            }
        }
    }

    @ViewBuilder private func component(_ i: Int, _ v: Double, label: String?, values: [Double]) -> some View {
        if p.editable {
            DataAPINumberField(value: v, property: p, label: label) { new in
                var next = values
                next[i] = new
                commit(RNAJSON.encode(next))
            }
        } else {
            HStack {
                if let label { Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim).frame(width: 14) }
                Text(DataAPIFormat.format(v, kind: p.kind, unit: p.unit, subtype: p.subtype, precision: p.precision))
                    .font(BTheme.Font.mono(12)).foregroundStyle(BTheme.textDim)
            }
        }
    }

    private var boolArray: some View {
        let values = RNAJSON.bools(json)
        let labels = DataAPIFormat.componentLabels(subtype: p.subtype, count: values.count)
        return HStack(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, on in
                Button {
                    var next = values
                    next[i].toggle()
                    commit(RNAJSON.encode(next))
                } label: {
                    Text(values.count <= 4 ? labels[i] : String(i + 1))
                        .font(BTheme.Font.ui(12, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? BTheme.select : BTheme.field))
                        .foregroundStyle(on ? Color.white : BTheme.text)
                }
                .buttonStyle(.plain)
                .disabled(!p.editable)
                .accessibilityLabel("\(p.name) \(labels[i])")
                .accessibilityValue(on ? "On" : "Off")
            }
        }
    }

    private var enumMenu: some View {
        let current = RNAJSON.string(json)
        let name = p.options.first { $0.id == current }?.name ?? current ?? ""
        return Menu {
            ForEach(p.options) { option in
                Button { commit(RNAJSON.encode(option.id)) } label: {
                    if option.id == current { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: { DataAPIValueBox(text: name, menu: true) }
        .disabled(!p.editable)
    }

    private var flagMenu: some View {
        let chosen = Set(RNAJSON.strings(json))
        let names = p.options.filter { chosen.contains($0.id) }.map(\.name)
        return Menu {
            ForEach(p.options) { option in
                Button {
                    var next = chosen
                    if next.contains(option.id) { next.remove(option.id) } else { next.insert(option.id) }
                    commit(RNAJSON.encode(p.options.map(\.id).filter(next.contains)))
                } label: {
                    if chosen.contains(option.id) { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: { DataAPIValueBox(text: names.isEmpty ? "None" : names.joined(separator: ", "), menu: true) }
        .disabled(!p.editable)
    }

    private var pointerMenu: some View {
        let current = RNAJSON.string(json)
        let name = p.valueName ?? p.options.first { $0.id == current }?.name ?? "None"
        return Menu {
            Button("None") { commit("null") }
            ForEach(p.options) { option in
                Button { commit(RNAJSON.encode(option.id)) } label: {
                    if option.id == current { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: { DataAPIValueBox(text: name, menu: true) }
        .disabled(!p.editable)
    }
}

/// A value's box: Blender's field, 34 points tall.
struct DataAPIValueBox: View {
    let text: String
    var menu = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(BTheme.Font.ui(13)).lineLimit(1)
            if menu {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BTheme.textDim)
            }
        }
        .foregroundStyle(BTheme.text)
        .padding(.horizontal, 10)
        .frame(minWidth: 96, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(BTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(BTheme.outline, lineWidth: 1))
    }
}

/// A number in its unit (a Location in metres, a rotation in degrees), typed:
/// shown as Blender shows it, edited as a plain number, sent once when the
/// field is finished with — Return or a tap elsewhere — and only if it changed.
struct DataAPINumberField: View {
    let value: Double
    let property: BlenderRNAInfo.Property
    var label: String? = nil
    var commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: String {
        DataAPIFormat.format(value, kind: property.kind, unit: property.unit, subtype: property.subtype,
                             precision: property.precision)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let label {
                Text(label).font(BTheme.Font.ui(11, weight: .medium)).foregroundStyle(BTheme.textDim)
                    .frame(width: 14)
            }
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(BTheme.Font.mono(13))
                .foregroundStyle(BTheme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .onSubmit(finish)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(BTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? BTheme.active : BTheme.outline, lineWidth: 1))
        .onAppear { text = shown }
        .onChange(of: value) { _, _ in if !focused { text = shown } }
        .onChange(of: focused) { _, now in
            if now {
                text = DataAPIFormat.editable(value, kind: property.kind, unit: property.unit, precision: property.precision)
            } else {
                finish()
            }
        }
    }

    private func finish() {
        if let typed = DataAPIFormat.parse(text, kind: property.kind, unit: property.unit, subtype: property.subtype) {
            var v = typed
            if let lo = property.hardMin { v = max(v, lo) }
            if let hi = property.hardMax { v = min(v, hi) }
            if v != value { commit(v) }
        }
        text = shown
    }
}

/// A Factor's or a Percentage's slider over its soft range, sent when the
/// finger lifts — one change, one undo step — with the value typed beside it.
struct DataAPISlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let property: BlenderRNAInfo.Property
    var commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range,
                   onEditingChanged: { editing in
                       if !editing, let d = draft {
                           let v = property.kind == "INT" ? d.rounded() : d
                           draft = nil
                           if v != value { commit(v) }
                       }
                   })
                .tint(BTheme.active)
            DataAPINumberField(value: draft ?? value, property: property, commit: commit)
                .frame(width: 110)
        }
        .frame(minHeight: 34)
    }
}

/// A color's swatch, Blender's color field: the picker sends its last color
/// once it has been still for a moment, not every step of a drag.
struct DataAPIColorSwatch: View {
    let values: [Double]
    var commit: ([Double]) -> Void
    @State private var pending: Task<Void, Never>?

    var body: some View {
        ColorPicker("", selection: Binding(get: { color }, set: { send($0) }), supportsOpacity: values.count == 4)
            .labelsHidden()
            .frame(width: 60, height: 34)
            .accessibilityLabel("Color")
    }

    private var color: Color {
        Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: values.count == 4 ? values[3] : 1)
    }

    private func send(_ new: Color) {
        let c = UIColor(new)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        var next = [Double(r), Double(g), Double(b)]
        if values.count == 4 { next.append(Double(a)) }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commit(next)
        }
    }
}

/// A text value, sent once when the field is finished with.
struct DataAPITextField: View {
    let text: String
    var commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .font(BTheme.Font.ui(13))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($focused)
            .onSubmit(finish)
            .padding(.horizontal, 10)
            .frame(minWidth: 140, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 5).fill(BTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? BTheme.active : BTheme.outline, lineWidth: 1))
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, now in if !now { finish() } }
    }

    private func finish() {
        if draft != text { commit(draft) }
    }
}

/// An operator's parameter in the Operator Search's form: the same widgets
/// as the Data API's rows, holding the value until Run.
struct BlenderPropertyField: View {
    let property: BlenderRNAInfo.Property
    @Binding var value: String

    var body: some View {
        DataAPIRow(property: property, json: value, commit: { value = $0 })
            .listRowInsets(EdgeInsets())
    }

    static func jsonString(_ string: String) -> String {
        String(data: (try? JSONEncoder().encode(string)) ?? Data(), encoding: .utf8) ?? "\"\""
    }
}

struct BlenderOperatorForm: View {
    let entry: OperatorCatalogue.Entry
    var bridge: BpyBridge?
    @Environment(\.dismiss) private var dismiss
    @State private var info: BlenderRNAInfo?
    @State private var values: [String: String] = [:]
    @State private var message = ""
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("bpy.ops.\(entry.path)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let info {
                        Text(info.description)
                        if let refused = info.refused {
                            Label(refused, systemImage: "exclamationmark.triangle")
                        } else if let mode = info.mode {
                            Label("Runs in \(mode), then goes back to \(info.currentMode ?? "the mode Blender is in"). Blender checks there whether it can run.", systemImage: "info.circle")
                        } else if !info.available {
                            Label("Needs a different selection, mode, or Blender editor context. Change the scene, then refresh.", systemImage: "info.circle")
                        }
                    } else {
                        Text("RNA controls require the real Blender backend. See the console if it could not be loaded.")
                    }
                }
                if let info {
                    Section("Parameters") {
                        ForEach(info.properties.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { prop in
                            BlenderPropertyField(property: prop, value: Binding(
                                get: { values[prop.id] ?? prop.value },
                                set: { values[prop.id] = $0 }))
                        }
                    }
                    Section {
                        Button("Run \(info.title)") { execute() }
                            .disabled(!info.available)
                        Button("Reset Parameters") { values = [:] }
                    }
                }
                if !message.isEmpty { Section { Text(message).textSelection(.enabled) } }
            }
            .searchable(text: $search, prompt: "Find a parameter")
            .navigationTitle(info?.title ?? entry.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { refresh() } }
            }
            .onAppear { refresh() }
        }
        .preferredColorScheme(.dark)
    }

    private func refresh() {
        info = BlenderRNAInfo.read(Self.infoCall(path: entry.path), bridge: bridge)
    }

    /// What Run sends (`OperatorCatalogue.runCommand`).
    static func command(path: String, json: String) -> String {
        OperatorCatalogue.runCommand(path: path, json: json)
    }

    /// What the form reads to draw itself.
    static func infoCall(path: String) -> String {
        "_bkui.operator_info(\(Bpy.quote(path)))"
    }

    private func execute() {
        do {
            var arguments: [String: Any] = [:]
            for (key, text) in values {
                arguments[key] = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            }
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            let json = String(decoding: data, as: UTF8.self)
            guard let outcome = bridge?.run(Self.command(path: entry.path, json: json), undo: entry.label)
            else { return }
            message = outcome.succeeded ? "Completed \(entry.label)" : (outcome.error ?? "Operation failed")
            refresh()
        } catch {
            message = "Invalid parameter: use a number, true/false, or an array such as [1, 2, 3]. \(error.localizedDescription)"
        }
    }
}

/// Blender's Data API (the Outliner's display mode of that name): everything
/// Blender keeps for a datablock or a struct, under Blender's own names, each
/// value as the widget Blender draws it with, and a row for each link to
/// another one. Opened on the active object, a modifier, a constraint;
/// the path's steps across the top lead back up.
///
/// Its settings come first, then what it links to — the mesh an object
/// holds, its Modifiers, Material Slots — then the values Blender will not let
/// be set, folded away. Every change is one write through
/// `_blenderkit_sync.set_property`, priced by the vertex budget first, and
/// one undo step named after the property.
struct BlenderDataBrowser: View {
    var bridge: BpyBridge?
    var startPath = "bpy.context.scene"
    var revision = 0
    @State private var path = "bpy.context.scene"
    @State private var history: [String] = []
    @State private var info: BlenderRNAInfo?
    @State private var search = ""
    @State private var message = ""
    @State private var showsReadOnly = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(BTheme.outline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    heading
                    filterField
                    if let info { page(info) } else {
                        note("Blender's data could not be read here: the Data API needs Blender's bpy, which this "
                             + "backend does not have.")
                    }
                }
                .padding(.bottom, 16)
            }
            if !message.isEmpty {
                Text(message)
                    .font(BTheme.Font.ui(12))
                    .foregroundStyle(BTheme.active)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(BTheme.header)
                    .textSelection(.enabled)
            }
        }
        .background(BTheme.properties)
        .foregroundStyle(BTheme.text)
        .onAppear { path = startPath; refresh() }
        .onChange(of: revision) { _, _ in refresh() }
    }

    // MARK: the bar: back, the path's steps, Go To, refresh

    private var bar: some View {
        HStack(spacing: 2) {
            Button { goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(history.isEmpty)
            .accessibilityLabel("Back")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let crumbs = info?.crumbs ?? []
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                        if i > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(BTheme.textDim)
                        }
                        Button { if crumb.path != path { navigate(crumb.path) } } label: {
                            Text(crumb.name)
                                .font(BTheme.Font.ui(12, weight: i == crumbs.count - 1 ? .semibold : .regular))
                                .foregroundStyle(i == crumbs.count - 1 ? BTheme.text : BTheme.textDim)
                                .padding(.horizontal, 6)
                                .frame(minHeight: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Menu {
                Button("Active Object") { navigate("bpy.context.object") }
                Button("Scene") { navigate("bpy.context.scene") }
                Button("Render Data") { navigate("bpy.context.scene.render") }
                Button("World") { navigate("bpy.context.scene.world") }
                Button("Blend-File Data") { navigate("bpy.data") }
            } label: {
                Image(systemName: "list.bullet.indent").font(.system(size: 15))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Go To")
            Button { refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 4)
        .background(BTheme.header)
    }

    // MARK: what the page is

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info?.title ?? "Data API").font(BTheme.Font.ui(16, weight: .semibold))
                if let type = info?.typeName, !type.isEmpty, type != info?.title {
                    Text(type).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                }
            }
            if let about = info?.typeDescription, !about.isEmpty {
                Text(about).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Everything Blender keeps for this, under Blender's own names. A row with › opens what it links to.")
                .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(BTheme.textDim)
            TextField("Filter", text: $search)
                .font(BTheme.Font.ui(13))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BTheme.textDim)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(BTheme.field))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: the page

    @ViewBuilder private func page(_ info: BlenderRNAInfo) -> some View {
        if let missing = info.missing {
            note(missing)
        } else {
            let matches: (String, String) -> Bool = { name, id in
                search.isEmpty || name.localizedCaseInsensitiveContains(search) || id.localizedCaseInsensitiveContains(search)
            }
            let settings = info.properties.filter { $0.editable && $0.group != "ID" && matches($0.name, $0.id) }
            let shared = info.properties.filter { $0.editable && $0.group == "ID" && matches($0.name, $0.id) }
            let readOnly = info.properties.filter { !$0.editable && matches($0.name, $0.id) }
            // An editable pointer is a setting with its own ›; its link row
            // would say the same twice.
            let pointerIDs = Set(info.properties.filter { $0.kind == "POINTER" && $0.editable }.map(\.id))
            let allLinks = info.children.filter {
                $0.kind != "ITEM" && !pointerIDs.contains($0.identifier ?? "") && matches($0.name, $0.identifier ?? "")
            }
            let links = allLinks.filter { $0.group != "ID" }
            let sharedLinks = allLinks.filter { $0.group == "ID" }
            let items = info.children.filter { $0.kind == "ITEM" && matches($0.name, $0.typeName ?? "") }
            if !items.isEmpty || (info.typeName == "Collection" && info.children.isEmpty) {
                section("Items", count: items.count)
                if info.children.isEmpty { note("Empty.") }
                ForEach(items) { link($0) }
            }
            if !settings.isEmpty {
                section("Settings", count: settings.count)
                ForEach(settings) { prop in
                    DataAPIRow(property: prop, json: prop.value, commit: { apply(prop, json: $0) },
                               open: opener(prop, in: info), dataPath: path)
                    divider
                }
            }
            if !links.isEmpty {
                section("Linked Data", count: links.count)
                ForEach(links) { link($0) }
            }
            // What every datablock has — Fake User, Library, Original ID —
            // after what is this one's own.
            if !shared.isEmpty || !sharedLinks.isEmpty {
                section("Data-Block", count: shared.count + sharedLinks.count)
                ForEach(shared) { prop in
                    DataAPIRow(property: prop, json: prop.value, commit: { apply(prop, json: $0) },
                               open: opener(prop, in: info), dataPath: path)
                    divider
                }
                ForEach(sharedLinks) { link($0) }
            }
            if !readOnly.isEmpty {
                Button { showsReadOnly.toggle() } label: {
                    HStack {
                        Image(systemName: showsReadOnly ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Read-Only").font(BTheme.Font.ui(12, weight: .semibold))
                        Text("\(readOnly.count)").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(BTheme.textDim)
                if showsReadOnly || !search.isEmpty {
                    ForEach(readOnly) { prop in
                        DataAPIRow(property: prop, json: prop.value, commit: { _ in }, dataPath: path)
                        divider
                    }
                }
            }
            if settings.isEmpty && shared.isEmpty && allLinks.isEmpty && readOnly.isEmpty && items.isEmpty
                && !search.isEmpty {
                note("Nothing here matches “\(search)”.")
            }
        }
    }

    /// A pointer setting's ›: the page of what it holds, when it holds one.
    private func opener(_ prop: BlenderRNAInfo.Property, in info: BlenderRNAInfo) -> (() -> Void)? {
        guard prop.kind == "POINTER", prop.value != "null",
              let child = info.children.first(where: { $0.identifier == prop.id }) else { return nil }
        return { navigate(child.path) }
    }

    private func link(_ child: BlenderRNAInfo.Child) -> some View {
        Button { navigate(child.path) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(child.name).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                    Text(detail(child)).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BTheme.textDim)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { divider }
    }

    /// What a link leads to: the datablock it holds and its type ("Cube ·
    /// Mesh"), a collection's count ("2 items · Modifier"), an item's type.
    private func detail(_ child: BlenderRNAInfo.Child) -> String {
        let type = child.typeName ?? ""
        switch child.kind {
        case "COLLECTION":
            return [child.count.map(DataAPIFormat.countText), type.isEmpty ? nil : type]
                .compactMap { $0 }.joined(separator: " · ")
        case "POINTER":
            let held = child.detail ?? ""
            return [held.isEmpty ? nil : held, type.isEmpty ? nil : type].compactMap { $0 }.joined(separator: " · ")
        default:
            return type
        }
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(BTheme.Font.ui(12, weight: .semibold))
            Text("\(count)").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
        }
        .foregroundStyle(BTheme.textDim)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var divider: some View {
        Rectangle().fill(BTheme.outline.opacity(0.6)).frame(height: 1).padding(.leading, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: moving and writing

    private func navigate(_ target: String) {
        history.append(path); path = target; search = ""; showsReadOnly = false; refresh()
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        path = previous; search = ""; refresh()
    }

    /// What a row's edit sends: `_blenderkit_sync.set_property`, which prices
    /// the change with the vertex budget first, whatever the struct and the
    /// property (round 4's fix round), then sets it. The DEBUG hook
    /// `-data-api` sends the same string.
    static func setCommand(path: String, property: String, json: String) -> String {
        "import _blenderkit_sync as _bkui; import json; _bkui.set_property(\(Bpy.quote(path)), \(Bpy.quote(property)), json.loads(\(Bpy.quote(json))))"
    }

    private func refresh() {
        info = BlenderRNAInfo.read("_bkui.inspect_data(\(Bpy.quote(path)))", bridge: bridge)
    }

    private func apply(_ prop: BlenderRNAInfo.Property, json: String) {
        guard RNAJSON.decode(json) != nil || json == "null" else { return }
        let result = bridge?.run(Self.setCommand(path: path, property: prop.id, json: json),
                                 // Named as Blender names an edit made in a
                                 // field: after the property ("Location").
                                 undo: prop.name)
        // Said only when Blender refused it (the budget, a read-only value);
        // a change that went through shows as the new value.
        message = result?.succeeded == true ? "" : (result?.error ?? "Blender is not available")
        refresh()
    }
}

#if DEBUG
/// What the DEBUG hooks print after a priced step (`-data-api`,
/// `-modifier-steps`, `-points-ops data:`, `-textimage-ops text:`): the active
/// object's count as the vertex budget makes it (`stack_vertices`, the count
/// every price judges) beside the mesh Blender has evaluated, so a run shows
/// the budget following Blender (round 4's fix round).
public enum BudgetProbe {
    /// The count for the active object, or for `object` when it is named.
    public static func python(object: String? = nil) -> String {
        let pick = object.map { "bpy.data.objects.get(\(Bpy.quote($0)))" } ?? "bpy.context.view_layer.objects.active"
        return """
        import _blenderkit_multires as _bk_m
        _bk_o = \(pick)
        if _bk_o is None or _bk_o.type not in ('MESH', 'CURVE', 'SURFACE', 'FONT'):
            print('no geometry object is active')
        else:
            _bk_e = _bk_o.evaluated_get(bpy.context.evaluated_depsgraph_get())
            _bk_mesh = _bk_e.to_mesh()
            _bk_n = len(_bk_mesh.vertices) if _bk_mesh is not None else 0
            _bk_e.to_mesh_clear()
            print('%s: the budget counts %d, Blender evaluates %d' % (_bk_o.name, _bk_m.stack_vertices(_bk_o), _bk_n))
        """
    }

    public static func report(_ bridge: BpyBridge?, object: String? = nil) -> String {
        bridge?.capture(python(object: object))?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "no count (Blender busy)"
    }
}
#endif
