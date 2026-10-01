import Foundation

// Vertex groups and shape keys, the Swift half of Blender's check. Two jobs:
//
// With no argument it prints every command the two panels send — what runs
// (`executed`), the Info log's line and the undo step — as `### NAME` blocks,
// and the Vertex Group field's edit for every modifier kind that has one, as
// `Bpy.modifierEdit` builds it from a freshly added row. verify.py runs each
// in desktop Blender in the order a session would.
//
// With `replay <json>` it reads the records Blender's own
// `_blenderkit_groups.record` and `_blenderkit_sync._modifier_record` produced
// beside what Blender held when it produced them, and checks the panels would
// show exactly that.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
let object = "Grid"

func block(_ name: String, _ command: GroupsBpy.Command) {
    print("### \(name)\n\(command.executed)\n#--")
    print("### \(name).call\n\(command.call)\n#--")
    print("### \(name).undo\n\(command.undo ?? "-")\n#--")
}

if args.count == 1 {
    block("ADD_GROUP", GroupsBpy.addGroup(object: object))
    block("RENAME_GROUP", GroupsBpy.renameGroup("Group", to: "Left", object: object))
    block("RENAME_GROUP_2", GroupsBpy.renameGroup("Group.001", to: "Right", object: object))
    // A name holding every separator the record has.
    block("RENAME_GROUP_ODD", GroupsBpy.renameGroup("Group", to: "a;b|c=d%e", object: object))
    block("RENAME_GROUP_EMPTY", GroupsBpy.renameGroup("Left", to: "  ", object: object))
    block("ACTIVE_LEFT", GroupsBpy.setActiveGroup("Left", object: object))
    block("ACTIVE_MISSING", GroupsBpy.setActiveGroup("Nope", object: object))
    block("LOCK_RIGHT", GroupsBpy.lockGroup("Right", true, object: object))
    block("UNLOCK_RIGHT", GroupsBpy.lockGroup("Right", false, object: object))
    block("ASSIGN_LEFT", GroupsBpy.assign("Left", weight: 0.5, object: object))
    // The Weight field past Blender's range is clamped before it is sent.
    block("ASSIGN_LEFT_HEAVY", GroupsBpy.assign("Left", weight: 7, object: object))
    block("ASSIGN_RIGHT", GroupsBpy.assign("Right", weight: 1, object: object))
    block("REMOVE_FROM_LEFT", GroupsBpy.removeFromGroup("Left", object: object))
    block("REMOVE_FROM_RIGHT", GroupsBpy.removeFromGroup("Right", object: object))
    block("SELECT_LEFT", GroupsBpy.selectGroup("Left", select: true, object: object))
    block("DESELECT_LEFT", GroupsBpy.selectGroup("Left", select: false, object: object))
    block("REMOVE_GROUP_RIGHT", GroupsBpy.removeGroup("Right", object: object))
    block("REMOVE_ALL_GROUPS", GroupsBpy.removeAllGroups(object: object))
    print("### WEIGHT\n\(GroupsBpy.setWeight(0.25))\n#--")
    print("### WEIGHT_PAST\n\(GroupsBpy.setWeight(-3))\n#--")

    block("ADD_KEY", GroupsBpy.addKey(fromMix: false, object: object))
    block("ADD_KEY_MIX", GroupsBpy.addKey(fromMix: true, object: object))
    block("REMOVE_KEY_SMILE", GroupsBpy.removeKey("Smile", object: object))
    block("DELETE_ALL_KEYS", GroupsBpy.removeAllKeys(apply: false, object: object))
    block("APPLY_ALL_KEYS", GroupsBpy.removeAllKeys(apply: true, object: object))
    block("ACTIVE_KEY_1", GroupsBpy.setActiveKey("Key 1", object: object))
    block("ACTIVE_KEY_BASIS", GroupsBpy.setActiveKey("Basis", object: object))
    // What the Value field sends for a drag to 1.5 on a key whose slider
    // stops at 1: the draft is clamped as Blender clamps it.
    let unit = MeshGroups.Key(name: "Key 1", value: 0, sliderMin: 0, sliderMax: 1)
    block("KEY_VALUE_HALF", GroupsBpy.setKeyValue("Key 1", unit.clamped(0.5), editing: false, object: object))
    block("KEY_VALUE_PAST", GroupsBpy.setKeyValue("Key 1", unit.clamped(1.5), editing: false, object: object))
    let wide = MeshGroups.Key(name: "Key 1", value: 0, sliderMin: 0, sliderMax: 2)
    block("KEY_VALUE_WIDE", GroupsBpy.setKeyValue("Key 1", wide.clamped(1.5), editing: false, object: object))
    block("KEY_VALUE_EDIT", GroupsBpy.setKeyValue("Key 1", 0.75, editing: true, object: object))
    block("KEY_MAX_2", GroupsBpy.setKey("Key 1", .sliderMax, "2", editing: false, object: object))
    block("KEY_MIN", GroupsBpy.setKey("Key 1", .sliderMin, "-0.5", editing: false, object: object))
    block("KEY_RELATIVE", GroupsBpy.setKey("Key 2", .relativeKey, Bpy.quote("Key 1"), editing: false, object: object))
    block("KEY_RELATIVE_MISSING", GroupsBpy.setKey("Key 2", .relativeKey, Bpy.quote("Nope"), editing: false,
                                                    object: object))
    block("KEY_VGROUP_LEFT", GroupsBpy.setKey("Key 1", .vertexGroup, Bpy.quote("Left"), editing: false, object: object))
    block("KEY_VGROUP_NONE", GroupsBpy.setKey("Key 1", .vertexGroup, Bpy.quote(""), editing: false, object: object))
    block("KEY_MUTE", GroupsBpy.setKey("Key 2", .mute, "True", editing: false, object: object))
    block("KEY_UNMUTE", GroupsBpy.setKey("Key 2", .mute, "False", editing: false, object: object))
    block("KEY_LOCK", GroupsBpy.setKey("Key 2", .locked, "True", editing: false, object: object))
    block("KEY_RENAME", GroupsBpy.setKey("Key 2", .name, Bpy.quote("Smile"), editing: false, object: object))
    block("KEY_RENAME_EDIT", GroupsBpy.setKey("Smile", .name, Bpy.quote("Grin"), editing: true, object: object))
    block("RELATIVE_OFF", GroupsBpy.set(.useRelative, false, editing: false, object: object))
    block("RELATIVE_ON", GroupsBpy.set(.useRelative, true, editing: false, object: object))
    block("SHOW_ONLY_ON", GroupsBpy.set(.showOnly, true, editing: false, object: object))
    block("SHOW_ONLY_OFF", GroupsBpy.set(.showOnly, false, editing: false, object: object))
    block("KEY_EDIT_MODE_ON", GroupsBpy.set(.editMode, true, editing: true, object: object))

    // The Vertex Group field on every modifier kind that has one: the edit a
    // row sends from a fresh row (as the mirror reports a new modifier) to
    // the group, then to Invert, then back to none.
    for kind in ModifierKind.allCases where kind.takesVertexGroup {
        let fresh = Modifier(kind: kind)
        var grouped = fresh
        grouped.vertexGroup = "Left"
        var inverted = grouped
        inverted.invertVertexGroup = true
        var cleared = inverted
        cleared.vertexGroup = ""
        print("### MOD_ADD \(kind.bpyType)\n\(Bpy.addModifier(kind.bpyType))\n#--")
        print("### MOD_GROUP \(kind.bpyType)\n\(Bpy.modifierEdit(from: fresh, to: grouped).joined(separator: "\n"))\n#--")
        print("### MOD_INVERT \(kind.bpyType)\n\(Bpy.modifierEdit(from: grouped, to: inverted).joined(separator: "\n"))\n#--")
        print("### MOD_CLEAR \(kind.bpyType)\n\(Bpy.modifierEdit(from: inverted, to: cleared).joined(separator: "\n"))\n#--")
        var stale = fresh
        stale.vertexGroup = "Gone"
        print("### MOD_STALE \(kind.bpyType)\n\(Bpy.modifierEdit(from: fresh, to: stale).joined(separator: "\n"))\n#--")
    }
    // A kind without one sends nothing for the field, whatever is set on it.
    var subsurf = Modifier(kind: .subdivision)
    subsurf.vertexGroup = "Left"
    print("### MOD_SUBSURF_GROUP\n\(Bpy.modifierEdit(from: Modifier(kind: .subdivision), to: subsurf).joined(separator: "\n"))\n#--")
    exit(0)
}

