import Foundation
import simd
import CoreGraphics

// Box, Circle and Lasso select: the screen-space pass (RegionSelect.swift) and
// the Select menu's Python (SelectMenu.swift). Pure geometry and strings, so it
// runs on the Mac; what Blender does with the Python, and whether the pass
// picks what Blender's own view3d.select_* picks, is
// scripts/run-regionselect-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

func vertex(_ x: Float, _ y: Float, _ z: Float) -> MeshVertex {
    MeshVertex(SIMD3(x, y, z), SIMD3(0, 0, 1))
}

/// A cube of eight shared corners, each face two triangles, with the topology
/// the mirror would report: six polygons, twelve real edges, no diagonals.
func cube() -> (MeshData, EditTopology) {
    let p: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
                             SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
    var indices: [UInt32] = []
    var polys: [UInt32] = []
    for (f, q) in quads.enumerated() {
        indices += [q[0], q[1], q[2], q[0], q[2], q[3]]
        polys += [UInt32(f), UInt32(f)]
    }
    let mesh = MeshData(vertices: p.map { MeshVertex($0, normalize($0)) }, indices: indices)
    var real = Set<Int>()
    let sides = Set(quads.flatMap { q in (0..<4).map { k -> Set<UInt32> in [q[k], q[(k + 1) % 4]] } })
    for e in 0..<(mesh.edges.count / 2) where sides.contains([mesh.edges[2 * e], mesh.edges[2 * e + 1]]) {
        real.insert(e)
    }
    return (mesh, EditTopology(vertexCount: 8, polygonCount: 6, trianglePolygons: polys, realEdges: real))
}

/// A flat n × n grid of quads in the XY plane, spacing 1, centred.
func grid(_ n: Int) -> (MeshData, EditTopology) {
    var verts: [MeshVertex] = []
    let h = Float(n) / 2
    for j in 0...n { for i in 0...n { verts.append(vertex(Float(i) - h, Float(j) - h, 0)) } }
    var indices: [UInt32] = [], polys: [UInt32] = []
    for j in 0..<n {
        for i in 0..<n {
            let a = UInt32(j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1) + 1, d = a + UInt32(n + 1)
            indices += [a, b, c, a, c, d]
            polys += [UInt32(j * n + i), UInt32(j * n + i)]
        }
    }
    let mesh = MeshData(vertices: verts, indices: indices)
    var real = Set<Int>()
    for e in 0..<(mesh.edges.count / 2) {
        let a = Int(mesh.edges[2 * e]), b = Int(mesh.edges[2 * e + 1])
        let (ai, aj, bi, bj) = (a % (n + 1), a / (n + 1), b % (n + 1), b / (n + 1))
        if (ai == bi) || (aj == bj) { real.insert(e) }   // not a diagonal
    }
    return (mesh, EditTopology(vertexCount: verts.count, polygonCount: n * n, trianglePolygons: polys, realEdges: real))
}

let size = CGSize(width: 800, height: 600)
let aspect = Float(size.width / size.height)

func project(_ p: SIMD3<Float>, _ vp: simd_float4x4) -> CGPoint {
    BoxSelect.project(p, viewProjection: vp, size: size)!
}

print("== the regions ==")
do {
    let box = SelectionRegion.box(CGRect(x: 100, y: 100, width: 200, height: 100))
    check("a box holds its own edges, as Blender's rectangle does",
          box.contains(CGPoint(x: 100, y: 100)) && box.contains(CGPoint(x: 300, y: 200)))
    check("and not a point beside it", !box.contains(CGPoint(x: 301, y: 150)))
    check("a segment across a box with both ends outside touches it",
          box.touches(CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)))
    check("a segment beside it does not", !box.touches(CGPoint(x: 50, y: 250), CGPoint(x: 350, y: 250)))

    let circle = SelectionRegion.circle(path: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)], radius: 20)
    check("a painted circle covers the path between its samples, not only the samples",
          circle.contains(CGPoint(x: 200, y: 115)) && !circle.contains(CGPoint(x: 200, y: 125)))
    check("an edge passing within the radius touches it, ends outside",
          circle.touches(CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 200)))
    check("one passing beyond it does not",
          !circle.touches(CGPoint(x: 350, y: 50), CGPoint(x: 350, y: 200)))

    // A C shape: the notch between its arms is outside.
    let c = SelectionRegion.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 100),
                                   CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200),
                                   CGPoint(x: 300, y: 300), CGPoint(x: 0, y: 300)])
    check("a lasso holds its inside", c.contains(CGPoint(x: 50, y: 150)) && c.contains(CGPoint(x: 250, y: 50)))
    check("and not its notch", !c.contains(CGPoint(x: 200, y: 150)))
    check("an edge from the notch across an arm touches it",
          c.touches(CGPoint(x: 200, y: 150), CGPoint(x: 200, y: 50)))
    check("an edge inside the notch does not",
          !c.touches(CGPoint(x: 150, y: 140), CGPoint(x: 250, y: 160)))
    // A bow tie: even-odd, as Blender counts, leaves nothing out of either lobe.
    let tie = SelectionRegion.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 200),
                                     CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200)])
    check("each lobe of a crossed lasso is inside",
          tie.contains(CGPoint(x: 20, y: 100)) && tie.contains(CGPoint(x: 180, y: 100)))
    check("a lasso too thin to have an inside is not a gesture",
          !SelectionRegion.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0)]).isUsable)
    check("a one-point box is a tap, not a gesture", !SelectionRegion.box(CGRect(x: 1, y: 1, width: 1, height: 1)).isUsable)

    // The coverage mask is filled shape by shape; it has to agree with the
    // point test at every sample, or face mode would see a different region.
    var disagreements = 0
    for region in [box, circle, c, tie,
                   SelectionRegion.circle(path: [CGPoint(x: 150, y: 150)], radius: 33.3)] {
        let (x0, y0, w, h) = (-5, -5, 330, 320)
        let mask = region.coverage(x0: x0, y0: y0, width: w, height: h)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] != region.contains(CGPoint(x: CGFloat(x0 + x) + 0.5,
                                                                               y: CGFloat(y0 + y) + 0.5)) {
                disagreements += 1
            }
        }
    }
    check("the coverage mask and the point test agree at every sample (\(disagreements) differ)",
          disagreements == 0)
}

