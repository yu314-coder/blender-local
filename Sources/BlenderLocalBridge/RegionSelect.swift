import Foundation
import CoreGraphics
import simd

// MARK: - the region a gesture sweeps

/// The part of the 3D View a Box, Circle or Lasso select gesture covers, in
/// view points (origin top-left, y down).
///
/// The three tools used to be one tool: box select was built, and Circle and
/// Lasso sat greyed out in the toolbar with "Needs a screen-space selection
/// pass". Blender's own `view3d.select_circle` and `select_lasso` cannot stand
/// in for that pass on the device. Measured in 5.2.1 without a window: with
/// the 3D View's X-Ray on they select (9, 13 and 9 vertices of a 10 × 10 grid
/// for circle, lasso and box), and with X-Ray off they select nothing, because
/// they read Blender's GPU selection buffer, which a bpy without a window
/// never draws. So the pass is Swift's, over the mesh the viewport draws, one
/// region type for all three tools — and what it picks is handed to Blender and
/// read back (`BpyBridge.run` → the mirror), never kept on the display cache.
public enum SelectionRegion: Equatable, Sendable {
    /// Box select's rectangle.
    case box(CGRect)
    /// Circle select is painted, not placed: Blender's modal circle selects
    /// under the circle at every mouse event of the drag. `path` is where its
    /// centre went, and the region is everything within `radius` of that
    /// path — the whole swept stroke, not only the samples a touch happened to
    /// report, so a fast stroke leaves no gaps between them.
    case circle(path: [CGPoint], radius: CGFloat)
    /// The lasso's outline, closed back to its first point.
    case lasso([CGPoint])

    /// Blender's name for the operator, which is what its undo step is called.
    public var undoName: String {
        switch self {
        case .box:    return "Box Select"
        case .circle: return "Circle Select"
        case .lasso:  return "Lasso Select"
        }
    }

    /// Whether the gesture covered anything. A box a point wide is a tap, and
    /// a lasso needs an area to have an inside.
    ///
    /// The lasso's area is what the even-odd rule covers, which is what
    /// `contains` takes and the overlay fills, not the signed area alone: the
    /// lobes of a lasso that crosses itself wind opposite ways, and a bow tie's
    /// two cancel to 0 (measured), so it was previewed filled and then
    /// selected nothing, with no word why.
    public var isUsable: Bool {
        switch self {
        case .box(let r):
            return r.width > 1 && r.height > 1
        case .circle(let path, let radius):
            return !path.isEmpty && radius > 0
        case .lasso(let points):
            guard points.count >= 3 else { return false }
            return abs(Self.signedArea(points)) > 4 || Self.evenOddArea(points, atLeast: 4) > 4
        }
    }

