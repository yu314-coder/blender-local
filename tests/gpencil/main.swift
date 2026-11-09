import Foundation
import simd

// Grease Pencil's Swift half (GreasePencil.swift, GreasePencilGeometry.swift,
// GreasePencilStroke.swift): the mirror's record read, the ribbons and fills
// the viewport is handed and their order, the stroke projected onto Blender's
// drawing plane, thinned, smoothed and simplified, with Blender's radius and
// opacity, picking, and the 20,000-point costs. What Blender makes of the
// strokes written this way is scripts/run-gpencil-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func near(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) <= eps }
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool { simd_distance(a, b) <= eps }
func f(_ v: SIMD3<Float>) -> String { String(format: "(%.5f, %.5f, %.5f)", v.x, v.y, v.z) }

// What `_blenderkit_gpencil.record` writes, built here.
struct Wire {
    var record: [String: Any] = [:]
    var bytes = Data()
    mutating func floats(_ v: [Float]) { v.withUnsafeBufferPointer { bytes.append(Data(buffer: $0)) } }
    mutating func ints(_ v: [Int32]) { v.withUnsafeBufferPointer { bytes.append(Data(buffer: $0)) } }
    var json: String { String(data: try! JSONSerialization.data(withJSONObject: record), encoding: .utf8)! }
}

func material(_ name: String, stroke: [Float], fill: [Float], showFill: Bool = true) -> [String: Any] {
    ["name": name, "stroke": stroke, "fill": fill, "show_stroke": stroke[3] > 0, "show_fill": showFill,
     "hide": false, "lock": false]
}

func layer(_ name: String, frames: [[Any]] = [[1, "KEYFRAME", false]], frame: Int? = 1,
           opacity: Float = 1, hide: Bool = false) -> [String: Any] {
    var l: [String: Any] = ["name": name, "hide": hide, "lock": false, "opacity": opacity, "tint": [0, 0, 0, 0],
                            "onion": true, "frames": frames, "blend": "REGULAR", "lights": true]
    l["frame"] = frame ?? NSNull()
    if frame == nil { l["frame"] = NSNull() }
    return l
}

/// One drawing: strokes as point lists, each with a material, cyclic, fill id.
func drawing(_ w: inout Wire, layerIndex: Int, onion: Int = 0, frame: Int? = nil,
             strokes: [([SIMD3<Float>], Int32, Bool, Int32)], radius: Float = 0.05, opacity: Float = 1) -> [String: Any] {
    let points = strokes.flatMap { $0.0 }
    w.floats(points.flatMap { [$0.x, $0.y, $0.z] })
    w.floats([Float](repeating: radius, count: points.count))
    w.floats([Float](repeating: opacity, count: points.count))
    var offsets: [Int32] = [0]
    for s in strokes { offsets.append(offsets.last! + Int32(s.0.count)) }
    w.ints(offsets)
    w.ints(strokes.map { $0.2 ? 1 : 0 })
    w.ints(strokes.map { $0.1 })
    w.ints(strokes.map { $0.3 })
    w.ints(strokes.map { _ in 0 })
    var block: [String: Any] = ["points": points.count, "strokes": strokes.count, "vcol": false, "fcol": false,
                                "layer": layerIndex, "onion": onion]
    if let frame { block["frame"] = frame }
    return block
}

func parse(_ w: Wire) -> GreasePencilWire.Parsed? {
    w.bytes.withUnsafeBytes { GreasePencilWire.parse(record: w.json, blob: $0) }
}

let square: [SIMD3<Float>] = [SIMD3(-1, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 0, 1), SIMD3(-1, 0, 1)]

