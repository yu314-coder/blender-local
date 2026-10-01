import Foundation
import simd

// What one `bpy.ops.transform.translate`, `rotate` or `resize` does to the
// scene, as values: the one definition that the gizmo's live preview, the
// simulator's stand-in operators and the host tests all run.
//
// The gizmo previews a drag by painting the display cache and commits it by
// sending Python, so the two are different code. That is how the same defect
// kept shipping: snapping that rounded only the preview, and proportional
// editing that the commit applied and the preview did not. Everything the
// commit asks Blender for is computed here first, and
// scripts/run-tools-blender-check.sh holds this file's answers against what
// Blender 5.2.1 does with the Python the gizmo sends.
//
// The formulas are Blender's own, read from the 5.3 source tree beside this
// repository and measured in 5.2.1 under `-b --factory-startup`:
//
//   * translate moves by `value * factor`, rotate turns by `angle * factor`
//     about the centre, and resize moves by `factor * (T - I)(p - centre)` and
//     scales an object by `1 + (s - 1) * factor` along its own axes
//     (transform_mode_translate.cc, transform_mode_rotate.cc,
//     transform_mode.cc ElementResize).
//   * `factor` is 1 for the selection and calculatePropRatio's curve for the
//     rest (transform_generics.cc). Measured: LINEAR at size 3 moved cubes 1
//     and 2 units from the selected one by 0.6667 and 0.3333 of a translate,
//     turned them by 60° and 30° of a 90° rotate, and scaled them by 1.6667
//     and 1.3333 of a 2× resize.
//   * The distance is to the nearest selected element in world space — a mesh
//     scaled ×2 in X reached 11 vertices where the unscaled one reached 21 —
//     or along the surface with Connected Only
//     (transform_convert_mesh_connectivity_distance, ported below).

// MARK: - Proportional editing

/// Blender's proportional editing as one transform applies it: the operator's
/// `use_proportional_edit`, `proportional_edit_falloff`, `proportional_size` and
/// `use_proportional_connected`.
public struct ProportionalEdit: Equatable, Sendable {
    public var falloff: MeshEditor.ProportionalFalloff
    public var size: Float
    public var connected: Bool

    public init(falloff: MeshEditor.ProportionalFalloff, size: Float, connected: Bool = false) {
        self.falloff = falloff
        self.size = size
        self.connected = connected
    }

    /// `td->factor` for an unselected element `distance` away.
    ///
    /// Strictly beyond the size is 0 and exactly at it is the curve's value at
    /// 0, which is what calculatePropRatio's `rdist > prop_size` test gives —
    /// Constant keeps its 1 right up to the rim.
    public func factor(distance: Float, random: Float) -> Float {
        guard size > 0, distance.isFinite, distance <= size else { return 0 }
        return falloff.curve(max((size - distance) / size, 0), random: random)
    }

    /// The operator arguments, which are the same in both modes.
    ///
    /// Arguments, not the tool settings they are stored in. Measured in
    /// 5.2.1 headless: with `tool_settings.use_proportional_edit = True` a
    /// translate moved 1 vertex of 121 — the same as with it False — while the
    /// same values passed to the operator moved 69. tool_settings is read by
    /// the modal transform, which needs a window; the operator's own
    /// properties are read by the exec path, which is the one a bpy module
    /// runs.
    ///
    /// `use_proportional_edit` is the operator's name for it in object mode as
    /// well: measured in 5.2.1, `translate(use_proportional_edit=True)` with
    /// the selection in object mode moved the unselected cubes, and left
    /// `tool_settings.use_proportional_edit` and `…_edit_objects` both False —
    /// an exec never writes its arguments back into the tool settings, so the
    /// header's object-mode switch and this argument do not have to share a
    /// name to agree.
    ///
    /// Five decimals, as `ToolsBpy.size` writes the setting: the preview
    /// measures with the mirrored value and four places could put a vertex on
    /// the other side of the rim.
    public var operatorArguments: [String] {
        var arguments = ["use_proportional_edit=True",
                         "proportional_edit_falloff='\(falloff.bpyIdentifier)'",
                         String(format: "proportional_size=%.5f", size)]
        if connected { arguments.append("use_proportional_connected=True") }
        return arguments
    }

    /// A stand-in for Blender's random weight that holds still for the length
    /// of a drag, so the preview does not flicker. Blender seeds its generator
    /// from the clock for every transform (`BLI_time_now_seconds_i`), so no
    /// preview can show the weights a Random commit will get.
    public static func previewRandom(_ index: Int) -> Float {
        var x = UInt64(truncatingIfNeeded: index) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Float(x >> 40) / Float(1 << 24)
    }
}

public extension MeshEditor.ProportionalFalloff {
    /// calculatePropRatio's curves, over `dist` = (size − d) / size: 1 at the
    /// selection and 0 at the rim (Constant stays 1).
    func curve(_ dist: Float, random: Float) -> Float {
        let x = max(0, min(1, dist))
        switch self {
        case .sharp:         return x * x
        // Clamped as Blender clamps it: float error can take it past 1.
        case .smooth:        return min(1, 3 * x * x - 2 * x * x * x)
        case .root:          return x.squareRoot()
        case .linear:        return x
        case .constant:      return 1
        case .sphere:        return max(0, 2 * x - x * x).squareRoot()
        case .random:        return random * x
        case .inverseSquare: return x * (2 - x)
        }
    }
}

// MARK: - Mirror clipping

/// A Mirror modifier's Clipping, as every edit-mode transform applies it
/// after moving the vertices (transform_convert_clip_mirror_modifier_apply,
/// called from recalcData_mesh). Not an operator argument: it is scene state
/// the commit obeys, so the preview has to obey it too or it shows vertices
/// crossing a plane Blender then puts them back on.
///
/// Per mirrored axis, in the object's own space, a vertex whose starting
/// coordinate was within the merge distance of the plane, or whose new one is
/// on the other side of it, gets that coordinate set to 0. Measured in 5.2.1
/// headless, each with `translate`, `rotate` or `resize` and no window:
///
///   * on-plane vertices moved (0.5, 0, 0.25) kept x = 0 and moved in z;
///   * vertices at x = 0.2 moved -0.5 stopped at 0, where unclipped they
///     reached -0.3; a half turn and a resize by -1 about the origin both
///     left a vertex at x = 0.3 on the plane;
///   * the distance is `merge_threshold`, with Merge on or off: at 0.001 a
///     vertex 0.0008 from the plane was pinned and one 0.0015 away was not;
///     at 0.002 both were;
///   * a Mirror turned off in the viewport clips nothing; one hidden only in
///     edit mode still clips.
public struct MirrorClip: Equatable, Sendable {
    /// X, Y, Z: the axes the modifier mirrors across.
    public var axes: [Bool]
    /// `merge_threshold`, which Blender stores as the modifier's tolerance.
    public var tolerance: Float

