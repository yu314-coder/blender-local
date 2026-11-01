import Foundation
import simd

// Blender's two interactive cutting tools, Loop Cut (Ctrl+R) and Knife (K),
// driven by the app's own picking.
//
// Both are modal in Blender and need a pointer in a window: round 3's review
// measured `mesh.knife_tool` returning PASS_THROUGH with no cut and no modal
// handler under the borrowed 3D View, from EXEC and INVOKE alike, and
// `loopcut_slide` invoked returning CANCELLED. Their non-modal cores do run
// under `_blenderkit_context.temp_override_view3d`: `loopcut_slide` given an
// edge index, and `knife_project` given an outline. So the app does what the
// modal half does — picks the edge, collects the points — and hands Blender
// the call the modal half would have made. What is shown before the cut is
// Blender's own answer for it: the ring comes from `_blenderkit_loopcut.ring`,
// a port of Blender's edge-ring walker held to Blender's cut on every edge of
// seven meshes (scripts/run-cuttools-blender-check.sh).

// MARK: - Loop Cut

/// The edges Blender's loop cut through one edge crosses, as
/// `_blenderkit_loopcut.ring` reads them off the edit mesh.
public struct LoopCutRing: Equatable, Sendable {
    /// The Blender edge it was asked for.
    public var edge: Int
    /// Every Blender edge the cut crosses, the picked one included.
    public var edges: [Int]
    /// Each preview line's two edges, as four vertex indices: the first edge's
    /// two ends, then the second's, each in the order Blender interpolates
    /// them (`edgering_find_order`), so cut i of n sits at i / (n + 1) from
    /// the first end to the second on both.
    public var segments: [[Int]]
    /// The edge has no quad either side. Blender's preview is then points on
    /// the edge alone, and the cut subdivides that edge.
    public var single: Bool
    /// Each crossed edge's two vertices, in `edges`' order.
    public var ends: [[Int]]
    /// How many vertices Blender's edit mesh had when it answered, so an
    /// answer about another mesh is never drawn over this one.
    public var vertexCount: Int

    public init(edge: Int, edges: [Int], segments: [[Int]], single: Bool, ends: [[Int]], vertexCount: Int) {
        self.edge = edge; self.edges = edges; self.segments = segments
        self.single = single; self.ends = ends; self.vertexCount = vertexCount
    }

    /// The ring from the line `_blenderkit_loopcut.ring_json` prints, or nil
    /// for anything else — its refusal included, which `refusal(json:)` reads.
    public init?(json: String) {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edge = object["edge"] as? Int, let edges = object["edges"] as? [Int],
              let segments = object["segments"] as? [[Int]], let single = object["single"] as? Bool,
              let ends = object["ends"] as? [[Int]], let vertices = object["vertices"] as? Int,
              segments.allSatisfy({ $0.count == 4 }), ends.allSatisfy({ $0.count == 2 }),
              ends.count == edges.count
        else { return nil }
        self.init(edge: edge, edges: edges, segments: segments, single: single, ends: ends,
                  vertexCount: vertices)
    }

    /// Why Blender would not say, from `ring_json`'s `{"refused": …}`.
    public static func refusal(json: String) -> String? {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["refused"] as? String
    }

    /// Blender's preview for `cuts` cuts on the vertices at `positions` (the
    /// drawn cage, as Blender previews on its deformed cage): a line across
    /// each quad of the ring per cut (`view3d_preselect_mesh_edgering_update_edges_from_edge`),
    /// or for an edge with no quad the points the cut puts on it
    /// (`…_update_verts_from_edge`). Lines come as pairs of points. Nil when
    /// an index is past `positions`: the ring is about another mesh.
    public func preview(cuts: Int, positions: [SIMD3<Float>]) -> (lines: [SIMD3<Float>], points: [SIMD3<Float>])? {
        let n = max(1, cuts)
        func at(_ i: Int) -> SIMD3<Float>? { positions.indices.contains(i) ? positions[i] : nil }
        if single {
            guard let pair = ends.first, let a = at(pair[0]), let b = at(pair[1]) else { return nil }
            let points = (1...n).map { k -> SIMD3<Float> in
                let f = Float(k) / Float(n + 1)
                return a + (b - a) * f
            }
            return ([], points)
        }
        var lines: [SIMD3<Float>] = []
        lines.reserveCapacity(segments.count * n * 2)
        for s in segments {
            guard let a0 = at(s[0]), let a1 = at(s[1]), let b0 = at(s[2]), let b1 = at(s[3]) else { return nil }
            for k in 1...n {
                let f = Float(k) / Float(n + 1)
                lines.append(a0 + (a1 - a0) * f)
                lines.append(b0 + (b1 - b0) * f)
            }
        }
        return (lines, [])
    }
}

public enum LoopCut {
    /// Blender's soft range for Number of Cuts (`MESH_OT_loopcut`, 1 to 100;
    /// its hard limit is a million), which the panel scrubs within.
    public static let softMaxCuts = 100

