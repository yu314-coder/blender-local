import Foundation
import simd

/// One of the Measure tool's rulers: Blender's `RulerItem`
/// (view3d_gizmo_ruler.cc in the 5.3 source) — three points, the middle one
/// meaning something only once the ruler measures an angle.
///
/// Blender's own ruler cannot run here: `view3d.ruler_add` fails its poll
/// even under the borrowed 3D View (round 3's review: it needs the tool
/// system's gizmo group, `view3d_ruler_poll`). So the ruler is an overlay of
/// the app's, built as Blender's gizmo behaves: a drag adds a ruler, a drag
/// from an end moves that end, a drag from a ruler's line puts an angle point
/// there, and each point lands where Blender's would — in the view's plane
/// through where it started, or, while snapping is on, on what Blender's snap
/// cursor finds (`RulerTool.place`). Its points come from the mirror, which is
/// Blender's evaluated geometry, and it changes nothing in the scene: Blender
/// writes its rulers into an annotation layer when the tool is left
/// (`view3d_ruler_to_gpencil`); these stay the app's until Ruler Remove.
public struct Ruler: Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// `co[0]`, `co[1]`, `co[2]`, world space.
    public var points: [SIMD3<Float>]
    /// RULERITEM_USE_ANGLE.
    public var usesAngle: Bool
    /// RULERITEM_USE_ANGLE_ACTIVE: the angle point was the part last pressed
    /// (`gizmo_ruler_invoke` sets it for `co_index` 1 and clears it for an
    /// end), so Ruler Remove takes the angle away and leaves the ruler.
    public var angleActive = false

    public init(start: SIMD3<Float>, end: SIMD3<Float>) {
        points = [start, (start + end) / 2, end]
        usesAngle = false
    }

    public init(points: [SIMD3<Float>], usesAngle: Bool) {
        precondition(points.count == 3)
        self.points = points
        self.usesAngle = usesAngle
    }

    /// `len_v3v3(co[0], co[2])`.
    public var length: Float { simd_distance(points[0], points[2]) }

    /// `angle_v3v3v3(co[0], co[1], co[2])`, radians.
    public var angle: Float { RulerTool.angle(points[0], points[1], points[2]) }

    /// `ruler_item_as_string` with the precision `gizmo_ruler_draw` passes:
    /// 2 for an angle, 6 for a length. Without a unit system Blender prints
    /// the bare number (the angle in degrees with its sign); with one,
    /// `BKE_unit_value_as_string` for the angle and its `_scaled` variant
    /// for the length.
    public func text(units: UnitSettings) -> String {
        if usesAngle {
            if units.system == .none {
                return String(format: "%.*f°", 2, Double(angle) * 180 / Double.pi)
            }
            return BlenderUnits.string(Double(angle), prec: 2, kind: .rotation, settings: units, scaled: false)
        }
        if units.system == .none { return String(format: "%.*f", 6, Double(length)) }
        return BlenderUnits.string(Double(length), prec: 6, kind: .length, settings: units, scaled: true)
    }
}

/// How the Measure tool's drags make and move rulers, after
/// view3d_gizmo_ruler.cc.
public enum RulerTool {
    /// RULER_PICK_DIST: how near a ruler a press must be to take it, in view
    /// points (the app takes Blender's pixel sizes as points).
    public static let pickDistance: Float = 12
    /// MVAL_MAX_PX_DIST, the snap's reach (`dist_px` in
    /// `view3d_ruler_item_mousemove`).
    public static let snapDistance: Float = 12
    /// `eps_view_align` in view3d_cursor_snap.cc.
    static let viewAlign: Float = 1e-2

    /// Blender's Measure tool's name, its toolbar's (`builtin.measure`).
    public static let label = "Measure"
    /// `VIEW3D_OT_ruler_remove`'s name: removes the active ruler (X, Delete).
    public static let removeLabel = "Ruler Remove"

