import Foundation
import simd

// Blender's X / Y / Z mirror editing, as one edit-mode transform applies it.
//
// With a mesh's `use_mirror_x` on, Blender's Move moves the vertex you hold
// and its reflection across the object's own X = 0 plane. Nothing about that
// is in the operator's arguments except `mirror=True`: the axes are the mesh's
// flags, and which vertex reflects which is worked out when the transform
// starts. A headless Blender — the bpy an iPad has — does it only when told:
// with no 3D View `initTransInfo` sets T_NO_MIRROR unless `mirror` is passed
// (transform_generics.cc). Measured in 5.2.1 on a 4 × 4 grid with
// `use_mirror_x` on: the gizmo's translate moved 1 vertex; with `mirror=True`
// it moved that one and its mirror image, x negated.
//
// The gizmo previews a drag by painting the display cache, so the preview has
// to find the same pairs Blender will and move them the same way, or the
// release puts back what the drag showed — the defect this app keeps shipping.
// This is that computation, ported from the 5.3 source beside this repository
// (transform_convert_mesh.cc, editmesh_utils.cc, mesh_mirror.cc) and held to
// Blender 5.2.1 by scripts/run-symmetry-blender-check.sh:
//
//   * transform_convert_mesh_mirrordata_calc: the side the selection's
//     coordinate sum is on (its "quadrant") drives; each of its vertices that
//     has a mirror makes that mirror a *follower*, which Blender does not
//     transform but sets to its source's result with the axis negated. A
//     selected vertex on the far side is a follower too. With two or three
//     axes the mirrors of mirrors follow as well (the diagonal of X+Y).
//   * With proportional editing every visible vertex, selected or not,
//     drives — so the far side becomes the near side's reflection.
//   * A transformed vertex within 0.00002 of a mirror plane stays on it
//     (TD_MIRROR_EDGE): measured, a selected vertex at x = 0 moved by
//     (0.1, 0.2, 0.3) ended at (0, 0.2, 0.3).
//   * Pairs are found by position (EDBM_verts_mirror_cache_begin_ex, nearest
//     within 0.00002), or with Topology Mirror by the edges alone
//     (ED_mesh_mirrtopo_init), which ignores the axis. Measured on Suzanne:
//     with a mirror vertex pushed 0.05 off its place, the positional mirror
//     moved 1 vertex and the topology mirror 2.
//   * mesh_transdata_mirror_apply runs after the Mirror modifier's clipping
//     (recalcData_mesh), so it is applied here after `MirrorClip` too.
//   * All of it on the edit mesh's own coordinates (BMVert co). Under a
//     modifier shown in edit mode that keeps the vertex count — SimpleDeform
//     and Shrinkwrap have `show_in_editmode` on by default — the viewport
//     draws other positions under the same numbers. Measured in 5.2.1 on a
//     10 × 10 grid with a SimpleDeform Twist, X on, (0.6, 0.4) selected:
//     paired on the drawn positions it had no image and the preview moved 1
//     vertex; `translate(mirror=True)` moved 2. So the pairs, the quadrant and
//     the plane test use Blender's coordinates (`EditTopology.blenderPositions`)
//     and `apply` works in them too, carrying each vertex's offset from what is
//     drawn (see `offsets`).

/// One edit-mode transform's mirror: which vertices follow which, across
/// which axes, and which are held on a mirror plane.
public struct SymmetricEdit: Equatable, Sendable {
    /// TRANSFORM_MAXDIST_MIRROR: the pairing distance, and how near a plane a
    /// vertex has to be to stay on it.
    public static let epsilon: Float = 0.00002