    /// Blender's index for the viewport edge `drawn` of the cage: the edge
    /// with the same two vertices in `topology.blenderEdges`, which the
    /// mirror sends in Blender's own order. Vertex indices are Blender's
    /// whenever `topology` describes the cage (`EditTopology.describes`);
    /// the viewport's own edge list is built from triangles and numbers its
    /// edges otherwise, diagonals included, so its index is never Blender's.
    /// Nil when the edge is not one of Blender's (a quad's diagonal) or the
    /// topology no longer describes the cage.
    public static func blenderEdge(drawn: Int, cage: MeshData, topology: EditTopology) -> Int? {
        guard topology.describes(cage), drawn >= 0, 2 * drawn + 1 < cage.edges.count else { return nil }
        let a = cage.edges[2 * drawn], b = cage.edges[2 * drawn + 1]
        let ends = topology.blenderEdges
        var e = 0
        while 2 * e + 1 < ends.count {
            let x = ends[2 * e], y = ends[2 * e + 1]
            if (x == a && y == b) || (x == b && y == a) { return e }
            e += 1
        }
        return nil
    }

    /// The question the viewport asks while the pointer is over an edge.
    public static func ringQuery(_ blenderEdge: Int) -> String {
        "import _blenderkit_loopcut\n_blenderkit_loopcut.ring_json(\(blenderEdge))"
    }

    /// Why Loop Cut cannot work on `object` here, in words for the banner,
    /// or nil when it can.
    public static func refusal(object: BKObject?, usesRealBlender: Bool) -> String? {
        CutTool.loopCut.refusal(object: object, usesRealBlender: usesRealBlender)
    }
}

/// Which of the two tools, for what they share: the refusals and the words.
public enum CutTool: Sendable {
    case loopCut, knife

    /// Blender's toolbar name.
    public var label: String { self == .loopCut ? "Loop Cut" : "Knife" }

    /// The row of Blender's menus that starts the same modal tool, which in
    /// the app's Mesh menu picks the tool: its label, the operator Blender's
    /// row runs, the menu it is in (5.2.1, tests/names/reference) and the row
    /// it follows there.
    public var menuRow: (label: String, idname: String, menu: String, after: String) {
        switch self {
        case .loopCut: return ("Loop Cut and Slide", "mesh.loopcut_slide", "VIEW3D_MT_edit_mesh_edges", "Edge Slide")
        case .knife:   return ("Knife Topology Tool", "mesh.knife_tool", "VIEW3D_MT_edit_mesh", "Knife Project")
        }
    }

    /// The tool the row picks.
    public var tool: ActiveTool { self == .loopCut ? .loopCut : .knife }

    /// Why the tool cannot cut `object` with the real Blender, or nil.
    ///
    /// The edge a loop cut is given is an index into Blender's edit mesh, so
    /// Loop Cut needs the drawn cage to be Blender's: under a modifier that
    /// rebuilds the mesh the viewport's elements are not Blender's, and the
    /// same words as Box, Circle and Lasso's refuse (`BKObject.editRegionRefusal`).
    /// The Knife does not: its path is lines of sight, which are the same
    /// whatever the viewport draws, and Blender's Knife cuts the edit cage
    /// along them — measured in 5.2.1, a cube under a Subdivision Surface
    /// was cut at the same three crossings as the bare cube, to 5e-7 m.
    public func refusal(object: BKObject?, usesRealBlender: Bool) -> String? {
        guard usesRealBlender else {
            return "\(label) cuts through Blender's 3D View, which the simulator's stand-in for "
                + "Blender does not have."
        }
        guard let object else { return "\(label) cuts the mesh being edited, and no object is active." }
        guard object.hasEditMode, !object.editsPoints else {
            return "\(label) cuts a mesh, and \(object.name) is not one."
        }
        guard self == .loopCut else { return nil }
        return object.editRegionRefusal(picking: "an edge picked on them", toDo: "cut a loop here")
    }
}

