import Foundation
import simd

// The Swift half of scripts/run-measure-blender-check.sh.
//
//   run <scenes.json> <calls.txt>
//
// For every pixel Blender's own Cursor tool was measured at (verify.py
// measure): the mirror as the device builds it from the fixture's evaluated
// meshes, the app's hits on it (CursorTool.depthHit at the pixel's centre,
// where Blender's depth buffer is read, and CursorTool.surfaceHit through the
// pixel's corner, where Blender's snap casts), and the call a tap sends
// (CursorTool.placePython) — written out for verify.py apply to run and hold
// to Blender's result. With a negative control: the face normal as the world
// cross product, which a mirrored object turns round.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
guard args.count == 3,
      let data = FileManager.default.contents(atPath: args[1]),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let scenes = root["scenes"] as? [[String: Any]] else {
    print("usage: run <scenes.json> <calls.txt>"); exit(2)
}

var calls: [String] = []
func emit(_ head: String, _ body: String) { calls.append("#-- \(head)\n\(body)") }

func floats(_ v: Any?) -> [Float] { (v as? [NSNumber])?.map(\.floatValue) ?? [] }
func v3(_ v: Any?) -> SIMD3<Float> { let f = floats(v); return SIMD3(f[0], f[1], f[2]) }
func matrix(_ rows: Any?) -> simd_float4x4 {
    let r = (rows as! [[NSNumber]]).map { $0.map(\.floatValue) }
    return simd_float4x4(columns: (SIMD4(r[0][0], r[1][0], r[2][0], r[3][0]),
                                   SIMD4(r[0][1], r[1][1], r[2][1], r[3][1]),
                                   SIMD4(r[0][2], r[1][2], r[2][2], r[3][2]),
                                   SIMD4(r[0][3], r[1][3], r[2][3], r[3][3])))
}

/// The objects as `SceneMirror.object` builds them from a pass.
func mirror(_ meshes: [[String: Any]]) -> [BKObject] {
    meshes.map { m in
        let object = BKObject(name: m["name"] as! String, kind: .cube)
        let vertices = (m["vertices"] as! [[NSNumber]]).map {
            MeshVertex(SIMD3($0[0].floatValue, $0[1].floatValue, $0[2].floatValue), SIMD3(0, 0, 1))
        }
        let triangles = (m["triangles"] as! [[NSNumber]]).flatMap { $0.map { UInt32($0.intValue) } }
        var data = MeshData(vertices: vertices, indices: triangles)
        data.cornerLoops = (m["loops"] as? [[NSNumber]])?.flatMap { $0.map { UInt32($0.intValue) } } ?? []
        object.setEvaluatedMesh(data)
        object.setMirroredTransform(matrix(m["matrix"]))
        object.displaysWire = (m["display"] as? String) == "WIRE"
        object.displaysBounds = (m["display"] as? String) == "BOUNDS"
        object.subdividesLastInEditMode = (m["subdivlast"] as? Bool) == true
        return object
    }
}

/// Blender's perspective matrix, its clip space's z from -1 to 1, as the
/// app's Metal one with z from 0 to 1, which GeometrySnap.View unprojects.
func metal(_ persmat: simd_float4x4) -> simd_float4x4 {
    var fix = matrix_identity_float4x4
    fix.columns.2.z = 0.5
    fix.columns.3.z = 0.5
    return fix * persmat
}

