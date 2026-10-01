import Foundation
import simd

// Three jobs, one binary, the halves of a modifier row's round trip.
//
// With no argument it prints every string the rows can send — `modifier_add`
// and then every one of `Bpy.modifierSettings` — for a headless Blender to run.
//
// With `--edit <case> <record>` it is the row mid-session: it reads the record
// Blender's own `_modifier_record` just produced, as the panel does, makes the
// case's change and prints exactly what `update` in PropertiesView sends for
// it (`Bpy.modifierEdit`). verify.py calls it from inside Blender, so what is
// checked is the round trip — Blender's state in, the Swift's edit out.
//
// With a path it reads the records Blender's own `_modifier_record` produced
// from that scene and checks the panel would show what was set. That is the
// half the Modifiers panel shipped without: its rows wrote to the display
// cache, reached Blender with nothing, and nothing came back to show it.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) < eps }

/// What a row sends for a freshly added modifier of `kind` after `change`.
func row(_ kind: ModifierKind, _ change: (inout Modifier) -> Void = { _ in }) -> String {
    var m = Modifier(kind: kind)
    change(&m)
    return ([Bpy.addModifier(kind.bpyType)] + Bpy.modifierSettings(m)).joined(separator: "\n")
}

let args = CommandLine.arguments

/// The change each `--edit` case makes to the modifier Blender reported.
let edits: [String: (inout Modifier) -> Void] = [
    // The target was deleted in Blender, so the record says none. The old row
    // still held the name, resent it with this edit and failed on it.
    "SHRINKWRAP_GONE": { $0.thickness = 0.07 },
    "WAVE_MOTION": { $0.waveX.toggle() },
    "MIRROR_Y": { $0.mirrorY.toggle() },
    "MIRROR_CLIP": { $0.mirrorClip.toggle() },
    "MIRROR_BISECT_Y": { $0.bisectY.toggle() },
    "MIRROR_DISTANCE": { $0.mergeThreshold = 0.0005 },
    // The Ratio field's own change: a ratio, and the type it needs.
    "DECIMATE_UNSUBDIV": { $0.ratio = 0.5; $0.decimateType = "COLLAPSE" },
    "REMESH_MODE": { $0.remeshMode = .blocks },
    "UNCHANGED": { _ in },
    // The row Shade Auto Smooth's modifier gets: its Angle, and its toggle.
    "SMOOTH_BY_ANGLE_ANGLE": { $0.angle = 5 * .pi / 180 },
    "SMOOTH_BY_ANGLE_IGNORE": { $0.ignoreSharpness = true },
    // A Geometry Nodes modifier whose inputs the row does not know.
    "NODES_OTHER": { $0.angle = 1; $0.ignoreSharpness = true },
    // The two switches every row has, on a kind with settings rows and on
    // one without.
    "VIEWPORT_OFF": { $0.showInViewport = false },
    "RENDER_OFF": { $0.showInRender = false },
    "OTHER_VIEWPORT_OFF": { $0.showInViewport = false },
    "WN_WEIGHT": { $0.weight = 70 },
    "LAPLACIAN_Z": { $0.smoothZ = false },
    "MULTIRES_LEVEL": { $0.levels = 1 },
    // The Lattice row's picker, from a record whose object is empty.
    "LATTICE_PICK": { $0.targetName = "Cage" },
    // The picker's None, from a record whose object is the cage.
    "LATTICE_CLEAR": { $0.targetName = "" },
]
if args.count == 5, args[1] == "--action" {
    // `--action <action> <modifier> <record>`: the header's control, or a
    // Multires button, on that modifier of Blender's record — printed as
    // `bridge.run` runs it on the real backend, inside `BpyModeGuard.wrap`.
    let record = (try? String(contentsOfFile: args[4], encoding: .utf8)) ?? ""
    let stack = Modifier.stack(from: record.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let action = ModifierRowAction(hookName: args[2]),
          let modifier = stack.first(where: { $0.name == args[3] })
    else {
        FileHandle.standardError.write(Data("no \(args[3]) in \(args[4]), or no action \(args[2])\n".utf8))
        exit(2)
    }
    if let command = action.command(for: modifier, in: stack) {
        print(BpyModeGuard.wrap(command.lines.joined(separator: "\n")))
    }
    exit(0)
}
if args.count == 4, args[1] == "--edit" {
    let record = (try? String(contentsOfFile: args[3], encoding: .utf8)) ?? ""
    guard let current = Modifier.stack(from: record.trimmingCharacters(in: .whitespacesAndNewlines)).first,
          let change = edits[args[2]]
    else {
        FileHandle.standardError.write(Data("no modifier in \(args[3]), or no case \(args[2])\n".utf8))
        exit(2)
    }
    var changed = current
    change(&changed)
    print(Bpy.modifierEdit(from: current, to: changed).joined(separator: "\n"))
    exit(0)
}

// `--remesh-floor <record> <positions>`: the Voxel Size row dragged to its
// floor, on an object whose stack is Blender's record and whose mesh on
// screen is Blender's evaluated one (x y z per vertex). Prints what the row
// sends.
if args.count == 4, args[1] == "--remesh-floor" {
    let record = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
    let numbers = ((try? String(contentsOfFile: args[3], encoding: .utf8)) ?? "")
        .split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Float($0) }
    let onScreen = MeshData(vertices: stride(from: 0, to: numbers.count - 2, by: 3).map {
        MeshVertex(SIMD3(numbers[$0], numbers[$0 + 1], numbers[$0 + 2]), SIMD3(0, 0, 1))
    }, indices: [])
    guard let current = Modifier.stack(from: record.trimmingCharacters(in: .whitespacesAndNewlines))
            .first(where: { $0.kind == .remesh })
    else {
        FileHandle.standardError.write(Data("no Remesh in \(args[2])\n".utf8))
        exit(2)
    }
    var changed = current
    // The row's clamp (PropertiesView), with the drag taken to 0.
    let floor = ModifierStack.remeshVoxelFloor(for: current, on: onScreen)
    changed.voxelSize = max(floor, min(0, max(2, floor)))
    print(Bpy.modifierEdit(from: current, to: changed).joined(separator: "\n"))
    exit(0)
}