public extension LastOperator {
    /// Blender's Loop Cut and Slide, as its toolbar's Loop Cut runs it: the
    /// ring through Blender edge `edge`, cut `cuts` times and slid by the
    /// Edge Slide's Factor — the line Blender's Info editor logs for a loop
    /// cut, inside the borrowed 3D View it needs. Measured in 5.2.1 with the
    /// app's context: a cube's edge 4 went from 8/12/6 to 12/20/10 vertices,
    /// edges and faces; Factor 0.5 put the new loop at x = 0.5 and -0.5 at
    /// x = -0.5; three cuts gave 20/36/18. The panel's fields are Blender's
    /// Loop Cut and Edge Slide rows, each measured changing the result (Even
    /// on a grid with a tilted row moved the loop 0.2, Flipped with Even
    /// 0.6 and alone nothing; Smoothness 1 bulged a cube's loop 0.78 and
    /// Falloff then moved it 0.39 between Inverse Square and Linear, and
    /// nothing at Smoothness 0). No row is greyed: Blender's panel greys
    /// none of them (`transform_poll_property` has no rule for these, and
    /// `MESH_OT_loopcut` no `poll_property`), and it shows Edge Slide's Clamp,
    /// Mirror Editing and Correct UVs too. Clamp and Correct UVs are on by
    /// default (5.2.1's RNA), and so is Mirror Editing as Blender's own Loop
    /// Cut records it: in a 3D View `initTransInfo` leaves mirroring on for an
    /// edit mesh and `saveTransform` stores `mirror` True (its RNA default,
    /// False, is what a headless call gets). Measured in 5.2.1 with the mesh's
    /// X mirror on: a loop cut across X stays on the mirror plane slid by 0.5
    /// with Mirror Editing on, and moves to x = 0.5 with it off; with the
    /// mesh's mirror off the two are the same.
    ///
    /// `_blenderkit_loopcut.check` runs first, in the same block: the edge is
    /// there and not hidden (on a hidden edge Blender answers FINISHED and
    /// cuts nothing), `object_index` names the active object (Blender counts
    /// the objects in Edit Mode, active first), and the result is inside the
    /// vertex budget.
    static func loopCutAndSlide(edge: Int, cuts: Int = 1, objectIndex: Int = 0) -> LastOperator {
        func toggle(_ key: String, _ label: String, on: Bool = false) -> Parameter {
            var p = Parameter(key: key, label: label,
                              kind: .literal([Parameter.Option("False", "Off"), Parameter.Option("True", "On")]),
                              value: on ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
            p.member = "TRANSFORM_OT_edge_slide"
            return p
        }
        var number = Parameter(key: "number_cuts", label: "Number of Cuts", kind: .integer,
                               value: Double(min(max(cuts, 1), LoopCut.softMaxCuts)), softMin: 1,
                               softMax: Double(LoopCut.softMaxCuts), step: 0.05)
        number.member = "MESH_OT_loopcut"
        var smoothness = Parameter(key: "smoothness", label: "Smoothness", kind: .float,
                                   value: 0, softMin: -4, softMax: 4, step: 0.004, unit: .none)
        smoothness.member = "MESH_OT_loopcut"
        var falloff = Parameter(key: "falloff", label: "Falloff",
                                kind: .choice([Parameter.Option("SMOOTH", "Smooth"),
                                               Parameter.Option("SPHERE", "Sphere"),
                                               Parameter.Option("ROOT", "Root"),
                                               Parameter.Option("INVERSE_SQUARE", "Inverse Square"),
                                               Parameter.Option("SHARP", "Sharp"),
                                               Parameter.Option("LINEAR", "Linear")]),
                                value: 3, softMin: 0, softMax: 5, step: 0.02)
        falloff.member = "MESH_OT_loopcut"
        // Blender's hard range, -10 to 10, which its panel takes typed: past
        // ±1 Clamp decides whether the loop stops at the ring's ends (measured
        // in 5.2.1: Factor 1.5 put a cube's loop at z = -1 clamped, -1.5 not),
        // and within ±1 a Clamp row could change nothing.
        var factor = Parameter(key: "value", label: "Factor", kind: .float,
                               value: 0, softMin: -10, softMax: 10, step: 0.004, unit: .none)
        factor.member = "TRANSFORM_OT_edge_slide"
        var made = LastOperator(name: "Loop Cut and Slide", call: "bpy.ops.mesh.loopcut_slide",
                                parameters: [number, smoothness, falloff, factor, toggle("use_even", "Even"),
                                             toggle("flipped", "Flipped"), toggle("use_clamp", "Clamp", on: true),
                                             toggle("mirror", "Mirror Editing", on: true),
                                             toggle("correct_uv", "Correct UVs", on: true)],
                                restoration: .restoreMesh, needsEditMode: true)
        made.memberArguments = ["MESH_OT_loopcut": ["\"object_index\": \(objectIndex)", "\"edge_index\": \(edge)"]]
        made.lead = "import _blenderkit_context, _blenderkit_loopcut\n"
            + "_blenderkit_loopcut.check(\(edge), @arg:number_cuts@, \(objectIndex))"
        made.within = "_blenderkit_context.temp_override_view3d('Loop Cut')"
        made.refusal = "Loop Cut and Slide found no edge \(edge) to cut across"
        return made
    }

    /// Blender's Knife (K) along a drawn path, through the knife Knife
    /// Project runs (`_blenderkit_knife.drawing`, whose docstring has what
    /// was measured): `path` is in world space, on the lines of sight from
    /// `eye` (perspective) or along `forward` (orthographic), and the cut is
    /// the one those lines of sight make, as Blender's Knife cuts along what
    /// it draws on the screen. Cut Through off cuts only what the view sees,
    /// as Blender's Knife does with Occlude Geometry on (its default).
    ///
    /// The redo panel and the undo step carry the name Blender's history
    /// gives a knife cut, its operator's: Knife Topology Tool. The Info line
    /// is the call that ran, `knife_project`, whose one argument is Cut
    /// Through.
    static func knife(path: [SIMD3<Float>], eye: SIMD3<Float>, forward: SIMD3<Float>,
                      up: SIMD3<Float>, orthographic: Bool, cutThrough: Bool = false) -> LastOperator {
        var made = LastOperator(
            name: "Knife Topology Tool", call: "bpy.ops.mesh.knife_project",
            parameters: [
                Parameter(key: "cut_through", label: "Cut Through",
                          kind: .literal([Parameter.Option("False", "Off"), Parameter.Option("True", "On")]),
                          value: cutThrough ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)],
            restoration: .restoreMesh, needsEditMode: true)
        // Every digit the Float has, not the panel's four decimals: the cut
        // is the plane through the eye and two of these, so rounding a point
        // turns the plane. Swift writes the shortest form that reads back as
        // the same Float, which Python takes as it is ("1e-05" included).
        func f(_ x: Float) -> String { x == 0 ? "0" : "\(x)" }
        func v(_ p: SIMD3<Float>) -> String { "(\(f(p.x)), \(f(p.y)), \(f(p.z)))" }
        // Knife Project cuts every mesh in Edit Mode
        // (`BKE_view_layer_array_from_objects_in_edit_mode_unique_data`), and
        // the mesh backup a re-run starts from holds the active one alone, so
        // with another mesh selected the panel would cut that one twice.
        made.actsOnSelection = true
        made.lead = "import _blenderkit_knife"
        made.within = "_blenderkit_knife.drawing([" + path.map(v).joined(separator: ", ") + "], "
            + "eye=\(v(eye)), forward=\(v(forward)), up=\(v(up)), ortho=\(orthographic ? "True" : "False"))"
        return made
    }
}

// MARK: - Knife

/// The Knife's path while it is being drawn: world positions, one per tap.
///
/// Each is on the line of sight the tap was made along — where it met the
/// mesh, or, past the mesh, at the depth of the object's middle. The cut is
/// made from the view as it is when Done is pressed (`LastOperator.knife`),
/// along the straight lines the overlay draws between the points from that
/// view, so what is drawn at Done is what is cut.
public struct KnifePath: Equatable, Sendable {
    public var points: [SIMD3<Float>] = []
    /// The object it is drawn over, so a path is never cut into another.
    public var object: UUID

