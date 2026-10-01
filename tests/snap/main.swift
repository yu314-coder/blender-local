import Foundation
import simd
import CoreGraphics

// Snapping a move to vertices, edges, edge centres, faces and face centres,
// on the Swift side: what the search finds under a pointer, what it leaves
// out, how a constrained move meets what it found, and that a drag commits
// exactly the move it previewed. Blender cannot snap headless (the round-1
// review measured it), so what Blender makes of the Python is held against
// its own meshes in scripts/run-tools-blender-check.sh.
//
// The meshes are installed as the mirror installs Blender's: shared corners,
// triangles, and the face corner behind each triangle corner, through
// `SceneMirror.installUVs` — which is what tells a quad's diagonal from its
// edges.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func near(_ a: SIMD3<Float>?, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
    guard let a else { return false }
    return simd_distance(a, b) < eps
}

let size = CGSize(width: 1193, height: 729)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 14
camera.target = SIMD3(2, 0, 0)
let projection = TransformGizmo.Projection(camera: camera, size: size)
let view = GeometrySnap.View(viewProjection: projection.matrix,
                             size: SIMD2(Float(size.width), Float(size.height)))
func screen(_ p: SIMD3<Float>) -> SIMD2<Float> { view.project(p)! }
func point(_ s: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)) }

// Blender's cube: eight shared corners, six quads wound outward.
let corners: [SIMD3<Float>] = [
    SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
    SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1),
]
let quads: [[Int]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]

/// Installs a mesh as the mirror does: evaluated, with its matrix, and with
/// the loops behind its triangles (fan-triangulated, as Blender's quads are).
func mirror(_ object: BKObject, _ positions: [SIMD3<Float>], _ faces: [[Int]],
            at matrix: simd_float4x4) {
    var indices: [UInt32] = [], loops: [UInt32] = []
    var next: UInt32 = 0
    for f in faces {
        for k in 1..<(f.count - 1) {
            indices += [UInt32(f[0]), UInt32(f[k]), UInt32(f[k + 1])]
            loops += [next, next + UInt32(k), next + UInt32(k + 1)]
        }
        next += UInt32(f.count)
    }
    var mesh = MeshData(vertices: positions.map { MeshVertex($0, SIMD3(0, 0, 1)) }, indices: indices)
    ModifierStack.recomputeNormals(&mesh, welded: true)
    object.setEvaluatedMesh(mesh)
    object.setMirroredTransform(matrix)
    let uvs = [Float](repeating: 0, count: Int(next) * 2)
    let seams: [UInt32] = []
    loops.withUnsafeBufferPointer { l in
        uvs.withUnsafeBufferPointer { u in
            seams.withUnsafeBufferPointer { s in
                _ = SceneMirror.installUVs(mapName: "UVMap", triangleLoops: l, loopUVs: u, seams: s, on: object)
            }
        }
    }
}

/// A (selected, at the origin) and B (at x = 4), both Blender's cube.
func scene() -> (BKScene, BKObject, BKObject) {
    let s = BKScene(startupFile: false)
    let a = s.add(.cube)
    a.name = "A"
    mirror(a, corners, quads, at: simd_float4x4(translation: .zero))
    let b = s.add(.cube)
    b.name = "B"
    mirror(b, corners, quads, at: simd_float4x4(translation: SIMD3(4, 0, 0)))
    s.selection = [a.id]
    s.activeID = a.id
    return (s, a, b)
}

func targets(_ s: BKScene, _ elements: Set<SnapElement>, xray: Bool = false) -> GeometrySnap.Targets {
    GeometrySnap.Targets(objects: s.objects, view: view, elements: elements,
                         excludedObjects: s.selection, occlusion: !xray)
}

let (s0, a0, b0) = scene()
let eye = camera.eye
let bCorners = corners.map { $0 + SIMD3(4, 0, 0) }
/// B's corner nearest the eye, which every face around it shows, and the one
/// farthest, which the cube hides.
let nearCorner = bCorners.min { simd_distance($0, eye) < simd_distance($1, eye) }!
let farCorner = bCorners.max { simd_distance($0, eye) < simd_distance($1, eye) }!
/// The edge from the near corner that is longest on screen.
let edgeEnd = bCorners.filter { c in
    (0..<3).filter { abs(c[$0] - nearCorner[$0]) > 1e-4 }.count == 1
}.max { simd_distance(screen($0), screen(nearCorner)) < simd_distance(screen($1), screen(nearCorner)) }!
func along(_ f: Float) -> SIMD3<Float> { nearCorner + (edgeEnd - nearCorner) * f }
/// A face of B that faces the eye and holds the near corner.
let faceNormal = [SIMD3<Float>(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0),
                  SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
    .filter { n in simd_dot(n, eye - (SIMD3(4, 0, 0) + n)) > 0
        && abs(simd_dot(nearCorner - SIMD3(4, 0, 0), n) - 1) < 1e-4 }
    .first!
let faceCentre = SIMD3<Float>(4, 0, 0) + faceNormal
func distanceToSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let t = max(0, min(1, simd_dot(p - a, b - a) / simd_length_squared(b - a)))
    return simd_distance(p, a + (b - a) * t)
}

print("== the two projections agree ==")
do {
    let p = SIMD3<Float>(1.3, -0.7, 2.2)
    let a = projection.project(p)!, b = view.project(p)!
    check("the search sees a point where the marker is drawn",
          abs(Float(a.x) - b.x) < 1e-3 && abs(Float(a.y) - b.y) < 1e-3, "\(a) \(b)")
    let ray = view.ray(SIMD2(400, 300))!, gizmoRay = TransformGizmo.ray(CGPoint(x: 400, y: 300),
                                                                        projection: projection)!
    check("and casts the same ray", simd_distance(ray.direction, gizmoRay.direction) < 1e-5)
}

print("\n== Vertex ==")
do {
    let t = targets(s0, [.vertex])
    let hit = t.find(screen(nearCorner) + SIMD2(4, -3))
    check("a corner 5 points from the pointer", hit?.kind == .vertex && near(hit?.location, nearCorner),
          String(describing: hit))
    let away = screen(nearCorner) + SIMD2(40, 0)
    let clear = bCorners.allSatisfy { simd_distance(screen($0), away) > 30 }
    check("nothing 40 points away: the reach is Blender's 30", clear && t.find(away) == nil)
    check("the selection never snaps to itself",
          t.find(screen(corners.min { simd_distance($0, eye) < simd_distance($1, eye) }!)) == nil)
    check("a corner the cube hides is out of reach",
          !near(t.find(screen(farCorner))?.location, farCorner))
    check("unless X-Ray is on", near(targets(s0, [.vertex], xray: true).find(screen(farCorner))?.location,
                                     farCorner))
    b0.visible = false
    check("a hidden object is no target", targets(s0, [.vertex]).find(screen(nearCorner)) == nil)
    b0.visible = true
}

