import Foundation
import simd

/// Blender's interaction modes. Object mode moves whole objects; edit mode
/// works on the mesh itself.
public enum InteractionMode: String, CaseIterable, Identifiable, Sendable {
    case object, edit, sculpt, vertexPaint, weightPaint, texturePaint

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .object:       return "Object Mode"
        case .edit:         return "Edit Mode"
        case .sculpt:       return "Sculpt Mode"
        case .vertexPaint:  return "Vertex Paint"
        case .weightPaint:  return "Weight Paint"
        case .texturePaint: return "Texture Paint"
        }
    }

    public var icon: String {
        switch self {
        case .object:       return "cube"
        case .edit:         return "point.3.connected.trianglepath.dotted"
        case .sculpt:       return "hand.draw"
        case .vertexPaint:  return "paintbrush.pointed"
        case .weightPaint:  return "scalemass"
        case .texturePaint: return "paintbrush"
        }
    }

    public var isImplemented: Bool { true }

    /// The string `bpy.ops.object.mode_set(mode=…)` expects.
    public var bpyMode: String {
        switch self {
        case .object:       return "OBJECT"
        case .edit:         return "EDIT"
        case .sculpt:       return "SCULPT"
        case .vertexPaint:  return "VERTEX_PAINT"
        case .weightPaint:  return "WEIGHT_PAINT"
        case .texturePaint: return "TEXTURE_PAINT"
        }
    }

    /// Why a mode is unavailable, shown in the dropdown.
    public var requirement: String { "" }
}

/// Blender's mesh select modes — the three buttons in the edit-mode header.
public enum MeshSelectMode: String, CaseIterable, Identifiable, Sendable {
    case vertex, edge, face
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    public var icon: String {
        switch self {
        case .vertex: return "circle.grid.3x3"
        case .edge:   return "line.diagonal"
        case .face:   return "square.split.diagonal.2x2"
        }
    }

    /// Blender binds these to 1, 2 and 3 in edit mode.
    public var shortcut: String {
        switch self {
        case .vertex: return "1"
        case .edge:   return "2"
        case .face:   return "3"
        }
    }
}

/// What is selected inside a mesh while editing.
///
/// Blender keeps selection on the mesh elements themselves; here it is a set of
/// indices per element type, which is enough for the operators below and keeps
/// MeshData a plain value type.
public struct EditSelection: Sendable {
    public var vertices: Set<Int> = []
    /// Index of the edge pair in `MeshData.edges`, so edge *n* is
    /// `edges[2n], edges[2n+1]`.
    public var edges: Set<Int> = []
    /// Triangle index, so face *n* is `indices[3n ..< 3n+3]`.
    public var faces: Set<Int> = []

    public var isEmpty: Bool { vertices.isEmpty && edges.isEmpty && faces.isEmpty }

    public mutating func clear() {
        vertices.removeAll(); edges.removeAll(); faces.removeAll()
    }
}

/// The mesh-editing operators from Blender's Mesh menu.
///
/// These work on the triangulated `MeshData` the app already carries. Blender
/// uses a BMesh half-edge structure, which is what lets it do loop cuts, knife
/// and proper n-gon bevels; those are absent here for exactly that reason.
public enum MeshEditor {

    /// `bpy.ops.mesh.extrude_region_and_move` — duplicates the selected faces,
    /// pushes them along their averaged normal, and walls the gap.
    public static func extrude(_ mesh: MeshData, faces: Set<Int>,
                               distance: Float) -> (MeshData, Set<Int>) {
        guard !faces.isEmpty else { return (mesh, faces) }
        var verts = mesh.vertices
        var indices = mesh.indices
        var newFaces: Set<Int> = []

        for face in faces.sorted() {
            let base = face * 3
            guard base + 2 < mesh.indices.count else { continue }
            let corner = (0..<3).map { Int(mesh.indices[base + $0]) }
            let p = corner.map { mesh.vertices[$0].position }
            let normal = normalize(cross(p[1] - p[0], p[2] - p[0]))

            // The moved copy of the face.
            guard verts.count + 3 <= Int(UInt32.max) else { break }
            let top = (0..<3).map { i -> UInt32 in
                verts.append(MeshVertex(p[i] + normal * distance, normal))
                return UInt32(verts.count - 1)
            }
            newFaces.insert(indices.count / 3)
            indices += [top[0], top[1], top[2]]

            // Side walls: one quad per original edge, as two triangles.
            for i in 0..<3 {
                let j = (i + 1) % 3
                let a = UInt32(corner[i]), b = UInt32(corner[j])
                indices += [a, b, top[j], a, top[j], top[i]]
            }
        }

        var result = MeshData(vertices: verts, indices: indices)
        ModifierStack.recomputeNormals(&result, welded: false)
        return (result, newFaces)
    }

