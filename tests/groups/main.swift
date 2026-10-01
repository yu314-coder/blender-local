import Foundation

// Vertex groups and shape keys, the Swift half: the record the mirror hands
// over (`MeshGroups`, `carryGroups`, the merge), what each control of the Data
// tab's two panels sends (`GroupsBpy`), and the modifiers' Vertex Group field
// (`Modifier.read`, `Bpy.modifierVertexGroup`, `Bpy.modifierEdit`). What
// Blender does with all of it is run-groups-blender-check.sh's.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

// What `_blenderkit_groups.record` writes for a mesh with two groups, the
// second called `a;b|c=d%e` (escaped, as `_value` escapes it), and three keys.
let record = "kind=head;active_group=1.0;weight=0.25;active_key=2.0;use_relative=1;reference=Basis;"
    + "show_only=0;key_edit_mode=1"
    + "|kind=group;name=Left;lock=0;count=9.0"
    + "|kind=group;name=a%3Bb%7Cc%3Dd%25e;lock=1;count=0.0"
    + "|kind=key;name=Basis;value=1.0;min=0.0;max=1.0;relative=Basis;mute=0;lock=0;vertex_group="
    + "|kind=key;name=Key 1;value=0.5;min=-0.5;max=2.0;relative=Basis;mute=0;lock=0;vertex_group=Left"
    + "|kind=key;name=Smile;value=1.0;min=0.0;max=1.0;relative=Key 1;mute=1;lock=1;vertex_group="

print("== the record ==")
let parsed = MeshGroups.parse(record)
check("parses", parsed != nil)
if let g = parsed {
    check("two groups, their names unescaped",
          g.groups.map(\.name) == ["Left", "a;b|c=d%e"], "\(g.groups.map(\.name))")
    check("their locks and counts", g.groups.map(\.locked) == [false, true] && g.groups.map(\.count) == [9, 0])
    check("the active group, by index, and its name", g.activeGroup == 1 && g.activeGroupName == "a;b|c=d%e")
    check("the Weight field", g.weight == 0.25)
    check("three keys", g.keys.map(\.name) == ["Basis", "Key 1", "Smile"])
    check("a key's value and range", g.keys[1].value == 0.5 && g.keys[1].sliderMin == -0.5
          && g.keys[1].sliderMax == 2)
    check("relative key, mute, lock and vertex group",
          g.keys[2].relativeKey == "Key 1" && g.keys[2].mute && g.keys[2].locked
          && g.keys[1].vertexGroup == "Left" && g.keys[0].vertexGroup == "")
    check("the active key", g.activeKey == 2 && g.activeKeyBlock?.name == "Smile")
    check("the switches", g.useRelative && !g.showOnlyShapeKey && g.shapeKeyEditMode)
    check("Basis is the reference, and has no value of its own while relative",
          g.isReference(g.keys[0]) && !g.isReference(g.keys[1]))
    var absolute = g
    absolute.useRelative = false
    check("in an absolute set no key is the reference", !absolute.isReference(absolute.keys[0]))
    check("counted", g.counted)
}
check("a record with no head is nothing", MeshGroups.parse("kind=group;name=Left;lock=0") == nil)
check("an empty mesh's record is a head alone",
      MeshGroups.parse("kind=head;active_group=-1.0;weight=1.0;active_key=-1.0;use_relative=1;reference=;"
                       + "show_only=0;key_edit_mode=0").map { $0.groups.isEmpty && $0.keys.isEmpty
                                                               && $0.activeGroupName == nil
                                                               && $0.activeKeyBlock == nil } == true)
let uncounted = MeshGroups.parse("kind=head;active_group=0.0;weight=1.0;active_key=-1.0;counted=0|kind=group;name=Left;lock=0")
check("past the count limit: no count, and the head says why",
      uncounted?.groups.first?.count == nil && uncounted?.counted == false)
check("an active index past the list names nothing",
      MeshGroups.parse("kind=head;active_group=4.0;weight=1.0;active_key=7.0")?.activeGroupName == nil)
check("a value that is not finite is not taken",
      MeshGroups.parse("kind=head;weight=nan|kind=key;name=K;value=inf")
        .map { $0.weight == 1 && $0.keys[0].value == 0 } == true)

print("== a key's value is clamped as Blender clamps it ==")
let key = MeshGroups.Key(name: "K", value: 0.3, sliderMin: 0, sliderMax: 1)
check("inside the range, itself", key.clamped(0.4) == 0.4)
check("past the maximum, the maximum", key.clamped(1.5) == 1)
check("below the minimum, the minimum", key.clamped(-2) == 0)
check("not a number, the value held", key.clamped(.nan) == 0.3)
let inverted = MeshGroups.Key(name: "K", value: 0, sliderMin: 0.5, sliderMax: 0.2)
check("a range whose maximum is under its minimum clamps to the minimum", inverted.clamped(3) == 0.5)