print("\n== Edge, Edge Center, and a vertex found through its edge ==")
do {
    let middle = screen(along(0.5)) + SIMD2(0, 3)
    let edge = targets(s0, [.edge]).find(middle)
    check("Edge: the point of the edge nearest the pointer's ray",
          edge?.kind == .edge && distanceToSegment(edge!.location, nearCorner, edgeEnd) < 1e-4
              && simd_distance(screen(edge!.location), middle) < 4,
          String(describing: edge))
    check("with the edge's direction, for a constraint to meet",
          abs(abs(simd_dot(edge?.direction ?? .zero, simd_normalize(edgeEnd - nearCorner))) - 1) < 1e-5)
    let centre = targets(s0, [.edgeMidpoint]).find(middle)
    check("Edge Center: the middle exactly", centre?.kind == .edgeMidpoint
              && near(centre?.location, (nearCorner + edgeEnd) / 2), String(describing: centre))
    let end = screen(along(0.08))
    check("near the end, the centre is out of reach and Edge was not asked for",
          simd_distance(screen(along(0.5)), end) > 30 && targets(s0, [.edgeMidpoint]).find(end) == nil)
    let both = targets(s0, [.vertex, .edge])
    check("Vertex and Edge: the end within a third of it", both.find(end)?.kind == .vertex
              && near(both.find(end)?.location, nearCorner))
    check("and the edge in its middle third", both.find(middle)?.kind == .edge)
    let all = targets(s0, [.vertex, .edge, .edgeMidpoint])
    check("all three: the middle fifth is the centre", all.find(middle)?.kind == .edgeMidpoint)
    let third = screen(along(0.3))
    check("at 0.3 the end's zone, but the end is too far on screen, so the edge",
          simd_distance(screen(nearCorner), third) > 30 && all.find(third)?.kind == .edge,
          String(describing: all.find(third)))
    check("and at 0.08 the end", all.find(end)?.kind == .vertex)
}

print("\n== Blender's quads, not the viewport's triangles ==")
do {
    // The face's centre lies on both diagonals.
    let pointer = screen(faceCentre)
    check("a diagonal is no edge", targets(s0, [.edge]).find(pointer) == nil)
    let (s, _, b) = scene()
    // The simulator's own cube: no loops to tell a diagonal from an edge.
    b.setEvaluatedMesh(MeshBuilder.make(.cube))
    let plain = targets(s, [.edge]).find(pointer)
    check("a mesh with no loops is taken as its triangles, diagonal included",
          plain?.kind == .edge, String(describing: plain))

    let centre = targets(s0, [.faceMidpoint]).find(pointer + SIMD2(8, -5))
    check("Face Center: the quad's centre, not a triangle's", centre?.kind == .faceMidpoint
              && near(centre?.location, faceCentre), String(describing: centre))

    // bke::mesh::face_center_calc is the corners' mean, not the centroid.
    let t = BKScene(startupFile: false)
    let q = t.add(.plane)
    mirror(q, [SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 1, 0), SIMD3(0, 3, 0)], [[0, 1, 2, 3]],
           at: simd_float4x4(translation: SIMD3(-1, -1, 0)))
    t.selection = []
    let mean = SIMD3<Float>(1, 0, 0)
    let found = GeometrySnap.Targets(objects: t.objects, view: view, elements: [.faceMidpoint],
                                     excludedObjects: []).find(screen(mean) + SIMD2(3, 3))
    check("an uneven quad's centre is its corners' mean", near(found?.location, mean),
          String(describing: found))
}

print("\n== Face ==")
do {
    let pointer = screen(faceCentre + SIMD3(0.2, 0.2, 0.2) * (SIMD3(1, 1, 1) - abs(faceNormal)))
    let face = targets(s0, [.face]).find(pointer)
    check("where the pointer's ray meets the surface",
          face?.kind == .face && abs(simd_dot(face!.location - faceCentre, faceNormal)) < 1e-4
              && simd_distance(screen(face!.location), pointer) < 0.5, String(describing: face))
    check("with the face's normal", abs(abs(simd_dot(face?.direction ?? .zero, faceNormal)) - 1) < 1e-5)
    let mixed = targets(s0, [.face, .vertex])
    check("a vertex in reach wins over the face", mixed.find(screen(nearCorner) + SIMD2(3, 2))?.kind == .vertex)
    check("and the face stands where no vertex is", mixed.find(screen(faceCentre))?.kind == .face)
    check("the moving object's own faces are no surface", targets(s0, [.face]).find(screen(.zero)) == nil)
}

print("\n== what is not a mesh ==")
do {
    let s = BKScene(startupFile: false)
    let empty = s.add(.cube)
    empty.blenderType = "EMPTY"
    empty.setEvaluatedMesh(MeshData(vertices: [MeshVertex(.zero, SIMD3(0, 0, 1))], indices: []))
    empty.setMirroredTransform(simd_float4x4(translation: SIMD3(0, 3, 0)))
    let lens = s.add(.cube)
    lens.blenderType = "CAMERA"
    lens.setEvaluatedMesh(MeshData(vertices: [MeshVertex(.zero, SIMD3(0, 0, 1))], indices: []))
    lens.setMirroredTransform(simd_float4x4(translation: SIMD3(0, -3, 0)))
    let wire = s.add(.circle)
    wire.setEvaluatedMesh(MeshData(vertices: [MeshVertex(SIMD3(-1, 0, 0), .zero), MeshVertex(SIMD3(1, 0, 0), .zero)],
                                   wireEdges: [0, 1]))
    wire.setMirroredTransform(simd_float4x4(translation: SIMD3(4, 3, 1)))
    s.selection = []
    let t = GeometrySnap.Targets(objects: s.objects, view: view, elements: [.vertex, .edge], excludedObjects: [])
    let origin = t.find(screen(SIMD3(0, 3, 0)) + SIMD2(2, 2))
    check("an empty snaps by its origin, as a point", origin?.kind == .point && near(origin?.location, SIMD3(0, 3, 0)),
          String(describing: origin))
    check("a camera does not", t.find(screen(SIMD3(0, -3, 0))) == nil)
    let line = t.find(screen(SIMD3(4.1, 3, 1)))
    check("a wire's edges are edges", line?.kind == .edge && abs(line!.location.y - 3) < 1e-4,
          String(describing: line))
}