    /// The axes mirrored, X Y Z.
    public let axes: [Bool]
    /// For each vertex, the vertex whose moved position it takes, or -1 for a
    /// vertex Blender transforms itself (or leaves alone).
    public let source: [Int32]
    /// For each follower, the axes its source's position is negated on: bit 0
    /// X, 1 Y, 2 Z.
    public let flips: [UInt8]
    /// For each transformed vertex, the planes it is held on (TD_MIRROR_EDGE),
    /// same bits.
    public let pinned: [UInt8]
    /// For each vertex, Blender's coordinate minus the drawn one, when the
    /// pairs were found on coordinates other than the ones the preview moves
    /// (`shown`); empty when they are the same. `apply` adds them to go into
    /// Blender's coordinates and takes them off to come back, which treats the
    /// modifier between the two as a shift per vertex: a follower moves by its
    /// source's movement, mirrored. That is what Blender does to the edit mesh;
    /// what the modifier then makes of it the preview cannot know — the same
    /// approximation every edit-mode drag over such a modifier makes.
    public let offsets: [SIMD3<Float>]
    /// The followers, in vertex order — the order Blender fills them in.
    public let followers: [Int]
    public let followerSet: Set<Int>
    /// Whether the mirror left Blender nothing to transform: every selected
    /// vertex became a follower. Then `createTransEditVerts` makes no
    /// TransData and the operator returns CANCELLED having changed nothing —
    /// measured in 5.2.1 with X, Y and Topology Mirror on, where each of the
    /// selected vertices of Suzanne's ear ends up its own follower: 0 moved.
    /// The preview shows that too, rather than its followers jumping.
    public let cancels: Bool

    /// `positions` in the object's own space, as Blender's edit mesh holds
    /// them; `shown`, when it is not those, what the viewport drew for each
    /// vertex, which is what the preview moves (`EditTopology.blenderPositions`
    /// says when); `selected` and `hidden` as the mirror reports them; `edges`
    /// Blender's, in its order (`EditTopology.blenderEdges`), for Topology
    /// Mirror. Nil when no axis is on — then Blender mirrors nothing.
    public init?(positions: [SIMD3<Float>], shown: [SIMD3<Float>]? = nil,
                 selected: Set<Int>, hidden: Set<Int> = [],
                 symmetry: MeshSymmetry, proportional: Bool, edges: [UInt32] = []) {
        guard symmetry.isOn else { return nil }
        let n = positions.count
        if let shown, shown.count == n, shown != positions {
            self.offsets = zip(positions, shown).map { $0 - $1 }
        } else {
            self.offsets = []
        }
        let axes = [symmetry.x, symmetry.y, symmetry.z]
        var isHidden = [Bool](repeating: false, count: n)
        for i in hidden where i >= 0 && i < n { isHidden[i] = true }
        var isSelected = [Bool](repeating: false, count: n)
        for i in selected where i >= 0 && i < n && !isHidden[i] { isSelected[i] = true }
        // use_select = (t->flag & T_PROP_EDIT) == 0.
        let useSelect = !proportional

        var mapIndex = [Int32](repeating: -1, count: n)
        var mapFlag = [UInt8](repeating: 0, count: n)

        // The quadrant: the sign of the selection's coordinate sum, summed in
        // float in vertex order as `add_v3_v3` does — on a symmetric
        // selection the sum is rounding noise, and its sign decides.
        var sum = SIMD3<Float>.zero
        for i in 0..<n where isSelected[i] { sum += positions[i] }
        var quadrant = SIMD3<Float>.zero
        for a in 0..<3 where axes[a] { quadrant[a] = sum[a] >= 0 ? 1 : -1 }
        func inQuadrant(_ p: SIMD3<Float>) -> Bool {
            for a in 0..<3 where quadrant[a] != 0 && p[a] * quadrant[a] < -Self.epsilon { return false }
            return true
        }

        let single = axes.filter { $0 }.count == 1
        let selectedOnly = useSelect && single
        let table = symmetry.topology ? Self.topologyTable(vertexCount: n, edges: edges) : nil
        // One search structure for every axis: the positions do not change.
        let grid = table == nil ? MirrorGrid(positions, hidden: isHidden) : nil
        var index: [[Int32]] = [[], [], []]
        var count = 0
        for a in 0..<3 where axes[a] {
            let found = Self.mirrorIndex(positions, axis: a, selectedOnly: selectedOnly ? isSelected : nil,
                                         hidden: isHidden, topology: table, grid: grid)
            index[a] = found
            let flag = UInt8(1 << a)
            for i in 0..<n {
                let m = Int(found[i])
                guard m >= 0, !isHidden[i], !useSelect || isSelected[i], inQuadrant(positions[i]),
                      // One mirror per element; and never a mirror of a mirror
                      // on the same axis (a pair within the threshold).
                      mapFlag[m] == 0, mapFlag[i] & flag == 0
                else { continue }
                mapIndex[m] = Int32(i)
                mapFlag[m] = flag
                count += 1
            }
        }
        if count > 0, !single {
            // "Adjustment for elements that are mirrors of mirrored elements."
            for a in 0..<3 where axes[a] {
                let flag = UInt8(1 << a)
                for i in 0..<n {
                    let m = Int(index[a][i])
                    guard m >= 0, mapIndex[i] != -1, mapFlag[i] & flag == 0 else { continue }
                    mapIndex[m] = mapIndex[i]
                    mapFlag[m] |= mapFlag[i] | flag
                }
            }
        }

        var pinned = [UInt8](repeating: 0, count: n)
        var followers: [Int] = []
        var transformed = 0
        for i in 0..<n where !isHidden[i] {
            if mapIndex[i] != -1 {
                followers.append(i)
            } else if proportional || isSelected[i] {
                // TransData: the selection, or with proportional editing every
                // visible vertex (createTransEditVerts).
                transformed += 1
                var bits: UInt8 = 0
                for a in 0..<3 where axes[a] && abs(positions[i][a]) < Self.epsilon { bits |= UInt8(1 << a) }
                pinned[i] = bits
            }
        }
        self.cancels = transformed == 0
        self.axes = axes
        self.source = mapIndex
        self.flips = mapFlag
        self.pinned = pinned
        self.followers = followers
        self.followerSet = Set(followers)
    }