    public init(axes: [Bool], tolerance: Float) {
        self.axes = axes
        self.tolerance = tolerance
    }

    /// The Mirror modifiers of a stack that clip, in stack order — the order
    /// Blender applies them in, each to the result of the one before. A
    /// Mirror with a mirror object clips in that object's space, which the
    /// record does not carry; none of the panel's rows can set one.
    public static func clipping(_ modifiers: [Modifier]) -> [MirrorClip] {
        modifiers.compactMap { m in
            guard m.kind == .mirror, m.mirrorClip, m.showInViewport,
                  m.mirrorX || m.mirrorY || m.mirrorZ else { return nil }
            return MirrorClip(axes: [m.mirrorX, m.mirrorY, m.mirrorZ], tolerance: m.mergeThreshold)
        }
    }

    /// `moved`, held to the planes, for a vertex that started at `start`.
    /// Strictly across: a vertex landing exactly on the plane is on it already.
    public func apply(start: SIMD3<Float>, moved: SIMD3<Float>) -> SIMD3<Float> {
        var p = moved
        for axis in 0..<3 where axes[axis] {
            if abs(start[axis]) <= tolerance || p[axis] * start[axis] < 0 {
                p[axis] = 0
            }
        }
        return p
    }
}

// MARK: - Auto Merge

/// Blender's Auto Merge (`use_mesh_automerge`), which an edit-mode transform
/// runs once it ends: `EDBM_automerge` from
/// `special_aftertrans_update__mesh`, with `double_threshold` as the reach.
/// Not an operator argument either — measured in 5.2.1, the headless
/// `transform.translate` the gizmo commits welds by the scene's setting — so
/// the preview welds by the same rule or it shows a mesh Blender does not
/// make.
///
/// The rule, measured in 5.2.1 headless, each vertex moved by a `translate`
/// or a `resize`:
///
///   * a moved vertex that lands within the threshold of one that did not
///     move is welded into it, and the weld stands where the unmoved one was
///     (moved to 0.9996, it merged into the vertex at 1.0, which stayed at 1.0);
///   * the reach is inclusive and the threshold's alone: moved to 0.9995 the
///     vertex merged at 0.001, to 0.9985 it did not;
///   * two unmoved vertices never weld to each other, whatever their distance
///     (0.0005 apart, both stayed);
///   * two moved vertices that end up within reach weld into the lower index
///     (squeezed together, the survivor was vertex 0's position).
///
/// That is `find_doubles` with `keep_verts` the unselected vertices (`%Hv`
/// in editmesh_automerge.cc): each moved vertex goes to the nearest kept one
/// in reach, the lowest index on a tie, and only moved vertices left over
/// are clustered among themselves (`kdtree_calc_duplicates_cb`).
public enum AutoMerge {

    /// Which vertex each vertex becomes: itself, or the one it is welded into.
    public static func targets(_ positions: [SIMD3<Float>], moved: Set<Int>,
                               threshold: Float) -> [Int] {
        let count = positions.count
        var target = Array(0..<count)
        let selected = moved.filter { $0 >= 0 && $0 < count && positions[$0].isFinite }.sorted()
        guard !selected.isEmpty, threshold >= 0, threshold.isFinite else { return target }
        let reach = threshold * threshold

        // The moved vertices, bucketed by a cell the threshold wide, so each
        // unmoved vertex asks only its own and the 26 neighbouring cells; and
        // their bounds, so a vertex nowhere near the drag asks nothing. The
        // preview runs this every frame over the whole mesh.
        let cell = max(threshold, 1e-6)
        func key(_ p: SIMD3<Float>) -> SIMD3<Int64> {
            let q = (p / cell).rounded(.down)
            let bound: Float = 1e17
            return SIMD3(Int64(min(max(q.x, -bound), bound)), Int64(min(max(q.y, -bound), bound)),
                         Int64(min(max(q.z, -bound), bound)))
        }
        var isMoved = [Bool](repeating: false, count: count)
        var buckets: [SIMD3<Int64>: [Int]] = [:]
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in selected {
            isMoved[i] = true
            buckets[key(positions[i]), default: []].append(i)
            lo = simd_min(lo, positions[i]); hi = simd_max(hi, positions[i])
        }
        lo -= SIMD3(repeating: threshold); hi += SIMD3(repeating: threshold)

        var nearest = [Float](repeating: .infinity, count: count)
        for k in 0..<count where !isMoved[k] {
            let p = positions[k]
            guard p.isFinite, p.x >= lo.x, p.y >= lo.y, p.z >= lo.z,
                  p.x <= hi.x, p.y <= hi.y, p.z <= hi.z else { continue }
            let c = key(p)
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                guard let bucket = buckets[c &+ SIMD3(Int64(dx), Int64(dy), Int64(dz))] else { continue }
                for v in bucket {
                    let d = simd_distance_squared(positions[v], p)
                    // Strictly nearer: `k` rises, so a tie keeps the lower index.
                    if d <= reach, d < nearest[v] {
                        nearest[v] = d
                        target[v] = k
                    }
                }
            }}}
        }

        // Moved vertices no unmoved one took, among themselves.
        for (n, i) in selected.enumerated() where target[i] == i && nearest[i] == .infinity {
            for j in selected[(n + 1)...] where target[j] == j && nearest[j] == .infinity {
                if simd_distance_squared(positions[i], positions[j]) <= reach {
                    target[j] = i
                    nearest[j] = 0
                }
            }
        }
        return target
    }

    /// `mesh` with the welds made: triangles that lost a corner to a weld are
    /// gone, as the faces Blender's weld collapses are.
    public static func weld(_ mesh: MeshData, moved: Set<Int>, threshold: Float) -> MeshData {
        let target = targets(mesh.vertices.map(\.position), moved: moved, threshold: threshold)
        guard target.indices.contains(where: { target[$0] != $0 }) else { return mesh }
        var newIndex = [Int](repeating: -1, count: target.count)
        var kept: [MeshVertex] = []
        for i in target.indices where target[i] == i {
            newIndex[i] = kept.count
            kept.append(mesh.vertices[i])
        }
        func remap(_ i: UInt32) -> UInt32? {
            let t = Int(i) < target.count ? newIndex[target[Int(i)]] : -1
            return t >= 0 ? UInt32(t) : nil
        }
        if mesh.indices.isEmpty {
            var seen = Set<UInt64>()
            var edges: [UInt32] = []
            for e in stride(from: 0, to: mesh.edges.count - 1, by: 2) {
                guard let a = remap(mesh.edges[e]), let b = remap(mesh.edges[e + 1]), a != b,
                      seen.insert(UInt64(min(a, b)) << 32 | UInt64(max(a, b))).inserted else { continue }
                edges += [a, b]
            }
            return MeshData(vertices: kept, wireEdges: edges)
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            guard let a = remap(mesh.indices[t]), let b = remap(mesh.indices[t + 1]),
                  let c = remap(mesh.indices[t + 2]), a != b, b != c, a != c else { continue }
            indices += [a, b, c]
        }
        var result = MeshData(vertices: kept, indices: indices)
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

// MARK: - The operation

/// One `bpy.ops.transform` call, as the values it acts on.
public struct TransformOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A world-space vector.
        case translate(SIMD3<Float>)
        /// About a world-space axis, in radians.
        case rotate(axis: SIMD3<Float>, angle: Float)
        /// Factors along the orientation's three axes.
        case resize(SIMD3<Float>)
    }

    public enum Pivot: Equatable, Sendable {
        /// `center_override`.
        case point(SIMD3<Float>)
        /// Each object about its own origin — Blender's Individual Origins,
        /// which no single `center_override` can say. Object mode only; edit
        /// mode takes the median.
        case individualOrigins
        /// No `center_override` at all. Measured in 5.2.1 with no View3D:
        /// every `transform_pivot_point` turned cubes at x = 0, 4 and 10 about
        /// x = 5, the centre of their bounds.
        case boundsCentre
    }

    public enum Orientation: Equatable, Sendable {
        case global
        /// `orient_type='LOCAL'`: each object's own axes in object mode — the
        /// measured behaviour for a selection of rotated objects — and the
        /// edited object's axes in edit mode.
        case local
    }

    public var kind: Kind
    public var pivot: Pivot
    public var orientation: Orientation
    public var proportional: ProportionalEdit?

    public init(kind: Kind, pivot: Pivot, orientation: Orientation = .global,
                proportional: ProportionalEdit? = nil) {
        self.kind = kind
        self.pivot = pivot
        self.orientation = orientation
        self.proportional = proportional
    }
}

