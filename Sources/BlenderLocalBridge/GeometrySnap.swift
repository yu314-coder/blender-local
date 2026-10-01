import Foundation
import simd

/// Snapping to geometry during a move: Blender's Vertex, Edge, Edge Center,
/// Face and Face Center, found by the app.
///
/// Blender cannot do this for a headless module. The round-1 review measured
/// it in 5.2.1: `transform.translate(snap=True, snap_elements={'VERTEX'})`
/// left the object at 2.7 even with a 3D View override and the GPU started,
/// because the search runs from the pointer in a view region and an exec has
/// neither (and takes `value` as final, see `TransformSnap`). The app does
/// hold every mirrored mesh and the camera, so it runs the same search here and
/// sends Blender the result as the operator's `value`. What the drag shows is
/// then exactly what Blender commits.
///
/// The rules are read from the 5.3 source (transform_snap.cc,
/// transform_snap_object.cc, transform_snap_object_mesh.cc and
/// transform_constraints.cc), since Blender cannot be made to snap here:
///
///   * The search is from the pointer, in screen space, within
///     `SNAP_MIN_DISTANCE` (30) of it. Nearest wins, and a vertex or an edge
///     beats a face: the face is only what the ray hit when nothing nearer
///     was found.
///   * What moves is never a target. In object mode that is every selected
///     object (`SCE_SNAP_TARGET_NOT_SELECTED`); while editing it is the
///     selected vertices and every edge and face that touches one
///     (`bm_edge_is_snap_target`, `bm_face_is_snap_target`). Here it is also
///     whatever proportional editing drags along: snapping onto something the
///     same drag then moves would commit a position that is not on it.
///   * With Edge or Edge Center chosen, edges are measured at the point
///     nearest the pointer's ray, and a Vertex or an Edge Center is only ever
///     found through the edge: which one depends on where along the edge the
///     ray passes (`snap_edge_points_impl`).
///   * Unless X-Ray is on, whatever lies behind the surface under the pointer
///     is out of reach — the occlusion plane — except the elements of the
///     polygon hit, which are tried first.
///   * The drag's constraint decides how the Snap With point meets the target:
///     projected onto the axis or plane for a point, to where the axis crosses
///     an edge or a face, to where an edge crosses the plane.
public enum GeometrySnap {

    /// `SNAP_MIN_DISTANCE` in transform_snap.hh: 30 region pixels. Taken as
    /// points, as the app takes Blender's pixel sizes everywhere
    /// (`OverlayView.pixelSize`); a fingertip is about 44 points across, so
    /// anything tighter would be under the finger.
    public static let radius: Float = 30

    /// The elements a move snaps to here. Volume and Edge Perpendicular are not
    /// reproduced: Volume peels through the depth under the pointer, and
    /// Perpendicular measures from where the moving element currently is.
    public static let honoured: Set<SnapElement> = [.vertex, .edge, .edgeMidpoint, .face, .faceMidpoint]

    /// What a snap landed on, as Blender reports it in `target_type`.
    public enum Kind: Equatable, Sendable {
        /// `SCE_SNAP_TO_POINT`: a vertex on no edge and no face, or the origin
        /// of an empty or a light.
        case point
        /// `SCE_SNAP_TO_EDGE_ENDPOINT` — what the Vertex element finds on a
        /// mesh with edges.
        case vertex
        case edge
        case edgeMidpoint
        case face
        case faceMidpoint

        /// The Snap To element that asked for it.
        public var element: SnapElement {
            switch self {
            case .point, .vertex: return .vertex
            case .edge:           return .edge
            case .edgeMidpoint:   return .edgeMidpoint
            case .face:           return .face
            case .faceMidpoint:   return .faceMidpoint
            }
        }

        public var label: String { element.label }
    }

    public struct Hit: Equatable, Sendable {
        public var kind: Kind
        /// World space.
        public var location: SIMD3<Float>
        /// Blender's `snapNormal`: the edge's direction for an Edge, the
        /// triangle's normal for a Face, unit length; zero for the rest, which
        /// a constraint treats as points.
        public var direction: SIMD3<Float>

        public init(kind: Kind, location: SIMD3<Float>, direction: SIMD3<Float> = .zero) {
            self.kind = kind
            self.location = location
            self.direction = direction
        }
    }

    /// The camera, frozen when the drag began, in the terms a touch is given:
    /// points from the view's top-left, y down.
    public struct View: Sendable {
        public let viewProjection: simd_float4x4
        public let size: SIMD2<Float>
        let inverse: simd_float4x4

        public init(viewProjection: simd_float4x4, size: SIMD2<Float>) {
            self.viewProjection = viewProjection
            self.size = size
            self.inverse = viewProjection.inverse
        }

        public func project(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let clip = viewProjection * SIMD4(p, 1)
            guard clip.w > 1e-5 else { return nil }   // behind the eye
            return SIMD2((clip.x / clip.w * 0.5 + 0.5) * size.x,
                         (0.5 - clip.y / clip.w * 0.5) * size.y)
        }

