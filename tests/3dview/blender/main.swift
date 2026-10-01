import Foundation
import simd
import CoreGraphics

// Two jobs, one binary.
//
//   dump                  every string the 3D View sends for the behaviour
//                         checked here, printed for a headless Blender to run.
//                         For the transforms, what the drag's preview left
//                         behind is printed too, so Blender's result can be
//                         held against it: a drag that previews one shape and
//                         commits another is the failure worth catching.
//   dump <records.json>   what Blender's mirror sent for each Set Origin and
//                         Apply scenario, and what Blender's operators then
//                         did, put through the Swift that greys those menus'
//                         rows out (ObjectTransformState). A greyed row has to
//                         be a true statement about Blender's scene.

if CommandLine.arguments.count > 1 {
    exit(replayObjectTransformRecords(CommandLine.arguments[1]))
}

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func numbers(_ values: [Float]) -> String {
    values.map { String(format: "%.6f", $0) }.joined(separator: " ")
}

// MARK: commands

emit("TOGGLE", Bpy.toggleEditMode)
emit("MODE_EDIT", Bpy.setMode(.edit))
emit("MODE_OBJECT", Bpy.setMode(.object))
emit("MODE_SCULPT", Bpy.setMode(.sculpt))
emit("LEAVEBRUSH", Bpy.leaveBrushMode)
// As `BpyBridge.run` sends them: bracketed by the mode guard.
emit("EDIT_SELECTALL", BpyModeGuard.wrap(Bpy.selectAll(editing: true)))
emit("EDIT_DESELECTALL", BpyModeGuard.wrap(Bpy.deselectAll(editing: true)))
emit("EDIT_INVERT", BpyModeGuard.wrap(Bpy.invertSelection(editing: true)))
emit("EDIT_DELETE_FACE", BpyModeGuard.wrap(Bpy.deleteSelection(editing: true, mode: .face)))
emit("SELECTMODE_EDGE", BpyModeGuard.wrap(Bpy.setSelectMode(.edge)))
// The operator form, which used to be sent VERTEX.
emit("SELECTMODE_OPERATOR", BpyModeGuard.wrap(Bpy.meshSelectMode(.face)))

// MARK: the viewport's selection, handed to Blender — Blender's cube has 8 vertices and 6 faces

emit("PUSH_VERT", Bpy.pushEditSelection(object: "Cube", mode: .vertex, vertices: [0, 1],
                                        vertexCount: 8, polygonCount: 6))
emit("PUSH_ALLVERTS", Bpy.pushEditSelection(object: "Cube", mode: .vertex, vertices: Array(0..<8),
                                            vertexCount: 8, polygonCount: 6))
emit("PUSH_FACE", Bpy.pushEditSelection(object: "Cube", mode: .face, polygons: [2],
                                        vertexCount: 8, polygonCount: 6))
// Vertex 0 paired with every other vertex: three of the pairs are edges.
emit("PUSH_EDGE", Bpy.pushEditSelection(object: "Cube", mode: .edge, edges: (1...7).map { (0, $0) },
                                        vertexCount: 8, polygonCount: 6))
emit("PUSH_STALE", Bpy.pushEditSelection(object: "Cube", mode: .vertex, vertices: [0],
                                         vertexCount: 9, polygonCount: 6))
do {
    // A mesh the mirror could not line up goes by position.
    let cube = BKObject(name: "Cube", kind: .cube)
    var selection = EditSelection()
    selection.vertices = Set(cube.mesh.vertices.indices.filter { cube.mesh.vertices[$0].position.x > 0 })
    emit("PUSH_POSITIONS", Bpy.pushEditSelection(selection, mode: .vertex, of: cube))
}

// MARK: mesh and add operators, as `perform` sends them

let pushFace = Bpy.pushEditSelection(object: "Cube", mode: .face, polygons: [2],
                                     vertexCount: 8, polygonCount: 6)
let inset = LastOperator.mesh(.inset)
emit("PERFORM_INSET_PUSHED",
     BpyBridge.script(push: pushFace, discardBackup: false, body: BpyBridge.performBody(for: inset)))
var rerun = inset
rerun.subject = "@SUBJECT@"
rerun["thickness"] = 0.2
emit("RERUN_INSET", rerun.rerunPython)
emit("PERFORM_BEVEL",
     BpyBridge.script(push: nil, discardBackup: true,
                      body: BpyBridge.performBody(for: LastOperator.mesh(.bevel))))