/// An object's transform as the display cache holds it: world location, XYZ
/// Euler, scale.
public struct ObjectPose: Equatable, Sendable {
    public var location: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var scale: SIMD3<Float>

    public init(location: SIMD3<Float>, rotation: SIMD3<Float>, scale: SIMD3<Float>) {
        self.location = location
        self.rotation = rotation
        self.scale = scale
    }

    public init(_ object: BKObject) {
        self.init(location: object.location, rotation: object.rotation, scale: object.scale)
    }

    /// The object's own axes, normalised: Blender's `td->axismtx`.
    var axes: simd_float3x3 { simd_float3x3(simd_float4x4(eulerXYZ: rotation)) }
}

public extension TransformOperation {

    // MARK: object mode

    /// The factor proportional editing gives each unselected object: by the
    /// world distance from its origin to the nearest selected origin, which
    /// is `set_prop_dist` over objects' centres.
    static func objectFactors(selected: [SIMD3<Float>], neighbours: [SIMD3<Float>],
                              proportional: ProportionalEdit) -> [Float] {
        neighbours.enumerated().map { index, p in
            let d = selected.map { simd_distance($0, p) }.min() ?? .infinity
            return proportional.factor(distance: d, random: ProportionalEdit.previewRandom(index))
        }
    }

    /// Object mode: the new pose of each object, given its factor — 1 for the
    /// selection, the proportional weight for a neighbour.
    func apply(to poses: [ObjectPose], factors: [Float],
               selectedLocations: [SIMD3<Float>]) -> [ObjectPose] {
        let centre: SIMD3<Float>?
        switch pivot {
        case .point(let p):        centre = p
        case .individualOrigins:   centre = nil
        case .boundsCentre:        centre = Self.boundsCentre(selectedLocations)
        }
        return zip(poses, factors).map { pose, f in
            guard f > 0 else { return pose }
            var next = pose
            let c = centre ?? pose.location
            switch kind {
            case .translate(let d):
                next.location += d * f
            case .rotate(let axis, let angle):
                let r = simd_float3x3(rotationAbout: axis, angle: angle * f)
                next.location = c + r * (pose.location - c)
                next.rotation = (r * pose.axes).eulerXYZ
            case .resize(let v):
                let t = resizeMatrix(v, axes: orientation == .local ? pose.axes : matrix_identity_float3x3)
                // TransMat3ToSize(tmat · axismtx, axismtx): the length each of
                // the object's own axes comes out at, signed by whether it
                // flipped.
                let own = pose.axes
                var s = SIMD3<Float>(repeating: 1)
                for i in 0..<3 {
                    let column = t * own[i]
                    s[i] = simd_length(column) * (simd_dot(column, own[i]) < 0 ? -1 : 1)
                }
                next.scale = pose.scale * (1 + (s - 1) * f)
                next.location = pose.location + (t * (pose.location - c) - (pose.location - c)) * f
            }
            return next
        }
    }

    // MARK: edit mode