    /// mesh_transdata_mirror_apply: `moved` is every vertex after the
    /// transform and the Mirror modifier's clipping. Pinned coordinates go to
    /// 0, then each follower takes its source's position, negated on its axes
    /// — in vertex order, reading what is there by then, as Blender's
    /// `loc_src` reads its source in place. With `offsets`, `moved` is in the
    /// drawn positions and both happen in Blender's: a pinned coordinate goes
    /// to where Blender's 0 is drawn, and a follower to its source's Blender
    /// position, negated, less its own offset.
    public func apply(to moved: inout [SIMD3<Float>]) {
        guard moved.count == source.count else { return }
        if offsets.count == moved.count {
            for i in moved.indices where pinned[i] != 0 {
                for a in 0..<3 where pinned[i] & UInt8(1 << a) != 0 { moved[i][a] = -offsets[i][a] }
            }
            for f in followers {
                let s = Int(source[f])
                var p = moved[s] + offsets[s]
                for a in 0..<3 where flips[f] & UInt8(1 << a) != 0 { p[a] = -p[a] }
                moved[f] = p - offsets[f]
            }
            return
        }
        for i in moved.indices where pinned[i] != 0 {
            for a in 0..<3 where pinned[i] & UInt8(1 << a) != 0 { moved[i][a] = 0 }
        }
        for f in followers {
            var p = moved[Int(source[f])]
            for a in 0..<3 where flips[f] & UInt8(1 << a) != 0 { p[a] = -p[a] }
            moved[f] = p
        }
    }

    // MARK: finding the pairs

