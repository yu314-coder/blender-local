import Foundation

// Sculpt Mode with Blender's own brushes. Everything here is the Python the
// interface sends to `_blenderkit_sculpt` (Resources/python/site), and the
// shapes of what it prints back; the brushes, the strokes, the undo steps and
// the operators are Blender's. See that module for what was measured.

/// The app's 3D View camera, as `_blenderkit_sculpt.aim` takes it: the same
/// numbers `ViewportCamera` holds, so Blender's 3D View is aimed where the
/// reader is looking.
public struct SculptCamera: Equatable, Sendable {
    public var target: SIMD3<Float>
    public var distance: Float
    public var azimuth: Float
    public var elevation: Float
    public var fovY: Float
    public var orthographic: Bool
    public var near: Float
    public var far: Float

    public init(target: SIMD3<Float>, distance: Float, azimuth: Float, elevation: Float,
                fovY: Float, orthographic: Bool, near: Float, far: Float) {
        self.target = target; self.distance = distance
        self.azimuth = azimuth; self.elevation = elevation
        self.fovY = fovY; self.orthographic = orthographic
        self.near = near; self.far = far
    }

    /// The Python dict literal `_blenderkit_sculpt.begin` reads.
    public var python: String {
        func n(_ v: Float) -> String { String(format: "%.9g", Double(v)) }
        return "dict(target=(\(n(target.x)), \(n(target.y)), \(n(target.z))), "
            + "distance=\(n(distance)), azimuth=\(n(azimuth)), elevation=\(n(elevation)), "
            + "fov_y=\(n(fovY)), ortho=\(orthographic ? "True" : "False"), "
            + "near=\(n(near)), far=\(n(far)))"
    }
}

/// One point of a stroke, in the 3D View's points (top-left origin), with the
/// pressure Blender's stroke takes (1 for a finger) and when it was made.
public struct SculptPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var time: Double

    public init(x: Float, y: Float, pressure: Float = 1, time: Double) {
        self.x = x; self.y = y; self.pressure = pressure; self.time = time
    }
}

/// `brush_stroke`'s mode: a plain stroke, Blender's Ctrl (the brush's other
/// direction) or its Shift (Smooth).
public enum SculptStrokeMode: String, CaseIterable, Sendable {
    case normal = "NORMAL", invert = "INVERT", smooth = "SMOOTH"

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .invert: return "Invert"
        case .smooth: return "Smooth"
        }
    }
}

/// Mask ▸ Clear, Invert and Fill: `paint.mask_flood_fill`.
public enum SculptMaskAction: String, CaseIterable, Sendable {
    case clear = "CLEAR", invert = "INVERT", fill = "FILL"

    public var label: String {
        switch self {
        case .clear:  return "Clear Mask"
        case .invert: return "Invert Mask"
        case .fill:   return "Fill Mask"
        }
    }
}

/// Face Sets ▸ Initialize: `sculpt.face_sets_init(mode=…)`.
public enum SculptFaceSetInit: String, CaseIterable, Sendable {
    case looseParts = "LOOSE_PARTS", materials = "MATERIALS", normals = "NORMALS"
    case uvSeams = "UV_SEAMS", creases = "CREASES", sharpEdges = "SHARP_EDGES"

    public var label: String {
        switch self {
        case .looseParts: return "By Loose Parts"
        case .materials:  return "By Materials"
        case .normals:    return "By Normals"
        case .uvSeams:    return "By UV Seams"
        case .creases:    return "By Edge Creases"
        case .sharpEdges: return "By Sharp Edges"
        }
    }
}

/// What the sculpt header shows, as Blender holds it (`_blenderkit_sculpt.state`).
public struct SculptState: Decodable, Equatable, Sendable {
    public struct Multires: Decodable, Equatable, Sendable {
        public var name: String
        public var levels: Int
        public var sculptLevels: Int
        public var totalLevels: Int
        enum CodingKeys: String, CodingKey {
            case name, levels
            case sculptLevels = "sculpt_levels", totalLevels = "total_levels"
        }
    }

