import Foundation
import simd

// What a tap in edit mode picks. A real cube, a real camera, and the tap given
// as a point on a real-sized viewport — because the bug this suite was written
// for was a tolerance measured in clip space, which is a different number of
// points across than it is up.
//
// The Python half, which checks that what is picked here is what Blender ends
// up with selected, is scripts/run-meshpick-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

// An iPad's 3D View, in points, with the cube Blender starts with — eight
// corners shared between the faces, which is how the mirror hands it over
// (`MeshBuilder`'s own cube splits them per face for flat shading, and edit
// mode never sees that one: on the device the tap log said eight vertices).
let viewSize = SIMD2<Float>(1193, 729)
let aspect = viewSize.x / viewSize.y

let corners: [SIMD3<Float>] = [
    SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
    SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1),
]
// Two triangles per face, wound outward, in face order.
let cubeIndices: [UInt32] = [0, 3, 2,  0, 2, 1,   4, 5, 6,  4, 6, 7,
                             0, 1, 5,  0, 5, 4,   1, 2, 6,  1, 6, 5,
                             2, 3, 7,  2, 7, 6,   3, 0, 4,  3, 4, 7]
let cube = MeshData(vertices: corners.map { MeshVertex($0, normalize($0)) },
                    indices: cubeIndices)

var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 8
camera.target = .zero

let model = matrix_identity_float4x4
let viewProjection = camera.viewProjection(aspect: aspect) * model

/// Blender's own edges for a cube: the twelve, without the six diagonals the
/// viewport's triangles leave behind.
func cubeTopology() -> EditTopology {
    var real: Set<Int> = []
    for e in 0..<(cube.edges.count / 2) {
        let a = cube.vertices[Int(cube.edges[e * 2])].position
        let b = cube.vertices[Int(cube.edges[e * 2 + 1])].position
        // A cube's real edges run along one axis; a diagonal moves in two.
        if (0..<3).filter({ abs(a[$0] - b[$0]) > 1e-4 }).count == 1 { real.insert(e) }
    }
    // Two triangles per face, so polygon 0 is the first pair and so on.
    let polygons = (0..<(cube.indices.count / 3)).map { UInt32($0 / 2) }
    return EditTopology(vertexCount: cube.vertices.count, polygonCount: 6,
                        trianglePolygons: polygons, realEdges: real)
}
let topology = cubeTopology()

/// Where a vertex lands on screen, in points from the middle.
func screen(_ i: Int) -> SIMD2<Float> {
    let clip = viewProjection * SIMD4(cube.vertices[i].position, 1)
    return SIMD2(clip.x / clip.w, clip.y / clip.w) * viewSize / 2
}

/// A tap, given in points from the middle of the view.
func pick(at points: SIMD2<Float>, mode: MeshSelectMode) -> MeshPicker.Hit {
    let ndc = points / (viewSize / 2)
    let (origin, direction) = camera.ray(atNDC: ndc, aspect: aspect)
    return MeshPicker.pick(mesh: cube, topology: topology, mode: mode,
                           ndc: ndc, viewSize: viewSize, viewProjection: viewProjection,
                           eye: camera.eye, ray: (origin, normalize(direction)))
}

/// The corner nearest the camera, and the one hidden behind the cube.
let nearest = cube.vertices.indices.max { distance(cube.vertices[$0].position, camera.eye)
    > distance(cube.vertices[$1].position, camera.eye) }!
let hidden = cube.vertices.indices.max { distance(cube.vertices[$0].position, camera.eye)
    < distance(cube.vertices[$1].position, camera.eye) }!

print("\n  a tap on a vertex")
check("straight on it picks it", pick(at: screen(nearest), mode: .vertex).vertex == nearest,
      "\(String(describing: pick(at: screen(nearest), mode: .vertex).vertex)) not \(nearest)")

// The bug: 0.05 in clip space was 18 points up and 30 across, so a tap a
// finger's width below a vertex picked nothing — and picking nothing is a Set
// click on empty space, which threw the whole selection away.
for offset in [SIMD2<Float>(0, -18), SIMD2(0, 18), SIMD2(-18, 0), SIMD2(18, 0)] {
    let hit = pick(at: screen(nearest) + offset, mode: .vertex)
    check("and \(Int(abs(offset.x + offset.y))) points \(offset.y < 0 ? "below" : offset.y > 0 ? "above" : offset.x < 0 ? "left of" : "right of") it too",
          hit.vertex == nearest, String(describing: hit.vertex))
}
check("the radius is the same distance in both directions",
      MeshPicker.touchRadius > 0
      && (pick(at: screen(nearest) + SIMD2(0, MeshPicker.touchRadius - 1), mode: .vertex).vertex
          == pick(at: screen(nearest) + SIMD2(MeshPicker.touchRadius - 1, 0), mode: .vertex).vertex))

