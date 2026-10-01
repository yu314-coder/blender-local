import Foundation
import simd
import CoreGraphics

/// A curve's or a lattice's control points while it is in Edit Mode, as
/// Blender holds them (`_blenderkit_points.cage`): what the 3D View draws,
/// what a tap or a box picks, and what the gizmo moves.
///
/// A curve or a lattice is not edited by a mesh. A Bézier spline is edited by
/// each point's knot and its two handles, a NURBS or poly spline by its
/// control points, a lattice by its grid — none of which is in the wire or the
/// deformed mesh the mirror draws. So they travel on their own, numbered as
/// `cage` numbers them: three per Bézier point (left handle, knot, right
/// handle), one per NURBS or poly point, one per lattice point.
public struct ControlCage: Equatable, Sendable {

    /// Which part of a point an entry is.
    public enum Part: UInt8, Sendable {
        /// A Bézier knot, a NURBS or poly point, or a lattice point.
        case point = 0
        case leftHandle = 1
        case rightHandle = 2
    }

    /// A Bézier handle's type, in Blender's enum order (`HD_FREE` …
    /// `HD_ALIGN`) — the integer `foreach_get` reads for `handle_left_type`.
    public enum HandleType: UInt8, CaseIterable, Sendable {
        case free = 0, auto = 1, vector = 2, aligned = 3

        /// What `curve.handle_type_set` calls it, and its menu's words.
        public var label: String {
            switch self {
            case .free: return "Free"
            case .auto: return "Automatic"
            case .vector: return "Vector"
            case .aligned: return "Aligned"
            }
        }
    }

    public static let selectedFlag: UInt8 = 1
    public static let hiddenFlag: UInt8 = 2
    public static let polygonFlag: UInt8 = 64

    /// In the object's own space.
    public var positions: [SIMD3<Float>]
    /// One byte per point: see `_blenderkit_points` for the bits.
    public var flags: [UInt8]
    /// Two indices per line: a handle to its knot, a NURBS or poly point to
    /// the next, a lattice point to its neighbours.
    public var lines: [UInt32]

    public init(positions: [SIMD3<Float>], flags: [UInt8], lines: [UInt32]) {
        self.positions = positions
        self.flags = flags
        self.lines = lines
    }

    /// The cage `sync_points` hands over, checked: a byte of flags per point,
    /// two indices per line, each naming a point. Nil for anything else.
    public init?(positions values: [Float], flags: [UInt8], lines: [UInt32]) {
        guard values.count % 3 == 0, values.count / 3 == flags.count, lines.count % 2 == 0,
              lines.allSatisfy({ Int($0) < flags.count }) else { return nil }
        self.positions = stride(from: 0, to: values.count, by: 3).map {
            SIMD3(values[$0], values[$0 + 1], values[$0 + 2])
        }
        self.flags = flags
        self.lines = lines
    }

    public var count: Int { positions.count }

    public func isSelected(_ i: Int) -> Bool { flags[i] & Self.selectedFlag != 0 }
    public func isHidden(_ i: Int) -> Bool { flags[i] & Self.hiddenFlag != 0 }
    public func part(_ i: Int) -> Part { Part(rawValue: (flags[i] >> 2) & 3) ?? .point }
    public func isHandle(_ i: Int) -> Bool { part(i) != .point }
    /// A handle's type; nil for anything that is not a handle.
    public func handleType(_ i: Int) -> HandleType? {
        isHandle(i) ? HandleType(rawValue: (flags[i] >> 4) & 3) : nil
    }
    /// A point of a NURBS or poly spline, which Blender joins by its control
    /// polygon rather than by handles.
    public func isPolygonPoint(_ i: Int) -> Bool { flags[i] & Self.polygonFlag != 0 }

    /// What Blender holds selected, by this numbering. Hidden points are
    /// never selected in Blender (hiding deselects), so none is left out.
    public var selected: Set<Int> {
        Set(flags.indices.filter { flags[$0] & Self.selectedFlag != 0 })
    }

    /// Whether the cage is a lattice's: no handle and no control polygon.
    public var isLattice: Bool {
        !flags.contains { $0 & Self.polygonFlag != 0 || ($0 >> 2) & 3 != 0 }
    }