emit("PERFORM_ADD",
     BpyBridge.script(push: nil, discardBackup: false,
                      body: BpyBridge.performBody(for: LastOperator.add(.cube, at: SIMD3(0.5, -1, 2)))))

// MARK: Set Origin and Apply Transform, as the menus send them

/// Records what reaches the interpreter, as a device's runtime receives it.
final class RecordingRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = false
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
}

do {
    // Through `BpyBridge.setOrigin` and `applyTransform` — the calls the
    // menus make — and `run(_:undo:setup:)` itself, rather than a copy of how
    // it joins `setup:` to the operator: that join is what keeps the mode
    // guard's OBJECT bracket, and a copy would pass whatever it did.
    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    undo.seed(scene)
    let runtime = RecordingRuntime()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    var labels: [String] = []
    func sent(_ body: () -> BpyBridge.Outcome) -> String {
        let before = runtime.sources.count
        _ = body()
        labels.append(undo.undoName ?? "-")
        return runtime.sources.count > before ? runtime.sources[runtime.sources.count - 1] : ""
    }
    emit("ORIGIN_GEOMETRY_MEDIAN", sent { bridge.setOrigin(Bpy.OriginChoice(.originToGeometry)) })
    emit("ORIGIN_GEOMETRY_BOUNDS", sent { bridge.setOrigin(Bpy.OriginChoice(.originToGeometry, .bounds)) })
    emit("GEOMETRY_TO_ORIGIN", sent { bridge.setOrigin(Bpy.OriginChoice(.geometryToOrigin)) })
    emit("ORIGIN_CURSOR", sent { bridge.setOrigin(Bpy.OriginChoice(.cursor)) })
    emit("ORIGIN_CENTER_OF_MASS", sent { bridge.setOrigin(Bpy.OriginChoice(.centerOfMass)) })
    emit("ORIGIN_CENTER_OF_VOLUME", sent { bridge.setOrigin(Bpy.OriginChoice(.centerOfVolume)) })
    for what in Bpy.AppliedTransform.allCases {
        emit("APPLY_" + what.rawValue.uppercased(), sent { bridge.applyTransform(what) })
    }
    // What the Undo menu names each step, for Blender's own label to be held to.
    emit("OBJECT_OP_UNDO_NAMES", labels.joined(separator: "\n"))
}

// Which types each operator acts on, as the menus and the guard decide it, for
// Blender to confirm one object of each type at a time. The second field is a
// light's kind, or INSTANCE for an empty that instances a collection.
let reachTypes: [(String, String?)] = [
    ("MESH", nil), ("CURVE", nil), ("SURFACE", nil), ("FONT", nil), ("META", nil),
    ("ARMATURE", nil), ("LATTICE", nil), ("EMPTY", nil), ("EMPTY", "INSTANCE"), ("CAMERA", nil),
    ("LIGHT", "POINT"), ("LIGHT", "SUN"), ("LIGHT", "SPOT"), ("LIGHT", "AREA"),
    ("SPEAKER", nil), ("LIGHT_PROBE", nil), ("VOLUME", nil),
    ("CURVES", nil), ("POINTCLOUD", nil), ("GREASEPENCIL", nil),
]
emit("REACH", reachTypes.map { type, variant in
    let light = type == "LIGHT" ? variant : nil
    let instances: Bool? = type == "EMPTY" ? variant == "INSTANCE" : nil
    let origin = Bpy.originReach.acts(onType: type, lightKind: light, instancesCollection: instances) ? 1 : 0
    let apply = Bpy.applyReach.acts(onType: type, lightKind: light, instancesCollection: instances) ? 1 : 0
    return "\(type) \(variant ?? "-") \(origin) \(apply)"
}.joined(separator: "\n"))

// MARK: a tap, and a sculpt stroke

emit("TAP_SELECT", BpyBridge.selectionScript(Bpy.select("Target")))
emit("SCULPT_WRITE", Bpy.writeSculpt(of: "Cube"))

// MARK: transforms, with where the preview put things

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

/// Runs one drag through the real session — make, begin, resolve, apply — and
/// returns the Python the release would send.
func drag(_ mode: TransformGizmo.Mode, handle: TransformGizmo.Handle, in scene: BKScene,
          from: (CGPoint, TransformGizmo) -> CGPoint,
          to: (CGPoint, TransformGizmo) -> CGPoint) -> String {
    let g = TransformGizmo.make(mode: mode, scene: scene, options: options, camera: camera, size: size)!
    let centre = TransformGizmo.Projection(camera: camera, size: size).project(g.origin)!
    let session = TransformGizmo.beginSession(handle: handle, at: from(centre, g), gizmo: g,
                                              scene: scene, camera: camera, size: size,
                                              options: options)
    let result = TransformGizmo.resolve(session, at: to(centre, g))!
    TransformGizmo.apply(result, session: session)
    return TransformGizmo.python(result, session: session)
}