    public init(object: UUID) { self.object = object }

    /// Adds a point, unless it is where the last one is.
    public mutating func add(_ p: SIMD3<Float>) {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return }
        if let last = points.last, simd_distance(last, p) < 1e-7 { return }
        points.append(p)
    }

    /// The size of the view, in points, the last point was tapped in: what
    /// `cutPoints` measures a point's closeness on screen in at Confirm.
    public var viewSize: SIMD2<Float>?

    /// Done cuts two points or more, as Blender's Knife cuts nothing before
    /// its second click.
    public var canCut: Bool { points.count >= 2 }

    /// Points closer than this on screen (view points) are one point of the
    /// cut. Blender's knife ignores a segment shorter than a pixel
    /// (`knife_find_line_hits`, interactive: `len_squared_v2v2(s1, s2) < 1`).
    public static let samePlace: Float = 1

    /// The path as it is cut from `view`: each point that lands within
    /// `samePlace` of an earlier one on screen becomes that earlier point.
    ///
    /// The cut is the planes the eye and the points' lines of sight make, so
    /// two points on one line of sight make no plane at all. Points can get
    /// there by orbiting between taps, and Knife Project then cut something
    /// the overlay never showed — round 4's review, desktop 5.2.1: p1 on a
    /// cube's face, p2 on the same line of sight at 1.8 times the depth, p3
    /// across the face, cut to 11/14/6 with a duplicate vertex, two loose
    /// edges and the face not split, where the overlay drew one line from p1
    /// to p3. Drawn from this view, such a path is a dot then a line, and
    /// that is what is cut: p1 to p3. A point that comes back to an earlier
    /// one closes the path there, as a click on the first point does.
    /// Consecutive repeats are dropped.
    public func cutPoints(in view: KnifeView) -> [SIMD3<Float>] {
        var kept: [(point: SIMD3<Float>, screen: SIMD2<Float>?)] = []
        var out: [SIMD3<Float>] = []
        for p in points {
            let s = view.project(p)
            var same: SIMD3<Float>?
            for k in kept {
                if let s, let ks = k.screen {
                    if simd_distance(s, ks) < Self.samePlace { same = k.point; break }
                } else if simd_distance(p, k.point) < 1e-7 {
                    same = k.point; break
                }
            }
            let point = same ?? p
            if same == nil { kept.append((p, s)) }
            if out.last != point { out.append(point) }
        }
        return out
    }

    /// The overlay: a line per segment, as pairs, and a dot per point.
    public var lines: [SIMD3<Float>] {
        guard points.count >= 2 else { return [] }
        var out: [SIMD3<Float>] = []
        for i in 0..<(points.count - 1) { out += [points[i], points[i + 1]] }
        return out
    }