    /// What a tap on point `i` selects. Blender's click on a Bézier knot
    /// selects the knot and both its handles (`ed_curve_editnurb_select_pick`
    /// with the knot hit calls `select_beztriple`), on a handle that handle
    /// alone; a NURBS, poly or lattice point is itself.
    public func tapped(_ i: Int) -> Set<Int> {
        guard i >= 0, i < count else { return [] }
        if part(i) == .point, i > 0, i + 1 < count,
           part(i - 1) == .leftHandle, part(i + 1) == .rightHandle {
            return [i - 1, i, i + 1]
        }
        return [i]
    }

    /// Each point where the view shows it, or nil behind the eye.
    public func screenPoints(model: simd_float4x4, viewProjection: simd_float4x4,
                             size: CGSize) -> [CGPoint?] {
        positions.map { BoxSelect.project((model * SIMD4($0, 1)).xyz, viewProjection: viewProjection, size: size) }
    }

    /// The visible point nearest `point` within `radius` points of it, the
    /// way Blender's click picks the nearest control point on screen
    /// (`ED_curve_pick_vert`). A knot wins a tie with its own handle, which a
    /// short handle can sit on top of.
    public func pick(at point: CGPoint, model: simd_float4x4, viewProjection: simd_float4x4,
                     size: CGSize, radius: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, p) in screenPoints(model: model, viewProjection: viewProjection, size: size).enumerated() {
            guard let p, !isHidden(i) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            guard d <= radius else { continue }
            if let b = best {
                if d < b.distance - 0.5 || (abs(d - b.distance) <= 0.5 && part(i) == .point && part(b.index) != .point) {
                    best = (i, d)
                }
            } else {
                best = (i, d)
            }
        }
        return best?.index
    }

    /// The visible points a box, circle or lasso covers, each by itself:
    /// with handles shown, Blender's box selects a knot and each handle by
    /// whether it is inside (`do_nurbs_box_select__doSelect`), and a lattice
    /// point by whether it is (`do_lattice_box_select__doSelect`).
    public func inside(_ region: SelectionRegion, model: simd_float4x4,
                       viewProjection: simd_float4x4, size: CGSize) -> Set<Int> {
        var found: Set<Int> = []
        for (i, p) in screenPoints(model: model, viewProjection: viewProjection, size: size).enumerated() {
            guard let p, !isHidden(i), region.contains(p) else { continue }
            found.insert(i)
        }
        return found
    }

    /// The selected points in world space, where they are drawn: what a drag
    /// must start on to take hold of them.
    public func selectedWorld(model: simd_float4x4) -> [SIMD3<Float>] {
        flags.indices.filter { isSelected($0) && !isHidden($0) }
            .map { (model * SIMD4(positions[$0], 1)).xyz }
    }

    /// Each selected point where Blender's transform measures it from, in
    /// world space: what the gizmo pivots on (Median Point, Bounding Box
    /// Center) and what Snap With snaps. `createTransCurveVerts` gives a
    /// handle whose knot is selected the knot as its `td->center`, and the
    /// median (`calculateCenterMedian`), the bounds (`calculateCenterBound`)
    /// and Closest (`snap_source_closest_fn`) all read the `td->center` of
    /// the elements marked selected. So a tapped knot, whose handles are
    /// selected with it, is measured three times at the knot, however long
    /// its handles. The mean of the entries themselves put the pivot
    /// elsewhere: measured in 5.2.1 with a VIEW_3D override, a knot at
    /// (0, 0, 0) with Free handles at (-1, 0, 0) and (3, 0, 0) stayed put
    /// through Blender's own 180° turn, and the app's centre of (0.667, 0, 0)
    /// moved it to (1.333, 0, 0). Seven selections of a two-point curve with
    /// Free handles, under both pivots, now agree with Blender's own turn.
    public func transformCentres(model: simd_float4x4) -> [SIMD3<Float>] {
        flags.indices.filter { isSelected($0) && !isHidden($0) }
            .map { (model * SIMD4(positions[selectedKnot(of: $0) ?? $0], 1)).xyz }
    }

    /// The knot of handle `i`, when the knot is selected too.
    private func selectedKnot(of i: Int) -> Int? {
        let knot: Int
        switch part(i) {
        case .point: return nil
        case .leftHandle: knot = i + 1
        case .rightHandle: knot = i - 1
        }
        guard knot >= 0, knot < count, part(knot) == .point, isSelected(knot) else { return nil }
        return knot
    }

    /// The one point a selection moves when it moves only one — a Bézier
    /// point by any of its knot and handles, a NURBS, poly or lattice point —
    /// as its knot, or itself, in world space. Nil for none or several.
    ///
    /// Blender turns and scales such a selection about that point:
    /// `transform_around_single_fallback_ex` switches Median Point, Bounding
    /// Box Center and Active Element to Individual Origins for one point,
    /// where a handle's centre is its knot. Measured in 5.2.1: a Free left
    /// handle selected alone turned 180° about its knot, not about itself.
    /// The fallback is skipped for a `center_override`, so the commit has to
    /// be given the knot.
    public func singlePoint(model: simd_float4x4) -> SIMD3<Float>? {
        var found: Int?
        var i = 0
        while i < count {
            let members: ClosedRange<Int>
            let anchor: Int
            if part(i) == .leftHandle, i + 2 < count, part(i + 1) == .point, part(i + 2) == .rightHandle {
                members = i...(i + 2)
                anchor = i + 1
            } else {
                members = i...i
                anchor = i
            }
            i = members.upperBound + 1
            guard members.contains(where: { isSelected($0) && !isHidden($0) }) else { continue }
            if found != nil { return nil }
            found = anchor
        }
        return found.map { (model * SIMD4(positions[$0], 1)).xyz }
    }
}

