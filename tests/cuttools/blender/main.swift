import Foundation
import simd

// Two jobs for scripts/run-cuttools-blender-check.sh.
//
//   dump            Prints what the app sends for Loop Cut, the Knife and
//                   Subdivide Edge-Ring — `BpyBridge.performBody` and the
//                   re-runs — for verify.py to run in Blender. The calls are
//                   the Swift's, not copies of them.
//   preview <json>  Reads the cuts verify.py made (each mesh's vertices
//                   before, Blender's ring for the edge, and the vertices and
//                   edges after the cut) and checks the preview the viewport
//                   draws from that ring (`LoopCutRing.preview`) against them:
//                   every cut vertex previewed, nothing previewed where
//                   Blender made nothing, and every preview line an edge of
//                   the cut mesh. `--negative` draws the lines without
//                   Blender's orientation, which must fail.

let args = CommandLine.arguments

func emit(_ head: String, _ body: String) { print("### \(head)\n\(body)") }

/// ViewportCamera's view-projection, rebuilt here (it lives in the UI
/// module): a right-handed look-at, then a perspective with Metal's 0…1 depth.
func cameraMatrix(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>, fovY: Float = 0.6,
                  aspect: Float) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let r = simd_normalize(simd_cross(f, up))
    let u = simd_cross(r, f)
    let view = simd_float4x4(rows: [SIMD4(r.x, r.y, r.z, -simd_dot(r, eye)), SIMD4(u.x, u.y, u.z, -simd_dot(u, eye)),
                                    SIMD4(-f.x, -f.y, -f.z, simd_dot(f, eye)), SIMD4(0, 0, 0, 1)])
    let near: Float = 0.1, far: Float = 100
    let y = 1 / tan(fovY / 2), x = y / aspect
    let projection = simd_float4x4(rows: [SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                                          SIMD4(0, 0, far / (near - far), far * near / (near - far)), SIMD4(0, 0, -1, 0)])
    return projection * view
}