print("\n== what a gesture does to what was selected: Blender's sel_op_result ==")
do {
    let table: [(SelectAction, [Bool])] = [
        (.set,        [false, true, false, true]),
        (.extend,     [false, true, true, true]),
        (.subtract,   [false, false, true, false]),
        (.difference, [false, true, true, false]),
        (.intersect,  [false, false, false, true])]
    // (selected, inside): (F,F) (F,T) (T,F) (T,T)
    for (action, want) in table {
        let got = [(false, false), (false, true), (true, false), (true, true)]
            .map { action.regionResult(selected: $0.0, inside: $0.1) }
        check("\(action.label)", got == want, "\(got)")
    }
    check("an Intersect drawn over nothing deselects everything, as Blender's does",
          SelectAction.intersect.applyRegion(Set([1, 2]), inside: Set<Int>()).isEmpty)
    check("while a click's Intersect on nothing leaves it (SelectAction.apply)",
          SelectAction.intersect.apply(Set([1, 2]), hit: Set<Int>()) == [1, 2])
    check("Shift extends and Ctrl subtracts, the box and lasso tools' keymap",
          SelectAction.forGesture(shift: true, control: false) == .extend
            && SelectAction.forGesture(shift: false, control: true) == .subtract
            && SelectAction.forGesture(shift: false, control: false) == nil)
}

print("\n== a cube in perspective: what the surface hides, and X-Ray ==")
do {
    let (mesh, topology) = cube()
    let camera = ViewportCamera()
    let vp = camera.viewProjection(aspect: aspect)
    let hiddenCorner = mesh.vertices.indices.max { simd_distance(mesh.vertices[$0].position, camera.eye)
                                                    < simd_distance(mesh.vertices[$1].position, camera.eye) }!
    func select(_ region: SelectionRegion, _ mode: MeshSelectMode, seeThrough: Bool) -> EditSelection {
        RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                              viewProjection: vp, size: size, region: region, mode: mode,
                              seeThrough: seeThrough)
    }
    let everything = SelectionRegion.box(CGRect(origin: .zero, size: size))
    let solid = select(everything, .vertex, seeThrough: false)
    check("a box over the whole cube takes the 7 corners on show (\(solid.vertices.count))",
          solid.vertices.count == 7 && !solid.vertices.contains(hiddenCorner), "\(solid.vertices.sorted())")
    check("with X-Ray, all 8", select(everything, .vertex, seeThrough: true).vertices.count == 8)

    let behind = project(mesh.vertices[hiddenCorner].position, vp)
    let dab = SelectionRegion.circle(path: [behind], radius: 6)
    check("a circle on the hidden corner takes nothing: the front face is over it",
          select(dab, .vertex, seeThrough: false).vertices.isEmpty,
          "\(select(dab, .vertex, seeThrough: false).vertices)")
    check("with X-Ray it takes that corner", select(dab, .vertex, seeThrough: true).vertices == [hiddenCorner])

    let edges = select(everything, .edge, seeThrough: false)
    check("edge mode: the 9 edges on show, not the 3 meeting the hidden corner (\(edges.edges.count))",
          edges.edges.count == 9 && edges.edges.allSatisfy {
              Int(mesh.edges[2 * $0]) != hiddenCorner && Int(mesh.edges[2 * $0 + 1]) != hiddenCorner })
    check("with X-Ray, all 12 and no diagonal", select(everything, .edge, seeThrough: true).edges == topology.realEdges)

    let faces = select(everything, .face, seeThrough: false)
    let faceCount = Set(faces.faces.map { topology.trianglePolygons[$0] }).count
    check("face mode: the 3 faces turned to the camera (\(faceCount)), each whole",
          faceCount == 3 && faces.faces.count == 6)
    check("with X-Ray, all 6 by their centres", select(everything, .face, seeThrough: true).faces.count == 12)
    // A small circle in the middle of the +Z face: no face dot in it, but the
    // face shows there, which is what Blender's selection buffer reads.
    let top = project(SIMD3(0.3, 0.3, 1), vp)
    let onTop = select(.circle(path: [top], radius: 4), .face, seeThrough: false)
    check("a small circle on a face's surface takes that face without X-Ray",
          Set(onTop.faces.map { topology.trianglePolygons[$0] }) == [1], "\(onTop.faces)")
    check("and nothing with X-Ray, where only the face dot counts",
          select(.circle(path: [top], radius: 4), .face, seeThrough: true).faces.isEmpty)
}