print("\n  what the surface hides")
check("the corner behind the cube is not picked",
      pick(at: screen(hidden), mode: .vertex).vertex != hidden,
      String(describing: pick(at: screen(hidden), mode: .vertex).vertex))
check("something in front of it is", pick(at: screen(hidden), mode: .vertex).vertex != nil)

print("\n  a tap on the face, away from any corner")
// The middle of the cube is nowhere near a corner. Blender would deselect;
// a finger cannot aim better than this, so the face's nearest corner is taken.
let middle = SIMD2<Float>(0, 0)
let onFace = pick(at: middle, mode: .vertex)
check("picks a corner of the face it hit", onFace.vertex != nil, "picked nothing")
check("and that corner is one of the ones on screen",
      onFace.vertex.map { MeshPicker.visibleVertices(mesh: cube, eye: camera.eye)?[$0] ?? true } == true)

print("\n  a tap on empty space")
let away = SIMD2<Float>(viewSize.x / 2 - 4, viewSize.y / 2 - 4)
for mode in MeshSelectMode.allCases {
    check("picks nothing in \(mode.label) mode", pick(at: away, mode: mode).isEmpty,
          "\(pick(at: away, mode: mode))")
}
check("so Set clears the selection, as Blender does",
      SelectAction.set.apply(Set([1, 2, 3]), hit: Set<Int>()).isEmpty)

print("\n  a tap on an edge")
// Halfway along the edge between the two corners nearest the camera — the
// place the old picker could never hit, because it looked for a vertex first.
let ends = topology.realEdges.sorted().map { (Int(cube.edges[$0 * 2]), Int(cube.edges[$0 * 2 + 1]), $0) }
let onEdge = ends.first { $0.0 == nearest || $0.1 == nearest }!
let midpoint = (screen(onEdge.0) + screen(onEdge.1)) / 2
check("the middle of an edge picks that edge", pick(at: midpoint, mode: .edge).edge == onEdge.2,
      String(describing: pick(at: midpoint, mode: .edge).edge))
check("not a vertex", pick(at: midpoint, mode: .edge).vertex == nil)

// Three edges meet at a corner. The old code returned whichever came first in
// the list; the nearest one is the one under the finger.
var byCorner = ends.filter { $0.0 == nearest || $0.1 == nearest }
check("three edges meet at the near corner", byCorner.count == 3, "\(byCorner.count)")
for edge in byCorner {
    let other = edge.0 == nearest ? edge.1 : edge.0
    // A quarter of the way along, well inside this edge and not the others.
    let aim = screen(nearest) + (screen(other) - screen(nearest)) * 0.35
    check("a tap along one of them picks that one", pick(at: aim, mode: .edge).edge == edge.2,
          "\(String(describing: pick(at: aim, mode: .edge).edge)) not \(edge.2)")
}

print("\n  edges Blender does not have")
let diagonals = Set(0..<(cube.edges.count / 2)).subtracting(topology.realEdges)
check("a cube has twelve edges and six face diagonals",
      topology.realEdges.count == 12 && diagonals.count == 6,
      "\(topology.realEdges.count) real, \(diagonals.count) diagonal")
check("and none of them can be picked",
      !diagonals.contains(where: { d in
          let a = screen(Int(cube.edges[d * 2])), b = screen(Int(cube.edges[d * 2 + 1]))
          return pick(at: (a + b) / 2, mode: .edge).edge == d
      }))
check("with no report, every edge is offered",
      MeshPicker.pickableEdges(mesh: cube, topology: nil).count == cube.edges.count / 2)

print("\n  a tap on a face")
let faceHit = pick(at: middle, mode: .face)
check("picks a whole polygon, not one triangle", faceHit.faces.count == 2, "\(faceHit.faces)")
check("both triangles belong to the same polygon",
      Set(faceHit.faces.map { topology.trianglePolygons[$0] }).count == 1)