    /// EDBM_verts_mirror_cache_begin_ex with `use_self` false and
    /// `respecthide` true, into an index array: each vertex's mirror across
    /// `axis`, or -1. Each pair is written both ways as it is found, later
    /// finds overwriting earlier ones, as Blender writes them.
    static func mirrorIndex(_ positions: [SIMD3<Float>], axis: Int, selectedOnly: [Bool]?,
                            hidden: [Bool], topology: [Int32]?, grid: MirrorGrid? = nil) -> [Int32] {
        let n = positions.count
        var out = [Int32](repeating: -1, count: n)
        let grid = topology == nil ? (grid ?? MirrorGrid(positions, hidden: hidden)) : nil
        for i in 0..<n where !hidden[i] {
            if let selectedOnly, !selectedOnly[i] { continue }
            var m = -1
            if let topology {
                m = Int(topology[i])
                if m >= 0, hidden[m] { m = -1 }
            } else if let grid {
                var q = positions[i]
                q[axis] = -q[axis]
                m = grid.nearest(to: q) ?? -1
            }
            if m >= 0, m != i {
                out[i] = Int32(m)
                out[m] = Int32(i)
            } else {
                out[i] = -1
            }
        }
        return out
    }

    /// ED_mesh_mirrtopo_init: vertices paired by their place in the mesh's
    /// edge graph alone. Each vertex starts with its edge count and adds, per
    /// pass, its neighbours' previous values times the pass number (UInt32,
    /// wrapping, as Blender's `uint` does); the passes stop when one adds
    /// neither unique values nor unequal edges. A value two vertices share is a
    /// pair, one only one vertex has is a centre vertex (its own mirror), and
    /// anything shared three or more ways is not mirrored.
    ///
    /// The unique values are counted after `qsort` with Blender's comparator,
    /// `mirrtopo_hash_sort`, which compares the elements' *addresses*
    /// (`MirrTopoHash_t(intptr_t(l1))`), not their values. So the count is of
    /// neighbours that differ in whatever order libc's qsort leaves the array
    /// under that comparator — and the number of passes, and with it which
    /// vertices pair, follows from that. It is reproduced by calling the same
    /// libc qsort with the same comparator: the comparisons depend only on the
    /// slots' relative addresses, so the permutation is Blender's.
    static func topologyTable(vertexCount n: Int, edges: [UInt32]) -> [Int32] {
        var lookup = [Int32](repeating: -1, count: n)
        guard n > 0 else { return lookup }
        let pairs = stride(from: 0, to: edges.count - 1, by: 2).compactMap { e -> (Int, Int)? in
            let a = Int(edges[e]), b = Int(edges[e + 1])
            return a < n && b < n ? (a, b) : nil
        }
        var hash = [UInt32](repeating: 0, count: n)
        for (a, b) in pairs {
            hash[a] &+= 1
            hash[b] &+= 1
        }
        var previous = hash
        var uniquePrevious = -1, uniqueEdgesPrevious = -1
        var pass: UInt32 = 1
        // Blender has no cap. The two counts are bounded, so a run longer
        // than this would be one that never ends in Blender either.
        let cap = n + pairs.count + 2
        while Int(pass) <= cap {
            var uniqueEdges = 0
            for (a, b) in pairs {
                hash[a] &+= previous[b] &* pass
                hash[b] &+= previous[a] &* pass
                if hash[a] != hash[b] { uniqueEdges += 1 }
            }
            previous = hash
            previous.withUnsafeMutableBytes { raw in
                qsort(raw.baseAddress, n, MemoryLayout<UInt32>.stride, mirrtopoHashSort)
            }
            var unique = 1
            for a in 1..<n where previous[a - 1] != previous[a] { unique += 1 }
            if unique <= uniquePrevious, uniqueEdges <= uniqueEdgesPrevious { break }
            uniquePrevious = unique
            uniqueEdgesPrevious = uniqueEdges
            previous = hash
            pass &+= 1
        }
        // Grouped by value; the order within a group does not matter, since
        // only groups of one and two are used and a pair is symmetric.
        let order = (0..<n).sorted { hash[$0] < hash[$1] }
        var last = 0
        for a in 1...n where a == n || hash[order[a - 1]] != hash[order[a]] {
            let matches = a - last
            if matches == 2 {
                let j = order[a - 1], k = order[a - 2]
                lookup[j] = Int32(k)
                lookup[k] = Int32(j)
            } else if matches == 1 {
                lookup[order[a - 1]] = Int32(order[a - 1])
            }
            last = a
        }
        return lookup
    }
}

