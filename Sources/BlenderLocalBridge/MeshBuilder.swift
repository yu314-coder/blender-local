import Foundation
import simd

public struct MeshVertex: Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// Texture coordinate, zero until the mesh is unwrapped. It lives on the
    /// vertex rather than beside it so the GPU gets one interleaved buffer.
    public var uv: SIMD2<Float> = .zero

    public init(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float> = .zero) {
        position = p; normal = n; self.uv = uv
    }
}

public struct MeshData: Sendable {
    public var vertices: [MeshVertex]
    public var indices: [UInt32]
    /// Unique edges, for the wireframe/outline overlay Blender draws.
    public var edges: [UInt32]
    /// One UV per vertex, empty until the mesh is unwrapped. Only the
    /// simulator's own projections write this; a mesh mirrored from Blender
    /// carries Blender's UVs in `cornerUVs` instead.
    public var uvs: [SIMD2<Float>] = []

    /// Blender's active UV map, one UV per entry of `indices` — per face
    /// corner, which is how Blender stores UVs, so a seam gives one vertex two
    /// UVs without splitting the vertex. Empty unless the mirror carried a UV
    /// map (`SceneMirror.installUVs`).
    public var cornerUVs: [SIMD2<Float>] = []
    /// The face corner — Blender's loop — behind each entry of `indices`, sent
    /// with `cornerUVs`. A loop belongs to exactly one polygon, which is what
    /// tells a polygon's own edges from the diagonals triangulation added
    /// (`uvDiagonals`).
    public var cornerLoops: [UInt32] = []
    /// Per triangle, which of its edges are triangulation diagonals rather
    /// than Blender's edges: bit k for the edge from corner k to corner k + 1.
    /// Derived from `cornerLoops` when they are installed; empty otherwise, and
    /// then every triangle edge is drawn.
    public var uvDiagonals: [UInt8] = []
    /// The name of the UV map `cornerUVs` came from, as Blender has it.
    public var uvMapName: String = ""
    /// Blender's seams: two vertex indices per edge marked as a seam. Carried
    /// whether or not the mesh has a UV map, since seams are marked before the
    /// unwrap that uses them.
    public var seamEdges: [UInt32] = []

    public var hasUVs: Bool {
        (!uvs.isEmpty && uvs.count == vertices.count)
            || (!cornerUVs.isEmpty && cornerUVs.count == indices.count)
    }

    /// The UV at one entry of `indices`: Blender's per-corner UV when the mesh
    /// has one, the simulator's per-vertex UV otherwise. Only meaningful while
    /// `hasUVs`.
    public func cornerUV(_ corner: Int) -> SIMD2<Float> {
        if cornerUVs.count == indices.count { return cornerUVs[corner] }
        return uvs[Int(indices[corner])]
    }

    public init(vertices: [MeshVertex], indices: [UInt32], uvs: [SIMD2<Float>] = []) {
        self.vertices = vertices
        self.indices = indices
        self.edges = MeshData.buildEdges(indices)
        self.uvs = uvs
        // Keep the per-vertex copy in step, since that is what the GPU reads.
        if uvs.count == vertices.count {
            for i in self.vertices.indices { self.vertices[i].uv = uvs[i] }
        }
    }

    /// A mesh with no faces — a wire circle, an unfilled curve, an edge-only
    /// mesh — whose edges are Blender's own, since there are no triangles to
    /// derive them from. The renderer draws these as lines.
    public init(vertices: [MeshVertex], wireEdges: [UInt32]) {
        self.vertices = vertices
        self.indices = []
        self.edges = wireEdges
    }

    /// Edges and no faces: drawn and picked by its lines.
    public var isWire: Bool { indices.isEmpty && !edges.isEmpty }

    /// Each triangle contributes three edges; a shared edge appears twice, so
    /// deduplicate on the unordered pair.
    static func buildEdges(_ indices: [UInt32]) -> [UInt32] {
        var seen = Set<UInt64>()
        var out: [UInt32] = []
        out.reserveCapacity(indices.count)
        for tri in stride(from: 0, to: indices.count, by: 3) {
            let v = (indices[tri], indices[tri + 1], indices[tri + 2])
            for (a, b) in [(v.0, v.1), (v.1, v.2), (v.2, v.0)] {
                let lo = min(a, b), hi = max(a, b)
                let key = UInt64(lo) << 32 | UInt64(hi)
                if seen.insert(key).inserted { out.append(lo); out.append(hi) }
            }
        }
        return out
    }
}

/// Generates the same primitives as `bpy.ops.mesh.primitive_*`, at Blender's
/// default sizes: a 2m cube, a 1m-radius sphere, a 2m-diameter cylinder.
public enum MeshBuilder {

