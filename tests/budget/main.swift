import Foundation
import simd

// The vertex budget's Swift half (round 4's fix round): every path the app has
// for a setting that can multiply geometry sends the budget's one price
// (`_blenderkit_budget`) in front of it.
//
//   1. Every modifier row's edit: for every kind, every change the row's own
//      fields can make, `Bpy.modifierEdit` puts the price first and the
//      price names every setting the edit assigns. Round 4's reviews found
//      three rows (Bevel's Segments, Mirror's axes, Screw's Steps) sending a
//      setting bare because each row chose which settings to price.
//   2. Add Modifier, every row on every object type, and the curve Data tab.
//   3. A source scan: no Swift string in Sources/ assigns a modifier's or a
//      curve's setting except through the builders checked above, so a new
//      path that writes one bare fails here until it is priced.
// What Blender makes of the Python is scripts/run-budget-blender-check.sh.
// Each group has a control that has to fail.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// (the keys the price line in front names, the keys the edit assigns), or
/// nil keys when there is no price line first.
func covered(_ lines: [String], _ name: String) -> (priced: Set<String>?, assigned: Set<String>) {
    let assigned = Set(lines.compactMap { Bpy.modifierAssignment($0, of: name)?.0 })
    guard let first = lines.first, first.hasPrefix("__import__('_blenderkit_budget').price_modifier(") else {
        return (nil, assigned)
    }
    var priced = Set<String>()
    // The dict's keys: each `"key": ` in the line.
    var rest = Substring(first)
    while let open = rest.range(of: "\"") {
        let after = rest[open.upperBound...]
        guard let close = after.range(of: "\"") else { break }
        let word = String(after[..<close.lowerBound])
        rest = after[close.upperBound...]
        if rest.hasPrefix(": ") { priced.insert(word) }
    }
    return (priced, assigned)
}

/// Every change the row's own fields can make to `m`.
func mutations(_ m: Modifier) -> [(String, Modifier)] {
    var out: [(String, Modifier)] = []
    func add(_ label: String, _ f: (inout Modifier) -> Void) {
        var c = m
        f(&c)
        out.append((label, c))
    }
    add("levels") { $0.levels += 2 }
    add("sculpt levels") { $0.sculptLevels += 1 }
    add("render levels") { $0.renderLevels += 1 }
    add("count") { $0.count += 5 }
    add("relative offset") { $0.relativeOffset *= 3 }
    add("mirror X") { $0.mirrorX.toggle() }
    add("mirror Y") { $0.mirrorY.toggle() }
    add("mirror Z") { $0.mirrorZ.toggle() }
    add("bisect") { $0.bisectY.toggle() }
    add("bisect flip") { $0.bisectFlipZ.toggle() }
    add("clip") { $0.mirrorClip.toggle() }
    add("merge") { $0.mirrorMerge.toggle() }
    add("merge distance") { $0.mergeThreshold += 0.01 }
    add("thickness") { $0.thickness += 0.5 }
    add("factor") { $0.factor += 0.25 }
    add("iterations") { $0.iterations += 3 }
    add("angle") { $0.angle += 1 }
    add("axis") { $0.axis = ($0.axis + 1) % 3 }
    add("wave X") { $0.waveX.toggle() }
    add("segments") { $0.segments += 7 }
    add("ratio") { $0.ratio *= 0.5 }
    add("voxel size") { $0.voxelSize *= 0.5 }
    add("octree depth") { $0.octreeDepth += 1 }
    add("weight") { $0.weight = min(100, $0.weight + 10) }
    add("threshold") { $0.threshold += 0.1 }
    add("keep sharp") { $0.keepSharp.toggle() }
    add("edge split angle") { $0.edgeSplitAngle.toggle() }
    add("lambda") { $0.lambdaFactor += 0.5 }
    add("smooth Z") { $0.smoothZ.toggle() }
    add("smooth scale") { $0.smoothScale += 1 }
    add("show in viewport") { $0.showInViewport.toggle() }
    add("show in render") { $0.showInRender.toggle() }
    add("vertex group") { $0.vertexGroup = "Group" }
    add("invert vertex group") { $0.invertVertexGroup.toggle() }
    add("target") { $0.targetName = "Other" }
    for field in m.kind.fields where !field.isReadOnly {
        guard let now = m.values[field.key] else { continue }
        let next: String
        switch field.kind {
        case .number, .integer: next = String((Double(now) ?? 0) + 3)
        case .toggle: next = now == "1" ? "0" : "1"
        case .choice, .flags:
            guard let other = m.choices(for: field).first(where: { $0.identifier != now })?.identifier else { continue }
            next = other
        case .vector3: next = "2.0,2.0,2.0"
        case .object: next = "Other"
        case .readOnly: continue
        }
        add("field \(field.key)") { $0.values[field.key] = next; if field.isObject { $0.targetName = next } }
    }
    return out
}