print("== the mirror's record (GreasePencilWire) ==")
do {
    var w = Wire()
    let b0 = drawing(&w, layerIndex: 0, strokes: [(square, 1, false, 1)])
    let b1 = drawing(&w, layerIndex: 1, strokes: [([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 1)], 0, false, 0),
                                                   ([SIMD3(5, 0, 5)], 0, false, 0)])
    let ghost = drawing(&w, layerIndex: 1, onion: -1, frame: 1, strokes: [(square, 0, true, 0)])
    w.record = ["layers": [layer("Fills"), layer("Lines", frames: [[1, "KEYFRAME", false], [5, "BREAKDOWN", true]], frame: 5)],
                "active_layer": 1,
                "materials": [material("Black", stroke: [0, 0, 0, 1], fill: [0, 0, 0, 1]),
                              material("Skin", stroke: [0.5, 0.2, 0.06, 1], fill: [0.5, 0.2, 0.06, 1]), NSNull()],
                "active_material": 0, "depth_order": "2D", "in_front": true,
                "onion": ["mode": "RELATIVE", "factor": 0.5, "filter": "ALL", "before": 1, "after": 1, "custom": true,
                          "before_color": [0.145, 0.42, 0.137], "after_color": [0.125, 0.082, 0.529],
                          "fade": true, "loop": false],
                "blocks": [b0, b1, ghost], "frame": 5]
    if let p = parse(w) {
        check("two layers, Lines active, its keyframes 1 and 5 (5 a selected Breakdown), 5 in effect",
              p.info.layers.map(\.name) == ["Fills", "Lines"] && p.info.activeLayer == 1
                && p.info.layers[1].keyframes == [GPKeyframe(frame: 1, type: "KEYFRAME", selected: false),
                                                   GPKeyframe(frame: 5, type: "BREAKDOWN", selected: true)]
                && p.info.layers[1].frameInEffect == 5)
        check("three slots, the third without a Grease Pencil material", p.info.materials.count == 3
                && p.info.materials[2] == nil && p.info.materials[1]?.name == "Skin")
        check("Show In Front and 2D Layers read", p.info.inFront && !p.info.depthOrder3D)
        check("the frame's points and strokes counted, the onion skin's not",
              p.info.pointCount == 8 && p.info.strokeCount == 3, "\(p.info.pointCount) \(p.info.strokeCount)")
        check("three drawings: two of the frame and one onion skin before it",
              p.drawings.blocks.map(\.onion) == [0, 0, -1] && p.drawings.blocks[2].frame == 1)
        check("a drawing's offsets, cyclic, materials and fill ids",
              p.drawings.blocks[1].drawing.offsets == [0, 3, 4] && p.drawings.blocks[2].drawing.cyclic == [true]
                && p.drawings.blocks[0].drawing.fillIDs == [1])
    } else {
        check("the record parses", false)
    }
    // Malformed: a short blob, offsets past the points, a layer out of range.
    var short = w
    short.bytes = short.bytes.dropLast(4)
    check("a blob shorter than the record says: refused", parse(short) == nil)
    var long = w
    long.bytes.append(contentsOf: [0, 0, 0, 0])
    check("a blob longer than the record says: refused", parse(long) == nil)
    var bad = Wire()
    _ = drawing(&bad, layerIndex: 0, strokes: [(square, 0, false, 0)])
    bad.bytes.replaceSubrange((4 * 4 * 5)..<(4 * 4 * 5 + 8), with: Data([0, 0, 0, 0, 9, 0, 0, 0]))
    bad.record = ["layers": [layer("L")], "active_layer": 0, "materials": [], "active_material": 0,
                  "blocks": [["points": 4, "strokes": 1, "vcol": false, "fcol": false, "layer": 0, "onion": 0]]]
    check("offsets running past the points: refused", parse(bad) == nil)
    var stray = w
    var record = stray.record
    var blocks = record["blocks"] as! [[String: Any]]
    blocks[0]["layer"] = 7
    record["blocks"] = blocks
    stray.record = record
    check("a block naming a layer that is not there: refused", parse(stray) == nil)
    check("not JSON: refused", Data().withUnsafeBytes { GreasePencilWire.parse(record: "layers=", blob: $0) } == nil)

    // Installing: the same bytes again change nothing.
    let obj = BKObject(name: "Stroke", kind: .cube)
    obj.blenderType = "GREASEPENCIL"
    let first = w.bytes.withUnsafeBytes { obj.installGreasePencil(record: w.json, blob: $0) }
    let version = obj.greasePencilVersion
    let again = w.bytes.withUnsafeBytes { obj.installGreasePencil(record: w.json, blob: $0) }
    check("installed once, then the same bytes are no change (no new version, no upload)",
          first == true && again == false && obj.greasePencilVersion == version)
    let fresh = BKObject(name: "Stroke", kind: .cube)
    let reused = w.bytes.withUnsafeBytes { fresh.installGreasePencil(record: w.json, blob: $0, previous: obj) }
    check("a pass's fresh object reuses the one on screen's drawings when the bytes match",
          reused == false && fresh.greasePencilDrawings == obj.greasePencilDrawings)
    obj.takeGreasePencil(from: fresh)
    check("and the merge then takes nothing", obj.greasePencilVersion == version)
}

