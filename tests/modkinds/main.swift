import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// The Swift half of round 4, group 8: Blender's whole Add Modifier menu by
// object type (`ModifierCatalog`), the eleven declared modifier rows (Curve,
// Wireframe, Skin, Hook, Armature, Surface Deform, Mesh Deform, Data Transfer,
// Normal Edit, Mask, Build) — the record read back, the settings each sends,
// the one line an edit sends, their buttons — a text object's settings and
// Body Text, and image empties: their record, Blender's rules for when the
// picture is drawn, and the passes. What Blender makes of the Python is
// scripts/run-modkinds-blender-check.sh; the catalog is held to Blender's own
// menus there. Each group of checks has a control that has to fail.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func equal<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    check(label, got == want, "\n        got  \(got)\n        want \(want)")
}

// --------------------------------------------------------------------------
print("Add Modifier, by object type")

let mesh = ModifierCatalog.menu(for: "MESH")
equal("a mesh's categories are Blender's", mesh.map(\.name), ["Edit", "Generate", "Deform", "Normals", "Physics"])
// Counted from OBJECT_MT_modifier_add_* drawn on a cube in 5.2.1 (round 4's
// group 8 probe): Edit 8, Generate 21 with its three Essentials rows,
// Deform 16, Normals 2, Physics 9.
equal("each with Blender's number of rows", mesh.map { $0.rows.count }, [8, 21, 16, 2, 9])
let generate = mesh[1].rows
equal("Generate starts with the Essentials Array, then Array (Legacy)",
      Array(generate.prefix(2)).map(\.label), ["Array", "Array (Legacy)"])
check("the Essentials rows are assets", generate.filter(\.asset).map(\.type) == ["Array", "Curve to Tube", "Scatter on Surface"])
check("Array (Legacy) is the ARRAY modifier, the app's Array row",
      generate[1].type == "ARRAY" && generate[1].kind == .array)
check("every modifier row's label is its RNA enum name, but Array (Legacy)",
      mesh.flatMap(\.rows).filter { !$0.asset && $0.type != "ARRAY" }
          .allSatisfy { $0.label == ModifierCatalog.labels[$0.type] })
equal("Geometry Nodes after them on a mesh", ModifierCatalog.geometryNodes(on: "MESH")?.label, "Geometry Nodes")
check("none on a lattice or a surface",
      ModifierCatalog.geometryNodes(on: "LATTICE") == nil && ModifierCatalog.geometryNodes(on: "SURFACE") == nil)
let curve = ModifierCatalog.menu(for: "CURVE")
equal("a curve's: no Normals", curve.map(\.name), ["Edit", "Generate", "Deform", "Physics"])
check("its Edit has no Data Transfer and its Physics only Soft Body",
      !curve[0].rows.contains { $0.type == "DATA_TRANSFER" } && curve[3].rows.map(\.type) == ["SOFT_BODY"])
check("its Generate leaves out Boolean, Mask, Multires, Skin and Wireframe",
      Set(curve[1].rows.map(\.type)).isDisjoint(with: ["BOOLEAN", "MASK", "MULTIRES", "SKIN", "WIREFRAME"]))
equal("a text's menu is a curve's", ModifierCatalog.rows(for: "FONT"), ModifierCatalog.rows(for: "CURVE"))
let lattice = ModifierCatalog.menu(for: "LATTICE")
equal("a lattice's: Edit, Deform, Physics", lattice.map(\.name), ["Edit", "Deform", "Physics"])
equal("its Deform rows", lattice[1].rows.map(\.type),
      ["ARMATURE", "CAST", "CURVE", "HOOK", "LATTICE", "MESH_DEFORM", "SHRINKWRAP", "SIMPLE_DEFORM", "WARP", "WAVE"])
check("a camera gets nothing", ModifierCatalog.rows(for: "CAMERA").isEmpty)
check("an empty gets Geometry Nodes alone", ModifierCatalog.rows(for: "EMPTY").map(\.type) == ["NODES"])
check("control: a mesh's rows are not a curve's", ModifierCatalog.rows(for: "MESH") != ModifierCatalog.rows(for: "CURVE"))
check("every first-class kind but Geometry Nodes has a row on a mesh",
      ModifierKind.addable.allSatisfy { kind in ModifierCatalog.rows(for: "MESH").contains { $0.kind == kind } })
check("the eleven new kinds are among them",
      [ModifierKind.curve, .wireframe, .skin, .hook, .armature, .surfaceDeform, .meshDeform, .dataTransfer,
       .normalEdit, .mask, .build].allSatisfy { kind in mesh.flatMap(\.rows).contains { $0.kind == kind } })
check("the simulator adds neither Curve (its stand-in keeps its own) nor Geometry Nodes nor an asset",
      !ModifierCatalog.Row(type: "CURVE", label: "Curve").simulatorCanAdd
          && !ModifierCatalog.Row(type: "NODES", label: "Geometry Nodes").simulatorCanAdd
          && !generate[0].simulatorCanAdd && ModifierCatalog.Row(type: "SKIN", label: "Skin").simulatorCanAdd)