/// A modifier of `kind` with every declared field holding a value, as the
/// mirror's record would have it.
func filled(_ kind: ModifierKind) -> Modifier {
    var m = Modifier(kind: kind, name: kind.displayName)
    for field in kind.fields where m.values[field.key] == nil {
        switch field.kind {
        case .number, .integer: m.values[field.key] = "1.0"
        case .toggle: m.values[field.key] = "0"
        case .choice(let choices), .flags(let choices): m.values[field.key] = choices.first?.identifier ?? ""
        case .vector3: m.values[field.key] = "1.0,1.0,1.0"
        case .object: m.values[field.key] = ""
        case .readOnly: m.values[field.key] = "0"
        }
    }
    return m
}

// --------------------------------------------------------------------------
print("1. every modifier row's edit is priced first, every setting it sends")

var edits = 0, uncovered: [String] = [], unpriced: [String] = []
for kind in ModifierKind.allCases {
    let m = filled(kind)
    for (label, changed) in mutations(m) {
        let lines = Bpy.modifierEdit(from: m, to: changed)
        guard !lines.isEmpty else { continue }
        let (priced, assigned) = covered(lines, changed.name)
        if assigned.isEmpty { continue }   // not an assignment (Smooth by Angle's node inputs)
        edits += 1
        guard let priced else { unpriced.append("\(kind.rawValue) \(label)"); continue }
        let missing = assigned.subtracting(priced)
        if !missing.isEmpty { uncovered.append("\(kind.rawValue) \(label): \(missing.sorted())") }
    }
}
check("\(edits) edits over \(ModifierKind.allCases.count) kinds each start with the budget's price", unpriced.isEmpty,
      unpriced.joined(separator: "; "))
check("and the price names every setting the edit sends", uncovered.isEmpty, uncovered.joined(separator: "; "))

var bevel = Modifier(kind: .bevel, name: "Bevel")
var twelve = bevel
twelve.segments = 12
let bevelLines = Bpy.modifierEdit(from: bevel, to: twelve)
check("the Bevel row's Segments 12 sends the price (round 4's review: it sent none)",
      bevelLines.first == "__import__('_blenderkit_budget').price_modifier(\"Bevel\", {\"segments\": 12})",
      bevelLines.joined(separator: " / "))
var mirror = Modifier(kind: .mirror, name: "Mirror")
var xyz = mirror
xyz.mirrorY = true
xyz.mirrorZ = true
let mirrorLines = Bpy.modifierEdit(from: mirror, to: xyz)
check("the Mirror row's axes send the price (round 4's review: they sent none)",
      mirrorLines.first?.contains("\"use_axis\": (True, True, True)") == true, mirrorLines.joined(separator: " / "))
bevel.name = "a;b|c=d%e \"quoted\""
twelve.name = bevel.name
let oddLines = Bpy.modifierEdit(from: bevel, to: twelve)
check("a modifier with quotes and separators in its name is priced by that name",
      covered(oddLines, bevel.name).priced == ["segments"], oddLines.joined(separator: " / "))

// Control: the edit with its price line taken out has nothing covering it.
let bare = Array(bevelLines.dropFirst())
check("control: without the price line the check finds the Segments unpriced", covered(bare, "Bevel").priced == nil)

// --------------------------------------------------------------------------
print("\n2. Add Modifier and the curve Data tab")