/// What the 3D View draws for a cage: each line with its colour, and the
/// points in colour groups, selected last so they sit on top. Blender's
/// default theme (`userdef_default_theme.c`): handles by their type, lighter
/// when selected; a NURBS or poly spline's control polygon in its NURBS line
/// colour; points black, and orange when selected, like a mesh's vertices.
public struct ControlCageOverlay: Sendable {
    public static let selected = SIMD4<Float>(1.0, 0.627, 0.157, 1)
    public static let unselected = SIMD4<Float>(0, 0, 0, 1)

    public static func handleColour(_ type: ControlCage.HandleType, selected: Bool) -> SIMD4<Float> {
        func hex(_ v: UInt32) -> SIMD4<Float> {
            SIMD4(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255, 1)
        }
        switch (type, selected) {
        case (.free, false):    return hex(0x000000)
        case (.free, true):     return hex(0x808080)
        case (.auto, false):    return hex(0x909000)
        case (.auto, true):     return hex(0xF0FF40)
        case (.vector, false):  return hex(0x409030)
        case (.vector, true):   return hex(0x40C030)
        case (.aligned, false): return hex(0x803060)
        case (.aligned, true):  return hex(0xF090A0)
        }
    }

    /// Each line's two points and colour. A hidden point has no line: the
    /// cage sends none for it.
    public let lines: [(a: Int, b: Int, colour: SIMD4<Float>)]
    /// The visible points by colour, unselected groups first.
    public let dots: [(colour: SIMD4<Float>, points: [UInt32])]

    public init(_ cage: ControlCage) {
        var lines: [(a: Int, b: Int, colour: SIMD4<Float>)] = []
        for e in stride(from: 0, to: cage.lines.count - 1, by: 2) {
            let a = Int(cage.lines[e]), b = Int(cage.lines[e + 1])
            let colour: SIMD4<Float>
            if let type = cage.handleType(a) ?? cage.handleType(b) {
                let handle = cage.isHandle(a) ? a : b
                colour = Self.handleColour(type, selected: cage.isSelected(handle))
            } else if cage.isPolygonPoint(a) {
                colour = cage.isSelected(a) && cage.isSelected(b)
                    ? SIMD4(0.941, 1.0, 0.251, 1) : SIMD4(0.565, 0.565, 0.0, 1)
            } else {
                colour = cage.isSelected(a) && cage.isSelected(b) ? Self.selected : Self.unselected
            }
            lines.append((a, b, colour))
        }
        var groups: [SIMD4<Float>: [UInt32]] = [:]
        var order: [SIMD4<Float>] = []
        for i in 0..<cage.count where !cage.isHidden(i) {
            let colour: SIMD4<Float>
            if cage.isSelected(i) {
                colour = Self.selected
            } else if let type = cage.handleType(i) {
                colour = Self.handleColour(type, selected: false)
            } else {
                colour = Self.unselected
            }
            if groups[colour] == nil { order.append(colour) }
            groups[colour, default: []].append(UInt32(i))
        }
        order = order.filter { $0 != Self.selected } + order.filter { $0 == Self.selected }
        self.lines = lines
        self.dots = order.map { ($0, groups[$0] ?? []) }
    }
}