    /// The factor proportional editing gives each vertex: 1 for the selection,
    /// the curve of the distance to the nearest selected vertex — in world
    /// space, or along the surface with Connected Only — for the rest.
    ///
    /// `hidden` (Blender's `mesh.hide`) get 0: Blender leaves a hidden vertex
    /// out of the transform altogether (measured in 5.2.1: one hidden beside
    /// the selection on a grid stayed put under a LINEAR move of size 3 that
    /// lifted every other vertex, Connected Only or not).
    ///
    /// `symmetry` takes its followers out: Blender does not transform a vertex
    /// that mirrors another (it is TransDataMirror, not TransData), so it gets
    /// 0 here and `SymmetricEdit.apply` places it. A selected follower is not
    /// one of the selected TransData `set_prop_dist` measures from either —
    /// but Connected Only's distances are seeded from every selected vertex
    /// (`transform_convert_mesh_connectivity_distance` reads BM_ELEM_SELECT
    /// before the mirror is worked out), so there they still count.
    static func vertexFactors(positions: [SIMD3<Float>], selected: Set<Int>,
                              model: simd_float4x4, proportional: ProportionalEdit?,
                              connectivity: MeshConnectivity?,
                              hidden: Set<Int> = [],
                              symmetry: SymmetricEdit? = nil) -> [Float] {
        var factors = [Float](repeating: 0, count: positions.count)
        let followers = symmetry?.followerSet ?? []
        let transformed = followers.isEmpty ? selected : selected.subtracting(followers)
        for i in transformed where i < factors.count { factors[i] = 1 }
        guard let proportional, !transformed.isEmpty else { return factors }
        // `td->mtx`: the object's 3×3, so distances are world-sized without
        // the translation, which cancels in a difference anyway.
        let m = simd_float3x3(model)
        let scaled = positions.map { m * $0 }
        let distances: [Float]
        if proportional.connected {
            // With no connectivity nothing is reachable, which is what Blender
            // does for a vertex no edge leads to.
            distances = connectivity?.distances(from: selected, positions: scaled)
                ?? [Float](repeating: .infinity, count: positions.count)
        } else {
            distances = nearestDistances(from: transformed, positions: scaled,
                                         within: proportional.size)
        }
        for i in positions.indices
        where !selected.contains(i) && !hidden.contains(i) && !followers.contains(i) {
            factors[i] = proportional.factor(distance: distances[i],
                                             random: ProportionalEdit.previewRandom(i))
        }
        return factors
    }

    /// Edit mode: the new local position of every vertex, given its factor,
    /// then held to the Mirror modifiers that clip (`MirrorClip`), then
    /// mirrored by the mesh's symmetry (`SymmetricEdit`) — the order of
    /// recalcData_mesh, which clips first so a follower copies a clipped
    /// source.
    func apply(toVertices positions: [SIMD3<Float>], factors: [Float],
               selected: Set<Int>, model: simd_float4x4,
               clipping: [MirrorClip] = [], hidden: Set<Int> = [],
               symmetry: SymmetricEdit? = nil) -> [SIMD3<Float>] {
        // Nothing left to transform: Blender cancels, and nothing moves.
        if symmetry?.cancels == true { return positions }
        var out = moved(positions, factors: factors, selected: selected, model: model)
        if !clipping.isEmpty {
            // Blender's TransData: the selection, or with proportional editing
            // every vertex, even one it does not move (createTransEditVerts) —
            // measured, a vertex 0.0005 from the plane and far out of reach was
            // pinned to it by a proportional move, and not by a plain one. A
            // hidden vertex is never in it, so never clipped, and neither is a
            // symmetry follower, which `symmetry` places below.
            let followers = symmetry?.followerSet ?? []
            for i in out.indices
            where (proportional != nil || selected.contains(i)) && !hidden.contains(i) && !followers.contains(i) {
                for clip in clipping { out[i] = clip.apply(start: positions[i], moved: out[i]) }
            }
        }
        symmetry?.apply(to: &out)
        return out
    }

    private func moved(_ positions: [SIMD3<Float>], factors: [Float],
                       selected: Set<Int>, model: simd_float4x4) -> [SIMD3<Float>] {
        let inverse = model.inverse
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { (model * SIMD4(p, 1)).xyz }
        let centre: SIMD3<Float>
        switch pivot {
        case .point(let p):
            centre = p
        case .individualOrigins:
            // No per-island origin here: the median, where the gizmo sits.
            let points = selected.filter { $0 < positions.count }.map { world(positions[$0]) }
            centre = points.isEmpty ? .zero : points.reduce(.zero, +) / Float(points.count)
        case .boundsCentre:
            centre = Self.boundsCentre(selected.filter { $0 < positions.count }.map { world(positions[$0]) })
        }
        // The edited object's own axes, normalised, for a LOCAL resize.
        let local = simd_float3x3(normalize(model.columns.0.xyz),
                                  normalize(model.columns.1.xyz),
                                  normalize(model.columns.2.xyz))
        var out = positions
        for i in positions.indices {
            let f = i < factors.count ? factors[i] : 0
            guard f > 0 else { continue }
            let w = world(positions[i])
            let moved: SIMD3<Float>
            switch kind {
            case .translate(let d):
                moved = w + d * f
            case .rotate(let axis, let angle):
                moved = centre + simd_float3x3(rotationAbout: axis, angle: angle * f) * (w - centre)
            case .resize(let v):
                let t = resizeMatrix(v, axes: orientation == .local ? local : matrix_identity_float3x3)
                moved = w + (t * (w - centre) - (w - centre)) * f
            }
            out[i] = (inverse * SIMD4(moved, 1)).xyz
        }
        return out
    }

    // MARK: pieces

    /// A scale along three axes, in world space: A · diag(v) · Aᵀ.
    private func resizeMatrix(_ v: SIMD3<Float>, axes a: simd_float3x3) -> simd_float3x3 {
        a * simd_float3x3(diagonal: v) * a.transpose
    }

    static func boundsCentre(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard var lo = points.first else { return .zero }
        var hi = lo
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo + hi) * 0.5
    }

    /// For every point, the distance to the nearest selected one — or
    /// infinity when that is beyond `radius`, which gets a factor of 0 either
    /// way. A k-d tree over the selection, as `set_prop_dist` builds one: this
    /// runs once per drag, on the main thread, and a heavy mesh with half its
    /// vertices selected is millions of pairs done the naive way.
    static func nearestDistances(from selected: Set<Int>, positions: [SIMD3<Float>],
                                 within radius: Float) -> [Float] {
        var out = [Float](repeating: .infinity, count: positions.count)
        let seeds = selected.filter { $0 < positions.count }.map { positions[$0] }
        guard !seeds.isEmpty, radius > 0 else { return out }
        for i in selected where i < out.count { out[i] = 0 }
        let tree = PointTree(seeds)
        for i in positions.indices where !selected.contains(i) {
            if let d = tree.nearest(to: positions[i], within: radius) { out[i] = d }
        }
        return out
    }
}

