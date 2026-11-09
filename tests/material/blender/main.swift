import Foundation
import simd

// Properties ▸ Material, the Swift half of Blender's check. Three jobs:
//
// With no argument it prints every command the tab sends — what runs
// (`executed`), the Info log's line and the undo step — as `### NAME` blocks,
// and the shader list the Surface menu offers. verify.py runs each in desktop
// Blender in the order a session would.
//
// With `inputs <state file>` it reads a state `_blenderkit_material.state`
// printed and prints, for every input of the surface node and every node
// setting it shows, the command the tab sends for a new value — so the
// inputs come from Blender's own state, as the tab's do — with the value
// Blender should then hold.
//
// With `replay <json>` it reads what verify.py recorded — states and the
// mirror's records beside what Blender held — and checks the tab and the 3D
// View would show exactly that.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
let object = "Cube"

func block(_ name: String, _ command: MaterialBpy.Command) {
    print("### \(name)\n\(command.executed)\n#--")
    print("### \(name).call\n\(command.call)\n#--")
    print("### \(name).undo\n\(command.undo ?? "-")\n#--")
}

func text(_ name: String, _ body: String) { print("### \(name)\n\(body)\n#--") }

if args.count == 1 {
    text("STATE", MaterialBpy.state(object: object))
    text("STATE_SPHERE", MaterialBpy.state(object: "Sphere"))
    text("SHADERS", MaterialBpy.shaders.map { "\($0.type)|\($0.name)" }.joined(separator: "\n"))
    text("SPECIALS", MaterialBpy.Special.allCases.map { "\($0.rawValue)|\($0.call)" }.joined(separator: "\n"))

    // The slot list.
    block("ADD_SLOT", MaterialBpy.addSlot(object: object, editing: false))
    block("ADD_SLOT_EDIT", MaterialBpy.addSlot(object: object, editing: true))
    block("ACTIVE_0", MaterialBpy.setActiveSlot(0, object: object, editing: false))
    block("ACTIVE_1", MaterialBpy.setActiveSlot(1, object: object, editing: false))
    block("ACTIVE_9", MaterialBpy.setActiveSlot(9, object: object, editing: false))
    block("REMOVE_SLOT", MaterialBpy.removeSlot(object: object))
    block("MOVE_UP", MaterialBpy.moveSlot(up: true, object: object, editing: false))
    block("MOVE_DOWN", MaterialBpy.moveSlot(up: false, object: object, editing: false))
    block("ASSIGN", MaterialBpy.assign(object: object))
    block("SELECT", MaterialBpy.select(true, object: object))
    block("DESELECT", MaterialBpy.select(false, object: object))
    for row in MaterialBpy.Special.allCases {
        let key = row.rawValue.uppercased().replacingOccurrences(of: " ", with: "_")
        block(key, MaterialBpy.special(row, object: object, editing: false))
        block(key + "_EDIT", MaterialBpy.special(row, object: object, editing: true))
    }

    // The datablock.
    block("NEW", MaterialBpy.newMaterial(object: object, editing: false))
    block("NEW_EDIT", MaterialBpy.newMaterial(object: object, editing: true))
    block("NEW_SPHERE", MaterialBpy.newMaterial(object: "Sphere", editing: false))
    block("BROWSE_MATERIAL", MaterialBpy.browse("Material", object: object, editing: false))
    block("BROWSE_EDIT", MaterialBpy.browse("Material", object: object, editing: true))
    block("ACTIVE_0_EDIT", MaterialBpy.setActiveSlot(0, object: object, editing: true))
    block("UNLINK_EDIT", MaterialBpy.unlink(object: object, editing: true))
    block("BROWSE_ODD", MaterialBpy.browse("Q \"uoted\" 名前;|=%", object: object, editing: false))
    block("BROWSE_MISSING", MaterialBpy.browse("Nope", object: object, editing: false))
    block("UNLINK", MaterialBpy.unlink(object: object, editing: false))
    block("SINGLE_USER", MaterialBpy.makeSingleUser("Material", object: object, editing: false))
    block("FAKE_ON", MaterialBpy.fakeUser("Material", true, editing: false))
    block("FAKE_OFF", MaterialBpy.fakeUser("Material", false, editing: false))
    block("RENAME_ODD", MaterialBpy.rename("Material", to: "Q \"uoted\" 名前;|=%", editing: false))
    block("RENAME_BACK", MaterialBpy.rename("Q \"uoted\" 名前;|=%", to: "Material", editing: false))
    block("RENAME_EMPTY", MaterialBpy.rename("Material", to: "  ", editing: false))
    block("LINK_OBJECT", MaterialBpy.link("OBJECT", slot: 0, object: object, editing: false))
    block("LINK_DATA", MaterialBpy.link("DATA", slot: 0, object: object, editing: false))

    // Surface.
    for (type, name) in MaterialBpy.shaders {
        let key = "SHADER_" + name.uppercased().replacingOccurrences(of: " ", with: "_")
        block(key, MaterialBpy.setShader(type, socket: "Surface", material: "Material", editing: false))
    }
    block("VOLUME_PRINCIPLED", MaterialBpy.setShader("ShaderNodeVolumePrincipled", socket: "Volume",
                                                     material: "Material", editing: false))
    block("SHADER_NOT_ONE", MaterialBpy.setShader("ShaderNodeTexImage", socket: "Surface", material: "Material",
                                                  editing: false))
    block("DISCONNECT", MaterialBpy.unlinkShader(remove: false, socket: "Surface", material: "Material",
                                                 editing: false))
    block("REMOVE", MaterialBpy.unlinkShader(remove: true, socket: "Surface", material: "Material",
                                             editing: false))

    // Settings, each set to something other than its default.
    let settings: [(MaterialBpy.Setting, MaterialBpy.Command)] = [
        (.passIndex, MaterialBpy.setSetting(.passIndex, number: 7.4, material: "Material", editing: false)),
        (.backfaceCamera, MaterialBpy.setSetting(.backfaceCamera, bool: true, material: "Material", editing: false)),
        (.backfaceShadow, MaterialBpy.setSetting(.backfaceShadow, bool: true, material: "Material", editing: false)),
        (.backfaceProbe, MaterialBpy.setSetting(.backfaceProbe, bool: true, material: "Material", editing: false)),
        (.displacement, MaterialBpy.setSetting(.displacement, option: "BOTH", material: "Material", editing: false)),
        (.maxDisplacement, MaterialBpy.setSetting(.maxDisplacement, number: 0.25, material: "Material",
                                                  editing: false)),
        (.transparentShadow, MaterialBpy.setSetting(.transparentShadow, bool: false, material: "Material",
                                                    editing: false)),
        (.renderMethod, MaterialBpy.setSetting(.renderMethod, option: "BLENDED", material: "Material",
                                               editing: false)),
        (.transparencyOverlap, MaterialBpy.setSetting(.transparencyOverlap, bool: false, material: "Material",
                                                      editing: false)),
        (.raytraceRefraction, MaterialBpy.setSetting(.raytraceRefraction, bool: true, material: "Material",
                                                     editing: false)),
        (.thickness, MaterialBpy.setSetting(.thickness, option: "SLAB", material: "Material", editing: false)),
        (.thicknessFromShadow, MaterialBpy.setSetting(.thicknessFromShadow, bool: true, material: "Material",
                                                      editing: false)),
        (.volumeIntersection, MaterialBpy.setSetting(.volumeIntersection, option: "ACCURATE", material: "Material",
                                                     editing: false)),
    ]
    for (setting, command) in settings {
        block("SETTING_" + setting.rawValue, command)
        let options = setting.options.map { "\($0.id)|\($0.name)" }.joined(separator: ",")
        text("SETTING_" + setting.rawValue + ".label", setting.label + (options.isEmpty ? "" : "\n" + options))
    }
    block("SETTING_EDIT", MaterialBpy.setSetting(.backfaceCamera, bool: false, material: "Material", editing: true))
    block("PASS_INDEX_PAST", MaterialBpy.setSetting(.passIndex, number: 99999, material: "Material", editing: false))

    // Viewport Display: sRGB (0.5, 0.25, 0.75) at alpha 0.5.
    block("VIEWPORT_COLOR", MaterialBpy.setViewportColor(srgb: SIMD4(0.5, 0.25, 0.75, 0.5), material: "Material",
                                                         editing: false))
    block("VIEWPORT_METALLIC", MaterialBpy.setViewport(metallic: true, 0.3, material: "Material", editing: false))
    block("VIEWPORT_ROUGHNESS", MaterialBpy.setViewport(metallic: false, 1.7, material: "Material", editing: false))
    block("VIEWPORT_EDIT", MaterialBpy.setViewport(metallic: true, 0.6, material: "Material", editing: true))
    exit(0)
}

