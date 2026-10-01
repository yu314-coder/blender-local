import Foundation
import simd
import CoreGraphics

// What Blender reports as selected, turned into what the viewport draws — and
// what the viewport has selected, turned back into what Blender is told. All
// index work, so it runs on the Mac; the Python half is run by a real Blender
// in scripts/run-3dview-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

func vertex(_ x: Float, _ y: Float, _ z: Float) -> MeshVertex {
    MeshVertex(SIMD3(x, y, z), SIMD3(0, 0, 1))
}

// A quad and a triangle beside it, the way the viewport gets them from
// Blender: the quad as two triangles. Blender itself has two polygons and six
// edges; the viewport's edge list has a seventh, the quad's diagonal.
//
//   3 ----- 2
//   |     / | \
//   |   /   |   4
//   | /     | /
//   0 ----- 1
let quad = MeshData(vertices: [vertex(0, 0, 0), vertex(1, 0, 0), vertex(1, 1, 0),
                               vertex(0, 1, 0), vertex(2, 0.5, 0)],
                    indices: [0, 1, 2,  0, 2, 3,  1, 4, 2])
// Blender's edges, in Blender's order.
let blenderEdges: [UInt32] = [0, 1,  1, 2,  2, 3,  3, 0,  1, 4,  4, 2]

func displayEdge(_ a: UInt32, _ b: UInt32) -> Int? {
    stride(from: 0, to: quad.edges.count, by: 2).first {
        Set([quad.edges[$0], quad.edges[$0 + 1]]) == Set([a, b])
    }.map { $0 / 2 }
}

print("== Blender's edit selection, in the viewport's terms ==")
do {
    // The quad selected in face mode.
    let report = BlenderEditReport(selectMode: 4,
                                   vertexSelected: [1, 1, 1, 1, 0],
                                   trianglePolygons: [0, 0, 1],
                                   polygonSelected: [1, 0],
                                   edgeVertices: blenderEdges,
                                   edgeSelected: [1, 1, 1, 1, 0, 0])
    guard let mirrored = EditSelection.mirrored(report, display: quad) else {
        check("a report that lines up is accepted", false); exit(1)
    }
    let s = mirrored.selection
    check("a selected polygon lights both of its triangles", s.faces == [0, 1], "\(s.faces)")
    check("and not the triangle beside it", !s.faces.contains(2))
    check("its corners", s.vertices == [0, 1, 2, 3], "\(s.vertices)")
    let outline = Set([displayEdge(0, 1), displayEdge(1, 2), displayEdge(2, 3), displayEdge(3, 0)].compactMap { $0 })
    check("its four edges, found by their ends", s.edges == outline, "\(s.edges) vs \(outline)")
    check("but not the diagonal Blender does not have", !s.edges.contains(displayEdge(0, 2)!))
    // Blender's six edges, as viewport edge numbers: the seventh, the quad's
    // diagonal, is the triangulation's and must not be among them — edit mode
    // neither draws it nor lets a tap pick it.
    let real = Set([displayEdge(0, 1), displayEdge(1, 2), displayEdge(2, 3), displayEdge(3, 0),
                    displayEdge(1, 4), displayEdge(4, 2)].compactMap { $0 })
    // And Blender's own edges in its order, for Topology Mirror (SymmetricEdit).
    check("the topology records the polygon behind each triangle",
          mirrored.topology == EditTopology(vertexCount: 5, polygonCount: 2,
                                            trianglePolygons: [0, 0, 1], realEdges: real,
                                            blenderEdges: blenderEdges),
          "\(mirrored.topology)")
    check("and which viewport edges are Blender's",
          mirrored.topology.realEdges == real && !mirrored.topology.realEdges.contains(displayEdge(0, 2)!),
          "\(mirrored.topology.realEdges) vs \(real)")

    // The triangle selected instead.
    let triangle = BlenderEditReport(selectMode: 4,
                                     vertexSelected: [0, 1, 1, 0, 1],
                                     trianglePolygons: [0, 0, 1],
                                     polygonSelected: [0, 1],
                                     edgeVertices: blenderEdges,
                                     edgeSelected: [0, 1, 0, 0, 1, 1])
    let t = EditSelection.mirrored(triangle, display: quad)?.selection
    check("a lone triangle is its own face", t?.faces == [2], "\(String(describing: t?.faces))")
    check("with its three edges", t?.edges == Set([displayEdge(1, 2)!, displayEdge(1, 4)!, displayEdge(2, 4)!]),
          "\(String(describing: t?.edges))")

    // A report from a mesh the viewport is not drawing.
    let rebuilt = BlenderEditReport(selectMode: 1, vertexSelected: [1, 0, 0, 0],
                                    trianglePolygons: [0, 0], polygonSelected: [0],
                                    edgeVertices: [], edgeSelected: [])
    check("counts that do not match the viewport's mesh are refused",
          EditSelection.mirrored(rebuilt, display: quad) == nil)
    let empty = BlenderEditReport(selectMode: 1, vertexSelected: [], trianglePolygons: [],
                                  polygonSelected: [], edgeVertices: [], edgeSelected: [])
    check("and so is an empty report, which is what a modifier that rebuilds the mesh sends",
          EditSelection.mirrored(empty, display: quad) == nil)
}