print("\n== the outline: no face turned away wins a sample on it ==")
do {
    // Along a silhouette a front and a back face share an edge. Measured
    // before the rasteriser asked both faces the same question of a sample on
    // it: a box over Blender's cube at 1366 × 900 took 5 faces where 3 show,
    // and widening every triangle instead took 72 faces of a UV sphere where
    // 55 show. Over three view sizes and three distances, face mode without
    // X-Ray has to take exactly the faces turned to the camera.
    let (cubeMesh, cubeTopology) = cube()
    let sphere = MeshBuilder.uvSphere(radius: 1.5, segments: 16, rings: 8)
    var mismatches: [String] = []
    for (w, h) in [(1194.0, 700.0), (800.0, 600.0), (1366.0, 900.0)] {
        for distance in [Float(11), 8, 6] {
            var camera = ViewportCamera()
            camera.distance = distance
            let size = CGSize(width: w, height: h)
            let vp = camera.viewProjection(aspect: Float(w / h))
            let all = SelectionRegion.box(CGRect(x: w * 0.01, y: h * 0.01, width: w * 0.98, height: h * 0.98))
            for (name, mesh, topology) in [("cube", cubeMesh, Optional(cubeTopology)), ("sphere", sphere, nil)] {
                let got = RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                                                viewProjection: vp, size: size, region: all, mode: .face,
                                                seeThrough: false).faces
                let facing = Set((0..<(mesh.indices.count / 3)).filter { t in
                    let a = mesh.vertices[Int(mesh.indices[3 * t])].position
                    let b = mesh.vertices[Int(mesh.indices[3 * t + 1])].position
                    let c = mesh.vertices[Int(mesh.indices[3 * t + 2])].position
                    let n = cross(b - a, c - a)
                    return simd_length(n) > 1e-9 && dot(n, camera.eye - a) > 0
                })
                if got != facing {
                    mismatches.append("\(name) \(Int(w))×\(Int(h)) at \(distance): \(got.count) vs \(facing.count)")
                }
            }
        }
    }
    check("face mode takes the faces turned to the camera, and no others, in all 18 views",
          mismatches.isEmpty, mismatches.joined(separator: "; "))
}

print("\n== edges: wholly inside first, crossing only when none is ==")
do {
    let (mesh, topology) = grid(4)
    var camera = ViewportCamera()
    camera.snap(to: .top)
    camera.distance = 6
    let vp = camera.viewProjection(aspect: aspect)
    func edges(_ region: SelectionRegion) -> Set<Int> {
        RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                              viewProjection: vp, size: size, region: region, mode: .edge,
                              seeThrough: false).edges
    }
    // Vertex 12 is the centre (0, 0); 13 is (1, 0).
    let a = project(mesh.vertices[12].position, vp), b = project(mesh.vertices[13].position, vp)
    let whole = SelectionRegion.box(CGRect(x: a.x - 5, y: a.y - 5, width: b.x - a.x + 10, height: 10))
    let got = edges(whole)
    check("a box round one edge takes that edge alone, not the ones it cuts across (\(got.count))",
          got.count == 1 && got.allSatisfy { Set([mesh.edges[2 * $0], mesh.edges[2 * $0 + 1]]) == [12, 13] })
    let mid = CGPoint(x: (a.x + b.x) / 2, y: a.y)
    let across = SelectionRegion.box(CGRect(x: mid.x - 5, y: mid.y - 5, width: 10, height: 10))
    let crossing = edges(across)
    check("a box holding no whole edge takes the one it crosses",
          crossing.count == 1 && crossing.allSatisfy { Set([mesh.edges[2 * $0], mesh.edges[2 * $0 + 1]]) == [12, 13] },
          "\(crossing)")
    let dab = SelectionRegion.circle(path: [a], radius: 5)
    check("a circle takes every edge it touches: the 4 at a vertex", edges(dab).count == 4, "\(edges(dab).count)")
}