    /// The smallest rectangle holding the whole region.
    public var bounds: CGRect {
        switch self {
        case .box(let r):
            return r.standardized
        case .circle(let path, let radius):
            guard let first = path.first else { return .null }
            var lo = first, hi = first
            for p in path {
                lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y))
                hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
            }
            return CGRect(x: lo.x - radius, y: lo.y - radius,
                          width: hi.x - lo.x + 2 * radius, height: hi.y - lo.y + 2 * radius)
        case .lasso(let points):
            guard let first = points.first else { return .null }
            var lo = first, hi = first
            for p in points {
                lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y))
                hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
            }
            return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        }
    }

    /// Whether a point is inside.
    ///
    /// Each test is Blender's: the rectangle's edges count as inside
    /// (`BLI_rctf_isect_pt_v`), a circle takes what is within its radius
    /// (`len_squared_v2v2 <= radius²`), and the lasso is even-odd, as
    /// `isect_point_poly_v2_int` counts crossings — so a lasso that crosses
    /// itself leaves the overlap out, as Blender's does.
    public func contains(_ p: CGPoint) -> Bool {
        switch self {
        case .box(let r):
            let r = r.standardized
            return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
        case .circle(let path, let radius):
            return Self.distance(from: p, toPath: path) <= radius
        case .lasso(let points):
            return Self.evenOdd(p, points)
        }
    }

    /// Whether the segment from `a` to `b` meets the region anywhere — an end
    /// inside, or the line crossing into it. Blender's `edge_inside_rect`,
    /// `edge_inside_circle` and `BLI_lasso_is_edge_inside`.
    public func touches(_ a: CGPoint, _ b: CGPoint) -> Bool {
        switch self {
        case .box(let r):
            let r = r.standardized
            if contains(a) || contains(b) { return true }
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            for i in 0..<4 where Self.segmentsCross(a, b, corners[i], corners[(i + 1) % 4]) {
                return true
            }
            return false
        case .circle(let path, let radius):
            guard let first = path.first else { return false }
            if path.count == 1 { return Self.distance(first, toSegment: a, b) <= radius }
            for i in 0..<(path.count - 1)
            where Self.segmentDistance(a, b, path[i], path[i + 1]) <= radius {
                return true
            }
            return false
        case .lasso(let points):
            guard points.count >= 3 else { return false }
            if contains(a) || contains(b) { return true }
            for i in 0..<points.count
            where Self.segmentsCross(a, b, points[i], points[(i + 1) % points.count]) {
                return true
            }
            return false
        }
    }

    /// Which samples of a grid of view points the region covers, a sample
    /// being the centre of a point: `(x0 + i + 0.5, y0 + j + 0.5)`.
    ///
    /// Filled shape by shape rather than by asking `contains` of every
    /// sample, which for a lasso of a few hundred points over the whole view
    /// is a few hundred million tests: rows of a scanline for the lasso (the
    /// same even-odd rule), and each stroke segment's own rectangle for the
    /// circle.
    func coverage(x0: Int, y0: Int, width: Int, height: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: max(0, width * height))
        guard width > 0, height > 0 else { return mask }
        func centre(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: CGFloat(x0 + x) + 0.5, y: CGFloat(y0 + y) + 0.5)
        }
        switch self {
        case .box:
            for y in 0..<height { for x in 0..<width where contains(centre(x, y)) { mask[y * width + x] = true } }
        case .circle(let path, let radius):
            guard let first = path.first else { return mask }
            let segments = path.count == 1 ? [(first, first)] : Array(zip(path, path.dropFirst()))
            for (a, b) in segments {
                // Clamped before they become Ints: see `clampedIndex`.
                let lx = max(0, clampedIndex(min(a.x, b.x) - radius - CGFloat(x0), .down, count: width))
                let hx = min(width - 1, clampedIndex(max(a.x, b.x) + radius - CGFloat(x0), .up, count: width))
                let ly = max(0, clampedIndex(min(a.y, b.y) - radius - CGFloat(y0), .down, count: height))
                let hy = min(height - 1, clampedIndex(max(a.y, b.y) + radius - CGFloat(y0), .up, count: height))
                guard lx <= hx, ly <= hy else { continue }
                for y in ly...hy {
                    for x in lx...hx where !mask[y * width + x]
                        && Self.distance(centre(x, y), toSegment: a, b) <= radius {
                        mask[y * width + x] = true
                    }
                }
            }
        case .lasso(let points):
            guard points.count >= 3 else { return mask }
            var crossings: [CGFloat] = []
            for y in 0..<height {
                let sy = CGFloat(y0 + y) + 0.5
                crossings.removeAll(keepingCapacity: true)
                var j = points.count - 1
                for i in 0..<points.count {
                    let a = points[i], b = points[j]
                    if (a.y > sy) != (b.y > sy) {
                        crossings.append((b.x - a.x) * (sy - a.y) / (b.y - a.y) + a.x)
                    }
                    j = i
                }
                crossings.sort()
                // Inside where an odd number of crossings lie to the right:
                // from each odd crossing up to the next.
                var k = 0
                while k + 1 < crossings.count {
                    let from = max(0, clampedIndex(crossings[k] - 0.5 - CGFloat(x0), .up, count: width))
                    let to = min(width - 1, clampedIndex(crossings[k + 1] - 0.5 - CGFloat(x0), .up, count: width) - 1)
                    if from <= to { for x in from...to { mask[y * width + x] = true } }
                    k += 2
                }
            }
        }
        return mask
    }

    /// Box and Lasso take edges in two passes: the edges wholly inside, and
    /// only when there are none, the edges that cross into the region
    /// (`do_mesh_box_select__doSelectEdge_pass0/1`, and the lasso's). A circle
    /// takes every edge it touches (`mesh_circle_doSelectEdge`).
    public var takesEdgesInTwoPasses: Bool {
        if case .circle = self { return false }
        return true
    }

    // MARK: plane geometry

    static func signedArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// The area the even-odd rule puts inside a polygon, in square points,
    /// measured a row of one point at a time — the rows `coverage` fills.
    /// Stops counting once past `atLeast`.
    static func evenOddArea(_ points: [CGPoint], atLeast: CGFloat = .infinity) -> CGFloat {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return 0 }
        let lo = points.map(\.y).min()!, hi = points.map(\.y).max()!
        var area: CGFloat = 0
        var crossings: [CGFloat] = []
        var y = lo.rounded(.down) + 0.5
        while y < hi && area <= atLeast {
            crossings.removeAll(keepingCapacity: true)
            var j = points.count - 1
            for i in 0..<points.count {
                let a = points[i], b = points[j]
                if (a.y > y) != (b.y > y) { crossings.append((b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) }
                j = i
            }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count { area += crossings[k + 1] - crossings[k]; k += 2 }
            y += 1
        }
        return area
    }

    static func evenOdd(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let length = abx * abx + aby * aby
        guard length > 1e-12 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / length, 0), 1)
        return hypot(p.x - (a.x + abx * t), p.y - (a.y + aby * t))
    }

    static func distance(from p: CGPoint, toPath path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        guard path.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 0..<(path.count - 1) {
            best = min(best, distance(p, toSegment: path[i], path[i + 1]))
        }
        return best
    }

    static func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Whether two segments meet, touching included.
    static func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2)
        let d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        func on(_ o: CGPoint, _ a: CGPoint, _ p: CGPoint) -> Bool {
            p.x >= min(o.x, a.x) && p.x <= max(o.x, a.x) && p.y >= min(o.y, a.y) && p.y <= max(o.y, a.y)
        }
        if d1 == 0 && on(q1, q2, p1) { return true }
        if d2 == 0 && on(q1, q2, p2) { return true }
        if d3 == 0 && on(p1, p2, q1) { return true }
        if d4 == 0 && on(p1, p2, q2) { return true }
        return false
    }

    static func segmentDistance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        if segmentsCross(a, b, c, d) { return 0 }
        return min(distance(a, toSegment: c, d), distance(b, toSegment: c, d),
                   distance(c, toSegment: a, b), distance(d, toSegment: a, b))
    }
}

// MARK: - what a gesture does to the selection

public extension SelectAction {
    /// Blender's `sel_op_result` for a gesture: what an element ends as, given
    /// whether it was selected and whether the region covers it.
    ///
    /// Not `apply(_:hit:)`, which is a click's: a click on nothing leaves the
    /// selection alone except for Set, but an Intersect box drawn over nothing
    /// deselects everything in Blender (`is_select && is_inside`), and that is
    /// what this does.
    func regionResult(selected: Bool, inside: Bool) -> Bool {
        switch self {
        case .set:        return inside
        case .extend:     return selected || inside
        case .subtract:   return selected && !inside
        case .difference: return selected != inside
        case .intersect:  return selected && inside
        }
    }