if args.count < 2 {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

    // Non-default values throughout, so a value that came back is one that was
    // sent rather than one Blender happened to start with.
    emit("SHRINKWRAP", row(.shrinkwrap) {
        $0.targetName = "Target"; $0.wrapMethod = .nearestVertex; $0.thickness = 0.05
    })
    emit("SHRINKWRAP_NONE", row(.shrinkwrap))
    emit("SCREW", row(.screw) { $0.count = 8; $0.axis = 0; $0.thickness = 0.5 })
    emit("DECIMATE", row(.decimate) { $0.ratio = 0.25 })
    emit("REMESH_VOXEL", row(.remesh) { $0.voxelSize = 0.2 })
    emit("REMESH_BLOCKS", row(.remesh) { $0.remeshMode = .blocks; $0.octreeDepth = 5 })
    // An integer that was already here, and never came back: every number in
    // the record is float-formatted, and Int("2.0") is nil.
    emit("SUBSURF", row(.subdivision) { $0.levels = 2 })
    // Wave has Motion X and Y, not an axis. The old row's "Z" sent both off.
    emit("WAVE", row(.wave) { $0.waveX = false; $0.thickness = 0.3 })
    // All three axes in one assignment, which the simulator can take too.
    emit("MIRROR", row(.mirror) { $0.mirrorX = false; $0.mirrorZ = true })
    // Every one of the new rows off Blender's default.
    emit("MIRROR_FULL", row(.mirror) {
        $0.bisectX = true; $0.bisectFlipX = true; $0.bisectFlipZ = true
        $0.mirrorClip = true; $0.mirrorMerge = false; $0.mergeThreshold = 0.0025
    })
    // What Add Modifier sends for a Remesh on a 100 m cube: the default 0.1
    // raised to the floor for its size in the same evaluation.
    emit("REMESH_ADD_LARGE", Bpy.addModifier(.remesh, on: MeshBuilder.cube(size: 100))
            .joined(separator: "\n"))
    emit("REMESH_ADD_SMALL", Bpy.addModifier(.remesh, on: MeshBuilder.cube(size: 2))
            .joined(separator: "\n"))
    emit("REMESH_FLOOR_LARGE", String(ModifierStack.remeshVoxelFloor(for: MeshBuilder.cube(size: 100))))
    // Each --edit case's first step: the modifier the row will then change.
    emit("EDIT_SHRINKWRAP_GONE", row(.shrinkwrap) { $0.targetName = "Target"; $0.thickness = 0.02 })
    emit("EDIT_WAVE_MOTION", Bpy.addModifier(ModifierKind.wave.bpyType))
    emit("EDIT_MIRROR_Y", Bpy.addModifier(ModifierKind.mirror.bpyType))
    emit("EDIT_MIRROR_CLIP", Bpy.addModifier(ModifierKind.mirror.bpyType))
    emit("EDIT_MIRROR_BISECT_Y", Bpy.addModifier(ModifierKind.mirror.bpyType))
    emit("EDIT_MIRROR_DISTANCE", Bpy.addModifier(ModifierKind.mirror.bpyType))
    emit("EDIT_DECIMATE_UNSUBDIV", Bpy.addModifier(ModifierKind.decimate.bpyType))
    emit("EDIT_REMESH_MODE", Bpy.addModifier(ModifierKind.remesh.bpyType))
    emit("EDIT_UNCHANGED", Bpy.addModifier(ModifierKind.bevel.bpyType))
    // Blender's own operator makes the modifier; the row's edit is what is
    // checked (tests/objectmenu runs the app's own Shade Auto Smooth).
    emit("EDIT_SMOOTH_BY_ANGLE_ANGLE", "bpy.ops.object.shade_auto_smooth()")
    emit("EDIT_SMOOTH_BY_ANGLE_IGNORE", "bpy.ops.object.shade_auto_smooth()")
    emit("EDIT_NODES_OTHER", Bpy.addModifier(ModifierKind.geometryNodes.bpyType)
            + "\nbpy.context.object.modifiers[-1].node_group = bpy.data.node_groups.new('Twist', 'GeometryNodeTree')")

    // The six kinds made first-class with every-modifier rows, each off
    // Blender's defaults in every setting its row has.
    emit("WEIGHTED_NORMAL", row(.weightedNormal) {
        $0.weightMode = .cornerAngle; $0.weight = 70; $0.threshold = 0.5
        $0.keepSharp = true; $0.faceInfluence = true
    })
    // Multires's levels are clamped to what Subdivide made, so the row's two
    // Subdivide presses go first.
    var multires = Modifier(kind: .multires)
    multires.levels = 1; multires.sculptLevels = 2; multires.renderLevels = 2
    emit("MULTIRES", ([Bpy.addModifier("MULTIRES"), Bpy.multires(.subdivide, "Multires"),
                       Bpy.multires(.subdivide, "Multires")] + Bpy.modifierSettings(multires))
            .joined(separator: "\n"))
    // 5 degrees: the check's UV sphere has its faces meeting at 11.25, so at
    // Blender's 30 nothing would split and the edit could not be seen.
    emit("EDGE_SPLIT", row(.edgeSplit) { $0.angle = 5 * .pi / 180; $0.edgeSplitSharp = false })
    emit("LAPLACIANSMOOTH", row(.laplacianSmooth) {
        $0.iterations = 4; $0.lambdaFactor = 0.5; $0.lambdaBorder = 0.2; $0.smoothY = false
        $0.preserveVolume = false; $0.normalized = false
    })
    emit("CORRECTIVE_SMOOTH", row(.correctiveSmooth) {
        $0.factor = 0.3; $0.iterations = 8; $0.smoothScale = 2; $0.smoothType = .lengthWeighted
        $0.onlySmooth = true; $0.pinBoundary = true
    })
    emit("LATTICE", row(.lattice) { $0.thickness = 0.5; $0.targetName = "Cage" })
    // The row a Lattice gets before anything is picked.
    emit("LATTICE_NONE", row(.lattice))
    emit("EDIT_VIEWPORT_OFF", Bpy.addModifier(ModifierKind.weightedNormal.bpyType))
    emit("EDIT_RENDER_OFF", Bpy.addModifier(ModifierKind.edgeSplit.bpyType))
    emit("EDIT_OTHER_VIEWPORT_OFF", Bpy.addModifier("WIREFRAME"))
    emit("EDIT_WN_WEIGHT", Bpy.addModifier(ModifierKind.weightedNormal.bpyType))
    emit("EDIT_LAPLACIAN_Z", Bpy.addModifier(ModifierKind.laplacianSmooth.bpyType))
    emit("EDIT_MULTIRES_LEVEL", [Bpy.addModifier("MULTIRES"), Bpy.multires(.subdivide, "Multires"),
                                 Bpy.multires(.subdivide, "Multires")].joined(separator: "\n"))
    emit("EDIT_LATTICE_PICK", Bpy.addModifier(ModifierKind.lattice.bpyType))
    emit("EDIT_LATTICE_CLEAR", Bpy.addModifier(ModifierKind.lattice.bpyType))
    // The header's controls as the simulator's stand-in gets them
    // (tests/modifiers/shim.py): a Subdivision above a Wave.
    let pair = [Modifier(kind: .subdivision), Modifier(kind: .wave)]
    for (name, action, target) in [("SHIM_UP_WAVE", ModifierRowAction.moveUp, 1),
                                   ("SHIM_DOWN_SUBSURF", .moveDown, 0),
                                   ("SHIM_APPLY_SUBSURF", .apply, 0),
                                   ("SHIM_REMOVE_WAVE", .remove, 1),
                                   ("SHIM_VIEWPORT_WAVE", .toggleViewport, 1)] {
        emit(name, action.command(for: pair[target], in: pair)!.lines.joined(separator: "\n"))
    }
    // Where a row with no settings of its own opens the Every Property
    // browser, for a modifier named with the record's separators.
    emit("DATA_PATH_ODD", Bpy.modifierDataPath("a;b|c=d%e"))
    // A move the row never offers, to see the refusal: past the top.
    emit("SHIM_UP_FIRST", Bpy.moveModifier("Subdivision", up: true))
    for op in Bpy.MultiresOperation.allCases {
        emit("SHIM_MULTIRES_" + op.rawValue, Bpy.multires(op, "Multires"))
    }
    print(out.joined(separator: "\n#--\n"))
    exit(0)
}

