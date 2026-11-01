import CoreGraphics
import Foundation
import ImageIO
import simd

// Round 4, group 8's strings for desktop Blender, and the Swift's replay of
// what Blender sent back (scripts/run-modkinds-blender-check.sh).
//
//   dump calls                 every string the controls send, in blocks
//   dump edits <records.json>  for each declared row Blender reported, one
//                              edit per setting, as the row builds it
//   dump replay <passes.json>  what Blender reported after those edits and
//                              after the text and image rows, read as the
//                              panels read it, against what Blender holds

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func block(_ name: String, _ body: String) {
    print("###\(name)")
    print(body)
    print("#--")
}

let declared: [ModifierKind] = [.curve, .wireframe, .skin, .hook, .armature, .surfaceDeform, .meshDeform,
                                .dataTransfer, .normalEdit, .mask, .build]
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "calls"

func kindTag(_ k: ModifierField.Kind) -> (String, [ModifierField.Choice]) {
    switch k {
    case .number: return ("number", [])
    case .integer: return ("integer", [])
    case .toggle: return ("toggle", [])
    case .choice(let c): return ("choice", c)
    case .flags(let c): return ("flags", c)
    case .vector3: return ("vector3", [])
    case .object: return ("object", [])
    case .readOnly: return ("readonly", [])
    }
}

/// The value an edit of `field` sets on `m`: another one Blender takes.
func changedValue(_ field: ModifierField, _ m: Modifier, objects: [String: String]) -> String? {
    let now = m.values[field.key] ?? ""
    switch field.kind {
    case .number(_, _, let lo, let hi):
        var v = (Float(now) ?? 0) + 0.25
        if let hi, v > hi { v = (lo ?? 0) + (hi - (lo ?? 0)) * 0.3 }
        if let lo, v < lo { v = lo }
        return String(Double(v))
    case .integer(let r):
        let v = Int((Float(now) ?? 0).rounded())
        return "\(v + 1 <= r.upperBound ? v + 1 : r.lowerBound)"
    case .toggle:
        return now == "1" ? "0" : "1"
    case .choice:
        return m.choices(for: field).first { $0.identifier != now }?.identifier
    case .flags(let c):
        let picked = ModifierField.flagSet(now)
        return picked.isEmpty ? c.map(\.identifier).prefix(2).sorted().joined(separator: ",") : ""
    case .vector3:
        return "0.5,-0.25,1.0"
    case .object:
        return objects["\(m.blenderType) \(field.key)"] ?? ""
    case .readOnly:
        return nil
    }
}

