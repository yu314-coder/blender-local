import Foundation
import simd

/// UV coordinates for a mesh, and the projections that generate them.
///
/// Blender unwraps with angle-based flattening (ABF) and LSCM, which minimise
/// distortion by solving over the whole mesh. These are projections: they
/// assign coordinates without solving anything, which is exactly what Blender's
/// own Cube, Cylinder and Sphere projections do, and what Smart UV Project
/// approximates before packing.
public extension MeshData {
    /// Assigns UVs and copies them onto the vertices the GPU reads.
    mutating func applyUVs(_ coords: [SIMD2<Float>]) {
        guard coords.count == vertices.count else { return }
        uvs = coords
        for i in vertices.indices { vertices[i].uv = coords[i] }
    }
}

public extension MeshData {
    /// What the UV Editor strokes, as pairs of entries of `indices` (triangle
    /// corners, whose UVs are the line's ends): every polygon edge — not the
    /// diagonals triangulation added, which `uvDiagonals` marks — with the
    /// ones Blender marks as seams apart. A seam between two faces is drawn
    /// once for each, since in UV space those are two lines.
    func uvEditorLines() -> (edges: [(Int, Int)], seams: [(Int, Int)]) {
        var seamPairs = Set<UInt64>()
        var s = 0
        while s + 1 < seamEdges.count {
            let a = seamEdges[s], b = seamEdges[s + 1]
            seamPairs.insert(UInt64(min(a, b)) << 32 | UInt64(max(a, b)))
            s += 2
        }
        let skip = uvDiagonals.count * 3 == indices.count ? uvDiagonals : []
        var edges: [(Int, Int)] = [], seams: [(Int, Int)] = []
        edges.reserveCapacity(indices.count)
        for t in 0..<indices.count / 3 {
            for k in 0..<3 where skip.isEmpty || skip[t] & (1 << k) == 0 {
                let from = 3 * t + k, to = 3 * t + (k + 1) % 3
                let a = indices[from], b = indices[to]
                if seamPairs.contains(UInt64(min(a, b)) << 32 | UInt64(max(a, b))) {
                    seams.append((from, to))
                } else {
                    edges.append((from, to))
                }
            }
        }
        return (edges, seams)
    }
}

/// The simulator's stand-ins for Blender's projections: what `bpy.ops.uv`
/// does in the shim, where there is no Blender to unwrap with. The UV Editor's
/// menu sends Blender's own operators (`UVOperator`).
public enum UVUnwrapMethod: String, CaseIterable, Identifiable, Sendable {
    case smart, cube, cylinder, sphere

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smart:    return "Smart UV Project"
        case .cube:     return "Cube Projection"
        case .cylinder: return "Cylinder Projection"
        case .sphere:   return "Sphere Projection"
        }
    }

    public var bpyCall: String {
        switch self {
        case .smart:    return "bpy.ops.uv.smart_project()"
        case .cube:     return "bpy.ops.uv.cube_project()"
        case .cylinder: return "bpy.ops.uv.cylinder_project()"
        case .sphere:   return "bpy.ops.uv.sphere_project()"
        }
    }

    public func project(_ mesh: MeshData) -> [SIMD2<Float>] {
        switch self {
        case .smart:    return UVUnwrap.smartProject(mesh)
        case .cube:     return UVUnwrap.cubeProject(mesh)
        case .cylinder: return UVUnwrap.cylinderProject(mesh)
        case .sphere:   return UVUnwrap.sphereProject(mesh)
        }
    }
}

/// The UV Editor's UV menu: Blender's own operators, by their 5.2.1
/// identifiers, in the order Blender's UV ▸ Unwrap menu lists them
/// (`IMAGE_MT_uvs_unwrap`), then the island and seam rows of its UV menu.
///
/// Every one of these runs headless — measured in 5.2.1 under
/// `-b --factory-startup` from Edit Mode with faces selected, each returned
/// FINISHED and moved UVs (Seams from Islands marks seams instead). The menu
/// used to grey out Follow Active Quads, Lightmap Pack and Pack Islands as
/// unavailable, and its Unwrap ran `smart_project`.
///
/// They go through `_blenderkit_uv.run`, which runs them the way Blender's
/// menu does and says so when there is nothing for them to act on — see that
/// module for Edit Mode, object mode and the active quad.
public enum UVOperator: String, CaseIterable, Identifiable, Sendable {
    case unwrapAngleBased, unwrapConformal, unwrapMinimumStretch
    case smartProject, lightmapPack, followActiveQuads
    case cubeProjection, cylinderProjection, sphereProjection
    case packIslands, averageIslandsScale
    case seamsFromIslands
    case reset

    public var id: String { rawValue }