print("\nwhat a row sends")
let cube = MeshBuilder.cube(size: 2)
let skinRow = mesh.flatMap(\.rows).first { $0.type == "SKIN" }!
equal("Skin: priced, then added", Bpy.addModifierRow(skinRow, on: cube),
      ["__import__('_blenderkit_budget').price_add(\"SKIN\")", "bpy.ops.object.modifier_add(type='SKIN')"])
let warp = mesh.flatMap(\.rows).first { $0.type == "WARP" }!
equal("an unmodelled kind the same", Bpy.addModifierRow(warp, on: cube),
      ["__import__('_blenderkit_budget').price_add(\"WARP\")", "bpy.ops.object.modifier_add(type='WARP')"])
let remesh = mesh.flatMap(\.rows).first { $0.type == "REMESH" }!
let bigRemesh = Bpy.addModifierRow(remesh, on: MeshBuilder.cube(size: 100))
check("Remesh keeps its floor after the add", bigRemesh.count == 3 && bigRemesh[2].contains("voxel_size"),
      bigRemesh.joined(separator: " / "))
check("an Essentials row loads its node group", Bpy.addModifierRow(generate[0], on: cube)
      == ["import _blenderkit_modifiers\n_blenderkit_modifiers.add_asset(\"Array\")"])

// --------------------------------------------------------------------------
print("\nthe declared rows")

/// What `_modifier_entry` sends for each kind on Blender 5.2.1's defaults
/// (round 4 group 8's probe), with a picked object where one is.
let records: [ModifierKind: String] = [
    .curve: "kind=CURVE;name=Curve;show_viewport=1;show_render=1;deform_axis=POS_X;vertex_group=;invert_vertex_group=0;object=BézierCurve",
    .wireframe: "kind=WIREFRAME;name=Wireframe;show_viewport=1;show_render=1;thickness=0.019999999552965164;offset=0.0;use_boundary=0;use_replace=1;use_even_offset=1;use_relative_offset=0;use_crease=0;crease_weight=1.0;material_offset=0.0;thickness_vertex_group=0.0;vertex_group=;invert_vertex_group=0",
    .skin: "kind=SKIN;name=Skin;show_viewport=1;show_render=1;branch_smoothing=0.0;use_x_symmetry=1;use_y_symmetry=0;use_z_symmetry=0;use_smooth_shade=0",
    .hook: "kind=HOOK;name=Hook;show_viewport=1;show_render=1;strength=1.0;falloff_type=SMOOTH;falloff_radius=0.0;use_falloff_uniform=0;vertex_group=;invert_vertex_group=0;object=Empty;vertex_count=4.0",
    .armature: "kind=ARMATURE;name=Armature;show_viewport=1;show_render=1;use_deform_preserve_volume=0;use_multi_modifier=0;use_vertex_groups=1;use_bone_envelopes=0;vertex_group=;invert_vertex_group=0;object=",
    .surfaceDeform: "kind=SURFACE_DEFORM;name=SurfaceDeform;show_viewport=1;show_render=1;falloff=4.0;strength=1.0;use_sparse_bind=0;is_bound=1;vertex_group=;invert_vertex_group=0;target=Plane",
    .meshDeform: "kind=MESH_DEFORM;name=MeshDeform;show_viewport=1;show_render=1;precision=5.0;use_dynamic_bind=0;is_bound=0;vertex_group=;invert_vertex_group=0;object=Cage",
    .dataTransfer: "kind=DATA_TRANSFER;name=DataTransfer;show_viewport=1;show_render=1;use_object_transform=1;mix_mode=REPLACE;mix_factor=1.0;use_vert_data=1;data_types_verts=VGROUP_WEIGHTS;vert_mapping=NEAREST;use_edge_data=0;data_types_edges=;edge_mapping=NEAREST;use_loop_data=1;data_types_loops=CUSTOM_NORMAL,UV;loop_mapping=NEAREST_POLYNOR;use_poly_data=0;data_types_polys=;poly_mapping=NEAREST;vertex_group=;invert_vertex_group=0;object=Source",
    .normalEdit: "kind=NORMAL_EDIT;name=NormalEdit;show_viewport=1;show_render=1;mode=RADIAL;use_direction_parallel=0;mix_mode=COPY;mix_factor=1.0;mix_limit=3.1415927410125732;no_polynors_fix=0;offset=0.0,0.0,0.0;vertex_group=;invert_vertex_group=0;target=",
    .mask: "kind=MASK;name=Mask;show_viewport=1;show_render=1;mode=VERTEX_GROUP;use_smooth=0;threshold=0.0;vertex_group=Top;invert_vertex_group=0;armature=",
    .build: "kind=BUILD;name=Build;show_viewport=1;show_render=1;frame_start=1.0;frame_duration=100.0;use_reverse=0;use_random_order=0;seed=1.0",
]
for kind in [ModifierKind.curve, .wireframe, .skin, .hook, .armature, .surfaceDeform, .meshDeform,
             .dataTransfer, .normalEdit, .mask, .build] {
    guard let m = Modifier.stack(from: records[kind]!).first else { check("\(kind) parses", false); continue }
    check("\(kind.label): its own kind, declared", m.kind == kind && kind.isDeclared, "\(m.kind)")
    let writable = kind.fields.filter { !$0.isReadOnly }
    check("\(kind.label): every setting Blender sent is held", writable.allSatisfy { m.values[$0.key] != nil },
          writable.filter { m.values[$0.key] == nil }.map(\.key).joined(separator: ","))
    let lines = Bpy.declaredSettings(m)
    check("\(kind.label): one line per setting, the budget's price aside",
          lines.filter { !$0.contains("check_setting") }.count == writable.count,
          "\(lines.count) for \(writable.count)")
    check("\(kind.label): the other object last", kind.fields.firstIndex(where: \.isObject).map { _ in
        lines.last?.contains(".object = ") == true || lines.last?.contains(".target = ") == true
            || lines.last?.contains(".armature = ") == true } ?? true, lines.last ?? "")
    // Each setting changed alone sends exactly its own line.
    for field in writable {
        var changed = m
        switch field.kind {
        case .number: changed.values[field.key] = "0.375"
        case .integer(let r): changed.values[field.key] = "\(r.lowerBound == Int(m.number(field.key) ?? 0) ? r.lowerBound + 1 : r.lowerBound)"
        case .toggle: changed.values[field.key] = m.values[field.key] == "1" ? "0" : "1"
        case .choice(let c): changed.values[field.key] = c.first { $0.identifier != m.values[field.key] }!.identifier
        case .flags(let c): changed.values[field.key] = m.values[field.key] == c[0].identifier ? "" : c[0].identifier
        case .vector3: changed.values[field.key] = "0.5,-0.25,1.0"
        case .object: changed.values[field.key] = m.values[field.key] == "Other" ? "" : "Other"
        case .readOnly: continue
        }
        let all = Bpy.modifierEdit(from: m, to: changed)
        let sent = all.filter { !$0.contains("_blenderkit_budget") }
        check("\(kind.label) \(field.label): one line, behind the budget's price for it",
              sent.count == 1 && sent[0].contains(".\(field.key) = ") && all.count == 2
                && all[0].hasPrefix("__import__('_blenderkit_budget').price_modifier(") && all[0].contains("\"\(field.key)\": "),
              all.joined(separator: " / "))
    }
}