// MARK: replay

guard args.count == 3, args[1] == "replay",
      let data = FileManager.default.contents(atPath: args[2]),
      let cases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("usage: dump [replay <json>]\n".utf8))
    exit(2)
}
print("== the Swift reads what Blender's record says ==")
for c in cases {
    let label = c["label"] as? String ?? "?"
    let record = c["record"] as? String ?? ""
    if let kind = c["modifier"] as? String {
        // A modifier record: the row's Vertex Group and Invert.
        let stack = Modifier.stack(from: record)
        guard let m = stack.first(where: { $0.blenderType == kind }) else {
            check("\(label): a row for \(kind)", false, record); continue
        }
        let want = c["vertex_group"] as? String ?? ""
        let invert = c["invert"] as? Bool ?? false
        check("\(label): the row shows group '\(want)', invert \(invert)",
              m.vertexGroup == want && m.invertVertexGroup == invert,
              "got '\(m.vertexGroup)' \(m.invertVertexGroup) from \(record)")
        continue
    }
    guard let groups = MeshGroups.parse(record) else { check("\(label): parses", false, record); continue }
    let names = c["groups"] as? [String] ?? []
    let counts = c["counts"] as? [Int?] ?? []
    let locks = c["locks"] as? [Bool] ?? []
    let keys = c["keys"] as? [[String: Any]] ?? []
    var ok = groups.groups.map(\.name) == names
        && groups.activeGroup == (c["active_group"] as? Int ?? -99)
        && abs(groups.weight - Float(c["weight"] as? Double ?? -1)) < 1e-5
        && groups.groups.map(\.locked) == locks
        && groups.activeKey == (c["active_key"] as? Int ?? -99)
        && groups.useRelative == (c["use_relative"] as? Bool ?? !groups.useRelative)
        && groups.showOnlyShapeKey == (c["show_only"] as? Bool ?? !groups.showOnlyShapeKey)
        && groups.shapeKeyEditMode == (c["key_edit_mode"] as? Bool ?? !groups.shapeKeyEditMode)
        && groups.reference == (c["reference"] as? String ?? "?")
        && groups.keys.count == keys.count
    if !counts.isEmpty { ok = ok && groups.groups.map(\.count) == counts }
    for (shown, held) in zip(groups.keys, keys) {
        ok = ok && shown.name == held["name"] as? String
            && abs(shown.value - Float(held["value"] as? Double ?? -99)) < 1e-5
            && abs(shown.sliderMin - Float(held["min"] as? Double ?? -99)) < 1e-5
            && abs(shown.sliderMax - Float(held["max"] as? Double ?? -99)) < 1e-5
            && shown.relativeKey == held["relative"] as? String
            && shown.mute == held["mute"] as? Bool
            && shown.locked == held["lock"] as? Bool
            && shown.vertexGroup == held["vertex_group"] as? String
    }
    check("\(label): the panels show what Blender holds", ok,
          "parsed \(groups) from \(record) against \(c)")
}
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