    /// The same, over whole sets.
    func applyRegion<T: Hashable>(_ current: Set<T>, inside: Set<T>) -> Set<T> {
        switch self {
        case .set:        return inside
        case .extend:     return current.union(inside)
        case .subtract:   return current.subtracting(inside)
        case .difference: return current.symmetricDifference(inside)
        case .intersect:  return current.intersection(inside)
        }
    }

    /// The operation Blender's keymap gives a select gesture with the
    /// keyboard's modifiers held, or nil to use the tool setting. Read from
    /// 5.2.1's blender_default.py: the box and lasso tools take
    /// `_template_items_tool_select_actions` — Shift ADD, Ctrl SUB, Shift+Ctrl
    /// AND (Intersect) — and the circle tool the `_simple` one, which has no
    /// Shift+Ctrl, so there Ctrl still subtracts.
    static func forGesture(shift: Bool, control: Bool, circle: Bool = false) -> SelectAction? {
        if shift && control && !circle { return .intersect }
        if control { return .subtract }
        if shift { return .extend }
        return nil
    }

    /// The modes a select tool's header offers, Blender's tool settings: Set,
    /// Extend, Subtract, Difference and Intersect for Box and Lasso
    /// (`view3d.select_box` and `select_lasso`'s `mode`), and only the first
    /// three for Circle (`select_circle`'s `mode` is SET, ADD or SUB). A touch
    /// screen has no Shift or Ctrl, so without them Circle and Lasso could
    /// only Set.
    static func regionModes(circle: Bool) -> [SelectAction] {
        circle ? [.set, .extend, .subtract] : allCases
    }

    /// This mode as a tool takes it: one the tool does not offer is Set.
    func forRegion(circle: Bool) -> SelectAction {
        Self.regionModes(circle: circle).contains(self) ? self : .set
    }
}

// MARK: - the pass

/// Which mesh elements and which objects a `SelectionRegion` covers.
///
/// Blender's rules, element by element (view3d_select.cc):
///
/// * a vertex counts when its dot is inside;
/// * an edge counts when both ends are inside — or, for Box and Lasso when no
///   edge is wholly inside, when it crosses into the region; a Circle takes
///   every edge it touches;
/// * a face counts when its centre (Blender's face dot) is inside, with X-Ray;
///   without X-Ray, when any of it shows inside the region — Blender reads
///   that off its selection buffer, the faces drawn with the depth test on.
///
/// Without X-Ray only what the surface does not hide counts, as in Blender,
/// where the selection buffer is drawn with the depth test on. That buffer is
/// the part a bpy without a window cannot draw, so here it is `DepthBuffer`: the
/// edited mesh rasterised in Swift, one sample per view point, over just the
/// rectangle the region covers. With X-Ray on — or in Wireframe, where
/// Blender's X-Ray is on by default (`show_xray_wireframe`, measured True in
/// 5.2.1) — everything inside counts, front or back.
///
/// Objects: a box takes an object any part of which it covers
/// (`BoxSelect.objects`), but a circle or a lasso takes an object only when it
/// covers its origin. That is Blender's too, and measured in 5.2.1 without a
/// window, top view: a circle or a lasso over a cube's surface away from its
/// origin selected nothing, on its origin it selected the cube, and a box over
/// the same spot of surface selected it, with X-Ray on and off alike
/// (`object_circle_select`, `do_lasso_select_objects` test `base->sx, sy`).
public enum RegionSelect {

    /// The elements of `mode` the region covers — vertices in vertex mode,
    /// edges in edge mode, viewport triangles (whole polygons) in face mode.
    /// The other two sets are left empty: what they imply is
    /// `EditSelection.implied`'s business.
    ///
    /// - Parameters:
    ///   - model: the object's matrix; `viewProjection` is the camera's, world
    ///     to clip.
    ///   - seeThrough: X-Ray, or Wireframe: nothing is hidden.
    public static func elements(mesh: MeshData, topology: EditTopology?,
                                model: simd_float4x4, viewProjection: simd_float4x4,
                                size: CGSize, region: SelectionRegion,
                                mode: MeshSelectMode, seeThrough: Bool) -> EditSelection {
        var selection = EditSelection()
        guard region.isUsable, size.width > 0, size.height > 0, !mesh.vertices.isEmpty
        else { return selection }
        let topology = topology.flatMap { $0.describes(mesh) ? $0 : nil }
        let hidden = topology?.hiddenVertices ?? []
        let real = topology?.realEdges ?? []
        func isReal(_ e: Int) -> Bool { real.isEmpty || real.contains(e) }

        let view = ProjectedMesh(mesh: mesh, clip: viewProjection * model, size: size)
        let area = region.bounds
        // A scale of -1 on one axis turns the object inside out, and its
        // faces wind the other way on screen (`DepthBuffer.init`).
        let linear = simd_float3x3(model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz)
        let depth = seeThrough ? nil
            : DepthBuffer(view: view, mesh: mesh, covering: area.insetBy(dx: -2, dy: -2), size: size,
                          mirrored: simd_determinant(linear) < 0)

        switch mode {
        case .vertex:
            for i in mesh.vertices.indices where !hidden.contains(i) {
                guard let s = view.screen[i], area.insetBy(dx: -1, dy: -1).contains(s),
                      region.contains(s) else { continue }
                if let depth, !depth.isVisible(s, depth: view.depth[i]) { continue }
                selection.vertices.insert(i)
            }

        case .edge:
            let count = mesh.edges.count / 2
            var inside: Set<Int> = [], crossing: Set<Int> = []
            for e in 0..<count where isReal(e) {
                let a = Int(mesh.edges[2 * e]), b = Int(mesh.edges[2 * e + 1])
                guard a < view.screen.count, b < view.screen.count,
                      !hidden.contains(a), !hidden.contains(b),
                      let sa = view.screen[a], let sb = view.screen[b] else { continue }
                // Nothing of an edge whose box misses the region's can meet it.
                let box = CGRect(x: min(sa.x, sb.x), y: min(sa.y, sb.y),
                                 width: abs(sa.x - sb.x), height: abs(sa.y - sb.y))
                guard box.insetBy(dx: -1, dy: -1).intersects(area) else { continue }
                let whole = region.contains(sa) && region.contains(sb)
                let meets = whole || region.touches(sa, sb)
                guard meets else { continue }
                if let depth, !depth.edgeShows(from: sa, view.depth[a], to: sb, view.depth[b],
                                               perspective: view.perspective, in: region) {
                    continue
                }
                if whole { inside.insert(e) }
                crossing.insert(e)
            }
            if region.takesEdgesInTwoPasses {
                selection.edges = inside.isEmpty ? crossing : inside
            } else {
                selection.edges = crossing
            }

        case .face:
            let triangles = mesh.indices.count / 3
            var polygons: [UInt32: [Int]] = [:]
            if let topology, topology.trianglePolygons.count == triangles {
                for t in 0..<triangles { polygons[topology.trianglePolygons[t], default: []].append(t) }
            } else {
                for t in 0..<triangles { polygons[UInt32(t)] = [t] }
            }
            if let depth {
                // Any of the face showing inside the region: the triangles that
                // won the depth test at a sample the region covers.
                let shown = depth.triangles(in: region)
                for (_, members) in polygons where members.contains(where: shown.contains) {
                    members.forEach { selection.faces.insert($0) }
                }
            } else {
                // Blender's face dot: the median of the polygon's corners.
                for (_, members) in polygons {
                    var corners = Set<Int>()
                    for t in members { for k in 0..<3 { corners.insert(Int(mesh.indices[3 * t + k])) } }
                    guard !corners.isEmpty else { continue }
                    let centre = corners.reduce(SIMD3<Float>.zero) { $0 + mesh.vertices[$1].position }
                        / Float(corners.count)
                    guard let s = ProjectedMesh.project(centre, clip: viewProjection * model, size: size),
                          region.contains(s) else { continue }
                    members.forEach { selection.faces.insert($0) }
                }
            }
        }
        return selection
    }

