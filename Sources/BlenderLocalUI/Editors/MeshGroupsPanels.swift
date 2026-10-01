import SwiftUI

/// The Data tab's Vertex Groups and Shape Keys panels for a mesh, as Blender's
/// Object Data tab has them.
///
/// Everything shown is `BKObject.meshGroups` — what the mirror read from
/// Blender — and every control sends one `GroupsBpy` command through the
/// bridge and shows what comes back. Nothing is written here first: a value
/// field holds a draft only while a finger is on it, and the commit sends the
/// draft clamped as Blender will clamp it.
struct MeshGroupsPanels: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject

    private var mode: InteractionMode { scene.mode }
    /// Edit Mode on this object: where Assign, Remove, Select and Deselect
    /// work, and where the mesh being edited is the active shape key.
    private var editing: Bool { mode == .edit && scene.active?.id == object.id }
    /// Object and Edit Mode. Blender allows some of these in Sculpt and the
    /// paint modes too; none of those paths has been run headless with the
    /// app's context, so `_blenderkit_groups` refuses them and the panels say
    /// so before a tap does.
    private var usable: Bool { mode == .object || mode == .edit }

    var body: some View {
        if !session.usesRealBlender {
            BPanel("Vertex Groups") {
                note("Vertex groups and shape keys are Blender's: the simulator's stand-in has neither")
            }
        } else if let groups = object.meshGroups {
            vertexGroups(groups)
            shapeKeys(groups)
        }
    }

    // MARK: Vertex Groups

    @ViewBuilder
    private func vertexGroups(_ groups: MeshGroups) -> some View {
        BPanel("Vertex Groups") {
            ForEach(Array(groups.groups.enumerated()), id: \.element.name) { index, group in
                groupRow(group, active: index == groups.activeGroup)
            }
            if groups.groups.isEmpty {
                note("No vertex groups")
            }
            HStack(spacing: 4) {
                listButton("plus", "Add Vertex Group") { send(GroupsBpy.addGroup(object: object.name)) }
                listButton("minus", "Remove Vertex Group") {
                    if let name = groups.activeGroupName { send(GroupsBpy.removeGroup(name, object: object.name)) }
                }
                .disabled(groups.activeGroupName == nil)
                Menu {
                    Button("Delete All Groups", role: .destructive) {
                        send(GroupsBpy.removeAllGroups(object: object.name))
                    }
                    .disabled(groups.groups.isEmpty)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10))
                        .foregroundStyle(BTheme.text)
                        .frame(width: 26, height: 22).background(BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                }
                .accessibilityLabel("Vertex Group Specials")
                Spacer()
            }
            .disabled(!usable)
            if let active = groups.activeGroupName {
                NameField(label: "Name", name: active) { wanted in
                    send(GroupsBpy.renameGroup(active, to: wanted, object: object.name))
                }
                .disabled(!usable)
            }
            if editing {
                if let active = groups.activeGroupName {
                    HStack(spacing: 4) {
                        wideButton("Assign") {
                            send(GroupsBpy.assign(active, weight: groups.weight, object: object.name))
                        }
                        wideButton("Remove") { send(GroupsBpy.removeFromGroup(active, object: object.name)) }
                    }
                    HStack(spacing: 4) {
                        wideButton("Select") { send(GroupsBpy.selectGroup(active, select: true, object: object.name)) }
                        wideButton("Deselect") {
                            send(GroupsBpy.selectGroup(active, select: false, object: object.name))
                        }
                    }
                }
                // Blender's own range for `vertex_group_weight`, 0 to 1. No
                // undo step: measured, Blender's undo does not take it back.
                DraftNumberField(label: "Weight", value: groups.weight, step: 0.01,
                                 clamp: { min(max($0, 0), 1) }) { v in
                    _ = bridge?.run(GroupsBpy.setWeight(v))
                }
            } else if !groups.groups.isEmpty, usable {
                note("Assign, Remove, Select and Deselect work in Edit Mode")
            }
            if !groups.counted {
                note("Members are counted on meshes of up to 20,000 vertices")
            }
            if !usable {
                note("Vertex groups are edited here in Object or Edit Mode")
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: MeshGroups.Group, active: Bool) -> some View {
        HStack(spacing: 5) {
            Button {
                send(GroupsBpy.setActiveGroup(group.name, object: object.name))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.crop.square.stack")
                        .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
                    Text(group.name).font(BTheme.Font.ui(11))
                        .foregroundStyle(active ? BTheme.title : BTheme.text)
                        .lineLimit(1)
                    Spacer()
                    if let count = group.count {
                        Text("\(count)").font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
                            .accessibilityLabel("\(count) vertices")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!usable || active)
            Button {
                send(GroupsBpy.lockGroup(group.name, !group.locked, object: object.name))
            } label: {
                Image(systemName: group.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(group.locked ? BTheme.text : BTheme.textDim)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .accessibilityLabel("Lock \(group.name)")
            .accessibilityValue(group.locked ? "On" : "Off")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(active ? BTheme.select.opacity(0.35) : BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    // MARK: Shape Keys

    @ViewBuilder
    private func shapeKeys(_ groups: MeshGroups) -> some View {
        BPanel("Shape Keys") {
            ForEach(Array(groups.keys.enumerated()), id: \.element.name) { index, key in
                keyRow(key, groups: groups, active: index == groups.activeKey)
            }
            if groups.keys.isEmpty {
                note("No shape keys")
            }
            HStack(spacing: 4) {
                listButton("plus", "Add Shape Key") {
                    send(GroupsBpy.addKey(fromMix: false, object: object.name))
                }
                listButton("minus", "Remove Shape Key") {
                    if let key = groups.activeKeyBlock { send(GroupsBpy.removeKey(key.name, object: object.name)) }
                }
                .disabled(groups.activeKeyBlock == nil)
                Menu {
                    Button("New Shape from Mix") { send(GroupsBpy.addKey(fromMix: true, object: object.name)) }
                        .disabled(groups.keys.isEmpty)
                    Button("Delete All Shape Keys", role: .destructive) {
                        send(GroupsBpy.removeAllKeys(apply: false, object: object.name))
                    }
                    .disabled(groups.keys.isEmpty)
                    Button("Apply All Shape Keys") {
                        send(GroupsBpy.removeAllKeys(apply: true, object: object.name))
                    }
                    .disabled(groups.keys.isEmpty)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10))
                        .foregroundStyle(BTheme.text)
                        .frame(width: 26, height: 22).background(BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                }
                .accessibilityLabel("Shape Key Specials")
                Spacer()
            }
            // Measured: `shape_key_add` and `shape_key_remove` fail their poll
            // in Edit Mode, where Blender greys its own + and - out.
            .disabled(mode != .object)
            if editing && !groups.keys.isEmpty {
                note("Blender adds and removes shape keys in Object Mode. Edit Mode edits the active key's shape"
                     + (groups.activeKeyBlock.map { ": " + $0.name } ?? ""))
            }
            if !groups.keys.isEmpty {
                flag("Relative", on: groups.useRelative) {
                    send(GroupsBpy.set(.useRelative, $0, editing: editing, object: object.name))
                }
                flag("Shape Key Lock", on: groups.showOnlyShapeKey) {
                    send(GroupsBpy.set(.showOnly, $0, editing: editing, object: object.name))
                }
                flag("Shape Key Edit Mode", on: groups.shapeKeyEditMode) {
                    send(GroupsBpy.set(.editMode, $0, editing: editing, object: object.name))
                }
                if !groups.useRelative {
                    note("Absolute keys follow Evaluation Time, which this panel does not have")
                }
            }
            if let key = groups.activeKeyBlock {
                activeKey(key, groups: groups)
            }
            if !usable {
                note("Shape keys are edited here in Object or Edit Mode")
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ key: MeshGroups.Key, groups: MeshGroups, active: Bool) -> some View {
        HStack(spacing: 5) {
            Button {
                send(GroupsBpy.setActiveKey(key.name, object: object.name))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
                    Text(key.name).font(BTheme.Font.ui(11))
                        .foregroundStyle(active ? BTheme.title : BTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!usable || active)
            // Blender draws no slider for the reference key of a relative
            // set: it is what the others are relative to.
            if !groups.isReference(key) && groups.useRelative {
                DraftNumberField(label: "", value: key.value, step: 0.01, clamp: key.clamped) { v in
                    send(GroupsBpy.setKeyValue(key.name, v, editing: editing, object: object.name))
                }
                .frame(width: 92)
                .disabled(!usable)
            }
            Button {
                send(GroupsBpy.setKey(key.name, .mute, key.mute ? "False" : "True", editing: editing,
                                      object: object.name))
            } label: {
                // Blender's checkbox is "on" while the key is NOT muted.
                Image(systemName: key.mute ? "square" : "checkmark.square.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(key.mute ? BTheme.textDim : BTheme.text)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!usable)
            .accessibilityLabel("Mute \(key.name)")
            .accessibilityValue(key.mute ? "On" : "Off")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(active ? BTheme.select.opacity(0.35) : BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    /// The active key's settings, below the list as Blender has them.
    @ViewBuilder
    private func activeKey(_ key: MeshGroups.Key, groups: MeshGroups) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NameField(label: "Name", name: key.name) { wanted in
                send(GroupsBpy.setKey(key.name, .name, Bpy.quote(wanted), editing: editing, object: object.name))
            }
            if !groups.isReference(key) && groups.useRelative {
                DraftNumberField(label: "Value", value: key.value, step: 0.01, clamp: key.clamped) { v in
                    send(GroupsBpy.setKeyValue(key.name, v, editing: editing, object: object.name))
                }
                // Blender's limits for the range: -10 to 10, the minimum
                // below the maximum.
                DraftNumberField(label: "Range Min", value: key.sliderMin, step: 0.01,
                                 clamp: { min(max($0, -10), key.sliderMax - 0.001) }) { v in
                    send(GroupsBpy.setKey(key.name, .sliderMin, Self.python(v), editing: editing,
                                          object: object.name))
                }
                DraftNumberField(label: "Max", value: key.sliderMax, step: 0.01,
                                 clamp: { min(max($0, key.sliderMin + 0.001), 10) }) { v in
                    send(GroupsBpy.setKey(key.name, .sliderMax, Self.python(v), editing: editing,
                                          object: object.name))
                }
                Menu {
                    Button("None") {
                        send(GroupsBpy.setKey(key.name, .vertexGroup, Bpy.quote(""), editing: editing,
                                              object: object.name))
                    }
                    ForEach(groups.groups, id: \.name) { group in
                        Button(group.name) {
                            send(GroupsBpy.setKey(key.name, .vertexGroup, Bpy.quote(group.name),
                                                  editing: editing, object: object.name))
                        }
                    }
                } label: {
                    fieldLabel("Vertex Group", key.vertexGroup.isEmpty ? "None" : key.vertexGroup,
                               dim: key.vertexGroup.isEmpty)
                }
                Menu {
                    ForEach(groups.keys, id: \.name) { other in
                        Button(other.name) {
                            send(GroupsBpy.setKey(key.name, .relativeKey, Bpy.quote(other.name),
                                                  editing: editing, object: object.name))
                        }
                    }
                } label: {
                    fieldLabel("Relative To", key.relativeKey, dim: false)
                }
            }
            flag("Lock Shape", on: key.locked) { on in
                send(GroupsBpy.setKey(key.name, .locked, on ? "True" : "False", editing: editing,
                                      object: object.name))
            }
        }
        .disabled(!usable)
    }

    // MARK: pieces

    private func send(_ command: GroupsBpy.Command) {
        _ = bridge?.run(command.call, undo: command.undo, executing: command.executed)
    }

    private static func python(_ v: Float) -> String { String(format: "%.6g", Double(v)) }

    @ViewBuilder
    private func note(_ text: String) -> some View {
        Text(text)
            .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func listButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BTheme.text)
                .frame(width: 26, height: 22).background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func wideButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
                .frame(maxWidth: .infinity).frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// One of Blender's checkboxes: it shows `on` — as the mirror last read
    /// it — and a tap sends the change.
    @ViewBuilder
    private func flag(_ label: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: set))
                .labelsHidden()
                .scaleEffect(0.7)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private func fieldLabel(_ label: String, _ value: String, dim: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11))
                .foregroundStyle(dim ? BTheme.textDim : BTheme.text)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }
}

/// A number held in Blender: shown from a draft while a finger is on it,
/// committed once when it lifts, clamped as Blender will clamp it.
private struct DraftNumberField: View {
    let label: String
    let value: Float
    let step: Float
    let clamp: (Float) -> Float
    let commit: (Float) -> Void
    @State private var draft: Float?

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? value }, set: { draft = clamp($0) }),
                     step: step,
                     commit: { v in
                         let sent = clamp(v)
                         if sent != value { commit(sent) }
                         draft = nil
                     })
    }
}

/// A name held in Blender: typed into a draft, sent on Return, and shown as
/// Blender has it after — which is where a clash comes back as "Group.001".
private struct NameField: View {
    let label: String
    let name: String
    let commit: (String) -> Void
    @State private var draft: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            TextField("", text: Binding(get: { draft ?? name }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(BTheme.Font.mono(11))
                .foregroundStyle(BTheme.text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit {
                    if let draft, draft != name { commit(draft) }
                    draft = nil
                }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        .onChange(of: name) { _, _ in draft = nil }
    }
}