if args.count >= 3, args[1] == "inputs" {
    // Every input and setting of the surface node in a state, as the tab
    // sends a new value for each.
    guard let raw = try? String(contentsOfFile: args[2], encoding: .utf8),
          let state = MaterialPanelState.parse(raw), let material = state.material,
          let node = material.surface.node else {
        print("### ERROR\nno state with a surface node in \(args[2])\n#--")
        exit(1)
    }
    let editing = args.count > 3 && args[3] == "edit"
    var n = 0
    func walk(_ items: [MaterialPanelState.Item]) {
        for item in items {
            switch item {
            case .input(let input):
                guard input.link == nil, !input.hideValue else { continue }
                let command: MaterialBpy.Command
                let expect: String
                switch input.type {
                case "RGBA":
                    let srgb = SIMD3<Float>(0.5, 0.25, 0.75)
                    command = MaterialBpy.setInput(input, srgb: srgb, node: node.name, material: material.name,
                                                   editing: editing)
                    let l = ColorSpace.linear(srgb)
                    expect = "\(l.x),\(l.y),\(l.z)"
                case "VALUE":
                    // Past the top of the range: the tab clamps as Blender's
                    // slider stops.
                    let wanted = (input.max ?? 1) + 5
                    command = MaterialBpy.setInput(input, number: wanted, node: node.name,
                                                   material: material.name, editing: editing)
                    expect = "\(input.clamped(wanted))"
                case "INT":
                    command = MaterialBpy.setInput(input, number: 3, node: node.name, material: material.name,
                                                   editing: editing)
                    expect = "3"
                case "VECTOR":
                    let v = [0.3, 0.4, 0.5]
                    command = MaterialBpy.setInput(input, vector: v, node: node.name, material: material.name,
                                                   editing: editing)
                    expect = v.map { "\(input.clamped($0))" }.joined(separator: ",")
                case "BOOLEAN":
                    let now = input.value?.bool ?? false
                    command = MaterialBpy.setInput(input, bool: !now, node: node.name, material: material.name,
                                                   editing: editing)
                    expect = now ? "False" : "True"
                default:
                    continue
                }
                block("INPUT_\(n)", command)
                text("INPUT_\(n).expect", "\(input.index)|\(input.id)|\(input.type)|\(expect)|\(input.label)")
                n += 1
            case .prop(let prop):
                guard let other = prop.options.first(where: { $0.first != prop.value })?.first else { continue }
                block("PROP_\(n)", MaterialBpy.setNodeProp(prop, to: other, node: node.name, material: material.name,
                                                           editing: editing))
                text("PROP_\(n).expect", "\(prop.id)|\(other)|\(prop.label)")
                n += 1
            case .panel(_, _, let inner):
                walk(inner)
            }
        }
    }
    walk(node.items)
    exit(0)
}