switch mode {
case "calls":
    for type in ["MESH", "CURVE", "FONT", "SURFACE", "LATTICE", "VOLUME", "GREASEPENCIL", "EMPTY", "CURVES",
                 "POINTCLOUD", "CAMERA", "LIGHT", "ARMATURE"] {
        var lines = ModifierCatalog.menu(for: type).flatMap { category in
            category.rows.map { "\(category.name)\t\($0.type)\t\($0.label)\t\($0.asset ? 1 : 0)" }
        }
        if let nodes = ModifierCatalog.geometryNodes(on: type) { lines.append("\t\(nodes.type)\t\(nodes.label)\t0") }
        block("CATALOG \(type)", lines.joined(separator: "\n"))
    }
    let cube = MeshBuilder.cube(size: 2)
    for type in ["MESH", "CURVE", "FONT", "SURFACE", "LATTICE"] {
        for row in ModifierCatalog.rows(for: type) {
            block("ADD \(type) \(row.type)", Bpy.addModifierRow(row, on: cube).joined(separator: "\n"))
        }
    }
    for kind in declared {
        block("FIELDS \(kind.bpyType)", ([kind.displayName, kind.label] + kind.fields.map { field in
            let (tag, choices) = kindTag(field.kind)
            return [field.key, field.label, tag, choices.map { "\($0.identifier)=\($0.label)" }.joined(separator: ","),
                    field.panel ?? ""].joined(separator: "\t")
        }).joined(separator: "\n"))
    }
    for op in ModifierOperation.allCases {
        let m = Modifier(kind: op.kind, name: op.kind.displayName)
        let command = ModifierRowAction.operation(op).command(for: m, in: [m])!
        block("OP \(op.rawValue)", command.undo + "\n" + command.lines.joined(separator: "\n"))
    }
    // For the simulator's stand-in (tests/modkinds/shim.py): each declared
    // row added and every setting sent, with a value of its kind.
    for kind in declared where kind != .curve {
        var m = Modifier(kind: kind)
        for field in kind.fields {
            switch field.kind {
            case .number: m.values[field.key] = "0.5"
            case .integer(let r): m.values[field.key] = "\(min(r.lowerBound + 1, r.upperBound))"
            case .toggle: m.values[field.key] = "1"
            case .choice(let c): m.values[field.key] = c[c.count > 1 ? 1 : 0].identifier
            case .flags(let c): m.values[field.key] = c[0].identifier
            case .vector3: m.values[field.key] = "0.1,0.2,0.3"
            case .object: m.values[field.key] = "Target"
            case .readOnly: break
            }
        }
        let row = ModifierCatalog.rows(for: "MESH").first { $0.kind == kind }!
        block("SHIM \(kind.bpyType)", (Bpy.addModifierRow(row, on: cube) + Bpy.declaredSettings(m))
            .joined(separator: "\n"))
    }
    // Data Transfer's Mix Mode list by the data types picked.
    var rules: [String] = []
    for (toggle, key, types) in [("use_vert_data", "data_types_verts", ""), ("use_vert_data", "data_types_verts", "VGROUP_WEIGHTS"),
                                 ("use_vert_data", "data_types_verts", "BEVEL_WEIGHT_VERT"),
                                 ("use_edge_data", "data_types_edges", "SHARP_EDGE"),
                                 ("use_edge_data", "data_types_edges", "CREASE"),
                                 ("use_loop_data", "data_types_loops", "CUSTOM_NORMAL"),
                                 ("use_loop_data", "data_types_loops", "UV"),
                                 ("use_poly_data", "data_types_polys", "SMOOTH")] {
        var m = Modifier(kind: .dataTransfer, name: "DataTransfer")
        m.values = [toggle: "1", key: types]
        let field = ModifierKind.dataTransfer.fields.first { $0.key == "mix_mode" }!
        rules.append([toggle, key, types, m.choices(for: field).map(\.identifier).joined(separator: ",")]
            .joined(separator: "\t"))
    }
    block("MIXRULES", rules.joined(separator: "\n"))
    // Showing a hidden modifier, priced (`modifierVisibility`).
    var hidden = Modifier(kind: .subdivision, name: "Subdivision")
    hidden.showInViewport = false
    var shown = hidden
    shown.showInViewport = true
    block("SHOW Subdivision", Bpy.modifierEdit(from: hidden, to: shown).joined(separator: "\n"))
    var wire = Modifier(kind: .wireframe, name: "Wireframe")
    wire.values = ["use_replace": "1"]
    var kept = wire
    kept.values["use_replace"] = "0"
    block("WIRE KEEP", Bpy.modifierEdit(from: wire, to: kept).joined(separator: "\n"))
    // Text.
    block("TEXT BODY", TextBpy.setBody("Hello;=|%\nWorld é \"quoted\"", object: "Text"))
    block("TEXT LONG", TextBpy.setBody(String(repeating: "abcdefghij", count: 900), object: "Text"))
    for (key, value) in [("size", "2.0"), ("extrude", "0.1"), ("bevel_depth", "0.02"), ("bevel_resolution", "4"),
                         ("offset", "0.01"), ("align_x", "CENTER"), ("align_y", "CENTER"), ("space_character", "1.5"),
                         ("space_word", "2.0"), ("space_line", "1.25"), ("shear", "0.2"), ("offset_x", "0.5"),
                         ("offset_y", "-0.5"), ("resolution_u", "6"), ("fill_mode", "FRONT")] {
        let python = Float(value).map { TextBpy.python(key, $0) } ?? "'\(value)'"
        block("TEXT SET \(key) \(value)", TextBpy.set(key, to: python, object: "Text"))
    }
    block("TEXT HUGE", TextBpy.set("resolution_u", to: "64", object: "Text"))
    // Round 4's review of this group: the price beaten by other letters, a
    // negative Bevel Depth, Fill Mode, and a cleared body.
    block("TEXT O1000", TextBpy.setBody(String(repeating: "O", count: 1000), object: "Text"))
    block("TEXT O10", TextBpy.setBody(String(repeating: "O", count: 10), object: "Text"))
    block("TEXT NEGBEVEL", TextBpy.set("bevel_depth", to: TextBpy.python("bevel_depth", -0.02), object: "Text"))
    block("TEXT FILL BOTH", TextBpy.set("fill_mode", to: "'BOTH'", object: "Text"))
    block("TEXT CLEAR", TextBpy.setBody("", object: "Text"))
    // The rows' lines for the budget on a text, a curve, a surface, Screw,
    // Skin and a move (round 4's review).
    for name in ["Array", "Array.001", "Array.002"] {
        var two = Modifier(kind: .array, name: name)
        two.count = 2
        var many = two
        many.count = 64
        block("ARRAY64 \(name)", Bpy.modifierEdit(from: two, to: many).joined(separator: "\n"))
    }
    for (from, to) in [(1, 2), (1, 4), (1, 6)] {
        var a = Modifier(kind: .subdivision, name: "Subdivision")
        a.levels = from
        var b = a
        b.levels = to
        block("SUBSURF \(from) TO \(to)", Bpy.modifierEdit(from: a, to: b).joined(separator: "\n"))
    }
    for steps in [200, 512] {
        var a = Modifier(kind: .screw, name: "Screw")
        a.count = 16
        var b = a
        b.count = steps
        block("SCREW STEPS \(steps)", Bpy.modifierEdit(from: a, to: b).joined(separator: "\n"))
    }
    block("MOVE UP Subdivision", Bpy.moveModifier("Subdivision", up: true))
    block("TEXT EDITMODE", Bpy.toggleEditMode)
    // Images.
    block("IMAGE REF", ReferenceImages.add(.reference, path: "{PATH}", location: SIMD3(1, 2, 3),
                                           rotation: SIMD3(0.5, 0, 0), orthographic: false))
    block("IMAGE BG ORTHO", ReferenceImages.add(.background, path: "{PATH}", location: .zero,
                                                rotation: .zero, orthographic: true))
    block("IMAGE BG PERSP", ReferenceImages.add(.background, path: "{PATH}", location: .zero,
                                                rotation: .zero, orthographic: false))
    block("IMAGE PLANE", ReferenceImages.add(.plane, path: "{PATH}", location: .zero, rotation: .zero,
                                             orthographic: false))
    for (key, python) in [("empty_image_depth", "'FRONT'"), ("empty_image_side", "'BACK'"),
                          ("show_empty_image_orthographic", "False"), ("show_empty_image_perspective", "False"),
                          ("show_empty_image_only_axis_aligned", "True"), ("use_empty_image_alpha", "True"),
                          ("opacity", "0.4"), ("empty_image_offset_x", "-0.25"), ("empty_image_offset_y", "0")] {
        block("EMPTY SET \(key)", ReferenceImages.set(key, to: python, object: "{NAME}"))
    }
    block("EMPTY SIZE", ReferenceImages.setEmpty("empty_display_size", to: "2.5", object: "{NAME}"))

case "pictures":
    // The pictures a device hands the app, and what `ReferenceImages.prepare`
    // makes of each, written to `args[2]` for Blender to read; pictures.json
    // says which is which.
    let folder = URL(fileURLWithPath: args[2], isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var made: [String: [String: Any]] = [:]
    func write(_ name: String, _ data: Data, prepare: Bool = true) {
        try! data.write(to: folder.appendingPathComponent(name))
        var entry: [String: Any] = ["file": name]
        if prepare {
            do {
                let out = try ReferenceImages.prepare(data, name: name)
                let prepared = "prepared-" + out.name
                try out.data.write(to: folder.appendingPathComponent(prepared))
                entry["prepared"] = prepared
                entry["same"] = out.data == data
            } catch {
                entry["error"] = "\(error)"
            }
        }
        made[name] = entry
    }
    let stored = Pictures.quadrants(width: 64, height: 32)
    write("photo.heic", Pictures.encode(stored, as: .heic)!)
    write("turned.jpg", Pictures.encode(stored, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])!)
    write("plain.png", Pictures.encode(stored, as: .png)!)
    write("progressive.jpg", Pictures.encode(stored, as: .jpeg, properties: [
        kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: String(repeating: "x", count: 3000)]])!)
    write("deep16.png", Pictures.encode(Pictures.sixteenBit(width: 40, height: 20), as: .png)!)
    write("deep16-big.png", Pictures.encode(Pictures.sixteenBit(width: 2100, height: 2100), as: .png)!, prepare: false)
    write("huge6000.png", Pictures.encode(Pictures.solid(width: 6000, height: 6000, rgb: [10, 200, 30],
                                                         space: CGColorSpace(name: CGColorSpace.sRGB)!), as: .png)!)
    write("p3.png", Pictures.encode(Pictures.solid(width: 32, height: 32, rgb: [180, 120, 60],
                                                   space: CGColorSpace(name: CGColorSpace.displayP3)!), as: .png)!)
    // What the viewport draws of each, as `ReferenceImages.viewportImage`
    // reads it: its size and its quarters' colours.
    for (name, _) in made {
        let path = folder.appendingPathComponent((made[name]?["prepared"] as? String) ?? name).path
        if let image = ReferenceImages.viewportImage(at: path, maxSide: 2048) {
            made[name]?["viewport"] = [image.width, image.height]
            made[name]?["viewport_quarters"] = Pictures.quarterColours(image)
        }
        let raw = folder.appendingPathComponent(name).path
        if let image = ReferenceImages.viewportImage(at: raw, maxSide: 2048) {
            made[name]?["viewport_raw"] = [image.width, image.height]
            made[name]?["viewport_raw_quarters"] = Pictures.quarterColours(image)
        }
    }
    let json = try! JSONSerialization.data(withJSONObject: made, options: [.sortedKeys])
    try! json.write(to: folder.appendingPathComponent("pictures.json"))
    print("  \(made.count) pictures written, \(made.values.filter { $0["prepared"] != nil }.count) prepared")