var records: [String: String] = [:]
for chunk in (try! String(contentsOfFile: args[1], encoding: .utf8)).components(separatedBy: "#--") {
    let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("### "), let nl = trimmed.firstIndex(of: "\n") else { continue }
    let head = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<nl])
    records[head] = String(trimmed[trimmed.index(after: nl)...])
}
func only(_ name: String) -> Modifier? {
    let stack = Modifier.stack(from: records[name] ?? "")
    check("\(name): Blender's record parses to one modifier", stack.count == 1,
          records[name] ?? "<no record>")
    return stack.first
}

print("\nBlender's record, read back as the panel reads it")
if let m = only("SHRINKWRAP") {
    check("Shrinkwrap target", m.targetName == "Target", m.targetName)
    check("Shrinkwrap wrap_method", m.wrapMethod == .nearestVertex, "\(m.wrapMethod)")
    check("Shrinkwrap offset", close(m.thickness, 0.05), "\(m.thickness)")
}
if let m = only("SHRINKWRAP_NONE") {
    check("an unset target reads as empty, so the row can say so", m.targetName.isEmpty, m.targetName)
}
if let m = only("SCREW") {
    check("Screw steps", m.count == 8, "\(m.count)")
    check("Screw axis X", m.axis == 0, "\(m.axis)")
    check("Screw screw_offset", close(m.thickness, 0.5), "\(m.thickness)")
    check("Screw angle", close(m.angle, 2 * .pi, 1e-3), "\(m.angle)")
}
if let m = only("DECIMATE") {
    check("Decimate ratio", close(m.ratio, 0.25), "\(m.ratio)")
    check("Decimate type", m.decimateType == "COLLAPSE", m.decimateType)
    let expected = Int(records["DECIMATE_FACES"] ?? "") ?? -1
    check("Decimate face_count is Blender's evaluated face count",
          m.faceCount == expected && expected > 0, "\(m.faceCount) vs \(expected)")
}
if let m = only("REMESH_VOXEL") {
    check("Remesh VOXEL mode", m.remeshMode == .voxel, "\(m.remeshMode)")
    check("Remesh voxel_size", close(m.voxelSize, 0.2), "\(m.voxelSize)")
}
if let m = only("REMESH_BLOCKS") {
    check("Remesh BLOCKS mode", m.remeshMode == .blocks, "\(m.remeshMode)")
    check("Remesh octree_depth", m.octreeDepth == 5, "\(m.octreeDepth)")
}
if let m = only("SUBSURF") {
    check("Subdivision levels comes back as 2, not the default 1", m.levels == 2, "\(m.levels)")
}
if let m = only("WAVE") {
    check("Wave Motion X comes back off", !m.waveX, "\(m.waveX)")
    check("Wave Motion Y comes back on", m.waveY, "\(m.waveY)")
    check("Wave height", close(m.thickness, 0.3), "\(m.thickness)")
}
if let m = only("MIRROR") {
    check("Mirror axes come back as sent", !m.mirrorX && !m.mirrorY && m.mirrorZ,
          "\(m.mirrorX) \(m.mirrorY) \(m.mirrorZ)")
}
if let m = only("MIRROR_FULL") {
    check("Mirror Bisect comes back as sent", m.bisectX && !m.bisectY && !m.bisectZ,
          "\(m.bisectX) \(m.bisectY) \(m.bisectZ)")
    check("Mirror Flip comes back as sent", m.bisectFlipX && !m.bisectFlipY && m.bisectFlipZ,
          "\(m.bisectFlipX) \(m.bisectFlipY) \(m.bisectFlipZ)")
    check("Mirror Clipping on and Merge off come back", m.mirrorClip && !m.mirrorMerge)
    check("Mirror's merge distance comes back", close(m.mergeThreshold, 0.0025, 1e-7), "\(m.mergeThreshold)")
    check("and it is on in the viewport", m.showInViewport)
    check("so the drag's preview clips on X at that distance",
          MirrorClip.clipping([m]) == [MirrorClip(axes: [true, false, false], tolerance: m.mergeThreshold)])
}
if let m = only("MIRROR") {
    check("a Mirror nobody set these on reads Blender's defaults",
          !m.bisectX && !m.bisectFlipX && !m.mirrorClip && m.mirrorMerge && close(m.mergeThreshold, 0.001, 1e-7),
          "\(m.mirrorClip) \(m.mirrorMerge) \(m.mergeThreshold)")
}
if let m = only("REMESH_ADD_LARGE") {
    check("a Remesh added to a 100 m cube starts at its floor, not 0.1",
          close(m.voxelSize, 100 / 256, 1e-5), "\(m.voxelSize)")
}
if let m = only("REMESH_ADD_SMALL") {
    check("one added to a 2 m cube keeps Blender's 0.1", close(m.voxelSize, 0.1, 1e-6), "\(m.voxelSize)")
}
if let m = only("NODES_EMPTY") {
    check("an empty Geometry Nodes modifier has a row, with no group",
          m.kind == .geometryNodes && m.nodeGroup.isEmpty && !m.smoothByAngle, "\(m.kind) \(m.nodeGroup)")
}
if let m = only("NODES_OTHER") {
    check("one with another group has a row naming it, and no Smooth by Angle numbers",
          m.kind == .geometryNodes && m.nodeGroup == "Twist" && !m.smoothByAngle, "\(m.kind) \(m.nodeGroup)")
    check("so it sends nothing", Bpy.modifierSettings(m).isEmpty)
}