guard args.count >= 3, args[1] == "replay",
      let data = FileManager.default.contents(atPath: args[2]),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
else {
    print("usage: dump | dump inputs <state> [edit] | dump replay <json>")
    exit(2)
}

print("== the tab reads back what Blender held ==")
for entry in (json["states"] as? [[String: Any]]) ?? [] {
    let label = entry["label"] as? String ?? "?"
    let raw = entry["json"] as? String ?? ""
    let expect = entry["expect"] as? [String: Any] ?? [:]
    guard let state = MaterialPanelState.parse(raw) else {
        check("\(label): the state parses", false, raw.prefix(200).description)
        continue
    }
    if let slots = expect["slots"] as? [Any] {
        let names = slots.map { $0 as? String }
        check("\(label): slots \(names.map { $0 ?? "(empty)" })", state.slots.map(\.material) == names,
              "\(state.slots.map(\.material))")
    }
    if let active = expect["active"] as? Int {
        check("\(label): the active slot is \(active)", state.active == active, "\(state.active)")
    }
    if let name = expect["material"] as? String {
        check("\(label): its material \(name)", state.material?.name == name, "\(state.material?.name ?? "none")")
    } else if expect["material"] is NSNull {
        check("\(label): no material in the active slot", state.material == nil)
    }
    if let users = expect["users"] as? Int {
        check("\(label): \(users) users", state.material?.users == users, "\(state.material?.users ?? -1)")
    }
    if let link = expect["surface"] as? String {
        check("\(label): Surface is \(link)", state.material?.surface.link == link,
              "\(state.material?.surface.link ?? "None")")
    }
    if let inputs = expect["inputs"] as? [String] {
        let shown = state.material?.surface.node?.inputs.map(\.id) ?? []
        check("\(label): the surface's inputs in Blender's order, unavailable ones left out (\(shown.count))",
              shown == inputs, "\(shown) vs \(inputs)")
    }
    if let labels = expect["labels"] as? [String: String] {
        let byID = Dictionary((state.material?.surface.node?.inputs ?? []).map { ($0.id, $0.label) },
                              uniquingKeysWith: { a, _ in a })
        let wrong = labels.filter { byID[$0.key] != $0.value }
        check("\(label): each input's label as Blender draws it in its panel (\(labels.count))", wrong.isEmpty,
              "\(wrong.map { "\($0.key): \(byID[$0.key] ?? "-") not \($0.value)" })")
    }
    if let panels = expect["panels"] as? [String] {
        let shown: [String] = (state.material?.surface.node?.items ?? []).compactMap {
            if case .panel(let l, _, _) = $0 { return l }
            return nil
        }
        check("\(label): the panels \(panels)", shown == panels, "\(shown)")
    }
    if let linkedInput = expect["linked_input"] as? [String] {
        let input = state.material?.surface.node?.inputs.first { $0.id == linkedInput[0] }
        check("\(label): \(linkedInput[0]) shows \(linkedInput[1])", input?.link == linkedInput[1],
              "\(input?.link ?? "no link")")
    }
    if let listed = expect["listed"] as? [String] {
        check("\(label): the browse menu lists \(listed)", state.materials.map(\.name) == listed,
              "\(state.materials.map(\.name))")
    }
    if let settings = expect["settings"] as? [String: Any] {
        var wrong: [String] = []
        for (key, value) in settings {
            let shown = state.material?.settings[key]
            switch value {
            case let b as Bool where shown?.bool != b: wrong.append(key)
            case let s as String where shown?.text != s: wrong.append(key)
            default: break
            }
        }
        check("\(label): the Settings panel shows Blender's \(settings.count) values", wrong.isEmpty, "\(wrong)")
    }
}