case "edits":
    // records.json: {"<TYPE>": "<record entry>", "objects": {"<TYPE> <key>": "<name>"}}
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let objects = json["objects"] as? [String: String] ?? [:]
    for kind in declared {
        guard let entry = json[kind.bpyType] as? String, let m = Modifier.stack(from: entry).first else {
            check("Blender reported a \(kind.label)", false); continue
        }
        for field in kind.fields where !field.isReadOnly {
            // To stderr: stdout is the blocks Blender reads. A setting
            // Blender's record left out would show nothing and send nothing —
            // the pointers once went missing this way, behind a name another
            // table in _blenderkit_sync.py also used.
            let carried = m.values[field.key] != nil
            FileHandle.standardError.write(((carried ? "  PASS  " : "  FAIL  ")
                + "\(kind.label) \(field.label): Blender's record carries it\n").data(using: .utf8)!)
            if !carried { failures += 1 }
            guard carried, let value = changedValue(field, m, objects: objects) else { continue }
            var changed = m
            changed.values[field.key] = value
            if field.isObject { changed.targetName = value }
            let lines = Bpy.modifierEdit(from: m, to: changed)
            block("EDIT \(kind.bpyType) \(field.key)\t\(value)", lines.joined(separator: "\n"))
        }
    }

case "replay":
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let edits = json["edits"] as? [[String: Any]] ?? []
    var replayed = 0
    for edit in edits {
        guard let type = edit["type"] as? String, let key = edit["key"] as? String,
              let expected = edit["expected"] as? String, let entry = edit["record"] as? String,
              let m = Modifier.stack(from: entry).first(where: { $0.blenderType == type }),
              let field = m.kind.fields.first(where: { $0.key == key }) else { continue }
        let shown = m.values[key] ?? "<none>"
        // The row shows the record's text, read as its control reads it.
        let same: Bool
        switch field.kind {
        case .number: same = abs((Float(shown) ?? .nan) - (Float(expected) ?? .nan)) < 1e-4
        case .integer: same = Int((Float(shown) ?? -1).rounded()) == Int((Float(expected) ?? -2).rounded())
        case .flags: same = ModifierField.flagSet(shown) == ModifierField.flagSet(expected)
        case .vector3:
            let a = shown.split(separator: ",").compactMap { Float($0) }
            let b = expected.split(separator: ",").compactMap { Float($0) }
            same = a.count == 3 && b.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) < 1e-4 }
        default: same = shown == expected
        }
        check("\(m.kind.label) \(field.label): the row shows what Blender holds after its edit", same,
              "shows \(shown), Blender \(expected)")
        if field.isObject {
            check("\(m.kind.label) \(field.label): and names it as its object", m.targetName == expected)
        }
        replayed += 1
    }
    // Every writable setting of the eleven kinds but Data Transfer's Mix
    // Mode, which with no data type picked has only Replace to go to.
    let writable = declared.reduce(0) { $0 + $1.fields.filter { !$0.isReadOnly }.count } - 1
    check("every edit was replayed (\(replayed) of \(writable))", replayed == writable, "\(replayed)")
    // The text record after the body and rows.
    if let record = json["text"] as? String, let held = json["text_held"] as? [String: String] {
        guard case .text(let t)? = ObjectDataSettings.parse(type: "FONT", record: record) else {
            check("the text record parses", false); break
        }
        check("the Body Text field shows Blender's body", t.body == held["body"], "\(t.body.debugDescription) vs \(held["body"]?.debugDescription ?? "")")
        for (key, value) in held where key != "body" {
            let shown = t.values[key] ?? "<none>"
            let same = Float(shown).flatMap { a in Float(value).map { abs(a - $0) < 1e-4 } } ?? (shown == value)
            check("the text's \(key) shows Blender's \(value)", same, shown)
        }
    } else {
        check("Blender reported the text", false)
    }
    if let record = json["text_cleared"] as? String {
        if case .text(let t)? = ObjectDataSettings.parse(type: "FONT", record: record) {
            check("a cleared body comes back as an empty Body Text, the Data tab's rows kept",
                  t.body == "" && t.values["resolution_u"] != nil, record)
        } else {
            check("a cleared body comes back as an empty Body Text, the Data tab's rows kept", false, record)
        }
    } else {
        check("Blender reported the cleared text", false)
    }
    for (label, entry) in json["images"] as? [String: [String: String]] ?? [:] {
        guard let record = entry["record"],
              case .empty(let e)? = ObjectDisplay(type: "EMPTY", dataName: "", record: record) else {
            check("\(label): the image record parses", false); continue
        }
        check("\(label): its picture's file is there to read", FileManager.default.fileExists(atPath: e.imageFile)
              && e.imageHasData, e.imageFile)
        check("\(label): depth, side and Show In as Blender holds them",
              e.depth.rawValue == entry["depth"] && e.side.rawValue == entry["side"]
                  && e.showOrthographic == (entry["ortho"] == "1") && e.showPerspective == (entry["persp"] == "1")
                  && e.onlyAxisAligned == (entry["axis"] == "1") && e.useAlpha == (entry["alpha"] == "1")
                  && abs(e.color.w - (Float(entry["opacity"] ?? "") ?? -1)) < 1e-4,
              "\(e.depth) \(e.side) \(e.showOrthographic) \(e.showPerspective) \(e.onlyAxisAligned) \(e.useAlpha) \(e.color.w) vs \(entry)")
    }
default:
    print("dump calls | edits <records.json> | replay <passes.json>")
}
if mode == "edits" && failures > 0 {
    FileHandle.standardError.write("\(failures) FAILED\n".data(using: .utf8)!)
    exit(1)
}
if mode == "replay" {
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