print("\n== a lasso over a grid, from the top ==")
do {
    let (mesh, topology) = grid(6)                // 7 × 7 vertices
    var camera = ViewportCamera()
    camera.snap(to: .top)
    camera.distance = 8
    let vp = camera.viewProjection(aspect: aspect)
    let o = project(SIMD3(0, 0, 0), vp), r = project(SIMD3(2.5, 0, 0), vp).x - o.x
    let triangle = SelectionRegion.lasso([CGPoint(x: o.x - r, y: o.y + r), CGPoint(x: o.x + r, y: o.y + r),
                                          CGPoint(x: o.x, y: o.y - r)])
    let got = RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                                    viewProjection: vp, size: size, region: triangle, mode: .vertex,
                                    seeThrough: false).vertices
    let want = Set(mesh.vertices.indices.filter { triangle.contains(project(mesh.vertices[$0].position, vp)) })
    check("it takes the vertices inside its outline (\(got.count)), none hidden on a flat grid",
          got == want && !got.isEmpty, "\(got.sorted()) vs \(want.sorted())")

    // The same grid seen from below: every face turned away, and still
    // nothing hides a vertex — Blender draws the edit mesh two-sided.
    var under = camera
    under.snap(to: .bottom)
    under.distance = 14                           // the whole grid in view
    let vpu = under.viewProjection(aspect: aspect)
    let all = RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                                    viewProjection: vpu, size: size,
                                    region: .box(CGRect(origin: .zero, size: size)), mode: .vertex,
                                    seeThrough: false).vertices
    check("from underneath, a box takes all 49", all.count == 49, "\(all.count)")
}

print("\n== combining with what is selected, and what it implies ==")
do {
    let (mesh, topology) = grid(2)                // 3 × 3 vertices, 4 quads
    let object = BKObject(name: "Grid", kind: .plane)
    object.setMirroredMesh(mesh)
    object.editTopology = topology
    var camera = ViewportCamera()
    camera.snap(to: .top)
    camera.distance = 4
    let vp = camera.viewProjection(aspect: aspect)
    // Around the four corners of the bottom-left quad: vertices 0, 1, 3, 4.
    let lo = project(SIMD3(-1, -1, 0), vp), hi = project(SIMD3(0, 0, 0), vp)
    let quadBox = SelectionRegion.box(CGRect(x: min(lo.x, hi.x) - 5, y: min(lo.y, hi.y) - 5,
                                             width: abs(hi.x - lo.x) + 10, height: abs(hi.y - lo.y) + 10))
    var current = EditSelection()
    current.vertices = [8]
    let set = object.regionSelection(quadBox, mode: .vertex, action: .set, current: current,
                                     viewProjection: vp, size: size, seeThrough: false)
    check("Set replaces: the quad's four corners", set.vertices == [0, 1, 3, 4], "\(set.vertices.sorted())")
    check("and implies that quad, both triangles, and its four edges",
          Set(set.faces.map { topology.trianglePolygons[$0] }) == [0] && set.faces.count == 2
            && set.edges.count == 4, "\(set.faces) \(set.edges.count)")
    let extend = object.regionSelection(quadBox, mode: .vertex, action: .extend, current: current,
                                        viewProjection: vp, size: size, seeThrough: false)
    check("Extend keeps vertex 8", extend.vertices == [0, 1, 3, 4, 8])
    current.vertices = [0, 1, 3, 4, 8]
    let subtract = object.regionSelection(quadBox, mode: .vertex, action: .subtract, current: current,
                                          viewProjection: vp, size: size, seeThrough: false)
    check("Subtract takes them away again", subtract.vertices == [8])
    // Three corners of a quad are not the quad.
    let three = EditSelection.implied(by: EditSelection(vertices: [0, 1, 3], edges: [], faces: []),
                                      mode: .vertex, mesh: mesh, topology: topology)
    check("three corners of a quad select no half of it", three.faces.isEmpty, "\(three.faces)")
}

