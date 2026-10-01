import SwiftUI

/// Blender's F3 operator search.
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
                    Text("All Tools").tag("All")
                    ForEach(Array(Set(catalogue.entries.map(\.category))).sorted(), id: \.self) { name in
                        Text(name.capitalized).tag(name)
                    }
                }
                Spacer()
                Text("\(catalogue.entries.count) tools").font(.caption).foregroundStyle(.secondary)
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
    }
    struct Child: Decodable, Identifiable {
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
    /// crash or hang Blender in the app's context (`_UNSAFE_OPERATORS`).
    let refused: String?

    static func read(_ call: String, bridge: BpyBridge?) -> Self? {
        guard let result = bridge?.capture("import _blenderkit_sync as _bkui; import json; print(json.dumps(\(call)))"),
              let line = result.split(separator: "\n").last,
              let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Values are edited locally. Blender sees one committed change, not every
/// keystroke or intermediate slider frame.
struct BlenderPropertyField: View {
    let property: BlenderRNAInfo.Property
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if property.kind == "BOOLEAN" && !property.array {
                Toggle(property.name, isOn: Binding(get: { value == "true" },
                                                   set: { value = $0 ? "true" : "false" }))
            } else if property.kind == "POINTER" {
                Picker(property.name, selection: $value) {
                    Text("None").tag("null")
                    ForEach(property.options) { option in
                        Text(option.name).tag(Self.jsonString(option.id))
                    }
                }
            } else if property.kind == "ENUM" && !property.enumFlag && !property.options.isEmpty {
                Picker(property.name, selection: $value) {
                    ForEach(property.options) { option in
                        Text(option.name).tag(Self.jsonString(option.id))
                    }
                }
            } else {
                HStack {
                    Text(property.name)
                    Spacer()
                    Text(property.kind.lowercased()).foregroundStyle(.secondary)
                }
                if property.kind == "STRING" {
                    TextField(property.name, text: Binding(get: {
                        (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value
                    }, set: { value = Self.jsonString($0) }))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } else {
                    TextField(property.array ? "[x, y, z]" : "Value", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
            }
            if !property.description.isEmpty {
                Text(property.description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!property.editable)
        .padding(.vertical, 4)
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

    /// What Run sends: `run_operator`, which puts the operator in the mode it
    /// needs, refuses what is measured to crash, and puts the mode back.
    static func command(path: String, json: String) -> String {
        "import _blenderkit_sync as _bkui; import json; _bkui.run_operator(\(Bpy.quote(path)), json.loads(\(Bpy.quote(json))))"
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

/// A compact, navigable view of the actual scene's RNA: modifiers, materials,
/// nodes, render settings, physics, animation and other datablocks share it.
struct BlenderDataBrowser: View {
    var bridge: BpyBridge?
    var startPath = "bpy.context.scene"
    var revision = 0
    @State private var path = "bpy.context.scene"
    @State private var stack: [String] = []
    @State private var info: BlenderRNAInfo?
    @State private var search = ""
    @State private var values: [String: String] = [:]
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { if let previous = stack.popLast() { path = previous; refresh() } } label: {
                    Image(systemName: "chevron.left")
                }.disabled(stack.isEmpty)
                Menu("Inspect") {
                    Button("Scene") { navigate("bpy.context.scene") }
                    Button("Active Object") { navigate("bpy.context.object") }
                    Button("All Data") { navigate("bpy.data") }
                    Button("Render Settings") { navigate("bpy.context.scene.render") }
                    Button("World") { navigate("bpy.context.scene.world") }
                }
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
            }.padding(10)
            TextField("Filter properties and data", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let info {
                        ForEach(info.children.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { child in
                            Button { navigate(child.path) } label: {
                                HStack { Text(child.name); Spacer(); Image(systemName: "chevron.right") }
                                    .frame(minHeight: 36)
                            }
                        }
                        ForEach(info.properties.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { prop in
                            VStack(alignment: .leading) {
                                BlenderPropertyField(property: prop, value: Binding(
                                    get: { values[prop.id] ?? prop.value }, set: { values[prop.id] = $0 }))
                                if let changed = values[prop.id], changed != prop.value {
                                    Button("Apply \(prop.name)") { apply(prop, value: changed) }
                                }
                            }
                        }
                    } else {
                        Text("Select an object or inspect scene data. Detailed properties require Blender bpy.")
                    }
                    if !message.isEmpty { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(10)
            }
        }
        .font(.system(size: 13))
        .background(BTheme.header)
        .foregroundStyle(BTheme.text)
        .onAppear { path = startPath; refresh() }
        .onChange(of: revision) { _, _ in refresh() }
    }

    private func navigate(_ target: String) {
        stack.append(path); path = target; search = ""; refresh()
    }
    private func refresh() {
        info = BlenderRNAInfo.read("_bkui.inspect_data(\(Bpy.quote(path)))", bridge: bridge)
        values = [:]
    }
    private func apply(_ prop: BlenderRNAInfo.Property, value: String) {
        guard (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) != nil else {
            message = "Enter a valid JSON value, for example 0.5 or [1, 2, 3]."; return
        }
        let result = bridge?.run("import _blenderkit_sync as _bkui; import json; _bkui.set_property(\(Bpy.quote(path)), \(Bpy.quote(prop.id)), json.loads(\(Bpy.quote(value))))", undo: "Set \(prop.name)")
        message = result?.succeeded == true ? "Updated \(prop.name)" : (result?.error ?? "Backend unavailable")
        refresh()
    }
}