print("\nEvery modifier Blender can put on a mesh, read back as the panel reads it")
// verify.py adds every type `modifier_add` takes on a mesh to one cube, and
// writes Blender's own list of (name, type) beside the record the mirror sent.
let expected = (records["ALL_TYPES_EXPECTED"] ?? "").split(separator: "\n").map {
    $0.split(separator: "\t", maxSplits: 1).map(String.init)
}
let all = Modifier.stack(from: records["ALL_TYPES"] ?? "")
check("Blender put more than fifty modifiers on the cube", expected.count > 50, "\(expected.count)")
check("the panel has a row for every one of them", all.count == expected.count,
      "\(all.count) rows for \(expected.count)")
check("in Blender's order, by name", all.map(\.name) == expected.map { $0.first ?? "" },
      zip(all.map(\.name), expected.map { $0.first ?? "" }).filter { $0 != $1 }.prefix(3).map { "\($0) vs \($1)" }
          .joined(separator: ", "))
check("each carrying Blender's type", all.map(\.blenderType) == expected.map { $0.last ?? "" },
      zip(all.map(\.blenderType), expected.map { $0.last ?? "" }).filter { $0 != $1 }.prefix(3)
          .map { "\($0) vs \($1)" }.joined(separator: ", "))
check("every kind with settings rows is read as that kind, the rest as `.other`",
      all.allSatisfy { ($0.kind == .other) == (ModifierKind.modelled($0.blenderType) == nil) })