    /// The objects a region selects: any part of them for a box, the origin
    /// for a circle or a lasso. Hidden objects are never selected.
    public static func objects(in region: SelectionRegion,
                               objects candidates: [(name: String, origin: SIMD3<Float>,
                                                     bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                                                     visible: Bool)],
                               viewProjection: simd_float4x4, size: CGSize) -> [String] {
        guard region.isUsable else { return [] }
        if case .box(let rect) = region {
            return BoxSelect.objects(in: rect,
                                     objects: candidates.map { ($0.name, $0.bounds, $0.visible) },
                                     viewProjection: viewProjection, size: size)
        }
        return candidates.compactMap { candidate in
            guard candidate.visible,
                  let s = BoxSelect.project(candidate.origin, viewProjection: viewProjection, size: size),
                  region.contains(s) else { return nil }
            return candidate.name
        }
    }
}

// MARK: - the selection it makes

public extension EditSelection {
    /// A selection of `mode`'s own elements, with what they imply filled in:
    /// the vertices of selected edges and faces, the edges between selected
    /// vertices, and the faces all of whose corners (vertex mode) or sides
    /// (edge mode) are selected — Blender's `select_flush_mode` — so the
    /// viewport can show what Blender will hold before the mirror says so.
    /// Faces are whole polygons, never half a quad.
    static func implied(by own: EditSelection, mode: MeshSelectMode,
                        mesh: MeshData, topology: EditTopology?) -> EditSelection {
        let topology = topology.flatMap { $0.describes(mesh) ? $0 : nil }
        let real = topology?.realEdges ?? []
        func isReal(_ e: Int) -> Bool { real.isEmpty || real.contains(e) }
        let triangles = mesh.indices.count / 3
        let edgeCount = mesh.edges.count / 2
        var polygons: [UInt32: [Int]] = [:]
        if let topology, topology.trianglePolygons.count == triangles {
            for t in 0..<triangles { polygons[topology.trianglePolygons[t], default: []].append(t) }
        } else {
            for t in 0..<triangles { polygons[UInt32(t)] = [t] }
        }
        func corners(_ members: [Int]) -> Set<Int> {
            var out = Set<Int>()
            for t in members { for k in 0..<3 { out.insert(Int(mesh.indices[3 * t + k])) } }
            return out
        }
        var byEnds: [UInt64: Int] = [:]
        func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        for e in 0..<edgeCount where isReal(e) {
            byEnds[key(Int(mesh.edges[2 * e]), Int(mesh.edges[2 * e + 1]))] = e
        }
        /// A polygon's sides: the real edges among its triangles' sides.
        func sides(_ members: [Int]) -> [Int] {
            var out: [Int] = []
            for t in members {
                for k in 0..<3 {
                    let a = Int(mesh.indices[3 * t + k]), b = Int(mesh.indices[3 * t + (k + 1) % 3])
                    if let e = byEnds[key(a, b)] { out.append(e) }
                }
            }
            return out
        }

        var out = EditSelection()
        switch mode {
        case .vertex:
            out.vertices = own.vertices
            for e in 0..<edgeCount where isReal(e)
                && own.vertices.contains(Int(mesh.edges[2 * e]))
                && own.vertices.contains(Int(mesh.edges[2 * e + 1])) {
                out.edges.insert(e)
            }
            for (_, members) in polygons where corners(members).isSubset(of: own.vertices) {
                members.forEach { out.faces.insert($0) }
            }
        case .edge:
            out.edges = own.edges
            for e in own.edges where 2 * e + 1 < mesh.edges.count {
                out.vertices.insert(Int(mesh.edges[2 * e]))
                out.vertices.insert(Int(mesh.edges[2 * e + 1]))
            }
            for (_, members) in polygons {
                let s = sides(members)
                if !s.isEmpty, s.allSatisfy(own.edges.contains) { members.forEach { out.faces.insert($0) } }
            }
        case .face:
            out.faces = own.faces
            for (_, members) in polygons where members.contains(where: own.faces.contains) {
                members.forEach { out.faces.insert($0) }
                out.vertices.formUnion(corners(members))
                sides(members).forEach { out.edges.insert($0) }
            }
        }
        return out
    }
}