print("== the 3D View draws the slots Blender holds ==")
for entry in (json["records"] as? [[String: Any]]) ?? [] {
    let label = entry["label"] as? String ?? "?"
    let record = entry["record"] as? String ?? ""
    let slots = (entry["slots"] as? [Int]) ?? []
    let expect = entry["expect"] as? [[String: Any]] ?? []
    let holder = BKObject(name: "Held", kind: .cube)
    let triangles = entry["triangles"] as? Int ?? 0
    var indices: [UInt32] = []
    for t in 0..<triangles { indices += [UInt32(t % 3), UInt32((t + 1) % 3), UInt32((t + 2) % 3)] }
    holder.setEvaluatedMesh(MeshData(vertices: [MeshVertex(.zero, SIMD3(0, 0, 1)), MeshVertex(SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
                                                MeshVertex(SIMD3(0, 1, 0), SIMD3(0, 0, 1))], indices: indices))
    let int32 = slots.map { Int32($0) }
    _ = int32.withUnsafeBufferPointer { buffer in
        SceneMirror.installMaterials(record: record, triangleSlots: buffer, on: holder)
    }
    check("\(label): \(expect.count) slot looks", holder.materialLooks.count == expect.count,
          "\(holder.materialLooks.count)")
    for (i, e) in expect.enumerated() where i < holder.materialLooks.count {
        let look = holder.materialLooks[i]
        func near(_ a: [Float], _ b: [Double]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs(Double($0) - $1) < 1e-4 }
        }
        if let display = e["display"] as? [Double] {
            check("\(label) slot \(i): Viewport Display Color \(display)",
                  near([look.display.x, look.display.y, look.display.z, look.display.w], display),
                  "\(look.display)")
        }
        if let base = e["base"] as? [Double] {
            check("\(label) slot \(i): Material Preview's base colour \(base)",
                  near([look.base.x, look.base.y, look.base.z], base), "\(look.base)")
        }
        if let metallic = e["metallic"] as? Double, let roughness = e["roughness"] as? Double {
            check("\(label) slot \(i): metallic \(metallic), roughness \(roughness)",
                  near([look.metallic, look.roughness], [metallic, roughness]), "\(look.metallic) \(look.roughness)")
        }
        if let connected = e["connected"] as? Bool {
            check("\(label) slot \(i): connected \(connected)", look.connected == connected)
        }
        if e["none"] as? Bool == true {
            check("\(label) slot \(i): empty, drawn as Blender's default material", look == .default)
        }
        if let name = e["name"] as? String {
            check("\(label) slot \(i): the material \(name)", look.material == name, "\(look.material ?? "nil")")
        }
    }
    if let runs = entry["runs"] as? [String: Int] {
        let found = holder.slotRuns() ?? []
        let byslot = Dictionary(found.map { ("\($0.slot)", $0.triangles.count) }, uniquingKeysWith: { a, _ in a })
        check("\(label): its triangles drawn by slot \(runs)", byslot == runs, "\(byslot)")
    } else {
        check("\(label): drawn with one look", holder.slotRuns() == nil)
    }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