print("\n== objects: a box by any part, a circle or lasso by the origin ==")
do {
    var camera = ViewportCamera()
    camera.snap(to: .top)
    camera.distance = 12
    let vp = camera.viewProjection(aspect: aspect)
    let body = (name: "Body", origin: SIMD3<Float>(0, 0, 0),
                bounds: (min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1)), visible: true)
    let hidden = (name: "Hidden", origin: SIMD3<Float>(0, 0, 0),
                  bounds: (min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1)), visible: false)
    let surface = project(SIMD3(0.8, 0.8, 1), vp), origin = project(.zero, vp)
    func names(_ region: SelectionRegion) -> [String] {
        RegionSelect.objects(in: region, objects: [body, hidden], viewProjection: vp, size: size)
    }
    check("a circle over the surface, off the origin, takes nothing (Blender's object_circle_select)",
          names(.circle(path: [surface], radius: 10)).isEmpty)
    check("a circle over the origin takes it", names(.circle(path: [origin], radius: 10)) == ["Body"])
    let square = [CGPoint(x: surface.x - 15, y: surface.y - 15), CGPoint(x: surface.x + 15, y: surface.y - 15),
                  CGPoint(x: surface.x + 15, y: surface.y + 15), CGPoint(x: surface.x - 15, y: surface.y + 15)]
    check("a lasso over the surface takes nothing", names(.lasso(square)).isEmpty)
    check("a box over the same spot takes it: any part counts",
          names(.box(CGRect(x: surface.x - 15, y: surface.y - 15, width: 30, height: 30))) == ["Body"])
    check("hidden objects never", !names(.box(CGRect(origin: .zero, size: size))).contains("Hidden"))
}

print("\n== the Python a region sends for objects ==")
do {
    let set = SelectMenu.objectRegion(["A", "B"], action: .set)
    check("Set deselects first, then selects each", set.hasPrefix(Bpy.deselectAll)
          && set.contains("bpy.data.objects[\"A\"].select_set(True)")
          && set.contains("bpy.data.objects[\"B\"].select_set(True)"), set)
    check("and makes the first active only if the active one was deselected",
          set.contains("if (_a is None or not _a.select_get())"), set)
    check("Set over nothing only deselects", SelectMenu.objectRegion([], action: .set) == Bpy.deselectAll)
    check("Subtract deselects each, and leaves the active alone",
          SelectMenu.objectRegion(["A"], action: .subtract) == "bpy.data.objects[\"A\"].select_set(False)")
    let intersect = SelectMenu.objectRegion([], action: .intersect)
    check("Intersect over nothing deselects everything", intersect.contains("_bk_hit = set()")
          && intersect.contains("_o.select_set(False)"), intersect)
    check("Extend over nothing changes nothing", SelectMenu.objectRegion([], action: .extend) == "pass")
}

print("\n== the Select menu ==")
do {
    check("Select Random is Blender's operator with its defaults",
          SelectMenu.MeshItem.random.operation.python
            == "bpy.ops.mesh.select_random(ratio=0.5, seed=0, action='SELECT')",
          SelectMenu.MeshItem.random.operation.python)
    check("Checker Deselect is select_nth",
          SelectMenu.MeshItem.checkerDeselect.operation.python == "bpy.ops.mesh.select_nth(skip=1, nth=1, offset=0)",
          SelectMenu.MeshItem.checkerDeselect.operation.python)
    check("Select Mirror sends its axis as the set Blender takes",
          SelectMenu.MeshItem.mirror.operation.python == "bpy.ops.mesh.select_mirror(axis={'X'}, extend=False)",
          SelectMenu.MeshItem.mirror.operation.python)
    check("Linked delimits at seams, Blender's default",
          SelectMenu.MeshItem.linked.operation.python == "bpy.ops.mesh.select_linked(delimit={'SEAM'})")
    check("Shortest Path turns a silent CANCELLED into a sentence",
          SelectMenu.MeshItem.shortestPath.operation.executedPython.contains("raise RuntimeError"))
    check("every edit-mode row runs in edit mode, as its undo step and panel title",
          SelectMenu.MeshItem.allCases.allSatisfy {
              $0.operation.needsEditMode && $0.operation.name == $0.operatorName
          })
    check("Non Manifold is not offered in face mode", !SelectMenu.MeshItem.nonManifold.isOffered(in: .face)
          && SelectMenu.MeshItem.nonManifold.isOffered(in: .vertex))
    check("Select Similar offers 5, 9 and 8 types in vertex, edge and face mode",
          SelectMenu.SimilarType.offered(in: .vertex).count == 5
            && SelectMenu.SimilarType.offered(in: .edge).count == 9
            && SelectMenu.SimilarType.offered(in: .face).count == 8)
    let similar = SelectMenu.SimilarType.edgeLength.operation
    check("and sends the one picked, with Compare and Threshold",
          similar.python == "bpy.ops.mesh.select_similar(type='EDGE_LENGTH', compare='EQUAL', threshold=0)",
          similar.python)
    var adjusted = SelectMenu.MeshItem.random.operation
    adjusted["ratio"] = 0.25
    adjusted["seed"] = 7
    check("its panel re-runs it with what is dragged",
          adjusted.python == "bpy.ops.mesh.select_random(ratio=0.25, seed=7, action='SELECT')", adjusted.python)
    if case .run(let python, let undo) = SelectMenu.selectLinked("MATERIAL") {
        check("object Select Linked puts the selection back when Blender cancels",
              python.contains("_bk_r = bpy.ops.object.select_linked(type='MATERIAL')")
                && python.contains("if 'CANCELLED' in _bk_r:")
                && python.contains("_bk_o.select_set(_bk_o.name in _bk_was)") && undo == "Select Linked", python)
        check("and refuses first when nothing is active, which Blender answers with an error "
              + "after deselecting everything", python.hasPrefix("if bpy.context.view_layer.objects.active is None:"))
    } else { check("object Select Linked is a run", false) }
    if case .run(let python, _) = SelectMenu.ObjectItem.child.action {
        check("Child is refused without an active object, where Blender's poll fails",
              python.hasPrefix("if bpy.context.view_layer.objects.active is None:")
                && SelectMenu.ObjectItem.child.needsActive && !SelectMenu.ObjectItem.more.needsActive)
    } else { check("object Select Linked is a run", false) }
    if case .run(let python, _) = SelectMenu.selectPattern("Wheel\"*") {
        check("a pattern goes over quoted", python.contains("pattern=\"Wheel\\\"*\""), python)
    }
}