public extension BKObject {
    /// What a region gesture leaves selected on this object, in edit mode:
    /// the current selection combined with what the region covers by
    /// `action`, in the select mode's own elements, with what they imply.
    ///
    /// On the cage the edit selection numbers (`editCage`), as box select and
    /// taps are.
    func regionSelection(_ region: SelectionRegion, mode: MeshSelectMode,
                         action: SelectAction, current: EditSelection,
                         viewProjection: simd_float4x4, size: CGSize,
                         seeThrough: Bool) -> EditSelection {
        let mesh = editCage
        let hit = RegionSelect.elements(mesh: mesh, topology: editTopology, model: modelMatrix,
                                        viewProjection: viewProjection, size: size,
                                        region: region, mode: mode, seeThrough: seeThrough)
        var own = EditSelection()
        switch mode {
        case .vertex: own.vertices = action.applyRegion(current.vertices, inside: hit.vertices)
        case .edge:   own.edges = action.applyRegion(current.edges, inside: hit.edges)
        case .face:   own.faces = action.applyRegion(current.faces, inside: hit.faces)
        }
        return EditSelection.implied(by: own, mode: mode, mesh: mesh, topology: editTopology)
    }

    /// Why a Box, Circle or Lasso select in Edit Mode cannot be handed to the
    /// real Blender on this object, in words for the banner — or nil when it
    /// can: the mirror's report still names the drawn mesh's elements as
    /// Blender's, index for index (`editTopology`).
    ///
    /// When it does not, the viewport is drawing a mesh a modifier rebuilt
    /// (on device the mesh is Blender's evaluated one), and nothing the pass
    /// picks is one of Blender's elements. The only way left to tell Blender
    /// was `Bpy.selectVertices`, which deselects every vertex and then
    /// matches the picked ones by position. Measured in 5.2.1 with the app's
    /// context: a cube under a level-1 Subdivision Surface draws 26 vertices
    /// over Blender's 8; with all 8 selected, the fallback handed all 26 —
    /// what a lasso over everything sends — left 0 of 8 selected, since
    /// subdividing moves every corner. Under a Mirror it left 8 of 8, but
    /// the viewport then shows nothing selected either way, because the
    /// report cannot name what is. So the gesture is refused instead of
    /// wiping a selection the next Extrude or Delete would act on. With the
    /// modifier hidden in the viewport (or its Edit Mode display off) the
    /// drawn mesh is Blender's again — measured: 8 vertices and 12 triangles
    /// on both sides, for Subdivision Surface and for Mirror.
    ///
    /// For the real Blender only: the simulator's stand-in reads the
    /// interface's selection and is never pushed this way.
    func editRegionRefusal() -> String? {
        if let topology = editTopology, topology.describes(editCage), topology.describes(mesh) { return nil }
        if let undrawn = undrawnVertexCount {
            return "\(name) has \(undrawn) vertices, more than the viewport draws, so it is shown as its "
                + "bounds and has no vertices here to pick."
        }
        // The kinds that only move vertices leave the elements Blender's; the
        // rest make new ones. One hidden in the viewport changes nothing.
        let deforming: Set<ModifierKind> = [.smooth, .cast, .simpleDeform, .displace, .wave, .shrinkwrap,
                                            .laplacianSmooth, .correctiveSmooth, .lattice, .weightedNormal,
                                            .multires]
        let shown = modifiers.filter(\.showInViewport)
        let rebuilding = shown.filter { !deforming.contains($0.kind) }
        let names = (rebuilding.isEmpty ? shown : rebuilding).map(\.name)
        guard !names.isEmpty else {
            return "The viewport's mesh of \(name) does not line up with Blender's yet. Try again once it redraws."
        }
        let list = names.count == 1 ? "its modifier \(names[0]) rebuilds"
            : "its modifiers \(names.dropLast().joined(separator: ", ")) and \(names.last!) rebuild"
        return "In Edit Mode \(list) the mesh the viewport draws, so the vertices on screen are not "
            + "Blender's and a selection made over them cannot be handed to it. Hide "
            + (names.count == 1 ? "the modifier" : "them") + " in the viewport, or apply "
            + (names.count == 1 ? "it" : "them") + ", to select here."
    }
}

// MARK: - the screen and depth the pass works in

/// A view coordinate as an index into a row or column of `count` samples:
/// rounded by `rule`, and clamped to -1…`count` while still a floating-point
/// number, -1 and `count` standing for "before the first" and "past the last".
///
/// `Int(_:)` of a value past Int.max traps, and a vertex far enough out
/// projects past it. The review measured it, and a harness built from these
/// sources before the clamps repeated it: a 2 × 2 grid with one vertex at
/// X = 1e17, seen from the top in orthographic, puts a triangle corner at
/// x ≈ 1.6e19, and a box select with X-Ray off stopped the process in
/// `rasterise` (exit 133; "Double value cannot be converted to Int because
/// the result would be greater than Int.max") in vertex, edge and face mode
/// alike. The host suite now runs that case. Not a number counts as before
/// the first.
func clampedIndex(_ v: Double, _ rule: FloatingPointRoundingRule, count: Int) -> Int {
    guard !v.isNaN else { return -1 }
    return Int(min(max(v.rounded(rule), -1), Double(count)))
}