/// The world-space cross product's normal: the negative control's.
func worldNormal(_ objects: [BKObject], ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> SIMD3<Float>? {
    var best: (Float, SIMD3<Float>)?
    for o in objects where o.visible && !o.displaysWire && !o.displaysBounds {
        let m = o.modelMatrix
        let w = o.mesh.vertices.map { (m * SIMD4($0.position, 1)).xyz }
        var t = 0
        while t + 2 < o.mesh.indices.count {
            let a = w[Int(o.mesh.indices[t])], b = w[Int(o.mesh.indices[t + 1])], c = w[Int(o.mesh.indices[t + 2])]
            t += 3
            if let d = MeshPicker.rayTriangle(ray.origin, ray.direction, a, b, c), d >= 0, best == nil || d < best!.0 {
                best = (d, simd_normalize(simd_cross(b - a, c - a)))
            }
        }
    }
    return best?.1
}

print("The Cursor tool's hits on the mirror and its calls, at the pixels Blender was measured at")
var made = 0, withDepth = 0, withSurface = 0, controls = 0, refused = 0
for (si, scene) in scenes.enumerated() {
    let region = scene["region"] as! [String: Any]
    let size = floats(region["size"])
    let view = GeometrySnap.View(viewProjection: metal(matrix(region["persmat"])), size: SIMD2(size[0], size[1]))
    let objects = mirror(scene["meshes"] as! [[String: Any]])
    let forward = -v3(region["z"])
    let cursorView = CursorTool.View(eye: v3(region["eye"]), forward: forward, up: v3(region["y"]),
                                     orthographic: region["ortho"] as! Bool, center: v3(region["center"]),
                                     axisAligned: region["axis"] as! Bool)
    let samples = scene["samples"] as! [[String: Any]]
    let meshes = scene["meshes"] as! [[String: Any]]
    let rebuilt = zip(meshes, objects).first { ($0.0["rebuilt"] as? Bool) == true }?.1
    // One answer per pixel: the hits do not depend on the settings.
    var cache: [String: (SIMD3<Float>?, CursorTool.Surface?, SIMD3<Float>, SIMD3<Float>?)] = [:]
    for (k, sample) in samples.enumerated() {
        let px = floats(sample["px"])
        let pkey = "\(px[0]),\(px[1])"
        if cache[pkey] == nil {
            // Blender's region pixel (up from the bottom) as the view's
            // points (down from the top): its corner, where Blender's snap and
            // `ED_view3d_win_to_3d_int` look, and its centre, where the depth
            // buffer was drawn and is unprojected.
            let corner = SIMD2(px[0], size[1] - px[1])
            let centre = SIMD2(px[0] + 0.5, size[1] - px[1] - 0.5)
            guard let ray = CursorTool.ray(view, corner) else { continue }
            let depth = CursorTool.depthHit(objects: objects, view: view, pointer: centre, forward: forward)
            let surface = CursorTool.surfaceHit(objects: objects, ray: ray)
            cache[pkey] = (depth, surface, CursorTool.linePoint(ray, center: cursorView.center),
                           worldNormal(objects, ray: ray))
        }
        let (depth, surface, point, world) = cache[pkey]!
        // The Geometry orientation where Blender's snap meets a mesh the
        // mirror does not hold (a last Subdivision Surface): refused in words
        // (CursorTool.geometryRefusal), not called.
        if let edited = rebuilt, (sample["orientation"] as! String) == "GEOM",
           CursorTool.geometryRefusal(surface, orientation: .geometry, edited: edited) != nil {
            refused += 1
            continue
        }
        guard let call = CursorTool.placePython(view: cursorView, point: point, depth: depth, surface: surface) else {
            check("scene \(si) sample \(k): a call", false, "none made"); continue
        }
        emit("cursor.\(si).\(k)", call)
        made += 1
        if depth != nil { withDepth += 1 }
        if surface != nil { withSurface += 1 }
        if var bad = surface, let world, (sample["orientation"] as! String) == "GEOM" {
            bad.normal = world
            if let control = CursorTool.placePython(view: cursorView, point: point, depth: depth, surface: bad) {
                emit("cursor.\(si).\(k) WORLDNORMAL", control)
                controls += 1
            }
        }
    }
}
print("  \(made) calls, \(withDepth) with a depth, \(withSurface) with a surface, \(controls) controls, "
      + "\(refused) Geometry taps under a last Subdivision Surface refused")
check("a call for every sample", made > 1000)

// MARK: the scene's units, as the ruler and the overlays print them

print("\nThe unit strings (BlenderUnits), for verify.py to hold to Blender's C")
let systems: [UnitSettings] = [
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 1, lengthUnit: "METERS"),
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 1, lengthUnit: "ADAPTIVE"),
    UnitSettings(system: .metric, rotation: .radians, scaleLength: 0.01, lengthUnit: "CENTIMETERS"),
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 1000, lengthUnit: "KILOMETERS"),
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 1, lengthUnit: "MILLIMETERS", separate: true),
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 1, lengthUnit: "MICROMETERS"),
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 1, lengthUnit: "ADAPTIVE", separate: true),
    UnitSettings(system: .metric, rotation: .degrees, scaleLength: 2.54, lengthUnit: "MICROMETERS"),
    UnitSettings(system: .imperial, rotation: .degrees, scaleLength: 1, lengthUnit: "FEET"),
    UnitSettings(system: .imperial, rotation: .degrees, scaleLength: 1, lengthUnit: "ADAPTIVE", separate: true),
    UnitSettings(system: .imperial, rotation: .radians, scaleLength: 1, lengthUnit: "INCHES", separate: true),
    UnitSettings(system: .imperial, rotation: .degrees, scaleLength: 1, lengthUnit: "MILES"),
    UnitSettings(system: .imperial, rotation: .degrees, scaleLength: 0.3048, lengthUnit: "THOU"),
    UnitSettings(system: .none, rotation: .degrees, scaleLength: 1, lengthUnit: "ADAPTIVE"),
    UnitSettings(system: .none, rotation: .radians, scaleLength: 5, lengthUnit: "ADAPTIVE"),
]
let values: [Double] = [0, 1, 2, 0.5, 0.02, 0.0012, 0.00009, 1234.5678, 2.8284271, 0.1, 0.00000047, 9.99999,
                        12.3456, 0.009999, 1609.344, 0.3048, 3.0 * 0.3048 + 4 * 0.0254, 1e-11, -0.75, -2.5]