    /// Blender's own menu text (`IMAGE_MT_uvs_unwrap`, `IMAGE_MT_uvs`).
    public var label: String {
        switch self {
        case .unwrapAngleBased:     return "Unwrap Angle Based"
        case .unwrapConformal:      return "Unwrap Conformal"
        case .unwrapMinimumStretch: return "Unwrap Minimum Stretch"
        case .smartProject:         return "Smart UV Project"
        case .lightmapPack:         return "Lightmap Pack"
        case .followActiveQuads:    return "Follow Active Quads"
        case .cubeProjection:       return "Cube Projection"
        case .cylinderProjection:   return "Cylinder Projection"
        case .sphereProjection:     return "Sphere Projection"
        case .packIslands:          return "Pack Islands"
        case .averageIslandsScale:  return "Average Islands Scale"
        case .seamsFromIslands:     return "Seams from Islands"
        case .reset:                return "Reset"
        }
    }

    /// The `bpy.ops.uv` operator.
    public var operatorName: String {
        switch self {
        case .unwrapAngleBased, .unwrapConformal, .unwrapMinimumStretch: return "unwrap"
        case .smartProject:        return "smart_project"
        case .lightmapPack:        return "lightmap_pack"
        case .followActiveQuads:   return "follow_active_quads"
        case .cubeProjection:      return "cube_project"
        case .cylinderProjection:  return "cylinder_project"
        case .sphereProjection:    return "sphere_project"
        case .packIslands:         return "pack_islands"
        case .averageIslandsScale: return "average_islands_scale"
        case .seamsFromIslands:    return "seams_from_islands"
        case .reset:               return "reset"
        }
    }

    /// Keyword arguments, as Python source. `uv.unwrap`'s `method` is always
    /// spelled out: its default is CONFORMAL in 5.2.1 (read from the
    /// operator's RNA), not the ANGLE_BASED older versions defaulted to.
    public var arguments: String {
        switch self {
        case .unwrapAngleBased:     return "method='ANGLE_BASED'"
        case .unwrapConformal:      return "method='CONFORMAL'"
        case .unwrapMinimumStretch: return "method='MINIMUM_STRETCH'"
        default:                    return ""
        }
    }

    /// The Python the menu sends.
    public var python: String {
        let args = arguments.isEmpty ? "" : ", " + arguments
        return "import _blenderkit_uv\n_blenderkit_uv.run('\(operatorName)'\(args))"
    }

    /// Where Blender's menu puts a separator after this row.
    public var endsGroup: Bool {
        [.unwrapMinimumStretch, .followActiveQuads, .sphereProjection,
         .averageIslandsScale, .seamsFromIslands].contains(self)
    }
}

public enum UVUnwrap {

    /// Blender's `uv.cube_project`: each triangle is projected on whichever
    /// world axis its normal points at most, so faces stay undistorted and the
    /// six directions become six islands.
    public static func cubeProject(_ mesh: MeshData, scale: Float = 1) -> [SIMD2<Float>] {
        var uvs = [SIMD2<Float>](repeating: .zero, count: mesh.vertices.count)

        var i = 0
        while i + 2 < mesh.indices.count {
            let idx = (0..<3).map { Int(mesh.indices[i + $0]) }
            let p = idx.map { mesh.vertices[$0].position }
            let n = cross(p[1] - p[0], p[2] - p[0])
            let a = abs(n)

            // The dominant axis decides the projection plane.
            for (k, vertex) in idx.enumerated() {
                let q = p[k]
                let uv: SIMD2<Float>
                if a.x >= a.y && a.x >= a.z {
                    uv = SIMD2(n.x > 0 ? -q.y : q.y, q.z)
                } else if a.y >= a.z {
                    uv = SIMD2(n.y > 0 ? q.x : -q.x, q.z)
                } else {
                    uv = SIMD2(q.x, n.z > 0 ? q.y : -q.y)
                }
                uvs[vertex] = uv * scale
            }
            i += 3
        }
        return normalize(uvs)
    }