    /// Where a tap at `ray` puts the next point: the nearest hit on the
    /// surface (world space), or the point on the ray at the depth of
    /// `centre` along the view's `forward`.
    public static func point(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                             surface: SIMD3<Float>?, centre: SIMD3<Float>,
                             forward: SIMD3<Float>) -> SIMD3<Float> {
        if let surface { return surface }
        let along = simd_dot(ray.direction, forward)
        guard abs(along) > 1e-6 else { return ray.origin + ray.direction }
        let t = simd_dot(centre - ray.origin, forward) / along
        return ray.origin + ray.direction * t
    }
}

// MARK: - Knife snapping

/// The app's view as the Knife measures in it: the view-projection and the
/// view's size in points, which is the unit Blender's knife thresholds are
/// in (`KMAXDIST`, 10 × the interface scale; a point of the app is a pixel
/// of Blender's at scale 1, as on a Retina display at its default).
public struct KnifeView: Sendable {
    public var viewProjection: simd_float4x4
    public var size: SIMD2<Float>

    public init(viewProjection: simd_float4x4, size: SIMD2<Float>) {
        self.viewProjection = viewProjection; self.size = size
    }

    /// Where `p` lands, in view points from the top left, or nil behind the eye.
    public func project(_ p: SIMD3<Float>) -> SIMD2<Float>? {
        let clip = viewProjection * SIMD4(p, 1)
        guard clip.w > 1e-5 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2((ndc.x * 0.5 + 0.5) * size.x, (1 - (ndc.y * 0.5 + 0.5)) * size.y)
    }

    /// The line of sight through the view point `s`, near to far, as
    /// `ViewportCamera.ray(atNDC:)` makes it.
    public func ray(at s: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let ndc = SIMD2(s.x / size.x * 2 - 1, 1 - s.y / size.y * 2)
        let inverse = viewProjection.inverse
        let near = inverse * SIMD4(ndc.x, ndc.y, 0, 1)
        let far = inverse * SIMD4(ndc.x, ndc.y, 1, 1)
        let o = SIMD3(near.x, near.y, near.z) / near.w
        let f = SIMD3(far.x, far.y, far.z) / far.w
        return (o, simd_normalize(f - o))
    }
}

/// The mesh the Knife snaps to, in world space: Blender's edit cage as its
/// knife reads it (`knifetool_init_obinfo`: the cage's coordinates; the
/// faces that are not hidden, as the viewport draws them in Edit Mode).
public struct KnifeCage: Sendable {
    public var positions: [SIMD3<Float>]
    /// Three vertex indices per triangle.
    public var triangles: [Int]
    /// The Blender polygon each triangle belongs to.
    public var trianglePolygons: [Int]
    /// Each polygon's sides, as vertex pairs: the edges of its triangles that
    /// no other triangle of the same polygon shares, so a quad's diagonal,
    /// which Blender has no edge for, is not one of them.
    public private(set) var polygonEdges: [[SIMD2<Int>]]

    public init(positions: [SIMD3<Float>], triangles: [Int], trianglePolygons: [Int]) {
        self.positions = positions; self.triangles = triangles; self.trianglePolygons = trianglePolygons
        let polygons = (trianglePolygons.max() ?? -1) + 1
        var counts = Array(repeating: [SIMD2<Int>: Int](), count: max(polygons, 0))
        var order = Array(repeating: [SIMD2<Int>](), count: max(polygons, 0))
        for t in 0..<min(trianglePolygons.count, triangles.count / 3) {
            let f = trianglePolygons[t]
            guard f >= 0 else { continue }
            for k in 0..<3 {
                let a = triangles[3 * t + k], b = triangles[3 * t + (k + 1) % 3]
                let key = SIMD2(min(a, b), max(a, b))
                if counts[f][key] == nil { order[f].append(key) }
                counts[f][key, default: 0] += 1
            }
        }
        polygonEdges = (0..<max(polygons, 0)).map { f in order[f].filter { counts[f][$0] == 1 } }
    }

    /// The cage of `object` from the mirror, when its report describes the
    /// mesh on screen: the drawn vertices (Blender's own coordinates where a
    /// deforming modifier moves what is drawn, `blenderPositions`), its
    /// triangles and the polygon each came from. Nil otherwise — a modifier
    /// that rebuilds the mesh draws elements that are not Blender's.
    public init?(object: BKObject) {
        let cage = object.editCage
        guard let topology = object.editTopology, topology.describes(cage), topology.describes(object.mesh) else {
            return nil
        }
        let local = topology.blenderPositions.count == cage.vertices.count
            ? topology.blenderPositions : cage.vertices.map(\.position)
        let model = object.modelMatrix
        self.init(positions: local.map { p in
                      let w = model * SIMD4(p, 1)
                      return SIMD3(w.x, w.y, w.z)
                  },
                  triangles: cage.indices.map { Int($0) },
                  trianglePolygons: topology.trianglePolygons.map { Int($0) })
    }