let angles: [Double] = [0, 0.5, Double.pi / 2, Double.pi, 2.0943951, 0.0001, 6.2831, 1.23456, 0.785398]
let kinds: [(BlenderUnits.Kind, Int, Bool, String)] = [(.length, 6, true, "LENGTH"), (.length, 3, true, "LENGTH"),
                                                       (.length, 2, true, "LENGTH"), (.area, 3, true, "AREA"),
                                                       (.rotation, 2, false, "ROTATION")]
var unitLines: [String] = []
for (si, settings) in systems.enumerated() {
    for (kind, prec, scaled, name) in kinds {
        for v in (kind == .rotation ? angles : values) {
            let text = BlenderUnits.string(v, prec: prec, kind: kind, settings: settings, scaled: scaled)
            unitLines.append([String(si), settings.system.rawValue, settings.rotation.rawValue,
                              String(format: "%.9g", Double(settings.scaleLength)), settings.lengthUnit,
                              settings.separate ? "1" : "0", name, String(prec), scaled ? "1" : "0",
                              String(format: "%.17g", v), text].joined(separator: "\t"))
        }
    }
}
emit("units", unitLines.joined(separator: "\n"))
print("  \(unitLines.count) strings")

// MARK: the ruler's points and its text

print("\nThe ruler's points (RulerTool.place) on the mirror, at the pixels the cursor was measured at")
var rulerLines: [String] = [], rulerTexts: [String] = []
var snappedKinds: [String: Int] = [:]
for (si, scene) in scenes.enumerated() {
    let region = scene["region"] as! [String: Any]
    let size = floats(region["size"])
    let view = GeometrySnap.View(viewProjection: metal(matrix(region["persmat"])), size: SIMD2(size[0], size[1]))
    let objects = mirror(scene["meshes"] as! [[String: Any]])
    let forward = -v3(region["z"])
    let eye = v3(region["eye"])
    let ortho = region["ortho"] as! Bool
    let rebuiltEdit = zip(scene["meshes"] as! [[String: Any]], objects).first { ($0.0["rebuilt"] as? Bool) == true }?.1
    let snap = GeometrySnap.Targets(objects: objects, view: view,
                                    elements: RulerTool.elements(snapTool: "GEOMETRY", scene: []),
                                    excludedObjects: RulerTool.excluded(objects, edited: rebuiltEdit).ids,
                                    occlusion: true, radius: RulerTool.snapDistance)
    let cursor = SIMD3<Float>(0.3, -0.2, 0.15)
    var placed: [SIMD3<Float>] = []
    var pixels = Set<String>()
    for sample in scene["samples"] as! [[String: Any]] {
        let px = floats(sample["px"])
        guard pixels.insert("\(px[0]),\(px[1])").inserted else { continue }
        let pointer = SIMD2(px[0], size[1] - px[1])
        // Snapping on; then off, in the view's plane through the world origin
        // (a new ruler's first point's depth, `drag_start_co` zeroed).
        for (snapping, depth) in [(true, SIMD3<Float>.zero), (false, SIMD3<Float>.zero), (false, SIMD3<Float>(1, 2, 0.5))] {
            guard let (point, hit) = RulerTool.place(pointer: pointer, depth: depth, snap: snapping ? snap : nil,
                                                    cursor: cursor, view: view, eye: eye, forward: forward,
                                                    orthographic: ortho) else { continue }
            let kind = hit.map { "\($0.kind)" } ?? (snapping ? "plane" : "depth")
            snappedKinds[kind, default: 0] += 1
            rulerLines.append([String(si), String(px[0]), String(px[1]), kind,
                               "\(point.x),\(point.y),\(point.z)", "\(depth.x),\(depth.y),\(depth.z)",
                               "\(cursor.x),\(cursor.y),\(cursor.z)"].joined(separator: "\t"))
            if snapping { placed.append(point) }
        }
    }
    // Rulers between the snapped points, and angle rulers through three.
    for i in stride(from: 0, to: max(0, placed.count - 2), by: 3) {
        let a = placed[i], b = placed[i + 1], c = placed[i + 2]
        for (ui, units) in systems.enumerated() {
            let length = Ruler(start: a, end: c)
            let angle = Ruler(points: [a, b, c], usesAngle: true)
            for ruler in [length, angle] {
                let p = ruler.points
                rulerTexts.append([String(ui), ruler.usesAngle ? "1" : "0",
                                   p.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";"),
                                   ruler.text(units: units)].joined(separator: "\t"))
            }
        }
    }
}
emit("ruler", rulerLines.joined(separator: "\n"))