print("\n== how a constrained move meets the target ==")
do {
    let x = SIMD3<Float>(1, 0, 0), z = SIMD3<Float>(0, 0, 1)
    let source = SIMD3<Float>(0, 0, 0)
    let point = GeometrySnap.Hit(kind: .vertex, location: SIMD3(3, 2, 1))
    check("free: all the way", GeometrySnap.move(source, to: point, constraint: .free) == SIMD3(3, 2, 1))
    check("on an axis, a point is projected", GeometrySnap.move(source, to: point, constraint: .axis(x)) == SIMD3(3, 0, 0))
    check("on a plane too", GeometrySnap.move(source, to: point, constraint: .plane(normal: z)) == SIMD3(3, 2, 0))
    let edge = GeometrySnap.Hit(kind: .edge, location: SIMD3(3, -1, 5), direction: SIMD3(0, 1, 0))
    check("an axis meets an edge where it passes nearest",
          near(GeometrySnap.move(source, to: edge, constraint: .axis(x)), SIMD3(3, 0, 0)))
    let along = GeometrySnap.Hit(kind: .edge, location: SIMD3(3, 2, 1), direction: x)
    check("and one running along the axis is projected",
          near(GeometrySnap.move(source, to: along, constraint: .axis(x)), SIMD3(3, 0, 0)))
    let upright = GeometrySnap.Hit(kind: .edge, location: SIMD3(2, 3, 5), direction: z)
    check("a plane meets an edge where it crosses it",
          near(GeometrySnap.move(source, to: upright, constraint: .plane(normal: z)), SIMD3(2, 3, 0)))
    let flat = GeometrySnap.Hit(kind: .edge, location: SIMD3(2, 3, 5), direction: x)
    check("and one parallel to it is projected",
          near(GeometrySnap.move(source, to: flat, constraint: .plane(normal: z)), SIMD3(2, 3, 0)))
    let slope = GeometrySnap.Hit(kind: .face, location: SIMD3(4, 0, 0), direction: simd_normalize(SIMD3(1, 1, 0)))
    check("an axis meets a face where it crosses its plane",
          near(GeometrySnap.move(source, to: slope, constraint: .axis(x)), SIMD3(4, 0, 0)))
    let wall = GeometrySnap.Hit(kind: .face, location: SIMD3(4, 2, 0), direction: SIMD3(0, 1, 0))
    check("a face parallel to the axis is projected",
          near(GeometrySnap.move(source, to: wall, constraint: .axis(x)), SIMD3(4, 0, 0)))
    check("a plane projects a face (Blender's face variant is disabled)",
          near(GeometrySnap.move(source, to: slope, constraint: .plane(normal: z)), SIMD3(4, 0, 0)))
}

print("\n== Snap With Closest ==")
do {
    let box = GeometrySnap.boxCorners(a0)
    check("an object's box corners", box.count == 8 && Set(box.map { "\($0)" }) == Set(corners.map { "\($0)" }))
    check("the nearest one to the target moves onto it",
          GeometrySnap.closest(box, to: SIMD3(3, 0.9, 0.8)) == SIMD3(1, 1, 1))
}

print("\n== a drag previews and commits the snap ==")

/// One drag through the real session, as MetalViewportView runs it.
func drag(_ s: BKScene, _ handle: TransformGizmo.Handle, from start: CGPoint, to end: CGPoint,
          mode: TransformGizmo.Mode = .translate, step: Float = 0.25)
    -> (TransformGizmo.Session, TransformGizmo.Result, GeometrySnap.Hit?, String) {
    var options = ViewportOptions()
    options.snapIncrement = step
    let g = TransformGizmo.make(mode: mode, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: handle, at: start, gizmo: g, scene: s,
                                              camera: camera, size: size, options: options)
    let (result, hit) = TransformGizmo.snapping(TransformGizmo.resolve(session, at: end)!,
                                                session: session, at: end)
    TransformGizmo.apply(result, session: session)
    return (session, result, hit, TransformGizmo.python(result, session: session))
}

/// The three numbers of `value=(…)`, as Blender will parse them.
func value(_ python: String) -> SIMD3<Float>? {
    guard let open = python.range(of: "value=("),
          let close = python[open.upperBound...].firstIndex(of: ")") else { return nil }
    let numbers = python[open.upperBound..<close].split(separator: ",").compactMap {
        Float($0.trimmingCharacters(in: .whitespaces)) }
    return numbers.count == 3 ? SIMD3(numbers[0], numbers[1], numbers[2]) : nil
}

/// How many places the first number of `value=(…)` is written to.
func decimals(_ python: String) -> Int? {
    guard let open = python.range(of: "value=(") else { return nil }
    let first = python[open.upperBound...].prefix { $0 != "," }
    return first.split(separator: ".").last?.count
}