    /// The cage Blender describes in `_blenderkit_knife.cage_json`'s line:
    /// world positions and each visible face's vertices, fanned into
    /// triangles. Nil for anything else.
    public init?(json: String) {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flat = object["positions"] as? [Double], flat.count % 3 == 0,
              let faces = object["faces"] as? [[Int]]
        else { return nil }
        let positions = stride(from: 0, to: flat.count, by: 3).map {
            SIMD3(Float(flat[$0]), Float(flat[$0 + 1]), Float(flat[$0 + 2]))
        }
        var triangles: [Int] = [], polygons: [Int] = []
        for (f, face) in faces.enumerated() where face.count >= 3 {
            guard face.allSatisfy({ positions.indices.contains($0) }) else { return nil }
            for k in 1..<(face.count - 1) {
                triangles += [face[0], face[k], face[k + 1]]
                polygons.append(f)
            }
        }
        self.init(positions: positions, triangles: triangles, trianglePolygons: polygons)
    }

    /// The nearest face the ray meets, both sides counting, as Blender's
    /// knife ray casts its BVH (`knife_bvh_raycast`).
    public func rayCast(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>))
        -> (polygon: Int, distance: Float, point: SIMD3<Float>)? {
        var best: (polygon: Int, distance: Float)?
        for t in 0..<min(trianglePolygons.count, triangles.count / 3) {
            let a = positions[triangles[3 * t]], b = positions[triangles[3 * t + 1]], c = positions[triangles[3 * t + 2]]
            if let d = Self.rayTriangle(ray.origin, ray.direction, a, b, c), d >= 0,
               best == nil || d < best!.distance {
                best = (trianglePolygons[t], d)
            }
        }
        return best.map { ($0.polygon, $0.distance, ray.origin + ray.direction * $0.distance) }
    }

    /// Möller–Trumbore, two-sided, with a determinant test relative to the
    /// triangle's size so a millimetre face is hit as surely as a metre one.
    static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                            _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-12 * simd_length(e1) * simd_length(e2) + 1e-30 else { return nil }
        let inv = 1 / det
        let t0 = o - a
        let u = simd_dot(t0, p) * inv
        guard u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        let q = simd_cross(t0, e1)
        let v = simd_dot(d, q) * inv
        guard v >= -1e-6, u + v <= 1 + 1e-6 else { return nil }
        return simd_dot(e2, q) * inv
    }

    /// The face nearest `pointer` on screen within `within` points that the
    /// view sees there — what Blender's knife falls back on when the pointer
    /// is just off the mesh (`knife_find_closest_face`: `EDBM_face_find_nearest`
    /// in the selection buffer, KMAXDIST). A face counts where its nearest
    /// point on screen is not hidden behind another.
    public func nearestVisiblePolygon(to pointer: SIMD2<Float>, within: Float, in view: KnifeView) -> Int? {
        // Each vertex projected once, and nothing more done for a pointer
        // nowhere near the mesh on screen: a hover over empty space asks this
        // on every move, over meshes of any size.
        let screen = positions.map { view.project($0) }
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for s in screen { if let s { low = simd_min(low, s); high = simd_max(high, s) } }
        guard pointer.x >= low.x - within, pointer.y >= low.y - within,
              pointer.x <= high.x + within, pointer.y <= high.y + within else { return nil }
        var candidates: [(polygon: Int, distance: Float, at: SIMD2<Float>)] = []
        var nearest = [Int: (Float, SIMD2<Float>)]()
        for t in 0..<min(trianglePolygons.count, triangles.count / 3) {
            guard let a = screen[triangles[3 * t]], let b = screen[triangles[3 * t + 1]],
                  let c = screen[triangles[3 * t + 2]] else { continue }
            let lo = simd_min(a, simd_min(b, c)), hi = simd_max(a, simd_max(b, c))
            guard pointer.x >= lo.x - within, pointer.y >= lo.y - within,
                  pointer.x <= hi.x + within, pointer.y <= hi.y + within else { continue }
            let (d, at) = Self.distance(pointer, toTriangle: a, b, c)
            guard d <= within else { continue }
            let f = trianglePolygons[t]
            if nearest[f] == nil || d < nearest[f]!.0 { nearest[f] = (d, at) }
        }
        for (f, v) in nearest { candidates.append((f, v.0, v.1)) }
        for candidate in candidates.sorted(by: { $0.distance < $1.distance || ($0.distance == $1.distance && $0.polygon < $1.polygon) }) {
            // A hair inside the face from its nearest point, where its own
            // pixels are, so the ray there meets it rather than its edge.
            let inside = candidate.at + simd_normalize(candidate.at - pointer + SIMD2(1e-9, 1e-9)) * 0.25
            if let hit = rayCast(view.ray(at: inside)), hit.polygon == candidate.polygon { return candidate.polygon }
            if let hit = rayCast(view.ray(at: candidate.at)), hit.polygon == candidate.polygon { return candidate.polygon }
        }
        return nil
    }

    static func distance(_ p: SIMD2<Float>, toTriangle a: SIMD2<Float>, _ b: SIMD2<Float>,
                         _ c: SIMD2<Float>) -> (Float, SIMD2<Float>) {
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let s1 = cross(b - a, p - a), s2 = cross(c - b, p - b), s3 = cross(a - c, p - c)
        if (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0) { return (0, p) }
        var best: (Float, SIMD2<Float>) = (.infinity, p)
        for (u, v) in [(a, b), (b, c), (c, a)] {
            let q = KnifeSnap.closest(p, onSegment: u, v)
            let d = simd_distance(p, q)
            if d < best.0 { best = (d, q) }
        }
        return best
    }
}