/// Every vertex of a mesh in view points, with a depth to compare by.
struct ProjectedMesh {
    /// Nil where the vertex is behind the eye, or so far out that its
    /// projection is not a number.
    var screen: [CGPoint?]
    /// Smaller is nearer: the distance along the view (clip w) in a
    /// perspective view, clip z in an orthographic one. Both grow with the
    /// distance from the eye.
    var depth: [Float]
    /// Each vertex in clip space, which `DepthBuffer` clips a triangle in
    /// where it reaches past the near plane.
    var clip: [SIMD4<Float>]
    var perspective: Bool
    let size: CGSize

    init(mesh: MeshData, clip matrix: simd_float4x4, size: CGSize) {
        // A perspective matrix makes w the distance along the view; an
        // orthographic one leaves w at 1 whatever the point.
        let row3 = SIMD3(matrix.columns.0.w, matrix.columns.1.w, matrix.columns.2.w)
        perspective = simd_length(row3) > 1e-6
        self.size = size
        screen = [CGPoint?](repeating: nil, count: mesh.vertices.count)
        depth = [Float](repeating: .infinity, count: mesh.vertices.count)
        clip = mesh.vertices.map { matrix * SIMD4($0.position, 1) }
        for i in clip.indices {
            guard let s = Self.screen(clip[i], size: size) else { continue }
            screen[i] = s
            depth[i] = depthOf(clip[i])
        }
    }

    /// A clip-space point's depth, as `depth` holds it.
    func depthOf(_ c: SIMD4<Float>) -> Float { perspective ? c.w : c.z / c.w }

    static func screen(_ c: SIMD4<Float>, size: CGSize) -> CGPoint? {
        guard c.w > 1e-5 else { return nil }
        let s = CGPoint(x: CGFloat(c.x / c.w * 0.5 + 0.5) * size.width,
                        y: CGFloat(1 - (c.y / c.w * 0.5 + 0.5)) * size.height)
        return s.x.isFinite && s.y.isFinite ? s : nil
    }

    static func project(_ p: SIMD3<Float>, clip: simd_float4x4, size: CGSize) -> CGPoint? {
        screen(clip * SIMD4(p, 1), size: size)
    }
}

/// The mesh rasterised over part of the view: the nearest depth, and which
/// triangle it belongs to, at the centre of each view point.
///
/// Blender's selection buffer, as far as selection needs it. Every triangle is
/// drawn, front- or back-facing, as Blender draws the edit mesh; the triangles
/// of hidden faces never reach the viewport's mesh, so they hide nothing.
struct DepthBuffer {
    let x0: Int, y0: Int, width: Int, height: Int
    var depth: [Float]
    var triangle: [Int32]
    let perspective: Bool
    /// How much nearer a surface has to be before it hides a point: a
    /// thousandth of the mesh's own depth, so the comparison means the same at
    /// any scale and in either projection.
    let tolerance: Float