        /// The pointer's ray, from the near plane.
        public func ray(_ pointer: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
            guard size.x > 0, size.y > 0 else { return nil }
            let ndc = SIMD2<Float>(pointer.x / size.x * 2 - 1, 1 - pointer.y / size.y * 2)
            let near = inverse * SIMD4(ndc.x, ndc.y, 0, 1)
            let far = inverse * SIMD4(ndc.x, ndc.y, 1, 1)
            guard abs(near.w) > 1e-6, abs(far.w) > 1e-6 else { return nil }
            let o = near.xyz / near.w
            let d = far.xyz / far.w - o
            guard length_squared(d) > 0 else { return nil }
            return (o, normalize(d))
        }
    }

    /// The object being edited, and which of its vertices cannot be targets:
    /// the ones the drag moves and the ones Blender has hidden.
    public struct Edited {
        public let object: BKObject
        public let excluded: Set<Int>

        public init(object: BKObject, excluded: Set<Int>) {
            self.object = object
            self.excluded = excluded
        }
    }

    // MARK: - What a drag may land on

    /// Everything a drag may snap onto, gathered once when it begins. Nothing
    /// in it moves while the drag lasts — what moves was left out — so the
    /// search under each new pointer position is a pass over fixed arrays.
    public struct Targets: Sendable {
        public let elements: Set<SnapElement>
        public let radius: Float
        public let view: View
        /// Blender's occlusion plane, which X-Ray turns off.
        public let occlusion: Bool
        let bodies: [Body]

        /// Nothing in reach at all: no object, or no chosen element any of
        /// them has.
        public var isEmpty: Bool { bodies.isEmpty }

        public init(objects: [BKObject], view: View, elements: Set<SnapElement>,
                    excludedObjects: Set<UUID>, edited: Edited? = nil,
                    occlusion: Bool = true, radius: Float = GeometrySnap.radius) {
            self.elements = elements.intersection(GeometrySnap.honoured)
            self.radius = radius
            self.view = view
            self.occlusion = occlusion
            var bodies: [Body] = []
            if !self.elements.isEmpty {
                for object in objects where object.visible && !excludedObjects.contains(object.id) {
                    let excluded = edited?.object === object ? edited!.excluded : []
                    if let body = Body(object, view: view, excluded: excluded,
                                       editing: edited?.object === object,
                                       centres: self.elements.contains(.faceMidpoint)) {
                        bodies.append(body)
                    }
                }
            }
            self.bodies = bodies
        }

        /// The snap under `pointer` (points from the top-left), or nil when
        /// nothing chosen is in reach.
        public func find(_ pointer: SIMD2<Float>) -> Hit? {
            guard !bodies.isEmpty, let ray = view.ray(pointer) else { return nil }
            var search = Search(targets: self, pointer: pointer, ray: ray)
            return search.run()
        }
    }

    // MARK: - One object's share

    struct Body: Sendable {
        let world: [SIMD3<Float>]
        /// Where each vertex lands on screen; NaN behind the eye.
        let screen: [SIMD2<Float>]
        /// Candidates that are on a candidate edge or face: Blender finds these
        /// as `SCE_SNAP_TO_EDGE_ENDPOINT`.
        let vertices: [Int32]
        /// Candidates on neither — `bvh_loose_verts` — found as
        /// `SCE_SNAP_TO_POINT`, like an empty's origin.
        let loose: [Int32]
        let edges: [SIMD2<Int32>]
        let triangles: [SIMD3<Int32>]
        let trianglePolygon: [Int32]
        /// Blender's polygons: each one's corners and edges, which the hit
        /// polygon is searched by, and `edgeIndex`, which takes the
        /// topology's edge indices to `edges` (-1 for an edge left out).
        let topology: Topology
        let edgeIndex: [Int32]
        /// Per polygon, its centre, for the candidates — gathered only with
        /// Face Center chosen.
        let polygonCentres: [SIMD3<Float>]
        let polygonScreen: [SIMD2<Float>]
        let candidatePolygons: [Int32]
        /// World bounds of `triangles`, for the ray.
        let lo: SIMD3<Float>, hi: SIMD3<Float>
        /// Screen bounds of every candidate point, for the pointer.
        let screenLo: SIMD2<Float>, screenHi: SIMD2<Float>
        /// What turns a world edge into the direction Blender reports for it:
        /// `register_result` takes the edge in the object's space and carries
        /// it out as a normal, by the inverse transpose
        /// (transform_snap_object.cc), and the constraint then meets that
        /// direction (`transform_constraint_snap_axis_to_edge`). For world
        /// vector w = M·l that is (M·Mᵀ)⁻¹·w, which only a non-uniform scale
        /// turns off the edge itself. Nil for a matrix with no inverse.
        let edgeMetric: simd_float3x3?
        /// Whether the occlusion plane hides its points. A curve's control
        /// points ignore it (`snapCurve` enables its clip planes with
        /// `skip_occlusion_plane`).
        let occludable: Bool

