import Foundation
import simd

/// A triangle mesh from a sampled field: the surface where the field crosses a
/// level, with each vertex shared by every triangle that meets on its grid
/// edge, and triangles wound so their normals point from inside (above the
/// level) to outside.
public enum MarchingCubes {

    public struct Mesh: Sendable {
        public var positions: [SIMD3<Float>] = []
        public var triangles: [UInt32] = []
        public var triangleCount: Int { triangles.count / 3 }
    }

    /// `field` is `n³` samples in [x][y][z] order — x is the slowest index —
    /// at `origin + index · spacing`. Inside is above `level`.
    public static func extract(field: [Float], resolution n: Int, level: Float,
                               origin: SIMD3<Float>, spacing: Float) -> Mesh {
        precondition(field.count == n * n * n, "field size")
        var mesh = Mesh()
        // A vertex per grid edge, found by the edge's lower grid point and axis.
        var vertexOnEdge: [Int: UInt32] = [:]
        vertexOnEdge.reserveCapacity(1 << 16)

        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (x * n + y) * n + z }
        let corners: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
                                          (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
        // Bourke's edges as (corner, corner).
        let edgeCorners: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6),
                                         (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]

        var values = [Float](repeating: 0, count: 8)
        var edgeVertex = [UInt32](repeating: 0, count: 12)
        for x in 0..<(n - 1) {
            for y in 0..<(n - 1) {
                for z in 0..<(n - 1) {
                    var cube = 0
                    for (c, o) in corners.enumerated() {
                        let v = field[index(x + o.0, y + o.1, z + o.2)]
                        values[c] = v
                        // Bourke's tables take a set bit as below the level.
                        if v <= level { cube |= 1 << c }
                    }
                    let mask = MarchingCubesTables.edges[cube]
                    if mask == 0 { continue }
                    for e in 0..<12 where mask & (1 << e) != 0 {
                        let (a, b) = edgeCorners[e]
                        let pa = (x + corners[a].0, y + corners[a].1, z + corners[a].2)
                        let pb = (x + corners[b].0, y + corners[b].1, z + corners[b].2)
                        let lower = min(index(pa.0, pa.1, pa.2), index(pb.0, pb.1, pb.2))
                        let axis = pa.0 != pb.0 ? 0 : (pa.1 != pb.1 ? 1 : 2)
                        let key = lower * 3 + axis
                        if let existing = vertexOnEdge[key] {
                            edgeVertex[e] = existing
                            continue
                        }
                        let va = values[a], vb = values[b]
                        let t = abs(vb - va) < 1e-12 ? 0.5 : (level - va) / (vb - va)
                        let p = SIMD3<Float>(Float(pa.0), Float(pa.1), Float(pa.2))
                            + (SIMD3<Float>(Float(pb.0), Float(pb.1), Float(pb.2))
                               - SIMD3<Float>(Float(pa.0), Float(pa.1), Float(pa.2))) * min(max(t, 0), 1)
                        let id = UInt32(mesh.positions.count)
                        mesh.positions.append(origin + p * spacing)
                        vertexOnEdge[key] = id
                        edgeVertex[e] = id
                    }
                    let row = cube * 16
                    var k = 0
                    while k < 16, MarchingCubesTables.triangles[row + k] >= 0 {
                        let a = edgeVertex[Int(MarchingCubesTables.triangles[row + k])]
                        let b = edgeVertex[Int(MarchingCubesTables.triangles[row + k + 1])]
                        let c = edgeVertex[Int(MarchingCubesTables.triangles[row + k + 2])]
                        if a != b, b != c, a != c {
                            // With set bits meaning below the level, Bourke's
                            // order already faces the low side: outward here.
                            // Measured: a sphere's signed volume is positive.
                            mesh.triangles.append(a); mesh.triangles.append(b); mesh.triangles.append(c)
                        }
                        k += 3
                    }
                }
            }
        }
        return mesh
    }

    /// The volume a closed mesh encloses: positive when its normals point out.
    public static func signedVolume(_ mesh: Mesh) -> Float {
        var total: Float = 0
        for t in stride(from: 0, to: mesh.triangles.count, by: 3) {
            let a = mesh.positions[Int(mesh.triangles[t])]
            let b = mesh.positions[Int(mesh.triangles[t + 1])]
            let c = mesh.positions[Int(mesh.triangles[t + 2])]
            total += dot(a, cross(b, c))
        }
        return total / 6
    }
}