let cube = MeshBuilder.cube(size: 2)
var adds = 0, bareAdds: [String] = []
for type in ["MESH", "CURVE", "FONT", "SURFACE", "LATTICE"] {
    for row in ModifierCatalog.rows(for: type) where !row.asset {
        let lines = Bpy.addModifierRow(row, on: cube)
        adds += 1
        let priced = lines.first == "__import__('_blenderkit_budget').price_add(\(Bpy.quote(row.type)))"
            || (lines.first?.hasPrefix("__import__('_blenderkit_budget').price_add(\(Bpy.quote(row.type)), settings=") ?? false)
        if !priced { bareAdds.append("\(type) \(row.type): \(lines.first ?? "")") }
    }
}
check("all \(adds) Add Modifier rows on five object types are priced first", bareAdds.isEmpty,
      bareAdds.joined(separator: "; "))
let bigCube = MeshBuilder.cube(size: 200)
let remeshLines = Bpy.addModifier(.remesh, on: bigCube)
check("a Remesh on a 200 m cube is priced at the voxel floor it is given in the same evaluation",
      remeshLines.first?.contains("settings={\"voxel_size\": ") == true && remeshLines.count == 3,
      remeshLines.joined(separator: " / "))
check("and every other kind's add carries its price too, the DEBUG hooks' among them",
      Bpy.addModifier(.lattice, on: cube).first == "__import__('_blenderkit_budget').price_add(\"LATTICE\")")
let data = PointsBpy.set("resolution_u", to: "64", object: "Curve")
check("the curve Data tab's Resolution Preview U sends the price before its assignment",
      data == "__import__('_blenderkit_budget').price(bpy.data.objects[\"Curve\"].data, \"resolution_u\", 64)\n"
        + "bpy.data.objects[\"Curve\"].data.resolution_u = 64", data)

// --------------------------------------------------------------------------
print("\n3. no Swift string assigns a modifier's or a curve's setting bare")

// Each place a Swift string may assign one, and what prices it.
let allowed: [(file: String, contains: String, why: String)] = [
    ("BpyBridge.swift", "\"bpy.context.object.modifiers[\\(quote(modifier))].\\(key) = \\(value)\"",
     "setModifierProperty, which modifierEdit prices (1)"),
    ("BpyBridge.swift", "after.append(\"bpy.context.object.modifiers.active.voxel_size = \\(value)\")",
     "Remesh's floor, priced with its add (priceAdd settings)"),
    ("ControlPoints.swift", "+ \"\\(data).\\(property) = \\(value)\"", "PointsBpy.set, priced in its first line"),
    ("ScriptExamples.swift", "", "an example script the user runs and reads: scripts are the user's own Python"),
    ("RenderRequest.swift", "\"bpy.data.objects[\\(quote(name))].data.\\(key) = \\(quote(choice))\"",
     "a camera's or a light's data (the Camera and Light panels), which makes no mesh"),
]
// A Python assignment to a modifier's or a curve's data inside a Swift string.
let patterns = [#"modifiers(\[[^\]]*\]|\.active)\.(\\\([a-z]+\)|[a-z_]+) = "#, #"\.data\.[a-z_\\()]+ = "#,
                #"\]\.data\)?\.\\\([a-z]+\) = "#]
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func scan(_ allowList: [(file: String, contains: String, why: String)]) -> [String] {
    var found: [String] = []
    let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                    includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), line.contains("\"") || url.lastPathComponent == "ScriptExamples.swift" else { continue }
            guard patterns.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) else { continue }
            if allowList.contains(where: { url.lastPathComponent == $0.file && ($0.contains.isEmpty || line.contains($0.contains)) }) {
                continue
            }
            found.append("\(url.lastPathComponent):\(n + 1): \(trimmed)")
        }
    }
    return found
}
let stray = scan(allowed)
check("every Swift string that assigns one goes through a priced builder", stray.isEmpty, stray.joined(separator: "\n        "))
let control = scan(Array(allowed.dropFirst()))
check("control: with setModifierProperty off the list, the scan finds it",
      control.contains { $0.hasPrefix("BpyBridge.swift") && $0.contains("modifiers[\\(quote(modifier))]") },
      control.joined(separator: "; "))