    /// The same primitives, built to the arguments the add operator was given
    /// rather than to Blender's defaults.
    ///
    /// This is what lets the redo panel do something visible without the real
    /// module: adjusting Vertices on a cylinder has to change the cylinder, and
    /// in the simulator there is no Blender to change it. The keys are bpy's
    /// own — `radius1`, `major_segments` — because the caller is parsing a bpy
    /// call, not inventing a vocabulary.
    public static func make(_ kind: PrimitiveKind,
                            arguments a: [String: Double]) -> MeshData {
        func f(_ key: String, _ fallback: Float) -> Float {
            a[key].map(Float.init) ?? fallback
        }
        func i(_ key: String, _ fallback: Int) -> Int {
            a[key].map { Int($0.rounded()) } ?? fallback
        }
        switch kind {
        case .plane:     return plane(size: f("size", 2))
        case .cube:      return cube(size: f("size", 2))
        case .circle:    return circle(radius: f("radius", 1), segments: i("vertices", 32))
        case .uvSphere:  return uvSphere(radius: f("radius", 1),
                                         segments: i("segments", 32), rings: i("ring_count", 16))
        case .icoSphere: return icoSphere(radius: f("radius", 1),
                                          subdivisions: i("subdivisions", 2))
        case .cylinder:  return cylinder(radius: f("radius", 1), depth: f("depth", 2),
                                         segments: i("vertices", 32))
        case .cone:      return cone(radius: f("radius1", 1), depth: f("depth", 2),
                                     segments: i("vertices", 32))
        case .torus:     return torus(major: f("major_radius", 1), minor: f("minor_radius", 0.25),
                                      majorSeg: i("major_segments", 48),
                                      minorSeg: i("minor_segments", 12))
        case .grid:      return grid(size: f("size", 2), divisions: i("x_subdivisions", 10))
        case .monkey:    return uvSphere(radius: f("size", 2) / 2, segments: 24, rings: 12)
        }
    }

    public static func make(_ kind: PrimitiveKind) -> MeshData {
        switch kind {
        case .plane:     return plane(size: 2)
        case .cube:      return cube(size: 2)
        case .circle:    return circle(radius: 1, segments: 32)
        case .uvSphere:  return uvSphere(radius: 1, segments: 32, rings: 16)
        case .icoSphere: return icoSphere(radius: 1, subdivisions: 2)
        case .cylinder:  return cylinder(radius: 1, depth: 2, segments: 32)
        case .cone:      return cone(radius: 1, depth: 2, segments: 32)
        case .torus:     return torus(major: 1, minor: 0.25, majorSeg: 48, minorSeg: 12)
        case .grid:      return grid(size: 2, divisions: 10)
        // Suzanne's mesh is a Blender datafile, not something to synthesise.
        // The real backend has her; the shim substitutes a sphere and the
        // Add menu marks it accordingly.
        case .monkey:    return uvSphere(radius: 1, segments: 24, rings: 12)
        }
    }

    // MARK: Flat-shaded primitives

    public static func plane(size: Float) -> MeshData {
        let h = size / 2
        let n = SIMD3<Float>(0, 0, 1)
        let v = [
            MeshVertex(SIMD3(-h, -h, 0), n), MeshVertex(SIMD3( h, -h, 0), n),
            MeshVertex(SIMD3( h,  h, 0), n), MeshVertex(SIMD3(-h,  h, 0), n),
        ]
        return MeshData(vertices: v, indices: [0, 1, 2, 0, 2, 3])
    }