print("\n== the geometry (GreasePencilGeometry.build) ==")
func simpleInfo(fill: Bool = true, strokeAlpha: Float = 1) -> GreasePencilInfo {
    var info = GreasePencilInfo()
    info.layers = [GPLayer(name: "Lines")]
    info.activeLayer = 0
    info.materials = [GPMaterial(name: "M", stroke: SIMD4(1, 0, 0, strokeAlpha), fill: SIMD4(0, 0, 1, 1),
                                 showStroke: strokeAlpha > 0, showFill: fill, hidden: false, locked: false)]
    return info
}
func one(_ strokes: [([SIMD3<Float>], Bool, Int)]) -> GreasePencilDrawings {
    var d = GPDrawing()
    for (points, cyclic, fill) in strokes {
        d.positions += points
        d.radii += [Float](repeating: 0.05, count: points.count)
        d.opacities += [Float](repeating: 1, count: points.count)
        d.offsets.append(d.offsets.last! + points.count)
        d.cyclic.append(cyclic)
        d.materials.append(0)
        d.fillIDs.append(fill)
        d.hideStroke.append(false)
    }
    var out = GreasePencilDrawings()
    out.blocks = [.init(layer: 0, onion: 0, frame: nil, drawing: d)]
    return out
}
do {
    let open = GreasePencilGeometry.build(info: simpleInfo(), drawings: one([(square, false, 0)]))
    check("an open 4-point stroke: 3 segments, no fill (fill_id 0)",
          open.primitives.count == 3 && open.primitives.allSatisfy { !$0.isFill })
    let cyclic = GreasePencilGeometry.build(info: simpleInfo(), drawings: one([(square, true, 0)]))
    check("cyclic: a 4th segment back to the start", cyclic.primitives.count == 4
            && cyclic.primitives.last!.a == 3 && cyclic.primitives.last!.b == 0)
    let filled = GreasePencilGeometry.build(info: simpleInfo(), drawings: one([(square, false, 1)]))
    let fills = filled.primitives.filter(\.isFill)
    check("fill_id 1: two fill triangles first, then the stroke's 3 segments over them",
          fills.count == 2 && filled.primitives.prefix(2).allSatisfy(\.isFill)
            && filled.primitives.suffix(3).allSatisfy { !$0.isFill })
    check("the fill's order is before its stroke's", fills[0].order == 1 && filled.primitives.last!.order == 2)
    check("its colour is the fill colour (blue)", fills[0].colour.z > 0.99 && fills[0].colour.x < 0.01)
    var hiddenLine = one([(square, false, 1)])
    hiddenLine.blocks[0].drawing.hideStroke = [true]
    let fillOnly = GreasePencilGeometry.build(info: simpleInfo(), drawings: hiddenLine)
    check("hide_stroke: the fill and no line (the Monkey's face)",
          fillOnly.primitives.count == 2 && fillOnly.primitives.allSatisfy(\.isFill))
    let noFill = GreasePencilGeometry.build(info: simpleInfo(fill: false), drawings: one([(square, false, 1)]))
    check("a material whose fill is not visible: no fill", noFill.primitives.filter(\.isFill).isEmpty)
    let dot = GreasePencilGeometry.build(info: simpleInfo(), drawings: one([([SIMD3(0, 0, 0)], false, 0)]))
    check("a one-point stroke is a dot (a segment from the point to itself)",
          dot.primitives.count == 1 && dot.primitives[0].a == dot.primitives[0].b)
    let two = GreasePencilGeometry.build(info: simpleInfo(), drawings: one([(square, false, 0), (square, false, 0)]))
    check("a later stroke is ordered after an earlier one",
          two.primitives[0].order == 1 && two.primitives[3].order == 2 && two.maxOrder == 2)
    var hidden = simpleInfo()
    hidden.layers[0].hidden = true
    check("a hidden layer draws nothing",
          GreasePencilGeometry.build(info: hidden, drawings: one([(square, false, 1)])).primitives.isEmpty)

    // Colour: Blender's material colour mixed with the vertex colour, the
    // layer's tint and opacity, then sRGB.
    var layer = GPLayer(name: "L")
    layer.opacity = 0.5
    let m = GPMaterial(name: "M", stroke: SIMD4(0.5, 0.2, 0.06, 1), fill: .zero, showStroke: true,
                       showFill: false, hidden: false, locked: false)
    let c = GreasePencilGeometry.strokeColour(material: m, vertexColour: nil, opacity: 0.8, layer: layer)
    check("stroke colour: linear 0.5 shows as sRGB 0.7354, alpha 1 x 0.8 x 0.5",
          near(c.x, 0.7354, 1e-3) && near(c.w, 0.4), "\(c)")
    let v = GreasePencilGeometry.strokeColour(material: m, vertexColour: SIMD4(0, 0, 1, 1), opacity: 1, layer: GPLayer(name: "L"))
    check("a vertex colour of alpha 1 replaces the material's", near(v.z, 1) && near(v.x, 0))
    var tinted = GPLayer(name: "L")
    tinted.tint = SIMD4(0, 1, 0, 1)
    let t = GreasePencilGeometry.strokeColour(material: m, vertexColour: nil, opacity: 1, layer: tinted)
    check("a layer tint of factor 1 replaces it", near(t.y, 1) && near(t.x, 0))
    check("sRGB and back", near(GreasePencilGeometry.linear(GreasePencilGeometry.display(SIMD3(0.2, 0.5, 0.9))),
                                SIMD3(0.2, 0.5, 0.9), 1e-4))

    // Onion skins: under the frame's strokes, tinted, fading.
    var info = simpleInfo()
    info.onion.before = 2
    var drawings = one([(square, false, 0)])
    var ghost = drawings.blocks[0]
    ghost.onion = -2
    drawings.blocks.insert(ghost, at: 0)
    let built = GreasePencilGeometry.build(info: info, drawings: drawings)
    check("onion skins come first and are counted", built.ghostPrimitives == 3 && built.primitives.count == 6)
    let tint = GreasePencilGeometry.ghostTint(info.onion, onion: -2)
    check("a ghost two keyframes back, Fade on, Before 2: the before colour at half the onion opacity",
          near(tint.w, 0.25) && near(SIMD3(tint.x, tint.y, tint.z), info.onion.beforeColour), "\(tint)")
    check("the ghost's points are tinted the before colour",
          near(SIMD3(built.points[0].colour.x, built.points[0].colour.y, built.points[0].colour.z),
               GreasePencilGeometry.display(info.onion.beforeColour), 1e-3))
    let none = GreasePencilGeometry.build(info: info, drawings: drawings, ghosts: false)
    check("while playing back, no onion skins", none.primitives.count == 3 && none.ghostPrimitives == 0)
}