do {
    let (s, a, _) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    let target = nearCorner
    let (_, result, hit, python) = drag(s, .screen, from: point(screen(.zero)), to: point(screen(target) + SIMD2(3, 2)))
    guard case .translate(let d) = result else { fatalError() }
    let source = GeometrySnap.closest(corners, to: target)!
    check("Closest: A's nearest corner lands on B's corner",
          hit?.kind == .vertex && near(source + d, target, 2e-6), "\(source + d) vs \(target)")
    check("the preview put A there", near(a.location, d, 1e-7) && near(a.modelMatrix.columns.3.xyz, d, 1e-7))
    check("and the Python sends exactly that move, to six places",
          python.hasPrefix(String(format: "bpy.ops.transform.translate(value=(%.6f, %.6f, %.6f)", d.x, d.y, d.z))
              && value(python) == d, python)
}
do {
    let (s, a, _) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    s.tools.target = .median
    let (_, result, _, _) = drag(s, .screen, from: point(screen(.zero)), to: point(screen(nearCorner) + SIMD2(3, 2)))
    guard case .translate(let d) = result else { fatalError() }
    check("Median: the origin lands on the corner", near(d, nearCorner, 2e-6) && near(a.location, nearCorner, 2e-6))
}
do {
    let (s, a, _) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    let g = TransformGizmo.make(mode: .translate, scene: s, options: ViewportOptions(), camera: camera, size: size)!
    let tip = projection.project(g.origin + g.axes[0] * g.radius)!
    let (_, result, hit, python) = drag(s, .axis(0), from: tip, to: point(screen(nearCorner) + SIMD2(-2, 3)))
    guard case .translate(let d) = result else { fatalError() }
    let source = GeometrySnap.closest(corners, to: nearCorner)!
    check("along X, only X moves, to the corner's X",
          hit != nil && d.y == 0 && d.z == 0 && abs(source.x + d.x - nearCorner.x) < 2e-6, "\(d)")
    check("and the constraint is still sent", python.contains("constraint_axis=(True, False, False)")
              && a.location.y == 0 && a.location.z == 0)
}
do {
    // Nothing in reach: Grid, then Increment, as when no geometry is chosen.
    let (s, a, _) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex, .grid]
    let start = point(screen(.zero)), end = CGPoint(x: start.x - 37, y: start.y + 150)
    let (_, _, hit, python) = drag(s, .screen, from: start, to: end)
    let onGrid = { (v: Float) in abs(v / 0.25 - (v / 0.25).rounded()) < 1e-4 }
    check("Grid when no vertex is near", hit == nil && onGrid(a.location.x) && onGrid(a.location.y),
          "\(a.location)")
    check("and a move that found none is still written to six places",
          python.hasPrefix("bpy.ops.transform.translate(value=(") && value(python) != nil
              && decimals(python) == 6,
          python)
    let (t, b, _) = scene()
    t.tools.useSnap = true
    t.tools.elements = [.vertex, .increment]
    let a0 = b.location
    _ = drag(t, .screen, from: start, to: end)
    let moved = b.location - a0
    check("Increment when no vertex is near", onGrid(moved.x) && onGrid(moved.y) && onGrid(moved.z), "\(moved)")
}
do {
    let (s, _, _) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    let c = projection.project(.zero)!
    let (session, _, hit, python) = drag(s, .axis(2), from: CGPoint(x: c.x + 100, y: c.y),
                                         to: point(screen(nearCorner)), mode: .rotate)
    check("a turn does not snap to geometry", hit == nil && session.geometry == nil
              && python.contains("value=") && !python.contains("0.000000"), python)
    let off = BKScene(startupFile: false)
    let o = off.add(.cube)
    off.selection = [o.id]
    let g = TransformGizmo.make(mode: .translate, scene: off, options: ViewportOptions(), camera: camera, size: size)!
    let plain = TransformGizmo.beginSession(handle: .screen, at: .zero, gizmo: g, scene: off,
                                            camera: camera, size: size)
    check("with the magnet off there is nothing to search and four places",
          plain.geometry == nil && TransformGizmo.places(plain) == 4)
}

print("\n== while editing ==")

/// A 5 × 5 grid of Blender's, 1 apart, in edit mode, with Blender's report of
/// which vertices are selected.
func editGrid(selected: Set<Int>) -> (BKScene, BKObject) {
    var positions: [SIMD3<Float>] = []
    for y in 0..<5 { for x in 0..<5 { positions.append(SIMD3(Float(x) - 2, Float(y) - 2, 0)) } }
    var faces: [[Int]] = []
    for y in 0..<4 { for x in 0..<4 { let i = y * 5 + x; faces.append([i, i + 1, i + 6, i + 5]) } }
    let s = BKScene(startupFile: false)
    let o = s.add(.grid)
    mirror(o, positions, faces, at: simd_float4x4(translation: SIMD3(3, 0, 0.5)))
    s.selection = [o.id]
    s.activeID = o.id
    s.setMode(.edit)
    var edges: [UInt32] = []
    for y in 0..<5 { for x in 0..<4 { edges += [UInt32(y * 5 + x), UInt32(y * 5 + x + 1)] } }
    for y in 0..<4 { for x in 0..<5 { edges += [UInt32(y * 5 + x), UInt32(y * 5 + x + 5)] } }
    let report = BlenderEditReport(
        selectMode: 1,
        vertexSelected: positions.indices.map { selected.contains($0) ? 1 : 0 },
        trianglePolygons: (0..<32).map { UInt32($0 / 2) },
        polygonSelected: Array(repeating: 0, count: 16),
        edgeVertices: edges,
        edgeSelected: Array(repeating: 0, count: edges.count / 2))
    let mirrored = s.mirrorEditSelection(report, on: o)
    precondition(mirrored, "the grid did not mirror as Blender's mesh")
    return (s, o)
}
func world(_ o: BKObject, _ i: Int) -> SIMD3<Float> { (o.modelMatrix * SIMD4(o.mesh.vertices[i].position, 1)).xyz }

do {
    let (s, o) = editGrid(selected: [12])
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    let start = world(o, 12), target = world(o, 18)
    let (session, result, hit, python) = drag(s, .screen, from: point(screen(start)),
                                              to: point(screen(target) + SIMD2(2, -3)))
    check("a selected vertex lands on another of the same mesh",
          hit?.kind == .vertex && near(world(o, 12), target, 2e-6), "\(world(o, 12)) vs \(target)")
    guard case .translate(let d) = result else { fatalError() }
    check("by the move the Python sends", value(python) == d && near(d, target - start, 2e-6), python)
    check("the object stays where it is", o.modelMatrix.columns.3.xyz == SIMD3(3, 0, 0.5))
    check("and the search had the rest of the mesh", session.geometry?.targets.isEmpty == false)
}
do {
    let (s, o) = editGrid(selected: [12])
    s.tools.useSnap = true
    s.tools.elements = [.vertex, .edge, .edgeMidpoint]
    let start = world(o, 12)
    // Where the selected vertex and the edges that touch it are, on screen.
    let spots = [start] + [13, 7, 11, 17].map { (start + world(o, $0)) / 2 }
    var landed: [GeometrySnap.Hit?] = []
    var drift: Float = 0
    for spot in spots {
        let (session, _, hit, _) = drag(s, .screen, from: point(screen(start)), to: point(screen(spot)))
        landed.append(hit)
        // The drag's own session: a new one would capture the mesh this
        // preview moved, and the next drag would start from there.
        TransformGizmo.rollBack(session)
        drift = max(drift, simd_distance(world(o, 12), start))
    }
    check("each drag is rolled back to where the vertex started, so each starts there",
          drift == 0, "\(drift)")
    let touching = [13, 7, 11, 17].map { world(o, $0) }
    // The far end of such an edge is still a vertex of edges that do not
    // touch it, so it stays a target.
    check("neither the selected vertex nor an edge that touches it is a target",
          landed.allSatisfy { hit in
              guard let hit else { return true }
              return simd_distance(hit.location, start) > 1e-3
                  && touching.allSatisfy { end in
                      distanceToSegment(hit.location, start, end) > 1e-3
                          || simd_distance(hit.location, end) < 1e-5 }
          }, landed.map { String(describing: $0) }.joined(separator: "; "))
    check("while the next edge along is one",
          landed.contains { $0 != nil })
}
do {
    let (s, o) = editGrid(selected: [12])
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    s.tools.proportionalEdit = true
    s.tools.falloff = .linear
    s.tools.size = 1.5
    let target = world(o, 13)
    let (session, _, hit, _) = drag(s, .screen, from: point(screen(world(o, 12))), to: point(screen(target)))
    check("proportional editing's neighbours move, so they are no target either",
          session.edit!.factors[13] > 0 && !near(hit?.location, target), String(describing: hit))
}