// --------------------------------------------------------------------------
print("\n4. every operator a Swift string calls is priced, or makes no more geometry (round 4's fix-round review)")

// The review found the Object menu's Join, Link/Transfer Data and Copy
// Modifiers to Selected Objects, Edit Mode's Subdivide, the curve's
// Subdivide, Apply ▸ Scale and QuadriFlow going bare: an operator call is
// invisible to the assignment scan above. Every `bpy.ops.<module>.<name>` in
// a Swift string is now either one the operator factory prices
// (`_blenderkit_context.PRICED_OPERATORS`, the primitives' PRICED_ADDS,
// transform.rotate's own wrapper) or on this list, with what it does that
// cannot make more vertices than there are.
let contextSource = (try? String(contentsOf: root.appendingPathComponent("Resources/python/site/_blenderkit_context.py"),
                                 encoding: .utf8)) ?? ""
func tuple(named name: String, in source: String) -> [String] {
    guard let start = source.range(of: "\n" + name + " = (") else { return [] }
    let rest = source[start.upperBound...]
    var depth = 1
    var end = rest.startIndex
    for i in rest.indices {
        if rest[i] == "(" { depth += 1 }
        if rest[i] == ")" { depth -= 1; if depth == 0 { end = i; break } }
    }
    let body = rest[..<end]
    var names: [String] = []
    for line in body.split(separator: "\n") {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        var s = Substring(code)
        while let open = s.firstIndex(of: "'") {
            let after = s[s.index(after: open)...]
            guard let close = after.firstIndex(of: "'") else { break }
            names.append(String(after[..<close]))
            s = after[after.index(after: close)...]
        }
    }
    return names
}
let pricedOperators = Set(tuple(named: "PRICED_OPERATORS", in: contextSource))
let pricedAdds = Set(tuple(named: "PRICED_ADDS", in: contextSource).map { "mesh." + $0 })
check("the factory's tables read from _blenderkit_context.py (\(pricedOperators.count) operators, \(pricedAdds.count) adds)",
      pricedOperators.contains("object.join") && pricedOperators.contains("mesh.subdivide")
      && pricedAdds.contains("mesh.primitive_grid_add"))