print("\n== the scene takes the report ==")
do {
    let scene = BKScene(startupFile: false)
    let object = scene.add(.plane)
    object.setMirroredMesh(quad)
    scene.setMode(.edit)
    scene.editSelection.vertices = [4]
    scene.editSelectionPending = true
    let report = BlenderEditReport(selectMode: 2, vertexSelected: [1, 1, 0, 0, 0],
                                   trianglePolygons: [0, 0, 1], polygonSelected: [0, 0],
                                   edgeVertices: blenderEdges, edgeSelected: [1, 0, 0, 0, 0, 0])
    check("a report that lines up is installed", scene.mirrorEditSelection(report, on: object))
    check("replacing what was tapped", scene.editSelection.vertices == [0, 1],
          "\(scene.editSelection.vertices)")
    check("with Blender's select mode", scene.selectMode == .edge)
    check("and nothing left to hand over", !scene.editSelectionPending)
    check("the object remembers how its mesh lines up", object.editTopology?.polygonCount == 2)

    let rebuilt = BlenderEditReport(selectMode: 1, vertexSelected: [], trianglePolygons: [],
                                    polygonSelected: [], edgeVertices: [], edgeSelected: [])
    check("one that does not is refused", !scene.mirrorEditSelection(rebuilt, on: object))
    check("and shows nothing selected rather than something wrong", scene.editSelection.isEmpty)
    check("forgetting how the mesh lined up", object.editTopology == nil)
}

print("\n== the viewport's selection, handed to Blender ==")
do {
    let object = BKObject(name: "Quad", kind: .plane)
    object.setMirroredMesh(quad)
    object.editTopology = EditTopology(vertexCount: 5, polygonCount: 2, trianglePolygons: [0, 0, 1])

    var selection = EditSelection()
    selection.faces = [0, 1]
    let faces = Bpy.pushEditSelection(selection, mode: .face, of: object)
    check("the quad's two triangles go over as its one polygon", faces.contains("for _bk_i in [0]:"), faces)
    check("selected with its edges and corners", faces.contains("_bk_bm.faces[_bk_i].select_set(True)"), faces)
    check("in face select mode", faces.contains("mesh_select_mode = (False, False, True)"), faces)
    check("refusing a mesh that is no longer the one it was read from",
          faces.contains("if len(_bk_bm.verts) != 5 or len(_bk_bm.faces) != 2:"), faces)

    selection = EditSelection()
    selection.edges = [displayEdge(1, 2)!, displayEdge(0, 2)!]
    let edges = Bpy.pushEditSelection(selection, mode: .edge, of: object)
    let pairs = [displayEdge(1, 2)!, displayEdge(0, 2)!].sorted().map {
        "(\(quad.edges[2 * $0]), \(quad.edges[2 * $0 + 1]))"
    }.joined(separator: ", ")
    check("edges go over by their ends", edges.contains("[\(pairs)]"), edges)
    check("looked up among Blender's edges, where the diagonal is simply not found",
          edges.contains("_bk_bm.edges.get((_bk_bm.verts[_bk_a], _bk_bm.verts[_bk_b]))")
            && edges.contains("if _bk_e is not None:"), edges)

    selection = EditSelection()
    selection.vertices = [4, 1]
    let vertices = Bpy.pushEditSelection(selection, mode: .vertex, of: object)
    check("vertices by index", vertices.contains("for _bk_i in [1, 4]:"), vertices)
    check("in vertex select mode", vertices.contains("mesh_select_mode = (True, False, False)"), vertices)
    check("with the selection cleared first",
          vertices.contains("for _bk_seq in (_bk_bm.faces, _bk_bm.edges, _bk_bm.verts):"), vertices)

    selection.vertices = Set(0..<5)
    check("all of them without listing them",
          Bpy.pushEditSelection(selection, mode: .vertex, of: object).contains("for _bk_v in _bk_bm.verts:"))

    object.editTopology = nil
    check("a mesh the mirror could not line up is selected by position instead",
          Bpy.pushEditSelection(selection, mode: .vertex, of: object).contains("Vector("))
}