        init?(_ object: BKObject, view: View, excluded: Set<Int>, editing: Bool, centres wantsCentres: Bool) {
            // Blender snaps an empty or a light to its origin
            // (`snap_object_center`), a camera only to motion-tracking
            // bundles, which the app does not have, and armatures and
            // lattices to data the mirror does not carry. An object sent as
            // its bounding box past the vertex limit is not its geometry, and
            // one displayed as its bounds is skipped (`snap_obj_fn`).
            let type = object.blenderType
            let pointOnly = type == "EMPTY" || type == "LIGHT"
            guard pointOnly || ["MESH", "CURVE", "SURFACE", "FONT", "META"].contains(type),
                  object.undrawnVertexCount == nil, pointOnly || !object.displaysBounds else { return nil }
            let model = object.modelMatrix
            // A curve with no surface by its control points, as loose points
            // only: `snapCurve` offers no edge, no face and no Edge Center,
            // and its wire is tessellation Blender does not snap to.
            let knots = pointOnly ? nil : object.snapPoints
            let mesh = pointOnly ? MeshData(vertices: [MeshVertex(.zero, SIMD3(0, 0, 1))], indices: [])
                : knots.map { MeshData(vertices: $0.map { MeshVertex($0, SIMD3(0, 0, 1)) }, indices: []) }
                    ?? object.mesh
            let count = mesh.vertices.count
            // An index past the vertices would read outside them below; such a
            // mesh is not one to land on.
            guard count > 0, mesh.indices.allSatisfy({ Int($0) < count }),
                  mesh.edges.allSatisfy({ Int($0) < count }) else { return nil }

            let world = mesh.vertices.map { (model * SIMD4($0.position, 1)).xyz }
            let nan = SIMD2<Float>(.nan, .nan)
            let screen = world.map { view.project($0) ?? nan }
            var candidate = [Bool](repeating: true, count: count)
            for i in excluded where i < count { candidate[i] = false }

            let topology = Topology(mesh: mesh,
                                    edit: editing ? object.editTopology.flatMap { $0.describes(mesh) ? $0 : nil } : nil)

            // A face is out when any vertex of its polygon is, not just of the
            // triangle: Blender asks it of the polygon.
            var polygonOut = [Bool](repeating: false, count: topology.polygonCount)
            for (t, tri) in topology.triangles.enumerated()
            where !(candidate[Int(tri.x)] && candidate[Int(tri.y)] && candidate[Int(tri.z)]) {
                polygonOut[Int(topology.trianglePolygon[t])] = true
            }

            var used = [Bool](repeating: false, count: count)
            var triangles: [SIMD3<Int32>] = []
            var trianglePolygon: [Int32] = []
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for (t, tri) in topology.triangles.enumerated()
            where !polygonOut[Int(topology.trianglePolygon[t])] {
                triangles.append(tri)
                trianglePolygon.append(topology.trianglePolygon[t])
                for k in 0..<3 {
                    let v = Int(tri[k])
                    used[v] = true
                    lo = simd_min(lo, world[v]); hi = simd_max(hi, world[v])
                }
            }
            var edgeIndex = [Int32](repeating: -1, count: topology.edges.count)
            var edges: [SIMD2<Int32>] = []
            for (e, edge) in topology.edges.enumerated()
            where candidate[Int(edge.x)] && candidate[Int(edge.y)] {
                edgeIndex[e] = Int32(edges.count)
                edges.append(edge)
                used[Int(edge.x)] = true
                used[Int(edge.y)] = true
            }
            var vertices: [Int32] = [], loose: [Int32] = []
            for i in 0..<count where candidate[i] && screen[i].x.isFinite {
                if used[i] { vertices.append(Int32(i)) } else { loose.append(Int32(i)) }
            }

            var centres: [SIMD3<Float>] = []
            var polygonScreen: [SIMD2<Float>] = []
            var candidatePolygons: [Int32] = []
            if wantsCentres {
                centres = [SIMD3<Float>](repeating: .zero, count: topology.polygonCount)
                polygonScreen = [SIMD2<Float>](repeating: nan, count: topology.polygonCount)
                for p in 0..<topology.polygonCount where !polygonOut[p] {
                    let corners = topology.corners(p)
                    guard !corners.isEmpty else { continue }
                    // bke::mesh::face_center_calc: the mean of the corners, not
                    // the area's centroid (measured in 5.2.1: `polygon.center`,
                    // which calls it, gave (2, 1, 0) for the quad (0,0) (4,0)
                    // (4,1) (0,3), whose centroid is at x = 1.67).
                    centres[p] = corners.reduce(SIMD3<Float>.zero) { $0 + world[Int($1)] } / Float(corners.count)
                    polygonScreen[p] = view.project(centres[p]) ?? nan
                    candidatePolygons.append(Int32(p))
                }
            }

            var screenLo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), screenHi = -screenLo
            for i in vertices + loose {
                screenLo = simd_min(screenLo, screen[Int(i)]); screenHi = simd_max(screenHi, screen[Int(i)])
            }
            for p in candidatePolygons where polygonScreen[Int(p)].x.isFinite {
                screenLo = simd_min(screenLo, polygonScreen[Int(p)])
                screenHi = simd_max(screenHi, polygonScreen[Int(p)])
            }
            guard !(vertices.isEmpty && loose.isEmpty && triangles.isEmpty) else { return nil }