// Operators that cannot make more vertices than the scene has: by the start
// of their name, then one by one. Each says why.
let growthFreePrefixes: [(String, String)] = [
    ("mesh.select", "selects"), ("object.select", "selects"), ("curve.select", "selects"),
    ("mesh.hide", "hides"), ("mesh.reveal", "shows what was hidden"), ("curve.hide", "hides"),
    ("curve.reveal", "shows what was hidden"), ("object.hide", "hides"),
    ("mesh.delete", "deletes"),
    ("mesh.dissolve", "removes elements; the N-Gons and many-edged vertices it leaves are priced for "
     + "Subdivision Surface's time by the gate's Edit Mode transaction (_blenderkit_gate._EditGuard)"),
    ("curve.delete", "deletes"),
    ("object.delete", "deletes"), ("mesh.mark_", "marks edges"), ("mesh.normals", "turns normals"),
    ("mesh.flip_normals", "turns normals"), ("mesh.average_normals", "turns normals"),
    ("mesh.faces_shade_", "draws faces smooth or flat (Mesh ▸ Shading)"),
    ("mesh.point_normals", "turns normals"), ("mesh.smooth_normals", "turns normals"),
    ("mesh.set_normals", "turns normals"), ("view3d.", "the view, the cursor or the selection"),
    ("uv.", "UVs"), ("anim.", "keyframes"), ("file.", "file paths"), ("wm.", "files"),
    ("outliner.", "collections and deletes"),
    ("constraint.", "constraints: where they move an object is priced by the gate in the operator's own "
     + "update, before Blender evaluates it (_blenderkit_gate)"),
    ("object.constraint", "constraints, priced by the gate as constraint. is"),
    ("object.vertex_group_", "vertex groups"), ("object.shape_key_", "shape keys, which keep the mesh's vertices"),
    ("object.shade_", "shading"), ("object.modifier_move_", "priced as object.modifier_move_up/down"),
    ("mesh.edgering_select", "selects"), ("mesh.loop_", "selects"), ("mesh.region_to_loop", "selects"),
    ("mesh.edges_select", "selects"), ("mesh.faces_select", "selects"), ("mesh.shortest_path", "selects"),
    ("mesh.prim", "the primitives, priced by name (PRICED_ADDS) — the cube, plane and monkey too, which "
     + "Edit Mode adds into the edited mesh under its stack"),
    ("view3d.snap_", "the snaps of the selection are priced by name; the cursor's move nothing"),
]
let growthFree: [String: String] = [
    "curve.cyclic_toggle": "closes or opens a spline: one segment", "curve.handle_type_set": "handles only",
    "curve.switch_direction": "reverses a spline", "curve.primitive_bezier_circle_add": "4 points",
    "curve.primitive_bezier_curve_add": "2 points", "lattice.flip": "moves lattice points",
    "lattice.make_regular": "moves lattice points", "mesh.edge_collapse": "removes",
    "mesh.edge_rotate": "turns edges", "mesh.knife_project": "cuts along an outline, priced by its own module "
    + "(_blenderkit_knife)", "mesh.loopcut_slide": "priced by its own check line (_blenderkit_loopcut.check)",
    "mesh.merge": "removes; what it leaves is priced for Subdivision Surface's time by the gate's Edit Mode transaction", "mesh.quads_convert_to_tris": "keeps the vertices", "mesh.remove_doubles": "removes",
    "mesh.separate": "moves part of the mesh to a new object, no larger than it was",
    "mesh.symmetry_snap": "moves vertices", "mesh.tris_convert_to_quads": "removes edges",
    "mesh.unsubdivide": "removes", "mesh.vertices_smooth": "moves vertices",
    "mesh.vertices_smooth_laplacian": "moves vertices", "object.add": "an empty or a light, no mesh",
    "object.align": "moves objects: where it leaves them is priced by the gate in its own update",
    "object.camera_add": "no mesh", "object.convert": "the evaluated mesh as it is",
    "object.empty_add": "no mesh", "object.light_add": "no mesh",
    "object.join_uvs": "UVs", "object.make_single_user": "copies data, the same counts",
    "object.mode_set": "modes (Sculpt Mode's way in is checked by _SculptEntry)",
    "object.modifier_apply": "makes a shown modifier's result the mesh: the same count",
    "object.modifier_remove": "removes", "object.parent_set": "where it leaves the children (with Keep Transform "
    + "off it drops an old parent's move) is priced by the gate in its own update, before Blender evaluates it",
    "object.randomize_transform": "moves objects: priced by the gate in its own update", "object.text_add": "the word Text",
    "render.render": "priced (PRICED_OPERATORS)", "sculpt.brush_stroke": "Dynamic Topology's dabs are priced "
    + "by the stroke through the stack (_blenderkit_sculpt._refuse_dyntopo_growth)",
    "transform.edge_bevelweight": "weights", "transform.edge_crease": "creases",
    "transform.edge_slide": "slides vertices", "transform.vert_slide": "slides vertices",
    "transform.push_pull": "moves vertices", "transform.shrink_fatten": "moves vertices",
    "transform.tosphere": "moves vertices", "transform.vertex_random": "moves vertices",
    "transform.shear": "moves objects or vertices: priced by the gate in its own update, before Blender "
    + "evaluates it", "transform.rotate": "priced by its own wrapper "
    + "(_blenderkit_context._Rotate), as Object Mode's moves are",
    "object.modifier_move_": "priced as object.modifier_move_up/down",
]
let opsPattern = try! NSRegularExpression(pattern: #"bpy\.ops\.([a-z_0-9]+)\.([a-z_0-9]+)"#)
func operatorCalls(priced: Set<String>) -> [String] {
    var unclassified: [String] = []
    let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                    includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift", url.lastPathComponent != "ScriptExamples.swift",
              let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), line.contains("\"") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in opsPattern.matches(in: line, range: range) {
                guard let m = Range(match.range(at: 1), in: line), let o = Range(match.range(at: 2), in: line) else { continue }
                let path = "\(line[m]).\(line[o])"
                if priced.contains(path) || pricedAdds.contains(path) || growthFree[path] != nil { continue }
                if growthFreePrefixes.contains(where: { path.hasPrefix($0.0) && !priced.contains(path) }) {
                    // A prefix covers it only when nothing priced shares the name.
                    if !path.hasPrefix("view3d.snap_selected") { continue }
                }
                unclassified.append("\(url.lastPathComponent):\(n + 1): \(path)")
            }
        }
    }
    return unclassified
}
let unclassified = operatorCalls(priced: pricedOperators)
check("every bpy.ops call in a Swift string is priced by the factory or listed as making no more geometry",
      unclassified.isEmpty, unclassified.joined(separator: "\n        "))