print("\n== fills (ear clipping) ==")
do {
    let tri = GreasePencilGeometry.triangulate(square)
    check("a square in the XZ plane: 2 triangles", tri.count == 2)
    // An L: concave, 6 corners, area 3.
    let l: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 0, 2), SIMD3(0, 0, 2)]
    let lt = GreasePencilGeometry.triangulate(l)
    func area(_ t: [(Int, Int, Int)], _ p: [SIMD3<Float>]) -> Float {
        t.reduce(0) { $0 + simd_length(simd_cross(p[$1.1] - p[$1.0], p[$1.2] - p[$1.0])) / 2 }
    }
    check("a concave L: 4 triangles covering exactly its area 3", lt.count == 4 && near(area(lt, l), 3, 1e-4),
          "\(lt.count) \(area(lt, l))")
    check("clockwise the same", near(area(GreasePencilGeometry.triangulate(l.reversed()), Array(l.reversed())), 3, 1e-4))
    var circle: [SIMD3<Float>] = []
    for k in 0..<200 { let a = Float(k) / 200 * 2 * .pi; circle.append(SIMD3(cos(a), sin(a) * 0.3, sin(a))) }
    let ct = GreasePencilGeometry.triangulate(circle)
    check("a tilted 200-point circle: 198 triangles", ct.count == 198)
    check("a line has no area: nothing", GreasePencilGeometry.triangulate([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]).isEmpty)
    let repeated = GreasePencilGeometry.triangulate(square + [square[3], square[0]])
    check("repeated points do not break it", repeated.count == 2)
}

