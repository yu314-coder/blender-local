import Foundation
import simd

/// Choosing the mesh element a tap means, in edit mode.
///
/// This used to live in the renderer and measured distance in clip space: a
/// vertex counted as hit within 0.05 of the tap in NDC. NDC is -1…1 across the
/// whole view whichever way round it is, so on a 1193 × 729 point viewport that
/// tolerance was 30 points across and 18 points up — under half a fingertip,
/// and a different size in each direction. Most taps therefore hit nothing, and
/// a tap that hits nothing is a Set click on empty space, which *clears* the
/// selection. Tapping a vertex usually deselected everything instead.
///
/// So the measuring is done in points here, the radius is a finger rather than
/// a pixel, and three more things follow Blender rather than the arithmetic
/// that happened to be easy:
///
///   * elements the surface hides are not candidates. The viewport draws vertex
///     dots with the depth test on, so a dot behind the model is not on screen;
///     picking one meant the tap selected something invisible on the far side.
///   * an edge is picked by its distance to the *line*, not by finding the
///     nearest vertex and then taking the first edge in the list that touched
///     it. Tapping the middle of an edge picked nothing at all before.
///   * a face is every triangle of its polygon. The viewport draws triangles
///     and Blender edits polygons, so picking one triangle lit up half a quad.
///
/// And one thing Blender does not do, because a finger is not a mouse: a tap
/// that lands on the model but near nothing in particular falls back to the
/// nearest element of the face it hit. Tapping a cube's face in vertex mode
/// selects that face's nearest corner rather than throwing the selection away.
/// Empty space still clears it, which is the gesture Blender gives that meaning.
public enum MeshPicker {

    /// What a tap picked. `faces` is viewport triangles — every triangle of the
    /// polygon that was hit — because that is what the viewport draws and what
    /// `EditSelection` stores.
    public struct Hit: Equatable, Sendable {
        public var faces: Set<Int> = []
        public var vertex: Int?
        public var edge: Int?

        public init(faces: Set<Int> = [], vertex: Int? = nil, edge: Int? = nil) {
            self.faces = faces
            self.vertex = vertex
            self.edge = edge
        }

        /// Nothing was picked: the tap was on empty space.
        public var isEmpty: Bool { faces.isEmpty && vertex == nil && edge == nil }
    }

    /// How far from a vertex or an edge a tap still counts, in points.
    ///
    /// A fingertip is about 44 points across, so half of one is the most that
    /// can be claimed without a tap on one corner of a small cube reaching the
    /// next. Nothing is picked beyond it unless the tap landed on the surface,
    /// and then the face decides.
    public static let touchRadius: Float = 22

    /// The element a tap at `ndc` means.
    ///
    /// - Parameters:
    ///   - viewProjection: the matrix that takes a *local* vertex to clip
    ///     space — the camera's, already multiplied by the object's.
    ///   - eye: the camera position in the object's local space, for deciding
    ///     which way a triangle faces. An orthographic view has no such point,
    ///     so pass `viewDirection` instead and every triangle is judged against
    ///     the one direction the whole view looks.
    ///   - ray: the tap's ray, also in local space.
    ///   - viewSize: the viewport in points, which is what makes the radius a
    ///     distance a finger can aim at rather than a fraction of the screen.
    public static func pick(mesh: MeshData, topology: EditTopology?,
                            mode: MeshSelectMode,
                            ndc: SIMD2<Float>, viewSize: SIMD2<Float>,
                            viewProjection: simd_float4x4,
                            eye: SIMD3<Float>, viewDirection: SIMD3<Float>? = nil,
                            ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                            radius: Float = touchRadius) -> Hit {
        guard !mesh.vertices.isEmpty, viewSize.x > 0, viewSize.y > 0 else { return Hit() }
        // Indices the mirror read off a mesh that has changed since name other
        // elements now, so an out-of-date report is no report.
        let topology = topology.flatMap { $0.describes(mesh) ? $0 : nil }

        // Points, not NDC: half the view is half its width in points one way
        // and half its height the other.
        let half = viewSize / 2
        func onScreen(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let clip = viewProjection * SIMD4(p, 1)
            guard clip.w > 0 else { return nil }
            return SIMD2(clip.x / clip.w, clip.y / clip.w) * half
        }
        let tap = ndc * half

        let screen = mesh.vertices.map { onScreen($0.position) }
        let visible = visibleVertices(mesh: mesh, eye: eye, viewDirection: viewDirection)
        let triangle = nearestTriangle(mesh: mesh, ray: ray)

        switch mode {
        case .face:
            guard let triangle else { return Hit() }
            return Hit(faces: polygon(of: triangle, topology: topology, mesh: mesh))

        case .vertex:
            // A vertex Blender has hidden has no dot to aim at. Its faces are
            // not drawn either, so the fallback below never reaches one.
            let hidden = topology?.hiddenVertices ?? []
            let candidates = hidden.isEmpty ? Array(mesh.vertices.indices)
                : mesh.vertices.indices.filter { !hidden.contains($0) }
            if let v = nearestVertex(candidates, screen: screen, visible: visible,
                                     to: tap, within: radius) {
                return Hit(vertex: v)
            }
            // On the model but not near a corner: its nearest corner, rather
            // than the empty hit that would clear the selection.
            guard let triangle else { return Hit() }
            let corners = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            return Hit(vertex: nearestVertex(corners, screen: screen, visible: nil,
                                             to: tap, within: .infinity))

        case .edge:
            let candidates = pickableEdges(mesh: mesh, topology: topology)
            if let e = nearestEdge(candidates, mesh: mesh, screen: screen, visible: visible,
                                   to: tap, within: radius) {
                return Hit(edge: e)
            }
            guard let triangle else { return Hit() }
            let corners = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            let sides = candidates.filter { e in
                corners.contains(Int(mesh.edges[e * 2])) && corners.contains(Int(mesh.edges[e * 2 + 1]))
            }
            return Hit(edge: nearestEdge(sides, mesh: mesh, screen: screen, visible: nil,
                                         to: tap, within: .infinity))
        }
    }