if args.count > 1 && args[1] == "dump" {
    // An edge index no mesh in the check has, replaced per edge by verify.py.
    let marker = 424_242
    let cut = LastOperator.loopCutAndSlide(edge: marker)
    emit("loopcut PERFORM", BpyBridge.performBody(for: cut))
    emit("loopcut UNDOPERFORM", BpyBridge.performBody(for: cut, backup: false))
    var three = LastOperator.loopCutAndSlide(edge: marker)
    three["number_cuts"] = 3
    three["value"] = 0.5
    emit("loopcut UNDOPERFORM3", BpyBridge.performBody(for: three, backup: false))
    var rerun = three
    rerun.subject = "@SUBJECT@"
    emit("loopcut RERUN3", rerun.rerunPython)
    emit("loopcut OBJECT1", BpyBridge.performBody(for: LastOperator.loopCutAndSlide(edge: marker, objectIndex: 1),
                                                  backup: false))
    emit("loopcut QUERY", LoopCut.ringQuery(marker))

    func knife(_ name: String, path: [SIMD3<Float>], eye: SIMD3<Float>, target: SIMD3<Float>, ortho: Bool) {
        let forward = simd_normalize(target - eye)
        var right = simd_cross(forward, SIMD3(0, 0, 1))
        right = simd_length(right) > 1e-6 ? simd_normalize(right) : SIMD3(1, 0, 0)
        let up = simd_cross(right, forward)
        for through in [false, true] {
            let op = LastOperator.knife(path: path, eye: eye, forward: forward, up: up, orthographic: ortho,
                                        cutThrough: through)
            emit("knife.\(name) \(through ? "THROUGH" : "FRONT")", BpyBridge.performBody(for: op, backup: false))
            if !through {
                emit("knife.\(name) PERFORM", BpyBridge.performBody(for: op, backup: true))
            }
            emit("knife.\(name) EYE", "\(eye.x),\(eye.y),\(eye.z);\(forward.x),\(forward.y),\(forward.z);\(ortho)")
            emit("knife.\(name) PATH", path.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";"))
        }
        var adjusted = LastOperator.knife(path: path, eye: eye, forward: forward, up: up, orthographic: ortho)
        adjusted["cut_through"] = 1
        emit("knife.\(name) ADJUSTED", BpyBridge.performBody(for: adjusted, backup: false))
    }
    // The views the check cuts a 2 m cube from, each path's points on lines
    // of sight from the eye (verify.py builds the same cube).
    func onSight(_ eye: SIMD3<Float>, _ target: SIMD3<Float>, _ sx: Float, _ sy: Float, _ depth: Float,
                 ortho: Bool) -> SIMD3<Float> {
        let f = simd_normalize(target - eye)
        let r = simd_normalize(simd_cross(f, SIMD3(0, 0, 1)))
        let u = simd_cross(r, f)
        if ortho { return eye + r * sx + u * sy + f * depth }
        return eye + simd_normalize(f + r * sx + u * sy) * depth
    }
    let eye = SIMD3<Float>(5, -6, 4)
    knife("persp", path: [onSight(eye, .zero, -0.35, 0.02, 9, ortho: false), onSight(eye, .zero, 0.35, -0.05, 9, ortho: false)],
          eye: eye, target: .zero, ortho: false)
    let high = SIMD3<Float>(-7, -3, 9)
    knife("persp3", path: [onSight(high, SIMD3(0, 0, 0.3), -0.3, 0.05, 10, ortho: false),
                           onSight(high, SIMD3(0, 0, 0.3), 0.02, 0.1, 10, ortho: false),
                           onSight(high, SIMD3(0, 0, 0.3), 0.3, -0.1, 10, ortho: false)],
          eye: high, target: SIMD3(0, 0, 0.3), ortho: false)
    let back = simd_normalize(SIMD3<Float>(0, 0, 0.3) - high) * -20 + SIMD3(0, 0, 0.3)
    knife("ortho", path: [onSight(back, SIMD3(0, 0, 0.3), -3, 0.05, 10, ortho: true),
                          onSight(back, SIMD3(0, 0, 0.3), 3, -0.1, 10, ortho: true)],
          eye: back, target: SIMD3(0, 0, 0.3), ortho: true)
    knife("miss", path: [onSight(eye, .zero, -0.35, 0.5, 9, ortho: false), onSight(eye, .zero, 0.35, 0.5, 9, ortho: false)],
          eye: eye, target: .zero, ortho: false)
    knife("behind", path: [onSight(eye, .zero, -0.35, 0, 9, ortho: false), eye - simd_normalize(-eye) * 2],
          eye: eye, target: .zero, ortho: false)

    // The Knife's snapping, as the viewport runs it (`KnifeSnap`, the tap's
    // own code): the cube verify.py makes, seen from (0, -6, 0) in a
    // 1000 × 750 point view with ViewportCamera's projection, each tap a view
    // point. What the snapped path cuts is held to Blender's knife result;
    // the same taps unsnapped are the negative control.
    func snappedKnife(_ name: String, taps: [SIMD3<Float>], nudge: [SIMD2<Float>] = [], unsnapped: Bool = false,
                      extra: [SIMD3<Float>] = []) {
        let eye = SIMD3<Float>(0, -6, 0), size = SIMD2<Float>(1000, 750)
        let view = KnifeView(viewProjection: cameraMatrix(eye: eye, target: .zero, up: SIMD3(0, 0, 1),
                                                          aspect: size.x / size.y), size: size)
        let cube: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
                                    SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
        let quads: [[Int]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
        var triangles: [Int] = [], polygons: [Int] = []
        for (f, q) in quads.enumerated() { triangles += [q[0], q[1], q[2], q[0], q[2], q[3]]; polygons += [f, f] }
        let cage = KnifeCage(positions: cube, triangles: triangles, trianglePolygons: polygons)
        var path = KnifePath(object: UUID())
        path.viewSize = size
        var said: [String] = []
        for (i, tap) in taps.enumerated() {
            let s = view.project(tap)! + (i < nudge.count ? nudge[i] : .zero)
            if unsnapped {
                let ray = view.ray(at: s)
                let hit = cage.rayCast(ray)
                path.add(hit?.point ?? tap)
                said.append("raw")
            } else {
                let snapped = KnifeSnap.snap(pointer: s, view: view, cage: cage, path: path.points) { r in
                    r.origin + r.direction * 6
                }
                path.add(snapped.point)
                said.append("\(snapped.target)")
            }
        }
        for p in extra { path.add(p) }
        let points = path.cutPoints(in: view)
        let op = LastOperator.knife(path: points, eye: eye, forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1),
                                    orthographic: false)
        emit("knife.\(name) FRONT", BpyBridge.performBody(for: op, backup: false))
        emit("knife.\(name) SNAPS", said.joined(separator: ";"))
        emit("knife.\(name) POINTS", points.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";"))
    }
    let edges: [SIMD3<Float>] = [SIMD3(-0.995, -1, 0.2), SIMD3(0.995, -1, 0.2)]
    snappedKnife("snap_edges", taps: edges)
    snappedKnife("raw_edges", taps: edges, unsnapped: true)
    snappedKnife("snap_corners", taps: [SIMD3(-0.99, -1, 0.99), SIMD3(0.99, -1, -0.99)])
    let square: [SIMD3<Float>] = [SIMD3(-0.5, -1, -0.5), SIMD3(0.5, -1, -0.5), SIMD3(0.5, -1, 0.5), SIMD3(-0.5, -1, 0.5)]
    // The fifth tap 3 points from the first: Blender's knife closes there.
    snappedKnife("snap_close", taps: square + [square[0]], nudge: [.zero, .zero, .zero, .zero, SIMD2(3, -2)])
    snappedKnife("raw_close", taps: square + [square[0]], nudge: [.zero, .zero, .zero, .zero, SIMD2(3, -2)],
                 unsnapped: true)
    // p2 on p1's line of sight at 1.8 times the depth (orbiting between taps
    // puts it there), then p3: cut as p1 to p3, what the overlay shows.
    let p1 = SIMD3<Float>(-0.5, -1, 0.1), p3 = SIMD3<Float>(0.6, -1, -0.15)
    snappedKnife("sight", taps: [p1], extra: [SIMD3<Float>(0, -6, 0) + (p1 - SIMD3<Float>(0, -6, 0)) * 1.8, p3])
    snappedKnife("sight_ref", taps: [p1], extra: [p3])

    for op in [LastOperator.Mesh.subdivideEdgeRing] {
        emit("edgering PERFORM", BpyBridge.performBody(for: LastOperator.mesh(op), backup: false))
    }
    exit(0)
}