check("and every `.other` row is named by Blender's name for its type",
      all.filter { $0.kind == .other }.allSatisfy { !$0.typeLabel.isEmpty && $0.typeLabel != $0.blenderType },
      all.filter { $0.kind == .other && $0.typeLabel == $0.blenderType }.map(\.blenderType).joined(separator: " "))
let labels = Dictionary(all.map { ($0.blenderType, $0.typeLabel) }, uniquingKeysWith: { a, _ in a })
check("Surface Deform, Mesh Deform and Volume to Mesh by their names in Blender's menu",
      labels["SURFACE_DEFORM"] == "Surface Deform" && labels["MESH_DEFORM"] == "Mesh Deform"
          && labels["VOLUME_TO_MESH"] == "Volume to Mesh", "\(labels)")

print("\nThe stack round 2's reviewer measured, which showed the Subdivision alone")
let reviewer = Modifier.stack(from: records["REVIEWER"] ?? "")
check("five rows", reviewer.map(\.kind) == [.multires, .weightedNormal, .edgeSplit, .laplacianSmooth, .subdivision],
      "\(reviewer.map(\.kind))")
if reviewer.count == 5 {
    check("with Blender's defaults: Multires at no level", reviewer[0].totalLevels == 0 && reviewer[0].levels == 0)
    check("Weighted Normal at 50, Face Area, 0.01", reviewer[1].weight == 50 && reviewer[1].weightMode == .faceArea
              && close(reviewer[1].threshold, 0.01))
    check("Edge Split at 30 degrees", close(reviewer[2].angle, .pi / 6))
    check("Laplacian Smooth once at 0.01", reviewer[3].iterations == 1 && close(reviewer[3].lambdaFactor, 0.01))
    check("all on in the viewport and the render", reviewer.allSatisfy { $0.showInViewport && $0.showInRender })
}