print("== counts kept across a frame change ==")
var old = parsed!
var frame = MeshGroups.parse(record.replacingOccurrences(of: ";count=9.0", with: "")
                             .replacingOccurrences(of: ";count=0.0", with: ""))!
check("the frame's record has none", frame.groups.allSatisfy { $0.count == nil })
frame.keys[1].value = 0.75
let kept = frame.keepingCounts(from: old)
check("the counts a group of the same name had stay, the new value comes",
      kept.groups.map(\.count) == [9, 0] && kept.keys[1].value == 0.75)
old.groups[0].name = "Renamed"
check("a group not there before has none", frame.keepingCounts(from: old).groups.map(\.count) == [nil, 0])
check("nothing before, nothing kept", frame.keepingCounts(from: nil).groups.map(\.count) == [nil, nil])

print("== carried onto the object ==")
let pushed = BKObject(name: "Grid", kind: .plane)
let other = BKObject(name: "Other", kind: .cube)
check("during a pass, onto the object the pass pushed",
      SceneMirror.carryGroups(record: record, named: "Grid", pass: [other, pushed], screen: [])
      && pushed.meshGroups?.groups.count == 2 && other.meshGroups == nil)
check("a name the pass did not push is refused",
      !SceneMirror.carryGroups(record: record, named: "Nope", pass: [pushed], screen: []))
check("a record with no head is refused, and leaves the object as it was",
      !SceneMirror.carryGroups(record: "garbage", named: "Grid", pass: [pushed], screen: [])
      && pushed.meshGroups?.groups.count == 2)
let tapped = record.replacingOccurrences(of: ";count=9.0", with: "")
check("outside a pass, onto the object on screen, keeping its counts",
      SceneMirror.carryGroups(record: tapped, named: "Grid", pass: nil, screen: [other, pushed])
      && pushed.meshGroups?.groups.first?.count == 9)
check("but during a pass a record without counts has none",
      SceneMirror.carryGroups(record: tapped, named: "Grid", pass: [pushed], screen: [])
      && pushed.meshGroups?.groups.first?.count == nil)

print("== the merge ==")
let scene = BKScene()
let first = BKObject(name: "Grid", kind: .plane)
first.meshGroups = MeshGroups.parse(record)
SceneMirror.merge([first], into: scene, unchanged: [], selection: [], active: nil)
let second = BKObject(name: "Grid", kind: .plane)
second.meshGroups = MeshGroups.parse("kind=head;active_group=0.0;weight=1.0;active_key=-1.0|kind=group;name=Only;lock=0")
SceneMirror.merge([second], into: scene, unchanged: [], selection: [], active: nil)
check("a pass's groups replace what the object on screen showed",
      scene.objects.first?.meshGroups?.groups.map(\.name) == ["Only"] && scene.objects.first !== second)
let third = BKObject(name: "Grid", kind: .plane)
SceneMirror.merge([third], into: scene, unchanged: [], selection: [], active: nil)
check("and a pass with none (a script made it something else) clears them",
      scene.objects.first?.meshGroups == nil)

print("== what the controls send ==")
let odd = "a;b|c=d%e \"quoted\""
let assign = GroupsBpy.assign(odd, weight: 3, object: "Grid")
check("Assign: Blender's operator in the Info log, its undo name",
      assign.call == "bpy.ops.object.vertex_group_assign()" && assign.undo == "Assign to Vertex Group")
check("runs the module function, the group named as Python, the weight clamped to 1",
      assign.executed.hasPrefix("import _blenderkit_groups as _bk_grp\n")
      && assign.executed.contains("_bk_grp.assign(\"Grid\", \(Bpy.quote(odd)), 1)"), assign.executed)
check("never a bare operator, so the mode guard leaves Edit Mode alone",
      BpyModeGuard.requiredMode(for: assign.executed) == nil)
check("a weight below 0 is sent as 0", GroupsBpy.assign("L", weight: -1, object: "G").executed.hasSuffix(", 0)"))
check("the Weight field: a tool setting, clamped",
      GroupsBpy.setWeight(1.7) == "bpy.context.scene.tool_settings.vertex_group_weight = 1")
check("Select and Deselect name their operators",
      GroupsBpy.selectGroup("L", select: true, object: "G").call == "bpy.ops.object.vertex_group_select()"
      && GroupsBpy.selectGroup("L", select: false, object: "G").undo == "Deselect Vertex Group")
check("Remove takes all=False; Delete All all=True",
      GroupsBpy.removeGroup("L", object: "G").call.contains("all=False")
      && GroupsBpy.removeAllGroups(object: "G").call.contains("all=True"))
check("New Shape from Mix is from_mix=True, and named so",
      GroupsBpy.addKey(fromMix: true, object: "G").call == "bpy.ops.object.shape_key_add(from_mix=True)"
      && GroupsBpy.addKey(fromMix: true, object: "G").undo == "New Shape from Mix")
check("Apply All is apply_mix=True",
      GroupsBpy.removeAllKeys(apply: true, object: "G").call.contains("apply_mix=True"))