let wire = Modifier.stack(from: records[.wireframe]!)[0]
equal("Wireframe's Thickness goes at Blender's precision", Bpy.declaredSettings(wire)[0],
      "bpy.context.object.modifiers[\"Wireframe\"].thickness = 0.02")
var keep = wire
keep.values["use_replace"] = "0"
equal("Replace Original off rides behind the budget's price", Bpy.modifierEdit(from: wire, to: keep),
      ["__import__('_blenderkit_budget').price_modifier(\"Wireframe\", {\"use_replace\": False})",
       "bpy.context.object.modifiers[\"Wireframe\"].use_replace = False"])
let transfer = Modifier.stack(from: records[.dataTransfer]!)[0]
check("an enum set as a Python set, sorted", Bpy.declaredSettings(transfer)
      .contains("bpy.context.object.modifiers[\"DataTransfer\"].data_types_loops = {'CUSTOM_NORMAL', 'UV'}"))
check("an empty one as set()", Bpy.declaredSettings(transfer)
      .contains("bpy.context.object.modifiers[\"DataTransfer\"].data_types_edges = set()"))
let normal = Modifier.stack(from: records[.normalEdit]!)[0]
check("a vector as a tuple", Bpy.declaredSettings(normal)
      .contains("bpy.context.object.modifiers[\"NormalEdit\"].offset = (0, 0, 0)"))
check("no object as None", Bpy.declaredSettings(normal)
      .contains("bpy.context.object.modifiers[\"NormalEdit\"].target = None"))
let curveMod = Modifier.stack(from: records[.curve]!)[0]
check("an object by its name, and the row knows it", curveMod.targetName == "BézierCurve"
      && Bpy.declaredSettings(curveMod).last == "bpy.context.object.modifiers[\"Curve\"].object = bpy.data.objects[\"BézierCurve\"]")
let hook = Modifier.stack(from: records[.hook]!)[0]
check("a Hook's vertex count is shown and never sent", hook.number("vertex_count") == 4
      && !Bpy.declaredSettings(hook).contains { $0.contains("vertex_count") })
let deform = Modifier.stack(from: records[.surfaceDeform]!)[0]
check("Bound is shown and never sent", deform.flag("is_bound") == true
      && !Bpy.declaredSettings(deform).contains { $0.contains("is_bound") })
check("Mask's armature is its other object", Modifier.stack(from: records[.mask]!)[0].kind.fields.first(where: \.isObject)?.key == "armature")
check("Mask's vertex group is read", Modifier.stack(from: records[.mask]!)[0].vertexGroup == "Top")
check("control: a setting Blender did not send is not written",
      !Bpy.declaredSettings(Modifier.stack(from: "kind=WIREFRAME;name=Wireframe;thickness=0.1")[0])
          .contains { $0.contains("use_replace") })
check("control: an enum value Blender does not have is not written",
      Bpy.declaredSettings(Modifier.stack(from: "kind=CURVE;name=Curve;deform_axis=SIDEWAYS;object=")[0])
          == ["bpy.context.object.modifiers[\"Curve\"].object = None"])