print("\n== box select while editing takes elements ==")
do {
    // Straight down the Z axis, two world units to half the screen:
    // world (x, y) lands at screen (100x + 200, 200 - 100y).
    let viewProjection = simd_float4x4(diagonal: SIMD4<Float>(0.5, 0.5, 0.5, 1))
    let size = CGSize(width: 400, height: 400)
    let object = BKObject(name: "Quad", kind: .plane)
    object.setMirroredMesh(quad)

    let left = CGRect(x: 150, y: 50, width: 100, height: 200)       // vertices 0 and 3
    let v = object.editElements(in: left, mode: .vertex, viewProjection: viewProjection, size: size)
    check("vertex mode takes the vertices inside", v.vertices == [0, 3], "\(v.vertices)")
    check("and the edge between them", v.edges == [displayEdge(0, 3)!], "\(v.edges)")
    check("but no face, since none has every corner inside", v.faces.isEmpty, "\(v.faces)")

    let square = CGRect(x: 150, y: 50, width: 200, height: 200)     // the whole quad
    let q = object.editElements(in: square, mode: .vertex, viewProjection: viewProjection, size: size)
    check("a box round the quad takes both its triangles", q.faces == [0, 1], "\(q.faces)")

    let bottom = CGRect(x: 150, y: 180, width: 200, height: 40)     // vertices 0 and 1
    let e = object.editElements(in: bottom, mode: .edge, viewProjection: viewProjection, size: size)
    check("edge mode takes an edge with both ends inside", e.edges == [displayEdge(0, 1)!], "\(e.edges)")
    check("and its ends", e.vertices == [0, 1], "\(e.vertices)")

    // The triangle's centre is at world (4/3, 1/2): screen (333, 150).
    let centre = CGRect(x: 320, y: 140, width: 30, height: 20)
    let f = object.editElements(in: centre, mode: .face, viewProjection: viewProjection, size: size)
    check("face mode takes a face whose centre is inside", f.faces == [2], "\(f.faces)")
    check("with its corners", f.vertices == [1, 2, 4], "\(f.vertices)")
}