/// `mirrtopo_hash_sort` as Blender compiles it: the arguments' addresses,
/// truncated to `uint`, compared.
private let mirrtopoHashSort: @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Int32 = { l1, l2 in
    let a = UInt32(truncatingIfNeeded: UInt(bitPattern: l1))
    let b = UInt32(truncatingIfNeeded: UInt(bitPattern: l2))
    return a > b ? 1 : (a < b ? -1 : 0)
}

/// The visible vertices by position, for the mirror search: Blender's
/// KD-tree finds the nearest vertex and keeps it when it is closer than
/// `epsilon`, which is the nearest of those within `epsilon`. Bucketed by a
/// cell much wider than that, and asked only for the cells the box `epsilon`
/// either side of the query touches — one, mostly. Two vertices at the same
/// distance — only duplicates are — go to the lower index, where the KD-tree's
/// choice depends on its build.
///
/// The cells are hashed into a table of one slot per vertex (rounded up to a
/// power of two) and the vertices sorted into it by a counting sort: two Int32
/// arrays, about 12 bytes a vertex. A slot two cells share is harmless — the
/// distance test throws out whatever is not within `epsilon` of the query, and
/// everything that is lies in a cell the query asks for. The first version
/// kept a Dictionary of one Swift array per cell, and measured (swiftc -O,
/// this Mac, X only, one vertex selected) 218 ms and 214 MB over the positions
/// at 1,000,000 vertices, 510 ms and 427 MB at 2,002,225: the gizmo builds it
/// at touch-down, on the main thread, beside Blender's own copy of the mesh.
/// This one: 24 ms and 20 MB at 1,000,000; 52 ms and 38 MB at 2,002,225.
struct MirrorGrid {
    private static let cell: Float = 0.001
    private let positions: [SIMD3<Float>]
    private let mask: Int
    /// For each slot, where its vertices start in `order`; one past the end
    /// for the last.
    private let starts: [Int32]
    private let order: [Int32]

    init(_ positions: [SIMD3<Float>], hidden: [Bool]) {
        self.positions = positions
        let n = positions.count
        var size = 1
        while size < n { size <<= 1 }
        let mask = size - 1
        self.mask = mask
        var starts = [Int32](repeating: 0, count: size + 1)
        // Each vertex's slot, or -1 for one that is hidden or not finite.
        var slots = [Int32](repeating: -1, count: n)
        for i in 0..<n where !hidden[i] && Self.finite(positions[i]) {
            let slot = Self.slot(Self.key(positions[i]), mask: mask)
            slots[i] = Int32(slot)
            starts[slot + 1] += 1
        }
        for s in 0..<size { starts[s + 1] += starts[s] }
        var fill = starts
        var order = [Int32](repeating: 0, count: Int(starts[size]))
        for i in 0..<n where slots[i] >= 0 {
            let s = Int(slots[i])
            order[Int(fill[s])] = Int32(i)
            fill[s] += 1
        }
        self.starts = starts
        self.order = order
    }

    private static func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }

    private static func key(_ p: SIMD3<Float>) -> SIMD3<Int64> {
        let q = (p / cell).rounded(.down)
        let bound: Float = 1e17
        return SIMD3(Int64(min(max(q.x, -bound), bound)), Int64(min(max(q.y, -bound), bound)),
                     Int64(min(max(q.z, -bound), bound)))
    }

    /// A cell's slot: the three coordinates mixed (SplitMix64's finaliser),
    /// so neighbouring cells spread over the table.
    private static func slot(_ k: SIMD3<Int64>, mask: Int) -> Int {
        var h = UInt64(bitPattern: k.x) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: k.y) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bitPattern: k.z) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 30
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        h &*= 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Int(truncatingIfNeeded: h) & mask
    }

    func nearest(to q: SIMD3<Float>) -> Int? {
        guard Self.finite(q), !order.isEmpty else { return nil }
        // `square_f(maxdist)` and `len_squared_v3v3`, in float, written out.
        let reach = SymmetricEdit.epsilon * SymmetricEdit.epsilon
        // Every point within epsilon of q is in the box epsilon either side
        // of it, and so in a cell between these two.
        let lo = Self.key(q - SIMD3(repeating: SymmetricEdit.epsilon))
        let hi = Self.key(q + SIMD3(repeating: SymmetricEdit.epsilon))
        var best: (index: Int32, d: Float)?
        for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x {
            let s = Self.slot(SIMD3(x, y, z), mask: mask)
            for k in Int(starts[s])..<Int(starts[s + 1]) {
                let i = order[k]
                let p = positions[Int(i)]
                let ex = q.x - p.x, ey = q.y - p.y, ez = q.z - p.z
                let d = ex * ex + ey * ey + ez * ez
                guard d < reach else { continue }
                if best == nil || d < best!.d || (d == best!.d && i < best!.index) { best = (i, d) }
            }
        }}}
        return best.map { Int($0.index) }
    }
}

