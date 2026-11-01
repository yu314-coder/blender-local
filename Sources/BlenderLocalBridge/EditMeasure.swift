import Foundation
import simd

/// The 3D View's Statistics overlay and Edit Mode's Measurement overlays
/// (Viewport Overlays ▸ Statistics; Mesh Edit Mode ▸ Measurement: Edge Length,
/// Edge Angle, Face Area, Face Angle), which the app's 3D View draws from
/// what Blender works out (`_blenderkit_measure`).
///
/// The switches are the 3D View's own, as Blender keeps them on its
/// SpaceView3D (`View3DOverlay.show_stats`, `show_extra_edge_length`, …): the
/// app's 3D View is an editor of its own, whose X-Ray and Overlays switches
/// are its own too. What they draw is Blender's: every number is read from
/// Blender's edit mesh after the viewport's selection is handed to it.
public struct MeasureOverlays: Equatable, Hashable, Sendable {
    public var statistics = false
    public var edgeLength = false
    public var edgeAngle = false
    public var faceArea = false
    public var faceAngle = false

    public init(statistics: Bool = false, edgeLength: Bool = false, edgeAngle: Bool = false,
                faceArea: Bool = false, faceAngle: Bool = false) {
        self.statistics = statistics; self.edgeLength = edgeLength; self.edgeAngle = edgeAngle
        self.faceArea = faceArea; self.faceAngle = faceAngle
    }

    public var measures: Bool { edgeLength || edgeAngle || faceArea || faceAngle }
    public var any: Bool { statistics || measures }

    /// Blender's labels, from VIEW3D_PT_overlay (Statistics) and
    /// VIEW3D_PT_overlay_edit_mesh_measurement (5.3's space_view3d.py, which
    /// the names check holds to 5.2.1's).
    public static let statisticsLabel = "Statistics"
    /// The Viewport Overlays popover's subpanel Statistics is in
    /// (VIEW3D_PT_overlay_text).
    public static let textLabel = "Text"
    /// The Mesh Edit Mode overlay popover's (VIEW3D_PT_overlay_edit_mesh).
    public static let meshEditModeLabel = "Mesh Edit Mode"
    public static let measurementLabel = "Measurement"
    public static let edgeLengthLabel = "Edge Length"
    public static let edgeAngleLabel = "Edge Angle"
    public static let faceAreaLabel = "Face Area"
    public static let faceAngleLabel = "Face Angle"

    /// The call that reads them: Edit Mode's numbers in the object's space, or
    /// through its matrix with Global (the Sidebar's Global / Local, which is
    /// the same 3D View flag in Blender, V3D_GLOBAL_STATS).
    ///
    /// `view` is the 3D View's world-to-clip matrix, which the read culls to
    /// once more labels are selected than it hands over
    /// (`_blenderkit_measure.LABELS`); nil when there is no view to cull to.
    public func python(global: Bool, view: simd_float4x4? = nil) -> String {
        func b(_ v: Bool) -> String { v ? "True" : "False" }
        var args = "stats=\(b(statistics)), edge_length=\(b(edgeLength)), edge_angle=\(b(edgeAngle)), "
            + "face_area=\(b(faceArea)), face_angle=\(b(faceAngle)), use_global=\(b(global))"
        if let view = Self.rows(view) { args += ", view=(\(view))" }
        return "import _blenderkit_measure\nprint(_blenderkit_measure.edit_overlay(\(args)))"
    }

    /// A simd matrix (column major) as Python's 16 numbers, row by row; nil
    /// for none, or for one with a number that is not finite, which would be
    /// Python's `nan`, not a literal.
    static func rows(_ m: simd_float4x4?) -> String? {
        guard let m else { return nil }
        var numbers: [String] = []
        for r in 0..<4 {
            for c in 0..<4 {
                let v = m[c][r]
                guard v.isFinite else { return nil }
                numbers.append(String(format: "%.9g", Double(v)))
            }
        }
        return numbers.joined(separator: ", ")
    }
}

/// What Blender worked out for the overlays: the statistics and every
/// measurement, positions in world space.
public struct EditMeasurements: Equatable, Sendable {
    public struct Statistics: Equatable, Sendable {
        public var editing, objects, verticesSelected, vertices, edgesSelected, edges,
                   facesSelected, faces, triangles: Int

        /// `ED_info_draw_stats`'s rows for a mesh in Edit Mode: the label and
        /// `stats_row`'s "selected / total", numbers grouped by thousands
        /// (`BLI_str_format_uint64_grouped`).
        public var rows: [(label: String, value: String)] {
            func n(_ v: Int) -> String { EditMeasurements.grouped(v) }
            var out: [(String, String)] = []
            out.append(("Objects", editing > 0 ? "\(n(editing)) / \(n(objects))" : n(objects)))
            out.append(("Vertices", "\(n(verticesSelected)) / \(n(vertices))"))
            out.append(("Edges", "\(n(edgesSelected)) / \(n(edges))"))
            out.append(("Faces", "\(n(facesSelected)) / \(n(faces))"))
            out.append(("Triangles", n(triangles)))
            return out
        }
    }