/// A point along a handle's shaft, `reach` shaft-lengths out from the centre.
func along(_ axis: Int, _ reach: CGFloat) -> (CGPoint, TransformGizmo) -> CGPoint {
    { centre, g in
        let tip = TransformGizmo.Projection(camera: camera, size: size)
            .project(g.origin + g.axes[axis] * g.radius)!
        return CGPoint(x: centre.x + (tip.x - centre.x) * reach,
                       y: centre.y + (tip.y - centre.y) * reach)
    }
}

func rotationRows(_ o: BKObject) -> [Float] {
    let m = o.modelMatrix
    return (0..<3).flatMap { row in (0..<3).map { column in m[column][row] } }
}

func positions(_ o: BKObject) -> [Float] {
    o.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }
}

do {
    // The outer ring, which used to send orient_axis='VIEW'.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = .zero
    o.rotation = SIMD3(0.2, -0.3, 0.4)
    s.selection = [o.id]; s.activeID = o.id
    let start = o.rotation
    let python = drag(.rotate, handle: .screen, in: s,
                      from: { c, _ in CGPoint(x: c.x + 150, y: c.y + 10) },
                      to: { c, _ in CGPoint(x: c.x + 20, y: c.y + 140) })
    emit("ROTATE_VIEW_OBJECT", python)
    emit("ROTATE_VIEW_OBJECT_START", numbers([start.x, start.y, start.z]))
    emit("ROTATE_VIEW_OBJECT_EXPECT", numbers(rotationRows(o)))
}
do {
    // A Z ring, the path that already worked, as a control.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.rotation = SIMD3(0.1, 0.2, 0.3)
    s.selection = [o.id]; s.activeID = o.id
    let start = o.rotation
    let python = drag(.rotate, handle: .axis(2), in: s,
                      from: { c, _ in CGPoint(x: c.x + 100, y: c.y) },
                      to: { c, _ in CGPoint(x: c.x, y: c.y + 100) })
    emit("ROTATE_AXIS_OBJECT", python)
    emit("ROTATE_AXIS_OBJECT_START", numbers([start.x, start.y, start.z]))
    emit("ROTATE_AXIS_OBJECT_EXPECT", numbers(rotationRows(o)))
}
do {
    // The outer ring while editing, every vertex selected.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = SIMD3(1, 2, 0)
    s.selection = [o.id]; s.activeID = o.id
    s.mode = .edit
    s.editSelection.vertices = Set(o.mesh.vertices.indices)
    let python = drag(.rotate, handle: .screen, in: s,
                      from: { c, _ in CGPoint(x: c.x + 150, y: c.y + 10) },
                      to: { c, _ in CGPoint(x: c.x + 20, y: c.y + 140) })
    emit("ROTATE_VIEW_EDIT", python)
    emit("ROTATE_VIEW_EDIT_EXPECT", numbers(positions(o)))
}
do {
    // Scale along the local X of an object turned 45°.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = .zero
    o.rotation = SIMD3(0, 0, .pi / 4)
    s.selection = [o.id]; s.activeID = o.id
    let python = drag(.scale, handle: .axis(0), in: s, from: along(0, 1), to: along(0, 2))
    emit("SCALE_LOCAL_OBJECT", python)
    emit("SCALE_LOCAL_OBJECT_START", numbers([0, 0, .pi / 4]))
    emit("SCALE_LOCAL_OBJECT_EXPECT", numbers([o.scale.x, o.scale.y, o.scale.z]))
}
do {
    // The same while editing.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = SIMD3(0.5, -0.5, 0)
    o.rotation = SIMD3(0, 0, .pi / 4)
    s.selection = [o.id]; s.activeID = o.id
    s.mode = .edit
    s.editSelection.vertices = Set(o.mesh.vertices.indices)
    let python = drag(.scale, handle: .axis(0), in: s, from: along(0, 1), to: along(0, 1.6))
    emit("SCALE_LOCAL_EDIT", python)
    emit("SCALE_LOCAL_EDIT_EXPECT", numbers(positions(o)))
}
do {
    // Two objects turned by different amounts, scaled together.
    let s = BKScene(startupFile: false)
    let a = s.add(.cube); a.location = SIMD3(2, 0, 0); a.rotation = SIMD3(0, 0, .pi / 4)
    let b = s.add(.cube); b.location = SIMD3(-2, 1, 0); b.rotation = SIMD3(0, 0, .pi / 6)
    s.selection = [a.id, b.id]; s.activeID = a.id
    let python = drag(.scale, handle: .axis(0), in: s, from: along(0, 1), to: along(0, 1.8))
    emit("SCALE_LOCAL_MULTI", python)
    emit("SCALE_LOCAL_MULTI_EXPECT", numbers([a.location.x, a.location.y, a.location.z,
                                              a.scale.x, a.scale.y, a.scale.z,
                                              b.location.x, b.location.y, b.location.z,
                                              b.scale.x, b.scale.y, b.scale.z]))
}