print("\nThe six new rows, read back from Blender")
if let m = only("WEIGHTED_NORMAL") {
    check("Weighted Normal: Corner Angle, 70, 0.5, Keep Sharp, Face Influence",
          m.weightMode == .cornerAngle && m.weight == 70 && close(m.threshold, 0.5) && m.keepSharp && m.faceInfluence,
          "\(m.weightMode) \(m.weight) \(m.threshold) \(m.keepSharp) \(m.faceInfluence)")
}
if let m = only("MULTIRES") {
    check("Multires: two levels made, viewport 1, sculpt and render 2",
          m.totalLevels == 2 && m.levels == 1 && m.sculptLevels == 2 && m.renderLevels == 2,
          "\(m.totalLevels) \(m.levels) \(m.sculptLevels) \(m.renderLevels)")
}
if let m = only("EDGE_SPLIT") {
    check("Edge Split: 5 degrees, Sharp Edges off", close(m.angle, 5 * .pi / 180) && m.edgeSplitAngle
              && !m.edgeSplitSharp, "\(m.angle)")
}
if let m = only("LAPLACIANSMOOTH") {
    check("Laplacian Smooth: 4 at 0.5, border 0.2, Y off, volume and normalized off",
          m.iterations == 4 && close(m.lambdaFactor, 0.5) && close(m.lambdaBorder, 0.2) && m.smoothX
              && !m.smoothY && m.smoothZ && !m.preserveVolume && !m.normalized)
}
if let m = only("CORRECTIVE_SMOOTH") {
    check("Corrective Smooth: 0.3, 8, scale 2, Length Weight, Only Smooth, Pin Boundaries",
          close(m.factor, 0.3) && m.iterations == 8 && close(m.smoothScale, 2) && m.smoothType == .lengthWeighted
              && m.onlySmooth && m.pinBoundary && m.restSource == "ORCO")
}
if let m = only("LATTICE") {
    check("Lattice: the cage, at 0.5", m.targetName == "Cage" && close(m.thickness, 0.5), "\(m.targetName) \(m.thickness)")
}
if let m = only("LATTICE_NONE") {
    check("a Lattice with nothing picked reads empty, so the row can say so", m.targetName.isEmpty && m.thickness == 1)
}
if let m = only("LATTICE_MESH") {
    check("and one a script pointed at a mesh reads empty too: Blender dropped it", m.targetName.isEmpty,
          m.targetName)
}

if let m = only("UNREAD") {
    // The row then has the header alone; its switches are Blender's, and its
    // text says the settings could not be read, since Subdivision Surface
    // does have rows here (PropertiesView's `.other` case).
    check("an unread Subdivision is a header row with Blender's switches: viewport off, render on",
          m.kind == .other && m.blenderType == "SUBSURF" && !m.showInViewport && m.showInRender
              && ModifierKind.modelled(m.blenderType) == .subdivision,
          "\(m.kind) \(m.blenderType) \(m.showInViewport) \(m.showInRender)")
}

print("\nA name with the record's separators in it, read back from Blender")
let odd = Modifier.stack(from: records["ODD_NAME"] ?? "")
check("two rows, the first named as Blender names it",
      odd.map(\.name) == ["a;b|c=d%e", "Subdivision"] && odd.first?.blenderType == "WIREFRAME"
          && odd.last?.levels == 1, "\(odd.map(\.name))")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