check("Wireframe's offset is its own, not Shrinkwrap's thickness", wire.thickness == Modifier(kind: .wireframe).thickness
      || wire.values["offset"] == "0.0")

print("\nthe switches, the buttons, the Vertex Group field")
var shown = Modifier.stack(from: "kind=SKIN;name=Skin;show_viewport=0;show_render=1")[0]
var on = shown
on.showInViewport = true
equal("showing a modifier is priced first", Bpy.modifierEdit(from: shown, to: on),
      ["__import__('_blenderkit_budget').price_modifier(\"Skin\", {\"show_viewport\": True})",
       "bpy.context.object.modifiers[\"Skin\"].show_viewport = True"])
equal("hiding one is priced as well (and passes: the budget counts it hidden)", Bpy.modifierEdit(from: on, to: shown),
      ["__import__('_blenderkit_budget').price_modifier(\"Skin\", {\"show_viewport\": False})",
       "bpy.context.object.modifiers[\"Skin\"].show_viewport = False"])
shown.showInViewport = true
for op in ModifierOperation.allCases {
    let target = Modifier(kind: op.kind, name: "M")
    let command = ModifierRowAction.operation(op).command(for: target, in: [target])
    check("\(op.label()) (\(op.kind.label)) runs through _blenderkit_modifiers as \"\(op.undo)\"",
          command?.lines == ["import _blenderkit_modifiers\n_blenderkit_modifiers.run(\"\(op.rawValue)\", \"M\")"]
              && command?.undo == op.undo)
    let other = Modifier(kind: op.kind == .skin ? .hook : .skin, name: "M")
    check("control: not on another kind", ModifierRowAction.operation(op).command(for: other, in: [other]) == nil)
    check("the hook names it", ModifierRowAction(hookName: op.rawValue) == .operation(op))
}
check("Bind reads Unbind while bound", ModifierOperation.bindSurface.label(bound: true) == "Unbind"
      && ModifierOperation.bindMesh.label() == "Bind")
check("the Hook's four and the Skin's marks are Edit Mode's",
      ModifierOperation.allCases.filter(\.editModeOnly) == [.hookReset, .hookRecenter, .hookSelect, .hookAssign,
                                                             .skinRoot, .skinLooseMark, .skinLooseClear, .skinEqualize])
for kind in [ModifierKind.curve, .hook, .armature, .surfaceDeform, .meshDeform, .dataTransfer] {
    var m = Modifier(kind: kind)
    check("\(kind.label) with nothing picked is disabled, as Blender's isDisabled", m.isDisabled)
    m.targetName = "X"
    check("and not with something", !m.isDisabled)
}
check("Normal Edit and Mask are not", !Modifier(kind: .normalEdit).isDisabled && !Modifier(kind: .mask).isDisabled)
check("nine new kinds take a vertex group",
      [ModifierKind.curve, .wireframe, .hook, .armature, .surfaceDeform, .meshDeform, .dataTransfer, .normalEdit,
       .mask].allSatisfy(\.takesVertexGroup) && !ModifierKind.skin.takesVertexGroup && !ModifierKind.build.takesVertexGroup)
check("the pure deforms among them are Blender's OnlyDeform",
      [ModifierKind.curve, .hook, .armature, .surfaceDeform, .meshDeform].allSatisfy(\.onlyDeforms)
          && ![ModifierKind.wireframe, .skin, .mask, .build, .dataTransfer, .normalEdit].contains(where: \.onlyDeforms))
check("Blender's names for a new one", [ModifierKind.surfaceDeform, .meshDeform, .dataTransfer, .normalEdit]
      .map(\.displayName) == ["SurfaceDeform", "MeshDeform", "DataTransfer", "NormalEdit"])

print("\nthe rows' prices")
var screw = Modifier(kind: .screw, name: "Screw")
screw.count = 16
var steep = screw
steep.count = 512
equal("the Screw row's Steps rides behind the budget's price, as Subdivision's levels do",
      Bpy.modifierEdit(from: screw, to: steep),
      ["__import__('_blenderkit_budget').price_modifier(\"Screw\", {\"steps\": 512, \"render_steps\": 512})",
       "bpy.context.object.modifiers[\"Screw\"].steps = 512",
       "bpy.context.object.modifiers[\"Screw\"].render_steps = 512"])
var turnedScrew = screw
turnedScrew.angle = 1
check("and an Angle change too: no row chooses which of its settings are priced",
      Bpy.modifierEdit(from: screw, to: turnedScrew).first?.contains("price_modifier(\"Screw\", {\"angle\": ") == true)
let move = Bpy.moveModifier("Subdivision", up: true)
check("a move is priced before Blender makes it: bpy.ops evaluates a finished move at once",
      move.contains("__import__('_blenderkit_budget').check_move(\"Subdivision\", True)")
          && move.range(of: "check_move")!.lowerBound < move.range(of: "modifier_move_up")!.lowerBound, move)
check("and down is priced as down", Bpy.moveModifier("Skin", up: false).contains("check_move(\"Skin\", False)"))