print("\n== a vertex projected past Int.max, or past a Float ==")
do {
    // The review's harness: a 2 x 2 grid with one vertex at X = 1e17, top
    // orthographic view, a box over the middle, X-Ray off. Before the clamps
    // this stopped the process in DepthBuffer.rasterise (exit 133, "Double
    // value cannot be converted to Int because the result would be greater
    // than Int.max") in all three modes. Reaching the checks is the test;
    // what is taken must still be what the box covers.
    let (flat, flatTopology) = grid(2)
    let box = SelectionRegion.box(CGRect(x: 300, y: 200, width: 200, height: 200))
    for (label, far) in [("1e17", Float(1e17)), ("3e38", Float(3e38)), ("infinity", Float.infinity),
                         ("not a number", Float.nan)] {
        var verts = flat.vertices
        verts[0].position.x = far
        let mesh = MeshData(vertices: verts, indices: flat.indices)
        for ortho in [true, false] {
            var camera = ViewportCamera()
            if ortho { camera.snap(to: .top) }
            camera.distance = 6
            let vp = camera.viewProjection(aspect: aspect)
            var taken: [String] = []
            for mode in [MeshSelectMode.vertex, .edge, .face] {
                let s = RegionSelect.elements(mesh: mesh, topology: flatTopology, model: matrix_identity_float4x4,
                                              viewProjection: vp, size: size, region: box, mode: mode,
                                              seeThrough: false)
                taken.append("\(s.vertices.count + s.edges.count + s.faces.count)")
            }
            let centre = RegionSelect.elements(mesh: mesh, topology: flatTopology, model: matrix_identity_float4x4,
                                               viewProjection: vp, size: size, region: box, mode: .vertex,
                                               seeThrough: false).vertices
            check("a vertex at X = \(label), \(ortho ? "top orthographic" : "perspective"): no trap in any mode "
                  + "(\(taken.joined(separator: "/")) taken), and the centre vertex is still taken",
                  centre.contains(4), "\(centre.sorted())")
        }
    }
}

print("\n== a floor reaching behind the eye still hides what is under it ==")
do {
    // The review's slab: a 100 x 100 floor quad at z = 0 over a 21 x 21 grid
    // one unit below it. Before near-plane clipping a triangle with a corner
    // behind the eye was dropped, and a box over the view with X-Ray off took
    // 0 hidden vertices at camera distance 200 but 321 / 321 / 265 at
    // 60 / 20 / 8. And the same floor with a small grid one unit above it,
    // which shows, so that clipping is not hiding everything either.
    func slab(gridZ: Float, n: Int, spacing: Float) -> (MeshData, Range<Int>) {
        var verts = [vertex(-50, -50, 0), vertex(50, -50, 0), vertex(50, 50, 0), vertex(-50, 50, 0)]
        var indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let h = Float(n) / 2
        for j in 0...n { for i in 0...n { verts.append(vertex((Float(i) - h) * spacing, (Float(j) - h) * spacing, gridZ)) } }
        for j in 0..<n { for i in 0..<n {
            let a = UInt32(4 + j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1) + 1, d = a + UInt32(n + 1)
            indices += [a, b, c, a, c, d]
        } }
        return (MeshData(vertices: verts, indices: indices), 4..<verts.count)
    }
    let (under, below) = slab(gridZ: -1, n: 20, spacing: 0.5)
    let (over, above) = slab(gridZ: 1, n: 4, spacing: 0.25)
    let view = CGRect(origin: .zero, size: size)
    for distance in [Float(200), 60, 20, 8, 3] {
        var camera = ViewportCamera()
        camera.distance = distance
        let vp = camera.viewProjection(aspect: aspect)
        func taken(_ mesh: MeshData, _ r: Range<Int>, xray: Bool) -> (got: Int, onScreen: Int) {
            let got = RegionSelect.elements(mesh: mesh, topology: nil, model: matrix_identity_float4x4,
                                            viewProjection: vp, size: size, region: .box(view), mode: .vertex,
                                            seeThrough: xray).vertices.filter(r.contains).count
            let onScreen = r.filter { i in
                BoxSelect.project(mesh.vertices[i].position, viewProjection: vp, size: size).map(view.contains) ?? false
            }.count
            return (got, onScreen)
        }
        let hidden = taken(under, below, xray: false), xray = taken(under, below, xray: true)
        let shown = taken(over, above, xray: false)
        check("camera distance \(Int(distance)): \(hidden.got) of the \(hidden.onScreen) grid vertices under the "
              + "floor taken without X-Ray, \(xray.got) with it; \(shown.got) of the \(shown.onScreen) above it",
              hidden.got == 0 && xray.got == xray.onScreen && shown.got == shown.onScreen)
    }
}

