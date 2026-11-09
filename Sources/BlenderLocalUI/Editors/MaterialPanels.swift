import SwiftUI
import UIKit
import simd

/// Properties ▸ Material, as Blender 5.x's Material Properties draw it, for a
/// finger: the slot list with its column of buttons and Material Specials
/// (MATERIAL_PT_context_material), the slot's material — browse, name, user
/// count, Fake User, New, Unlink — and its Link, Assign / Select / Deselect
/// in Edit Mode, then the Surface and Volume panels (the Material Output's
/// inputs, `template_node_view`), Settings and Viewport Display.
///
/// Everything shown is what Blender holds, read in one call
/// (`MaterialBpy.state`) when the active object, the mode or Blender's
/// history moves, and after each control's command. Every control sends one
/// `MaterialBpy.Command`. A drag or a colour being picked is previewed in
/// the 3D View at once (`BKScene.previewMaterial`) and written once.
struct MaterialPanels: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject

    @State private var state: MaterialPanelState?
    /// Moves after every command, so the tab reads Blender again even when
    /// the command made no undo step (Edit Mode's values).
    @State private var tick = 0

    private var editing: Bool { state?.editing ?? (scene.mode == .edit) }
    /// Object and Edit Mode: where `_blenderkit_material` works.
    private var usable: Bool { scene.mode == .object || scene.mode == .edit }

    var body: some View {
        Group {
            if !session.usesRealBlender {
                BPanel("Material") {
                    note("Materials are Blender's: the simulator's stand-in has none to show")
                }
            } else if let state, state.object == object.name {
                if state.hasMaterials {
                    slotsSection(state)
                    if let material = state.material {
                        surfacePanel(material, socket: \.surface, title: "Surface", open: true)
                            .id("material-surface")
                        surfacePanel(material, socket: \.volume, title: "Volume", open: false)
                        settingsPanel(material)
                            .id("material-settings")
                        viewportPanel(material)
                            .id("material-viewport")
                    }
                } else {
                    BPanel("Material") { note("\(object.name) takes no material") }
                }
            } else {
                BPanel("Material") { note("Reading the material from Blender…") }
            }
        }
        .background(KeyedRefresh(key: { refreshKey }, refresh: { read() }))
        #if DEBUG
        .task(id: state != nil) { await runDebugOps() }
        #endif
    }

    private struct RefreshKey: Equatable {
        var revision: Int
        var running: Bool
        var object: String
        var mode: InteractionMode
        var tick: Int
    }

    private var refreshKey: RefreshKey {
        RefreshKey(revision: session.backendRevision, running: session.isRunning, object: object.name,
                   mode: scene.mode, tick: tick)
    }

    private func read() {
        guard let bridge, session.usesRealBlender, !session.isRunning else { return }
        guard let text = bridge.capture(MaterialBpy.state(object: object.name)) else { return }
        let parsed = MaterialPanelState.parse(text)
        guard parsed != state else { return }
        state = parsed
        #if DEBUG
        MaterialPanelsDebug.shown(parsed)
        #endif
    }

    private func send(_ command: MaterialBpy.Command) {
        _ = bridge?.run(command.call, undo: command.undo, executing: command.executed)
        tick &+= 1
    }

    #if DEBUG
    /// `-material-ops a,b,…`: the tab's controls pressed through the commands
    /// they send, once the tab has read Blender (after any `-eval64` script),
    /// each followed by what the tab then reads and what the 3D View draws
    /// the object with. Tokens: `add`, `remove`, `new`, `active:N`, `up`,
    /// `down`, `edit`, `object`, `all` (every face selected), `assign`,
    /// `faces:i;j` (only those faces selected), `select`, `deselect`,
    /// `browse:<name>`, `unlink`, `single`, `fake`,
    /// `link:DATA|OBJECT`, `special:<row number>`, `shader:<type>`,
    /// `base:r;g;b` (the surface's Base Color or Color, sRGB),
    /// `metallic:v`, `viewport:r;g;b`.
    private func runDebugOps() async {
        let args = ProcessInfo.processInfo.arguments
        guard state != nil, !MaterialPanelsDebug.ran, let i = args.firstIndex(of: "-material-ops"),
              i + 1 < args.count, let bridge else { return }
        MaterialPanelsDebug.ran = true
        // After a `-eval64` script, which starts a second after launch.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        // The active object as it is now: this view's `object` is the one it
        // was made for, which a script may have removed since.
        func current() -> (BKObject, MaterialPanelState)? {
            guard let target = scene.active,
                  let text = bridge.capture(MaterialBpy.state(object: target.name)),
                  let read = MaterialPanelState.parse(text) else { return nil }
            return (target, read)
        }
        for token in args[i + 1].split(separator: ",").map(String.init) {
            guard let (target, s) = current() else { break }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            let triple = arg.split(separator: ";").compactMap { Float($0) }
            let name = target.name
            let node = s.material?.surface.node
            var command: MaterialBpy.Command?
            switch parts[0] {
            case "add": command = MaterialBpy.addSlot(object: name, editing: s.editing)
            case "remove": command = MaterialBpy.removeSlot(object: name)
            case "new": command = MaterialBpy.newMaterial(object: name, editing: s.editing)
            case "active": command = MaterialBpy.setActiveSlot(Int(arg) ?? 0, object: name, editing: s.editing)
            case "up", "down": command = MaterialBpy.moveSlot(up: parts[0] == "up", object: name, editing: s.editing)
            case "edit", "object":
                _ = bridge.run(Bpy.setMode(parts[0] == "edit" ? .edit : .object), undo: UndoStep.editMode)
            case "all": _ = bridge.run("bpy.ops.mesh.select_all(action='SELECT')", undo: SelectMenu.selectAllUndo)
            case "faces":
                // Only these faces selected in Blender's edit mesh, as taps would.
                let picked = arg.split(separator: ";").compactMap { Int($0) }.map(String.init).joined(separator: ", ")
                let body = "import bmesh\n_bk_o = bpy.context.object\n_bk_bm = bmesh.from_edit_mesh(_bk_o.data)\n"
                    + "_bk_bm.faces.ensure_lookup_table()\n"
                    + "for _bk_f in _bk_bm.faces:\n    _bk_f.select_set(False)\n"
                    + "for _bk_f in _bk_bm.faces:\n    if _bk_f.index in (\(picked),):\n        _bk_f.select_set(True)\n"
                    + "_bk_bm.select_flush_mode()\nbmesh.update_edit_mesh(_bk_o.data)"
                _ = bridge.run("faces \(picked) selected", undo: nil, executing: body)
            case "assign": command = MaterialBpy.assign(object: name)
            case "select", "deselect": command = MaterialBpy.select(parts[0] == "select", object: name)
            case "browse": command = MaterialBpy.browse(arg, object: name, editing: s.editing)
            case "unlink": command = MaterialBpy.unlink(object: name, editing: s.editing)
            case "single": command = s.material.map { MaterialBpy.makeSingleUser($0.name, object: name, editing: s.editing) }
            case "fake": command = s.material.map { MaterialBpy.fakeUser($0.name, !$0.fakeUser, editing: s.editing) }
            case "link": command = MaterialBpy.link(arg, slot: s.active, object: name, editing: s.editing)
            case "special":
                let rows = MaterialBpy.Special.allCases
                if let n = Int(arg), rows.indices.contains(n) {
                    command = MaterialBpy.special(rows[n], object: name, editing: s.editing)
                }
            case "shader":
                command = s.material.map { MaterialBpy.setShader(arg, socket: "Surface", material: $0.name,
                                                                 editing: s.editing) }
            case "base":
                if let m = s.material, let node, triple.count == 3,
                   let input = node.inputs.first(where: { $0.id == "Base Color" || $0.id == "Color" }) {
                    command = MaterialBpy.setInput(input, srgb: SIMD3(triple[0], triple[1], triple[2]),
                                                   node: node.name, material: m.name, editing: s.editing)
                }
            case "metallic":
                if let m = s.material, let node, let input = node.inputs.first(where: { $0.id == "Metallic" }) {
                    command = MaterialBpy.setInput(input, number: Double(arg) ?? 0, node: node.name,
                                                   material: m.name, editing: s.editing)
                }
            case "viewport":
                if let m = s.material, triple.count == 3 {
                    command = MaterialBpy.setViewportColor(srgb: SIMD4(triple[0], triple[1], triple[2], 1),
                                                           material: m.name, editing: s.editing)
                }
            default: break
            }
            if let command {
                let outcome = bridge.run(command.call, undo: command.undo, executing: command.executed)
                print("[bk] material-ops \(token): \(outcome.succeeded ? "done" : "refused: \(outcome.error ?? "?")")"
                      + " — step \(command.undo ?? "none")")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            tick &+= 1
            let after = current()?.1
            let slotsNow = after?.slots.map { $0.material ?? "(empty)" }.joined(separator: ", ") ?? "?"
            print("[bk] material-ops \(token): the tab reads slots [\(slotsNow)], active \(after?.active ?? -1), "
                  + "material \(after?.material?.name ?? "none") (users \(after?.material?.users ?? 0)), "
                  + "Surface \(after?.material?.surface.link ?? "None")")
            let looks = target.materialLooks.map { look -> String in
                let c = look.display, b = look.previewBase
                return "\(look.material ?? "-") solid (\(String(format: "%.2f, %.2f, %.2f", c.x, c.y, c.z)))"
                    + " preview (\(String(format: "%.2f, %.2f, %.2f", b.x, b.y, b.z)))"
            }
            let runs = target.slotRuns()?.map { "\($0.slot):\($0.triangles.count)" }.joined(separator: " ") ?? "one look"
            print("[bk] material-ops \(token): 3D View draws \(target.name) with [\(looks.joined(separator: "; "))], "
                  + "triangles by slot: \(runs)")
            fflush(stdout)
        }
        print("[bk] material-ops finished; steps: \(bridge.debugSession.backendRevision)")
        fflush(stdout)
    }
    #endif

    // MARK: the slot list and the material

    @ViewBuilder
    private func slotsSection(_ state: MaterialPanelState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                slotList(state)
                slotButtons(state)
            }
            datablockRow(state)
            if state.editing {
                HStack(spacing: 4) {
                    wideButton("Assign") { send(MaterialBpy.assign(object: object.name)) }
                    if state.type != "FONT" {
                        wideButton("Select") { send(MaterialBpy.select(true, object: object.name)) }
                        wideButton("Deselect") { send(MaterialBpy.select(false, object: object.name)) }
                    }
                }
                .disabled(state.slots.isEmpty)
            }
            if !usable {
                note("Material slots are changed here in Object or Edit Mode")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(!usable)
    }

    @ViewBuilder
    private func slotList(_ state: MaterialPanelState) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(state.slots.enumerated()), id: \.offset) { index, slot in
                Button {
                    if index != state.active { send(MaterialBpy.setActiveSlot(index, object: object.name, editing: state.editing)) }
                } label: {
                    HStack(spacing: 8) {
                        Swatch(rgb: slot.swatch, size: 18)
                        Text(slot.material ?? "")
                            .font(BTheme.Font.ui(13))
                            .foregroundStyle(index == state.active ? BTheme.title : BTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: BTheme.Metric.touchRow)
                    .frame(maxWidth: .infinity)
                    .background(index == state.active ? BTheme.select.opacity(0.35) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Material slot \(index + 1): \(slot.material ?? "empty")")
                .accessibilityAddTraits(index == state.active ? .isSelected : [])
            }
            if state.slots.isEmpty {
                Color.clear.frame(height: BTheme.Metric.touchRow * 2)
            }
        }
        .padding(2)
        .frame(minHeight: BTheme.Metric.touchRow * 3, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    /// Blender's column beside the list: +, -, Material Specials, and the
    /// move arrows once there are two slots.
    @ViewBuilder
    private func slotButtons(_ state: MaterialPanelState) -> some View {
        VStack(spacing: 4) {
            iconButton("plus", "Add Material Slot") {
                send(MaterialBpy.addSlot(object: object.name, editing: state.editing))
            }
            iconButton("minus", "Remove Material Slot") { send(MaterialBpy.removeSlot(object: object.name)) }
                // Blender's poll: "Unable to remove material slot in edit mode".
                .disabled(state.slots.isEmpty || state.editing)
            Menu {
                ForEach(MaterialBpy.Special.allCases, id: \.self) { row in
                    Button(row.rawValue) {
                        send(MaterialBpy.special(row, object: object.name, editing: state.editing))
                    }
                    .disabled(!row.available(editing: state.editing) || state.slots.isEmpty
                              || ((row == .copyMaterial || row == .pasteMaterial) && state.material == nil))
                }
            } label: {
                iconLabel("chevron.down")
            }
            .accessibilityLabel("Material Specials")
            if state.isSortable {
                iconButton("arrowtriangle.up.fill", "Move Material Up") {
                    send(MaterialBpy.moveSlot(up: true, object: object.name, editing: state.editing))
                }
                .disabled(state.active <= 0)
                iconButton("arrowtriangle.down.fill", "Move Material Down") {
                    send(MaterialBpy.moveSlot(up: false, object: object.name, editing: state.editing))
                }
                .disabled(state.active >= state.slots.count - 1)
            }
        }
    }

    /// The slot's template_ID: browse, the name, the user count, Fake User,
    /// New (a duplicate when the slot is full) and Unlink; then the Link.
    /// Blender draws them on one row; the Properties editor here is narrow
    /// enough for a finger's buttons to leave the name no room, so the name
    /// has the first row to itself with the browse button, and the buttons
    /// the second, in Blender's order.
    @ViewBuilder
    private func datablockRow(_ state: MaterialPanelState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                browseMenu(state)
                if let material = state.material {
                    MaterialNameField(name: material.name) { wanted in
                        send(MaterialBpy.rename(material.name, to: wanted, editing: state.editing))
                    }
                } else {
                    Button {
                        send(MaterialBpy.newMaterial(object: object.name, editing: state.editing))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            Text("New").font(BTheme.Font.ui(13))
                        }
                        .foregroundStyle(BTheme.text)
                        .frame(maxWidth: .infinity, minHeight: BTheme.Metric.touchField)
                        .background(BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Material")
                }
            }
            HStack(spacing: 4) {
                if let material = state.material {
                    if material.users > 1 {
                        Button {
                            send(MaterialBpy.makeSingleUser(material.name, object: object.name,
                                                            editing: state.editing))
                        } label: {
                            Text("\(material.users)").font(BTheme.Font.mono(13)).foregroundStyle(BTheme.text)
                                .frame(minWidth: BTheme.Metric.touchButton, minHeight: BTheme.Metric.touchField)
                                .background(BTheme.widget)
                                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(material.users) users: Make Single User")
                    }
                    iconButton(material.fakeUser ? "shield.fill" : "shield", "Fake User") {
                        send(MaterialBpy.fakeUser(material.name, !material.fakeUser, editing: state.editing))
                    }
                    .accessibilityValue(material.fakeUser ? "On" : "Off")
                    iconButton("plus.square.on.square", "New Material") {
                        send(MaterialBpy.newMaterial(object: object.name, editing: state.editing))
                    }
                    iconButton("xmark", "Unlink Data-Block") {
                        send(MaterialBpy.unlink(object: object.name, editing: state.editing))
                    }
                }
                Spacer(minLength: 0)
                if let slot = state.activeSlot {
                    Menu {
                        ForEach([("DATA", "Data"), ("OBJECT", "Object")], id: \.0) { id, name in
                            Button {
                                if id != slot.link {
                                    send(MaterialBpy.link(id, slot: state.active, object: object.name,
                                                          editing: state.editing))
                                }
                            } label: {
                                Label(name, systemImage: id == slot.link ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(slot.link == "OBJECT" ? "Object" : "Data")
                                .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(BTheme.textDim)
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: BTheme.Metric.touchField)
                        .background(BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                    }
                    .accessibilityLabel("Link")
                }
            }
        }
    }

    /// The browse button: every material of the file, each with its colour.
    @ViewBuilder
    private func browseMenu(_ state: MaterialPanelState) -> some View {
        Menu {
            ForEach(state.materials, id: \.name) { listed in
                Button {
                    send(MaterialBpy.browse(listed.name, object: object.name, editing: state.editing))
                } label: {
                    Label {
                        Text(listed.name)
                    } icon: {
                        Image(uiImage: Swatch.image(listed.swatch))
                    }
                }
            }
            if state.materials.isEmpty {
                Button("No materials in this file") {}.disabled(true)
            }
        } label: {
            HStack(spacing: 3) {
                Swatch(rgb: state.activeSlot?.swatch, size: 16)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BTheme.text)
            }
            .frame(width: 50, height: BTheme.Metric.touchField)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .accessibilityLabel("Browse Material to be linked")
    }

    // MARK: Surface and Volume

    @ViewBuilder
    private func surfacePanel(_ material: MaterialPanelState.Material,
                              socket path: KeyPath<MaterialPanelState.Material, MaterialPanelState.SocketView>,
                              title: String, open: Bool) -> some View {
        let view = material[keyPath: path]
        BPanel(title, open: open) {
            if view.output == nil {
                note("No output node")
            } else if view.missing == true {
                note("Incompatible output node")
            } else {
                shaderRow(material, view: view, title: title)
                if let node = view.node {
                    NodeItemsView(items: node.items, node: node, material: material.name, editing: editing,
                                  scene: scene, send: send)
                }
            }
        }
        .disabled(!usable || material.library)
    }

    /// The output's socket and the shader linked to it, as a menu of every
    /// shader (Blender's node link button and its menu).
    @ViewBuilder
    private func shaderRow(_ material: MaterialPanelState.Material, view: MaterialPanelState.SocketView,
                           title: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer(minLength: 4)
            Menu {
                Section("Shader") {
                    ForEach(MaterialBpy.shaders, id: \.type) { shader in
                        Button {
                            send(MaterialBpy.setShader(shader.type, socket: title, material: material.name,
                                                       editing: editing))
                        } label: {
                            Label(shader.name, systemImage: view.node?.type == shader.type ? "checkmark" : "")
                        }
                    }
                }
                if view.node != nil {
                    Section("Link") {
                        Button("Remove", role: .destructive) {
                            send(MaterialBpy.unlinkShader(remove: true, socket: title, material: material.name,
                                                          editing: editing))
                        }
                        Button("Disconnect") {
                            send(MaterialBpy.unlinkShader(remove: false, socket: title, material: material.name,
                                                          editing: editing))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0x63C763)).frame(width: 8, height: 8)
                    Text(view.link ?? "None").font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BTheme.textDim)
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 170, minHeight: BTheme.Metric.touchField)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }
            .accessibilityLabel("\(title): \(view.link ?? "None")")
        }
        .frame(minHeight: BTheme.Metric.touchField)
    }

    // MARK: Settings and Viewport Display

    @ViewBuilder
    private func settingsPanel(_ material: MaterialPanelState.Material) -> some View {
        let s = material.settings
        BPanel("Settings") {
            settingNumber(.passIndex, s, material: material.name, step: 0.1, unit: .count)
            subheading("Surface")
            subheading("Backface Culling", dim: true)
            settingFlag(.backfaceCamera, s, material: material.name)
            settingFlag(.backfaceShadow, s, material: material.name)
            settingFlag(.backfaceProbe, s, material: material.name)
            settingChoice(.displacement, s, material: material.name)
            settingNumber(.maxDisplacement, s, material: material.name, step: 0.01, unit: .meters)
                .disabled(s[MaterialBpy.Setting.displacement.rawValue]?.text == "BUMP")
            settingFlag(.transparentShadow, s, material: material.name)
            settingChoice(.renderMethod, s, material: material.name)
            if s[MaterialBpy.Setting.renderMethod.rawValue]?.text == "BLENDED" {
                settingFlag(.transparencyOverlap, s, material: material.name)
            } else {
                settingFlag(.raytraceRefraction, s, material: material.name)
            }
            settingChoice(.thickness, s, material: material.name)
            if s[MaterialBpy.Setting.renderMethod.rawValue]?.text == "DITHERED" {
                settingFlag(.thicknessFromShadow, s, material: material.name)
            }
            subheading("Volume")
            settingChoice(.volumeIntersection, s, material: material.name)
        }
        .disabled(!usable || material.library)
    }

    @ViewBuilder
    private func viewportPanel(_ material: MaterialPanelState.Material) -> some View {
        let c = material.viewport.color.map(Float.init)
        BPanel("Viewport Display", open: Self.opensViewportDisplay) {
            MaterialColorField(
                label: "Color",
                linear: SIMD4(c.count > 0 ? c[0] : 0.8, c.count > 1 ? c[1] : 0.8, c.count > 2 ? c[2] : 0.8,
                              c.count > 3 ? c[3] : 1),
                opacity: true,
                preview: { srgb in
                    let l = ColorSpace.linear(SIMD3(srgb.x, srgb.y, srgb.z))
                    scene.previewMaterial(material.name) { $0.display = SIMD4(l.x, l.y, l.z, srgb.w) }
                },
                commit: { srgb in
                    send(MaterialBpy.setViewportColor(srgb: srgb, material: material.name, editing: editing))
                })
            MaterialNumberField(label: "Metallic", value: material.viewport.metallic, step: 0.01,
                                clamp: { min(max($0, 0), 1) },
                                preview: { v in scene.previewMaterial(material.name) { $0.displayMetallic = Float(v) } },
                                commit: { v in
                                    send(MaterialBpy.setViewport(metallic: true, v, material: material.name,
                                                                 editing: editing))
                                })
            MaterialNumberField(label: "Roughness", value: material.viewport.roughness, step: 0.01,
                                clamp: { min(max($0, 0), 1) },
                                preview: { v in scene.previewMaterial(material.name) { $0.displayRoughness = Float(v) } },
                                commit: { v in
                                    send(MaterialBpy.setViewport(metallic: false, v, material: material.name,
                                                                 editing: editing))
                                })
        }
        .disabled(!usable || material.library)
    }

    @ViewBuilder
    private func settingFlag(_ setting: MaterialBpy.Setting, _ s: [String: MaterialPanelState.Value],
                             material: String) -> some View {
        if let on = s[setting.rawValue]?.bool {
            flagRow(setting.label, on: on) { send(MaterialBpy.setSetting(setting, bool: $0, material: material,
                                                                        editing: editing)) }
        }
    }

    @ViewBuilder
    private func settingChoice(_ setting: MaterialBpy.Setting, _ s: [String: MaterialPanelState.Value],
                               material: String) -> some View {
        if let value = s[setting.rawValue]?.text {
            choiceRow(setting.label, options: setting.options.map { [$0.id, $0.name] }, selected: value) { id in
                send(MaterialBpy.setSetting(setting, option: id, material: material, editing: editing))
            }
        }
    }

    @ViewBuilder
    private func settingNumber(_ setting: MaterialBpy.Setting, _ s: [String: MaterialPanelState.Value],
                               material: String, step: Float, unit: BNumberField.Unit) -> some View {
        if let value = s[setting.rawValue]?.number {
            MaterialNumberField(label: setting.label, value: value, step: Double(step), unit: unit,
                                clamp: { max($0, 0) }, preview: { _ in },
                                commit: { v in send(MaterialBpy.setSetting(setting, number: v, material: material,
                                                                           editing: editing)) })
        }
    }

    /// Closed, as Blender draws it; DEBUG's `-material-open-viewport` opens it
    /// for a picture.
    private static var opensViewportDisplay: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-material-open-viewport")
        #else
        return false
        #endif
    }

    // MARK: pieces

    @ViewBuilder
    private func note(_ text: String) -> some View {
        Text(text)
            .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func subheading(_ text: String, dim: Bool = false) -> some View {
        Text(text).font(BTheme.Font.ui(12, weight: dim ? .regular : .medium))
            .foregroundStyle(dim ? BTheme.textDim : BTheme.text)
            .padding(.top, 4)
    }

    private func iconLabel(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(BTheme.text)
            .frame(width: BTheme.Metric.touchButton, height: BTheme.Metric.touchField)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    @ViewBuilder
    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(icon) }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func wideButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                .frame(maxWidth: .infinity).frame(height: BTheme.Metric.touchField)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

// MARK: - A node's inputs (template_node_view)

/// A node's buttons, inputs and panels, drawn as Blender's Material tab
/// draws them: each input's label on the left, its value on the right — or,
/// linked, the name of the node it comes from — and each panel collapsible,
/// closed until opened as Blender's are.
private struct NodeItemsView: View {
    let items: [MaterialPanelState.Item]
    let node: MaterialPanelState.Node
    let material: String
    let editing: Bool
    let scene: BKScene
    let send: (MaterialBpy.Command) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .input(let input):
                InputRow(input: input, node: node, material: material, editing: editing, scene: scene, send: send)
            case .prop(let prop):
                choiceRow(prop.label, options: prop.options, selected: prop.value) { id in
                    send(MaterialBpy.setNodeProp(prop, to: id, node: node.name, material: material, editing: editing))
                }
            case .panel(let label, let open, let inner):
                NodePanel(label: label, open: open) {
                    NodeItemsView(items: inner, node: node, material: material, editing: editing,
                                  scene: scene, send: send)
                }
            }
        }
    }
}

/// One of a node's panels: Subsurface, Specular, Coat… with its triangle.
private struct NodePanel<Content: View>: View {
    let label: String
    @State private var open: Bool
    @ViewBuilder let content: Content

    init(label: String, open: Bool, @ViewBuilder content: () -> Content) {
        self.label = label
        self._open = State(initialValue: open)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(label).font(BTheme.Font.ui(13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(BTheme.text)
                .frame(height: BTheme.Metric.touchField)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(open ? "Open" : "Closed")
            if open {
                VStack(alignment: .leading, spacing: 4) { content }
                    .padding(.leading, 10)
            }
        }
    }
}

/// One input of a node.
private struct InputRow: View {
    let input: MaterialPanelState.Input
    let node: MaterialPanelState.Node
    let material: String
    let editing: Bool
    let scene: BKScene
    let send: (MaterialBpy.Command) -> Void

    var body: some View {
        if let link = input.link {
            labelled(input.label) {
                // A linked input's value is not used; Blender names the node.
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0xC7C729)).frame(width: 8, height: 8)
                    Text(link).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: BTheme.Metric.touchField)
                .background(BTheme.field)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                .accessibilityLabel("\(input.label): \(link)")
            }
        } else if input.hideValue || input.type == "SHADER" {
            labelled(input.label) {
                Text(input.type == "SHADER" ? "None" : "Default")
                    .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(minHeight: BTheme.Metric.touchField)
            }
        } else {
            switch input.type {
            case "RGBA":
                let v = (input.value?.vector ?? [0.8, 0.8, 0.8, 1]).map(Float.init)
                labelled(input.label) {
                    MaterialColorField(
                        label: input.label,
                        linear: SIMD4(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0, 1),
                        opacity: false, showsLabel: false,
                        preview: { srgb in
                            let l = ColorSpace.linear(SIMD3(srgb.x, srgb.y, srgb.z))
                            preview(colour: l)
                        },
                        commit: { srgb in
                            send(MaterialBpy.setInput(input, srgb: SIMD3(srgb.x, srgb.y, srgb.z), node: node.name,
                                                      material: material, editing: editing))
                        })
                }
            case "VALUE", "INT":
                MaterialNumberField(label: input.label, value: input.value?.number ?? 0,
                                    step: input.type == "INT" ? 0.1 : step,
                                    unit: input.type == "INT" ? .count : (input.subtype == "DISTANCE" ? .meters : .none),
                                    clamp: { input.clamped($0) },
                                    preview: { v in preview(number: v) },
                                    commit: { v in
                                        send(MaterialBpy.setInput(input, number: v, node: node.name,
                                                                  material: material, editing: editing))
                                    })
                    .opacity(input.inactive ? 0.5 : 1)
            case "BOOLEAN":
                flagRow(input.label, on: input.value?.bool ?? false) { on in
                    send(MaterialBpy.setInput(input, bool: on, node: node.name, material: material, editing: editing))
                }
            case "VECTOR":
                let v = input.value?.vector ?? [0, 0, 0]
                VStack(alignment: .leading, spacing: 2) {
                    Text(input.label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                    ForEach(0..<v.count, id: \.self) { axis in
                        MaterialNumberField(label: ["X", "Y", "Z", "W"][min(axis, 3)], value: v[axis], step: step,
                                            clamp: { input.clamped($0) }, preview: { _ in },
                                            commit: { component in
                                                var next = v
                                                next[axis] = component
                                                send(MaterialBpy.setInput(input, vector: next, node: node.name,
                                                                          material: material, editing: editing))
                                            })
                    }
                }
            default:
                labelled(input.label) {
                    Text(input.value?.text ?? "").font(BTheme.Font.mono(13)).foregroundStyle(BTheme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A drag step that suits the range: a hundredth across 0…1.
    private var step: Double {
        guard let lo = input.min, let hi = input.max, hi > lo else { return 0.01 }
        return min(max((hi - lo) / 100, 0.001), 1)
    }

    /// What the 3D View previews while this input is dragged: the look's
    /// field this socket feeds (`_blenderkit_material.look`).
    private func preview(number v: Double) {
        let x = Float(v)
        scene.previewMaterial(material) { look in
            guard look.shader == node.type else { return }
            switch input.id {
            case "Metallic": look.metallic = x
            case "Roughness": look.roughness = x
            case "IOR": look.ior = x
            case "Alpha": look.alpha = x
            case "Emission Strength", "Strength": look.strength = x
            default: break
            }
        }
    }

    private func preview(colour l: SIMD3<Float>) {
        scene.previewMaterial(material) { look in
            guard look.shader == node.type else { return }
            switch input.id {
            case "Base Color", "Color":
                if node.type == "ShaderNodeEmission" || node.type == "ShaderNodeBackground" {
                    look.emission = l
                } else {
                    look.base = l
                }
            case "Emission Color": look.emission = l
            default: break
            }
        }
    }
}

// MARK: - Fields

/// A label on the left and a control on the right, Blender's split layout.
@ViewBuilder
private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 6) {
        Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            .lineLimit(1)
            .frame(width: 110, alignment: .trailing)
        content()
    }
    .frame(minHeight: BTheme.Metric.touchField)
}

/// One of Blender's checkboxes: it shows `on` as Blender holds it, and a tap
/// sends the change.
@ViewBuilder
private func flagRow(_ label: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
    HStack {
        Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
        Spacer()
        Toggle("", isOn: Binding(get: { on }, set: set))
            .labelsHidden()
            .scaleEffect(0.8)
    }
    .frame(minHeight: BTheme.Metric.touchField)
    .accessibilityElement(children: .combine)
}

/// An enum: its name for the value, and a menu of its items.
@ViewBuilder
private func choiceRow(_ label: String, options: [[String]], selected: String,
                       set: @escaping (String) -> Void) -> some View {
    HStack(spacing: 6) {
        Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
        Spacer(minLength: 4)
        Menu {
            ForEach(options, id: \.self) { option in
                let id = option.first ?? ""
                Button {
                    if id != selected { set(id) }
                } label: {
                    Label(option.count > 1 ? option[1] : id, systemImage: id == selected ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.first == selected }.flatMap { $0.count > 1 ? $0[1] : nil } ?? selected)
                    .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BTheme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: BTheme.Metric.touchField)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .accessibilityLabel(label)
    }
    .frame(minHeight: BTheme.Metric.touchField)
}

/// A number held in Blender: a draft while a finger is on it, previewed in
/// the 3D View as it moves, committed once when it lifts, clamped to the
/// range Blender's own slider drags within.
private struct MaterialNumberField: View {
    let label: String
    let value: Double
    var step: Double = 0.01
    var unit: BNumberField.Unit = .none
    let clamp: (Double) -> Double
    let preview: (Double) -> Void
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        BNumberField(label, value: Binding(get: { Float(draft ?? value) },
                                           set: { v in
                                               let c = clamp(Double(v))
                                               draft = c
                                               preview(c)
                                           }),
                     step: Float(step), unit: unit,
                     commit: { v in
                         let sent = clamp(Double(v))
                         draft = nil
                         if abs(sent - value) > 1e-9 { commit(sent) }
                     })
    }
}

/// A colour held in Blender, picked in sRGB. The system picker streams every
/// change; each is previewed in the 3D View, and the colour is written once
/// the picking has paused, so one pick is one write and one undo step.
private struct MaterialColorField: View {
    let label: String
    /// As Blender holds it: linear, alpha last.
    let linear: SIMD4<Float>
    var opacity = false
    var showsLabel = true
    let preview: (SIMD4<Float>) -> Void
    let commit: (SIMD4<Float>) -> Void
    @State private var draft: SIMD4<Float>?
    @State private var pending: Task<Void, Never>?

    private var shownSRGB: SIMD4<Float> {
        if let draft { return draft }
        let s = ColorSpace.srgb(SIMD3(linear.x, linear.y, linear.z))
        return SIMD4(s.x, s.y, s.z, linear.w)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsLabel {
                Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                Spacer(minLength: 4)
            }
            ZStack {
                RoundedRectangle(cornerRadius: BTheme.Metric.corner)
                    .fill(Color(.sRGB, red: Double(shownSRGB.x), green: Double(shownSRGB.y),
                                blue: Double(shownSRGB.z), opacity: 1))
                ColorPicker("", selection: Binding(get: {
                    let c = shownSRGB
                    return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z),
                                 opacity: Double(c.w))
                }, set: { picked in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
                    UIColor(picked).getRed(&r, green: &g, blue: &b, alpha: &a)
                    let c = SIMD4(Float(min(max(r, 0), 1)), Float(min(max(g, 0), 1)),
                                  Float(min(max(b, 0), 1)), opacity ? Float(a) : linear.w)
                    draft = c
                    preview(c)
                    pending?.cancel()
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        finish()
                    }
                }), supportsOpacity: opacity)
                .labelsHidden()
                .opacity(0.02)
            }
            .frame(maxWidth: showsLabel ? 120 : .infinity, minHeight: BTheme.Metric.touchField)
            .accessibilityLabel(label)
        }
        .frame(minHeight: BTheme.Metric.touchField)
        .onDisappear { finish() }
    }

    private func finish() {
        pending?.cancel()
        pending = nil
        guard let c = draft else { return }
        draft = nil
        commit(c)
    }
}