/// A static k-d tree: the points sorted in place so that each range's middle
/// element splits it on one axis.
struct PointTree {
    private var points: [SIMD3<Float>]

    init(_ points: [SIMD3<Float>]) {
        self.points = points
        build(0, points.count, 0)
    }

    private mutating func build(_ lo: Int, _ hi: Int, _ depth: Int) {
        guard hi - lo > 1 else { return }
        let axis = depth % 3
        points[lo..<hi].sort { $0[axis] < $1[axis] }
        let mid = (lo + hi) / 2
        build(lo, mid, depth + 1)
        build(mid + 1, hi, depth + 1)
    }

    /// The distance to the nearest point no further than `radius`, or nil.
    func nearest(to q: SIMD3<Float>, within radius: Float) -> Float? {
        // Squared, and inclusive of the rim: a factor is still owed there.
        var best = radius * radius
        var found = false
        func search(_ lo: Int, _ hi: Int, _ depth: Int) {
            guard lo < hi else { return }
            let mid = (lo + hi) / 2
            let p = points[mid]
            let d = simd_distance_squared(p, q)
            if d <= best { best = d; found = true }
            let axis = depth % 3
            let diff = q[axis] - p[axis]
            if diff < 0 {
                search(lo, mid, depth + 1)
                if diff * diff <= best { search(mid + 1, hi, depth + 1) }
            } else {
                search(mid + 1, hi, depth + 1)
                if diff * diff <= best { search(lo, mid, depth + 1) }
            }
        }
        search(0, points.count, 0)
        return found ? best.squareRoot() : nil
    }
}

// MARK: - Connected Only

/// A mesh's edges and faces as Blender's edit mesh has them, for measuring
/// Connected Only's distance along the surface.
///
/// The viewport holds triangles, and a quad's diagonal is not one of
/// Blender's edges. When the mirror has said which edges are real and which
/// polygon each triangle came from (`EditTopology`), this rebuilds Blender's
/// polygons from them; otherwise every triangle is a face and every triangle
/// edge an edge.
public struct MeshConnectivity: Sendable {
    public private(set) var edges: [SIMD2<Int32>] = []
    /// Each face's vertices.
    public private(set) var faces: [[Int]] = []
    var edgeFaces: [[Int]] = []
    var vertexEdges: [[Int]] = []

    public init(mesh: MeshData, topology: EditTopology?) {
        let triangleCount = mesh.indices.count / 3
        let edgeCount = mesh.edges.count / 2
        let known = topology.flatMap { $0.describes(mesh) ? $0 : nil }
        var edgeList: [SIMD2<Int32>] = []
        for e in 0..<edgeCount {
            if let known, !known.realEdges.isEmpty, !known.realEdges.contains(e) { continue }
            edgeList.append(SIMD2(Int32(mesh.edges[2 * e]), Int32(mesh.edges[2 * e + 1])))
        }
        var faceList: [[Int]] = []
        if let known, known.trianglePolygons.count == triangleCount {
            var byPolygon: [UInt32: Int] = [:]
            for t in 0..<triangleCount {
                let p = known.trianglePolygons[t]
                let index: Int
                if let existing = byPolygon[p] {
                    index = existing
                } else {
                    index = faceList.count
                    byPolygon[p] = index
                    faceList.append([])
                }
                for k in 0..<3 {
                    let v = Int(mesh.indices[3 * t + k])
                    if !faceList[index].contains(v) { faceList[index].append(v) }
                }
            }
        } else {
            for t in 0..<triangleCount {
                faceList.append((0..<3).map { Int(mesh.indices[3 * t + $0]) })
            }
        }
        self.init(edges: edgeList, faces: faceList, vertexCount: mesh.vertices.count)
    }

    /// Every triangle a face, every triangle edge an edge.
    public init(triangles: [UInt32], vertexCount: Int) {
        var seen = Set<UInt64>()
        var edgeList: [SIMD2<Int32>] = []
        var faceList: [[Int]] = []
        for t in 0..<(triangles.count / 3) {
            let v = (0..<3).map { Int(triangles[3 * t + $0]) }
            faceList.append(v)
            for k in 0..<3 {
                let a = v[k], b = v[(k + 1) % 3]
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if seen.insert(key).inserted { edgeList.append(SIMD2(Int32(a), Int32(b))) }
            }
        }
        self.init(edges: edgeList, faces: faceList, vertexCount: vertexCount)
    }

    public init(edges: [SIMD2<Int32>], faces: [[Int]], vertexCount: Int) {
        self.edges = edges
        self.faces = faces
        vertexEdges = Array(repeating: [], count: vertexCount)
        var byEnds: [UInt64: Int] = [:]
        for (e, pair) in edges.enumerated() {
            let a = Int(pair.x), b = Int(pair.y)
            guard a < vertexCount, b < vertexCount else { continue }
            vertexEdges[a].append(e)
            vertexEdges[b].append(e)
            byEnds[UInt64(min(a, b)) << 32 | UInt64(max(a, b))] = e
        }
        edgeFaces = Array(repeating: [], count: edges.count)
        // An edge belongs to a face when both its ends are corners of it. The
        // face's own loop order is not in a triangle list, and for the
        // polygons a mesh editor makes the two agree.
        for (f, corners) in faces.enumerated() {
            for i in corners.indices {
                for j in corners.indices where j > i {
                    let a = corners[i], b = corners[j]
                    if let e = byEnds[UInt64(min(a, b)) << 32 | UInt64(max(a, b))] {
                        edgeFaces[e].append(f)
                    }
                }
            }
        }
    }