    /// `angle_v3v3v3`: at `b`, between `a` and `c`.
    public static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        func unit(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let l = simd_length(v)
            return l > 0 ? v / l : .zero
        }
        let v1 = unit(a - b), v2 = unit(c - b)
        // angle_normalized_v3v3: the asin form.
        if simd_dot(v1, v2) >= 0 {
            return 2 * asin(min(max(simd_distance(v1, v2) / 2, -1), 1))
        }
        return .pi - 2 * asin(min(max(simd_distance(v1, -v2) / 2, -1), 1))
    }

    /// What a press takes: one of a ruler's points, or the line of a ruler
    /// that has no angle yet (`view3d_ruler_pick` and
    /// `gizmo_ruler_test_select`).
    public enum Part: Equatable, Sendable {
        case point(Int)
        case line
    }

    /// The ruler and part a press at `pointer` takes, nearest first; nil
    /// for none within `pickDistance`. `project` puts a world point on
    /// screen (view points), nil behind the eye.
    public static func pick(_ rulers: [Ruler], at pointer: SIMD2<Float>,
                            project: (SIMD3<Float>) -> SIMD2<Float>?) -> (index: Int, part: Part)? {
        var best: (index: Int, part: Part, distance: Float)?
        for (index, ruler) in rulers.enumerated() {
            guard let s0 = project(ruler.points[0]), let s1 = project(ruler.points[1]),
                  let s2 = project(ruler.points[2]) else { continue }
            let line: Float
            if ruler.usesAngle {
                line = min(MeshPicker.distanceToSegment(pointer, s0, s1), MeshPicker.distanceToSegment(pointer, s1, s2))
            } else {
                line = MeshPicker.distanceToSegment(pointer, s0, s2)
            }
            guard line < pickDistance, best == nil || line < best!.distance else { continue }
            let ends: [(Int, Float)] = ruler.usesAngle
                ? [(0, simd_distance(s0, pointer)), (1, simd_distance(s1, pointer)), (2, simd_distance(s2, pointer))]
                : [(0, simd_distance(s0, pointer)), (2, simd_distance(s2, pointer))]
            // The nearest end within reach (`min_axis_v3` / the first on a tie).
            var end: (Int, Float)?
            for e in ends where e.1 < pickDistance && (end == nil || e.1 < end!.1) { end = e }
            if let end {
                best = (index, .point(end.0), line)
            } else if !ruler.usesAngle {
                best = (index, .line, line)
            }
            // An angle ruler's line away from its points takes nothing: Blender
            // returns -1 there, and the press makes a new ruler instead.
        }
        return best.map { ($0.index, $0.part) }
    }

    /// The factor along the screen line from `a` to `b` nearest `p`, clamped
    /// (`line_point_factor_v2`, CLAMP 0 to 1): where an angle point goes.
    public static func lineFactor(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let l = simd_length_squared(ab)
        guard l > 0 else { return 0 }
        return min(max(simd_dot(p - a, ab) / l, 0), 1)
    }

    /// What the ruler's snap leaves out: in Edit Mode, the object being
    /// edited when the viewport draws it rebuilt by a modifier. Blender's
    /// ruler snaps to the edit cage there (V3D_SNAPCURSOR_SNAP_EDIT_GEOM_CAGE,
    /// and `data_for_snap` casts at the edit mesh itself while the cage is
    /// it) — measured in desktop 5.2.1: under a Subdivision Surface a ray
    /// met the cage 0.15 m in front of the subdivided surface the mirror
    /// holds — so a point snapped to the drawn surface would not be
    /// Blender's. `refusal` says so on the bar.
    public static func excluded(_ objects: [BKObject], edited: BKObject?) -> (ids: Set<UUID>, refusal: String?) {
        guard let edited, let why = edited.editRegionRefusal(picking: "a ruler point snapped to it",
                                                             toDo: "snap the ruler to it") else { return ([], nil) }
        return ([edited.id], why)
    }

    /// The snap elements the ruler's snap cursor uses: Snap To's Geometry
    /// (`snap_elements_tool` 'GEOMETRY', SCE_SNAP_TO_GEOM: vertices, edges,
    /// faces, their centres and Perpendicular, which is not reproduced here)
    /// or the scene's own (`DEFAULT`, `v3d_cursor_snap_elements`).
    public static func elements(snapTool: String, scene: Set<SnapElement>) -> Set<SnapElement> {
        if snapTool == "DEFAULT" { return scene }
        return [.vertex, .edge, .face, .faceMidpoint, .edgeMidpoint]
    }

    /// Where a ruler point goes with the pointer at `pointer`.
    ///
    /// Without snapping, `view3d_ruler_item_project`: in the view's plane
    /// through `depth`, where the drag started (a new ruler's first point, in
    /// Blender, at the depth of a point it has not got yet: the world origin).
    /// With it — the scene's Snap toggle, inverted while Ctrl is held
    /// (`ED_gizmotypes_snap_3d_is_enabled`) — what the snap cursor finds
    /// within `snapDistance`, and where it finds nothing the plane through the
    /// 3D cursor facing Z (`v3d_cursor_snap_update`: the placement plane), or
    /// for a view looking along that plane, the view's plane through the
    /// cursor.
    public static func place(pointer: SIMD2<Float>, depth: SIMD3<Float>, snap: GeometrySnap.Targets?,
                             cursor: SIMD3<Float>, view: GeometrySnap.View, eye: SIMD3<Float>,
                             forward: SIMD3<Float>, orthographic: Bool) -> (point: SIMD3<Float>, hit: GeometrySnap.Hit?)? {
        guard let snap else {
            return CursorTool.winTo3D(depth: depth, view: view, pointer: pointer, eye: eye, forward: forward,
                                      orthographic: orthographic).map { ($0, nil) }
        }
        if let hit = snap.find(pointer) { return (hit.location, hit) }
        let normal = SIMD3<Float>(0, 0, 1)
        if !orthographic || abs(simd_dot(normal, -forward)) > viewAlign, let ray = view.ray(pointer) {
            let along = simd_dot(ray.direction, normal)
            if abs(along) > 1e-12 {
                let t = simd_dot(cursor - ray.origin, normal) / along
                // `isect_ray_plane_v3` clipped in perspective: in front only.
                if orthographic || t >= 0 { return (ray.origin + ray.direction * t, nil) }
            }
        }
        return CursorTool.winTo3D(depth: cursor, view: view, pointer: pointer, eye: eye, forward: forward,
                                  orthographic: orthographic).map { ($0, nil) }
    }

    /// A drag in progress: which ruler, which of its points, and the point
    /// the drag started from, whose depth an unsnapped point keeps.
    public struct Drag: Equatable, Sendable {
        public var ruler: Int
        public var point: Int
        public var start: SIMD3<Float>
        /// The first move of an angle point is never snapped
        /// (`gizmo_ruler_invoke` moves it with `do_snap` false).
        public var fresh: Bool
    }

    /// A press at `pointer`: `gizmo_ruler_invoke` on what it picked, or
    /// `view3d_ruler_add_invoke` — a new ruler, its first point placed (and
    /// snapped when snapping is on), its far end dragged from there.
    public static func begin(_ rulers: inout [Ruler], at pointer: SIMD2<Float>,
                             project: (SIMD3<Float>) -> SIMD2<Float>?,
                             placeNew: (SIMD2<Float>) -> SIMD3<Float>?) -> Drag? {
        if let (index, part) = pick(rulers, at: pointer, project: project) {
            switch part {
            case .point(let k):
                rulers[index].angleActive = k == 1
                return Drag(ruler: index, point: k, start: rulers[index].points[k], fresh: false)
            case .line:
                var ruler = rulers[index]
                guard let a = project(ruler.points[0]), let b = project(ruler.points[2]) else { return nil }
                let f = lineFactor(pointer, a, b)
                ruler.points[1] = ruler.points[0] + (ruler.points[2] - ruler.points[0]) * f
                ruler.usesAngle = true
                ruler.angleActive = true
                rulers[index] = ruler
                // The interaction's `drag_start_co` is zeroed and this branch
                // never sets it, so the angle point moves in the view's plane
                // through the world origin, as a new ruler's first point does.
                return Drag(ruler: index, point: 1, start: .zero, fresh: true)
            }
        }
        guard let first = placeNew(pointer) else { return nil }
        rulers.append(Ruler(start: first, end: first))
        return Drag(ruler: rulers.count - 1, point: 2, start: first, fresh: false)
    }

    /// A tap with the Measure tool: the ruler under it becomes the active
    /// one, its angle point marked as the part pressed or not, as
    /// `gizmo_ruler_invoke` marks it. A tap on nothing leaves the active
    /// ruler as it was: Blender's tool adds a ruler on a drag
    /// (`view3d.ruler_add` on CLICK_DRAG in its keymap) and does nothing on a
    /// click, so `item_active` stays.
    public static func tap(_ rulers: inout [Ruler], active: Int?, at pointer: SIMD2<Float>,
                           project: (SIMD3<Float>) -> SIMD2<Float>?) -> Int? {
        guard let (index, part) = pick(rulers, at: pointer, project: project) else { return active }
        if case .point(let k) = part { rulers[index].angleActive = k == 1 }
        return index
    }

    /// Ruler Remove (`view3d_ruler_remove_invoke`): an angle ruler whose
    /// angle point was the part last pressed loses its angle and stays
    /// active; any other active ruler goes. Nothing without an active one.
    public static func remove(_ rulers: inout [Ruler], active: inout Int?) {
        guard let index = active, index < rulers.count else { return }
        if rulers[index].usesAngle, rulers[index].angleActive {
            rulers[index].usesAngle = false
            rulers[index].angleActive = false
            return
        }
        rulers.remove(at: index)
        active = nil
    }
}
