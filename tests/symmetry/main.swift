import Foundation
import simd
import CoreGraphics

// Mirror editing on the Swift side: the flag the mirror carries, which
// vertices follow which (SymmetricEdit), Topology Mirror's pairs, what a drag
// previews and sends, and what the toggles and the Mesh menu send. What
// Blender does with all of it is tests/symmetry/blender/verify.py.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
    abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

/// A flat grid, `n` × `n` vertices from -1 to 1, row by row, and its edges.
func grid(_ n: Int) -> (positions: [SIMD3<Float>], triangles: [UInt32], edges: [UInt32]) {
    var positions: [SIMD3<Float>] = []
    for j in 0..<n {
        for i in 0..<n {
            positions.append(SIMD3(-1 + 2 * Float(i) / Float(n - 1), -1 + 2 * Float(j) / Float(n - 1), 0))
        }
    }
    var triangles: [UInt32] = [], edges: [UInt32] = []
    for j in 0..<n {
        for i in 0..<n {
            let v = UInt32(j * n + i)
            if i + 1 < n { edges += [v, v + 1] }
            if j + 1 < n { edges += [v, v + UInt32(n)] }
            if i + 1 < n, j + 1 < n {
                triangles += [v, v + 1, v + UInt32(n) + 1, v, v + UInt32(n) + 1, v + UInt32(n)]
            }
        }
    }
    return (positions, triangles, edges)
}
let g5 = grid(5)       // x and y in -1, -0.5, 0, 0.5, 1
func at(_ x: Float, _ y: Float) -> Int { g5.positions.firstIndex { close($0, SIMD3(x, y, 0)) }! }

print("== the mirror carries Blender's flags ==")
check("`|mirror=xt` is X and Topology Mirror",
      SceneMirror.symmetry(["MESH", "mirror=xt"]) == MeshSymmetry(x: true, topology: true))
check("no flag is no symmetry", SceneMirror.symmetry(["MESH", "hidden"]) == MeshSymmetry())
check("Topology Mirror alone mirrors nothing", !MeshSymmetry(topology: true).isOn)
do {
    let scene = BKScene(startupFile: false)
    let o = scene.add(.cube)
    o.name = "Cube"
    let fresh = BKObject(name: "Cube", kind: .cube)
    fresh.symmetry = MeshSymmetry(y: true, z: true)
    SceneMirror.merge([fresh], into: scene, unchanged: [], selection: [], active: nil)
    check("a pass's symmetry reaches the object already on screen",
          scene.objects.first?.symmetry == MeshSymmetry(y: true, z: true))
    let cleared = BKObject(name: "Cube", kind: .cube)
    SceneMirror.merge([cleared], into: scene, unchanged: [], selection: [], active: nil)
    check("and a pass with the flags off turns it off", scene.objects.first?.symmetry == MeshSymmetry())
}

print("== which vertices follow which ==")
check("no axis on is no mirror",
      SymmetricEdit(positions: g5.positions, selected: [at(0.5, 0.5)], symmetry: MeshSymmetry(topology: true),
                    proportional: false) == nil)