    /// transform_convert_mesh_connectivity_distance, ported: the distance from
    /// the selection along edges and across faces, by front propagation that
    /// estimates a geodesic across each triangle rather than walking edges
    /// alone. `positions` are already in world scale (`mtx · co`).
    ///
    /// The queues are LIFO, as BLI_LINKSTACK is, so the order the front
    /// advances in is Blender's for the same edge order.
    public func distances(from selected: Set<Int>, positions: [SIMD3<Float>]) -> [Float] {
        let n = positions.count
        var dists = [Float](repeating: .greatestFiniteMagnitude, count: n)
        for i in selected where i < n { dists[i] = 0 }
        guard !edges.isEmpty else { return dists.map { $0 == .greatestFiniteMagnitude ? .infinity : $0 } }

        let loose = edgeFaces.map(\.isEmpty)
        var queued = [Bool](repeating: false, count: edges.count)
        var queue: [Int] = []
        var next: [Int] = []
        for (e, pair) in edges.enumerated() {
            let a = Int(pair.x), b = Int(pair.y)
            guard a < n, b < n else { continue }
            if dists[a] != .greatestFiniteMagnitude || dists[b] != .greatestFiniteMagnitude {
                queue.append(e)
            }
        }

        func other(_ e: Int, _ v: Int) -> Int {
            Int(edges[e].x) == v ? Int(edges[e].y) : Int(edges[e].x)
        }
        /// bmesh_test_dist_add.
        func testAdd(_ v0: Int, _ v1: Int, _ v2: Int?) -> Bool {
            guard !selected.contains(v0), dists[v0] > dists[v1] else { return false }
            let d: Float
            if let v2 {
                guard dists[v0] > dists[v2] else { return false }
                d = Self.geodesicAcrossTriangle(positions[v0], positions[v1], positions[v2],
                                                dists[v1], dists[v2])
            } else {
                d = dists[v1] + simd_length(positions[v1] - positions[v0])
            }
            if d < dists[v0] {
                dists[v0] = d
                return true
            }
            return false
        }

        repeat {
            while let e = queue.popLast() {
                var v1 = Int(edges[e].x), v2 = Int(edges[e].y)
                guard v1 < n, v2 < n else { continue }
                if loose[e] || dists[v1] == .greatestFiniteMagnitude
                    || dists[v2] == .greatestFiniteMagnitude {
                    // Along the edge, from the nearer end to the further.
                    if dists[v1] > dists[v2] { swap(&v1, &v2) }
                    if testAdd(v2, v1, nil) {
                        let direct = loose[e] || selected.contains(v1) || selected.contains(v2)
                        for eo in vertexEdges[v2] where eo != e && !queued[eo]
                            && (direct || loose[eo]
                                || dists[other(eo, v2)] != .greatestFiniteMagnitude) {
                            queued[eo] = true
                            next.append(eo)
                        }
                    }
                }
                if !loose[e] {
                    // Across the edge, to the rest of each face beside it.
                    for f in edgeFaces[e] {
                        for vo in faces[f] where vo != v1 && vo != v2 && vo < n {
                            guard testAdd(vo, v1, v2) else { continue }
                            for eo in vertexEdges[vo] where eo != e && !queued[eo]
                                && (loose[eo] || dists[other(eo, vo)] != .greatestFiniteMagnitude) {
                                queued[eo] = true
                                next.append(eo)
                            }
                        }
                    }
                }
            }
            for e in next { queued[e] = false }
            queue = next
            next = []
        } while !queue.isEmpty

        return dists.map { $0 == .greatestFiniteMagnitude ? .infinity : $0 }
    }

    /// geodesic_distance_propagate_across_triangle (math_geom.cc): the
    /// distance to `v0` from a virtual source placed so that it is `dist1`
    /// from `v1` and `dist2` from `v2`, when the straight line from it to `v0`
    /// crosses the edge; Dijkstra along the two edges otherwise.
    static func geodesicAcrossTriangle(_ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>,
                                       _ dist1: Float, _ dist2: Float) -> Float {
        let v10 = v0 - v1
        let v12 = v2 - v1
        if dist1 != 0, dist2 != 0 {
            let d12 = simd_length(v12)
            if d12 * d12 > 0 {
                let u = v12 / d12
                let n = simd_normalize(simd_cross(v12, v10))
                let v = simd_cross(n, u)
                let p0 = SIMD2<Float>(simd_dot(v10, u), abs(simd_dot(v10, v)))
                let a = 0.5 * (1 + (dist1 * dist1 - dist2 * dist2) / (d12 * d12))
                let hh = dist1 * dist1 - a * a * d12 * d12
                if hh > 0 {
                    let h = hh.squareRoot()
                    let s = SIMD2<Float>(a * d12, -h)
                    let intercept = s.x + h * (p0.x - s.x) / (p0.y + h)
                    if intercept >= 0, intercept <= d12 {
                        return simd_distance(s, p0)
                    }
                }
            }
        }
        return min(dist1 + simd_length(v10), dist2 + simd_distance(v0, v2))
    }
}

// MARK: - The simulator's operators

public extension BKObject {
    /// The mesh an edit-mode transform moves: Blender's edit mesh, which the
    /// modifier stack runs over, and never the stack's output.
    ///
    /// On device `mesh` is Blender's evaluated mesh and is installed as it
    /// is, so that is what the preview paints. In the simulator `mesh` is
    /// `ModifierStack`'s output, and moving it then handing it back through
    /// `setMirroredMesh` ran the stack over it a second time. Measured on a
    /// cube (24 vertices) with a Mirror X and Clipping, one vertex picked
    /// (tests/tools/main.swift, "the simulator edits the mesh its modifier
    /// stack runs over"): the preview showed 95 vertices over a base of 48,
    /// the roll-back left 96, and the commit plus two more translates reached
    /// 761 over a base of 381. With no stack the two are the same mesh, and
    /// `mesh` is kept so nothing else changes.
    ///
    /// A selection index past the base's count is a vertex only the stack
    /// made — a Mirror's image, an Array's copy. Blender's cage has no such
    /// vertex to move, and neither does this: the transform, its factors and
    /// the gizmo's pivot all skip indices beyond `vertices.count`.
    var editCage: MeshData {
        meshIsEvaluated || modifiers.isEmpty ? mesh : evaluatedBase
    }

    /// Puts a transformed `editCage` back the way this object's mesh came
    /// in: as Blender's evaluated mesh on device, and in the simulator as
    /// the new base the stack runs over once. `setMirroredMesh` over the
    /// evaluated mesh would be the double application 5250eed took out of
    /// the mirror.
    func installTransformed(_ cage: MeshData) {
        if meshIsEvaluated {
            setEvaluatedMesh(cage)
        } else {
            setMirroredMesh(cage)
        }
    }
}