print("\nthe simulator's stand-in")
let soup = MeshBuilder.cube(size: 2)
func unchanged(_ a: MeshData, _ b: MeshData) -> Bool {
    a.indices == b.indices && a.vertices.count == b.vertices.count
        && zip(a.vertices, b.vertices).allSatisfy { $0.position == $1.position }
}
for kind in ModifierKind.allCases where kind.standInLeavesMesh {
    var m = Modifier(kind: kind)
    m.targetName = "X"
    check("\(kind.label): the stand-in draws the mesh as it was, and its row says so",
          unchanged(ModifierStack.apply([m], to: soup), soup))
}
check("control: Subdivision Surface changes it", !unchanged(ModifierStack.apply([Modifier(kind: .subdivision)], to: soup), soup))
check("the ten the stand-in adds among them (Curve it does not)",
      ModifierCatalog.rows(for: "MESH").filter { $0.kind?.standInLeavesMesh == true && $0.simulatorCanAdd }.count == 10)

print("\nEdit Mode's refusal names what rebuilds")
let hooked = BKObject(name: "Cube", kind: .cube)
hooked.setEvaluatedMesh(MeshBuilder.uvSphere(radius: 1, segments: 8, rings: 4))
hooked.modifiers = [Modifier(kind: .hook, name: "Hook"), Modifier(kind: .subdivision, name: "Subdivision"),
                    Modifier(kind: .meshDeform, name: "MeshDeform")]
let said = hooked.editRegionRefusal() ?? ""
check("a Hook and a Mesh Deform beside a Subdivision: only the Subdivision rebuilds",
      said.contains("its modifier Subdivision rebuilds") && !said.contains("Hook") && !said.contains("MeshDeform"), said)

print("\nsaved and reopened")
do {
    let m = Modifier.stack(from: records[.dataTransfer]!)[0]
    let data = try JSONEncoder().encode([m])
    let back = try JSONDecoder().decode([Modifier].self, from: data)
    check("a declared row's settings survive a save", back[0].values == m.values && back[0].kind == .dataTransfer)
    let old = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\"values\":", with: "\"oldValues\":")
    let reopened = try JSONDecoder().decode([Modifier].self, from: Data(old.utf8))
    check("and a file from before them opens with none", reopened[0].values.isEmpty)
} catch {
    check("Codable", false, "\(error)")
}

// --------------------------------------------------------------------------
print("\na text object")

let textRecord = "size=1.0;shear=0.0;extrude=0.1;offset=0.0;bevel_depth=0.02;bevel_resolution=4.0;resolution_u=12.0;"
    + "fill_mode=BOTH;align_x=CENTER;align_y=TOP_BASELINE;space_character=1.5;space_word=1.0;space_line=1.0;"
    + "offset_x=0.0;offset_y=0.0;chars=20.0;font=Bfont%3B Regular;body=Hello%3B%3D%7C%25%0AWorld é 中"
guard case .text(let text)? = ObjectDataSettings.parse(type: "FONT", record: textRecord) else {
    check("a text record parses", false); exit(1)
}
equal("its body, the separators unescaped", text.body, "Hello;=|%\nWorld é 中")
equal("its font", text.values["font"], "Bfont; Regular")
check("its settings", text.number("extrude") == 0.1 && text.values["align_x"] == "CENTER" && text.number("chars") == 20)
check("control: a record without the body key is no text",
      ObjectDataSettings.parse(type: "FONT", record: "size=1.0") == nil)
// What `_blenderkit_text.record` sends once the body is cleared: `body=` last.
// Round 4's review found it parsed as no text at all, the Data tab's text
// panels gone and the Body Text sheet saying the text had not arrived.
let cleared = textRecord.components(separatedBy: ";body=")[0] + ";body="
if case .text(let empty)? = ObjectDataSettings.parse(type: "FONT", record: cleared) {
    check("a cleared body is an empty body, its settings kept", empty.body == "" && empty.number("extrude") == 0.1)
} else {
    check("a cleared body is an empty body, its settings kept", false, "no text parsed from \(cleared)")
}
check("and an empty font name is an empty name", {
    if case .text(let t)? = ObjectDataSettings.parse(type: "FONT", record: "size=1.0;font=;body=x") {
        return t.values["font"] == "" && t.body == "x"
    }
    return false
}())
// Blender's hard ranges, measured in 5.2.1 (`TextCurve.bl_rna`).
check("Offset X and Y, Extrude, Offset and Depth take what Blender takes, past their old ±50 and 1e6",
      TextSettings.ranges["offset_x"]!.contains(1000) && TextSettings.ranges["offset_y"]!.contains(-1000)
          && TextSettings.ranges["extrude"]!.contains(1e7) && TextSettings.ranges["bevel_depth"]!.contains(-1e7)
          && TextSettings.ranges["offset"]!.contains(-1e7))
check("control: Extrude is never negative, and Shear stays within ±1, as in Blender",
      !TextSettings.ranges["extrude"]!.contains(-0.1) && !TextSettings.ranges["shear"]!.contains(1.5))
check("the text rows send no drawn count: the price is Blender's own layout",
      !TextBpy.set("resolution_u", to: "64", object: "Text").contains("drawn")
          && !TextBpy.setBody("x", object: "Text").contains("drawn"))