/// A curve's or a lattice's settings, as `_blenderkit_points.record` reads
/// them and the Data tab shows them.
public enum ObjectDataSettings: Equatable, Sendable {
    case curve(CurveSettings)
    case lattice(LatticeSettings)

    /// Nil for a type with no such settings or a record that does not parse.
    public static func parse(type: String, record: String) -> ObjectDataSettings? {
        var values: [String: String] = [:]
        for pair in record.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        func float(_ key: String) -> Float? { values[key].flatMap(Float.init) }
        // Integers come as floats ("2.0"): `Int("2.0")` is nil.
        func int(_ key: String) -> Int? { float(key).map { Int($0.rounded()) } }
        switch type {
        case "CURVE":
            guard let resolution = int("resolution_u"), let depth = float("bevel_depth"),
                  let bevelResolution = int("bevel_resolution"), let extrude = float("extrude"),
                  let fill = values["fill_mode"], let dimensions = values["dimensions"]
            else { return nil }
            return .curve(CurveSettings(dimensions: dimensions, resolutionU: resolution,
                                        bevelDepth: depth, bevelResolution: bevelResolution,
                                        extrude: extrude, offset: float("offset") ?? 0,
                                        fillMode: fill, splines: int("splines") ?? 0,
                                        points: int("points") ?? 0, bezierSplines: int("bezier") ?? 0,
                                        cyclicSplines: int("cyclic") ?? 0))
        case "LATTICE":
            guard let u = int("points_u"), let v = int("points_v"), let w = int("points_w") else { return nil }
            return .lattice(LatticeSettings(pointsU: u, pointsV: v, pointsW: w,
                                            interpolation: [values["interpolation_type_u"] ?? "",
                                                            values["interpolation_type_v"] ?? "",
                                                            values["interpolation_type_w"] ?? ""],
                                            useOutside: values["use_outside"] == "1",
                                            resolutionEditable: values["points_editable"] != "0"))
        default:
            return nil
        }
    }
}

public struct CurveSettings: Equatable, Sendable {
    /// "2D" or "3D".
    public var dimensions: String
    public var resolutionU: Int
    public var bevelDepth: Float
    public var bevelResolution: Int
    public var extrude: Float
    public var offset: Float
    /// Blender's identifier: FULL, BACK, FRONT, HALF for a 3D curve; NONE,
    /// BACK, FRONT, BOTH for a 2D one.
    public var fillMode: String
    public var splines: Int
    public var points: Int
    public var bezierSplines: Int
    public var cyclicSplines: Int

    public init(dimensions: String, resolutionU: Int, bevelDepth: Float, bevelResolution: Int,
                extrude: Float, offset: Float, fillMode: String, splines: Int, points: Int,
                bezierSplines: Int, cyclicSplines: Int) {
        self.dimensions = dimensions; self.resolutionU = resolutionU
        self.bevelDepth = bevelDepth; self.bevelResolution = bevelResolution
        self.extrude = extrude; self.offset = offset; self.fillMode = fillMode
        self.splines = splines; self.points = points
        self.bezierSplines = bezierSplines; self.cyclicSplines = cyclicSplines
    }

    /// The fill modes Blender accepts for this curve, with its words:
    /// `rna_Curve_fill_mode_itemf` gives a 3D curve one list and a 2D curve
    /// another, and assigning one from the other list is an error.
    public var fillModes: [(identifier: String, label: String)] {
        dimensions == "2D"
            ? [("NONE", "None"), ("BACK", "Back"), ("FRONT", "Front"), ("BOTH", "Both")]
            : [("FULL", "Full"), ("BACK", "Back"), ("FRONT", "Front"), ("HALF", "Half")]
    }
}

public struct LatticeSettings: Equatable, Sendable {
    public var pointsU: Int
    public var pointsV: Int
    public var pointsW: Int
    /// U, V and W: KEY_LINEAR, KEY_CARDINAL, KEY_CATMULL_ROM or KEY_BSPLINE.
    public var interpolation: [String]
    public var useOutside: Bool
    /// False on a lattice with shape keys, whose resolution Blender keeps:
    /// it greys the fields out, and a write is refused as read-only.
    public var resolutionEditable: Bool