public extension TransformOperation {
    /// What the simulator's `bpy.ops.transform.translate / rotate / resize`
    /// send (`_TransformOps` in Resources/python/site/bpy/__init__.py), already
    /// reduced to world-space values:
    ///
    ///     {"kind": "rotate", "value": [0.5], "axis": [0, 0, 1],
    ///      "orientation": "GLOBAL", "center": [1, 2, 3] | null,
    ///      "proportional": {"falloff": "SMOOTH", "size": 1, "connected": false} | null}
    ///
    /// Nil for anything malformed or unknown, which the stand-in reports.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String,
              let value = (object["value"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.floatValue })
        else { return nil }
        func vector(_ key: String) -> SIMD3<Float>? {
            guard let v = (object[key] as? [Any])?.compactMap({ ($0 as? NSNumber)?.floatValue }),
                  v.count == 3 else { return nil }
            return SIMD3(v[0], v[1], v[2])
        }
        let operationKind: Kind
        switch kind {
        case "translate":
            guard value.count == 3 else { return nil }
            operationKind = .translate(SIMD3(value[0], value[1], value[2]))
        case "rotate":
            guard value.count == 1, let axis = vector("axis"), simd_length(axis) > 0 else { return nil }
            operationKind = .rotate(axis: axis, angle: value[0])
        case "resize":
            guard value.count == 3 else { return nil }
            operationKind = .resize(SIMD3(value[0], value[1], value[2]))
        default:
            return nil
        }
        let orientation: Orientation
        switch object["orientation"] as? String ?? "GLOBAL" {
        case "GLOBAL": orientation = .global
        case "LOCAL":  orientation = .local
        default:       return nil
        }
        var proportional: ProportionalEdit?
        if let p = object["proportional"] as? [String: Any] {
            guard let name = p["falloff"] as? String,
                  let falloff = MeshEditor.ProportionalFalloff.allCases.first(where: { $0.bpyIdentifier == name }),
                  let size = (p["size"] as? NSNumber)?.floatValue
            else { return nil }
            proportional = ProportionalEdit(falloff: falloff, size: size,
                                            connected: (p["connected"] as? Bool) ?? false)
        }
        self.init(kind: operationKind,
                  pivot: vector("center").map(Pivot.point) ?? .boundsCentre,
                  orientation: orientation, proportional: proportional)
    }
}

public extension BKScene {
    /// The simulator's `bpy.ops.transform.*`: the operation the gizmo
    /// previewed, applied to the scene the same way, so a drag commits what
    /// it showed there too. Edit mode moves the selected vertices of the
    /// active object; object mode moves the selection, and with proportional
    /// editing the visible objects in reach. Returns how many selected
    /// elements it moved.
    @discardableResult
    func perform(_ operation: TransformOperation) -> Int {
        if mode == .edit {
            guard let obj = active, !editSelection.vertices.isEmpty else { return 0 }
            let cage = obj.editCage
            let positions = cage.vertices.map(\.position)
            let model = obj.modelMatrix
            let selected = editSelection.vertices.filter { $0 < positions.count }
            guard !selected.isEmpty else { return 0 }
            let connectivity = operation.proportional?.connected == true
                ? MeshConnectivity(mesh: cage, topology: obj.editTopology) : nil
            let hidden = obj.hiddenEditVertices
            let factors = TransformOperation.vertexFactors(positions: positions, selected: selected,
                                                           model: model,
                                                           proportional: operation.proportional,
                                                           connectivity: connectivity, hidden: hidden)
            // Clipping is the edited object's, read here as Blender reads it
            // from the object, not passed with the operator.
            let moved = operation.apply(toVertices: positions, factors: factors,
                                        selected: selected, model: model,
                                        clipping: MirrorClip.clipping(obj.modifiers), hidden: hidden)
            var mesh = cage
            for i in mesh.vertices.indices { mesh.vertices[i].position = moved[i] }
            ModifierStack.recomputeNormals(&mesh, welded: true)
            // Blender reads Auto Merge from the scene, as it reads Clipping
            // from the object; the preview welds by the same call.
            if tools.autoMerge {
                mesh = AutoMerge.weld(mesh, moved: selected, threshold: tools.mergeThreshold)
            }
            obj.installTransformed(mesh)
            return selected.count
        }
        let targets = objects.filter { selection.contains($0.id) && $0.visible }
        guard !targets.isEmpty else { return 0 }
        var others: [BKObject] = []
        var factors = [Float](repeating: 1, count: targets.count)
        if let proportional = operation.proportional {
            let candidates = objects.filter { !selection.contains($0.id) && $0.visible }
            let weights = TransformOperation.objectFactors(selected: targets.map(\.location),
                                                           neighbours: candidates.map(\.location),
                                                           proportional: proportional)
            for (object, weight) in zip(candidates, weights) where weight > 0 {
                others.append(object)
                factors.append(weight)
            }
        }
        let everyone = targets + others
        let poses = operation.apply(to: everyone.map { ObjectPose($0) }, factors: factors,
                                    selectedLocations: targets.map(\.location))
        for (object, pose) in zip(everyone, poses) {
            if object.location != pose.location { object.location = pose.location }
            if object.rotation != pose.rotation { object.rotation = pose.rotation }
            if object.scale != pose.scale { object.scale = pose.scale }
        }
        return targets.count
    }
}

// MARK: - Snapping during a drag

/// Blender's Increment and Grid snapping, computed here because a headless
/// Blender cannot: its exec path takes the operator's `value` as final
/// (`T_INPUT_IS_VALUES_FINAL`) and never reaches the snapping code, which is
/// why `translate(value=(0.3,0,0), snap=True, snap_elements={'INCREMENT'})`
/// measured 0.3. So the drag snaps its own result, and the commit sends the
/// snapped value — one vector for the whole selection, as Blender moves it.
///
/// From transform_snap.cc and transform_snap_object.cc (5.3):
///
///   * Increment is relative. The drag's value is rounded to multiples of
///     the step in the constraint's own axes, or in world axes with no
///     constraint (`transform_snap_increment_ex`). A rotation rounds its angle
///     to `snap_angle_increment_3d`, a resize its factors to 0.1.
///   * Grid is absolute, and moves only. The Snap With point — the median
///     for Closest and Median, the pivot for Center, the active object for
///     Active — lands on a grid point: with a constraint, the one nearest
///     `pivot + drag`, projected back onto the constraint; with none, the one
///     under the pointer on the first world plane its ray meets, the ground
///     first. When both are chosen Grid wins, because a grid target is always
///     found and Increment only applies when nothing was.
///   * A vertex, edge or face in reach (`GeometrySnap`) wins over both:
///     Blender tries the grid only when no geometry was found
///     (`snap_object_project_view3d_ex`).
public struct TransformSnap: Equatable, Sendable {
    public var grid: Bool
    public var increment: Bool
    public var target: SnapTarget
    /// The app's increment: Blender takes it from the 3D View's grid, which
    /// this app does not have (ViewportOptions.snapIncrement).
    public var step: Float