    public var real: Bool
    public var essentials: Bool
    public var object: String?
    public var mode: String
    public var brush: String?
    /// Blender's 3D View region, in pixels.
    public var region: [Int]?
    /// Brush Size: a diameter in the region's pixels.
    public var size: Int?
    public var strength: Double?
    public var unifiedSize: Bool?
    public var unifiedStrength: Bool?
    public var brushType: String?
    public var strokeMethod: String?
    public var strategy: String?
    public var detailType: String?
    public var detailSize: Double?
    public var detailPercent: Double?
    public var detailResolution: Double?
    public var dyntopo: Bool?
    public var voxelSize: Double?
    public var vertices: Int?
    public var faces: Int?
    public var multires: Multires?
    /// Masked vertices; nil where Blender holds a mask no script can read —
    /// on a Multires level, whose mask is in grid layers.
    public var masked: Int?
    public var faceSets: Int?
    /// The object's world scale: the voxel size is in its own units.
    public var scale: [Double]?
    /// The most base-mesh vertices a Multires is sculpted on here
    /// (`_blenderkit_sculpt.MULTIRES_BASE_BUDGET`).
    public var multiresBaseBudget: Int?
    /// How many steps Blender's undo stack holds, read from it; nil where it
    /// cannot be read, and then a stroke's steps are counted as they are made.
    public var undoStack: Int?

    enum CodingKeys: String, CodingKey {
        case real, essentials, object, mode, brush, region, size, strength, strategy
        case unifiedSize = "unified_size", unifiedStrength = "unified_strength"
        case brushType = "brush_type", strokeMethod = "stroke_method"
        case detailType = "detail_type", detailSize = "detail_size"
        case detailPercent = "detail_percent", detailResolution = "detail_resolution"
        case dyntopo, voxelSize = "voxel_size", vertices, faces, multires, masked, scale
        case faceSets = "face_sets", undoStack = "undo_stack"
        case multiresBaseBudget = "multires_base_budget"
    }

    /// Whether the object's scale makes its own units — the voxel size's —
    /// differ from the scene's.
    public var isScaled: Bool {
        guard let scale, scale.count == 3 else { return false }
        return scale.contains { abs(abs($0) - 1) > 1e-4 }
    }

    /// The voxel size in the scene's metres, where the object's scale is the
    /// same on every axis; nil otherwise.
    public var voxelSizeInScene: Double? {
        guard let voxelSize, let scale, scale.count == 3 else { return nil }
        let s = scale.map(abs)
        guard let first = s.first, s.allSatisfy({ abs($0 - first) <= 1e-6 * max(1, first) }) else { return nil }
        return voxelSize * first
    }

    /// Whether a Multires on this mesh would be over the base budget.
    public var multiresOverBudget: Bool {
        guard let vertices, let multiresBaseBudget else { return false }
        return vertices > multiresBaseBudget
    }

    /// The last line of `text` that decodes.
    public static func parse(_ text: String) -> SculptState? {
        SculptJSON.last(SculptState.self, in: text)
    }

    /// The Detailing value the header edits: Blender's field for the method
    /// in use — pixels for Relative, a percentage of the brush for Brush, a
    /// resolution for Constant and Manual.
    public var detailValue: Double? {
        switch detailType {
        case "RELATIVE": return detailSize
        case "BRUSH":    return detailPercent
        case .some:      return detailResolution
        case .none:      return nil
        }
    }

    public var detailUnit: String {
        switch detailType {
        case "RELATIVE": return "px"
        case "BRUSH":    return "%"
        default:         return ""
        }
    }

    /// Region pixels per 3D View point for a view of this size — the scale
    /// `_blenderkit_sculpt.mapping` strokes with — so Blender's Size can be
    /// drawn as the circle it covers. 1 when Blender's region is not known.
    public func regionScale(viewWidth: Float, viewHeight: Float) -> Float {
        guard let region, region.count == 2, viewWidth > 0, viewHeight > 0 else { return 1 }
        return min(1, Float(region[0]) / viewWidth, Float(region[1]) / viewHeight)
    }
}