var withoutSubdivide = pricedOperators
withoutSubdivide.remove("mesh.subdivide")
withoutSubdivide.remove("object.join")
let missed = operatorCalls(priced: withoutSubdivide)
check("control: with Subdivide and Join off the factory's list, the scan finds their calls",
      missed.contains { $0.hasSuffix("mesh.subdivide") } && missed.contains { $0.hasSuffix("object.join") },
      missed.joined(separator: "; "))

// --------------------------------------------------------------------------
print("\n5. no Swift string moves an object bare (round 4's fix-round review)")

// The review: the N panel's Location line went bare while the Data API row
// refused the same move. Every write of an object's channels in a Swift
// string comes from the Transform fields' builder, which prices first.
let movePatterns = [#"\.(location|rotation_euler|rotation_quaternion|rotation_axis_angle|scale|dimensions|delta_location|delta_rotation_euler|delta_rotation_quaternion|delta_scale|matrix_world|matrix_basis|parent)(\[[^\]]*\])? = "#,
                    // and an object's property named by an interpolation
                    #"(objects\[[^\]]*\]|\\\(target\))\.\\\([a-z]+\)(\[[^\]]*\])? = "#]
let moveAllowed: [(file: String, contains: String, why: String)] = [
    ("ObjectTransformState.swift", "lines.append(\"\\(target).\\(property)[\\(axis)] = \\(new)\")",
     "TransformChannels.assignments, which python(writing:) prices in its first line"),
    ("RenderRequest.swift", "_camera.location = ", "the render's own temporary camera, no mesh"),
    ("RenderRequest.swift", "_camera.rotation_euler = ", "the render's own temporary camera, no mesh"),
    ("BpyRuntime.swift", "", "the simulator stand-in's parser of script lines, not a line the app sends"),
    ("TextAndImages.swift", "\"bpy.data.objects[\\(Bpy.quote(name))].\\(key) = \\(python)\"",
     "ReferenceImages.setEmpty: an empty's Display As and Size, which place nothing"),
    ("ScriptExamples.swift", "", "an example script the user runs and reads"),
]
func moveScan(_ allowList: [(file: String, contains: String, why: String)]) -> [String] {
    var found: [String] = []
    let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                    includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), line.contains("\"") else { continue }
            guard movePatterns.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) else { continue }
            guard line.contains("bpy") || line.contains("_camera") || line.contains("\\(target)") || line.contains("objects[") else { continue }
            if allowList.contains(where: { url.lastPathComponent == $0.file && ($0.contains.isEmpty || line.contains($0.contains)) }) {
                continue
            }
            found.append("\(url.lastPathComponent):\(n + 1): \(trimmed)")
        }
    }
    return found
}
let strayMoves = moveScan(moveAllowed)
check("every Swift string that moves an object goes through the priced builder", strayMoves.isEmpty,
      strayMoves.joined(separator: "\n        "))
let moveControl = moveScan(Array(moveAllowed.dropFirst()))
check("control: with the builder's line off the list, the scan finds it",
      moveControl.contains { $0.hasPrefix("ObjectTransformState.swift") }, moveControl.joined(separator: "; "))