/// Blender's knife snapping, for a tap or a hover with the Knife: a pointer
/// near an edge of the face under it lands on that edge, and near one of
/// that edge's ends on the vertex (`knife_snap_curr`, editmesh_knife.cc:
/// `knife_find_closest_edge_of_face` within `ethresh`, then
/// `knife_find_closest_vert_of_edge` within `vthresh`, both scaled down by
/// how many of the face's corners are near, `knife_snap_size`).
///
/// Knife Project, which the commit runs, has this snapping turned off
/// (`EDBM_mesh_knife`: `ignore_edge_snapping`, `ignore_vert_snapping`), and
/// round 4's review measured what that does to a cut from edge to edge: a
/// cube seen from (0, -6, 0), a path from (-0.995, -1, 0.2) to (0.995, -1,
/// 0.2) — about 2 px inside each side edge — came out 10/15/7 with both new
/// vertices inside the face and the face a hexagon with slivers, where
/// Blender's knife would have put them on x = ±1 and split the face into two
/// quads. So the app snaps as Blender's knife does, before the point joins
/// the path, and the point it keeps is exactly on the edge or the vertex.
/// Knife Project takes a cutter point within half a pixel of an edge or a
/// vertex as a hit on it (`knife_find_line_hits`, non-interactive
/// tolerances), so the cut is the one Blender's knife makes from the clicks.
public enum KnifeSnap {
    /// `KMAXDIST` and `KMAXDIST - 1` (`ethresh`, `vthresh`), in view points.
    public static let edgeThreshold: Float = 10
    public static let vertexThreshold: Float = 9

    public enum Target: Equatable, Sendable {
        /// A vertex of the cage, by index.
        case vertex(Int)
        /// A point on the cage's edge between these two vertices.
        case edge(Int, Int)
        /// Inside this polygon, where the line of sight meets it.
        case face(Int)
        /// A point the path already has, by index: Blender's knife snaps to
        /// the vertices of its own cut as it does to the mesh's.
        case pathPoint(Int)
        /// Off the mesh.
        case none
    }

    public struct Snapped: Equatable, Sendable {
        public var point: SIMD3<Float>
        public var target: Target
    }

    /// Where a pointer at `pointer` (view points) puts the Knife's next point.
    /// `offMesh` gives the point for a line of sight that meets no face
    /// (`KnifePath.point`'s depth rule).
    public static func snap(pointer: SIMD2<Float>, view: KnifeView, cage: KnifeCage, path: [SIMD3<Float>],
                            offMesh: ((origin: SIMD3<Float>, direction: SIMD3<Float>)) -> SIMD3<Float>) -> Snapped {
        let ray = view.ray(at: pointer)
        let hit = cage.rayCast(ray)
        guard let face = hit?.polygon
                ?? cage.nearestVisiblePolygon(to: pointer, within: edgeThreshold, in: view),
              cage.polygonEdges.indices.contains(face) else {
            return Snapped(point: offMesh(ray), target: .none)
        }
        var result = hit.map { Snapped(point: $0.point, target: .face(face)) }
        var resultScreen = pointer
        // The nearest side of the face within the edge distance.
        let edgeLimit = snapSize(edgeThreshold, around: pointer, polygon: face, cage: cage, view: view)
        var best: (distance: Float, a: Int, b: Int, point: SIMD3<Float>, screen: SIMD2<Float>)?
        for side in cage.polygonEdges[face] {
            let q = closestRayToSegment(ray, cage.positions[side.x], cage.positions[side.y])
            guard let s = view.project(q) else { continue }
            let d = simd_distance(s, pointer)
            if d < (best?.distance ?? edgeLimit) { best = (d, side.x, side.y, q, s) }
        }
        if let best {
            result = Snapped(point: best.point, target: .edge(best.a, best.b))
            resultScreen = best.screen
            // Then one of that edge's ends, near where the pointer met it.
            let vertexLimit = snapSize(vertexThreshold, around: best.screen, polygon: face, cage: cage, view: view)
            var nearest = vertexLimit
            for v in [best.a, best.b] {
                guard let s = view.project(cage.positions[v]) else { continue }
                let d = simd_distance(s, best.screen)
                if d < nearest {
                    nearest = d
                    result = Snapped(point: cage.positions[v], target: .vertex(v))
                    resultScreen = s
                }
            }
        }
        // A point of the path already on the mesh where the view sees it,
        // within the vertex distance of the pointer, and nearer to it than
        // a vertex of the mesh: the path's own vertex, as a click on the
        // first point closes Blender's knife path. A point off the mesh is
        // none of the knife's vertices, so it is not snapped to.
        var pathBest: (distance: Float, index: Int)?
        for (i, p) in path.enumerated() {
            guard let s = view.project(p) else { continue }
            let d = simd_distance(s, pointer)
            guard d < vertexThreshold, d < (pathBest?.distance ?? .infinity), isOnCage(p, at: s, cage: cage, view: view)
            else { continue }
            pathBest = (d, i)
        }
        if let pathBest {
            let meshVertexIsNearer: Bool
            if case .vertex = result?.target { meshVertexIsNearer = simd_distance(resultScreen, pointer) <= pathBest.distance }
            else { meshVertexIsNearer = false }
            if !meshVertexIsNearer {
                result = Snapped(point: path[pathBest.index], target: .pathPoint(pathBest.index))
            }
        }
        return result ?? Snapped(point: offMesh(ray), target: .none)
    }