do {
    let s = SymmetricEdit(positions: g5.positions, selected: [at(0.5, 0.5)], symmetry: MeshSymmetry(x: true),
                          proportional: false)!
    check("X: the selected vertex's mirror image follows it", s.followers == [at(-0.5, 0.5)], "\(s.followers)")
    check("negated on X", s.source[at(-0.5, 0.5)] == Int32(at(0.5, 0.5)) && s.flips[at(-0.5, 0.5)] == 1)
    var moved = g5.positions
    moved[at(0.5, 0.5)] = SIMD3(0.7, 0.6, 0.3)
    s.apply(to: &moved)
    check("and is placed at the mirror image of where it went", close(moved[at(-0.5, 0.5)], SIMD3(-0.7, 0.6, 0.3)))
}
do {
    let s = SymmetricEdit(positions: g5.positions, selected: [at(-0.5, 0.5)], symmetry: MeshSymmetry(x: true),
                          proportional: false)!
    check("a selection on the -X side drives the +X side", s.followers == [at(0.5, 0.5)])
}
do {
    let both: Set<Int> = [at(0.5, 0.5), at(-0.5, 0.5)]
    let s = SymmetricEdit(positions: g5.positions, selected: both, symmetry: MeshSymmetry(x: true),
                          proportional: false)!
    check("both sides selected: the sum is 0, its sign +, and the -X one follows",
          s.followers == [at(-0.5, 0.5)])
}
do {
    let s = SymmetricEdit(positions: g5.positions, selected: [at(0, 0.5), at(0.5, 0.5)],
                          symmetry: MeshSymmetry(x: true), proportional: false)!
    check("a selected vertex on the plane is held there", s.pinned[at(0, 0.5)] == 1 && s.pinned[at(0.5, 0.5)] == 0)
    var moved = g5.positions
    moved[at(0, 0.5)] = SIMD3(0.2, 0.6, 0.1)
    s.apply(to: &moved)
    check("its X goes back to 0, the rest of its move stays", close(moved[at(0, 0.5)], SIMD3(0, 0.6, 0.1)))
}
do {
    let s = SymmetricEdit(positions: g5.positions, selected: [at(0.5, 1)], symmetry: MeshSymmetry(x: true, y: true),
                          proportional: false)!
    check("X and Y: three images follow, the diagonal one negated on both",
          Set(s.followers) == [at(-0.5, 1), at(0.5, -1), at(-0.5, -1)]
            && s.flips[at(-0.5, 1)] == 1 && s.flips[at(0.5, -1)] == 2 && s.flips[at(-0.5, -1)] == 3,
          "\(s.followers) \(s.followers.map { s.flips[$0] })")
}
do {
    let s = SymmetricEdit(positions: g5.positions, selected: [at(0.5, 0.5)], hidden: [at(-0.5, 0.5)],
                          symmetry: MeshSymmetry(x: true), proportional: false)!
    check("a hidden mirror image does not follow", s.followers.isEmpty)
}
do {
    let s = SymmetricEdit(positions: g5.positions, selected: [at(0.5, 0.5)], symmetry: MeshSymmetry(x: true),
                          proportional: true)!
    // Every visible vertex on the +X side drives: the 10 off the plane on -X follow.
    check("with proportional editing every vertex in the quadrant drives its image",
          s.followers.count == 10 && s.followers.allSatisfy { g5.positions[$0].x < 0 }, "\(s.followers.count)")
    let factors = TransformOperation.vertexFactors(
        positions: g5.positions, selected: [at(0.5, 0.5)], model: matrix_identity_float4x4,
        proportional: ProportionalEdit(falloff: .linear, size: 2), connectivity: nil, symmetry: s)
    check("and the followers take no share of the move themselves",
          s.followers.allSatisfy { factors[$0] == 0 } && factors[at(0.5, 0.5)] == 1 && factors[at(1, 1)] > 0)
}
do {
    // Both of a pair selected, and a third on +X: the sum is +, so the -X one
    // of the pair is a follower and is not transformed as a selected vertex.
    let chosen: Set<Int> = [at(0.5, 0.5), at(-0.5, 0.5), at(1, 1)]
    let s = SymmetricEdit(positions: g5.positions, selected: chosen,
                          symmetry: MeshSymmetry(x: true), proportional: false)!
    let factors = TransformOperation.vertexFactors(
        positions: g5.positions, selected: chosen, model: matrix_identity_float4x4,
        proportional: nil, connectivity: nil, symmetry: s)
    check("a selected follower is not moved as a selected vertex",
          s.followers == [at(-0.5, 0.5), at(-1, 1)].sorted() && factors[at(-0.5, 0.5)] == 0
            && factors[at(0.5, 0.5)] == 1 && factors[at(1, 1)] == 1, "\(s.followers)")
    let left = SymmetricEdit(positions: g5.positions, selected: [at(0.5, 0.5), at(-1, -1)],
                             symmetry: MeshSymmetry(x: true), proportional: false)!
    check("and the side is the selection's sum: 0.5 and -1 make -X the driver",
          left.followers == [at(1, -1)], "\(left.followers)")
}

