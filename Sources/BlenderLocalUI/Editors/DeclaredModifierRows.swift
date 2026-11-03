import SwiftUI
import simd

/// The rows of the eleven modifiers round 4, group 8 added to Add Modifier —
/// Curve, Wireframe, Skin, Hook, Armature, Surface Deform, Mesh Deform, Data
/// Transfer, Normal Edit, Mask and Build — drawn from their declared settings
/// (`ModifierKind.fields`) in Blender's panel order and words, with the
/// buttons Blender's panels carry.
///
/// Every control writes through the bridge and shows what the mirror brings
/// back: nothing is written here first. A setting the record did not carry is
/// not drawn, so no row shows a value Blender does not hold.
struct DeclaredModifierRows: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject
    var modifier: Modifier

    var body: some View {
        let fields = modifier.kind.fields
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(groups(fields).enumerated()), id: \.offset) { _, group in
                if let heading = group.panel {
                    Text(heading)
                        .font(BTheme.Font.ui(10, weight: .medium)).foregroundStyle(BTheme.textDim)
                        .padding(.top, 2)
                }
                if modifier.kind == .skin && group.panel == "Symmetry" {
                    symmetryRow(group.fields)
                } else {
                    ForEach(group.fields, id: \.key) { field in
                        if shows(field) {
                            control(field)
                                .opacity(dims(field) ? 0.5 : 1)
                                .disabled(locked(field))
                        }
                    }
                }
            }
            notes
            buttons
        }
    }

    // MARK: which fields, and how

    private struct Group { var panel: String?; var fields: [ModifierField] }

    private func groups(_ fields: [ModifierField]) -> [Group] {
        var out: [Group] = []
        for field in fields where !field.isReadOnly {
            if let last = out.last, last.panel == field.panel {
                out[out.count - 1].fields.append(field)
            } else {
                out.append(Group(panel: field.panel, fields: [field]))
            }
        }
        return out
    }

    /// Drawn only when Blender sent it, and where Blender's panel draws it:
    /// Mask's Armature in its Armature mode, its Smooth in Vertex Group mode.
    private func shows(_ field: ModifierField) -> Bool {
        guard modifier.values[field.key] != nil else { return false }
        if modifier.kind == .mask {
            let armature = modifier.setting("mode") == "ARMATURE"
            if field.key == "armature" { return armature }
            if field.key == "use_smooth" { return !armature }
        }
        return true
    }

    /// Blender greys these out (`active_set`): they change nothing then.
    private func dims(_ field: ModifierField) -> Bool {
        switch (modifier.kind, field.key) {
        case (.wireframe, "crease_weight"): return modifier.flag("use_crease") != true
        case (.normalEdit, "use_direction_parallel"): return modifier.setting("mode") != "DIRECTIONAL"
        case (.build, "seed"): return modifier.flag("use_random_order") != true
        case (.dataTransfer, let key) where key.hasPrefix("data_types_") || key.hasSuffix("_mapping"):
            let toggle = ["data_types_verts": "use_vert_data", "vert_mapping": "use_vert_data",
                          "data_types_edges": "use_edge_data", "edge_mapping": "use_edge_data",
                          "data_types_loops": "use_loop_data", "loop_mapping": "use_loop_data",
                          "data_types_polys": "use_poly_data", "poly_mapping": "use_poly_data"][key]
            return toggle.map { modifier.flag($0) != true } ?? false
        case (.surfaceDeform, "use_sparse_bind"): return modifier.vertexGroup.isEmpty
        default: return false
        }
    }

    /// Blender disables these while bound (`enabled_set(!is_bound)`): a
    /// bound modifier keeps what it was bound with.
    private func locked(_ field: ModifierField) -> Bool {
        let bound = modifier.flag("is_bound") == true
        switch (modifier.kind, field.key) {
        case (.surfaceDeform, "target"), (.surfaceDeform, "falloff"), (.surfaceDeform, "use_sparse_bind"):
            return bound
        case (.meshDeform, "object"), (.meshDeform, "precision"):
            return bound
        default:
            return false
        }
    }

    @ViewBuilder
    private func control(_ field: ModifierField) -> some View {
        let text = modifier.values[field.key] ?? ""
        switch field.kind {
        case .number(let step, let unit, let lo, let hi):
            DeclaredNumberField(label: field.label, value: Float(text) ?? 0, step: step,
                                unit: Self.unit(unit),
                                clamp: { v in min(max(v, lo ?? -.greatestFiniteMagnitude),
                                                  hi ?? .greatestFiniteMagnitude) }) { v in
                send(field.key, String(Double(v)))
            }
        case .integer(let range):
            let value = Int((Float(text) ?? 0).rounded())
            stepper(field.label, value: value, range: range) { send(field.key, "\($0)") }
        case .toggle:
            flag(field.label, on: text == "1") { send(field.key, $0 ? "1" : "0") }
        case .choice(let choices):
            Menu {
                ForEach(modifier.choices(for: field), id: \.identifier) { choice in
                    Button(choice.label) { send(field.key, choice.identifier) }
                }
            } label: {
                fieldLabel(field.label, choices.first { $0.identifier == text }?.label ?? text, dim: false)
            }
        case .flags(let choices):
            let picked = ModifierField.flagSet(text)
            // Blender draws an enum set expanded, one toggle per item.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(choices, id: \.identifier) { choice in
                    flag(choice.label, on: picked.contains(choice.identifier)) { on in
                        var next = picked
                        if on { next.insert(choice.identifier) } else { next.remove(choice.identifier) }
                        send(field.key, next.sorted().joined(separator: ","))
                    }
                }
            }
        case .vector3(let step):
            let parts = text.split(separator: ",").compactMap { Float($0) }
            if parts.count == 3 {
                ForEach(0..<3, id: \.self) { i in
                    DeclaredNumberField(label: (i == 0 ? field.label + " " : "") + ["X", "Y", "Z"][i],
                                        value: parts[i], step: step, unit: .none, clamp: { $0 }) { v in
                        var next = parts
                        next[i] = v
                        send(field.key, next.map { String(Double($0)) }.joined(separator: ","))
                    }
                }
            }
        case .object(let types):
            objectPicker(field, types: types, current: text)
        case .readOnly:
            EmptyView()
        }
    }

    private static func unit(_ unit: ModifierField.Unit) -> BNumberField.Unit {
        switch unit {
        case .none, .frames: return .none
        case .meters: return .meters
        case .degrees: return .degrees
        }
    }

    // MARK: notes and buttons

    @ViewBuilder
    private var notes: some View {
        let bound = modifier.flag("is_bound") == true
        if !session.usesRealBlender && modifier.kind.standInLeavesMesh {
            // The simulator's stand-in keeps these rows' settings but draws
            // the mesh as it was (`ModifierKind.standInLeavesMesh`).
            note("The simulator draws the mesh without this modifier: Blender on a device builds it")
        }
        switch modifier.kind {
        case .curve where modifier.targetName.isEmpty:
            note("No curve — this modifier does nothing")
        case .hook:
            if modifier.targetName.isEmpty {
                note("No object — this modifier does nothing")
            } else if modifier.number("vertex_count") == 0 {
                // Measured: an Object alone moved nothing; Assign in Edit Mode
                // gave it the selected vertices.
                note("No vertices assigned: select them in Edit Mode and press Assign")
            } else if let n = modifier.number("vertex_count") {
                note("Moves \(Int(n)) vertices")
            }
        case .armature where modifier.targetName.isEmpty:
            note("No armature — this modifier does nothing")
        case .surfaceDeform, .meshDeform:
            note(bound ? "Bound" : (modifier.targetName.isEmpty ? "Nothing to bind to — pick a mesh"
                                                                  : "Not bound — press Bind"))
        case .dataTransfer where modifier.targetName.isEmpty:
            note("No source — this modifier does nothing")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if session.usesRealBlender {
            let editing = scene.mode == .edit && scene.active?.id == object.id
            let bound = modifier.flag("is_bound") == true
            switch modifier.kind {
            case .surfaceDeform:
                button(.bindSurface, bound: bound)
                    .disabled(!bound && modifier.targetName.isEmpty)
            case .meshDeform:
                button(.bindMesh, bound: bound)
                    .disabled(!bound && modifier.targetName.isEmpty)
            case .dataTransfer:
                button(.generate).disabled(modifier.targetName.isEmpty)
            case .hook where editing:
                HStack(spacing: 4) { button(.hookReset); button(.hookRecenter) }
                HStack(spacing: 4) { button(.hookSelect); button(.hookAssign) }
            case .skin:
                button(.skinArmature)
                if editing {
                    HStack(spacing: 4) { button(.skinLooseMark); button(.skinLooseClear) }
                    button(.skinRoot)
                    button(.skinEqualize)
                }
            default:
                EmptyView()
            }
        }
    }

    private func button(_ op: ModifierOperation, bound: Bool = false) -> some View {
        Button {
            guard let command = ModifierRowAction.operation(op).command(for: modifier, in: object.modifiers)
            else { return }
            bridge?.run(command.lines, undo: command.undo)
        } label: {
            Text(op.label(bound: bound)).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                .frame(maxWidth: .infinity).frame(height: BTheme.Metric.touchField)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: sending

    /// One setting's change, and nothing else (`Bpy.modifierEdit`). The row
    /// shows what the mirror brings back.
    private func send(_ key: String, _ text: String) {
        var changed = modifier
        changed.values[key] = text
        if modifier.kind.fields.first(where: { $0.key == key })?.isObject == true {
            changed.targetName = text
        }
        let lines = Bpy.modifierEdit(from: modifier, to: changed)
        guard !lines.isEmpty else { return }
        bridge?.run(lines, undo: "Edit Modifier")
    }

    // MARK: controls

    /// The other object: only the types Blender's pointer takes (it leaves
    /// the pointer as it was for any other, measured), never the modifier's
    /// own object (Blender raises), and None.
    @ViewBuilder
    private func objectPicker(_ field: ModifierField, types: [String]?, current: String) -> some View {
        let candidates = scene.objects.filter { other in
            other.id != object.id && (types.map { $0.contains(other.blenderType) } ?? true)
        }
        Menu {
            ForEach(candidates, id: \.id) { other in
                Button(other.name) { send(field.key, other.name) }
            }
            if candidates.isEmpty {
                Text(types.map { "No " + $0.map(Self.typeName).joined(separator: " or ") + " in the scene" }
                     ?? "No other object in the scene")
            }
            if !current.isEmpty {
                Button("None") { send(field.key, "") }
            }
        } label: {
            fieldLabel(field.label, current.isEmpty ? "None" : current, dim: current.isEmpty)
        }
    }

    private static func typeName(_ type: String) -> String {
        ["CURVE": "curve", "MESH": "mesh", "ARMATURE": "armature"][type] ?? type.lowercased()
    }

    private func symmetryRow(_ fields: [ModifierField]) -> some View {
        HStack(spacing: 3) {
            Text("Symmetry").font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            ForEach(fields, id: \.key) { field in
                if let text = modifier.values[field.key] {
                    let on = text == "1"
                    Button { send(field.key, on ? "0" : "1") } label: {
                        Text(field.label).font(BTheme.Font.ui(13))
                            .foregroundStyle(on ? Color.white : BTheme.textDim)
                            .frame(width: 24, height: 20)
                            .background(on ? BTheme.select : BTheme.widget)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: BTheme.Metric.touchField)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ label: String, _ value: String, dim: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(13)).lineLimit(1)
                .foregroundStyle(dim ? BTheme.textDim : BTheme.text)
        }
        .padding(.horizontal, 6)
        .frame(height: BTheme.Metric.touchField)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private func flag(_ label: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: set))
                .labelsHidden()
                .scaleEffect(0.7)
        }
        .frame(height: BTheme.Metric.touchField)
    }

    private func stepper(_ label: String, value: Int, range: ClosedRange<Int>,
                         set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Button { if value > range.lowerBound { set(value - 1) } } label: {
                Image(systemName: "minus").font(.system(size: 12))
                    .frame(width: BTheme.Metric.touchButton, height: BTheme.Metric.touchField).background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain).foregroundStyle(BTheme.text)
            Text("\(value)").font(BTheme.Font.mono(13)).foregroundStyle(BTheme.text).frame(minWidth: 26)
            Button { if value < range.upperBound { set(value + 1) } } label: {
                Image(systemName: "plus").font(.system(size: 12))
                    .frame(width: BTheme.Metric.touchButton, height: BTheme.Metric.touchField).background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain).foregroundStyle(BTheme.text)
        }
        .frame(height: BTheme.Metric.touchField)
    }
}

/// A declared row's number: Blender's value, and while a finger is on it a
/// draft; the lift sends one change (`ModifierNumberField`'s rule).
private struct DeclaredNumberField: View {
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