    /// Blender's `uv.sphere_project`: longitude and latitude straight off the
    /// direction from the object's centre.
    public static func sphereProject(_ mesh: MeshData) -> [SIMD2<Float>] {
        guard !mesh.vertices.isEmpty else { return [] }
        let centre = mesh.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position }
                   / Float(mesh.vertices.count)
        return mesh.vertices.map { v in
            let d = simd.normalize(v.position - centre)
            let u = 0.5 + atan2(d.y, d.x) / (2 * .pi)
            let t = 0.5 - asin(max(-1, min(d.z, 1))) / .pi
            return SIMD2(u, t)
        }
    }

    /// Blender's `uv.cylinder_project`: angle around Z, height along it.
    public static func cylinderProject(_ mesh: MeshData) -> [SIMD2<Float>] {
        guard !mesh.vertices.isEmpty else { return [] }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in mesh.vertices { lo = min(lo, v.position.z); hi = max(hi, v.position.z) }
        let span = max(hi - lo, 1e-5)
        return mesh.vertices.map { v in
            let u = 0.5 + atan2(v.position.y, v.position.x) / (2 * .pi)
            return SIMD2(u, (v.position.z - lo) / span)
        }
    }

    /// Blender's `uv.smart_project`, in spirit: cube-project, then fit the
    /// result to the 0–1 square. Blender additionally packs islands to remove
    /// overlap, which needs an island-packing pass this does not have — so
    /// islands here can overlap, and the UV editor shows that honestly.
    public static func smartProject(_ mesh: MeshData) -> [SIMD2<Float>] {
        cubeProject(mesh)
    }

    /// Fits coordinates into 0–1, which is the square the UV editor draws.
    private static func normalize(_ uvs: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard !uvs.isEmpty else { return uvs }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for uv in uvs { lo = min(lo, uv); hi = max(hi, uv) }
        let span = SIMD2(max(hi.x - lo.x, 1e-5), max(hi.y - lo.y, 1e-5))
        return uvs.map { ($0 - lo) / span }
    }

    /// How far the projection stretches the mesh: the ratio of UV area to
    /// world area per triangle, averaged. Blender shows this as stretch
    /// colouring; a single number is enough to tell a good unwrap from a bad
    /// one.
    public static func averageStretch(_ mesh: MeshData, uvs: [SIMD2<Float>]) -> Float {
        guard uvs.count == mesh.vertices.count else { return 0 }
        return averageStretch(mesh) { uvs[Int(mesh.indices[$0])] }
    }

    /// The same, over whatever UVs the mesh has — Blender's per-corner map on
    /// a mirrored mesh, where a UV per vertex cannot describe a seam.
    public static func averageStretch(_ mesh: MeshData) -> Float {
        guard mesh.hasUVs else { return 0 }
        return averageStretch(mesh) { mesh.cornerUV($0) }
    }

    private static func averageStretch(_ mesh: MeshData,
                                       uv: (Int) -> SIMD2<Float>) -> Float {
        // Each triangle's ratio, once: world area from the vertices, UV area
        // from the triangle's own three corners.
        var ratios: [Float] = []
        ratios.reserveCapacity(mesh.indices.count / 3)
        var i = 0
        while i + 2 < mesh.indices.count {
            let p0 = mesh.vertices[Int(mesh.indices[i])].position
            let p1 = mesh.vertices[Int(mesh.indices[i + 1])].position
            let p2 = mesh.vertices[Int(mesh.indices[i + 2])].position
            let worldArea = length(cross(p1 - p0, p2 - p0)) * 0.5
            let e1 = uv(i + 1) - uv(i), e2 = uv(i + 2) - uv(i)
            let uvArea = abs(e1.x * e2.y - e1.y * e2.x) * 0.5
            if worldArea > 1e-8, uvArea > 1e-8 { ratios.append(uvArea / worldArea) }
            i += 3
        }
        guard !ratios.isEmpty else { return 0 }
        let mean = ratios.reduce(0, +) / Float(ratios.count)
        // Report deviation from uniform, so 0 is a perfect unwrap.
        return ratios.reduce(0) { $0 + abs($1 - mean) / mean } / Float(ratios.count)
    }

    /// Which edges of each triangle are diagonals that triangulation added,
    /// from the face corner (loop) behind each triangle corner: bit k for the
    /// edge from corner k to corner k + 1.
    ///
    /// Blender's loops belong to one polygon each. Two triangles naming the
    /// same *pair of loops* are therefore two pieces of one polygon, and the
    /// edge between them is a diagonal; an edge between two polygons has
    /// different loops on either side and is named once. That is exact for
    /// any polygon, where comparing vertex pairs cannot tell a quad's diagonal
    /// from a real edge. Blender's UV Editor draws polygons, so the diagonals
    /// are what it leaves out.
    public static func diagonals(cornerLoops loops: [UInt32]) -> [UInt8] {
        let triangles = loops.count / 3
        guard triangles > 0 else { return [] }
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            UInt64(min(a, b)) << 32 | UInt64(max(a, b))
        }
        var seen = Set<UInt64>(minimumCapacity: loops.count)
        var shared = Set<UInt64>()
        for t in 0..<triangles {
            for k in 0..<3 {
                let pair = key(loops[3 * t + k], loops[3 * t + (k + 1) % 3])
                if !seen.insert(pair).inserted { shared.insert(pair) }
            }
        }
        var mask = [UInt8](repeating: 0, count: triangles)
        guard !shared.isEmpty else { return mask }
        for t in 0..<triangles {
            for k in 0..<3 where shared.contains(key(loops[3 * t + k], loops[3 * t + (k + 1) % 3])) {
                mask[t] |= 1 << k
            }
        }
        return mask
    }
}