print("\n== elements Blender has hidden (mesh.hide) ==")
do {
    // Vertices 1 and 2 hidden in vertex mode: every face uses one, so both
    // faces go, and every edge but 3-0. The mirror sends the vertices, no
    // triangle, and the one edge left (`_unhidden_triangles`, `_unhidden_edges`).
    let shown = MeshData(vertices: quad.vertices, wireEdges: [3, 0])
    let report = BlenderEditReport(selectMode: 1,
                                   vertexSelected: [0, 0, 0, 0, 0],
                                   trianglePolygons: [],
                                   polygonSelected: [0, 0],
                                   edgeVertices: blenderEdges,
                                   edgeSelected: [0, 0, 0, 0, 0, 0],
                                   vertexHidden: [0, 1, 1, 0, 0])
    guard let mirrored = EditSelection.mirrored(report, display: shown) else {
        check("a report with hidden vertices is accepted", false); exit(1)
    }
    check("the topology knows which vertices are hidden", mirrored.topology.hiddenVertices == [1, 2],
          "\(mirrored.topology.hiddenVertices)")
    check("and the one edge left is Blender's", mirrored.topology.realEdges.count == 1)
    var wrong = report
    wrong.vertexHidden = [0, 1]
    check("a hidden list of the wrong length is no report", EditSelection.mirrored(wrong, display: shown) == nil)
    var none = report
    none.vertexHidden = []
    check("an empty one means nothing is hidden",
          EditSelection.mirrored(none, display: shown)?.topology.hiddenVertices.isEmpty == true)

    // With no face left the picker's own visibility test lets every vertex
    // through: only the hidden flags keep a tap off 1 and 2.
    let viewProjection = simd_float4x4(diagonal: SIMD4<Float>(0.5, 0.5, 0.5, 1))
    func tap(_ v: Int) -> Int? {
        let p = viewProjection * SIMD4(shown.vertices[v].position, 1)
        return MeshPicker.pick(mesh: shown, topology: mirrored.topology, mode: .vertex,
                               ndc: SIMD2(p.x / p.w, p.y / p.w), viewSize: SIMD2(400, 400),
                               viewProjection: viewProjection, eye: SIMD3(0, 0, 10),
                               ray: (SIMD3(shown.vertices[v].position.x, shown.vertices[v].position.y, 10),
                                     SIMD3(0, 0, -1))).vertex
    }
    check("a tap on a hidden vertex picks nothing", tap(1) == nil, "\(String(describing: tap(1)))")
    check("a tap on a shown one, with no face left, still picks it", tap(4) == 4, "\(String(describing: tap(4)))")

    let object = BKObject(name: "Quad", kind: .plane)
    object.setMirroredMesh(shown)
    object.editTopology = mirrored.topology
    let all = object.editElements(in: CGRect(x: -10, y: -10, width: 420, height: 420), mode: .vertex,
                                  viewProjection: viewProjection, size: CGSize(width: 400, height: 400))
    check("a box round everything takes the shown vertices only", all.vertices == [0, 3, 4], "\(all.vertices)")
}

print("\n== a mirror pass that hands back the same mesh is recognised ==")
do {
    let positions = quad.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }
    let normals = quad.vertices.flatMap { [$0.normal.x, $0.normal.y, $0.normal.z] }
    func same(_ p: [Float], _ n: [Float], _ t: [UInt32]) -> Bool {
        p.withUnsafeBufferPointer { pp in
            n.withUnsafeBufferPointer { nn in
                t.withUnsafeBufferPointer { tt in
                    quad.matches(positions: pp, normals: nn, triangles: tt)
                }
            }
        }
    }
    check("the same buffers match", same(positions, normals, quad.indices))
    var moved = positions; moved[4] += 0.001
    check("a moved vertex does not", !same(moved, normals, quad.indices))
    var turned = normals; turned[2] = -1
    check("nor a changed normal", !same(positions, turned, quad.indices))
    check("nor the same vertices in other triangles", !same(positions, normals, [0, 1, 2, 0, 2, 3, 2, 4, 1]))
    check("nor a different count", !same(Array(positions.dropLast(3)), Array(normals.dropLast(3)), quad.indices))
}

print("\n== select modes, as Blender spells them ==")
check("bit 1 is vertex", MeshSelectMode(blenderBits: 1) == .vertex)
check("bit 2 is edge", MeshSelectMode(blenderBits: 2) == .edge)
check("bit 4 is face", MeshSelectMode(blenderBits: 4) == .face)
check("several at once: the finest wins", MeshSelectMode(blenderBits: 6) == .edge)
check("none is nothing", MeshSelectMode(blenderBits: 0) == nil)
check("the operator's names are VERT, EDGE and FACE",
      MeshSelectMode.allCases.map(\.bpyType) == ["VERT", "EDGE", "FACE"])

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