print("\n== a mirrored object (scale -1 on one axis) ==")
do {
    // Its faces wind the other way on screen. Measured before the flip: the
    // cube at scale.x = -1 in the nine cube views of the outline sweep took
    // 6 faces in every one, where 3 show (and 3 at scale.x = +1).
    let (mesh, topology) = cube()
    var model = matrix_identity_float4x4
    model.columns.0.x = -1
    var counts: [Int] = []
    var verticesAndEdges: [String] = []
    for (w, h) in [(1194.0, 700.0), (800.0, 600.0), (1366.0, 900.0)] {
        for distance in [Float(11), 8, 6] {
            var camera = ViewportCamera()
            camera.distance = distance
            let size = CGSize(width: w, height: h)
            let vp = camera.viewProjection(aspect: Float(w / h))
            let all = SelectionRegion.box(CGRect(x: w * 0.01, y: h * 0.01, width: w * 0.98, height: h * 0.98))
            func take(_ mode: MeshSelectMode) -> EditSelection {
                RegionSelect.elements(mesh: mesh, topology: topology, model: model, viewProjection: vp,
                                      size: size, region: all, mode: mode, seeThrough: false)
            }
            counts.append(Set(take(.face).faces.map { topology.trianglePolygons[$0] }).count)
            verticesAndEdges.append("\(take(.vertex).vertices.count)/\(take(.edge).edges.count)")
        }
    }
    check("face mode takes the 3 faces that show in all nine views (\(counts))", counts.allSatisfy { $0 == 3 })
    check("vertex and edge mode, which compare depth alone, still take 7 and 9 (\(Set(verticesAndEdges)))",
          Set(verticesAndEdges) == ["7/9"])
}

print("\n== a lasso that crosses itself ==")
do {
    let tie = SelectionRegion.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 200),
                                     CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200)])
    check("a bow tie, whose lobes' signed areas cancel to \(SelectionRegion.signedArea([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200)])), is a gesture: "
          + "its even-odd area is \(Int(SelectionRegion.evenOddArea([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200)]))) points",
          tie.isUsable)
    let (mesh, topology) = grid(6)
    var camera = ViewportCamera()
    camera.snap(to: .top)
    camera.distance = 8
    let vp = camera.viewProjection(aspect: aspect)
    let o = project(SIMD3(0, 0, 0), vp), r = project(SIMD3(2.6, 0, 0), vp).x - o.x
    let lobes = SelectionRegion.lasso([CGPoint(x: o.x - r, y: o.y - r), CGPoint(x: o.x + r, y: o.y + r),
                                       CGPoint(x: o.x + r, y: o.y - r), CGPoint(x: o.x - r, y: o.y + r)])
    let got = RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                                    viewProjection: vp, size: size, region: lobes, mode: .vertex,
                                    seeThrough: false).vertices
    let want = Set(mesh.vertices.indices.filter { lobes.contains(project(mesh.vertices[$0].position, vp)) })
    let left = got.filter { mesh.vertices[$0].position.x < -0.5 }.count
    let right = got.filter { mesh.vertices[$0].position.x > 0.5 }.count
    check("it takes what lies in either lobe (\(left) left, \(right) right, \(got.count) in all)",
          got == want && left > 0 && right > 0, "\(got.sorted()) vs \(want.sorted())")
    check("a lasso along a line is still no gesture",
          !SelectionRegion.lasso([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0),
                                  CGPoint(x: 100, y: 0)]).isUsable)
}