// In Edit Mode no key setting and no switch pushes a step (measured: the
// edit-mesh undo step holds none of them); in Object Mode each does.
for setting in GroupsBpy.KeySetting.allCases {
    let inObject = GroupsBpy.setKey("K", setting, "1", editing: false, object: "G")
    let inEdit = GroupsBpy.setKey("K", setting, "1", editing: true, object: "G")
    check("\(setting.rawValue): a step named \(setting.label) in Object Mode, none in Edit Mode",
          inObject.undo == setting.label && inEdit.undo == nil)
}
for toggle in GroupsBpy.Switch.allCases {
    check("\(toggle.rawValue): a step in Object Mode, none in Edit Mode",
          GroupsBpy.set(toggle, true, editing: false, object: "G").undo == toggle.label
          && GroupsBpy.set(toggle, true, editing: true, object: "G").undo == nil)
}
check("the active key is taken back by an Edit Mode undo, so it has a step there too",
      GroupsBpy.setActiveKey("K", object: "G").undo == "Active Shape Key")
check("Relative is the Key's, the other two the object's",
      GroupsBpy.set(.useRelative, false, editing: false, object: "G").call.hasSuffix(".data.shape_keys.use_relative = False")
      && GroupsBpy.set(.showOnly, true, editing: false, object: "G").call.hasSuffix("].show_only_shape_key = True"))
check("a relative key is named in the log by its key",
      GroupsBpy.setKey("Key 2", .relativeKey, Bpy.quote("Key 1"), editing: false, object: "G").call
        .hasSuffix(".relative_key = bpy.data.objects[\"G\"].data.shape_keys.key_blocks[\"Key 1\"]"))
check("a value is sent at six significant places",
      GroupsBpy.setKeyValue("K", 0.123456789, editing: false, object: "G").executed.hasSuffix("\"value\", 0.123457)"))

print("== the modifiers' Vertex Group field ==")
let kinds = ModifierKind.allCases.filter(\.takesVertexGroup)
check("thirteen kinds take one", kinds.count == 13, "\(kinds)")
check("Bevel does not: its group is read only under a limit the row does not offer",
      !ModifierKind.bevel.takesVertexGroup && !ModifierKind.subdivision.takesVertexGroup)
var displace = Modifier(kind: .displace)
displace.read(Modifier.fields("vertex_group=a%3Bb;invert_vertex_group=1"))
check("the record's group and Invert are read, unescaped",
      displace.vertexGroup == "a;b" && displace.invertVertexGroup)
var subsurf = Modifier(kind: .subdivision)
subsurf.read(Modifier.fields("vertex_group=Left;invert_vertex_group=1"))
check("a kind without the field reads neither", subsurf.vertexGroup == "" && !subsurf.invertVertexGroup)
var grouped = Modifier(kind: .displace)
grouped.vertexGroup = "Left"
check("picking a group sends that line alone",
      Bpy.modifierEdit(from: Modifier(kind: .displace), to: grouped)
        == ["bpy.context.object.modifiers[\"Displace\"].vertex_group = \"Left\""])
var inverted2 = grouped
inverted2.invertVertexGroup = true
check("Invert sends that line alone",
      Bpy.modifierEdit(from: grouped, to: inverted2)
        == ["bpy.context.object.modifiers[\"Displace\"].invert_vertex_group = True"])
var stronger = grouped
stronger.thickness = 0.3
check("another setting's edit sends no Vertex Group line",
      Bpy.modifierEdit(from: grouped, to: stronger) == ["bpy.context.object.modifiers[\"Displace\"].strength = 0.3000"])
check("the field is not in the settings the simulator's stand-in is checked against",
      !Bpy.modifierSettings(grouped).contains { $0.contains("vertex_group") })
var subsurfGrouped = Modifier(kind: .subdivision)
subsurfGrouped.vertexGroup = "Left"
check("a kind without the field sends nothing for it",
      Bpy.modifierEdit(from: Modifier(kind: .subdivision), to: subsurfGrouped).isEmpty)
let stack = Modifier.stack(from: "kind=SOLIDIFY;name=Solidify;thickness=0.1;vertex_group=Left;invert_vertex_group=0")
check("a stack from the record carries it", stack.first?.vertexGroup == "Left" && stack.first?.invertVertexGroup == false)

print("== saved and opened ==")
let encoded = try! JSONEncoder().encode(grouped)
let decoded = try! JSONDecoder().decode(Modifier.self, from: encoded)
check("a saved row keeps its group", decoded.vertexGroup == "Left")
var json = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
json.removeValue(forKey: "vertexGroup")
json.removeValue(forKey: "invertVertexGroup")
let older = try? JSONDecoder().decode(Modifier.self, from: JSONSerialization.data(withJSONObject: json))
check("a file from before the field opens, with no group", older?.vertexGroup == "" && older?.invertVertexGroup == false)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
