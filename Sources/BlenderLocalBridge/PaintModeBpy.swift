import Foundation

// Weight Paint and Vertex Paint with Blender's own brushes. Everything here is
// the Python the interface sends to `_blenderkit_vwpaint` (Resources/python/
// site), and the shape of what it prints back; the modes, the brushes, the
// strokes and the undo steps are Blender's. See that module for what was
// measured. A stroke streams exactly as a sculpt stroke does
// (SculptStrokeInput, `BpyBridge.sculptBegin` with `.paint`), and answers in
// the same shapes (`SculptStrokeStart`, `SculptChunkResult`, `SculptStrokeEnd`).

/// Blender 5.2.1's paint toolbar for both modes: Brush, Blur, Average and
/// Smear (VIEW3D_PT_tools_active), each a tool with a brush of its own type.
public enum PaintTool: String, CaseIterable, Sendable {
    case brush = "BRUSH", blur = "BLUR", average = "AVERAGE", smear = "SMEAR"

    /// The toolbar's names, as Blender's shows them.
    public var label: String {
        switch self {
        case .brush:   return "Brush"
        case .blur:    return "Blur"
        case .average: return "Average"
        case .smear:   return "Smear"
        }
    }

    /// The app's toolbar tool for it.
    public var tool: ActiveTool {
        switch self {
        case .brush:   return .paintDraw
        case .blur:    return .paintBlur
        case .average: return .paintAverage
        case .smear:   return .paintSmear
        }
    }

    public init?(_ tool: ActiveTool) {
        guard let found = Self.allCases.first(where: { $0.tool == tool }) else { return nil }
        self = found
    }
}

/// What the paint header shows, as Blender holds it (`_blenderkit_vwpaint.state`).
public struct PaintModeState: Decodable, Equatable, Sendable {
    public var real: Bool
    /// WEIGHT_PAINT or VERTEX_PAINT; nil outside both.
    public var mode: String?
    public var object: String?
    public var essentials: Bool?
    public var brush: String?
    public var region: [Int]?
    public var brushType: String?
    public var tool: String?
    public var strokeMethod: String?
    /// Size in Blender's header: a diameter in the region's pixels.
    public var size: Int?
    /// The brush's Blend, and the choices with Blender's names for them.
    public var blend: String?
    public var blends: [[String]]?
    public var strength: Double?
    public var weight: Double?
    /// sRGB, as Blender's colour picker shows it and as a stroke paints it
    /// into a colour attribute (`color_srgb`).
    public var color: [Double]?
    /// What Blender's RNA holds (`Brush.color` or the unified one), and in
    /// what space: SCENE_LINEAR in desktop 5.2.1 (subtype COLOR), SRGB for a
    /// COLOR_GAMMA property.
    public var colorHeld: [Double]?
    public var colorSpace: String?
    /// The vertex group Weight Paint paints, and whether it is locked.
    public var group: String?
    public var groupLocked: Bool?
    public var groups: Int?
    public var colorAttribute: String?
    public var undoStack: Int?

    enum CodingKeys: String, CodingKey {
        case real, mode, object, essentials, brush, region, tool, size, strength, weight, color, group, groups
        case blend, blends
        case brushType = "brush_type", strokeMethod = "stroke_method", groupLocked = "group_locked"
        case colorAttribute = "color_attribute", undoStack = "undo_stack"
        case colorHeld = "color_held", colorSpace = "color_space"
    }

    /// The toolbar tool Blender's brush belongs to.
    public var paintTool: PaintTool? { tool.flatMap(PaintTool.init(rawValue:)) }

    /// Region pixels per 3D View point, as `SculptState.regionScale`.
    public func regionScale(viewWidth: Float, viewHeight: Float) -> Float {
        guard let region, region.count == 2, viewWidth > 0, viewHeight > 0 else { return 1 }
        return min(1, Float(region[0]) / viewWidth, Float(region[1]) / viewHeight)
    }

    /// The last line of `text` that decodes.
    public static func parse(_ text: String) -> PaintModeState? {
        SculptJSON.last(PaintModeState.self, in: text)
    }
}

/// The Python for Weight Paint and Vertex Paint.
public enum PaintModeBpy {
    static let lead = "import json, _blenderkit_vwpaint as _bk_vw\n"
    static let module = "import _blenderkit_vwpaint\n"