    public static func cube(size: Float) -> MeshData {
        let h = size / 2
        var verts: [MeshVertex] = []
        var idx: [UInt32] = []
        // (normal, tangent, bitangent) per face — Blender's Z-up axes.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3( 0,  0,  1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),   // +Z top
            (SIMD3( 0,  0, -1), SIMD3(1, 0, 0), SIMD3(0, -1, 0)),  // -Z bottom
            (SIMD3( 1,  0,  0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),   // +X
            (SIMD3(-1,  0,  0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)),  // -X
            (SIMD3( 0,  1,  0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)),  // +Y
            (SIMD3( 0, -1,  0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),   // -Y
        ]
        for (n, t, b) in faces {
            let base = UInt32(verts.count)
            let c = n * h
            verts.append(MeshVertex(c - t * h - b * h, n))
            verts.append(MeshVertex(c + t * h - b * h, n))
            verts.append(MeshVertex(c + t * h + b * h, n))
            verts.append(MeshVertex(c - t * h + b * h, n))
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return MeshData(vertices: verts, indices: idx)
    }

    public static func circle(radius: Float, segments: Int) -> MeshData {
        let n = SIMD3<Float>(0, 0, 1)
        var verts = [MeshVertex(.zero, n)]
        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            verts.append(MeshVertex(SIMD3(cos(a) * radius, sin(a) * radius, 0), n))
        }
        var idx: [UInt32] = []
        for i in 0..<segments {
            idx += [0, UInt32(i + 1), UInt32((i + 1) % segments + 1)]
        }
        return MeshData(vertices: verts, indices: idx)
    }

    public static func uvSphere(radius: Float, segments: Int, rings: Int) -> MeshData {
        var verts: [MeshVertex] = []
        // Blender's UV sphere is Z-up: rings run from the -Z pole to +Z.
        for r in 0...rings {
            let phi = Float(r) / Float(rings) * .pi
            for s in 0...segments {
                let theta = Float(s) / Float(segments) * 2 * .pi
                let n = SIMD3(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi))
                verts.append(MeshVertex(n * radius, n))
            }
        }
        var idx: [UInt32] = []
        let stride = segments + 1
        for r in 0..<rings {
            for s in 0..<segments {
                let a = UInt32(r * stride + s)
                let b = UInt32((r + 1) * stride + s)
                idx += [a, b, b + 1, a, b + 1, a + 1]
            }
        }
        return MeshData(vertices: verts, indices: idx)
    }

    public static func cylinder(radius: Float, depth: Float, segments: Int) -> MeshData {
        let h = depth / 2
        var verts: [MeshVertex] = []
        var idx: [UInt32] = []

        // Side wall — duplicated rims so the side normals stay radial and the
        // caps stay flat, which is what Blender's flat shading looks like.
        let sideBase = UInt32(verts.count)
        for s in 0...segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            let n = SIMD3(cos(a), sin(a), 0)
            verts.append(MeshVertex(SIMD3(n.x * radius, n.y * radius, -h), n))
            verts.append(MeshVertex(SIMD3(n.x * radius, n.y * radius,  h), n))
        }
        for s in 0..<segments {
            let a = sideBase + UInt32(s * 2)
            idx += [a, a + 2, a + 3, a, a + 3, a + 1]
        }