/// `_blenderkit_sculpt.begin`'s answer.
public struct SculptStrokeStart: Decodable, Equatable, Sendable {
    public var strategy: String
    public var brush: String
    public var scale: Double
    public var region: [Int]
}

/// `_blenderkit_sculpt.chunk`'s answer.
public struct SculptChunkResult: Decodable, Equatable, Sendable {
    public var dabs: Int
    public var applied: Bool
    public var strategy: String
    public var strokeMs: Double
    public var mirrorMs: Double
    public var runMs: Double?
    public var undoMs: Double?
    public var cut: Bool?

    enum CodingKeys: String, CodingKey {
        case dabs, applied, strategy, cut
        case strokeMs = "stroke_ms", mirrorMs = "mirror_ms", runMs = "run_ms", undoMs = "undo_ms"
    }
}

/// `_blenderkit_sculpt.end`'s answer: how many of Blender's undo steps the
/// stroke is, and what it cost.
public struct SculptStrokeEnd: Decodable, Equatable, Sendable {
    public var pushed: Int
    public var counted: Bool
    public var chunks: Int
    public var cuts: Int
    public var dabs: Int
    public var strategy: String
    public var strokeMs: [Double]
    public var mirrorMs: [Double]
    /// Why a stroke gathered for the lift (on a Multires level) was not made.
    public var refused: String?

    enum CodingKeys: String, CodingKey {
        case pushed, counted, chunks, cuts, dabs, strategy, refused
        case strokeMs = "stroke_ms", mirrorMs = "mirror_ms"
    }
}

enum SculptJSON {
    /// Blender's operators may print before the answer, so the last line that
    /// decodes wins.
    static func last<T: Decodable>(_ type: T.Type, in text: String) -> T? {
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                  let data = trimmed.data(using: .utf8),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { continue }
            return value
        }
        return nil
    }
}

/// When a stroke's points go to Blender.
///
/// Each chunk replays the stroke so far as one of Blender's strokes and
/// mirrors the object, on the main thread, so it holds the interface while it
/// runs. Sending one per touch event would spend every frame in Blender on a
/// heavy mesh; sending only at the end would show nothing while the finger
/// moves. So the first point goes at once — the dab appears under the finger —
/// and then a chunk goes once `interval` has passed since the last one, and
/// never sooner than the last one's cost again: the interface keeps at least
/// half of every second to draw and take touches in.
public struct SculptStreamPolicy: Equatable, Sendable {
    /// Seconds between chunks at the least.
    public var interval: Double
    /// Times the last chunk's cost the next one waits, at the least.
    public var costFactor: Double

    public private(set) var lastSent: Double?
    public private(set) var lastCost: Double = 0

    public init(interval: Double = 1.0 / 30.0, costFactor: Double = 1.0) {
        self.interval = interval
        self.costFactor = costFactor
    }

    /// Whether the points waiting at `now` go now.
    public func shouldSend(at now: Double, pending: Int) -> Bool {
        guard pending > 0 else { return false }
        guard let lastSent else { return true }
        return now - lastSent >= max(interval, lastCost * costFactor)
    }

    /// A chunk went at `now` and took `cost` seconds.
    public mutating func sent(at now: Double, cost: Double) {
        lastSent = now + cost
        lastCost = cost
    }
}

/// The Python for Sculpt Mode.
public enum SculptBpy {
    static let lead = "import json, _blenderkit_sculpt as _bk_sculpt\n"

    /// What the header shows (`SculptState`), printed as one line of JSON.
    public static let stateQuery = lead + "print(json.dumps(_bk_sculpt.state()))"

    /// Blender's Essentials sculpt brushes, by name.
    public static let brushesQuery = lead + "print(json.dumps(_bk_sculpt.brushes()))"