    public init(pointsU: Int, pointsV: Int, pointsW: Int, interpolation: [String], useOutside: Bool,
                resolutionEditable: Bool = true) {
        self.pointsU = pointsU; self.pointsV = pointsV; self.pointsW = pointsW
        self.interpolation = interpolation; self.useOutside = useOutside
        self.resolutionEditable = resolutionEditable
    }

    /// Blender's range for a resolution (`rna_def_lattice`: 1 to 64).
    public static let resolutionRange = 1...64
    public static let interpolations: [(identifier: String, label: String)] = [
        ("KEY_LINEAR", "Linear"), ("KEY_CARDINAL", "Cardinal"),
        ("KEY_CATMULL_ROM", "Catmull-Rom"), ("KEY_BSPLINE", "BSpline"),
    ]
}

public extension SceneMirror {
    /// A curve's or a lattice's settings and its control points, onto the
    /// object of that name: the one the pass just pushed during a pass, the
    /// one on screen outside one (a drag's frame, a tap). False when there is
    /// no such object or the points do not parse.
    @discardableResult
    static func carryPoints(record: String, positions: [Float], flags: [UInt8], lines: [UInt32],
                            named name: String, pass: [BKObject]?, screen: [BKObject]) -> Bool {
        let target: BKObject?
        if let pass {
            target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        } else {
            target = screen.first { $0.name == name }
        }
        guard let target else { return false }
        if flags.isEmpty {
            if target.controlCage != nil { target.controlCage = nil }
        } else {
            guard let cage = ControlCage(positions: positions, flags: flags, lines: lines) else { return false }
            if target.controlCage != cage { target.controlCage = cage }
        }
        let settings = ObjectDataSettings.parse(type: target.blenderType, record: record)
        if target.dataSettings != settings { target.dataSettings = settings }
        return true
    }
}

public extension BKScene {
    /// The object Edit Mode edits by its control points, when that is what
    /// is being edited.
    var editedPoints: (object: BKObject, cage: ControlCage)? {
        guard mode == .edit, let object = active, object.editsPoints,
              let cage = object.controlCage else { return nil }
        return (object, cage)
    }
}

/// The Python behind Edit Mode on a curve or a lattice.
public enum PointsBpy {

    static let module = "import _blenderkit_points as _bk_pts"

    /// Selects exactly `indices` of the edited object's points, by the
    /// numbering `ControlCage` has, and deselects the rest.
    public static func select(_ indices: Set<Int>, object name: String) -> String {
        "\(module)\n_bk_pts.select(\(Bpy.quote(name)), [\(indices.sorted().map(String.init).joined(separator: ", "))])"
    }

    /// Remembers the points before a drag; `followers` are the objects whose
    /// geometry follows them, mirrored with each frame.
    public static func beginDrag(object name: String, followers: [String]) -> String {
        "\(module)\n_bk_pts.begin_drag(\(Bpy.quote(name)), [\(followers.map(Bpy.quote).joined(separator: ", "))])"
    }

    /// One frame of a drag: the points put back, `call` run on them — the
    /// operator the release commits — and the result remembered and mirrored.
    /// `restore` raises, so `call` never runs, when the curve has left Edit
    /// Mode or been changed since the last frame (`_blenderkit_points._check`).
    public static func preview(_ call: String) -> String {
        "\(module)\n_bk_pts.restore()\n\(call)\n_bk_pts.settle()"
    }

    /// What runs before the commit's operator, in its evaluation: the points
    /// put back where the drag found them, so the operator moves them once —
    /// or a refusal, and no operator, when Blender no longer holds what the
    /// last frame left it.
    public static let commitSetup = "\(module)\n_bk_pts.restore(end=True)"

    /// A drag that ends without a commit: everything back as it was.
    public static let cancel = "\(module)\n_bk_pts.cancel()"

    // MARK: the Curve and Lattice menus

    /// One row of the Curve or Lattice menu: the call, its undo name, and
    /// what to say when Blender returns CANCELLED without a word.
    public struct Command: Equatable, Sendable {
        public let label: String
        /// The call, as the Info log shows it.
        public let python: String
        public let undo: String
        public let refusal: String
        /// Refused before the call when nothing is selected.
        public var needsSelection = true
        /// Refused after a FINISHED call too when Blender holds exactly what
        /// it held before (`_blenderkit_points.fingerprint`): Subdivide with
        /// one point selected returns FINISHED and does nothing. A CANCELLED
        /// call is refused only on the same condition, so a refusal is never
        /// said over a change Blender made, which would then have no undo step.
        public var changesPoints = false