        for (zSign, normal) in [(Float(1), SIMD3<Float>(0, 0, 1)), (Float(-1), SIMD3<Float>(0, 0, -1))] {
            let center = UInt32(verts.count)
            verts.append(MeshVertex(SIMD3(0, 0, h * zSign), normal))
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                verts.append(MeshVertex(SIMD3(cos(a) * radius, sin(a) * radius, h * zSign), normal))
            }
            for s in 0..<segments {
                let i0 = center + 1 + UInt32(s)
                let i1 = center + 1 + UInt32((s + 1) % segments)
                idx += zSign > 0 ? [center, i0, i1] : [center, i1, i0]
            }
        }
        return MeshData(vertices: verts, indices: idx)
    }

    public static func cone(radius: Float, depth: Float, segments: Int) -> MeshData {
        let h = depth / 2
        var verts: [MeshVertex] = []
        var idx: [UInt32] = []

        // Side: the apex is duplicated per segment so each face gets its own
        // normal rather than a degenerate averaged one at the tip.
        let slant = atan2(radius, depth)
        for s in 0..<segments {
            let a0 = Float(s) / Float(segments) * 2 * .pi
            let a1 = Float(s + 1) / Float(segments) * 2 * .pi
            let am = (a0 + a1) / 2
            let n = SIMD3(cos(am) * cos(slant), sin(am) * cos(slant), sin(slant))
            let base = UInt32(verts.count)
            verts.append(MeshVertex(SIMD3(cos(a0) * radius, sin(a0) * radius, -h), n))
            verts.append(MeshVertex(SIMD3(cos(a1) * radius, sin(a1) * radius, -h), n))
            verts.append(MeshVertex(SIMD3(0, 0, h), n))
            idx += [base, base + 1, base + 2]
        }

        let down = SIMD3<Float>(0, 0, -1)
        let center = UInt32(verts.count)
        verts.append(MeshVertex(SIMD3(0, 0, -h), down))
        for s in 0..<segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            verts.append(MeshVertex(SIMD3(cos(a) * radius, sin(a) * radius, -h), down))
        }
        for s in 0..<segments {
            let i0 = center + 1 + UInt32(s)
            let i1 = center + 1 + UInt32((s + 1) % segments)
            idx += [center, i1, i0]
        }
        return MeshData(vertices: verts, indices: idx)
    }

    /// Blender's Ico Sphere: an icosahedron with each triangle split and the
    /// new vertices pushed back onto the sphere, giving evenly sized faces
    /// rather than the poles a UV sphere has.
    public static func icoSphere(radius: Float, subdivisions: Int) -> MeshData {
        let t = (1 + sqrt(5.0) as Float) / 2
        var positions: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ].map { normalize($0) }

        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        for _ in 0..<max(0, subdivisions) {
            var cache: [UInt64: Int] = [:]
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let hit = cache[key] { return hit }
                positions.append(normalize((positions[a] + positions[b]) * 0.5))
                cache[key] = positions.count - 1
                return positions.count - 1
            }
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)
            for (a, b, c) in faces {
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next += [(a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)]
            }
            faces = next
        }

        // On a unit sphere the position is the normal.
        let verts = positions.map { MeshVertex($0 * radius, $0) }
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * 3)
        for (a, b, c) in faces {
            indices += [UInt32(a), UInt32(b), UInt32(c)]
        }
        return MeshData(vertices: verts, indices: indices)
    }

    /// Blender's Grid: a subdivided plane.
    public static func grid(size: Float, divisions: Int) -> MeshData {
        let n = max(1, divisions)
        let h = size / 2
        let normal = SIMD3<Float>(0, 0, 1)
        var verts: [MeshVertex] = []
        for row in 0...n {
            for col in 0...n {
                let x = -h + size * Float(col) / Float(n)
                let y = -h + size * Float(row) / Float(n)
                verts.append(MeshVertex(SIMD3(x, y, 0), normal))
            }
        }
        var indices: [UInt32] = []
        let stride = n + 1
        for row in 0..<n {
            for col in 0..<n {
                let a = UInt32(row * stride + col)
                let b = UInt32((row + 1) * stride + col)
                indices += [a, b + 1, b, a, a + 1, b + 1]
            }
        }
        return MeshData(vertices: verts, indices: indices)
    }

    public static func torus(major: Float, minor: Float, majorSeg: Int, minorSeg: Int) -> MeshData {
        var verts: [MeshVertex] = []
        for i in 0...majorSeg {
            let u = Float(i) / Float(majorSeg) * 2 * .pi
            let center = SIMD3(cos(u) * major, sin(u) * major, 0)
            for j in 0...minorSeg {
                let v = Float(j) / Float(minorSeg) * 2 * .pi
                let n = SIMD3(cos(u) * cos(v), sin(u) * cos(v), sin(v))
                verts.append(MeshVertex(center + n * minor, n))
            }
        }
        var idx: [UInt32] = []
        let stride = minorSeg + 1
        for i in 0..<majorSeg {
            for j in 0..<minorSeg {
                let a = UInt32(i * stride + j)
                let b = UInt32((i + 1) * stride + j)
                idx += [a, b, b + 1, a, b + 1, a + 1]
            }
        }
        return MeshData(vertices: verts, indices: idx)
    }
}

// MARK: - Matrix helpers

public extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self.init(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    init(scale s: SIMD3<Float>) {
        self.init(SIMD4(s.x, 0, 0, 0), SIMD4(0, s.y, 0, 0), SIMD4(0, 0, s.z, 0), SIMD4(0, 0, 0, 1))
    }

    /// XYZ Euler, applied X then Y then Z — Blender's default rotation mode.
    init(eulerXYZ e: SIMD3<Float>) {
        let (sx, cx) = (sin(e.x), cos(e.x))
        let (sy, cy) = (sin(e.y), cos(e.y))
        let (sz, cz) = (sin(e.z), cos(e.z))
        let rx = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, cx, sx, 0), SIMD4(0, -sx, cx, 0), SIMD4(0, 0, 0, 1))
        let ry = simd_float4x4(SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1))
        let rz = simd_float4x4(SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        self = rz * ry * rx
    }

    /// Right-handed look-at, matching Metal's clip-space conventions.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return simd_float4x4(
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        )
    }

    /// Orthographic projection, Metal depth range [0, 1].
    static func orthographic(halfWidth: Float, halfHeight: Float,
                             near: Float, far: Float) -> simd_float4x4 {
        let x = 1 / max(halfWidth, 1e-4)
        let y = 1 / max(halfHeight, 1e-4)
        let z = 1 / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, 0),
            SIMD4(0, 0, near * z, 1)
        )
    }

    /// Metal depth range is [0, 1], not OpenGL's [-1, 1].
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        )
    }
}


public extension SIMD4 where Scalar == Float {
    /// Drops the w of a homogeneous point or direction.
    ///
    /// Lives in the bridge rather than beside the camera that first needed it:
    /// the geometry code here uses it too, and a lower layer must not depend on
    /// an extension declared above it.
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