print("== Topology Mirror ==")
do {
    // A path of five: the ends pair, the next two in pair, the middle is its own.
    let table = SymmetricEdit.topologyTable(vertexCount: 5, edges: [0, 1, 1, 2, 2, 3, 3, 4])
    check("a path of five pairs end with end and keeps its middle", table == [4, 3, 2, 1, 0], "\(table)")
    // The same path, 3-0-4-1-2, numbered out of order.
    let shuffled = SymmetricEdit.topologyTable(vertexCount: 5, edges: [3, 0, 0, 4, 4, 1, 1, 2])
    check("whatever the numbering", shuffled == [1, 0, 3, 2, 4], "\(shuffled)")
    // A square grid is symmetric four ways, so no two vertices are alone in
    // their place but the centre, which is its own.
    let square = SymmetricEdit.topologyTable(vertexCount: g5.positions.count, edges: g5.edges)
    check("a square grid pairs nothing and keeps its centre",
          square.enumerated().allSatisfy { $0.element == ($0.offset == at(0, 0) ? Int32(at(0, 0)) : -1) },
          "\(square)")
}
do {
    // Pushed out of place, the path still pairs by its edges.
    let positions: [SIMD3<Float>] = [SIMD3(-2, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 0), SIMD3(1.3, 0, 0), SIMD3(2.2, 0.1, 0)]
    let edges: [UInt32] = [0, 1, 1, 2, 2, 3, 3, 4]
    let byPlace = SymmetricEdit(positions: positions, selected: [4], symmetry: MeshSymmetry(x: true),
                                proportional: false, edges: edges)!
    let byEdges = SymmetricEdit(positions: positions, selected: [4], symmetry: MeshSymmetry(x: true, topology: true),
                                proportional: false, edges: edges)!
    check("by position, a vertex out of place has no image", byPlace.followers.isEmpty)
    check("by topology it still has", byEdges.followers == [0], "\(byEdges.followers)")
    let both = SymmetricEdit(positions: positions, selected: [4], symmetry: MeshSymmetry(x: true, y: true, topology: true),
                             proportional: false, edges: edges)!
    check("X and Y with Topology Mirror make the selected vertex its own follower, and Blender cancels",
          both.cancels && both.followerSet.contains(4))
    var moved = positions
    moved[4] += SIMD3(0, 0, 1)
    let out = TransformOperation(kind: .translate(SIMD3(0, 0, 1)), pivot: .point(.zero))
        .apply(toVertices: positions, factors: [0, 0, 0, 0, 1], selected: [4], model: matrix_identity_float4x4,
               symmetry: both)
    check("so the preview moves nothing", out == positions)
}

print("== a drag previews the mirror and sends mirror=True ==")
let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 8
let options = ViewportOptions()

func editScene(symmetry: MeshSymmetry, selected: Set<Int>) -> (BKScene, BKObject) {
    let s = BKScene(startupFile: false)
    let o = s.add(.plane)
    var mesh = MeshData(vertices: g5.positions.map { MeshVertex($0, SIMD3(0, 0, 1)) }, indices: g5.triangles)
    ModifierStack.recomputeNormals(&mesh, welded: true)
    o.setEvaluatedMesh(mesh)
    o.symmetry = symmetry
    s.selection = [o.id]
    s.activeID = o.id
    s.setMode(.edit)
    let report = BlenderEditReport(selectMode: 1,
                                   vertexSelected: g5.positions.indices.map { selected.contains($0) ? 1 : 0 },
                                   trianglePolygons: (0..<(g5.triangles.count / 3)).map { UInt32($0 / 2) },
                                   polygonSelected: Array(repeating: 0, count: g5.triangles.count / 6),
                                   edgeVertices: g5.edges,
                                   edgeSelected: Array(repeating: 0, count: g5.edges.count / 2))
    precondition(s.mirrorEditSelection(report, on: o))
    return (s, o)
}

func dragUp(_ s: BKScene) -> String {
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let p = TransformGizmo.Projection(camera: camera, size: size)
    let c = p.project(g.origin)!, t = p.project(g.origin + g.axes[2] * g.radius)!
    let session = TransformGizmo.beginSession(handle: .axis(2), at: t, gizmo: g, scene: s,
                                              camera: camera, size: size, options: options)
    let to = CGPoint(x: t.x + (t.x - c.x) * 0.5, y: t.y + (t.y - c.y) * 0.5)
    let result = TransformGizmo.resolve(session, at: to)!
    TransformGizmo.apply(result, session: session)
    return TransformGizmo.python(result, session: session)
}

do {
    let (s, o) = editScene(symmetry: MeshSymmetry(x: true), selected: [at(0.5, 0.5)])
    check("the report carries Blender's edges for Topology Mirror", o.editTopology?.blenderEdges == g5.edges)
    let python = dragUp(s)
    let lifted = o.mesh.vertices[at(0.5, 0.5)].position.z
    check("the preview lifts the vertex and its image together",
          lifted > 0.1 && abs(o.mesh.vertices[at(-0.5, 0.5)].position.z - lifted) < 1e-6
            && o.mesh.vertices[at(0.5, -0.5)].position.z == 0, "\(lifted)")
    check("and the commit says mirror=True", python.contains("mirror=True"), python)
}
do {
    let (s, o) = editScene(symmetry: MeshSymmetry(), selected: [at(0.5, 0.5)])
    let python = dragUp(s)
    check("with the symmetry off the image stays and nothing is said",
          o.mesh.vertices[at(-0.5, 0.5)].position.z == 0 && !python.contains("mirror"), python)
}
do {
    // Object mode never mirrors: there is no mesh being edited.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.symmetry = MeshSymmetry(x: true)
    s.selection = [o.id]
    s.activeID = o.id
    let python = dragUp(s)
    check("an object-mode move says nothing of mirroring", !python.contains("mirror"), python)
}