    /// An edge's ends and its value.
    public struct Segment: Equatable, Sendable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var value: Double
    }

    /// A face's label: where it is drawn and its value.
    public struct Point: Equatable, Sendable {
        public var at: SIMD3<Float>
        public var value: Double
    }

    public var statistics: Statistics?
    public var lengths: [Segment] = []
    public var edgeAngles: [Segment] = []
    public var areas: [Point] = []
    public var faceAngles: [Point] = []
    /// The object and modifier whose cage Blender would draw the
    /// measurements on, which is not read here; nil otherwise.
    public var cage: String?

    /// Set when more labels were selected than a read hands over
    /// (`_blenderkit_measure.LABELS`): how many have their place in the view
    /// the read was made for, and the n of "every n-th" it kept of them.
    /// `culled` says the view decided which, so a read for another view is
    /// another set. Nil when the read is every label Blender would write.
    public struct Thinning: Equatable, Sendable {
        public var inView: Int
        public var every: Int
        public var culled: Bool
    }
    public var thinning: Thinning?

    /// How many labels the read handed over.
    public var count: Int { lengths.count + edgeAngles.count + areas.count + faceAngles.count }

    /// What the overlay says when it draws fewer labels than Blender would,
    /// or nil. Blender draws a label for every selected element in view
    /// (`DRW_text_edit_mesh_measure_stats`); past `LABELS` the app keeps one
    /// in `every`, and says so rather than letting a part pass for the whole.
    public var thinningNote: String? {
        guard let thinning, thinning.every > 1 else { return nil }
        return "\(MeasureOverlays.measurementLabel): \(Self.grouped(count)) of the \(Self.grouped(thinning.inView)) "
            + "values in view are drawn, one in every \(thinning.every). Zoom in or select less to read them all."
    }

    public init() {}

    /// The line `_blenderkit_measure.edit_overlay` prints; nil for anything
    /// else, a number that is not finite included.
    public init?(json: String) {
        guard let line = json.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = String(line).data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func numbers(_ v: Any) -> [Double]? {
            guard let a = v as? [NSNumber] else { return nil }
            let d = a.map(\.doubleValue)
            return d.allSatisfy(\.isFinite) ? d : nil
        }
        func segments(_ key: String) -> [Segment]? {
            guard let rows = root[key] as? [Any] else { return nil }
            var out: [Segment] = []
            for row in rows {
                guard let v = numbers(row), v.count == 7 else { return nil }
                out.append(Segment(a: SIMD3(Float(v[0]), Float(v[1]), Float(v[2])),
                                   b: SIMD3(Float(v[3]), Float(v[4]), Float(v[5])), value: v[6]))
            }
            return out
        }
        func points(_ key: String) -> [Point]? {
            guard let rows = root[key] as? [Any] else { return nil }
            var out: [Point] = []
            for row in rows {
                guard let v = numbers(row), v.count == 4 else { return nil }
                out.append(Point(at: SIMD3(Float(v[0]), Float(v[1]), Float(v[2])), value: v[3]))
            }
            return out
        }
        guard let lengths = segments("lengths"), let edgeAngles = segments("edge_angles"),
              let areas = points("areas"), let faceAngles = points("face_angles") else { return nil }
        self.lengths = lengths; self.edgeAngles = edgeAngles; self.areas = areas; self.faceAngles = faceAngles
        if let s = root["stats"] {
            guard let v = (s as? [NSNumber])?.map(\.intValue), v.count == 9 else { return nil }
            statistics = Statistics(editing: v[0], objects: v[1], verticesSelected: v[2], vertices: v[3],
                                    edgesSelected: v[4], edges: v[5], facesSelected: v[6], faces: v[7],
                                    triangles: v[8])
        }
        cage = root["cage"] as? String
        if let t = root["thinned"] {
            guard let v = (t as? [NSNumber])?.map(\.intValue), v.count == 2, v[0] >= 0, v[1] >= 1 else { return nil }
            thinning = Thinning(inView: v[0], every: v[1], culled: (root["culled"] as? Bool) ?? false)
        }
    }

    /// `BLI_str_format_uint64_grouped`: 1234567 as "1,234,567".
    public static func grouped(_ v: Int) -> String {
        let digits = String(abs(v))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (v < 0 ? "-" : "") + out
    }

    // MARK: the text Blender draws

    /// Edge Length's text: `BKE_unit_value_as_string_scaled` to 3 places with
    /// a unit system, the grid's precision without (`conv_float`).
    public static func lengthText(_ v: Double, units: UnitSettings) -> String {
        if units.system != .none {
            return BlenderUnits.string(v, prec: 3, kind: .length, settings: units, scaled: true)
        }
        return String(format: BlenderUnits.overlayFormat(grid: units.grid), v)
    }

    /// Face Area's text, as Edge Length's with the area unit.
    public static func areaText(_ v: Double, units: UnitSettings) -> String {
        if units.system != .none {
            return BlenderUnits.string(v, prec: 3, kind: .area, settings: units, scaled: true)
        }
        return String(format: BlenderUnits.overlayFormat(grid: units.grid), v)
    }

    /// Edge Angle's and Face Angle's text: "%.3f" in degrees with "°", or in
    /// radians with "r" when the scene's rotation is Radians — whatever the
    /// unit system.
    public static func angleText(_ radians: Double, units: UnitSettings) -> String {
        if units.rotation == .radians { return String(format: "%.3fr", radians) }
        return String(format: "%.3f°", radians * 180 / Double.pi)
    }

    /// `clip_segment_v3_plane_n` against the view's four side planes
    /// (`ED_view3d_clipping_calc` for the whole region): the part of `a`–`b`
    /// inside the view, or nil when none is. In clip space the planes are
    /// -w ≤ x ≤ w and -w ≤ y ≤ w, each linear along the segment.
    public static func clip(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                            viewProjection: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>)? {
        let ca = viewProjection * SIMD4(a, 1), cb = viewProjection * SIMD4(b, 1)
        var t0: Float = 0, t1: Float = 1
        // Each plane as d(t) = f(a) + t (f(b) - f(a)) ≥ 0.
        let planes: [(Float, Float)] = [
            (ca.w + ca.x, cb.w + cb.x), (ca.w - ca.x, cb.w - cb.x),
            (ca.w + ca.y, cb.w + cb.y), (ca.w - ca.y, cb.w - cb.y),
        ]
        for (da, db) in planes {
            if da < 0 && db < 0 { return nil }
            if da < 0 { t0 = max(t0, da / (da - db)) }
            else if db < 0 { t1 = min(t1, da / (da - db)) }
            if t0 > t1 { return nil }
        }
        return (a + (b - a) * t0, a + (b - a) * t1)
    }

    /// One label as the overlay draws it: its world point, its text, which
    /// measurement it is, and the vertical offset Blender gives it.
    public struct Label: Equatable, Sendable {
        public enum Kind: Sendable { case length, edgeAngle, area, faceAngle }
        public var at: SIMD3<Float>
        public var text: String
        public var kind: Kind
        /// Points up (Blender's `yoffs`): Edge Length above, Edge Angle below,
        /// 5 apart when both are on (`edge_tex_sep`).
        public var raise: Float
    }

    /// Every label, positioned for the view (`viewProjection`) and written
    /// with the scene's units, in Blender's order: lengths, edge angles,
    /// areas, face angles.
    public func labels(units: UnitSettings, viewProjection: simd_float4x4,
                       overlays: MeasureOverlays) -> [Label] {
        let both = overlays.edgeLength && overlays.edgeAngle
        let sep: Float = both ? 5 : 0
        var out: [Label] = []
        if overlays.edgeLength {
            for s in lengths {
                guard let (a, b) = Self.clip(s.a, s.b, viewProjection: viewProjection) else { continue }
                out.append(Label(at: (a + b) / 2, text: Self.lengthText(s.value, units: units), kind: .length,
                                 raise: sep))
            }
        }
        if overlays.edgeAngle {
            for s in edgeAngles {
                guard let (a, b) = Self.clip(s.a, s.b, viewProjection: viewProjection) else { continue }
                out.append(Label(at: (a + b) / 2, text: Self.angleText(s.value, units: units), kind: .edgeAngle,
                                 raise: -sep))
            }
        }
        if overlays.faceArea {
            out += areas.map { Label(at: $0.at, text: Self.areaText($0.value, units: units), kind: .area, raise: 0) }
        }
        if overlays.faceAngle {
            out += faceAngles.map { Label(at: $0.at, text: Self.angleText($0.value, units: units),
                                          kind: .faceAngle, raise: 0) }
        }
        return out
    }

    /// The theme's colours for the four (userdef_default_theme.c:
    /// `extra_edge_len` #150806, `extra_edge_angle` #4D4D00, `extra_face_area`
    /// #004D00, `extra_face_angle` #0000CC), as 0–1 RGB.
    public static func colour(_ kind: Label.Kind) -> SIMD3<Float> {
        switch kind {
        case .length:    return SIMD3(0x15, 0x08, 0x06) / 255
        case .edgeAngle: return SIMD3(0x4d, 0x4d, 0x00) / 255
        case .area:      return SIMD3(0x00, 0x4d, 0x00) / 255
        case .faceAngle: return SIMD3(0x00, 0x00, 0xcc) / 255
        }
    }
}