            self.world = world
            self.screen = screen
            self.vertices = vertices
            self.loose = loose
            self.edges = edges
            self.triangles = triangles
            self.trianglePolygon = trianglePolygon
            self.topology = topology
            self.edgeIndex = edgeIndex
            self.polygonCentres = centres
            self.polygonScreen = polygonScreen
            self.candidatePolygons = candidatePolygons
            self.lo = lo; self.hi = hi
            self.screenLo = screenLo; self.screenHi = screenHi
            let linear = simd_float3x3(model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz)
            let gram = linear * linear.transpose
            self.edgeMetric = abs(gram.determinant) > 1e-12 ? gram.inverse : nil
            self.occludable = knots == nil
        }

        /// The direction Blender gives an edge from `a` to `b` (world space).
        func edgeDirection(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            normalizeOrZero(edgeMetric.map { $0 * (b - a) } ?? (b - a))
        }
    }

    /// Blender's edges and polygons, recovered from the triangles the viewport
    /// draws.
    ///
    /// The viewport's edge list comes from triangles, so it holds the
    /// diagonals triangulation added, which Blender has no edge for, and a
    /// quad is two triangles where Blender has one face whose centre is not
    /// either triangle's. The mirror says which is which in two ways: while
    /// editing, Blender's own edges and each triangle's polygon
    /// (`EditTopology`); otherwise the face corner behind each triangle
    /// corner, sent with the UV map, from which `uvDiagonals` marks the
    /// diagonals. A mesh with neither — no UV map, or the simulator's own
    /// meshes — can only be taken as triangles, diagonals and all.
    struct Topology: Sendable {
        var triangles: [SIMD3<Int32>] = []
        var trianglePolygon: [Int32] = []
        var polygonCount = 0
        /// Each polygon's corners, `polygonCorners[polygonStart[p] ..<
        /// polygonStart[p + 1]]`, and its edges (indices into `edges`) the
        /// same way. Flat, because an array per polygon was two heap blocks
        /// per polygon at every touch-down: 1.28 million of them for 1.28
        /// million triangles.
        var polygonStart: [Int32] = [0]
        var polygonCorners: [Int32] = []
        var polygonEdgeStart: [Int32] = [0]
        var polygonEdgeList: [Int32] = []
        var edges: [SIMD2<Int32>] = []

        func corners(_ p: Int) -> ArraySlice<Int32> {
            p + 1 < polygonStart.count ? polygonCorners[Int(polygonStart[p])..<Int(polygonStart[p + 1])] : []
        }

        func polygonEdges(_ p: Int) -> ArraySlice<Int32> {
            p + 1 < polygonEdgeStart.count
                ? polygonEdgeList[Int(polygonEdgeStart[p])..<Int(polygonEdgeStart[p + 1])] : []
        }

        init(mesh: MeshData, edit: EditTopology?) {
            let triangleCount = mesh.indices.count / 3
            let vertexCount = mesh.vertices.count
            triangles.reserveCapacity(triangleCount)
            for t in 0..<triangleCount {
                triangles.append(SIMD3(Int32(mesh.indices[3 * t]), Int32(mesh.indices[3 * t + 1]),
                                       Int32(mesh.indices[3 * t + 2])))
            }

            // The mesh's edges, found from either end through that vertex's
            // own short list of neighbours rather than by hashing every
            // triangle side: hashing is what cost 460 ms at touch-down for
            // 1.28 million triangles (host, -O). A repeated pair is kept once.
            let pairCount = mesh.edges.count / 2
            func pair(_ e: Int) -> SIMD2<Int32> {
                SIMD2(Int32(mesh.edges[2 * e]), Int32(mesh.edges[2 * e + 1]))
            }
            var adjacencyStart = [Int32](repeating: 0, count: vertexCount + 1)
            for e in 0..<pairCount {
                let p = pair(e)
                guard Int(p.x) < vertexCount, Int(p.y) < vertexCount else { continue }
                adjacencyStart[Int(p.x) + 1] += 1
                adjacencyStart[Int(p.y) + 1] += 1
            }
            for v in 0..<vertexCount { adjacencyStart[v + 1] += adjacencyStart[v] }
            var fill = adjacencyStart
            var neighbour = [Int32](repeating: -1, count: Int(adjacencyStart[vertexCount]))
            var neighbourEdge = [Int32](repeating: -1, count: neighbour.count)
            var skip = [Bool](repeating: false, count: pairCount)
            func find(_ a: Int32, _ b: Int32) -> Int32 {
                guard Int(a) < vertexCount else { return -1 }
                for i in Int(adjacencyStart[Int(a)])..<Int(fill[Int(a)]) where neighbour[i] == b {
                    return neighbourEdge[i]
                }
                return -1
            }
            for e in 0..<pairCount {
                let p = pair(e)
                guard Int(p.x) < vertexCount, Int(p.y) < vertexCount, find(p.x, p.y) < 0 else {
                    skip[e] = true
                    continue
                }
                neighbour[Int(fill[Int(p.x)])] = p.y; neighbourEdge[Int(fill[Int(p.x)])] = Int32(e)
                fill[Int(p.x)] += 1
                neighbour[Int(fill[Int(p.y)])] = p.x; neighbourEdge[Int(fill[Int(p.y)])] = Int32(e)
                fill[Int(p.y)] += 1
            }

            if let edit, edit.trianglePolygons.count == triangleCount {
                trianglePolygon = edit.trianglePolygons.map { Int32($0) }
                polygonCount = max(edit.polygonCount, Int(edit.trianglePolygons.max() ?? 0) + 1)
                if !edit.realEdges.isEmpty {
                    var real = [Bool](repeating: false, count: pairCount)
                    for e in edit.realEdges where e >= 0 && e < pairCount { real[e] = true }
                    for e in 0..<pairCount where !real[e] { skip[e] = true }
                }
            } else {
                var mask = mesh.uvDiagonals
                if mask.count != triangleCount, mesh.cornerLoops.count == mesh.indices.count {
                    mask = UVUnwrap.diagonals(cornerLoops: mesh.cornerLoops)
                }
                // Two triangles across a diagonal are one polygon; the
                // diagonal is left out of the edges.
                var parent = [Int32](0..<Int32(triangleCount))
                func root(_ x: Int32) -> Int32 {
                    var x = x
                    while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
                    return x
                }
                if mask.count == triangleCount {
                    var across = [Int32](repeating: -1, count: pairCount)
                    for t in 0..<triangleCount where mask[t] != 0 {
                        for k in 0..<3 where mask[t] & (1 << k) != 0 {
                            let e = Int(find(triangles[t][k], triangles[t][(k + 1) % 3]))
                            guard e >= 0 else { continue }
                            skip[e] = true
                            if across[e] < 0 {
                                across[e] = Int32(t)
                            } else {
                                let a = root(Int32(t)), b = root(across[e])
                                if a != b { parent[Int(a)] = b }
                            }
                        }
                    }
                }
                var number = [Int32](repeating: -1, count: triangleCount)
                trianglePolygon = [Int32](repeating: 0, count: triangleCount)
                for t in 0..<triangleCount {
                    let r = Int(root(Int32(t)))
                    if number[r] < 0 { number[r] = Int32(polygonCount); polygonCount += 1 }
                    trianglePolygon[t] = number[r]
                }
            }

            var remap = [Int32](repeating: -1, count: pairCount)
            for e in 0..<pairCount where !skip[e] {
                remap[e] = Int32(edges.count)
                edges.append(pair(e))
            }

            // Each polygon's triangles, in order (a counting sort), then its
            // corners and its edges in the order its triangles name them.
            var triangleStart = [Int32](repeating: 0, count: polygonCount + 1)
            for t in 0..<triangleCount where Int(trianglePolygon[t]) < polygonCount {
                triangleStart[Int(trianglePolygon[t]) + 1] += 1
            }
            for p in 0..<polygonCount { triangleStart[p + 1] += triangleStart[p] }
            var next = triangleStart
            var order = [Int32](repeating: 0, count: Int(triangleStart[polygonCount]))
            for t in 0..<triangleCount where Int(trianglePolygon[t]) < polygonCount {
                let p = Int(trianglePolygon[t])
                order[Int(next[p])] = Int32(t)
                next[p] += 1
            }
            polygonStart.reserveCapacity(polygonCount + 1)
            polygonEdgeStart.reserveCapacity(polygonCount + 1)
            polygonCorners.reserveCapacity(triangleCount + 2 * polygonCount)
            polygonEdgeList.reserveCapacity(triangleCount + 2 * polygonCount)
            for p in 0..<polygonCount {
                let firstCorner = polygonCorners.count, firstEdge = polygonEdgeList.count
                for i in Int(triangleStart[p])..<Int(triangleStart[p + 1]) {
                    let tri = triangles[Int(order[i])]
                    for k in 0..<3 {
                        if !polygonCorners[firstCorner...].contains(tri[k]) { polygonCorners.append(tri[k]) }
                        let e = find(tri[k], tri[(k + 1) % 3])
                        if e >= 0, remap[Int(e)] >= 0, !polygonEdgeList[firstEdge...].contains(remap[Int(e)]) {
                            polygonEdgeList.append(remap[Int(e)])
                        }
                    }
                }
                polygonStart.append(Int32(polygonCorners.count))
                polygonEdgeStart.append(Int32(polygonEdgeList.count))
            }
        }
    }

    // MARK: - The search

    /// One search, for one pointer position: `snap_object_project_view3d_ex`.
    struct Search {
        let targets: Targets
        let pointer: SIMD2<Float>
        let ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)

        /// The nearest element so far, and the edge it is on (a point's is
        /// the point twice).
        var best: (hit: Hit, a: SIMD3<Float>, b: SIMD3<Float>)?
        var bestDistance: Float
        /// The occlusion plane, facing the eye: a point counts only while
        /// `dot(n, p) + d > 0`.
        var plane: SIMD4<Float>?

        init(targets: Targets, pointer: SIMD2<Float>, ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) {
            self.targets = targets
            self.pointer = pointer
            self.ray = ray
            self.bestDistance = targets.radius * targets.radius
        }

        mutating func run() -> Hit? {
            let elements = targets.elements
            // Blender casts the ray for Face, and for the occlusion plane.
            let face = targets.occlusion || elements.contains(.face) ? raycast() : nil
            var result: Hit?
            if elements.contains(.face), let face {
                result = Hit(kind: .face, location: face.location, direction: face.normal)
            }
            let useEdges = elements.contains(.edge) || elements.contains(.edgeMidpoint)
            let useVertices = elements.contains(.vertex)
            let useCentres = elements.contains(.faceMidpoint)
            guard useEdges || useVertices || useCentres else { return result }

            if targets.occlusion, let face {
                // The polygon hit first, before the plane through it goes up:
                // part of it can lie behind its own plane (`snap_polygon`).
                // Its edges when an edge element is chosen, and otherwise its
                // corners, as SCE_SNAP_TO_EDGE_ENDPOINT, whatever was chosen
                // (`snap_polygon_mesh`) — with Face Center alone as well. A
                // corner found that way blocks every centre farther away, and
                // when nothing nearer beats it the whole search comes back
                // empty (the end of `run`).
                let body = targets.bodies[face.body]
                let polygon = Int(body.trianglePolygon[face.triangle])
                if useEdges {
                    for e in body.topology.polygonEdges(polygon) where body.edgeIndex[Int(e)] >= 0 {
                        testEdge(body, Int(body.edgeIndex[Int(e)]), clipped: false)
                    }
                } else {
                    for v in body.topology.corners(polygon) {
                        testPoint(body.world[Int(v)], body.screen[Int(v)], .vertex, clipped: false)
                    }
                }
                var n = face.normal
                if simd_dot(ray.direction, n) > 0 { n = -n }
                // occlusion_plane_create: a little in front of the surface, so
                // its own vertices and edges are not cut away with it.
                let depth = simd_dot(face.location - ray.origin, ray.direction)
                plane = SIMD4(n, -simd_dot(n, face.location) + max(depth * 1e-5, .ulpOfOne))
            }

            for body in targets.bodies {
                guard reachable(body) else { continue }
                if useVertices {
                    for v in body.loose {
                        testPoint(body.world[Int(v)], body.screen[Int(v)], .point, clipped: body.occludable)
                    }
                }
                if useCentres {
                    for p in body.candidatePolygons {
                        testPoint(body.polygonCentres[Int(p)], body.polygonScreen[Int(p)], .faceMidpoint)
                    }
                }
                if useEdges {
                    for e in body.edges.indices { testEdge(body, e) }
                } else if useVertices {
                    for v in body.vertices { testPoint(body.world[Int(v)], body.screen[Int(v)], .vertex) }
                }
            }

            guard var found = best else { return result }
            if found.hit.kind == .edge,
               elements.contains(.vertex) || elements.contains(.edgeMidpoint) {
                found.hit = edgePoints(found.hit, found.a, found.b)
            }
            if elements.contains(found.hit.kind.element) { return found.hit }
            // An edge found only on the way to a vertex or a centre that was
            // not there: Blender restores what it had before (`ret_bak`), so
            // the face under the pointer stands, if it was asked for.
            if found.hit.kind == .edge { return result }
            // A corner of the polygon under the pointer, tried for Face Center:
            // `retval = elem & snap_to_flag` is empty, which drops the face
            // too (snap_object_project_view3d_ex).
            return nil
        }

        /// Whether anything of `body` can still beat the best so far.
        private func reachable(_ body: Body) -> Bool {
            let r = bestDistance.squareRoot()
            return pointer.x >= body.screenLo.x - r && pointer.x <= body.screenHi.x + r
                && pointer.y >= body.screenLo.y - r && pointer.y <= body.screenHi.y + r
        }

        private func visible(_ p: SIMD3<Float>) -> Bool {
            guard let plane else { return true }
            return simd_dot(plane.xyz, p) + plane.w > 0
        }

        /// `clipped` is false only for the polygon under the pointer, which is
        /// tried before the occlusion plane exists.
        private mutating func testPoint(_ p: SIMD3<Float>, _ s: SIMD2<Float>, _ kind: Kind,
                                        clipped: Bool = true) {
            guard s.x.isFinite else { return }
            let d = simd_distance_squared(s, pointer)
            guard d < bestDistance, !clipped || visible(p) else { return }
            bestDistance = d
            best = (Hit(kind: kind, location: p), p, p)
        }

        /// `test_projected_edge_dist`: the point of the edge nearest the
        /// pointer's ray, measured on screen.
        private mutating func testEdge(_ body: Body, _ e: Int, clipped: Bool = true) {
            let edge = body.edges[e]
            let sa = body.screen[Int(edge.x)], sb = body.screen[Int(edge.y)]
            guard sa.x.isFinite, sb.x.isFinite else { return }
            // The nearest point projects onto the drawn segment, so the drawn
            // segment's distance is never more than its own: a cheap refusal.
            let floor = MeshPicker.distanceToSegment(pointer, sa, sb)
            guard floor * floor < bestDistance else { return }
            let a = body.world[Int(edge.x)], b = body.world[Int(edge.y)]
            let near = GeometrySnap.closestOnSegment(to: ray, a, b)
            guard let s = targets.view.project(near) else { return }
            let d = simd_distance_squared(s, pointer)
            guard d < bestDistance, !clipped || visible(near) else { return }
            bestDistance = d
            best = (Hit(kind: .edge, location: near, direction: body.edgeDirection(a, b)), a, b)
        }

        /// `snap_edge_points_impl`: the edge's end or middle instead, when the
        /// ray passes near enough to it along the edge and it is itself within
        /// the radius. The zones split the edge by how many of Edge, Vertex and
        /// Edge Center are chosen, exactly as Blender splits it — with all
        /// three the middle fifth goes to the centre and the rest to the ends.
        private func edgePoints(_ hit: Hit, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Hit {
            guard let lambda = GeometrySnap.rayLineFactor(ray, a, b) else { return hit }
            let elements = targets.elements
            let modes = [SnapElement.edge, .vertex, .edgeMidpoint].filter(elements.contains).count
            var range = 1 / Float(2 * modes - 1)
            var out = hit
            var limit = targets.radius * targets.radius
            if elements.contains(.edgeMidpoint) {
                range *= Float(modes - 1)
                if range < lambda && lambda < 1 - range {
                    let middle = (a + b) * 0.5
                    if let s = targets.view.project(middle), simd_distance_squared(s, pointer) < limit {
                        limit = simd_distance_squared(s, pointer)
                        out = Hit(kind: .edgeMidpoint, location: middle, direction: hit.direction)
                    }
                }
            }
            if elements.contains(.vertex), lambda < range || 1 - range < lambda {
                let end = lambda < 0.5 ? a : b
                if let s = targets.view.project(end), simd_distance_squared(s, pointer) < limit {
                    out = Hit(kind: .vertex, location: end)
                }
            }
            return out
        }

        /// The nearest candidate triangle under the pointer, two-sided, as
        /// Blender's ray cast with backface culling off (its default).
        private func raycast() -> (body: Int, triangle: Int, location: SIMD3<Float>, normal: SIMD3<Float>)? {
            var nearest: (body: Int, triangle: Int, t: Float)?
            for (b, body) in targets.bodies.enumerated() where !body.triangles.isEmpty {
                guard let entry = GeometrySnap.rayBox(ray, body.lo, body.hi),
                      nearest == nil || entry < nearest!.t else { continue }
                for (t, tri) in body.triangles.enumerated() {
                    guard let d = MeshPicker.rayTriangle(ray.origin, ray.direction, body.world[Int(tri.x)],
                                                         body.world[Int(tri.y)], body.world[Int(tri.z)]),
                          d > 0, nearest == nil || d < nearest!.t else { continue }
                    nearest = (b, t, d)
                }
            }
            guard let nearest else { return nil }
            let body = targets.bodies[nearest.body], tri = body.triangles[nearest.triangle]
            let a = body.world[Int(tri.x)]
            let n = simd_cross(body.world[Int(tri.y)] - a, body.world[Int(tri.z)] - a)
            return (nearest.body, nearest.triangle, ray.origin + ray.direction * nearest.t, normalizeOrZero(n))
        }
    }

    // MARK: - Where the Snap With point goes

    /// Snap With Closest: the candidate nearest the target, first on a tie
    /// (`snap_source_closest_fn`, squared distance in 3D).
    public static func closest(_ sources: [SIMD3<Float>], to target: SIMD3<Float>) -> SIMD3<Float>? {
        var best: (p: SIMD3<Float>, d: Float)?
        for p in sources {
            let d = simd_distance_squared(p, target)
            if best == nil || d < best!.d { best = (p, d) }
        }
        return best?.p
    }

    /// The 8 corners of an object's bounding box in world space: what Closest
    /// measures from in object mode (`BKE_object_boundbox_eval_cached_get`
    /// through the object's matrix). The mirror's mesh is the evaluated one,
    /// so its bounds are Blender's; an object with no vertices has its origin.
    public static func boxCorners(_ object: BKObject) -> [SIMD3<Float>] {
        let m = object.modelMatrix
        guard let first = object.mesh.vertices.first?.position else { return [m.columns.3.xyz] }
        var lo = first, hi = first
        for v in object.mesh.vertices { lo = simd_min(lo, v.position); hi = simd_max(hi, v.position) }
        return (0..<8).map { i in
            let local = SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            return (m * SIMD4(local, 1)).xyz
        }
    }

    /// The constraint a drag is under, in the handle's terms: an axis, a plane
    /// named for its normal, or none.
    public enum Constraint: Equatable, Sendable {
        case axis(SIMD3<Float>)
        case plane(normal: SIMD3<Float>)
        case free
    }

    /// The move that takes `source` to the target under the drag's
    /// constraint: `transform_constraint_get_nearest`.
    ///
    /// A point target is projected onto the constraint. An Edge is met where
    /// the axis passes nearest it, or where it crosses the plane; a Face where
    /// the axis crosses its plane. A plane constraint projects a Face, since
    /// Blender's face variant is disabled (#82386). Each falls back to the
    /// projection when the two are parallel within `CONSTRAIN_EPSILON`.
    public static func move(_ source: SIMD3<Float>, to hit: Hit, constraint: Constraint) -> SIMD3<Float> {
        let v = hit.location - source
        let epsilon: Float = 0.0001
        switch constraint {
        case .free:
            return v
        case .axis(let axis):
            let projected = axis * simd_dot(v, axis)
            switch hit.kind {
            case .edge:
                let e = hit.direction
                guard abs(simd_dot(axis, e)) <= 1 - epsilon,
                      let lambda = rayRayFactor(source, axis, hit.location, e) else { return projected }
                return axis * lambda
            case .face:
                let n = hit.direction
                let facing = simd_dot(n, axis)
                guard abs(facing) >= epsilon else { return projected }
                return axis * (-simd_dot(n, source - hit.location) / facing)
            default:
                return projected
            }
        case .plane(let normal):
            let projected = v - normal * simd_dot(v, normal)
            guard hit.kind == .edge, projected != .zero else { return projected }
            let e = hit.direction
            let crossing = simd_dot(normal, e)
            guard abs(crossing) >= epsilon else { return projected }
            let lambda = -simd_dot(normal, hit.location - source) / crossing
            return hit.location + e * lambda - source
        }
    }

    // MARK: - Geometry, as Blender's math_geom does it

    /// `closest_ray_to_segment_v3`.
    static func closestOnSegment(to ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                 _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        guard let lambda = rayLineFactor(ray, a, b) else { return a }
        if lambda <= 0 { return a }
        if lambda >= 1 { return b }
        return a + (b - a) * lambda
    }

    /// `isect_ray_line_v3`: where along a → b the line passes nearest the ray,
    /// as a fraction of a → b; nil when they are parallel.
    static func rayLineFactor(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                              _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float? {
        let edge = b - a
        let n = simd_cross(edge, ray.direction)
        let length = simd_length_squared(n)
        guard length > 0 else { return nil }
        let c = n - (a - ray.origin)
        return simd_dot(simd_cross(c, ray.direction), n) / length
    }

    /// `isect_ray_ray_v3`: how far along `da` from `oa` the two lines come
    /// closest; nil when they are parallel.
    static func rayRayFactor(_ oa: SIMD3<Float>, _ da: SIMD3<Float>,
                             _ ob: SIMD3<Float>, _ db: SIMD3<Float>) -> Float? {
        let n = simd_cross(da, db)
        let length = simd_length_squared(n)
        guard length > .leastNormalMagnitude else { return nil }
        return simd_dot(simd_cross(ob - oa, db), n) / length
    }

    /// The ray's entry into a box, or nil when it misses.
    static func rayBox(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                       _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Float? {
        guard lo.x <= hi.x else { return nil }
        var near = -Float.greatestFiniteMagnitude, far = Float.greatestFiniteMagnitude
        for k in 0..<3 {
            let o = ray.origin[k], d = ray.direction[k]
            // Padded: a flat mesh has a box of no depth, and a ray along its
            // face must still reach it.
            let l = lo[k] - 1e-4, h = hi[k] + 1e-4
            if abs(d) < 1e-12 {
                if o < l || o > h { return nil }
                continue
            }
            var t0 = (l - o) / d, t1 = (h - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            near = max(near, t0); far = min(far, t1)
            if near > far { return nil }
        }
        return far < 0 ? nil : max(near, 0)
    }
}

private func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = simd_length(v)
    return l > 0 ? v / l : .zero
}