print("\n== the stroke (GreasePencilStroke) ==")
// The app's default view, Front: looking along +Y at the origin, 10 m away.
func frontView(ortho: Bool = false) -> GPView {
    var c = ViewportCamera()
    c.snap(to: .front)
    c.isOrthographic = ortho
    c.distance = 10
    return GPView(viewProjection: c.viewProjection(aspect: 1100.0 / 800.0), size: SIMD2(1100, 800),
                  forward: c.target - c.eye)
}
do {
    let view = frontView()
    let state = GPDrawState()   // Origin, View: the factory settings' (5.2.1)
    let plane = GreasePencilStroke.placement(state, toWorld: matrix_identity_float4x4, view: view)
    check("Origin and View: the plane through the object's origin, facing the view",
          near(plane.point, .zero) && near(plane.normal, SIMD3(0, 1, 0)), f(plane.normal))
    let centre = GreasePencilStroke.project(SIMD2(550, 400), onto: plane, view: view)
    check("the view's centre lands on the origin", near(centre, .zero, 1e-4), f(centre))
    let right = GreasePencilStroke.project(SIMD2(825, 400), onto: plane, view: view)
    check("a point to the right lands to the right on the plane, at y 0",
          right.x > 0 && near(right.y, 0, 1e-4) && near(right.z, 0, 1e-4), f(right))
    // It projects back to where it was drawn.
    check("and projects back to the same place", simd_distance(view.project(right).point, SIMD2(825, 400)) < 0.01)

    // Front (X-Z) on an object turned 90° about Z: the plane is the object's
    // own XZ plane, whose normal is now world X.
    var turned = GPDrawState()
    turned.plane = "AXIS_Y"
    let rotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
    var moved = rotation
    moved.columns.3 = SIMD4(0, 2, 0, 1)
    let axisPlane = GreasePencilStroke.placement(turned, toWorld: moved, view: view)
    check("Front (X-Z) follows the object's axes: its Y turned to world -X, through its origin",
          near(axisPlane.normal, SIMD3(-1, 0, 0), 1e-5) && near(axisPlane.point, SIMD3(0, 2, 0)), f(axisPlane.normal))
    var cursor = GPDrawState()
    cursor.placement = "CURSOR"
    cursor.cursor = SIMD3(0, 3, 0)
    let behind = GreasePencilStroke.project(SIMD2(550, 400),
                                            onto: GreasePencilStroke.placement(cursor, toWorld: matrix_identity_float4x4, view: view),
                                            view: view)
    check("3D Cursor placement: on the plane through the cursor", near(behind, SIMD3(0, 3, 0), 1e-3), f(behind))
    // Edge-on: Top (X-Y) seen from the front; the ray runs along the plane.
    var top = GPDrawState()
    top.plane = "AXIS_Z"
    let edge = GreasePencilStroke.project(SIMD2(825, 300),
                                          onto: GreasePencilStroke.placement(top, toWorld: matrix_identity_float4x4, view: view),
                                          view: view)
    check("an edge-on plane falls back to the view's plane through the point", near(edge.y, 0, 1e-3), f(edge))

    // Thinning, smoothing, simplifying.
    let jittery = (0..<50).map { GPSample(SIMD2(Float($0) * 0.3, 0)) }
    // Every fourth sample (1.2 points apart) up to 14.4, the last (14.7)
    // in its place: 13.
    check("samples under a point apart are thinned (50 over 14.7 points: 13 kept), the last kept",
          GreasePencilStroke.thinned(jittery).count == 13
            && GreasePencilStroke.thinned(jittery).last == jittery.last)
    let zig = [GPSample(SIMD2(0, 0)), GPSample(SIMD2(10, 4)), GPSample(SIMD2(20, 0))]
    let smooth = GreasePencilStroke.smoothed(zig, factor: 0.35)
    check("Active Smooth 0.35 moves the middle 35% of the way to its neighbours' midpoint, the ends held",
          near(smooth[1].point.y, 2.6) && smooth[0] == zig[0] && smooth[2] == zig[2])
    let straight = (0...100).map { GPSample(SIMD2(Float($0), Float($0) * 0.5 + ($0 % 2 == 0 ? 0.1 : -0.1))) }
    check("Simplify 0.4 px: a line with 0.1 px of wobble keeps its two ends",
          GreasePencilStroke.simplified(straight, epsilon: 0.4).count == 2)
    let widening = (0...10).map { GPSample(SIMD2(Float($0) * 10, 0)) }
    check("…but a straight stroke that widens keeps where its width changes",
          GreasePencilStroke.simplified(widening, epsilon: 0.4, radii: (0...10).map { $0 < 5 ? 2 : Float($0) }).count > 2)
    let corner = (0...20).map { GPSample(SIMD2(Float($0), 0)) } + (1...20).map { GPSample(SIMD2(20, Float($0))) }
    let kept = GreasePencilStroke.simplified(corner, epsilon: 0.4)
    check("and keeps a corner", kept.count == 3 && kept[1].point == SIMD2(20, 0))

    // Radius and opacity, as Blender's draw tool takes them.
    var pencil = GPBrush()   // the Pencil: Size Unit Scene, 0.06, Strength 1, both pressure toggles on
    pencil.sizeCurve = []
    let made = GreasePencilStroke.point(GPSample(SIMD2(550, 400), pressure: 0.5), brush: pencil, placement: plane,
                                        toWorld: matrix_identity_float4x4, view: view)
    check("Scene unit: radius Unprojected Size / 2 x pressure (0.06 / 2 x 0.5 = 0.015)", near(made.radius, 0.015))
    check("opacity Strength x pressure (0.5)", near(made.opacity, 0.5))
    var unpressured = pencil
    unpressured.usePressureSize = false
    unpressured.usePressureStrength = false
    let full = GreasePencilStroke.point(GPSample(SIMD2(550, 400), pressure: 0.2), brush: unpressured,
                                        placement: plane, toWorld: matrix_identity_float4x4, view: view)
    check("pressure toggles off: the full radius and strength", near(full.radius, 0.03) && near(full.opacity, 1))
    var pixels = GPBrush()
    pixels.sceneUnit = false
    pixels.size = 20
    pixels.usePressureSize = false
    let px = GreasePencilStroke.point(GPSample(SIMD2(550, 400)), brush: pixels, placement: plane,
                                      toWorld: matrix_identity_float4x4, view: view)
    let perPoint = view.worldPerPoint(at: .zero)
    check("View unit: 10 px of radius at the point's depth (\(String(format: "%.5f", perPoint)) m a point)",
          near(px.radius, 10 * perPoint, 1e-5) && perPoint > 0)
    var scaled = matrix_identity_float4x4
    scaled.columns.0.x = 2; scaled.columns.1.y = 2; scaled.columns.2.z = 2
    let half = GreasePencilStroke.point(GPSample(SIMD2(550, 400)), brush: pixels, placement: plane,
                                        toWorld: scaled, view: view)
    check("…divided by the object's scale (2: half), as Blender divides it", near(half.radius, px.radius / 2, 1e-6))
    check("a curve sampled: halfway between samples", near(GPBrush.evaluate([0, 0.25, 1], 0.75), 0.625))

    // Into the layer's space.
    var offset = matrix_identity_float4x4
    offset.columns.3 = SIMD4(1, 0, 0, 1)
    let local = GreasePencilStroke.point(GPSample(SIMD2(825, 400)), brush: pencil, placement:
                                            GreasePencilStroke.placement(state, toWorld: offset, view: view),
                                         toWorld: offset, view: view)
    check("positions are the layer's: the world point less the object's offset",
          near(local.position, local.world - SIMD3(1, 0, 0), 1e-5), "\(f(local.position)) \(f(local.world))")

    // The whole stroke, and what Blender is sent.
    let samples = (0...60).map { GPSample(SIMD2(400 + Float($0) * 5, 400 + 30 * sin(Float($0) / 8)), pressure: 1) }
    var drawing = GPDrawState()
    drawing.brush = pencil
    let stroke = GreasePencilStroke.make(samples, state: drawing, toWorld: matrix_identity_float4x4, view: view)
    check("a 61-sample wave: every point on the plane (y 0)", !stroke.isEmpty && stroke.allSatisfy { abs($0.position.y) < 1e-4 })
    let payload = GreasePencilStroke.payload(stroke)
    check("five floats a point sent", payload.count == stroke.count * 20)
    let python = GreasePencilStroke.python(object: "Stroke's \"one\"", points: stroke)
    check("one call, the name quoted", python.contains("_blenderkit_gpencil.draw_stroke(") && python.contains("base64.b64decode"))
    let erase = GreasePencilStroke.erasePython(object: "GPencil", view: view, path: [SIMD2(1, 2), SIMD2(3, 4)],
                                               radius: 20, mode: "HARD", strength: 1, activeLayerOnly: true)
    check("the eraser's call: the matrix row-major, the path, the mode",
          erase.contains("mode='HARD'") && erase.contains("[1, 2, 3, 4]") && erase.contains("active_layer_only=True"))
}