// MARK: - The header's toggles

/// What the X, Y, Z and Topology Mirror toggles send: the mesh's own flags,
/// on the object the header shows. Blender's header writes
/// `context.object.data`; this names the object, so a toggle cannot land on a
/// different mesh from the one whose state it showed.
///
/// An undo step only where Blender's would restore the flag (`undoLabel`).
public enum SymmetryBpy {
    public enum Flag: Int, CaseIterable, Identifiable, Sendable {
        case x = 0, y, z, topology

        public var id: Int { rawValue }
        public var property: String {
            switch self {
            case .x:        return "use_mirror_x"
            case .y:        return "use_mirror_y"
            case .z:        return "use_mirror_z"
            case .topology: return "use_mirror_topology"
            }
        }
        /// Blender's own labels (`rna_mesh.cc`): "X", "Y", "Z", "Topology Mirror".
        public var label: String {
            switch self {
            case .x:        return "X"
            case .y:        return "Y"
            case .z:        return "Z"
            case .topology: return "Topology Mirror"
            }
        }

        public func isOn(in symmetry: MeshSymmetry) -> Bool {
            self == .topology ? symmetry.topology : symmetry[rawValue]
        }
    }

    public static func set(_ flag: Flag, _ on: Bool, objectNamed name: String) -> String {
        "bpy.data.objects[\(Bpy.quote(name))].data.\(flag.property) = \(on ? "True" : "False")"
    }

    /// The undo step a toggle makes in `mode`, named as Blender's button is,
    /// or none.
    ///
    /// Blender's header pushes one for a property unless the object is in
    /// Sculpt Mode, or in Edit Mode on another ID type
    /// (ED_undo_is_legacy_compatible_for_property). In Edit Mode the step is
    /// an edit-mesh one, and that does not put the flag back — measured in
    /// 5.2.1, X on, a Move, then Undo left `use_mirror_x` True, and a second
    /// Undo past an undo step pushed for the toggle left it True too — so
    /// there it would be a step that undoes nothing. Texture, Vertex and
    /// Weight Paint here keep Blender in object mode (_blenderkit_sync
    /// `_REAL_APP_MODES`), where its undo restores the whole file: measured,
    /// an un-pushed `use_mirror_x = True` there was turned back to False by
    /// undoing a later, unrelated step. So those take a step of their own.
    public static func undoLabel(_ flag: Flag, mode: InteractionMode) -> String? {
        switch mode {
        case .texturePaint, .vertexPaint, .weightPaint, .object: return flag.label
        case .edit, .sculpt:                                     return nil
        }
    }

    /// Whether Topology Mirror is offered in `mode`. Blender 5.2's interface
    /// shows it in Edit Mode's options and Weight Paint's symmetry panel
    /// (space_view3d_toolbar.py), and nothing else reads ME_EDIT_MIRROR_TOPO:
    /// in Sculpt, Vertex and Texture Paint the toggle would write a flag that
    /// changes nothing the user is doing.
    public static func offersTopology(in mode: InteractionMode) -> Bool {
        mode == .edit || mode == .weightPaint
    }
}