guard args.count > 2, args[1] == "preview", let data = FileManager.default.contents(atPath: args[2]),
      let fixtures = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    print("usage: dump | preview <fixtures.json> [--negative]")
    exit(2)
}
let negative = args.contains("--negative")
var failures = 0
var byMesh: [String: (cuts: Int, edges: Int, agree: Int)] = [:]
var firstBad: [String] = []

func points(_ any: Any?) -> [SIMD3<Float>] {
    (any as? [[Double]] ?? []).map { SIMD3(Float($0[0]), Float($0[1]), Float($0[2])) }
}

for fixture in fixtures {
    let mesh = fixture["mesh"] as? String ?? "?"
    let cuts = fixture["cuts"] as? Int ?? 1
    let positions = points(fixture["before"])
    let made = points(fixture["new"])
    let edges = (fixture["edges_after"] as? [[[Double]]] ?? []).map { pair in
        (SIMD3(Float(pair[0][0]), Float(pair[0][1]), Float(pair[0][2])),
         SIMD3(Float(pair[1][0]), Float(pair[1][1]), Float(pair[1][2])))
    }
    guard var ring = LoopCutRing(json: fixture["ring"] as? String ?? "") else {
        failures += 1; firstBad.append("\(mesh): ring did not parse"); continue
    }
    if negative {
        // Each segment drawn between the edges' ends as the edge lists them,
        // not in the order Blender interpolates them.
        ring.segments = ring.segments.map { s in
            let a = ring.ends.first { Set($0) == Set([s[0], s[1]]) } ?? [s[0], s[1]]
            let b = ring.ends.first { Set($0) == Set([s[2], s[3]]) } ?? [s[2], s[3]]
            return a + b
        }
    }
    guard let preview = ring.preview(cuts: cuts, positions: positions) else {
        failures += 1; firstBad.append("\(mesh): no preview"); continue
    }
    func near(_ p: SIMD3<Float>, _ list: [SIMD3<Float>]) -> Bool { list.contains { simd_distance($0, p) < 2e-4 } }
    var previewed = preview.points
    for p in preview.lines where !near(p, previewed) { previewed.append(p) }
    let allMade = made.allSatisfy { near($0, previewed) }
    let allPreviewed = previewed.allSatisfy { near($0, made) }
    let linesAreEdges = stride(from: 0, to: preview.lines.count, by: 2).allSatisfy { i in
        let a = preview.lines[i], b = preview.lines[i + 1]
        return simd_distance(a, b) < 2e-4 || edges.contains { e in
            (simd_distance(e.0, a) < 2e-4 && simd_distance(e.1, b) < 2e-4)
                || (simd_distance(e.0, b) < 2e-4 && simd_distance(e.1, a) < 2e-4)
        }
    }
    let ok = allMade && allPreviewed && linesAreEdges && made.count == cuts * ring.edges.count
    var tally = byMesh["\(mesh) ×\(cuts)"] ?? (cuts, 0, 0)
    tally.edges += 1
    if ok { tally.agree += 1 } else if firstBad.count < 6 {
        firstBad.append("\(mesh) ×\(cuts) edge \(ring.edge): made \(made.count), previewed \(previewed.count), "
                        + "all made previewed \(allMade), all previewed made \(allPreviewed), lines are edges \(linesAreEdges)")
    }
    byMesh["\(mesh) ×\(cuts)"] = tally
    if !ok { failures += 1 }
}
for (mesh, tally) in byMesh.sorted(by: { $0.key < $1.key }) {
    let ok = tally.agree == tally.edges
    print((ok ? "  PASS  " : "  FAIL  ") + "\(mesh): the preview drawn from Blender's ring is the cut Blender made, "
          + "\(tally.agree) of \(tally.edges) edges")
}
for line in firstBad { print("        " + line) }
print(failures == 0 ? "PREVIEW ALL PASS" : "PREVIEW \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