check("control: a curve's record is not a text's", ObjectDataSettings.parse(type: "CURVE", record: textRecord) == nil)
equal("the Body Text field writes data.body through the price",
      TextBpy.setBody("Logo \"one\"\nline", object: "Text"),
      "import _blenderkit_text\n_blenderkit_text.set_body(\"Text\", \"Logo \\\"one\\\"\\nline\")")
equal("a row", TextBpy.set("bevel_resolution", to: TextBpy.python("bevel_resolution", 6.4), object: "Text"),
      "import _blenderkit_text\n_blenderkit_text.set_setting(\"Text\", \"bevel_resolution\", 6)")
equal("a float row", TextBpy.python("size", 2.5), "2.5")
check("every row's key has a Blender label and a panel", TextSettings.rows.count == 15
      && Set(TextSettings.rows.map(\.panel)) == ["Shape", "Geometry", "Bevel", "Transform", "Alignment", "Spacing"])
check("Middle is align_y's CENTER, Blender's word", TextSettings.choices["align_y"]?.contains { $0.id == "CENTER" && $0.label == "Middle" } == true)

// --------------------------------------------------------------------------
print("\nimage empties")

let imageRecord = "empty_display_type=IMAGE;empty_display_size=5.0;instances_collection=0;empty_image_offset=-0.5,-0.5;"
    + "image_aspect=1.0,0.5;image_name=ref%3D1.png;image_file=/tmp/a%3Bb/ref.png;image_has_data=1;"
    + "image_premultiplied=0;empty_image_depth=DEFAULT;empty_image_side=FRONT;show_empty_image_orthographic=1;"
    + "show_empty_image_perspective=0;show_empty_image_only_axis_aligned=0;use_empty_image_alpha=1;"
    + "color=1.0,0.5,0.25,0.75;show_in_front=0"
guard case .empty(let empty)? = ObjectDisplay(type: "EMPTY", dataName: "", record: imageRecord) else {
    check("an image empty's record parses", false); exit(1)
}
check("its picture and its file, unescaped", empty.imageName == "ref=1.png" && empty.imageFile == "/tmp/a;b/ref.png"
      && empty.imageHasData)
check("its rules", empty.side == .front && !empty.showPerspective && empty.showOrthographic && empty.useAlpha
      && empty.color == SIMD4(1, 0.5, 0.25, 0.75))
check("and it writes the same record back", ObjectDisplay(type: "EMPTY", dataName: "",
                                                           record: ObjectDisplay.empty(empty).record) == .empty(empty))