print(out.joined(separator: "\n#--\n"))

// MARK: replay — Blender's records through ObjectTransformState

/// Returns the exit status.
func replayObjectTransformRecords(_ path: String) -> Int32 {
    var failures = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
        if !ok { failures += 1 }
    }
    guard let data = FileManager.default.contents(atPath: path),
          let scenarios = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          !scenarios.isEmpty
    else {
        print("  FAIL  no scenarios in \(path)")
        return 1
    }

    // A refusal counts for an offered row only when it is Blender's own. The
    // guard's refusals begin with the operator's name ("Set Origin does
    // nothing to …", "… needs a selected object."), and one of those on a row
    // the menu offers is the guard disagreeing with the menu — which is what
    // turned a collection instance away while its row stood open.
    func saidByBlender(_ sent: String, not reach: Bpy.ObjectReach) -> Bool {
        sent.hasPrefix("refused") && !sent.hasPrefix("refused: \(reach.name) ")
    }

    print("\nSet Origin and Apply, greyed out only where Blender would change nothing")
    var byName: [String: (state: ObjectTransformState, worldScale: SIMD3<Float>?)] = [:]
    for record in scenarios {
        let name = record["name"] as? String ?? "?"
        let scene = BKScene(startupFile: false)
        scene.objects = []
        var selection = Set<UUID>()
        var activeWorldScale: SIMD3<Float>?
        for o in record["objects"] as? [[String: Any]] ?? [] {
            // As bk_sync_push, bk_sync_display and bk_sync_local build it.
            let object = BKObject(name: o["name"] as? String ?? "?", kind: .cube)
            let kind = (o["kind"] as? String ?? "MESH").components(separatedBy: "|")
            object.blenderType = kind[0]
            object.visible = !kind.contains("hidden")
            if let m = o["matrix"] as? [Double], m.count == 16 {
                var matrix = simd_float4x4()
                for c in 0..<4 {
                    matrix[c] = SIMD4(Float(m[c]), Float(m[4 + c]), Float(m[8 + c]), Float(m[12 + c]))
                }
                object.setMirroredTransform(matrix)
            }
            if let d = o["display"] as? [String], d.count == 3 {
                object.display = ObjectDisplay(type: d[0], dataName: d[1], record: d[2])
            }
            if let values = o["local"] as? [Double] {
                object.localTransform = LocalTransform(values)
            }
            scene.objects.append(object)
            if o["selected"] as? Bool == true { selection.insert(object.id) }
            if o["active"] as? Bool == true {
                scene.activeID = object.id
                activeWorldScale = object.scale
            }
        }
        scene.selection = selection
        let state = ObjectTransformState(scene: scene, editing: false, isRunning: false)
        byName[name] = (state, activeWorldScale)

        let apply = record["apply"] as? [String: [String: String]] ?? [:]
        for what in Bpy.AppliedTransform.allCases {
            guard let outcome = apply[what.rawValue] else {
                check("\(name): Blender's outcome for \(what.title) was recorded", false)
                continue
            }
            let bare = outcome["bare"] ?? "?", sent = outcome["sent"] ?? "?"
            if state.offers(what) {
                check("\(name): \(what.title) is offered, and Blender changes something or says why not",
                      sent == "changed" || saidByBlender(sent, not: Bpy.applyReach), "sent: \(sent)")
            } else {
                check("\(name): \(what.title) is greyed out, and Blender would change nothing",
                      bare != "changed", "bare: \(bare)")
            }
        }
        if let origin = record["origin"] as? [String: String] {
            let offered = state.enabled && state.canSetOrigin
            let bare = origin["bare"] ?? "?", sent = origin["sent"] ?? "?"
            check(offered ? "\(name): Set Origin is offered, and Blender moves an origin or says why not"
                          : "\(name): Set Origin is greyed out, and Blender would move nothing",
                  offered ? (sent == "changed" || saidByBlender(sent, not: Bpy.originReach)) : bare != "changed",
                  "bare: \(bare), sent: \(sent)")
        }
        if let scale = record["scale"] as? [Double], scale.count == 3 {
            let blender = SIMD3(Float(scale[0]), Float(scale[1]), Float(scale[2]))
            let bakes = any(abs(blender - 1) .> LocalTransform.tolerance)
            let shown = state.activeScale
            check("\(name): the subtitle under Apply Scale is Blender's own scale, sign and all",
                  bakes ? (shown.map { all(abs($0 - blender) .< 1e-4) } ?? false) : shown == nil,
                  "shown \(String(describing: shown)), Blender \(blender)")
        }
    }

    // The cases that were wrong, by name, so a scenario silently dropped from
    // verify.py cannot turn the loop above into a pass.
    print("\nthe cases the world matrix got wrong")
    func state(_ name: String) -> ObjectTransformState? {
        let found = byName[name]?.state
        check("\(name) was recorded", found != nil)
        return found
    }
    if let s = state("mirrored") {
        check("a mirrored object offers Apply Scale, which flips its normals", s.offers(.scale))
        check("and does not offer Apply Rotation for a rotation of zero", !s.offers(.rotation))
        check("and says -1", s.activeScale.map { $0.x < 0 } ?? false, String(describing: s.activeScale))
    }
    if let s = state("child_of_small") {
        check("a child at scale 1 under a 0.01 parent does not offer Apply Scale", !s.offers(.scale))
    }
    if let s = state("child_x100") {
        check("a child at scale 100 under a 0.01 parent does", s.offers(.scale))
    }
    for name in ["turned_45", "turned_10", "noise"] {
        if let s = state(name) {
            check("\(name): float noise does not offer Apply Scale, nor a \"1 × 1 × 1\" subtitle",
                  !s.offers(.scale) && s.activeScale == nil, String(describing: s.activeScale))
        }
    }
    if let s = state("area_x2") {
        check("an area light's Apply menu is open", s.canApply)
        check("and offers Apply Scale", s.offers(.scale))
    }
    if let s = state("point_x2") {
        check("a point light's is greyed out", !s.canApply)
    }
    if let s = state("instance") {
        check("an empty instancing a collection offers Set Origin, which moves it", s.enabled && s.canSetOrigin)
    }
    if let s = state("empty_x2") {
        check("and a plain empty does not", !s.canSetOrigin)
    }
    if let s = state("no_active") {
        check("a selection with no active object offers both menus, as Blender acts on it",
              s.enabled && s.canSetOrigin && s.offers(.scale))
    }
    if let s = state("scale_1_0002") {
        check("a scale of 1.0002 is offered, and its subtitle does not read 1 × 1 × 1",
              s.offers(.scale) && s.activeScaleText == "1.0002 × 1 × 1", s.activeScaleText ?? "none")
    }
    // Channels `rotation_euler`, `scale` and `location` alone do not show.
    let hidden: [(String, Bpy.AppliedTransform)] = [
        ("delta_scale", .scale), ("delta_location", .location), ("quaternion", .rotation),
        ("zero_quaternion", .rotation), ("axis_angle", .rotation), ("zxy_delta", .rotation),
    ]
    for (name, what) in hidden {
        if let s = state(name) {
            check("\(name): Apply \(what.title) is offered", s.offers(what), "\(s)")
        }
    }
    // For contrast: the decomposition of matrix_world the menu used to read.
    // If these stop differing, the scenarios no longer tell the two apart.
    if let mirrored = byName["mirrored"]?.worldScale, let small = byName["child_of_small"]?.worldScale,
       let turned = byName["turned_45"]?.worldScale {
        check("the world decomposition reads the mirror as scale 1",
              all(abs(mirrored - 1) .< 1e-5), "\(mirrored)")
        check("and the child of a 0.01 parent as 0.01", abs(small.x - 0.01) < 1e-5, "\(small)")
        check("and a 45° turn as a scale other than exactly 1", turned != SIMD3(repeating: 1), "\(turned)")
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    return failures == 0 ? 0 : 1
}
