import SwiftUI

/// Blender's Object Constraints tab (Properties ▸ Constraints): Add Object
/// Constraint, then each constraint of the active object as Blender's panel
/// draws it — the header's name, Enabled switch, menu (Apply, Duplicate, Copy
/// to Selected, Move to First, Move to Last), order and Delete; the rows of
/// the eleven types modelled here; Influence.
///
/// Everything shown is the constraint as Blender holds it, read back by the
/// mirror after every command (`BKObject.constraints`); every control sends
/// Blender's own operator or property write through the bridge
/// (`ConstraintsBpy`) and shows what comes back — nothing is written here
/// first. A type without rows here keeps the controls every constraint has
/// and opens on its Data API path, where every setting is Blender's RNA.
struct ConstraintsPanel: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            addMenu
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ForEach(Array(object.constraints.enumerated()), id: \.element.id) { index, con in
                ConstraintCard(scene: scene, session: session, bridge: bridge, object: object,
                               constraint: con, index: index, count: object.constraints.count)
            }
            if object.constraints.isEmpty {
                Text("No constraints")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    .padding(.horizontal, 12)
            }
        }
    }

    /// `layout.operator_menu_enum("object.constraint_add", "type",
    /// text="Add Object Constraint")`, in Blender's four columns.
    private var addMenu: some View {
        Menu {
            ForEach(ConstraintMenu.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.types, id: \.id) { type in
                        Button(type.label) {
                            bridge?.run(ConstraintsBpy.add(type.id, to: object.name))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 11))
                Text("Add Object Constraint").font(BTheme.Font.ui(12))
                Spacer()
            }
            .foregroundStyle(BTheme.text)
            .padding(.horizontal, 9)
            .frame(height: BTheme.Metric.rowHeight)
            .frame(maxWidth: .infinity)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .disabled(session.isRunning || bridge == nil)
    }
}