    /// `tool_settings.snap_angle_increment_3d`'s factory value, measured in
    /// 5.2.1 as 0.0872665 rad. Not mirrored: nothing in the app changes it.
    public static let angleStep: Float = 5 * .pi / 180
    /// transform_mode_resize.cc: `t->increment = float3(0.1f)`.
    public static let scaleStep: Float = 0.1

    /// Nil when neither is on: the magnet is off, or only geometry elements
    /// are chosen, which `GeometrySnap` handles.
    public init?(tools: TransformToolSettings, step: Float) {
        guard tools.useSnap else { return nil }
        let grid = tools.elements.contains(.grid)
        let increment = tools.elements.contains(.increment)
        guard grid || increment, step > 0 else { return nil }
        self.grid = grid
        self.increment = increment
        self.target = tools.target
        self.step = step
    }

    public enum Constraint: Equatable, Sendable {
        case axis(Int)
        /// Named for its normal, as the gizmo names its planes.
        case plane(Int)
        case free
    }

    /// Rounds half away from zero, as `roundf` and `math::round` do.
    private static func round(_ x: Float, _ step: Float) -> Float {
        (x / step).rounded(.toNearestOrAwayFromZero) * step
    }

    private static func round(_ v: SIMD3<Float>, _ step: Float) -> SIMD3<Float> {
        SIMD3(round(v.x, step), round(v.y, step), round(v.z, step))
    }

    /// A translate: the snapped vector for the whole selection.
    ///
    /// `ray` is the pointer's, for a free drag onto the grid.
    public func translate(_ delta: SIMD3<Float>, constraint: Constraint,
                          axes: [SIMD3<Float>], pivot: SIMD3<Float>, source: SIMD3<Float>,
                          ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)?,
                          viewNormal: SIMD3<Float>) -> SIMD3<Float> {
        if grid {
            switch constraint {
            case .axis(let i):
                let v = Self.round(pivot + delta, step) - source
                return axes[i] * simd_dot(v, axes[i])
            case .plane(let i):
                let v = Self.round(pivot + delta, step) - source
                return v - axes[i] * simd_dot(v, axes[i])
            case .free:
                if let ray, let hit = Self.gridPlaneHit(ray, source: source, viewNormal: viewNormal) {
                    return Self.round(hit, step) - source
                }
                return Self.round(pivot + delta, step) - source
            }
        }
        guard increment else { return delta }
        switch constraint {
        case .axis(let i):
            return axes[i] * Self.round(simd_dot(delta, axes[i]), step)
        case .plane(let i):
            var v = SIMD3<Float>.zero
            for j in 0..<3 where j != i {
                v += axes[j] * Self.round(simd_dot(delta, axes[j]), step)
            }
            return v
        case .free:
            return Self.round(delta, step)
        }
    }

    /// snap_grid's planes, in its order: the ground, then the other two world
    /// planes — the one the ray runs across least first — then the view plane
    /// through the snap source.
    private static func gridPlaneHit(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                     source: SIMD3<Float>,
                                     viewNormal: SIMD3<Float>) -> SIMD3<Float>? {
        let d = ray.direction
        var planes: [(normal: SIMD3<Float>, point: SIMD3<Float>)] = [(SIMD3(0, 0, 1), .zero)]
        if abs(d.x) < abs(d.y) {
            planes += [(SIMD3(0, 1, 0), .zero), (SIMD3(1, 0, 0), .zero)]
        } else {
            planes += [(SIMD3(1, 0, 0), .zero), (SIMD3(0, 1, 0), .zero)]
        }
        planes.append((viewNormal, source))
        for plane in planes {
            let denom = simd_dot(d, plane.normal)
            guard abs(denom) > 1e-8 else { continue }
            let t = simd_dot(plane.point - ray.origin, plane.normal) / denom
            if t > 0 { return ray.origin + d * t }
        }
        return nil
    }

    /// A rotation's angle. Grid has no effect here: Blender turns the
    /// selection toward a grid point under the pointer, which is not
    /// reproduced, so a rotation snaps only with Increment chosen.
    public func angle(_ a: Float) -> Float {
        increment ? Self.round(a, Self.angleStep) : a
    }

    /// A resize's factors, likewise.
    public func factors(_ f: SIMD3<Float>) -> SIMD3<Float> {
        increment ? Self.round(f, Self.scaleStep) : f
    }
}

// MARK: - Matrix helpers the preview and the stand-in share

public extension simd_float3x3 {
    /// Rodrigues' rotation, so an arbitrary world axis works and not just X/Y/Z.
    init(rotationAbout axis: SIMD3<Float>, angle: Float) {
        let a = normalize(axis)
        let c = cos(angle), s = sin(angle), t = 1 - c
        self.init(SIMD3(t * a.x * a.x + c,       t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y),
                  SIMD3(t * a.x * a.y - s * a.z, t * a.y * a.y + c,       t * a.y * a.z + s * a.x),
                  SIMD3(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c))
    }

    init(_ m: simd_float4x4) {
        self.init(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)
    }

    /// The inverse of `simd_float4x4(eulerXYZ:)`, which composes Rz·Ry·Rx.
    var eulerXYZ: SIMD3<Float> {
        // columns[col][row], so m(row, col) is columns[col][row].
        let m20 = columns.0[2], m21 = columns.1[2], m22 = columns.2[2]
        let m10 = columns.0[1], m00 = columns.0[0]
        let m12 = columns.2[1], m11 = columns.1[1]
        let sy = max(-1, min(1, -m20))
        let y = asin(sy)
        // At |sy| = 1 the X and Z rotations act on the same axis; Blender folds
        // the pair onto X and zeroes Z, and so do we.
        if abs(m20) < 0.99999 {
            return SIMD3(atan2(m21, m22), y, atan2(m10, m00))
        }
        return SIMD3(atan2(-m12, m11), y, 0)
    }
}