print("== under a modifier that moves what is drawn, the pairs are Blender's ==")
// A twist about X, as SimpleDeform's default Twist does it: the angle grows
// with x, so the drawn mesh is no longer symmetric in X while the edit mesh
// is. Measured in 5.2.1 on Blender's grid with that modifier: the vertex at
// (0.6, 0.4) has no image among the drawn positions, and translate(mirror=True)
// moved it and its image on the edit mesh.
func twisted(_ p: SIMD3<Float>) -> SIMD3<Float> {
    let t = 0.4 * p.x
    return SIMD3(p.x, p.y * cos(t) - p.z * sin(t), p.y * sin(t) + p.z * cos(t))
}
let drawn = g5.positions.map(twisted)
do {
    let none = SymmetricEdit(positions: drawn, selected: [at(0.5, 0.5)], symmetry: MeshSymmetry(x: true),
                             proportional: false)!
    check("paired on the drawn positions the vertex has no image (the defect)", none.followers.isEmpty,
          "\(none.followers)")
    let s = SymmetricEdit(positions: g5.positions, shown: drawn, selected: [at(0.5, 0.5)],
                          symmetry: MeshSymmetry(x: true), proportional: false)!
    check("paired on Blender's coordinates it has its image", s.followers == [at(-0.5, 0.5)], "\(s.followers)")
    // The preview moves the drawn positions: the image moves by its source's
    // movement, X negated — Blender's rule, applied in Blender's coordinates.
    var moved = drawn
    let step = SIMD3<Float>(0.1, 0.2, 0.3)
    moved[at(0.5, 0.5)] += step
    s.apply(to: &moved)
    check("the image moves by the source's step, X negated",
          close(moved[at(-0.5, 0.5)], drawn[at(-0.5, 0.5)] + SIMD3(-0.1, 0.2, 0.3)),
          "\(moved[at(-0.5, 0.5)] - drawn[at(-0.5, 0.5)])")
    let plain = SymmetricEdit(positions: g5.positions, shown: g5.positions, selected: [at(0.5, 0.5)],
                              symmetry: MeshSymmetry(x: true), proportional: false)!
    check("drawn positions equal to Blender's carry no offsets", plain.offsets.isEmpty)
    // On the plane: Blender's x = 0 is where the vertex is drawn, whatever
    // the drawn x.
    var shifted = g5.positions
    for i in shifted.indices { shifted[i].x += 0.05 }
    let pinned = SymmetricEdit(positions: g5.positions, shown: shifted, selected: [at(0, 0.5)],
                               symmetry: MeshSymmetry(x: true), proportional: false)!
    var out = shifted
    out[at(0, 0.5)].x += 0.3
    pinned.apply(to: &out)
    check("a vertex held on the plane stays where Blender's plane is drawn", abs(out[at(0, 0.5)].x - 0.05) < 1e-6,
          "\(out[at(0, 0.5)].x)")
}
do {
    // The mirror's report, carrying Blender's coordinates.
    func report(_ coordinates: [SIMD3<Float>]) -> BlenderEditReport {
        BlenderEditReport(selectMode: 1,
                          vertexSelected: g5.positions.indices.map { $0 == at(0.5, 0.5) ? 1 : 0 },
                          trianglePolygons: (0..<(g5.triangles.count / 3)).map { UInt32($0 / 2) },
                          polygonSelected: Array(repeating: 0, count: g5.triangles.count / 6),
                          edgeVertices: g5.edges,
                          edgeSelected: Array(repeating: 0, count: g5.edges.count / 2),
                          vertexCoordinates: coordinates.flatMap { [$0.x, $0.y, $0.z] })
    }
    let s = BKScene(startupFile: false)
    let o = s.add(.plane)
    var mesh = MeshData(vertices: drawn.map { MeshVertex($0, SIMD3(0, 0, 1)) }, indices: g5.triangles)
    ModifierStack.recomputeNormals(&mesh, welded: true)
    o.setEvaluatedMesh(mesh)
    o.symmetry = MeshSymmetry(x: true)
    s.selection = [o.id]
    s.activeID = o.id
    s.setMode(.edit)
    precondition(s.mirrorEditSelection(report(g5.positions), on: o))
    check("the report's coordinates reach the topology", o.editTopology?.blenderPositions == g5.positions)
    let python = dragUp(s)
    let source = o.mesh.vertices[at(0.5, 0.5)].position - drawn[at(0.5, 0.5)]
    let image = o.mesh.vertices[at(-0.5, 0.5)].position - drawn[at(-0.5, 0.5)]
    check("a drag over the twist previews the image Blender will move",
          simd_length(source) > 0.1 && close(image, SIMD3(-source.x, source.y, source.z)) && python.contains("mirror=True"),
          "source \(source) image \(image)")
    check("and nothing else", o.mesh.vertices.indices.filter {
        simd_distance(o.mesh.vertices[$0].position, drawn[$0]) > 1e-6
    }.count == 2)
    let back = BKScene(startupFile: false)
    let p = back.add(.plane)
    p.setEvaluatedMesh(mesh)
    back.selection = [p.id]
    back.activeID = p.id
    back.setMode(.edit)
    precondition(back.mirrorEditSelection(report(drawn), on: p))
    check("coordinates equal to the drawn ones are dropped", p.editTopology?.blenderPositions.isEmpty == true)
}