        public init(label: String, python: String, undo: String, refusal: String,
                    needsSelection: Bool = true, changesPoints: Bool = false) {
            self.label = label; self.python = python; self.undo = undo; self.refusal = refusal
            self.needsSelection = needsSelection; self.changesPoints = changesPoints
        }

        /// What runs: `python`, held to its preconditions, a CANCELLED and a
        /// call that changed nothing said in `refusal`'s words.
        ///
        /// "Changed nothing" is the whole curve, not its point count: Delete
        /// ▸ Segments on a cyclic spline keeps every point and opens it
        /// (measured in 5.2.1), and held to the count it said "Delete
        /// Segments needs two neighbouring points selected" over the opened
        /// curve, with no undo step for it.
        public var executed: String {
            let refusal = Bpy.quote(self.refusal)
            var lines = [PointsBpy.module,
                         needsSelection ? "_bk_before = _bk_pts.require_selection(\(refusal))"
                                        : "_bk_before = _bk_pts.fingerprint()",
                         "_bk_result = \(python)"]
            let cancelled = changesPoints ? "" : "'CANCELLED' in _bk_result and "
            lines += ["if \(cancelled)_bk_pts.fingerprint() == _bk_before:",
                      "    raise RuntimeError(\(refusal))"]
            return lines.joined(separator: "\n")
        }
    }

    /// Blender's curve Edit Mode menu rows (`VIEW3D_MT_edit_curve`,
    /// `VIEW3D_MT_edit_curve_ctrlpoints`, `VIEW3D_MT_edit_curve_segments`).
    public static func subdivide(cuts: Int) -> Command {
        Command(label: cuts == 1 ? "1 Cut" : "\(cuts) Cuts",
                python: "bpy.ops.curve.subdivide(number_cuts=\(cuts))", undo: "Subdivide",
                refusal: "Subdivide needs two neighbouring points selected", changesPoints: true)
    }

    /// Extrude in place, as E does before the mouse moves: the new points
    /// sit on the old and are selected, and the Move tool takes them from
    /// there.
    public static let extrude = Command(
        label: "Extrude",
        python: "bpy.ops.curve.extrude_move(CURVE_OT_extrude={\"mode\": 'TRANSLATION'}, "
            + "TRANSFORM_OT_translate={\"value\": (0, 0, 0)})",
        undo: "Extrude Curve and Move",
        refusal: "Extrude needs a selected point", changesPoints: true)

    public static func delete(segments: Bool) -> Command {
        Command(label: segments ? "Segments" : "Vertices",
                python: "bpy.ops.curve.delete(type='\(segments ? "SEGMENT" : "VERT")')",
                undo: "Delete", refusal: segments ? "Delete Segments needs two neighbouring points selected"
                    : "Nothing is selected to delete", changesPoints: true)
    }

    /// `curve.handle_type_set`'s five types, in its menu's order.
    public static let handleTypes: [(identifier: String, label: String)] = [
        ("AUTOMATIC", "Automatic"), ("VECTOR", "Vector"), ("ALIGNED", "Aligned"),
        ("FREE_ALIGN", "Free"), ("TOGGLE_FREE_ALIGN", "Toggle Free/Align"),
    ]

    public static func handleType(_ identifier: String) -> Command {
        let label = handleTypes.first { $0.identifier == identifier }?.label ?? identifier
        return Command(label: label, python: "bpy.ops.curve.handle_type_set(type='\(identifier)')",
                       undo: "Set Handle Type", refusal: "Set Handle Type works on selected Bézier points")
    }

    public static let toggleCyclic = Command(
        label: "Toggle Cyclic", python: "bpy.ops.curve.cyclic_toggle(direction='CYCLIC_U')",
        undo: "Toggle Cyclic", refusal: "Toggle Cyclic needs a selected point on a spline of two or more")

    public static let switchDirection = Command(
        label: "Switch Direction", python: "bpy.ops.curve.switch_direction()",
        undo: "Switch Direction", refusal: "Switch Direction needs a selected point")