    public static func begin(object: String, camera: SculptCamera, viewWidth: Float,
                             viewHeight: Float, mode: SculptStrokeMode) -> String {
        lead + "print(json.dumps(_bk_sculpt.begin(\(Bpy.quote(object)), \(camera.python), "
            + String(format: "(%.3f, %.3f)", viewWidth, viewHeight)
            + ", '\(mode.rawValue)')))"
    }

    public static func chunk(_ points: [SculptPoint]) -> String {
        let list = points.map {
            String(format: "(%.3f, %.3f, %.4f, %.4f)", $0.x, $0.y, $0.pressure, $0.time)
        }.joined(separator: ", ")
        return lead + "print(json.dumps(_bk_sculpt.chunk([\(list)])))"
    }

    public static let end = lead + "print(json.dumps(_bk_sculpt.end()))"

    // Settings: no undo step, as Blender pushes none for a brush setting.

    public static func activate(_ brush: String) -> String {
        "import _blenderkit_sculpt\n_blenderkit_sculpt.activate(\(Bpy.quote(brush)))"
    }

    public static func setSize(_ pixels: Int) -> String {
        "import _blenderkit_sculpt\n_blenderkit_sculpt.set_size(\(max(1, pixels)))"
    }

    public static func setStrength(_ value: Float) -> String {
        "import _blenderkit_sculpt\n"
            + String(format: "_blenderkit_sculpt.set_strength(%.4f)", min(max(value, 0), 10))
    }

    public static func setDetail(_ value: Float) -> String {
        "import _blenderkit_sculpt\n" + String(format: "_blenderkit_sculpt.set_detail(%.4f)", value)
    }

    public static func setVoxelSize(_ value: Float) -> String {
        "import _blenderkit_sculpt\n" + String(format: "_blenderkit_sculpt.set_voxel_size(%.6f)", value)
    }

    // Operations: each an undo step, named as Blender names the operator.

    public static func dyntopo(_ on: Bool) -> String {
        "import _blenderkit_sculpt\n_blenderkit_sculpt.dyntopo(\(on ? "True" : "False"))"
    }
    public static let dyntopoUndo = "Dynamic Topology Toggle"

    public static let voxelRemesh = "import _blenderkit_sculpt\n_blenderkit_sculpt.voxel_remesh()"
    public static let voxelRemeshUndo = "Voxel Remesh"

    public static let multiresSubdivide = "import _blenderkit_sculpt\n_blenderkit_sculpt.multires_subdivide()"
    public static let multiresSubdivideUndo = "Multires Subdivide"

    public static func mask(_ action: SculptMaskAction) -> String {
        "import _blenderkit_sculpt\n_blenderkit_sculpt.mask('\(action.rawValue)')"
    }
    public static let maskUndo = "Mask Flood Fill"

    public static func faceSetsInit(_ mode: SculptFaceSetInit) -> String {
        "import _blenderkit_sculpt\n_blenderkit_sculpt.face_sets_init('\(mode.rawValue)')"
    }
    public static let faceSetsInitUndo = "Init Face Sets"

    public static let faceSetFromMask = "import _blenderkit_sculpt\n_blenderkit_sculpt.face_set_from_mask()"
    public static let faceSetFromMaskUndo = "Create Face Set"

    /// Sculpt Mode, in and out: Blender's own, so its brushes, dynamic
    /// topology and mask work on the mesh itself. The way in is refused, in
    /// words and before Blender enters, for a Multires level too heavy to
    /// sculpt here (`_blenderkit_sculpt.refuse_heavy_multires`): entering
    /// would read the level back, 26.8 s on a 49,922-vertex base.
    public static let enter = Bpy.needsAMesh(for: InteractionMode.sculpt.label)
        + "\nimport _blenderkit_sculpt\n_blenderkit_sculpt.refuse_heavy_multires()"
        + "\nbpy.ops.object.mode_set(mode='\(InteractionMode.sculpt.bpyMode)')"
    public static let leave = "bpy.ops.object.mode_set(mode='OBJECT')"
    public static let modeUndo = "Sculpt Mode"
}