print("\n== what moves with the selection is no target, and the preview carries it ==")
do {
    // B is A's child, as the mirror reports Blender's `parent`: measured in
    // 5.2.1, translating a parent alone moved its unselected child with it.
    let (s, _, b) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    b.parentName = "A"
    b.dependencies = ["A"]
    let before = b.modelMatrix
    let (session, result, hit, _) = drag(s, .screen, from: point(screen(.zero)),
                                         to: point(screen(nearCorner) + SIMD2(3, 2)))
    check("a child of what moves is no target", hit == nil && session.geometry == nil,
          String(describing: hit))
    // The move as the commit prints it, which is what the preview ran.
    guard case .translate(let d) = TransformGizmo.committed(result, places: TransformGizmo.places(session))
    else { fatalError() }
    check("the preview moves it by the parent's move, as the commit will",
          session.followers.count == 1 && near(b.modelMatrix.columns.3.xyz, before.columns.3.xyz + d, 1e-5),
          "\(b.modelMatrix.columns.3.xyz) vs \(before.columns.3.xyz + d)")
    TransformGizmo.rollBack(session)
    check("and the roll-back puts it back as the mirror had it", b.modelMatrix == before)

    let (u, _, free) = scene()
    u.tools.useSnap = true
    u.tools.elements = [.vertex]
    let (_, _, control, _) = drag(u, .screen, from: point(screen(.zero)), to: point(screen(nearCorner) + SIMD2(3, 2)))
    check("the same drag with no parent lands on it", control?.kind == .vertex && free.parentName == nil)
}
do {
    // Affect Only Parents keeps an unselected child in place, and Blender's
    // snapping then keeps it as a target (BA_TRANSFORM_LOCKED_IN_PLACE clears
    // BA_SNAP_FIX_DEPS_FIASCO, transform_convert_object.cc in 5.3).
    let (s, _, b) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    s.tools.affectOnlyParents = true
    b.parentName = "A"
    b.dependencies = ["A"]
    let before = b.modelMatrix
    let (session, _, hit, _) = drag(s, .screen, from: point(screen(.zero)),
                                    to: point(screen(nearCorner) + SIMD2(3, 2)))
    check("Affect Only Parents: the child that stays is a target again",
          hit?.kind == .vertex && near(hit?.location, nearCorner), String(describing: hit))
    check("and the preview leaves it where it is", session.followers.isEmpty && b.modelMatrix == before)
    TransformGizmo.rollBack(session)
    b.dependencies = ["A", "Z"]
    let c = s.add(.cube)
    c.name = "Z"
    c.dependencies = ["A"]
    let (_, _, second, _) = drag(s, .screen, from: point(screen(.zero)),
                                 to: point(screen(nearCorner) + SIMD2(3, 2)))
    check("unless something else it reads moves it", second == nil, String(describing: second))
}
do {
    // Affect Only Origins: Blender snaps onto anything, the moved object's
    // own geometry too (SCE_SNAP_TARGET_ALL for CTX_OBMODE_XFORM_OBDATA), and
    // the geometry does not move with the drag.
    let (s, a, b) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    s.tools.affectOnlyOrigins = true
    b.parentName = "A"
    b.dependencies = ["A"]
    let aBefore = a.modelMatrix
    let (session, _, hit, _) = drag(s, .screen, from: point(screen(.zero)),
                                    to: point(screen(nearCorner) + SIMD2(3, 2)))
    check("Affect Only Origins: even what moves with it is a target",
          hit?.kind == .vertex && near(hit?.location, nearCorner), String(describing: hit))
    check("the selection's geometry is not drawn moving", a.modelMatrix == aBefore)
    check("and the child follows the origin, as measured in 5.2.1",
          session.followers.count == 1 && b.modelMatrix.columns.3.x > 4.5, "\(b.modelMatrix.columns.3)")
    TransformGizmo.rollBack(session)
}
do {
    // A turn carries a child about the parent's pivot, however it is turned.
    let (s, a, b) = scene()
    b.parentName = "A"
    b.dependencies = ["A"]
    b.setMirroredTransform(simd_float4x4(translation: SIMD3(4, 0, 0)) * simd_float4x4(eulerXYZ: SIMD3(0.3, 0, 0.2)))
    let before = b.modelMatrix
    let g = TransformGizmo.make(mode: .rotate, scene: s, options: ViewportOptions(), camera: camera, size: size)!
    let c = projection.project(g.origin)!
    let session = TransformGizmo.beginSession(handle: .axis(2), at: CGPoint(x: c.x + 100, y: c.y), gizmo: g,
                                              scene: s, camera: camera, size: size)
    let end = CGPoint(x: c.x, y: c.y - 100)
    TransformGizmo.apply(TransformGizmo.resolve(session, at: end)!, session: session)
    let expected = a.modelMatrix * before
    var gap: Float = 0
    for k in 0..<4 { gap = max(gap, simd_length(b.modelMatrix[k] - expected[k])) }
    check("a turned parent carries its child as parenting does (world = parent × local)",
          gap < 1e-4 && simd_distance(b.modelMatrix.columns.3.xyz, before.columns.3.xyz) > 1, "\(gap)")
    TransformGizmo.rollBack(session)
}
do {
    // What depends on the moved object without being its child: a Boolean's
    // base mesh when its cutter moves, a Copy Location follower, an object
    // whose modifier reads the moved one — and so on down the chain.
    let (s, a, b) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    b.dependencies = ["A"]
    check("an object whose modifier reads the one moved is no target",
          drag(s, .screen, from: point(screen(.zero)), to: point(screen(nearCorner) + SIMD2(3, 2))).2 == nil)
    check("and it is not carried like a child", b.modelMatrix.columns.3.xyz == SIMD3(4, 0, 0))
    let c = s.add(.cube)
    c.name = "C"
    c.dependencies = ["B"]
    check("nor is what depends on that", s.dependents(of: [a.id]) == [a.id, b.id, c.id])
    b.dependencies = ["Z"]
    check("while one that reads something else is", s.dependents(of: [a.id]) == [a.id])
}
do {
    // Proportional editing in object mode flushes the flag from every visible
    // object that is neither selected nor the selection's parent or child
    // (`count_proportional_objects`), reached by its falloff or not.
    let (s, a, b) = scene()
    let p = s.add(.cube)
    p.name = "P"
    mirror(p, corners, quads, at: simd_float4x4(translation: SIMD3(0, -4, 0)))
    a.parentName = "P"
    a.dependencies = ["P"]
    s.selection = [a.id]
    s.activeID = a.id
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    s.tools.proportionalObjects = true
    s.tools.size = 0.5
    check("with it on, only the selection's ancestors stay in reach",
          s.movedByObjectDrag(selection: [a.id], proportional: true) == [a.id, b.id]
              && s.movedByObjectDrag(selection: [a.id], proportional: false) == [a.id])
    let pCorner = corners.map { $0 + SIMD3(0, -4, 0) }.min { simd_distance($0, eye) < simd_distance($1, eye) }!
    let (session, _, hit, _) = drag(s, .screen, from: point(screen(.zero)), to: point(screen(pCorner) + SIMD2(2, 2)))
    check("so the parent is a target", hit?.kind == .vertex && near(hit?.location, pCorner), String(describing: hit))
    check("and it gets no weight of its own", session.neighbours.allSatisfy { $0.object !== p })
    TransformGizmo.rollBack(session)
    check("while B, out of the falloff's reach, is not",
          drag(s, .screen, from: point(screen(.zero)), to: point(screen(nearCorner) + SIMD2(3, 2))).2 == nil)
}