// --------------------------------------------------------------------------
print("\n6. the gate every write goes through is wired where Blender evaluates (round 4's fix round 2)")

// The gate (_blenderkit_gate.py) prices every write before Blender evaluates
// it, from where Blender would: an operator's call (its update before and
// after), the mirror, the app's own bmesh edits. Each wire is held here by
// the source, so a new wrapper, a new mirror or a new bmesh edit that skips
// it fails — and each scan is shown failing on a copy with the wire taken out.
let site = root.appendingPathComponent("Resources/python/site")
func source(_ name: String) -> String {
    (try? String(contentsOf: site.appendingPathComponent(name), encoding: .utf8)) ?? ""
}
let gateSource = source("_blenderkit_gate.py")
check("_blenderkit_gate.py is there, with its handlers and its price", gateSource.contains("def install(")
      && gateSource.contains("depsgraph_update_pre") && gateSource.contains("frame_change_pre")
      && gateSource.contains("price_state("))

/// The `_Guarded` wrappers of _blenderkit_context.py whose `__call__` calls the
/// operator outside `with _calling(`: each class's body, split at `class `.
/// One hands the call to the wrapper inside it, which is held there.
let delegating = ["_Unsafe": "asks its table, then calls `_UndoInArea`, which calls inside `_calling`",
                  // Fix round 3: refused inside an override that sets view_layer.
                  "_SceneSwitch": "asks the overrides in force, then calls `_UndoInArea`, which calls inside `_calling`"]
func unwrappedCalls(_ text: String) -> [String] {
    var found: [String] = []
    for body in text.components(separatedBy: "\nclass ").dropFirst() {
        let name = String(body.prefix { $0 != "(" && $0 != ":" })
        guard body.contains("(_Guarded)"), delegating[name] == nil,
              let call = body.range(of: "def __call__") else { continue }
        let method = body[call.lowerBound...]
        let next = method.range(of: "\ndef ") ?? method.range(of: "\nclass ")
        let text = String(next.map { method[..<$0.lowerBound] } ?? method)
        guard let first = text.range(of: "self._operator(") else { continue }
        guard let with = text.range(of: "with _calling("), with.lowerBound < first.lowerBound else {
            found.append(name)
            continue
        }
    }
    return found
}
let contextText = source("_blenderkit_context.py")
let unwrapped = unwrappedCalls(contextText)
check("every operator wrapper of _blenderkit_context calls the operator inside the gate's `_calling`",
      unwrapped.isEmpty && contextText.contains("class _calling"), unwrapped.joined(separator: ", "))
// `_UndoInArea`'s `with _calling(...)` line taken out whatever it passes (its
// arguments changed once and left this control matching nothing, a FAIL that
// said only that the copy was unchanged).
func withoutUndoInAreaGate(_ text: String) -> String {
    guard let start = text.range(of: "\nclass _UndoInArea("),
          let end = text.range(of: "\ndef flips_rotation", range: start.upperBound..<text.endIndex),
          let line = text.range(of: #"\n        with _calling\([^\n]*\):\n            return self\._operator"#,
                                options: .regularExpression, range: start.upperBound..<end.lowerBound)
    else { return text }
    return text.replacingCharacters(in: line, with: "\n        return self._operator")
}
let stripped = withoutUndoInAreaGate(contextText)
check("control: with `_UndoInArea`'s call taken out of `_calling`, the scan names it",
      stripped != contextText && unwrappedCalls(stripped).contains("_UndoInArea"), unwrappedCalls(stripped).joined(separator: ", "))

/// Whether `sync()` asks the gate before it first asks Blender to evaluate.
func mirrorGatedFirst(_ text: String) -> Bool {
    guard let start = text.range(of: "\ndef sync(") else { return false }
    let body = text[start.upperBound...]
    guard let gate = body.range(of: "_gate_first()"), let evaluate = body.range(of: "evaluated_depsgraph_get()")
    else { return false }
    return gate.lowerBound < evaluate.lowerBound
}
let syncText = source("_blenderkit_sync.py")
check("the mirror (`_blenderkit_sync.sync`) asks the gate before it asks Blender for the evaluated scene",
      mirrorGatedFirst(syncText))