    /// Whether `p`, landing at `s`, is on the cage where the view sees it: the
    /// first face its line of sight meets is where it is.
    static func isOnCage(_ p: SIMD3<Float>, at s: SIMD2<Float>, cage: KnifeCage, view: KnifeView) -> Bool {
        let ray = view.ray(at: s)
        guard let hit = cage.rayCast(ray) else { return false }
        let along = simd_dot(p - ray.origin, ray.direction)
        return abs(hit.distance - along) <= max(1e-5, 1e-4 * abs(along))
    }

    /// `knife_snap_size`: the distance scaled down by the corners of the face
    /// near `centre` (each side counts both its ends, as Blender counts them),
    /// within twice the distance.
    static func snapSize(_ size: Float, around centre: SIMD2<Float>, polygon: Int, cage: KnifeCage,
                         view: KnifeView) -> Float {
        var density = 0
        for side in cage.polygonEdges[polygon] {
            for v in [side.x, side.y] {
                if let s = view.project(cage.positions[v]), simd_distance(s, centre) < 2 * size { density += 1 }
            }
        }
        return density > 0 ? min(size / (Float(density) * 0.5), size) : size
    }

    /// `closest_ray_to_segment_v3`: the point of the segment nearest the
    /// line of sight, its ends when the nearest point of the line is past them.
    static func closestRayToSegment(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                    _ v0: SIMD3<Float>, _ v1: SIMD3<Float>) -> SIMD3<Float> {
        // isect_ray_line_v3
        let a = v1 - v0, t = v0 - ray.origin
        let n = simd_cross(a, ray.direction)
        let length = simd_length_squared(n)
        guard length > 0 else { return v0 }
        let c = n - t
        let lambda = simd_dot(simd_cross(c, ray.direction), n) / length
        if lambda <= 0 { return v0 }
        if lambda >= 1 { return v1 }
        return v0 + a * lambda
    }

    static func closest(_ p: SIMD2<Float>, onSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
        let ab = b - a
        let length = simd_length_squared(ab)
        guard length > 0 else { return a }
        return a + ab * min(max(simd_dot(p - a, ab) / length, 0), 1)
    }
}

/// What the viewport draws for the tool in hand before it cuts: Loop Cut's
/// ring, or the Knife's path. In world space, lines as pairs.
public struct CutPreview: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case loopCut, knife }
    public var kind: Kind
    public var lines: [SIMD3<Float>]
    public var points: [SIMD3<Float>]
    /// The object it is over; for Loop Cut also how many vertices its cage
    /// had and the mirror's report it was made from (`editTopologyRevision`):
    /// drawn only while they still hold, so a ring never lingers over a mesh
    /// it is not about. A knife path is points in the world, and stays.
    public var object: UUID
    public var cageVertexCount: Int
    public var topologyRevision: Int?
    /// Loop Cut: the Blender edge the ring goes through, which a tap on the
    /// same edge cuts.
    public var blenderEdge: Int?
    public var cuts: Int

    public init(kind: Kind, lines: [SIMD3<Float>], points: [SIMD3<Float>], object: UUID,
                cageVertexCount: Int, blenderEdge: Int? = nil, cuts: Int = 1, topologyRevision: Int? = nil) {
        self.kind = kind; self.lines = lines; self.points = points; self.object = object
        self.cageVertexCount = cageVertexCount; self.blenderEdge = blenderEdge; self.cuts = cuts
        self.topologyRevision = topologyRevision
    }

    /// Whether it is still about `object` as it is drawn now.
    public func holds(for object: BKObject?) -> Bool {
        guard let object, object.id == self.object else { return false }
        guard kind == .loopCut else { return true }
        if let topologyRevision, topologyRevision != object.editTopologyRevision { return false }
        return object.editCage.vertices.count == cageVertexCount
    }
}