// The negative control: the mirror without the face corners the device sends
// with the UV map, so GeometrySnap takes a quad's diagonal for an edge. Some
// snapped points must then land where Blender has no edge.
var controlLines: [String] = []
for (si, scene) in scenes.enumerated() {
    let region = scene["region"] as! [String: Any]
    let size = floats(region["size"])
    let view = GeometrySnap.View(viewProjection: metal(matrix(region["persmat"])), size: SIMD2(size[0], size[1]))
    let bare = (scene["meshes"] as! [[String: Any]]).map { m -> [String: Any] in
        var m = m; m["loops"] = nil; return m
    }
    let objects = mirror(bare)
    let snap = GeometrySnap.Targets(objects: objects, view: view,
                                    elements: RulerTool.elements(snapTool: "GEOMETRY", scene: []),
                                    excludedObjects: [], occlusion: true, radius: RulerTool.snapDistance)
    var pixels = Set<String>()
    for sample in scene["samples"] as! [[String: Any]] {
        let px = floats(sample["px"])
        guard pixels.insert("\(px[0]),\(px[1])").inserted,
              let hit = snap.find(SIMD2(px[0], size[1] - px[1])),
              hit.kind == .edge || hit.kind == .edgeMidpoint else { continue }
        controlLines.append([String(si), String(px[0]), String(px[1]), "\(hit.kind)",
                             "\(hit.location.x),\(hit.location.y),\(hit.location.z)"].joined(separator: "\t"))
    }
}
emit("ruler_control", controlLines.joined(separator: "\n"))
emit("rulertext", rulerTexts.joined(separator: "\n"))
print("  \(rulerLines.count) points: \(snappedKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); \(rulerTexts.count) texts")
check("the ruler snapped to vertices, edge midpoints, edges and faces, and found the plane in empty space",
      ["vertex", "edgeMidpoint", "edge", "face", "plane"].allSatisfy { snappedKinds[$0, default: 0] > 0 },
      "\(snappedKinds)")

// MARK: Edit Mode's overlays

print("\nEdit Mode's measurements (EditMeasurements) as the overlay writes them")
let overlayRoot = root["overlays"] as! [String: Any]
var overlayLines: [String] = []
let wide = simd_float4x4(diagonal: SIMD4(0.01, 0.01, 0.01, 1))   // a view that holds every edge whole
for (ci, case_) in (overlayRoot["cases"] as! [[String: Any]]).enumerated() {
    guard let measured = EditMeasurements(json: case_["record"] as! String) else {
        check("overlay case \(ci) parses", false, case_["record"] as! String); continue
    }
    let all = MeasureOverlays(statistics: true, edgeLength: true, edgeAngle: true, faceArea: true, faceAngle: true)
    for (ui, units) in systems.enumerated() {
        for label in measured.labels(units: units, viewProjection: wide, overlays: all) {
            overlayLines.append([String(ci), String(ui), "\(label.kind)", "\(label.at.x),\(label.at.y),\(label.at.z)",
                                 label.text].joined(separator: "\t"))
        }
    }
    if let stats = measured.statistics {
        overlayLines.append([String(ci), "-", "stats", stats.rows.map { "\($0.label)=\($0.value)" }.joined(separator: ";"),
                             ""].joined(separator: "\t"))
    }
}
emit("overlay", overlayLines.joined(separator: "\n"))
print("  \(overlayLines.count) labels and rows")

// MARK: the drag's call

emit("drag", [CursorTool.dragPython(from: SIMD3(0.5, -0.5, 2), to: SIMD3(1.25, 0.75, 1.5))!,
              CursorTool.dragPython(from: SIMD3(0, 0, 0), to: SIMD3(-0.3, 2.0, 0.125))!].joined(separator: "\n"))

try! calls.joined(separator: "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
exit(failures == 0 ? 0 : 1)