check("control: with the gate's call taken out, the scan says so",
      !mirrorGatedFirst(syncText.replacingOccurrences(of: "    refusals = _gate_first()\n", with: "    refusals = []\n")))

/// Every `bmesh.update_edit_mesh` in a site module — the app's own edits of an
/// edited mesh, which no operator's price sees — inside the gate's `editing`,
/// or on the list with why it changes no element and moves none.
let bmeshAllowed: [(file: String, function: String, why: String)] = [
    ("_blenderkit_knife.py", "_untag", "removes the Knife's own tag layers"),
    ("_blenderkit_knife.py", "_restore_selection", "the selection"),
    ("_blenderkit_knife.py", "_select_like_the_knife", "the selection"),
    ("_blenderkit_item.py", "_finish", "the end of `set_median` and of `set_data`, each of which calls it inside "
     + "`editing` (a Bevel Weight is what a Bevel limited by Weight bevels: round 4's fix round 2 review, "
     + "14,400 → 3,139,984)"),
    ("_blenderkit_meshmenu.py", "_to_cursor", "Extrude to Cursor or Add's body, which `to_cursor` runs inside "
     + "`gate.editing`"),
    ("_blenderkit_selftest.py", "_gn_bmesh", "the Self-Test plays a script's own bmesh edit on purpose, in its "
     + "scratch scene, to check that the gate prices it at the leave of Edit Mode without reading freed memory"),
    ("_blenderkit_selftest.py", "_bmesh_modifiers", "the same, under Subdivision, Remesh, Bevel, Array and "
     + "Geometry Nodes"),
]
func bmeshEdits(_ allow: [(file: String, function: String, why: String)], replacing: [String: String] = [:]) -> [String] {
    var found: [String] = []
    let files = (try? FileManager.default.contentsOfDirectory(atPath: site.path)) ?? []
    for file in files.sorted() where file.hasPrefix("_blenderkit_") && file.hasSuffix(".py") && file != "_blenderkit_gate.py" {
        let lines = (replacing[file] ?? source(file)).components(separatedBy: "\n")
        var function = "", editingIndent: Int? = nil
        for (n, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let code = line.trimmingCharacters(in: .whitespaces)
            // The function a line is in: the outermost `def` (a nested one,
            // as the Knife's `in_selected_face`, is part of it).
            if line.hasPrefix("def ") {
                function = String(code.dropFirst(4).prefix { $0 != "(" })
                editingIndent = nil
            }
            if let open = editingIndent, !code.isEmpty, indent <= open { editingIndent = nil }
            if code.hasPrefix("with "), code.contains("editing(") || code.contains("_editing_gate(") {
                editingIndent = indent
                continue
            }
            guard line.contains("bmesh.update_edit_mesh(") else { continue }
            if editingIndent != nil { continue }
            if allow.contains(where: { $0.file == file && $0.function == function }) { continue }
            found.append("\(file):\(n + 1) in \(function)")
        }
    }
    return found
}
let looseEdits = bmeshEdits(bmeshAllowed)
check("every bmesh edit of an edited mesh in the app's Python is inside the gate's `editing` (or listed with why)",
      looseEdits.isEmpty, looseEdits.joined(separator: "; "))
let meshmenuText = source("_blenderkit_meshmenu.py")
check("Extrude to Cursor or Add's bmesh code runs inside `editing` (the review's 504,482 → 4,202,512)",
      meshmenuText.contains("    with gate.editing(what):\n        return _to_cursor("))
let toolsText = source("_blenderkit_tools.py")
let snapBare = toolsText.replacingOccurrences(of: "        with _editing_gate(\"Snap\"):\n", with: "        if True:\n")
let snapFound = bmeshEdits(bmeshAllowed, replacing: ["_blenderkit_tools.py": snapBare])
check("control: with Snap's `editing` taken out, the scan names its edit",
      snapBare != toolsText && snapFound.contains { $0.hasPrefix("_blenderkit_tools.py") && $0.hasSuffix("in snap") },
      snapFound.joined(separator: "; "))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