print("\n== picking ==")
do {
    let view = frontView()
    let info = simpleInfo()
    let drawings = one([([SIMD3(-1, 0, 0), SIMD3(1, 0, 0)], false, 0)])
    var c = ViewportCamera(); c.snap(to: .front); c.distance = 10
    let focal = c.projectionMatrix(aspect: 1100.0 / 800.0)[1][1] * 400
    let on = GreasePencilGeometry.pickDistance(SIMD2(550, 400), info: info, drawings: drawings,
                                               toClip: view.viewProjection, size: view.size, scale: 1,
                                               focal: focal, reach: 12)
    check("a tap on the line: within its radius, distance 0", on == 0)
    let off = GreasePencilGeometry.pickDistance(SIMD2(550, 300), info: info, drawings: drawings,
                                                toClip: view.viewProjection, size: view.size, scale: 1,
                                                focal: focal, reach: 12)
    check("100 points away: nothing", off == nil)
    let filled = one([(square, false, 1)])
    let inside = GreasePencilGeometry.pickDistance(SIMD2(560, 410), info: info, drawings: filled,
                                                   toClip: view.viewProjection, size: view.size, scale: 1,
                                                   focal: focal, reach: 12)
    check("inside a filled outline: 0", inside == 0)
}

print("\n== 20,000 points ==")
do {
    var d = GPDrawing()
    var k = 0
    for s in 0..<100 {
        for i in 0..<200 {
            d.positions.append(SIMD3(Float(i) * 0.01, 0, Float(s) * 0.02 + 0.005 * sin(Float(i))))
            k += 1
        }
        d.offsets.append(k)
        d.cyclic.append(false)
        d.materials.append(0)
        d.fillIDs.append(s % 10 == 0 ? 1 : 0)
        d.hideStroke.append(false)
    }
    d.radii = [Float](repeating: 0.01, count: k)
    d.opacities = [Float](repeating: 1, count: k)
    var drawings = GreasePencilDrawings()
    drawings.blocks = [.init(layer: 0, onion: 0, frame: nil, drawing: d)]
    let started = Date()
    var built = GreasePencilGeometry.Built()
    for _ in 0..<5 { built = GreasePencilGeometry.build(info: simpleInfo(), drawings: drawings) }
    let ms = Date().timeIntervalSince(started) * 1000 / 5
    check(String(format: "built 20,000 points, 10 fills, in %.1f ms (swiftc -O): under 40 ms", ms),
          ms < 40 && built.points.count == 20_000)
    // The mirror: parse 20,000 points' record.
    var w = Wire()
    var strokes: [([SIMD3<Float>], Int32, Bool, Int32)] = []
    for s in 0..<100 { strokes.append((Array(d.positions[(s * 200)..<(s * 200 + 200)]), 0, false, 0)) }
    let block = drawing(&w, layerIndex: 0, strokes: strokes)
    w.record = ["layers": [layer("L")], "active_layer": 0, "materials": [material("M", stroke: [0, 0, 0, 1], fill: [0, 0, 0, 1])],
                "active_material": 0, "blocks": [block]]
    let json = w.json
    let parseStart = Date()
    var parsed: GreasePencilWire.Parsed?
    for _ in 0..<5 { parsed = w.bytes.withUnsafeBytes { GreasePencilWire.parse(record: json, blob: $0) } }
    let parseMs = Date().timeIntervalSince(parseStart) * 1000 / 5
    check(String(format: "parsed 20,000 points in %.1f ms: under 20 ms", parseMs),
          parseMs < 20 && parsed?.info.pointCount == 20_000)
    let obj = BKObject(name: "Big", kind: .cube)
    _ = w.bytes.withUnsafeBytes { obj.installGreasePencil(record: json, blob: $0) }
    let sameStart = Date()
    for _ in 0..<20 { _ = w.bytes.withUnsafeBytes { obj.installGreasePencil(record: json, blob: $0) } }
    let sameMs = Date().timeIntervalSince(sameStart) * 1000 / 20
    check(String(format: "an unchanged 20,000-point drawing costs %.3f ms a pass: under 2 ms", sameMs), sameMs < 2)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