    /// `bpy.ops.mesh.subdivide` — splits each selected triangle into four.
    public static func subdivide(_ mesh: MeshData, faces: Set<Int>) -> (MeshData, Set<Int>) {
        guard !faces.isEmpty else { return (mesh, faces) }
        var verts = mesh.vertices
        var indices: [UInt32] = []
        var midpoints: [UInt64: UInt32] = [:]
        var newFaces: Set<Int> = []

        func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let hit = midpoints[key] { return hit }
            guard verts.count < Int(UInt32.max) else { return a }
            let va = verts[Int(a)], vb = verts[Int(b)]
            verts.append(MeshVertex((va.position + vb.position) * 0.5,
                                    normalize(va.normal + vb.normal)))
            let index = UInt32(verts.count - 1)
            midpoints[key] = index
            return index
        }

        for face in 0..<(mesh.indices.count / 3) {
            let base = face * 3
            let a = mesh.indices[base], b = mesh.indices[base + 1], c = mesh.indices[base + 2]
            if faces.contains(face) {
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                for tri in [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]] {
                    newFaces.insert(indices.count / 3)
                    indices += tri
                }
            } else {
                indices += [a, b, c]
            }
        }
        return (MeshData(vertices: verts, indices: indices), newFaces)
    }

    /// `bpy.ops.mesh.inset_faces` — shrinks each selected face toward its
    /// centre and rings it with the offcut.
    public static func inset(_ mesh: MeshData, faces: Set<Int>,
                             thickness: Float) -> (MeshData, Set<Int>) {
        guard !faces.isEmpty else { return (mesh, faces) }
        var verts = mesh.vertices
        var indices: [UInt32] = []
        var newFaces: Set<Int> = []

        for face in 0..<(mesh.indices.count / 3) {
            let base = face * 3
            let corner = (0..<3).map { mesh.indices[base + $0] }
            guard faces.contains(face), verts.count + 3 <= Int(UInt32.max) else {
                indices += corner
                continue
            }
            let p = corner.map { mesh.vertices[Int($0)].position }
            let centre = (p[0] + p[1] + p[2]) / 3
            let n = mesh.vertices[Int(corner[0])].normal

            let inner = (0..<3).map { i -> UInt32 in
                verts.append(MeshVertex(mix(p[i], centre, t: thickness), n))
                return UInt32(verts.count - 1)
            }
            newFaces.insert(indices.count / 3)
            indices += [inner[0], inner[1], inner[2]]
            // The ring between the original edge and the inset one.
            for i in 0..<3 {
                let j = (i + 1) % 3
                indices += [corner[i], corner[j], inner[j],
                            corner[i], inner[j], inner[i]]
            }
        }
        return (MeshData(vertices: verts, indices: indices), newFaces)
    }

    /// `bpy.ops.mesh.delete(type='FACE')`.
    public static func deleteFaces(_ mesh: MeshData, faces: Set<Int>) -> MeshData {
        guard !faces.isEmpty else { return mesh }
        var indices: [UInt32] = []
        for face in 0..<(mesh.indices.count / 3) where !faces.contains(face) {
            let base = face * 3
            indices += [mesh.indices[base], mesh.indices[base + 1], mesh.indices[base + 2]]
        }
        return MeshData(vertices: mesh.vertices, indices: indices)
    }

    /// `bpy.ops.transform.translate` in edit mode: moves the selected vertices.
    ///
    /// With `proportional` set, unselected vertices within `radius` come along
    /// too, weighted by the falloff curve — Blender's O key. The weight is
    /// measured from the *nearest selected vertex*, not from the median, which
    /// is what lets a proportional drag follow the shape of a selection rather
    /// than bulging around its centre. The weighting is TransformOperation's,
    /// the one the gizmo previews with.
    public static func move(_ mesh: MeshData, vertices: Set<Int>,
                            by delta: SIMD3<Float>,
                            proportional: ProportionalFalloff? = nil,
                            radius: Float = 1) -> MeshData {
        guard !vertices.isEmpty else { return mesh }
        let edit = proportional.map { ProportionalEdit(falloff: $0, size: radius) }
        let positions = mesh.vertices.map(\.position)
        let factors = TransformOperation.vertexFactors(positions: positions, selected: vertices,
                                                       model: matrix_identity_float4x4,
                                                       proportional: edit, connectivity: nil)
        let operation = TransformOperation(kind: .translate(delta), pivot: .boundsCentre,
                                           proportional: edit)
        let moved = operation.apply(toVertices: positions, factors: factors,
                                    selected: vertices, model: matrix_identity_float4x4)
        var result = mesh
        for i in result.vertices.indices { result.vertices[i].position = moved[i] }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// Blender's proportional-editing falloff curves, in its own menu order.
    ///
    /// These live beside the operator that uses them rather than in the
    /// viewport's options, so the maths can be tested without a view.
    public enum ProportionalFalloff: String, CaseIterable, Identifiable, Codable, Sendable {
        case smooth, sphere, root, inverseSquare, sharp, linear, constant, random

        public var id: String { rawValue }
        public var label: String {
            self == .inverseSquare ? "Inverse Square" : rawValue.capitalized
        }

        /// Weight for a normalised distance in 0…1: 1 at the selection, 0 at
        /// the edge of the radius. Blender's curves (`curve`, in
        /// TransformEvaluation.swift), which run on 1 − t.
        ///
        /// Root used to be 1 − √t here where Blender's is √(1 − t): at half the
        /// radius that is 0.29 against Blender's 0.71, so a Root drag previewed
        /// well under half of what the commit then moved.
        public func weight(_ t: Float) -> Float {
            curve(1 - max(0, min(1, t)), random: Float.random(in: 0..<1))
        }
    }

    // MARK: - Vertex menu  (VIEW3D_MT_edit_mesh_vertices)

    /// `bpy.ops.mesh.remove_doubles` — welds vertices closer than `threshold`.
    ///
    /// Blender calls this Merge by Distance. It is the one cleanup operation
    /// that matters most on a triangulated mesh, because every operation that
    /// duplicates geometry leaves coincident vertices behind.
    public static func mergeByDistance(_ mesh: MeshData, vertices selection: Set<Int>,
                                       threshold: Float = 0.0001) -> (MeshData, Int) {
        let scope = selection.isEmpty ? Set(mesh.vertices.indices) : selection
        guard !scope.isEmpty else { return (mesh, 0) }

        // Quantising to a grid is O(n) where comparing every pair is O(n²), and
        // at these thresholds the two agree.
        let step = max(threshold, 1e-6)
        var representative: [SIMD3<Int32>: UInt32] = [:]
        var remap = [UInt32](0..<UInt32(mesh.vertices.count))
        var merged = 0

        for i in scope.sorted() where i < mesh.vertices.count {
            let p = mesh.vertices[i].position
            let key = SIMD3<Int32>(Int32((p.x / step).rounded()),
                                   Int32((p.y / step).rounded()),
                                   Int32((p.z / step).rounded()))
            if let first = representative[key] {
                remap[i] = first
                merged += 1
            } else {
                representative[key] = UInt32(i)
            }
        }
        guard merged > 0 else { return (mesh, 0) }

        // Compact: drop the vertices nothing points at any more.
        var keep: [UInt32] = []
        var newIndex = [Int](repeating: -1, count: mesh.vertices.count)
        for i in mesh.vertices.indices where Int(remap[i]) == i {
            newIndex[i] = keep.count
            keep.append(UInt32(i))
        }
        var indices: [UInt32] = []
        for tri in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = newIndex[Int(remap[Int(mesh.indices[tri])])]
            let b = newIndex[Int(remap[Int(mesh.indices[tri + 1])])]
            let c = newIndex[Int(remap[Int(mesh.indices[tri + 2])])]
            // A triangle whose corners collapsed onto each other is gone.
            guard a >= 0, b >= 0, c >= 0, a != b, b != c, a != c else { continue }
            indices += [UInt32(a), UInt32(b), UInt32(c)]
        }
        var result = MeshData(vertices: keep.map { mesh.vertices[Int($0)] }, indices: indices)
        ModifierStack.recomputeNormals(&result, welded: true)
        return (result, merged)
    }

    /// `bpy.ops.mesh.vertices_smooth` — moves each vertex toward the average of
    /// its neighbours, which is Laplacian smoothing.
    public static func smoothVertices(_ mesh: MeshData, vertices selection: Set<Int>,
                                      factor: Float = 0.5) -> MeshData {
        let scope = selection.isEmpty ? Set(mesh.vertices.indices) : selection
        guard !scope.isEmpty else { return mesh }

        var sum = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
        var count = [Float](repeating: 0, count: mesh.vertices.count)
        for e in stride(from: 0, to: mesh.edges.count, by: 2) {
            let a = Int(mesh.edges[e]), b = Int(mesh.edges[e + 1])
            guard a < sum.count, b < sum.count else { continue }
            sum[a] += mesh.vertices[b].position; count[a] += 1
            sum[b] += mesh.vertices[a].position; count[b] += 1
        }
        var result = mesh
        for i in scope where i < result.vertices.count && count[i] > 0 {
            let average = sum[i] / count[i]
            result.vertices[i].position = mix(result.vertices[i].position, average, t: factor)
        }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// `bpy.ops.mesh.delete(type='VERT')` — removes the vertices and every face
    /// that used them, as Blender does.
    public static func deleteVertices(_ mesh: MeshData, vertices selection: Set<Int>) -> MeshData {
        guard !selection.isEmpty else { return mesh }
        var newIndex = [Int](repeating: -1, count: mesh.vertices.count)
        var keep: [MeshVertex] = []
        for i in mesh.vertices.indices where !selection.contains(i) {
            newIndex[i] = keep.count
            keep.append(mesh.vertices[i])
        }
        var indices: [UInt32] = []
        for tri in stride(from: 0, to: mesh.indices.count, by: 3) {
            let c = (0..<3).map { newIndex[Int(mesh.indices[tri + $0])] }
            guard c.allSatisfy({ $0 >= 0 }) else { continue }
            indices += c.map { UInt32($0) }
        }
        return MeshData(vertices: keep, indices: indices)
    }

    // MARK: - Edge menu  (VIEW3D_MT_edit_mesh_edges)

    /// `bpy.ops.mesh.delete(type='EDGE')`. Deleting an edge takes the faces on
    /// either side with it; the vertices stay, as they do in Blender.
    public static func deleteEdges(_ mesh: MeshData, edges selection: Set<Int>) -> MeshData {
        guard !selection.isEmpty else { return mesh }
        var doomed = Set<UInt64>()
        for e in selection {
            let base = e * 2
            guard base + 1 < mesh.edges.count else { continue }
            doomed.insert(edgeKey(mesh.edges[base], mesh.edges[base + 1]))
        }
        var indices: [UInt32] = []
        for tri in stride(from: 0, to: mesh.indices.count, by: 3) {
            let c = (0..<3).map { mesh.indices[tri + $0] }
            let touches = (0..<3).contains { doomed.contains(edgeKey(c[$0], c[($0 + 1) % 3])) }
            if !touches { indices += c }
        }
        return MeshData(vertices: mesh.vertices, indices: indices)
    }

    // MARK: - Face menu  (VIEW3D_MT_edit_mesh_faces)

    /// `bpy.ops.mesh.poke` — fans each face out from a new centre vertex.
    public static func pokeFaces(_ mesh: MeshData, faces: Set<Int>) -> (MeshData, Set<Int>) {
        guard !faces.isEmpty else { return (mesh, faces) }
        var verts = mesh.vertices
        var indices: [UInt32] = []
        var newFaces: Set<Int> = []

        for face in 0..<(mesh.indices.count / 3) {
            let base = face * 3
            let c = (0..<3).map { mesh.indices[base + $0] }
            guard faces.contains(face), verts.count + 1 <= Int(UInt32.max) else {
                indices += c
                continue
            }
            let p = c.map { mesh.vertices[Int($0)].position }
            let centre = (p[0] + p[1] + p[2]) / 3
            let n = normalize(cross(p[1] - p[0], p[2] - p[0]))
            verts.append(MeshVertex(centre, n))
            let mid = UInt32(verts.count - 1)
            for i in 0..<3 {
                newFaces.insert(indices.count / 3)
                indices += [c[i], c[(i + 1) % 3], mid]
            }
        }
        var result = MeshData(vertices: verts, indices: indices)
        ModifierStack.recomputeNormals(&result, welded: false)
        return (result, newFaces)
    }

    /// `bpy.ops.mesh.flip_normals` — reverses winding, which is what a normal
    /// flip is on a triangle soup.
    public static func flipNormals(_ mesh: MeshData, faces: Set<Int>) -> MeshData {
        var indices = mesh.indices
        let scope = faces.isEmpty ? Set(0..<(mesh.indices.count / 3)) : faces
        for face in scope {
            let base = face * 3
            guard base + 2 < indices.count else { continue }
            indices.swapAt(base + 1, base + 2)
        }
        var result = MeshData(vertices: mesh.vertices, indices: indices)
        ModifierStack.recomputeNormals(&result, welded: false)
        return result
    }

    /// `bpy.ops.mesh.extrude_faces_move` — extrudes each face on its own,
    /// leaving them unattached to their neighbours.
    public static func extrudeIndividual(_ mesh: MeshData, faces: Set<Int>,
                                         distance: Float) -> (MeshData, Set<Int>) {
        guard !faces.isEmpty else { return (mesh, faces) }
        var verts = mesh.vertices
        var indices = mesh.indices
        var newFaces: Set<Int> = []

        for face in faces.sorted() {
            let base = face * 3
            guard base + 2 < mesh.indices.count, verts.count + 3 <= Int(UInt32.max) else { continue }
            let corner = (0..<3).map { Int(mesh.indices[base + $0]) }
            let p = corner.map { mesh.vertices[$0].position }
            let n = normalize(cross(p[1] - p[0], p[2] - p[0]))
            // Each face gets its own ring of vertices, so neighbours do not
            // drag along with it — that is what "individual" means here.
            let ring = (0..<3).map { i -> UInt32 in
                verts.append(MeshVertex(p[i], n))
                return UInt32(verts.count - 1)
            }
            let top = (0..<3).map { i -> UInt32 in
                verts.append(MeshVertex(p[i] + n * distance, n))
                return UInt32(verts.count - 1)
            }
            newFaces.insert(indices.count / 3)
            indices += [top[0], top[1], top[2]]
            for i in 0..<3 {
                let j = (i + 1) % 3
                indices += [ring[i], ring[j], top[j], ring[i], top[j], top[i]]
            }
        }
        var result = MeshData(vertices: verts, indices: indices)
        ModifierStack.recomputeNormals(&result, welded: false)
        return (result, newFaces)
    }

    /// `bpy.ops.transform.vertex_random` — jitters vertices along their own
    /// normals, which keeps a surface looking like a rougher version of itself
    /// rather than a cloud of noise.
    public static func randomize(_ mesh: MeshData, vertices selection: Set<Int>,
                                 amount: Float = 0.08) -> MeshData {
        let scope = selection.isEmpty ? Set(mesh.vertices.indices) : selection
        guard !scope.isEmpty else { return mesh }
        var result = mesh
        for i in scope where i < result.vertices.count {
            let n = result.vertices[i].normal
            // Jittering along a non-finite normal writes NaN into the position,
            // which then trapped the quantiser downstream.
            guard n.x.isFinite, n.y.isFinite, n.z.isFinite else { continue }
            result.vertices[i].position += n * Float.random(in: -amount...amount)
        }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// `bpy.ops.transform.shrink_fatten` — moves the selected vertices along
    /// their normals: outward for a positive offset, as Blender does.
    ///
    /// Along the welded normal, so the copies of a corner that flat shading
    /// splits apart all move the same way and the surface does not tear.
    public static func shrinkFatten(_ mesh: MeshData, vertices selection: Set<Int>,
                                    offset: Float) -> MeshData {
        let scope = selection.isEmpty ? Set(mesh.vertices.indices) : selection
        guard !scope.isEmpty, offset != 0 else { return mesh }
        var result = mesh
        ModifierStack.recomputeNormals(&result, welded: true)
        for i in scope where i < result.vertices.count {
            let n = result.vertices[i].normal
            guard n.x.isFinite, n.y.isFinite, n.z.isFinite else { continue }
            result.vertices[i].position += n * offset
        }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// `bpy.ops.transform.push_pull` — moves the selected vertices toward
    /// their median point for a positive distance, away from it for a negative
    /// one. Measured in Blender 5.2.1: 0.2 takes a cube's corners from 1 to
    /// 0.885 on each axis, 0.2 along the diagonal.
    public static func pushPull(_ mesh: MeshData, vertices selection: Set<Int>,
                                distance: Float) -> MeshData {
        let scope = selection.isEmpty ? Set(mesh.vertices.indices) : selection
        guard let center = medianPoint(mesh, scope), distance != 0 else { return mesh }
        var result = mesh
        for i in scope where i < result.vertices.count {
            let toCenter = center - result.vertices[i].position
            let length = simd_length(toCenter)
            guard length > 1e-6 else { continue }
            result.vertices[i].position += toCenter / length * distance
        }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// `bpy.ops.transform.tosphere` — blends each selected vertex's distance
    /// from the median point toward the average distance, so a factor of 1
    /// puts them all on one sphere.
    public static func toSphere(_ mesh: MeshData, vertices selection: Set<Int>,
                                factor: Float) -> MeshData {
        let scope = selection.isEmpty ? Set(mesh.vertices.indices) : selection
        guard let center = medianPoint(mesh, scope), factor != 0 else { return mesh }
        let unique = Set(scope.filter { $0 < mesh.vertices.count }.map { mesh.vertices[$0].position })
        let radius = unique.map { simd_distance($0, center) }.reduce(0, +) / Float(unique.count)
        let t = min(max(factor, 0), 1)
        var result = mesh
        for i in scope where i < result.vertices.count {
            let offset = result.vertices[i].position - center
            let length = simd_length(offset)
            guard length > 1e-6 else { continue }
            result.vertices[i].position = center + offset / length * (length + (radius - length) * t)
        }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// The mean of the selected positions, each counted once however many
    /// copies of it flat shading made.
    private static func medianPoint(_ mesh: MeshData, _ scope: Set<Int>) -> SIMD3<Float>? {
        let unique = Set(scope.filter { $0 < mesh.vertices.count }.map { mesh.vertices[$0].position })
        guard !unique.isEmpty else { return nil }
        return unique.reduce(.zero, +) / Float(unique.count)
    }

    // MARK: - Select menu  (VIEW3D_MT_select_edit_mesh)

    /// `bpy.ops.mesh.select_linked` — floods the selection across every face
    /// reachable through a shared edge.
    public static func selectLinked(_ mesh: MeshData, from seed: Set<Int>) -> Set<Int> {
        guard !seed.isEmpty else { return seed }
        // Which faces touch each vertex.
        var byVertex: [UInt32: [Int]] = [:]
        let faceCount = mesh.indices.count / 3
        for face in 0..<faceCount {
            for i in 0..<3 { byVertex[mesh.indices[face * 3 + i], default: []].append(face) }
        }
        var seen = seed
        var queue = Array(seed)
        while let face = queue.popLast() {
            let base = face * 3
            guard base + 2 < mesh.indices.count else { continue }
            for i in 0..<3 {
                for neighbour in byVertex[mesh.indices[base + i]] ?? [] where !seen.contains(neighbour) {
                    seen.insert(neighbour)
                    queue.append(neighbour)
                }
            }
        }
        return seen
    }

    /// `bpy.ops.mesh.select_more` / `select_less`.
    public static func growSelection(_ mesh: MeshData, faces: Set<Int>) -> Set<Int> {
        guard !faces.isEmpty else { return faces }
        let selectedVerts = vertices(of: faces, in: mesh)
        var out = faces
        for face in 0..<(mesh.indices.count / 3) {
            let base = face * 3
            if (0..<3).contains(where: { selectedVerts.contains(Int(mesh.indices[base + $0])) }) {
                out.insert(face)
            }
        }
        return out
    }

    public static func shrinkSelection(_ mesh: MeshData, faces: Set<Int>) -> Set<Int> {
        guard !faces.isEmpty else { return faces }
        // A face survives only if every vertex it uses is interior to the
        // selection — i.e. no unselected face also uses it.
        var usedByUnselected: Set<Int> = []
        for face in 0..<(mesh.indices.count / 3) where !faces.contains(face) {
            let base = face * 3
            for i in 0..<3 { usedByUnselected.insert(Int(mesh.indices[base + i])) }
        }
        return faces.filter { face in
            let base = face * 3
            guard base + 2 < mesh.indices.count else { return false }
            return !(0..<3).contains { usedByUnselected.contains(Int(mesh.indices[base + $0])) }
        }
    }

    /// Every vertex used by the given faces — how Blender widens a face
    /// selection when you switch to vertex mode.
    public static func vertices(of faces: Set<Int>, in mesh: MeshData) -> Set<Int> {
        var out: Set<Int> = []
        for face in faces {
            let base = face * 3
            guard base + 2 < mesh.indices.count else { continue }
            for i in 0..<3 { out.insert(Int(mesh.indices[base + i])) }
        }
        return out
    }
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

/// An unordered vertex pair packed into one integer, so an edge has the same
/// key whichever way round it is given.
private func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
    let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
    return lo << 32 | hi
}
