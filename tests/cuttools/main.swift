import Foundation
import simd

// Loop Cut and the Knife's Swift half (CutTools.swift): which of Blender's
// edges a drawn edge is, the ring's preview from Blender's answer, the calls
// the commit sends, the knife's path, and the refusals. What Blender makes of
// the calls is scripts/run-cuttools-blender-check.sh.
//
//     scripts/run-cuttools-tests.sh

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "\n        " + detail()))
    if !ok { failures += 1 }
}
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-6) -> Bool { simd_distance(a, b) <= eps }

/// The cube the mirror hands over: eight shared corners, two triangles a
/// face, and Blender's twelve edges in an order of Blender's own (not the
/// viewport's), as `blenderEdges` carries them.
func cube() -> (MeshData, EditTopology) {
    let p: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
                             SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
    var indices: [UInt32] = [], polys: [UInt32] = []
    for (f, q) in quads.enumerated() {
        indices += [q[0], q[1], q[2], q[0], q[2], q[3]]
        polys += [UInt32(f), UInt32(f)]
    }
    let mesh = MeshData(vertices: p.map { MeshVertex($0, normalize($0)) }, indices: indices)
    // Blender's edge order: anything but the viewport's.
    let blender: [UInt32] = [4, 5, 0, 1, 7, 6, 2, 3, 0, 3, 1, 2, 4, 7, 5, 6, 0, 4, 1, 5, 2, 6, 3, 7]
    let sides = Set(quads.flatMap { q in (0..<4).map { k -> Set<UInt32> in [q[k], q[(k + 1) % 4]] } })
    var real = Set<Int>()
    for e in 0..<(mesh.edges.count / 2) where sides.contains([mesh.edges[2 * e], mesh.edges[2 * e + 1]]) {
        real.insert(e)
    }
    return (mesh, EditTopology(vertexCount: 8, polygonCount: 6, trianglePolygons: polys, realEdges: real,
                               blenderEdges: blender))
}

print("\n== a drawn edge is named by Blender's index ==")
do {
    let (mesh, topology) = cube()
    var named = 0, diagonals = 0, wrong = 0
    for e in 0..<(mesh.edges.count / 2) {
        let a = mesh.edges[2 * e], b = mesh.edges[2 * e + 1]
        let index = LoopCut.blenderEdge(drawn: e, cage: mesh, topology: topology)
        if topology.realEdges.contains(e) {
            guard let index else { wrong += 1; continue }
            let x = topology.blenderEdges[2 * index], y = topology.blenderEdges[2 * index + 1]
            if Set([x, y]) == Set([a, b]) { named += 1 } else { wrong += 1 }
        } else if index == nil {
            diagonals += 1
        } else {
            wrong += 1
        }
    }
    check("each of the cube's twelve edges is named by the Blender edge with its two vertices", named == 12 && wrong == 0,
          "named \(named), wrong \(wrong)")
    check("and none of the six diagonals the triangles add is named at all", diagonals == 6, "\(diagonals)")
    // The viewport's own numbering is not Blender's: a cut sent by it would
    // cut some other edge (the negative control for the mapping).
    let viewportIndices = (0..<(mesh.edges.count / 2)).filter { topology.realEdges.contains($0) }
    let same = viewportIndices.filter { LoopCut.blenderEdge(drawn: $0, cage: mesh, topology: topology) == $0 }
    check("the viewport's own edge numbers are not Blender's (so sending them would cut other edges)",
          same.count < viewportIndices.count, "\(same.count) of \(viewportIndices.count) coincide")
    let stale = EditTopology(vertexCount: 26, polygonCount: 24, trianglePolygons: [], blenderEdges: topology.blenderEdges)
    check("a report about another mesh names nothing", LoopCut.blenderEdge(drawn: 0, cage: mesh, topology: stale) == nil)
    check("nor does an index past the drawn edges",
          LoopCut.blenderEdge(drawn: 999, cage: mesh, topology: topology) == nil
            && LoopCut.blenderEdge(drawn: -1, cage: mesh, topology: topology) == nil)
}