print("\n== a curve with no surface snaps by its control points ==")
do {
    // A Bezier circle as the mirror sends it: its tessellated wire to draw
    // (48 points, measured in 5.2.1) and its 4 knots to snap to.
    let s = BKScene(startupFile: false)
    let circle = s.add(.circle)
    circle.blenderType = "CURVE"
    let ring = (0..<48).map { k -> SIMD3<Float> in
        let a = Float(k) / 48 * 2 * .pi
        return SIMD3(cos(a), sin(a), 0)
    }
    circle.setEvaluatedMesh(MeshData(vertices: ring.map { MeshVertex($0, .zero) },
                                     wireEdges: (0..<48).flatMap { [UInt32($0), UInt32(($0 + 1) % 48)] }))
    circle.setMirroredTransform(simd_float4x4(translation: SIMD3(4, 0, 1.2)))
    let knots: [SIMD3<Float>] = [SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0)]
    circle.snapPoints = knots
    s.selection = []
    func find(_ elements: Set<SnapElement>, _ p: SIMD3<Float>) -> GeometrySnap.Hit? {
        GeometrySnap.Targets(objects: s.objects, view: view, elements: elements, excludedObjects: []).find(screen(p))
    }
    let diagonal = SIMD3<Float>(4 + cos(.pi / 4), sin(.pi / 4), 1.2)
    check("not a tessellation point between knots",
          knots.allSatisfy { simd_distance(screen($0 + SIMD3(4, 0, 1.2)), screen(diagonal)) > 30 }
              && find([.vertex], diagonal) == nil, String(describing: find([.vertex], diagonal)))
    let knot = SIMD3<Float>(5, 0, 1.2)
    check("a knot, as a point", find([.vertex], knot)?.kind == .point && near(find([.vertex], knot)?.location, knot))
    check("and no edge, edge centre or face", find([.edge, .edgeMidpoint, .face, .faceMidpoint], diagonal) == nil
              && find([.edge], knot) == nil)
    circle.snapPoints = nil
    check("where a curve that is snapped as its mesh gives its tessellation",
          find([.vertex], diagonal)?.kind == .vertex)
}
do {
    // A knot behind a surface is still in reach: `snapCurve` skips the
    // occlusion plane.
    let (s, _, _) = scene()
    let curve = s.add(.circle)
    curve.blenderType = "CURVE"
    curve.setEvaluatedMesh(MeshData(vertices: [MeshVertex(.zero, .zero), MeshVertex(SIMD3(0.5, 0, 0), .zero)],
                                    wireEdges: [0, 1]))
    curve.setMirroredTransform(simd_float4x4(translation: farCorner))
    curve.snapPoints = [.zero]
    s.selection = []
    let hit = targets(s, [.vertex]).find(screen(farCorner))
    check("a knot the cube hides is in reach", hit?.kind == .point && near(hit?.location, farCorner),
          String(describing: hit))
}
do {
    // Display As Bounds: `snap_obj_fn` snaps such an object to nothing.
    let (s, _, b) = scene()
    b.displaysBounds = true
    check("an object displayed as its bounds is no target", targets(s, [.vertex, .edge, .face]).find(screen(nearCorner)) == nil)
    b.blenderType = "EMPTY"
    b.setEvaluatedMesh(MeshData(vertices: [MeshVertex(.zero, SIMD3(0, 0, 1))], indices: []))
    check("but an empty so displayed still snaps by its origin (`snap_object_center` comes first)",
          targets(s, [.vertex]).find(screen(SIMD3(4, 0, 0)))?.kind == .point)
}

print("\n== Face Center under the pointer: its corners first ==")
do {
    // snap_polygon_mesh tries the corners of the polygon hit when no edge
    // element is chosen; a corner found that way leaves Blender with an
    // element nobody chose, and no snap at all.
    let towards = simd_normalize(screen(faceCentre) - screen(nearCorner))
    let pointer = screen(nearCorner) + towards * 4
    check("the pointer is on the face, 4 points from its corner and far from its centre",
          simd_distance(pointer, screen(faceCentre)) > 20
              && targets(s0, [.face]).find(pointer).map { abs(simd_dot($0.direction, faceNormal)) > 0.999 } == true)
    check("Face Center alone: nothing", targets(s0, [.faceMidpoint]).find(pointer) == nil,
          String(describing: targets(s0, [.faceMidpoint]).find(pointer)))
    check("Face and Face Center: not even the face", targets(s0, [.face, .faceMidpoint]).find(pointer) == nil)
    check("with Vertex too, the corner", targets(s0, [.vertex, .faceMidpoint]).find(pointer)?.kind == .vertex)
    check("and on the centre, the centre",
          targets(s0, [.faceMidpoint]).find(screen(faceCentre) + SIMD2(2, 1))?.kind == .faceMidpoint)
}