check("and it is the face the ray hit",
      faceHit.faces.contains(MeshPicker.nearestTriangle(
          mesh: cube, ray: { let r = camera.ray(atNDC: .zero, aspect: aspect)
                             return (r.origin, normalize(r.direction)) }())!))
check("nothing else comes with it", faceHit.vertex == nil && faceHit.edge == nil)

print("\n  the arithmetic underneath")
check("distance to a segment is to the line, not the ends",
      abs(MeshPicker.distanceToSegment(SIMD2(5, 3), SIMD2(0, 0), SIMD2(10, 0)) - 3) < 1e-5,
      "\(MeshPicker.distanceToSegment(SIMD2(5, 3), SIMD2(0, 0), SIMD2(10, 0)))")
check("past the end it is to the end",
      abs(MeshPicker.distanceToSegment(SIMD2(14, 3), SIMD2(0, 0), SIMD2(10, 0)) - 5) < 1e-5)
check("a segment of no length is its point",
      abs(MeshPicker.distanceToSegment(SIMD2(3, 4), SIMD2(0, 0), SIMD2(0, 0)) - 5) < 1e-5)
check("a cube shows seven of its eight corners",
      MeshPicker.visibleVertices(mesh: cube, eye: camera.eye)?.filter { $0 }.count == 7,
      "\(String(describing: MeshPicker.visibleVertices(mesh: cube, eye: camera.eye)?.filter { $0 }.count))")
check("and the one it hides is the far one",
      MeshPicker.visibleVertices(mesh: cube, eye: camera.eye)?[hidden] == false)

print("\n  meshes with nothing to hide behind")
let loose = MeshData(vertices: [MeshVertex(SIMD3(0, 0, 0), SIMD3(0, 0, 1))], indices: [])
check("loose vertices are all pickable", MeshPicker.visibleVertices(mesh: loose, eye: camera.eye) == nil)
check("and an empty mesh picks nothing",
      MeshPicker.pick(mesh: MeshData(vertices: [], indices: []), topology: nil, mode: .vertex,
                      ndc: .zero, viewSize: viewSize, viewProjection: viewProjection,
                      eye: camera.eye, ray: (camera.eye, SIMD3(0, 0, -1))).isEmpty)
check("a view with no size picks nothing",
      MeshPicker.pick(mesh: cube, topology: topology, mode: .vertex, ndc: .zero,
                      viewSize: .zero, viewProjection: viewProjection,
                      eye: camera.eye, ray: (camera.eye, SIMD3(0, 0, -1))).isEmpty)

print("\n  a report the mesh has outgrown")
// Every number in the topology is an index into the mesh it was read from.
// After a subdivide, before the next mirror pass, they name other elements.
let stale = EditTopology(vertexCount: 99, polygonCount: 6,
                         trianglePolygons: topology.trianglePolygons, realEdges: topology.realEdges)
check("is not describing this mesh", !stale.describes(cube) && topology.describes(cube))
let staleHit = MeshPicker.pick(mesh: cube, topology: stale, mode: .face, ndc: .zero,
                               viewSize: viewSize, viewProjection: viewProjection,
                               eye: camera.eye,
                               ray: { let r = camera.ray(atNDC: .zero, aspect: aspect)
                                      return (r.origin, normalize(r.direction)) }())
check("so a face is the one triangle the ray hit, not a polygon it cannot name",
      staleHit.faces.count == 1, "\(staleHit.faces)")

print("\n  an orthographic view")
// There is no eye to be towards, so facing is judged against the one direction
// the whole view looks.
var flat = camera
flat.isOrthographic = true
let flatVP = flat.viewProjection(aspect: aspect)
let down = normalize(flat.ray(atNDC: .zero, aspect: aspect).direction)
let seen = MeshPicker.visibleVertices(mesh: cube, eye: flat.eye, viewDirection: down)
check("still shows seven of the eight corners", seen?.filter { $0 }.count == 7,
      "\(String(describing: seen?.filter { $0 }.count))")
check("and still hides the far one", seen?[hidden] == false)
check("a tap on the hidden corner picks something else",
      MeshPicker.pick(mesh: cube, topology: topology, mode: .vertex,
                      ndc: { let c = flatVP * SIMD4(cube.vertices[hidden].position, 1)
                             return SIMD2(c.x / c.w, c.y / c.w) }(),
                      viewSize: viewSize, viewProjection: flatVP, eye: flat.eye,
                      viewDirection: down,
                      ray: (flat.eye, down)).vertex != hidden)

print()
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASS")