    /// Select All, None and Invert in curve or lattice Edit Mode.
    public static func selectAll(_ action: String, lattice: Bool) -> String {
        "bpy.ops.\(lattice ? "lattice" : "curve").select_all(action='\(action)')"
    }

    public static let makeRegular = Command(
        label: "Make Regular", python: "bpy.ops.lattice.make_regular()",
        undo: "Make Regular", refusal: "Make Regular needs a lattice in Edit Mode", needsSelection: false)

    public static func flip(_ axis: String) -> Command {
        Command(label: "Flip \(axis)", python: "bpy.ops.lattice.flip(axis='\(axis)')",
                undo: "Flip (Distortion)", refusal: "Flip needs a lattice in Edit Mode", needsSelection: false)
    }

    /// H, Shift+H and Alt+H in curve Edit Mode.
    public static func showHide(_ what: Bpy.ShowHide) -> String {
        switch what {
        case .hideSelected:   return "bpy.ops.curve.hide(unselected=False)"
        case .hideUnselected: return "bpy.ops.curve.hide(unselected=True)"
        case .reveal:         return "bpy.ops.curve.reveal()"
        }
    }

    // MARK: the Data tab

    /// One setting of the object's curve or lattice, by Blender's property
    /// name. `value` is already Python: a number, or a quoted identifier.
    public static func set(_ property: String, to value: String, object name: String) -> String {
        "bpy.data.objects[\(Bpy.quote(name))].data.\(property) = \(value)"
    }
}

public extension LastOperator {
    /// Add ▸ Lattice, as Blender's Add menu adds one: `object.add` with the
    /// type, which takes Radius and the placement (read out of
    /// `get_rna_type()` in 5.2.1). Its resolution is the lattice's own
    /// setting, in the Data tab, not an argument: `object.add` has none.
    static func addLattice(at location: SIMD3<Float>) -> LastOperator {
        let place = SIMD3<Double>(Double(location.x), Double(location.y), Double(location.z))
        var op = LastOperator(
            name: "Add Lattice", call: "bpy.ops.object.add",
            parameters: [Parameter(key: "radius", label: "Radius", kind: .float,
                                   value: 1, softMin: 0.001, softMax: 100, step: 0.01)],
            location: place, restoration: .removeCreated)
        op.fixedArguments = ["type='LATTICE'"]
        op.dataCollection = "lattices"
        return op
    }
}

public extension BpyBridge {
    /// Starts a drag of the edited curve's or lattice's points: Blender
    /// remembers them as they are. False, with Blender's reason on the
    /// banner, when it refuses — then nothing may move.
    func beginPointDrag(object name: String, followers: [String], undo label: String) -> Bool {
        guard usesRealBlender else { return false }
        // A drag whose end never came — its view went away mid-gesture — is
        // cancelled first, so its hold cannot outlive it.
        if pointDragOpen { cancelPointDrag() }
        // The frame path's name index is built per frame change; a drag's
        // frames use it too (`anim_mesh`), so it starts from the screen as it
        // is now.
        SceneMirror.frameIndex.invalidate()
        guard captureReporting(PointsBpy.beginDrag(object: name, followers: followers), failing: label) != nil
        else { return false }
        // From here until the commit or the cancel nothing else runs, undoes
        // or redoes (BpySession.pointDragOpen).
        pointDragOpen = true
        return true
    }

    /// One frame of the drag: Blender puts the points back and runs `call` —
    /// the very call the release commits — and the result is mirrored. False
    /// when Blender raised, the curve having left Edit Mode or been changed
    /// since the last frame among the reasons; the drag should then be
    /// cancelled.
    func previewPointDrag(_ call: String, undo label: String) -> Bool {
        captureReporting(PointsBpy.preview(call), failing: label) != nil
    }

    /// The release: the points put back and `call` run once, as one undo step
    /// named `label`, logged as the bare call. The hold ends first: the
    /// commit is a command like any other, which the hold would refuse.
    @discardableResult
    func commitPointDrag(_ call: String, undo label: String) -> Outcome {
        pointDragOpen = false
        return run(call, undo: label, setup: PointsBpy.commitSetup)
    }

    /// A drag that ends without moving anything, or is abandoned.
    func cancelPointDrag() {
        pointDragOpen = false
        _ = capture(PointsBpy.cancel)
    }
}