print("\n== the ring Blender answers, and its preview ==")
// Blender's answer for the cube's bottom-front edge (0–1) as
// `_blenderkit_loopcut.ring_json` prints it: the four edges along X, each
// preview segment joining two of them, both oriented the same way.
let cubeRing = """
{"edge":2,"edges":[2,0,4,6],"ends":[[0,1],[4,5],[7,6],[3,2]],"segments":[[0,1,4,5],[4,5,7,6],[7,6,3,2],[3,2,0,1]],"single":false,"vertices":8}
"""
do {
    let (mesh, _) = cube()
    let positions = mesh.vertices.map(\.position)
    guard let ring = LoopCutRing(json: cubeRing) else { check("the ring parses", false); fatalError() }
    check("the ring parses: four edges, four segments, not single",
          ring.edges.count == 4 && ring.segments.count == 4 && !ring.single && ring.vertexCount == 8)
    let one = ring.preview(cuts: 1, positions: positions)
    check("one cut: four lines, each across a face, through the middle of the edges along X",
          one?.lines.count == 8 && one?.points.isEmpty == true
            && (one?.lines.allSatisfy { abs($0.x) < 1e-6 } ?? false), "\(one?.lines ?? [])")
    let three = ring.preview(cuts: 3, positions: positions)
    let xs = Set((three?.lines ?? []).map { ($0.x * 4).rounded() / 4 })
    check("three cuts: twelve lines at a quarter, a half and three quarters along each edge",
          three?.lines.count == 24 && xs == [-0.5, 0, 0.5], "\(xs)")
    // Both ends of a line at the same fraction: the lines do not cross the
    // face (Blender's `edgering_find_order`).
    let parallel = stride(from: 0, to: three?.lines.count ?? 0, by: 2).allSatisfy {
        abs(three!.lines[$0].x - three!.lines[$0 + 1].x) < 1e-6
    }
    check("and each line keeps to one fraction from end to end", parallel)
    check("an answer about a mesh with fewer vertices draws nothing",
          ring.preview(cuts: 1, positions: Array(positions.prefix(5))) == nil)
    let single = LoopCutRing(json: """
        {"edge":7,"edges":[7],"ends":[[0,1]],"segments":[],"single":true,"vertices":8}
        """)
    let dots = single?.preview(cuts: 2, positions: positions)
    check("an edge with no quad previews points on it alone, as Blender does",
          dots?.lines.isEmpty == true && dots?.points.count == 2
            && near(dots!.points[0], SIMD3(-1.0 / 3, -1, -1)) && near(dots!.points[1], SIMD3(1.0 / 3, -1, -1)),
          "\(dots?.points ?? [])")
    check("a refusal is read as one", LoopCutRing(json: #"{"refused": "edge 4 is hidden"}"#) == nil
          && LoopCutRing.refusal(json: #"{"refused": "edge 4 is hidden"}"#) == "edge 4 is hidden")
    check("and anything else is neither", LoopCutRing(json: "Traceback") == nil
          && LoopCutRing.refusal(json: "Traceback") == nil
          && LoopCutRing(json: #"{"edge":1,"edges":[1],"ends":[[0]],"segments":[],"single":true,"vertices":8}"#) == nil)
    check("the question asked is Blender's ring for that edge",
          LoopCut.ringQuery(4) == "import _blenderkit_loopcut\n_blenderkit_loopcut.ring_json(4)")
}

print("\n== the cut: Blender's Loop Cut and Slide, as its Info editor logs it ==")
do {
    let op = LastOperator.loopCutAndSlide(edge: 4)
    let call = "bpy.ops.mesh.loopcut_slide(MESH_OT_loopcut={\"number_cuts\": 1, \"smoothness\": 0, "
        + "\"falloff\": 'INVERSE_SQUARE', \"object_index\": 0, \"edge_index\": 4}, "
        + "TRANSFORM_OT_edge_slide={\"value\": 0, \"use_even\": False, \"flipped\": False, \"use_clamp\": True, "
        + "\"mirror\": True, \"correct_uv\": True})"
    let lines = op.python.split(separator: "\n").map(String.init)
    check("named Loop Cut and Slide, its operator's name, for the panel and the step", op.name == "Loop Cut and Slide")
    check("the call is Blender's, each sub-operator's arguments in one dictionary", lines.last == "    " + call,
          op.python)
    check("inside the borrowed 3D View", lines.dropLast().last == "with _blenderkit_context.temp_override_view3d('Loop Cut'):",
          op.python)
    check("after the checks Blender does not make, with the panel's cuts",
          op.python.contains("_blenderkit_loopcut.check(4, 1, 0)"), op.python)
    check("MESH_OT_loopcut= is written once (two would be a TypeError)",
          op.python.components(separatedBy: "MESH_OT_loopcut=").count == 2
            && op.python.components(separatedBy: "TRANSFORM_OT_edge_slide=").count == 2)
    var adjusted = op
    adjusted["number_cuts"] = 3
    adjusted["value"] = 0.5
    check("the panel's Number of Cuts and Factor re-run the same edge",
          adjusted.python.contains("\"number_cuts\": 3") && adjusted.python.contains("\"value\": 0.5")
            && adjusted.python.contains("\"edge_index\": 4") && adjusted.python.contains("check(4, 3, 0)"),
          adjusted.python)
    adjusted["number_cuts"] = 1e9
    check("Number of Cuts is held to Blender's soft range, 1 to 100",
          adjusted["number_cuts"] == 100 && adjusted.python.contains("\"number_cuts\": 100"))
    check("the redo panel's rows are Blender's Loop Cut and Edge Slide rows, Clamp, Mirror Editing and Correct UVs too",
          op.parameters.map(\.label) == ["Number of Cuts", "Smoothness", "Falloff", "Factor", "Even", "Flipped",
                                          "Clamp", "Mirror Editing", "Correct UVs"], "\(op.parameters.map(\.label))")
    check("with what Blender's own Loop Cut records: Clamp on, Mirror Editing on, Correct UVs on",
          op["use_clamp"] == 1 && op["mirror"] == 1 && op["correct_uv"] == 1)
    var far = op
    far["value"] = 1.5
    check("Factor takes Blender's hard range, past 1, where Clamp decides", far.python.contains("\"value\": 1.5"),
          far.python)
    // Blender's panel greys none of these (transform_poll_property has no
    // rule for them, MESH_OT_loopcut no poll_property): round 4's review.
    check("no row is greyed, at Smoothness 0 and with Even off as anywhere",
          op.parameters.allSatisfy { op.isActive($0) && $0.activeWhen == nil })
    check("Smoothness and Factor are bare numbers, not metres",
          op.parameters.first { $0.key == "value" }?.display == "0.000"
            && op.parameters.first { $0.key == "smoothness" }?.display == "0.000")
    check("its CANCELLED is said in words, out of the Info line",
          op.executedPython.contains("if 'CANCELLED' in bpy.ops.mesh.loopcut_slide(") && !op.python.contains("CANCELLED"))
    check("it is an edit-mode operator that keeps the mesh to re-run it",
          op.needsEditMode && op.restoration == .restoreMesh)
    check("another object's index goes to Blender as it is",
          LastOperator.loopCutAndSlide(edge: 9, cuts: 2, objectIndex: 1).python.contains("\"object_index\": 1, \"edge_index\": 9"))
}

print("\n== the Knife's cut ==")
do {
    let path: [SIMD3<Float>] = [SIMD3(-2.1727, -2.0362, 0.2796), SIMD3(2.5704, 1.5546, -0.2456), SIMD3(0.1, 0.30000001, 1e-05)]
    let op = LastOperator.knife(path: path, eye: SIMD3(5, -6, 4), forward: SIMD3(-0.57, 0.68, -0.46),
                                up: SIMD3(0, 0, 1), orthographic: false)
    check("named Knife Topology Tool, what Blender's history calls a knife cut", op.name == "Knife Topology Tool")
    check("the Info line is the call that runs, Knife Project's, Cut Through off",
          op.python.hasSuffix("    bpy.ops.mesh.knife_project(cut_through=False)"), op.python)
    check("inside the path's own view, every point to the Float's last digit",
          op.python.contains("with _blenderkit_knife.drawing([(-2.1727, -2.0362, 0.2796), (2.5704, 1.5546, -0.2456), "
                             + "(0.1, 0.3, 1e-05)], eye=(5.0, -6.0, 4.0), forward=(-0.57, 0.68, -0.46), "
                             + "up=(0, 0, 1.0), ortho=False):"), op.python)
    var through = op
    through["cut_through"] = 1
    check("Cut Through on, in the panel", through.python.contains("knife_project(cut_through=True)"))
    check("orthographic, said so",
          LastOperator.knife(path: path, eye: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), orthographic: true,
                             cutThrough: true).python.contains("ortho=True):\n    bpy.ops.mesh.knife_project(cut_through=True)"))
}

print("\n== the Knife's path ==")
do {
    var path = KnifePath(object: UUID())
    path.add(SIMD3(0, 0, 0))
    path.add(SIMD3(0, 0, 0))
    path.add(SIMD3(.nan, 0, 0))
    check("a second tap where the last was, or a point that is not a number, adds nothing", path.points.count == 1)
    check("one point cannot cut", !path.canCut && path.lines.isEmpty)
    path.add(SIMD3(1, 0, 0)); path.add(SIMD3(1, 1, 0))
    check("three points: two segments drawn, and Confirm can cut",
          path.canCut && path.lines == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)])
    let ray = (origin: SIMD3<Float>(0, -10, 0), direction: simd_normalize(SIMD3<Float>(0.1, 1, 0)))
    let hit = KnifePath.point(ray: ray, surface: SIMD3(0.9, -1, 0), centre: .zero, forward: SIMD3(0, 1, 0))
    check("on the mesh, the point is where the line of sight meets it", hit == SIMD3(0.9, -1, 0))
    let off = KnifePath.point(ray: ray, surface: nil, centre: SIMD3(0, 3, 0), forward: SIMD3(0, 1, 0))
    check("past it, on the same line of sight at the depth of the object's middle",
          abs(off.y - 3) < 1e-5 && abs(off.x - 1.3) < 1e-5, "\(off)")
}

print("\n== the Knife snaps as Blender's knife snaps ==")
/// A view-projection as ViewportCamera makes one: right-handed look-at, then
/// a perspective (or orthographic) projection with Metal's 0…1 depth.
func viewProjection(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>, fovY: Float = 0.6,
                    aspect: Float, ortho: Float? = nil) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let r = simd_normalize(simd_cross(f, up))
    let u = simd_cross(r, f)
    let view = simd_float4x4(rows: [SIMD4(r.x, r.y, r.z, -simd_dot(r, eye)), SIMD4(u.x, u.y, u.z, -simd_dot(u, eye)),
                                    SIMD4(-f.x, -f.y, -f.z, simd_dot(f, eye)), SIMD4(0, 0, 0, 1)])
    let near: Float = 0.1, far: Float = 100
    let projection: simd_float4x4
    if let h = ortho {
        let w = h * aspect
        projection = simd_float4x4(rows: [SIMD4(1 / w, 0, 0, 0), SIMD4(0, 1 / h, 0, 0),
                                          SIMD4(0, 0, -1 / (far - near), -near / (far - near)), SIMD4(0, 0, 0, 1)])
    } else {
        let y = 1 / tan(fovY / 2), x = y / aspect
        projection = simd_float4x4(rows: [SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                                          SIMD4(0, 0, far / (near - far), far * near / (near - far)), SIMD4(0, 0, -1, 0)])
    }
    return projection * view
}
do {
    let (mesh, topology) = cube()
    let object = BKObject(name: "Cube", kind: .cube)
    object.setEvaluatedMesh(mesh)
    object.editTopology = topology
    guard let cage = KnifeCage(object: object) else { check("the mirror's cube is a cage to snap to", false); fatalError() }
    let sides = Set(cage.polygonEdges.flatMap { $0 }.map { [$0.x, $0.y] })
    check("each face's sides are its four edges, no diagonal: 24 sides, the cube's 12 edges",
          cage.polygonEdges.allSatisfy { $0.count == 4 } && sides.count == 12, "\(cage.polygonEdges.map(\.count))")
    let size = SIMD2<Float>(1000, 750)
    let view = KnifeView(viewProjection: viewProjection(eye: SIMD3(0, -6, 0), target: .zero, up: SIMD3(0, 0, 1),
                                                        aspect: size.x / size.y), size: size)
    func at(_ p: SIMD3<Float>) -> SIMD2<Float> { view.project(p)! }
    let ray = view.ray(at: at(SIMD3(0.3, -1, 0.2)))
    let back = ray.origin + ray.direction * simd_dot(SIMD3<Float>(0.3, -1, 0.2) - ray.origin, ray.direction)
    check("a view point's line of sight goes back through the point it shows", near(back, SIMD3(0.3, -1, 0.2), 1e-4), "\(back)")
    func snap(_ s: SIMD2<Float>, path: [SIMD3<Float>] = [], cage: KnifeCage? = nil, view v: KnifeView? = nil) -> KnifeSnap.Snapped {
        KnifeSnap.snap(pointer: s, view: v ?? view, cage: cage ?? KnifeCage(object: object)!, path: path) { r in r.origin + r.direction * 6 }
    }
    // The review's path: about 2 px inside each side edge of the front face.
    let left = at(SIMD3(-0.995, -1, 0.2)), right = at(SIMD3(0.995, -1, 0.2))
    let edgeLeft = at(SIMD3(-1, -1, 0.2))
    check("the review's points are a few points inside the side edges here (\(String(format: "%.1f", simd_distance(left, edgeLeft))) pt)",
          simd_distance(left, edgeLeft) > 1 && simd_distance(left, edgeLeft) < 10)
    let a = snap(left), b = snap(right)
    check("the point 2 px inside the left edge lands on it, x = -1 at its height",
          { if case .edge = a.target { return true }; return false }() && abs(a.point.x + 1) < 1e-6
            && abs(a.point.y + 1) < 1e-6 && abs(a.point.z - 0.2) < 1e-3, "\(a)")
    check("and the right one on the right edge, x = 1",
          { if case .edge = b.target { return true }; return false }() && abs(b.point.x - 1) < 1e-6 && abs(b.point.z - 0.2) < 1e-3, "\(b)")
    let middle = snap(at(SIMD3(0, -1, 0.2)))
    check("in the middle of the face, far from every edge, the point stays on the face",
          middle.target == .face(2) && near(middle.point, SIMD3(0, -1, 0.2), 1e-4), "\(middle)")
    let corner = snap(at(SIMD3(-0.99, -1, 0.99)))
    check("near a corner it lands on the corner vertex, exactly", { if case .vertex = corner.target { return true }; return false }()
          && near(corner.point, SIMD3(-1, -1, 1), 0), "\(corner)")
    // Blender's knife_snap_size: a small face on screen (both ends of a
    // side within twice the distance) shrinks the distance it snaps within.
    let far = KnifeView(viewProjection: viewProjection(eye: SIMD3(0, -300, 0), target: .zero, up: SIMD3(0, 0, 1),
                                                       aspect: size.x / size.y), size: size)
    let tiny = KnifeSnap.snapSize(10, around: far.project(SIMD3(0, -1, 0))!, polygon: 2, cage: cage, view: far)
    check("a face a few points across halves and halves again the distance (\(tiny) pt of 10), as Blender's density does",
          tiny < 10 && tiny > 0, "\(tiny)")
    // Off the mesh, within ten points of its outline: Blender's knife finds
    // the face there (EDBM_face_find_nearest) and snaps to its edge.
    let outside = at(SIMD3(-1, -1, 0.2)) + SIMD2(-4, 0)
    let o = snap(outside)
    check("4 points outside the cube's outline it snaps onto the outline's edge",
          { if case .edge = o.target { return true }; return false }() && abs(o.point.x + 1) < 1e-6, "\(o)")
    let faraway = snap(at(SIMD3(-1, -1, 0.2)) + SIMD2(-30, 0))
    check("30 points out it stays off the mesh", faraway.target == .none, "\(faraway)")
    // The path's own points: a tap near the first point closes on it.
    let first = SIMD3<Float>(-0.5, -1, -0.5)
    let path = [first, SIMD3(0.5, -1, -0.5), SIMD3(0.5, -1, 0.5)]
    let close = snap(at(first) + SIMD2(3, -2), path: path)
    check("a tap 3.6 pt from the path's first point lands on it exactly, closing the path",
          close.target == .pathPoint(0) && close.point == first, "\(close)")
    let behind = SIMD3<Float>(-0.5, 1, -0.5)
    let hidden = snap(at(behind) + SIMD2(2, 2), path: [behind])
    check("a path point behind the cube, where the view does not see it, is not snapped to", hidden.target != .pathPoint(0), "\(hidden)")
    let offMeshPoint = SIMD3<Float>(-3, -1, 0)
    let offTap = snap(at(offMeshPoint) + SIMD2(1, 1), path: [offMeshPoint])
    check("nor is one off the mesh, which is none of the knife's vertices", offTap.target == .none, "\(offTap)")
    // The negative control: without snapping the review's point stays in the face.
    var unsnapped = cage
    unsnapped = KnifeCage(positions: cage.positions, triangles: cage.triangles, trianglePolygons: cage.trianglePolygons)
    let farther = KnifeView(viewProjection: viewProjection(eye: SIMD3(0, -6, 0), target: .zero, up: SIMD3(0, 0, 1),
                                                           fovY: 0.05, aspect: size.x / size.y), size: size)
    let zoomed = KnifeSnap.snap(pointer: farther.project(SIMD3(-0.995, -1, 0.2))!, view: farther, cage: unsnapped, path: []) { r in r.origin }
    check("the negative control: zoomed in until the same point is far from the edge on screen, it stays in the face",
          zoomed.target == .face(2), "\(zoomed)")
    // Orthographic.
    let orthoView = KnifeView(viewProjection: viewProjection(eye: SIMD3(0, -6, 0), target: .zero, up: SIMD3(0, 0, 1),
                                                             aspect: size.x / size.y, ortho: 2), size: size)
    let oa = KnifeSnap.snap(pointer: orthoView.project(SIMD3(-0.99, -1, 0.2))!, view: orthoView, cage: cage, path: []) { r in r.origin }
    check("orthographic, the same: onto the edge", { if case .edge = oa.target { return true }; return false }()
          && abs(oa.point.x + 1) < 1e-5, "\(oa)")
    // Blender's own cage, as `cage_json` prints it.
    let json = #"{"positions": [-1,-1,-1, 1,-1,-1, 1,-1,1, -1,-1,1], "faces": [[0,1,2,3]], "vertices": 4}"#
    let quad = KnifeCage(json: json)
    check("Blender's cage from its line: one quad, two triangles, four sides",
          quad?.triangles.count == 6 && quad?.polygonEdges.first?.count == 4)
    check("and a line that is not one is refused", KnifeCage(json: #"{"refused": "x"}"#) == nil
          && KnifeCage(json: #"{"positions": [0,0,0], "faces": [[0,1,2]]}"#) == nil)
}

print("\n== the path Confirm cuts, from the view it is cut from ==")
do {
    let size = SIMD2<Float>(1000, 750)
    let eye = SIMD3<Float>(0, -6, 0)
    let view = KnifeView(viewProjection: viewProjection(eye: eye, target: .zero, up: SIMD3(0, 0, 1), aspect: size.x / size.y),
                         size: size)
    let p1 = SIMD3<Float>(-0.5, -1, 0), p3 = SIMD3<Float>(0.5, -1, 0)
    let p2 = eye + (p1 - eye) * 1.8
    var path = KnifePath(object: UUID())
    for p in [p1, p2, p3] { path.add(p) }
    check("p1, p2 on its line of sight at 1.8 times the depth, p3: cut as p1 to p3, what the overlay shows",
          path.cutPoints(in: view) == [p1, p3], "\(path.cutPoints(in: view))")
    var two = KnifePath(object: UUID())
    two.add(p1); two.add(p2)
    check("p1 and p2 alone: one point, nothing to cut", two.cutPoints(in: view) == [p1])
    var loop = KnifePath(object: UUID())
    let square: [SIMD3<Float>] = [SIMD3(-0.5, -1, -0.5), SIMD3(0.5, -1, -0.5), SIMD3(0.5, -1, 0.5), SIMD3(-0.5, -1, 0.5)]
    for p in square { loop.add(p) }
    loop.add(SIMD3(-0.5, -1, -0.5))
    check("a path that comes back to its first point closes on it", loop.cutPoints(in: view) == square + [square[0]])
    let other = KnifeView(viewProjection: viewProjection(eye: SIMD3(6, 0, 0), target: .zero, up: SIMD3(0, 0, 1),
                                                         aspect: size.x / size.y), size: size)
    check("from another view the same p1, p2, p3 are three points (the negative control)",
          path.cutPoints(in: other) == [p1, p2, p3], "\(path.cutPoints(in: other))")
    var spread = KnifePath(object: UUID())
    spread.add(p1); spread.add(p1 + SIMD3(0.01, 0, 0)); spread.add(p3)
    let gap = simd_distance(view.project(p1)!, view.project(p1 + SIMD3(0.01, 0, 0))!)
    check("points \(String(format: "%.1f", gap)) pt apart on screen stay apart", spread.cutPoints(in: view).count == 3)
    check("the Knife's cut acts on every mesh in Edit Mode, so the backup's re-run is not offered with another selected",
          LastOperator.knife(path: [p1, p3], eye: eye, forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1),
                             orthographic: false).actsOnSelection)
}

print("\n== what is refused, and in which words ==")
do {
    let (mesh, topology) = cube()
    let object = BKObject(name: "Cube", kind: .cube)
    object.setEvaluatedMesh(mesh)
    object.editTopology = topology
    check("on Blender's own cube both tools can cut",
          CutTool.loopCut.refusal(object: object, usesRealBlender: true) == nil
            && CutTool.knife.refusal(object: object, usesRealBlender: true) == nil)
    check("the simulator's stand-in has no 3D View to cut through, and says so",
          CutTool.loopCut.refusal(object: object, usesRealBlender: false)?.contains("simulator's stand-in") == true)
    check("with nothing active, said", CutTool.knife.refusal(object: nil, usesRealBlender: true)?
            .contains("no object is active") == true)
    let rebuilt = BKObject(name: "Smooth", kind: .cube)
    rebuilt.setEvaluatedMesh(MeshBuilder.uvSphere(radius: 1, segments: 8, rings: 4))
    rebuilt.modifiers = [Modifier(kind: .subdivision, name: "Subdivision")]
    let words = CutTool.loopCut.refusal(object: rebuilt, usesRealBlender: true) ?? ""
    check("under a modifier that rebuilds the mesh, Box, Circle and Lasso's words, with Loop Cut's last ones",
          words.contains("its modifier Subdivision rebuilds the mesh the viewport draws")
            && words.contains("an edge picked on them cannot be handed to it") && words.hasSuffix("to cut a loop here."),
          words)
    check("the Knife cuts there: its path is lines of sight, and Blender's Knife cuts the cage along them",
          CutTool.knife.refusal(object: rebuilt, usesRealBlender: true) == nil)
    check("and the Select tools keep theirs",
          rebuilt.editRegionRefusal()?.hasSuffix("a selection made over them cannot be handed to it. Hide the modifier "
                                                  + "in the viewport, or apply it, to select here.") == true,
          rebuilt.editRegionRefusal() ?? "nil")
}

print("\n== the preview belongs to the mesh it was made over ==")
do {
    let (mesh, topology) = cube()
    let object = BKObject(name: "Cube", kind: .cube)
    object.setEvaluatedMesh(mesh)
    object.editTopology = topology
    let preview = CutPreview(kind: .loopCut, lines: [], points: [], object: object.id, cageVertexCount: 8, blenderEdge: 4)
    check("it holds over the cube it was made on", preview.holds(for: object))
    let other = BKObject(name: "Other", kind: .cube)
    other.setEvaluatedMesh(mesh)
    check("not over another object", !preview.holds(for: other) && !preview.holds(for: nil))
    object.setEvaluatedMesh(MeshBuilder.uvSphere(radius: 1, segments: 8, rings: 4))
    check("nor once the mesh has changed under it", !preview.holds(for: object))
    object.setEvaluatedMesh(mesh)
    let made = CutPreview(kind: .loopCut, lines: [], points: [], object: object.id, cageVertexCount: 8,
                          blenderEdge: 4, topologyRevision: object.editTopologyRevision)
    check("a ring holds while the mirror's report it was made from does", made.holds(for: object))
    object.editTopology = topology
    check("and not after another report, even with the same counts (a script, an Undo)", !made.holds(for: object))
    let path = CutPreview(kind: .knife, lines: [], points: [], object: object.id, cageVertexCount: 8)
    object.setEvaluatedMesh(MeshBuilder.uvSphere(radius: 1, segments: 8, rings: 4))
    check("a knife path, points in the world, stays drawn over a mesh that changed", path.holds(for: object))
}

print("\n== the toolbar ==")
check("Loop Cut and Knife are tools with behaviour now", ActiveTool.loopCut.isImplemented && ActiveTool.knife.isImplemented)
check("by Blender's toolbar names", ActiveTool.loopCut.label == "Loop Cut" && ActiveTool.knife.label == "Knife"
      && CutTool.loopCut.label == "Loop Cut" && CutTool.knife.label == "Knife")
check("and in Edit Mode's toolbar", ActiveTool.groups(for: .edit).flatMap { $0 }.contains(.loopCut)
      && ActiveTool.groups(for: .edit).flatMap { $0 }.contains(.knife))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