print("\n== Wireframe is X-Ray ==")
do {
    let (s, _, _) = scene()
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    let g = TransformGizmo.make(mode: .translate, scene: s, options: ViewportOptions(), camera: camera, size: size)!
    let solid = TransformGizmo.beginSession(handle: .screen, at: point(screen(.zero)), gizmo: g, scene: s,
                                            camera: camera, size: size)
    let wire = TransformGizmo.beginSession(handle: .screen, at: point(screen(.zero)), gizmo: g, scene: s,
                                           camera: camera, size: size, wireframe: true)
    check("in Solid the corner the cube hides is out of reach",
          !near(solid.geometry?.targets.find(screen(farCorner))?.location, farCorner))
    check("in Wireframe, which draws it, it is not (show_xray_wireframe, factory True)",
          near(wire.geometry?.targets.find(screen(farCorner))?.location, farCorner))
}

print("\n== an edge's direction is Blender's, under an uneven scale ==")
do {
    let s = BKScene(startupFile: false)
    let wire = s.add(.circle)
    wire.setEvaluatedMesh(MeshData(vertices: [MeshVertex(.zero, .zero), MeshVertex(SIMD3(1, 1, 0), .zero)],
                                   wireEdges: [0, 1]))
    wire.setMirroredTransform(simd_float4x4(translation: SIMD3(3, 2, 0.5)) * simd_float4x4(scale: SIMD3(3, 1, 1)))
    s.selection = []
    let t = GeometrySnap.Targets(objects: s.objects, view: view, elements: [.edge], excludedObjects: [])
    let hit = t.find(screen(SIMD3(3, 2, 0.5) + SIMD3(1.5, 0.5, 0)))
    let blender = simd_normalize(SIMD3<Float>(1.0 / 3, 1, 0))
    let drawn = simd_normalize(SIMD3<Float>(3, 1, 0))
    check("the local edge carried as a normal, (M·Mᵀ)⁻¹ applied to the world edge",
          hit?.kind == .edge && abs(abs(simd_dot(hit!.direction, blender)) - 1) < 1e-5,
          String(describing: hit))
    check("which is not the edge as drawn", abs(abs(simd_dot(hit?.direction ?? .zero, drawn)) - 1) > 0.1)
    // An axis meets that direction, not the drawn edge.
    let moved = GeometrySnap.move(.zero, to: hit!, constraint: .axis(SIMD3(0, 1, 0)))
    let wanted = GeometrySnap.rayRayFactor(.zero, SIMD3(0, 1, 0), hit!.location, hit!.direction)!
    check("and a constrained move meets it there", near(moved, SIMD3(0, wanted, 0), 1e-4), "\(moved)")
    wire.setMirroredTransform(simd_float4x4(translation: SIMD3(3, 2, 0.5)) * simd_float4x4(eulerXYZ: SIMD3(0, 0, 0.4))
                                  * simd_float4x4(scale: SIMD3(2, 2, 2)))
    let even = GeometrySnap.Targets(objects: s.objects, view: view, elements: [.edge], excludedObjects: [])
    let m = wire.modelMatrix
    let a = (m * SIMD4(0, 0, 0, 1)).xyz, b = (m * SIMD4(1, 1, 0, 1)).xyz
    let straight = even.find(screen((a + b) / 2))
    check("an even scale leaves it the edge itself",
          abs(abs(simd_dot(straight?.direction ?? .zero, simd_normalize(b - a))) - 1) < 1e-5)
}

print("\n== Target Selection while editing ==")
do {
    let (s, o) = editGrid(selected: [12])
    let other = s.add(.cube)
    other.name = "Other"
    mirror(other, corners, quads, at: simd_float4x4(translation: SIMD3(3, 0, 3)))
    // Adding selects what it added; the grid is the one being edited.
    s.selection = [o.id]
    s.activeID = o.id
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    let start = world(o, 12), own = world(o, 18)
    let otherCorner = corners.map { $0 + SIMD3(3, 0, 3) }.min { simd_distance($0, eye) < simd_distance($1, eye) }!
    func land(_ to: SIMD3<Float>) -> GeometrySnap.Hit? {
        let (session, _, hit, _) = drag(s, .screen, from: point(screen(start)), to: point(screen(to) + SIMD2(2, -2)))
        TransformGizmo.rollBack(session)
        return hit
    }
    check("the factory's: the edited mesh and the rest", near(land(own)?.location, own)
              && near(land(otherCorner)?.location, otherCorner))
    s.tools.snapSelf = false
    check("Include Active off: not the edited mesh (use_snap_self)",
          !near(land(own)?.location, own) && near(land(otherCorner)?.location, otherCorner))
    s.tools.snapSelf = true
    s.tools.snapNonEdited = false
    check("Include Non-edited off: nothing else (use_snap_nonedit)",
          near(land(own)?.location, own) && !near(land(otherCorner)?.location, otherCorner))
}