print("== what the toggles and the Mesh menu send ==")
check("a toggle names its object and the mesh's flag",
      SymmetryBpy.set(.x, true, objectNamed: "Cube") == "bpy.data.objects[\"Cube\"].data.use_mirror_x = True")
check("a name with quotes in it stays one string",
      SymmetryBpy.set(.topology, false, objectNamed: "a\"b") == "bpy.data.objects[\"a\\\"b\"].data.use_mirror_topology = False",
      SymmetryBpy.set(.topology, false, objectNamed: "a\"b"))
for op in LastOperator.Mesh.allCases {
    let on = LastOperator.mesh(op, spinningAround: nil, symmetry: MeshSymmetry(x: true)).python
    let off = LastOperator.mesh(op, spinningAround: nil, symmetry: MeshSymmetry()).python
    let none = LastOperator.mesh(op, spinningAround: nil, symmetry: nil).python
    if op.honoursMeshSymmetry {
        // As Blender's 3D View stores it, so a redo reads the flags then.
        check("\(op.rawValue) sends mirror=True on a mesh, axis on or not, and nothing with no mesh",
              on.contains("mirror=True") && off.contains("mirror=True") && !none.contains("mirror"), off)
    } else if on.contains("mirror") {
        check("\(op.rawValue) does not mirror and says nothing of it", false, on)
    }
}
do {
    // X turned on with the redo panel open: the re-run says mirror=True.
    var made = LastOperator.mesh(.shrinkFatten, spinningAround: nil, symmetry: MeshSymmetry())
    made.subject = "Grid"
    made["value"] = 0.2
    check("an adjusted Shrink/Fatten still says mirror=True", made.rerunPython.contains("mirror=True"), made.rerunPython)
    check("and its re-run keeps the mesh's current symmetry flags over the backup's",
          made.rerunPython.contains("setattr(_o.data, _p, getattr(_old, _p))"), made.rerunPython)
}
check("toggles make an undo step where Blender's undo restores the flag",
      SymmetryBpy.undoLabel(.x, mode: .texturePaint) == "X" && SymmetryBpy.undoLabel(.y, mode: .vertexPaint) == "Y"
        && SymmetryBpy.undoLabel(.topology, mode: .weightPaint) == "Topology Mirror")
check("and none in Edit and Sculpt Mode, where it would not",
      SymmetryBpy.undoLabel(.x, mode: .edit) == nil && SymmetryBpy.undoLabel(.z, mode: .sculpt) == nil)
check("Topology Mirror is offered in Edit Mode and Weight Paint only",
      InteractionMode.allCases.filter(SymmetryBpy.offersTopology).map(\.rawValue) == ["edit", "weightPaint"])
check("the five that mirror are Blender's mirroring transforms",
      LastOperator.Mesh.allCases.filter(\.honoursMeshSymmetry).map(\.rawValue).sorted()
        == ["edgeSlide", "pushPull", "shrinkFatten", "slideVertices", "toSphere"])

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