    /// Nil when the rectangle is off the view.
    ///
    /// `mirrored`: the object's matrix turns space inside out (a negative
    /// determinant — a scale of -1 on one axis), which reverses every face's
    /// winding on screen. Blender flips its front face for such an object, so
    /// a face turned towards the view still draws as one.
    init?(view: ProjectedMesh, mesh: MeshData, covering rect: CGRect, size: CGSize,
          mirrored: Bool = false) {
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        x0 = Int(clipped.minX.rounded(.down)); y0 = Int(clipped.minY.rounded(.down))
        width = max(1, Int(clipped.maxX.rounded(.up)) - x0)
        height = max(1, Int(clipped.maxY.rounded(.up)) - y0)
        perspective = view.perspective
        depth = [Float](repeating: .infinity, count: width * height)
        triangle = [Int32](repeating: -1, count: width * height)
        var lo = Float.infinity, hi = -Float.infinity
        for d in view.depth where d.isFinite { lo = min(lo, d); hi = max(hi, d) }
        tolerance = hi >= lo ? max((hi - lo) * 1e-3, max(abs(hi), abs(lo)) * 1e-6, 1e-9) : 1e-6

        // Faces turned away first, then the ones turned towards the view,
        // which win anything within `tolerance` of them. Along a silhouette
        // a front and a back face share an edge at the same depth — the same
        // up to rounding, which differs between the two triangles — and a
        // sample on the outline went to whichever rounded nearer: measured on
        // Blender's own cube at 1366 × 900, two back faces won a sample each
        // at the outline, and a box over the cube took five faces where three
        // show. Drawing the front faces last with a plain `<=` still left
        // four or five at other sizes; the tolerance is what settles it.
        // Turned towards the view is clockwise here: view points count y
        // downwards, and Blender winds a face anticlockwise seen from outside
        // — the other way round on a mirrored object. Measured before the
        // flip, Blender's cube at scale.x = -1 in the 18-view sweep's nine
        // cube views: 6 faces taken in every view where 3 show (3 at +1).
        //
        // A triangle that reaches past the near plane is clipped there, as
        // the renderer's own clipping does (Metal keeps clip z ≥ 0, which in
        // perspective is w ≥ the camera's `near`), and what is left in front
        // is drawn. It used to be left out whole, on the theory that it could
        // only hide what is nearly at the eye — false for a floor, a wall or
        // terrain: measured, a 100 × 100 floor over a 21 × 21 grid one unit
        // below it took 0 hidden grid vertices at camera distance 200, where
        // the whole floor is in front, and 321 / 321 / 265 at 60 / 20 / 8,
        // where it reaches behind the eye and the viewport draws it opaque.
        // A point where an edge meets the plane is computed once per edge,
        // from its lower-numbered end, and numbered past the mesh's own
        // vertices, so the two triangles sharing the edge meet at exactly the
        // same point and `rasterise`'s shared-edge test still agrees.
        let count = mesh.indices.count / 3
        var cuts: [UInt64: (id: Int, at: CGPoint, depth: Float)] = [:]
        func cut(_ i: Int, _ j: Int) -> (id: Int, at: CGPoint, depth: Float)? {
            let (lo, hi) = i < j ? (i, j) : (j, i)
            let key = UInt64(lo) << 32 | UInt64(hi)
            if let known = cuts[key] { return known }
            let p = view.clip[lo], q = view.clip[hi]
            var c = p + (q - p) * (p.z / (p.z - q.z))
            c.z = 0
            guard let s = ProjectedMesh.screen(c, size: size) else { return nil }
            let made = (id: view.clip.count + cuts.count, at: s, depth: view.depthOf(c))
            cuts[key] = made
            return made
        }
        func finite(_ c: SIMD4<Float>) -> Bool { c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite }
        var polygon: [(id: Int, at: CGPoint, depth: Float)] = []
        for frontPass in [false, true] {
            for t in 0..<count {
                let ia = Int(mesh.indices[3 * t]), ib = Int(mesh.indices[3 * t + 1]), ic = Int(mesh.indices[3 * t + 2])
                guard ia < view.clip.count, ib < view.clip.count, ic < view.clip.count else { continue }
                let ca = view.clip[ia], cb = view.clip[ib], cc = view.clip[ic]
                if ca.z >= 0 && cb.z >= 0 && cc.z >= 0 {
                    // Wholly in front of the near plane: the common case,
                    // with no allocation.
                    guard let a = view.screen[ia], let b = view.screen[ib], let c = view.screen[ic] else { continue }
                    let turned = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) < 0) != mirrored
                    guard turned == frontPass else { continue }
                    rasterise(Int32(t), ia, a, view.depth[ia], ib, b, view.depth[ib], ic, c, view.depth[ic],
                              slack: frontPass ? tolerance : 0)
                    continue
                }
                // Past the near plane, or not a number anywhere: clipped, or
                // left out when there is nothing finite to clip.
                guard finite(ca), finite(cb), finite(cc) else { continue }
                polygon.removeAll(keepingCapacity: true)
                var whole = true
                for (i, j) in [(ia, ib), (ib, ic), (ic, ia)] {
                    let inI = view.clip[i].z >= 0, inJ = view.clip[j].z >= 0
                    if inI {
                        guard let s = view.screen[i] else { whole = false; break }
                        polygon.append((i, s, view.depth[i]))
                    }
                    if inI != inJ {
                        guard let made = cut(i, j) else { whole = false; break }
                        polygon.append(made)
                    }
                }
                guard whole, polygon.count >= 3 else { continue }
                // What is left in front of the plane projects to a convex
                // polygon wound as the triangle was; its signed area says
                // which way it faces.
                var twiceArea: CGFloat = 0
                for k in polygon.indices {
                    let p = polygon[k].at, q = polygon[(k + 1) % polygon.count].at
                    twiceArea += p.x * q.y - q.x * p.y
                }
                guard twiceArea != 0 else { continue }
                let turned = (twiceArea < 0) != mirrored
                guard turned == frontPass else { continue }
                for k in 1..<(polygon.count - 1) {
                    let a = polygon[0], b = polygon[k], c = polygon[k + 1]
                    rasterise(Int32(t), a.id, a.at, a.depth, b.id, b.at, b.depth, c.id, c.at, c.depth,
                              slack: frontPass ? tolerance : 0)
                }
            }
        }
    }

    /// One triangle into the buffer.
    ///
    /// Inside is decided edge by edge, each edge's test written from its two
    /// vertex numbers in a fixed order, so the two triangles sharing an edge
    /// ask exactly the same question of a sample on it and get the same
    /// answer. Asked per triangle from its own corners, a sample exactly on a
    /// silhouette edge rounded to just outside the front face (barycentric
    /// -1.9e-5, measured on Blender's cube) while the back face behind took
    /// it; widening every triangle by a tenth of a point instead let back
    /// faces poke out past the outline's corners (a sphere took 72 faces where
    /// 55 show). With the tests agreeing, a sample on the edge is in both
    /// faces, and the front one — drawn last, winning within `slack` — has it.
    private mutating func rasterise(_ id: Int32, _ ia: Int, _ a: CGPoint, _ da: Float,
                                    _ ib: Int, _ b: CGPoint, _ db: Float,
                                    _ ic: Int, _ c: CGPoint, _ dc: Float, slack: Float) {
        let area = Double((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
        // Edge-on: it covers no area, and hides nothing.
        guard abs(area) > 1e-9 else { return }
        // Clamped to the buffer before they become Ints (`clampedIndex`): a
        // corner can project as far out as 1.6e19 points.
        let minX = x0 + max(0, clampedIndex(min(a.x, b.x, c.x) - CGFloat(x0), .down, count: width))
        let maxX = x0 + min(width - 1, clampedIndex(max(a.x, b.x, c.x) - CGFloat(x0), .up, count: width))
        let minY = y0 + max(0, clampedIndex(min(a.y, b.y, c.y) - CGFloat(y0), .down, count: height))
        let maxY = y0 + min(height - 1, clampedIndex(max(a.y, b.y, c.y) - CGFloat(y0), .up, count: height))
        guard minX <= maxX, minY <= maxY else { return }
        // Each edge from its lower-numbered end, and the side the third
        // corner is on.
        struct Edge {
            let ox: Double, oy: Double, dx: Double, dy: Double, side: Double
            func value(_ x: Double, _ y: Double) -> Double { dx * (y - oy) - dy * (x - ox) }
        }
        func edge(_ i: Int, _ p: CGPoint, _ j: Int, _ q: CGPoint, opposite r: CGPoint) -> Edge {
            let (o, e) = i < j ? (p, q) : (q, p)
            let dx = Double(e.x - o.x), dy = Double(e.y - o.y)
            let side = dx * (Double(r.y) - Double(o.y)) - dy * (Double(r.x) - Double(o.x))
            return Edge(ox: Double(o.x), oy: Double(o.y), dx: dx, dy: dy, side: side < 0 ? -1 : 1)
        }
        let eA = edge(ib, b, ic, c, opposite: a), eB = edge(ic, c, ia, a, opposite: b)
        let eC = edge(ia, a, ib, b, opposite: c)
        // Perspective-correct: 1/w is what varies linearly across the screen;
        // an orthographic depth varies linearly itself.
        let qa = perspective ? 1 / da : da, qb = perspective ? 1 / db : db, qc = perspective ? 1 / dc : dc
        let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
        let cx = Double(c.x), cy = Double(c.y)
        for py in minY...maxY {
            let sy = Double(py) + 0.5
            for px in minX...maxX {
                let sx = Double(px) + 0.5
                guard eA.value(sx, sy) * eA.side >= 0, eB.value(sx, sy) * eB.side >= 0,
                      eC.value(sx, sy) * eC.side >= 0 else { continue }
                let w0 = Float(((bx - sx) * (cy - sy) - (by - sy) * (cx - sx)) / area)
                let w1 = Float(((cx - sx) * (ay - sy) - (cy - sy) * (ax - sx)) / area)
                let w2 = 1 - w0 - w1
                let q = w0 * qa + w1 * qb + w2 * qc
                let d = perspective ? 1 / q : q
                let k = (py - y0) * width + (px - x0)
                if d <= depth[k] + slack { depth[k] = min(d, depth[k]); triangle[k] = id }
            }
        }
    }

    /// Whether a point at `d` shows at `s`, or the surface hides it.
    ///
    /// Judged over the point and its eight neighbours, the way Blender's
    /// vertex dot is a few pixels across: a point on the surface is at the
    /// surface's own depth, which at a neighbouring sample differs by the
    /// surface's slope. So it shows when it is no farther than the farthest
    /// neighbour plus that neighbourhood's own spread — and always when its
    /// own sample sees past the mesh. A vertex also shows when any neighbour
    /// does (`silhouette`): its dot sits on the outline, half over nothing.
    func isVisible(_ s: CGPoint, depth d: Float, silhouette: Bool = true) -> Bool {
        let px = clampedIndex(s.x - CGFloat(x0), .down, count: width)
        let py = clampedIndex(s.y - CGFloat(y0), .down, count: height)
        guard px >= 0, px < width, py >= 0, py < height, depth[py * width + px].isFinite else { return true }
        var lo = Float.infinity, hi = -Float.infinity
        for dy in -1...1 {
            for dx in -1...1 {
                let x = px + dx, y = py + dy
                guard x >= 0, x < width, y >= 0, y < height else {
                    if silhouette { return true }
                    continue
                }
                let v = depth[y * width + x]
                guard v.isFinite else {
                    if silhouette { return true }
                    continue
                }
                lo = min(lo, v); hi = max(hi, v)
            }
        }
        return d <= hi + tolerance + (hi - lo)
    }

    /// Whether any of an edge shows inside the region: samples along it,
    /// depth interpolated as the rasteriser does.
    ///
    /// Not at its ends. An end is a vertex, and a vertex on the silhouette
    /// shows; the edges leaving it for the hidden side of the mesh share that
    /// point without showing anywhere else. Sampled to its ends, the cube's
    /// three edges into its hidden corner counted as shown (measured by
    /// tests/regionselect: 12 edges where 9 are on screen), and 3 points clear
    /// of the ends, still 10: near a silhouette corner a hidden edge is only
    /// a sliver behind the face in front. So the samples keep to the middle
    /// 70% of the edge, and a sample counts only on its own depth, not on a
    /// neighbour seeing past the outline. Only when the region reaches no
    /// part of that middle — a small circle on one end — are the rest of it
    /// sampled, 3 points clear of the ends.
    func edgeShows(from a: CGPoint, _ da: Float, to b: CGPoint, _ db: Float,
                   perspective: Bool, in region: SelectionRegion) -> Bool {
        let length = hypot(b.x - a.x, b.y - a.y)
        var reached = false
        func shows(from lo: Float, to hi: Float) -> Bool {
            // Counted while still a floating-point number: an edge to a far
            // vertex is longer than Int.max points (`clampedIndex`).
            let wanted = length * CGFloat(hi - lo) / 3
            let samples = wanted.isNaN ? 64 : Int(min(64, max(1, wanted)))
            for k in 0...samples {
                let t = lo + (hi - lo) * Float(k) / Float(samples)
                let p = CGPoint(x: a.x + (b.x - a.x) * CGFloat(t), y: a.y + (b.y - a.y) * CGFloat(t))
                guard region.contains(p) else { continue }
                reached = true
                let d = perspective ? 1 / ((1 - t) / da + t / db) : (1 - t) * da + t * db
                if isVisible(p, depth: d, silhouette: false) { return true }
            }
            return false
        }
        if shows(from: 0.15, to: 0.85) { return true }
        if reached { return false }
        let clear: Float = length > 8 ? Float(3 / length) : 0.5
        return shows(from: clear, to: 1 - clear)
    }

    /// The triangles that won the depth test at a sample inside the region.
    func triangles(in region: SelectionRegion) -> Set<Int> {
        let covered = region.coverage(x0: x0, y0: y0, width: width, height: height)
        var out = Set<Int>()
        for k in 0..<(width * height) where covered[k] && triangle[k] >= 0 {
            out.insert(Int(triangle[k]))
        }
        return out
    }
}