/// A material's name, typed into a draft and sent when the edit ends —
/// Return or the field losing focus — as Blender applies a text field.
private struct MaterialNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: Binding(get: { draft ?? name }, set: { draft = $0 }))
            .textFieldStyle(.plain)
            .font(BTheme.Font.ui(13))
            .foregroundStyle(BTheme.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .focused($focused)
            .onSubmit { end() }
            .onChange(of: focused) { _, now in if !now { end() } }
            .onChange(of: name) { _, _ in draft = nil }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: BTheme.Metric.touchField)
            .background(BTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            .accessibilityLabel("Name")
    }

    private func end() {
        guard let text = draft, text != name else { draft = nil; return }
        draft = nil
        commit(text)
    }
}

/// A material's colour, as a circle (Blender draws its preview there).
private struct Swatch: View {
    let rgb: [Double]?
    let size: CGFloat

    var body: some View {
        Group {
            if let rgb, rgb.count >= 3 {
                Circle().fill(Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2], opacity: 1))
            } else {
                Circle().strokeBorder(BTheme.textDim, lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }

    /// The same circle as an image a menu row can show in its own colour.
    static func image(_ rgb: [Double]?) -> UIImage {
        let size = CGSize(width: 18, height: 18)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let path = UIBezierPath(ovalIn: rect)
            if let rgb, rgb.count >= 3 {
                UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).setFill()
                path.fill()
            } else {
                UIColor.gray.setStroke()
                path.stroke()
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}

#if DEBUG
/// What the tab last read, for DEBUG hooks that check it without a screen.
enum MaterialPanelsDebug {
    nonisolated(unsafe) static var last: MaterialPanelState?
    nonisolated(unsafe) static var ran = false
    static func shown(_ state: MaterialPanelState?) {
        last = state
        guard ProcessInfo.processInfo.arguments.contains("-material-ops"), let state else { return }
        let slots = state.slots.map { $0.material ?? "(empty)" }.joined(separator: ", ")
        print("[bk] Material tab: \(state.object ?? "?") slots [\(slots)] active \(state.active)"
              + (state.material.map { "; \($0.name) users \($0.users), surface \($0.surface.link ?? "None")" } ?? ""))
        fflush(stdout)
    }
}
#endif