func view(eye: SIMD3<Float>, target: SIMD3<Float> = .zero, ortho: Bool) -> OverlayView {
    let v = simd_float4x4.lookAt(eye: eye, center: target, up: abs(eye.z) > 0.9 * simd_length(eye) ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
    let p = ortho ? simd_float4x4.orthographic(halfWidth: 5, halfHeight: 4, near: -100, far: 100)
        : simd_float4x4.perspective(fovY: 0.8, aspect: 1.333, near: 0.1, far: 100)
    return OverlayView(view: v, projection: p, size: CGSize(width: 800, height: 600))
}
let identity = matrix_identity_float4x4
let fromFront = view(eye: SIMD3(0, 0, 10), ortho: false), fromBehind = view(eye: SIMD3(0, 0, -10), ortho: false)
let orthoFront = view(eye: SIMD3(0, 0, 10), ortho: true), slanted = view(eye: SIMD3(3, 0, 10), ortho: true)
var e = EmptyDisplay()
e.kind = .image; e.imageHasData = true; e.imageFile = "/x.png"
check("both sides by default", e.pictureVisible(world: identity, view: fromFront) && e.pictureVisible(world: identity, view: fromBehind))
e.side = .front
check("Side Front: seen from its Z side, and not from behind",
      e.pictureVisible(world: identity, view: fromFront) && !e.pictureVisible(world: identity, view: fromBehind))
e.side = .back
check("Side Back: the other way round",
      !e.pictureVisible(world: identity, view: fromFront) && e.pictureVisible(world: identity, view: fromBehind))
e.side = .front
let edgeOn = view(eye: SIMD3(10, 0, 0), ortho: true)
check("orthographic edge-on with Front, hidden (Blender's 1e-5 margin)", !e.pictureVisible(world: identity, view: edgeOn))
e.side = .both; e.onlyAxisAligned = true
check("Only Axis Aligned: shown looking along its Z", e.pictureVisible(world: identity, view: orthoFront))
check("and hidden from a slant", !e.pictureVisible(world: identity, view: slanted))
e.onlyAxisAligned = false
e.showPerspective = false
check("Show In Perspective off hides the frame in perspective, not in orthographic",
      !e.frameVisible(perspective: true) && e.frameVisible(perspective: false))
check("control: the view's projection is read", fromFront.isPerspective && !orthoFront.isPerspective)
e.showPerspective = true

func quad(_ d: EmptyDisplay, _ v: OverlayView = fromFront) -> ImageEmptyDraw.Quad? {
    ImageEmptyDraw.quad(d, "E", identity, v)
}
check("Default without Opacity draws in the scene pass", quad(e)?.pass == .scene && quad(e)?.alphaBlend == false)
var blended = e; blended.useAlpha = true; blended.color.w = 0.5
check("with Opacity, blended", quad(blended)?.pass == .blended && quad(blended)?.tint.w == 0.5)
var clear = blended; clear.color.w = 0
check("Opacity on at 0 draws nothing, as Blender's `color[3] > 0` test", quad(clear) == nil)
var opaque = clear; opaque.useAlpha = false
check("control: Opacity off at 0 still draws", quad(opaque) != nil)
var back = e; back.depth = .back
var front = e; front.depth = .front
var inFront = e; inFront.inFront = true; inFront.depth = .back
check("Back, Front and In Front", quad(back)?.pass == .back && quad(front)?.pass == .front && quad(inFront)?.pass == .front)
var noData = e; noData.imageHasData = false
check("no picture to read, nothing drawn", quad(noData) == nil)
var plain = e; plain.kind = .cube
check("not an image empty, nothing", quad(plain) == nil)
e.size = 5; e.imageAspect = SIMD2(1, 0.5)
if let q = quad(e) {
    check("the quad is the frame: 5 wide, 2.5 tall, centred by the offset",
          simd_distance(q.corners[0], SIMD3(-2.5, -1.25, 0)) < 1e-5 && simd_distance(q.corners[2], SIMD3(2.5, 1.25, 0)) < 1e-5,
          "\(q.corners)")
}
let scene = BKScene(startupFile: false)
scene.objects = []
for (name, depth, alpha, z) in [("near", EmptyDisplay.Depth.default, true, Float(2)), ("far", .default, true, -2),
                                ("bg", .back, false, 0), ("solid", .default, false, 0)] {
    var d = e; d.depth = depth; d.useAlpha = alpha
    let obj = scene.addObject(.empty(d), named: name, at: SIMD3(0, 0, z))
    _ = obj
}
let order = ImageEmptyDraw.quads(in: scene, view: fromFront).map(\.object)
equal("passes in Blender's order, the blended back to front", order, ["bg", "solid", "far", "near"])
check("none with the overlays off", ImageEmptyDraw.quads(in: scene, view: fromFront, overlays: false).isEmpty)

print("\nAdd ▸ Image")
equal("Reference... adds through Blender's operator, facing the view",
      ReferenceImages.add(.reference, path: "/tmp/a b.png", location: SIMD3(1, 2, 3), rotation: SIMD3(0.5, 0, 0),
                          orthographic: true),
      "import _blenderkit_images\n_blenderkit_images.add(\"/tmp/a b.png\", False, (1, 2, 3), (0.5, 0, 0), True)")
check("Background... says so", ReferenceImages.add(.background, path: "/p", location: .zero, rotation: .zero,
                                                    orthographic: false).contains("\"/p\", True,"))
check("Blender's words, in its order, and undo", ReferenceImages.Kind.allCases.map(\.label)
      == ["Reference...", "Background...", "Mesh Plane..."]
      && ReferenceImages.Kind.reference.undo == "Add Empty Image/Drop Image to Empty"
      && ReferenceImages.Kind.background.undo == ReferenceImages.undo
      && ReferenceImages.Kind.plane.undo == "Import Images as Planes")
equal("Mesh Plane... is Blender's importer, at its defaults",
      ReferenceImages.add(.plane, path: "/tmp/a b.png", location: SIMD3(1, 2, 3), rotation: .zero, orthographic: true),
      "import _blenderkit_images\n_blenderkit_images.add_plane(\"/tmp/a b.png\")")

print("\nwhat Blender is handed for a picture")
// Measured in 5.2.1 (_blenderkit_images.py): Blender reads no HEIC, ignores
// a JPEG's EXIF orientation, and decodes a picture whole.
let stored = Pictures.quadrants(width: 64, height: 32)
let png = Pictures.encode(stored, as: .png)!
do {
    let same = try ReferenceImages.prepare(png, name: "ref.png")
    check("an sRGB PNG the right way up and small enough goes as it is", same.data == png && same.name == "ref.png")
    let renamed = try ReferenceImages.prepare(png, name: "Photo.heic")
    check("named for what it is", renamed.name == "Photo.png")
} catch {
    check("a PNG prepares", false, "\(error)")
}
if let heic = Pictures.encode(stored, as: .heic) {
    check("control: the HEIC is one", Pictures.header(heic)?.type == UTType.heic.identifier)
    do {
        let made = try ReferenceImages.prepare(heic, name: "Photo.heic")
        let h = Pictures.header(made.data)
        check("a HEIC from Photos becomes a JPEG, same size", h?.type == UTType.jpeg.identifier && h?.width == 64
              && h?.height == 32 && made.name == "Photo.jpg", "\(String(describing: h)) \(made.name)")
        let colours = Pictures.quarterColours(Pictures.decoded(made.data, transform: false)!)
        check("its quarters where they were", zip(colours, Pictures.quarters).allSatisfy { Pictures.near($0, $1) },
              "\(colours)")
    } catch {
        check("a HEIC prepares", false, "\(error)")
    }
} else {
    check("this Mac writes HEIC, for the test", false)
}
let turned = Pictures.encode(stored, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])!
check("control: the JPEG is stored 64 x 32 and tagged to turn a quarter",
      Pictures.header(turned).map { $0.width == 64 && $0.height == 32 && $0.orientation == 6 } == true)