print("\n== Shift+Ctrl, and what refuses ==")
do {
    check("Shift+Ctrl intersects on the box and lasso tools (blender_default.py's "
          + "_template_items_tool_select_actions)",
          SelectAction.forGesture(shift: true, control: true) == .intersect)
    check("the circle tool's keymap has no Shift+Ctrl: Ctrl still subtracts",
          SelectAction.forGesture(shift: true, control: true, circle: true) == .subtract
            && SelectAction.forGesture(shift: true, control: false, circle: true) == .extend)
    check("the tool menu's Mode offers Box and Lasso all five, Circle Set, Extend and Subtract",
          SelectAction.regionModes(circle: false).count == 5
            && SelectAction.regionModes(circle: true) == [.set, .extend, .subtract])
    check("and a mode Circle does not have is Set there, kept for Box and Lasso",
          SelectAction.intersect.forRegion(circle: true) == .set
            && SelectAction.intersect.forRegion(circle: false) == .intersect
            && SelectAction.subtract.forRegion(circle: true) == .subtract)

    // A cube under a level-1 Subdivision Surface, as the device's mirror
    // leaves it: the evaluated mesh drawn (26 vertices over Blender's 8), and
    // no topology, because the report cannot name its elements.
    let sphere = MeshBuilder.uvSphere(radius: 1, segments: 8, rings: 4)
    let object = BKObject(name: "Cube", kind: .cube)
    object.setEvaluatedMesh(sphere)
    object.modifiers = [Modifier(kind: .displace, name: "Displace"),
                        Modifier(kind: .subdivision, name: "Subdivision")]
    let refusal = object.editRegionRefusal() ?? ""
    check("a mesh drawn through a modifier that rebuilds it is refused, naming that modifier",
          refusal.contains("its modifier Subdivision rebuilds") && !refusal.contains("Displace")
            && refusal.contains("Hide the modifier in the viewport"), refusal)
    var hidden = Modifier(kind: .mirror, name: "Mirror")
    hidden.showInViewport = false
    object.modifiers = [Modifier(kind: .array, name: "Array"), hidden, Modifier(kind: .bevel, name: "Bevel")]
    let two = object.editRegionRefusal() ?? ""
    check("two shown, one hidden: the shown two", two.contains("its modifiers Array and Bevel rebuild")
          && !two.contains("Mirror"), two)
    object.editTopology = EditTopology(vertexCount: sphere.vertices.count, polygonCount: sphere.indices.count / 3,
                                       trianglePolygons: (0..<(sphere.indices.count / 3)).map(UInt32.init),
                                       realEdges: [])
    check("once the report names the drawn mesh's elements, nothing is refused", object.editRegionRefusal() == nil)
    object.editTopology = nil
    object.undrawnVertexCount = 2_000_000
    check("a mesh drawn as its bounds is refused as that",
          object.editRegionRefusal()?.contains("shown as its bounds") == true, object.editRegionRefusal() ?? "nil")
}

print("\n== the Select menu's greyed rows and fields ==")
do {
    let item = SelectMenu.MeshItem.ungrouped
    check("Ungrouped Vertices runs in vertex mode on a mesh with a group",
          item.isEnabled(in: .vertex, vertexGroups: 1) && item.isEnabled(in: .vertex, vertexGroups: nil))
    check("and is greyed in edge and face mode, and with no group (Blender's poll, measured)",
          !item.isEnabled(in: .edge, vertexGroups: 2) && !item.isEnabled(in: .face, vertexGroups: 2)
            && !item.isEnabled(in: .vertex, vertexGroups: 0))
    check("every other row is enabled", SelectMenu.MeshItem.allCases.filter { $0 != .ungrouped }
        .allSatisfy { $0.isEnabled(in: .face, vertexGroups: 0) })
    let ratio = SelectMenu.MeshItem.random.operation.parameters.first { $0.key == "ratio" }
    check("Select Random's Ratio shows as Blender's factor, 0.500 (\(ratio?.display ?? "?"))",
          ratio?.display == "0.500")
}

print("\n== fast enough for a heavy mesh ==")
do {
    let (mesh, topology) = grid(200)              // 40,401 vertices, 80,000 triangles
    var camera = ViewportCamera()
    camera.distance = 260
    let vp = camera.viewProjection(aspect: aspect)
    let started = Date()
    let got = RegionSelect.elements(mesh: mesh, topology: topology, model: matrix_identity_float4x4,
                                    viewProjection: vp, size: size,
                                    region: .box(CGRect(origin: .zero, size: size)), mode: .face,
                                    seeThrough: false)
    let seconds = Date().timeIntervalSince(started)
    print(String(format: "  (80,000 triangles, face mode, the whole view: %.0f ms, %d faces)",
                 seconds * 1000, got.faces.count / 2))
    check("under a second", seconds < 1)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