    /// The two modes this module paints in.
    public static let modes: [InteractionMode] = [.weightPaint, .vertexPaint]

    /// Into the mode, as Blender's mode menu row does (`object.mode_set`),
    /// refused in words for what Blender would enter and not paint.
    public static func enter(_ mode: InteractionMode) -> String {
        module + "_blenderkit_vwpaint.enter('\(mode.bpyMode)')"
    }

    /// Back to Object Mode.
    public static let leave = module + "_blenderkit_vwpaint.leave()"

    /// What Blender's undo history calls a step into or out of the mode:
    /// measured in desktop 5.2.1, `mode_set` into either and back out pushes
    /// "Weight Paint Mode" / "Vertex Paint Mode" (its toggle operator's name).
    public static func modeUndo(_ mode: InteractionMode) -> String {
        mode == .vertexPaint ? "Vertex Paint Mode" : "Weight Paint Mode"
    }

    /// The step Blender's history records a stroke as (measured: a Global
    /// Undo step named "Weight Paint" / "Vertex Paint"), which a stroke's
    /// failure is reported under too.
    public static func strokeName(_ mode: InteractionMode) -> String {
        mode == .vertexPaint ? "Vertex Paint" : "Weight Paint"
    }

    public static let stateQuery = lead + "print(json.dumps(_bk_vw.state()))"

    public static let brushesQuery = lead + "print(json.dumps(_bk_vw.brushes()))"

    // Settings: no undo step, as Blender pushes none for a brush setting.

    public static func activate(_ brush: String) -> String {
        module + "_blenderkit_vwpaint.activate(\(Bpy.quote(brush)))"
    }

    public static func setTool(_ tool: PaintTool) -> String {
        module + "_blenderkit_vwpaint.set_tool('\(tool.rawValue)')"
    }

    public static func setSize(_ pixels: Int) -> String {
        module + "_blenderkit_vwpaint.set_size(\(max(1, pixels)))"
    }

    public static func setStrength(_ value: Float) -> String {
        module + String(format: "_blenderkit_vwpaint.set_strength(%.4f)", min(max(value, 0), 10))
    }

    public static func setWeight(_ value: Float) -> String {
        module + String(format: "_blenderkit_vwpaint.set_weight(%.4f)", min(max(value, 0), 1))
    }

    public static func setBlend(_ identifier: String) -> String {
        module + "_blenderkit_vwpaint.set_blend(\(Bpy.quote(identifier)))"
    }

    /// `rgb` in sRGB, as the colour picker gives it: Blender's module holds
    /// it in the property's own space (scene linear in 5.2.1).
    public static func setColor(_ rgb: SIMD3<Float>) -> String {
        module + String(format: "_blenderkit_vwpaint.set_color((%.4f, %.4f, %.4f))",
                        min(max(rgb.x, 0), 1), min(max(rgb.y, 0), 1), min(max(rgb.z, 0), 1))
    }

    // The stroke, in the shapes a sculpt stroke answers with.

    public static func begin(object: String, camera: SculptCamera, viewWidth: Float,
                             viewHeight: Float, invert: Bool = false) -> String {
        lead + "print(json.dumps(_bk_vw.begin(\(Bpy.quote(object)), \(camera.python), "
            + String(format: "(%.3f, %.3f)", viewWidth, viewHeight)
            + ", '\(invert ? "INVERT" : "NORMAL")')))"
    }

    public static func chunk(_ points: [SculptPoint]) -> String {
        let list = points.map {
            String(format: "(%.3f, %.3f, %.4f, %.4f)", $0.x, $0.y, $0.pressure, $0.time)
        }.joined(separator: ", ")
        return lead + "print(json.dumps(_bk_vw.chunk([\(list)])))"
    }

    public static let end = lead + "print(json.dumps(_bk_vw.end()))"

    /// Ends a stroke whose chunk Blender refused: what Blender holds of it
    /// (what the 3D View shows) is kept, and the dabs the throttle held back
    /// are not replayed. `end` would replay them, running the checks the
    /// chunk had just failed and putting the same refusal on the banner a
    /// second time (round 4's review).
    public static let cancel = lead + "print(json.dumps(_bk_vw.cancel()))"
}