/// One constraint's panel.
private struct ConstraintCard: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject
    var constraint: ObjectConstraint
    var index: Int
    var count: Int

    @State private var open = true
    @State private var draftName: String?
    @FocusState private var nameFocused: Bool

    private var con: ObjectConstraint { constraint }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if open {
                Group {
                    if con.isModelled, let kind = ConstraintKind(rawValue: con.kind) {
                        rows(kind)
                    } else {
                        unmodelled
                    }
                    number("Influence", key: "influence", value: con.influence, step: 0.01,
                           clamp: { min(max($0, 0), 1) })
                }
                .opacity(con.enabled ? 1 : 0.55)
            }
        }
        .padding(8)
        .background(BTheme.widget.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(con.valid ? Color.clear : Color.red.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(con.name), \(con.typeLabel)")
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 4) {
            Button { open.toggle() } label: {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).foregroundStyle(BTheme.textDim).frame(width: 12)
            }
            .buttonStyle(.plain)
            TextField(con.typeLabel, text: Binding(get: { draftName ?? con.name },
                                                   set: { draftName = $0 }))
                .textFieldStyle(.plain)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(con.valid ? BTheme.text : Color.red)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, now in if !now { commitName() } }
                .onChange(of: con.name) { _, _ in draftName = nil }
                .accessibilityLabel("Name")
            // Blender's header switch: `enabled`, "Use the results of this
            // constraint", named Enabled.
            Toggle("", isOn: Binding(get: { con.enabled }, set: { on in
                send(ConstraintsBpy.set("enabled", of: con.name, on: object.name,
                                        to: ConstraintsBpy.literal(on), undo: "Enabled"))
            }))
            .labelsHidden()
            .scaleEffect(0.65)
            .frame(width: 40)
            .accessibilityLabel("Enabled")
            Menu {
                Button(ConstraintsBpy.Operation.apply.label) { operate(.apply) }
                Button(ConstraintsBpy.Operation.copy.label) { operate(.copy) }
                Button(ConstraintsBpy.Operation.copyToSelected.label) { operate(.copyToSelected) }
                Divider()
                Button("Move to First") { send(ConstraintsBpy.move(con.name, of: object.name, to: 0)) }
                    .disabled(index == 0)
                Button("Move to Last") {
                    send(ConstraintsBpy.move(con.name, of: object.name, to: count - 1))
                }
                .disabled(index == count - 1)
            } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 11)).foregroundStyle(BTheme.textDim).frame(width: 20, height: 20)
            }
            .accessibilityLabel("Constraint menu")
            iconButton("arrow.up", "Move Constraint Up", enabled: index > 0) {
                send(ConstraintsBpy.move(con.name, of: object.name, by: -1))
            }
            iconButton("arrow.down", "Move Constraint Down", enabled: index < count - 1) {
                send(ConstraintsBpy.move(con.name, of: object.name, by: 1))
            }
            iconButton("xmark", "Delete Constraint", enabled: true) {
                send(ConstraintsBpy.remove(con.name, of: object.name))
            }
        }
        .frame(height: 22)
    }

    private func commitName() {
        defer { draftName = nil }
        guard let draft = NameDraft(text: draftName?.trimmingCharacters(in: .whitespaces)).ending(over: con.name),
              !draft.isEmpty else { return }
        send(ConstraintsBpy.set("name", of: con.name, on: object.name, to: Bpy.quote(draft), undo: "Name"))
    }

    // MARK: the types' rows

    @ViewBuilder
    private func rows(_ kind: ConstraintKind) -> some View {
        if kind.hasTarget { targetRow }
        switch kind {
        case .copyLocation:
            switches("Axis", [("X", "use_x"), ("Y", "use_y"), ("Z", "use_z")])
            switches("Invert", [("X", "invert_x"), ("Y", "invert_y"), ("Z", "invert_z")])
            flag("Offset", "use_offset")
            spaces(target: true)
        case .copyRotation:
            choice("Order", "euler_order")
            switches("Axis", [("X", "use_x"), ("Y", "use_y"), ("Z", "use_z")])
            switches("Invert", [("X", "invert_x"), ("Y", "invert_y"), ("Z", "invert_z")])
            choice("Mix", "mix_mode")
            spaces(target: true)
        case .copyScale:
            switches("Axis", [("X", "use_x"), ("Y", "use_y"), ("Z", "use_z")])
            number("Power", key: "power", value: con.float("power") ?? 1, step: 0.01)
            flag("Make Uniform", "use_make_uniform")
            flag("Offset", "use_offset")
            flag("Additive", "use_add")
            spaces(target: true)
        case .copyTransforms:
            flag("Remove Target Shear", "remove_target_shear")
            choice("Mix", "mix_mode")
            spaces(target: true)
        case .trackTo:
            choice("Track Axis", "track_axis")
            choice("Up", "up_axis")
            flag("Target Z", "use_target_z")
            spaces(target: true)
        case .dampedTrack:
            choice("Track Axis", "track_axis")
        case .limitLocation, .limitScale:
            let unit: NumberFieldUnit = kind == .limitLocation ? .meters : .none
            ForEach(["x", "y", "z"], id: \.self) { a in
                limit(a == "x" ? "Minimum X" : a.uppercased(), use: "use_min_\(a)", key: "min_\(a)", unit: unit)
            }
            ForEach(["x", "y", "z"], id: \.self) { a in
                limit(a == "x" ? "Maximum X" : a.uppercased(), use: "use_max_\(a)", key: "max_\(a)", unit: unit)
            }
            flag("Affect Transform", "use_transform_limit")
            spaces(target: false)
        case .limitRotation:
            ForEach(["x", "y", "z"], id: \.self) { a in
                limit(a == "x" ? "Limit X" : a.uppercased(), use: "use_limit_\(a)", key: "min_\(a)",
                      unit: .degrees, label: "Min")
                number("Max", key: "max_\(a)", value: con.float("max_\(a)") ?? 0, step: 0.004,
                       unit: .degrees, undo: Self.propertyName("max_\(a)"))
                    .opacity(con.bool("use_limit_\(a)") == true ? 1 : 0.5)
            }
            choice("Order", "euler_order")
            flag("Affect Transform", "use_transform_limit")
            flag("Legacy Behavior", "use_legacy_behavior")
            spaces(target: false)
        case .childOf:
            switches("Location", [("X", "use_location_x"), ("Y", "use_location_y"), ("Z", "use_location_z")])
            switches("Rotation", [("X", "use_rotation_x"), ("Y", "use_rotation_y"), ("Z", "use_rotation_z")])
            switches("Scale", [("X", "use_scale_x"), ("Y", "use_scale_y"), ("Z", "use_scale_z")])
            HStack(spacing: 4) {
                wide(ConstraintsBpy.Operation.setInverse)
                wide(ConstraintsBpy.Operation.clearInverse)
            }
        case .followPath:
            if con.bool("use_fixed_location") == true {
                number("Offset Factor", key: "offset_factor", value: con.float("offset_factor") ?? 0,
                       step: 0.01, clamp: { min(max($0, 0), 1) })
            } else {
                number("Offset", key: "offset", value: con.float("offset") ?? 0, step: 1)
            }
            choice("Forward Axis", "forward_axis")
            choice("Up Axis", "up_axis")
            flag("Fixed Position", "use_fixed_location")
            flag("Curve Radius", "use_curve_radius")
            flag("Follow Curve", "use_curve_follow")
            wide(ConstraintsBpy.Operation.animatePath)
        }
    }

    /// A type without rows here: its settings are Blender's RNA, one tap
    /// away in the Data API browser, opened on this constraint.
    @ViewBuilder
    private var unmodelled: some View {
        if session.usesRealBlender, let bridge {
            NavigationLink {
                BlenderDataBrowser(bridge: bridge, startPath: ConstraintsBpy.dataPath(con.name),
                                   revision: session.backendRevision)
            } label: {
                fieldLabel("Settings", "Data API ›")
            }
            .buttonStyle(.plain)
        }
        Text(con.unread ? "Blender's settings for this \(con.typeLabel) could not be read"
                        : "\(con.typeLabel) has no rows of its own in this panel")
            .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: rows

    /// The Target field: every other object, or a curve for Follow Path.
    private var targetRow: some View {
        let followPath = con.kind == ConstraintKind.followPath.rawValue
        let candidates = scene.objects.filter { $0.id != object.id && (!followPath || $0.blenderType == "CURVE") }
        return Menu {
            Button("None") { send(ConstraintsBpy.setTarget(nil, of: con.name, on: object.name)) }
            ForEach(candidates, id: \.id) { other in
                Button(other.name) { send(ConstraintsBpy.setTarget(other.name, of: con.name, on: object.name)) }
            }
        } label: {
            fieldLabel("Target", con.target ?? (followPath ? "Pick a curve" : "None"), dim: con.target == nil)
        }
        .disabled(session.isRunning)
    }

    /// Owner and Target spaces, Blender's `space_template` (World and Local;
    /// Custom Space needs an object of its own, set through the Data API).
    @ViewBuilder
    private func spaces(target: Bool) -> some View {
        if target { choice("Target", "target_space") }
        choice("Owner", "owner_space")
    }

    /// A row of toggle buttons under a heading: Axis X Y Z, Invert X Y Z.
    /// Each button's text is its undo step, as Blender names a field's edit.
    private func switches(_ heading: String, _ items: [(String, String)]) -> some View {
        HStack(spacing: 3) {
            Text(heading).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            ForEach(items, id: \.1) { item in
                let on = con.bool(item.1) == true
                Button {
                    send(ConstraintsBpy.set(item.1, of: con.name, on: object.name,
                                            to: ConstraintsBpy.literal(!on), undo: item.0))
                } label: {
                    Text(item.0)
                        .font(BTheme.Font.ui(11))
                        .foregroundStyle(on ? Color.white : BTheme.textDim)
                        .frame(width: 24, height: 20)
                        .background(on ? BTheme.select : BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("\(heading) \(item.0)")
                .accessibilityValue(on ? "On" : "Off")
            }
        }
        .frame(height: 22)
        .disabled(session.isRunning)
    }

    private func flag(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Toggle("", isOn: Binding(get: { con.bool(key) == true }, set: { on in
                send(ConstraintsBpy.set(key, of: con.name, on: object.name,
                                        to: ConstraintsBpy.literal(on), undo: label))
            }))
            .labelsHidden()
            .scaleEffect(0.7)
        }
        .frame(height: 22)
        .disabled(session.isRunning)
    }

    /// An enum, offered as Blender's running build offers it (the record
    /// carries the items).
    private func choice(_ label: String, _ key: String) -> some View {
        Menu {
            ForEach(con.options(key), id: \.id) { option in
                Button(option.label) {
                    send(ConstraintsBpy.set(key, of: con.name, on: object.name,
                                            to: "'\(option.id)'", undo: label))
                }
            }
        } label: {
            fieldLabel(label, con.label(of: key))
        }
        .disabled(session.isRunning)
    }

    /// A limit's switch and its value, greyed while the switch is off, as
    /// Blender's row does.
    private func limit(_ heading: String, use: String, key: String, unit: NumberFieldUnit,
                       label: String = "") -> some View {
        HStack(spacing: 4) {
            Text(heading).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                .frame(width: 70, alignment: .leading)
            Toggle("", isOn: Binding(get: { con.bool(use) == true }, set: { on in
                send(ConstraintsBpy.set(use, of: con.name, on: object.name,
                                        to: ConstraintsBpy.literal(on), undo: heading))
            }))
            .labelsHidden()
            .scaleEffect(0.65)
            .frame(width: 40)
            .accessibilityLabel(heading)
            number(label, key: key, value: con.float(key) ?? 0, step: unit == .degrees ? 0.004 : 0.01,
                   unit: unit, undo: Self.propertyName(key))
                .opacity(con.bool(use) == true ? 1 : 0.5)
        }
        .disabled(session.isRunning)
    }

    /// A number field. Its undo step is its text, as Blender names a field's
    /// edit, or the property's name where Blender draws the field without one.
    private func number(_ label: String, key: String, value: Float, step: Float,
                        unit: NumberFieldUnit = .none, undo: String? = nil,
                        clamp: @escaping (Float) -> Float = { $0 }) -> some View {
        ConstraintNumberField(label: label, value: value, step: step, unit: unit, clamp: clamp) { v in
            send(ConstraintsBpy.set(key, of: con.name, on: object.name,
                                    to: ConstraintsBpy.literal(v), undo: undo ?? label))
        }
        .disabled(session.isRunning)
    }

    /// The RNA names of the limits' values (5.2.1): `min_x` is Minimum X.
    static func propertyName(_ key: String) -> String {
        let parts = key.split(separator: "_")
        guard parts.count == 2 else { return key }
        return (parts[0] == "min" ? "Minimum " : "Maximum ") + parts[1].uppercased()
    }

    private func wide(_ operation: ConstraintsBpy.Operation) -> some View {
        Button { operate(operation) } label: {
            Text(operation.label)
                .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
                .frame(maxWidth: .infinity).frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(session.isRunning)
    }

    private func iconButton(_ icon: String, _ label: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10))
                .foregroundStyle(BTheme.textDim.opacity(enabled ? 1 : 0.35))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled || session.isRunning)
        .help(label)
        .accessibilityLabel(label)
    }

    private func fieldLabel(_ label: String, _ value: String, dim: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11)).foregroundStyle(dim ? BTheme.textDim : BTheme.text)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private func operate(_ operation: ConstraintsBpy.Operation) {
        send(ConstraintsBpy.operate(operation, on: con.name, of: object.name))
    }

    private func send(_ command: BlenderCommand) {
        bridge?.run(command)
    }
}

/// A constraint's number: the value Blender holds, and while a finger is on
/// it, a draft; the finger lifting sends one write, and the field then shows
/// what Blender took.
private struct ConstraintNumberField: View {
    let label: String
    let value: Float
    let step: Float
    let unit: NumberFieldUnit
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