    // MARK: the pieces

    /// The vertices the surface does not hide.
    ///
    /// A vertex is on screen when at least one triangle meeting it faces the
    /// camera. That is exact for a solid like a cube — the one corner at the
    /// back has all three of its triangles facing away — and close enough
    /// elsewhere that it beats picking through the model. A mesh with no
    /// triangles at all (loose vertices) has nothing to hide behind, so every
    /// vertex counts.
    static func visibleVertices(mesh: MeshData, eye: SIMD3<Float>,
                                viewDirection: SIMD3<Float>? = nil) -> [Bool]? {
        guard mesh.indices.count >= 3 else { return nil }
        var front = [Bool](repeating: false, count: mesh.vertices.count)
        var any = false
        var i = 0
        while i + 2 < mesh.indices.count {
            let ia = Int(mesh.indices[i]), ib = Int(mesh.indices[i + 1]), ic = Int(mesh.indices[i + 2])
            let a = mesh.vertices[ia].position
            let normal = cross(mesh.vertices[ib].position - a, mesh.vertices[ic].position - a)
            // Towards the eye, or — with no eye to be towards — against the
            // one direction an orthographic view looks.
            let towards = viewDirection.map { -$0 } ?? (eye - a)
            if dot(normal, towards) > 0 {
                front[ia] = true; front[ib] = true; front[ic] = true
                any = true
            }
            i += 3
        }
        // Nothing faces us — a plane seen from behind. Rather than refuse every
        // tap, pick as if the mesh were see-through.
        return any ? front : nil
    }

    /// The nearest triangle the tap's ray meets, as a triangle index.
    static func nearestTriangle(mesh: MeshData,
                                ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> Int? {
        var best: (triangle: Int, t: Float)?
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])].position
            let b = mesh.vertices[Int(mesh.indices[i + 1])].position
            let c = mesh.vertices[Int(mesh.indices[i + 2])].position
            if let t = rayTriangle(ray.origin, ray.direction, a, b, c), t > 0,
               best == nil || t < best!.t {
                best = (i / 3, t)
            }
            i += 3
        }
        return best?.triangle
    }

    /// Every viewport triangle of the polygon a triangle belongs to.
    static func polygon(of triangle: Int, topology: EditTopology?, mesh: MeshData) -> Set<Int> {
        let triangles = mesh.indices.count / 3
        guard let topology, topology.trianglePolygons.count == triangles,
              triangle < triangles else { return [triangle] }
        let p = topology.trianglePolygons[triangle]
        return Set(topology.trianglePolygons.indices.filter { topology.trianglePolygons[$0] == p })
    }

    /// The viewport edges a tap may choose.
    ///
    /// The viewport's edge list is built from triangles, so a quad contributes
    /// a diagonal Blender has no edge for — selecting one sends Blender an edge
    /// it cannot find, and nothing happens. When the mirror has told us which
    /// of them are Blender's, only those are offered.
    static func pickableEdges(mesh: MeshData, topology: EditTopology?) -> [Int] {
        let all = Array(0..<(mesh.edges.count / 2))
        guard let real = topology?.realEdges, !real.isEmpty else { return all }
        return all.filter { real.contains($0) }
    }

    static func nearestVertex<S: Sequence<Int>>(_ candidates: S, screen: [SIMD2<Float>?],
                                                visible: [Bool]?, to tap: SIMD2<Float>,
                                                within radius: Float) -> Int? {
        var best: (index: Int, d: Float)?
        for i in candidates {
            guard i < screen.count, let s = screen[i] else { continue }
            if let visible, i < visible.count, !visible[i] { continue }
            let d = distance(s, tap)
            guard d <= radius, best == nil || d < best!.d else { continue }
            best = (i, d)
        }
        return best?.index
    }

    static func nearestEdge<S: Sequence<Int>>(_ candidates: S, mesh: MeshData,
                                              screen: [SIMD2<Float>?], visible: [Bool]?,
                                              to tap: SIMD2<Float>, within radius: Float) -> Int? {
        var best: (index: Int, d: Float)?
        for e in candidates {
            let base = e * 2
            guard base + 1 < mesh.edges.count else { continue }
            let ia = Int(mesh.edges[base]), ib = Int(mesh.edges[base + 1])
            guard ia < screen.count, ib < screen.count,
                  let a = screen[ia], let b = screen[ib] else { continue }
            // An edge with a hidden end runs into the model: on a solid it is
            // the far side of the silhouette, which is not on screen either.
            if let visible, ia < visible.count, ib < visible.count,
               !(visible[ia] && visible[ib]) { continue }
            let d = distanceToSegment(tap, a, b)
            guard d <= radius, best == nil || d < best!.d else { continue }
            best = (e, d)
        }
        return best?.index
    }

    /// How far a point is from a line segment — the whole edge, not its ends.
    static func distanceToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>,
                                  _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let length = length_squared(ab)
        guard length > 1e-9 else { return distance(p, a) }
        let t = min(max(dot(p - a, ab) / length, 0), 1)
        return distance(p, a + ab * t)
    }

    /// Möller–Trumbore, two-sided so a back face still registers a hit.
    static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>,
                            _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = cross(d, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-7 else { return nil }
        let invDet = 1 / det
        let t0 = o - a
        let u = dot(t0, p) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let q = cross(t0, e1)
        let v = dot(d, q) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        return dot(e2, q) * invDet
    }
}