do {
    let made = try ReferenceImages.prepare(turned, name: "IMG_1.JPG")
    let h = Pictures.header(made.data)!
    check("an EXIF-turned JPEG is turned in its pixels: 32 x 64, no tag", h.width == 32 && h.height == 64
          && h.orientation == 1 && made.name == "IMG_1.jpg", "\(h)")
    // Orientation 6 shows the stored top row down the right side: what was
    // top left (red) is top right, bottom left (green) top left, bottom
    // right (yellow) bottom left, top right (blue) bottom right.
    let shown = Pictures.quarterColours(Pictures.decoded(made.data, transform: false)!)
    let expected: [[UInt8]] = [Pictures.quarters[2], Pictures.quarters[0], Pictures.quarters[3], Pictures.quarters[1]]
    check("as Photos shows it: green, red / yellow, blue", zip(shown, expected).allSatisfy { Pictures.near($0, $1) },
          "\(shown)")
    let photos = Pictures.quarterColours(Pictures.decoded(turned, transform: true)!)
    check("which is ImageIO's own turn of the original", zip(shown, photos).allSatisfy { a, b in
        zip(a, b).allSatisfy { abs($0 - $1) <= 48 } }, "\(shown) \(photos)")
} catch {
    check("an EXIF-turned JPEG prepares", false, "\(error)")
}
let deep = Pictures.encode(Pictures.sixteenBit(width: 40, height: 20), as: .png)!
check("control: the 16-bit PNG is one", Pictures.header(deep)?.depth == 16)
if let made = try? ReferenceImages.prepare(deep, name: "deep.png") {
    check("a 16-bit PNG becomes an 8-bit PNG", Pictures.header(made.data).map { $0.depth == 8
        && $0.type == UTType.png.identifier && $0.width == 40 } == true, "\(String(describing: Pictures.header(made.data)))")
}
let huge = Pictures.encode(Pictures.quadrants(width: 6000, height: 3000), as: .png)!
if let made = try? ReferenceImages.prepare(huge, name: "huge.png") {
    let h = Pictures.header(made.data)
    check("a 6,000 x 3,000 PNG is scaled to 4,096 on its longer side (\(huge.count) bytes in)",
          h?.width == 4096 && h?.height == 2048, "\(String(describing: h))")
}
// A colour inside sRGB's gamut, so converting it changes its numbers.
let p3 = Pictures.encode(Pictures.solid(width: 32, height: 32, rgb: [180, 120, 60],
                                        space: CGColorSpace(name: CGColorSpace.displayP3)!), as: .png)!
if let made = try? ReferenceImages.prepare(p3, name: "p3.png") {
    check("control: the P3 picture says so", Pictures.header(p3)?.profile?.contains("P3") == true)
    let converted = Pictures.quarterColours(Pictures.decoded(made.data, transform: false)!)[0]
    check("a Display P3 picture is converted to sRGB for Blender, which takes its numbers as sRGB: "
          + "180, 120, 60 is \(converted)", made.data != p3 && converted != [180, 120, 60]
              && Pictures.header(made.data)?.profile?.contains("sRGB") == true,
          "\(String(describing: Pictures.header(made.data)))")
}
do {
    _ = try ReferenceImages.prepare(Data("not a picture".utf8), name: "x.png")
    check("control: what is not a picture is refused", false)
} catch {
    check("control: what is not a picture is refused", (error as? ReferenceImages.PictureError) == .unreadable)
}

print("\nthe viewport's picture, as Blender reads the file")
let turnedFile = FileManager.default.temporaryDirectory.appendingPathComponent("modkinds-turned.jpg")
try? turned.write(to: turnedFile)
if let drawn = ReferenceImages.viewportImage(at: turnedFile.path, maxSide: 2048) {
    check("an EXIF-turned JPEG is drawn as stored, 64 x 32, as Blender reads it", drawn.width == 64 && drawn.height == 32,
          "\(drawn.width) x \(drawn.height)")
    let colours = Pictures.quarterColours(drawn)
    check("its quarters where they are stored: red, blue / green, yellow",
          zip(colours, Pictures.quarters).allSatisfy { Pictures.near($0, $1) }, "\(colours)")
} else {
    check("the viewport reads the JPEG", false)
}
check("control: decoded the way Photos shows it, it is 32 x 64",
      Pictures.decoded(turned, transform: true).map { $0.width == 32 && $0.height == 64 } == true)
let p3File = FileManager.default.temporaryDirectory.appendingPathComponent("modkinds-p3.png")
try? p3.write(to: p3File)
if let drawn = ReferenceImages.viewportImage(at: p3File.path, maxSide: 2048) {
    let bytes = Pictures.rgba(drawn)
    check("a P3 file's numbers are drawn as stored, read as sRGB: 180, 120, 60",
          Array(bytes[0..<3]) == [180, 120, 60] && drawn.colorSpace?.name == CGColorSpace.sRGB,
          "\(Array(bytes[0..<3])) \(String(describing: drawn.colorSpace?.name))")
}
try? FileManager.default.removeItem(at: turnedFile)
try? FileManager.default.removeItem(at: p3File)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