print("\n== Auto Merge welds as Blender does, at Blender's threshold ==")
do {
    func line(_ xs: [Float]) -> [SIMD3<Float>] { xs.map { SIMD3($0, 0, 0) } }
    // Each measured in 5.2.1 headless, as AutoMerge's comment records.
    check("moved to 0.9995: welded into the vertex at 1 (inclusive, 0.001)",
          AutoMerge.targets(line([0.9995, 1]), moved: [0], threshold: 0.001) == [1, 1])
    check("moved to 0.9985: not", AutoMerge.targets(line([0.9985, 1]), moved: [0], threshold: 0.001) == [0, 1])
    check("two that did not move never weld",
          AutoMerge.targets(line([0.1, 1, 5, 5.0005]), moved: [0], threshold: 0.001) == [0, 1, 2, 3])
    check("two that moved weld into the lower index",
          AutoMerge.targets(line([0.49995, 0.50005, 3]), moved: [0, 1], threshold: 0.001) == [0, 0, 2])
    check("a moved one goes to the nearest that stayed",
          AutoMerge.targets(line([1.0004, 1, 1.0009]), moved: [0], threshold: 0.001) == [1, 1, 2])
    // Halves are exact in Float, so the two distances tie exactly.
    check("and on a tie to the lower index",
          AutoMerge.targets(line([1, 0.5, 1.5]), moved: [0], threshold: 0.5) == [1, 1, 2])
    check("at a threshold of 0, only a vertex exactly on another",
          AutoMerge.targets(line([1, 1, 2.001, 2]), moved: [0, 2], threshold: 0) == [1, 1, 2, 3])
}
do {
    // The 3 × 3 grid's centre moved onto its neighbour: 9 vertices with Auto
    // Merge off and 8 with it on (measured in 5.2.1), as the preview shows.
    var positions: [SIMD3<Float>] = []
    for y in 0..<3 { for x in 0..<3 { positions.append(SIMD3(Float(x) - 1, Float(y) - 1, 0)) } }
    var indices: [UInt32] = []
    for y in 0..<2 { for x in 0..<2 {
        let i = UInt32(y * 3 + x)
        indices += [i, i + 1, i + 4, i, i + 4, i + 3]
    } }
    var mesh = MeshData(vertices: positions.map { MeshVertex($0, SIMD3(0, 0, 1)) }, indices: indices)
    mesh.vertices[4].position = SIMD3(1, 0, 0)
    let welded = AutoMerge.weld(mesh, moved: [4], threshold: 0.001)
    check("the grid's centre onto its neighbour: 8 vertices, where the neighbour was",
          welded.vertices.count == 8 && welded.vertices.contains { $0.position == SIMD3(1, 0, 0) }
              && welded.indices.count / 3 == 6, "\(welded.vertices.count) \(welded.indices.count / 3)")
}
do {
    // Through a drag: the edit grid's vertex 12 snapped onto vertex 18.
    for on in [false, true] {
        let (s, o) = editGrid(selected: [12])
        s.tools.useSnap = true
        s.tools.elements = [.vertex]
        s.tools.autoMerge = on
        let (session, _, hit, _) = drag(s, .screen, from: point(screen(world(o, 12))),
                                        to: point(screen(world(o, 18)) + SIMD2(2, -3)))
        check("Auto Merge \(on ? "on" : "off"): the snap puts one vertex on another and the preview shows "
              + (on ? "24" : "25"),
              hit?.kind == .vertex && o.mesh.vertices.count == (on ? 24 : 25), "\(o.mesh.vertices.count)")
        TransformGizmo.rollBack(session)
    }
    let (s, o) = editGrid(selected: [12])
    s.tools.autoMerge = true
    s.tools.mergeThreshold = 0.001
    let start = world(o, 12)
    // 0.01 short of vertex 13 along X: the app's old 0.02 welded this.
    let g = TransformGizmo.make(mode: .translate, scene: s, options: ViewportOptions(), camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .screen, at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    TransformGizmo.apply(.translate(SIMD3(0.99, 0, 0)), session: session)
    check("0.01 away stays apart at Blender's 0.001", o.mesh.vertices.count == 25)
    TransformGizmo.rollBack(session)
    s.tools.mergeThreshold = 0.02
    let wide = TransformGizmo.beginSession(handle: .screen, at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    TransformGizmo.apply(.translate(SIMD3(0.99, 0, 0)), session: wide)
    check("and welds at the scene's own 0.02 when that is what it holds", o.mesh.vertices.count == 24)
    TransformGizmo.rollBack(wide)
    check("the roll-back restores all 25", o.mesh.vertices.count == 25 && world(o, 12) == start)
    // The simulator's own translate welds by the same call.
    s.tools.mergeThreshold = 0.001
    _ = s.perform(TransformOperation(kind: .translate(SIMD3(1, 0, 0)), pivot: .point(start)))
    check("the simulator's commit welds too", o.mesh.vertices.count == 24)
}

print("\n== the marker is Blender's symbol ==")
do {
    let c = CGPoint(x: 100, y: 50)
    let vertex = TransformGizmo.snapMarker(.vertex, at: c)
    check("a square on a vertex", vertex.count == 1 && vertex[0].points.count == 4 && vertex[0].closed
              && vertex[0].points.contains(CGPoint(x: 92.5, y: 57.5)))
    let edge = TransformGizmo.snapMarker(.edge, at: c)
    check("a bow tie on an edge, its first stroke a diagonal",
          edge.count == 1 && edge[0].points[0] == CGPoint(x: 92.5, y: 57.5)
              && edge[0].points[1] == CGPoint(x: 107.5, y: 42.5))
    let middle = TransformGizmo.snapMarker(.edgeMidpoint, at: c)
    check("a triangle, point up, on an edge's centre",
          middle.count == 1 && middle[0].points.count == 3 && middle[0].points[1].y < c.y)
    check("a circle on a face, with a dot on its centre, with a cross on a point",
          TransformGizmo.snapMarker(.face, at: c).count == 1
              && TransformGizmo.snapMarker(.faceMidpoint, at: c).count == 2
              && TransformGizmo.snapMarker(.point, at: c).count == 3)
}

print("\n== the search keeps up with a drag ==")
// Gathering runs on the main thread when the finger goes down, and the mirror
// takes meshes of up to 10 million vertices, so it is timed on a big one too.
// It hashed every triangle side and allocated two arrays per polygon: 434 ms
// at 1.28 million triangles in the review's harness, 460 ms here.
for (n, gatherLimit) in [(200, 60.0), (800, 250.0)] {
    // n × n quads, with loops: 80,000 and 1,280,000 triangles.
    var positions: [SIMD3<Float>] = []
    for y in 0...n { for x in 0...n { positions.append(SIMD3(Float(x) / Float(n) * 6 - 3, Float(y) / Float(n) * 6 - 3,
                                                             0.3 * sin(Float(x) * 0.2))) } }
    var faces: [[Int]] = []
    for y in 0..<n { for x in 0..<n { let i = y * (n + 1) + x; faces.append([i, i + 1, i + n + 2, i + n + 1]) } }
    let s = BKScene(startupFile: false)
    let big = s.add(.grid)
    mirror(big, positions, faces, at: simd_float4x4(translation: SIMD3(2, 0, 0)))
    s.selection = []
    let begin = Date()
    let t = GeometrySnap.Targets(objects: s.objects, view: view,
                                 elements: [.vertex, .edge, .edgeMidpoint, .face, .faceMidpoint],
                                 excludedObjects: [])
    let built = Date().timeIntervalSince(begin) * 1000
    let searches = Date()
    var found = 0
    for k in 0..<120 {
        let p = SIMD2<Float>(Float(300 + k * 5), Float(250 + (k % 7) * 20))
        if t.find(p) != nil { found += 1 }
    }
    let each = Date().timeIntervalSince(searches) * 1000 / 120
    print(String(format: "  %d triangles: gathering the targets %.1f ms; one search %.2f ms (%d of 120 found)",
                 2 * n * n, built, each, found))
    check("gathered at touch-down in under \(Int(gatherLimit)) ms", built < gatherLimit)
    check("and searched well inside a 60 Hz frame", each < 8 && found > 60)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
