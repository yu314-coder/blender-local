import Foundation
import simd

// Blender's precision trio — snapping, the pivot point and proportional
// editing — and the 3D cursor they all work against.
//
// All four are scene state, not operators: Blender keeps them on
// `scene.tool_settings` and `scene.cursor`, and its 3D View header reads them
// straight back out. So every control writes through
// Resources/python/site/_blenderkit_tools.py and shows what the mirror brings
// back, never a local copy. Identifiers here are Blender's own, spelled out
// rather than derived from the case name: `inverseSquare.uppercased()` is
// "INVERSESQUARE", and a wrong identifier is a silent runtime failure inside a
// mirroring pass.

/// `tool_settings.snap_elements_base`, in Blender's RNA order — which is also
/// the bit position `_blenderkit_tools` packs each one at.
public enum SnapElement: Int, CaseIterable, Identifiable, Codable, Sendable {
    case increment = 0, grid, vertex, edge, face, volume,
         edgeMidpoint, edgePerpendicular, faceMidpoint

    public var id: Int { rawValue }

    public var bpyIdentifier: String {
        switch self {
        case .increment:          return "INCREMENT"
        case .grid:               return "GRID"
        case .vertex:             return "VERTEX"
        case .edge:               return "EDGE"
        case .face:               return "FACE"
        case .volume:             return "VOLUME"
        case .edgeMidpoint:       return "EDGE_MIDPOINT"
        case .edgePerpendicular:  return "EDGE_PERPENDICULAR"
        case .faceMidpoint:       return "FACE_MIDPOINT"
        }
    }

    /// The name Blender's own menu uses, read from `bl_rna` in 5.2.1.
    public var label: String {
        switch self {
        case .increment:          return "Increment"
        case .grid:               return "Grid"
        case .vertex:             return "Vertex"
        case .edge:               return "Edge"
        case .face:               return "Face"
        case .volume:             return "Volume"
        case .edgeMidpoint:       return "Edge Center"
        case .edgePerpendicular:  return "Edge Perpendicular"
        case .faceMidpoint:       return "Face Center"
        }
    }

    /// Whether a drag in this viewport honours it.
    ///
    /// A headless Blender does not snap a transform at all — measured in
    /// 5.2.1, `translate(value=(0.3,0,0))` landed on 0.3 with `use_snap` on and
    /// INCREMENT chosen, and again with `snap=True, snap_elements={'INCREMENT'}`
    /// passed to the operator, because the exec path takes `value` as final.
    /// So the drag snaps its own result and commits the snapped value:
    /// Increment and Grid in `TransformSnap`, Vertex, Edge, Edge Center, Face
    /// and Face Center in `GeometrySnap`. Volume and Edge Perpendicular are not
    /// reproduced, so they stay scene settings: saved in the .blend,
    /// meaningful on a desktop, and changing no drag.
    public var isHonouredByDrag: Bool {
        self == .increment || self == .grid || GeometrySnap.honoured.contains(self)
    }

    /// What the Snapping panel says beside it.
    public var dragNote: String? {
        switch self {
        case .increment: return "steps"
        case .volume, .edgePerpendicular: return "scene setting"
        default:         return "moves only"
        }
    }
}

/// `tool_settings.snap_elements_individual` — the two Blender keeps apart from
/// the rest because they project rather than snap to a point.
public enum SnapElementIndividual: Int, CaseIterable, Identifiable, Codable, Sendable {
    case faceProject = 0, faceNearest

    public var id: Int { rawValue }

    public var bpyIdentifier: String {
        self == .faceProject ? "FACE_PROJECT" : "FACE_NEAREST"
    }

    public var label: String {
        self == .faceProject ? "Face Project" : "Face Nearest"
    }
}

/// `tool_settings.snap_target` — Blender's "Snap With".
public enum SnapTarget: Int, CaseIterable, Identifiable, Codable, Sendable {
    case closest = 0, center, median, active

    public var id: Int { rawValue }

    public var bpyIdentifier: String {
        switch self {
        case .closest: return "CLOSEST"
        case .center:  return "CENTER"
        case .median:  return "MEDIAN"
        case .active:  return "ACTIVE"
        }
    }

    public var label: String {
        switch self {
        case .closest: return "Closest"
        case .center:  return "Center"
        case .median:  return "Median"
        case .active:  return "Active"
        }
    }
}

/// `tool_settings.transform_pivot_point` — what a rotation or a scale turns
/// about.
public enum TransformPivot: Int, CaseIterable, Identifiable, Codable, Sendable {
    case boundingBoxCenter = 0, cursor, individualOrigins, medianPoint, activeElement

    public var id: Int { rawValue }

    public var bpyIdentifier: String {
        switch self {
        case .boundingBoxCenter: return "BOUNDING_BOX_CENTER"
        case .cursor:            return "CURSOR"
        case .individualOrigins: return "INDIVIDUAL_ORIGINS"
        case .medianPoint:       return "MEDIAN_POINT"
        case .activeElement:     return "ACTIVE_ELEMENT"
        }
    }

    public var label: String {
        switch self {
        case .boundingBoxCenter: return "Bounding Box Center"
        case .cursor:            return "3D Cursor"
        case .individualOrigins: return "Individual Origins"
        case .medianPoint:       return "Median Point"
        case .activeElement:     return "Active Element"
        }
    }

    public var icon: String {
        switch self {
        case .boundingBoxCenter: return "rectangle.dashed"
        case .cursor:            return "scope"
        case .individualOrigins: return "circle.grid.2x2"
        case .medianPoint:       return "circle.and.line.horizontal"
        case .activeElement:     return "square.on.square.dashed"
        }
    }
}

public extension MeshEditor.ProportionalFalloff {
    /// `tool_settings.proportional_edit_falloff`. Spelled out because
    /// `inverseSquare.rawValue.uppercased()` would be "INVERSESQUARE".
    var bpyIdentifier: String {
        switch self {
        case .smooth:        return "SMOOTH"
        case .sphere:        return "SPHERE"
        case .root:          return "ROOT"
        case .inverseSquare: return "INVERSE_SQUARE"
        case .sharp:         return "SHARP"
        case .linear:        return "LINEAR"
        case .constant:      return "CONSTANT"
        case .random:        return "RANDOM"
        }
    }
}

/// The whole of `scene.tool_settings` this app reads and writes.
///
/// Defaults are Blender's factory defaults, measured in 5.2.1: nothing snaps,
/// Increment is the element, Closest is the target, Median Point is the pivot,
/// proportional editing is off with a Smooth falloff and a size of 1.
public struct TransformToolSettings: Equatable, Codable, Sendable {
    public var useSnap = false
    public var elements: Set<SnapElement> = [.increment]
    public var individual: Set<SnapElementIndividual> = []
    public var target: SnapTarget = .closest
    public var pivot: TransformPivot = .medianPoint
    /// Blender keeps edit mode's proportional switch apart from object mode's.
    public var proportionalEdit = false
    public var proportionalObjects = false
    public var connected = false
    public var falloff: MeshEditor.ProportionalFalloff = .smooth
    public var size: Float = 1
    /// `use_mesh_automerge` and `double_threshold`. Measured in 5.2.1
    /// headless: the translate the gizmo commits honours both straight from
    /// the scene (the centre vertex of a 3 × 3 grid moved onto its neighbour
    /// left 8 vertices with Auto Merge on and 9 with it off; moved to 0.9995
    /// it merged at 0.001, and to 0.9985 it did not), so the preview has to
    /// weld by exactly these and nothing of its own.
    public var autoMerge = false
    public var mergeThreshold: Float = 0.001
    /// `use_snap_self` and `use_snap_nonedit`, the two Target Selection
    /// options a drag here honours. Both apply while editing only
    /// (`snap_target_select_from_spacetype_and_tool_settings`,
    /// transform_snap.cc): the first keeps the edited object's own geometry
    /// in reach, the second every other object.
    public var snapSelf = true
    public var snapNonEdited = true
    /// `use_mesh_automerge_and_split`, Auto Merge's Split Edges & Faces.
    /// Measured in 5.2.1: with it on, a vertex moved onto another mesh's edge
    /// splits that edge where the vertex is (7 vertices either way, 8 edges
    /// for 7, a quad becomes a pentagon), and an edge moved across another
    /// splits both where they cross (7 vertices became 9).
    public var autoMergeSplit = false
    /// `use_transform_skip_children`, Affect Only Parents. Measured in 5.2.1:
    /// a parent moved, turned or scaled leaves its child where it was, while a
    /// Copy Location follower still follows.
    public var affectOnlyParents = false
    /// `use_transform_data_origin`, Affect Only Origins. Measured in 5.2.1:
    /// the origin moves, turns or scales and the geometry stays where it was
    /// in the world, while children still follow the origin.
    public var affectOnlyOrigins = false

    /// `proportional_size`'s hard range, read from `bl_rna` in 5.2.1. Measured:
    /// bpy clamps to it rather than raising — 0.0 came back as 1e-5 and 9000 as
    /// 5000 — so a field that did not clamp would show a number Blender never
    /// held until the next mirroring pass corrected it.
    public static let sizeRange: ClosedRange<Float> = 1e-5...5000

    /// `double_threshold`'s hard range, read from `bl_rna` in 5.2.1.
    public static let mergeThresholdRange: ClosedRange<Float> = 0...1

    public init() {}

    /// Whether proportional editing applies right now. Blender's header toggle
    /// writes `use_proportional_edit` in edit mode and
    /// `use_proportional_edit_objects` everywhere else.
    public func isProportional(editing: Bool) -> Bool {
        editing ? proportionalEdit : proportionalObjects
    }

    /// Whether a drag snaps: the magnet is on and one of the elements is one a
    /// drag honours. See `SnapElement.isHonouredByDrag`.
    public var snapsDrag: Bool {
        useSnap && elements.contains(where: \.isHonouredByDrag)
    }

    /// Whether unticking one Snap To element would leave none at all, which
    /// Blender refuses. Measured in 5.2.1: `snap_elements_base = set()` is
    /// ignored while `snap_elements_individual` is empty too, and accepted
    /// with {'FACE_PROJECT'} there — and the individual set cannot be
    /// emptied while the base is. The rule is on the two together.
    public var holdsLastSnapElement: Bool {
        elements.count + individual.count <= 1
    }
}

// MARK: - The Python every control sends

/// The strings the header's menus and the N-panel run.
///
/// Every one of these goes through `bridge.run`. None carries an undo label:
/// they are settings, and Blender does not push an undo step for changing one
/// either. The snap menu's five actions do carry one — they move objects.
public enum ToolsBpy {

    /// Spelled out, as `_blenderkit_anim`'s callers are: the Info log is the
    /// action, and a reader has to be able to find what ran.
    private static let preamble = "import _blenderkit_tools\n"

    private static func set(_ argument: String) -> String {
        preamble + "_blenderkit_tools.set_tools(\(argument))"
    }

    private static func identifiers<T: Collection>(_ values: T) -> String
        where T.Element == String {
        // `{}` would be an empty dict, which reads wrong in the Info log.
        values.isEmpty ? "set()" : "{" + values.sorted().map { "'\($0)'" }.joined(separator: ", ") + "}"
    }

    public static func useSnap(_ on: Bool) -> String {
        set("use_snap=\(on ? "True" : "False")")
    }

    /// The interface never empties both sets at once: measured in 5.2.1,
    /// Blender ignores the assignment that would (see
    /// `TransformToolSettings.holdsLastSnapElement`), so that box would look
    /// like a control that does nothing.
    public static func elements(_ values: Set<SnapElement>) -> String {
        set("elements=" + identifiers(values.map(\.bpyIdentifier)))
    }

    public static func individual(_ values: Set<SnapElementIndividual>) -> String {
        set("individual=" + identifiers(values.map(\.bpyIdentifier)))
    }

    public static func target(_ value: SnapTarget) -> String {
        set("target='\(value.bpyIdentifier)'")
    }

    public static func pivot(_ value: TransformPivot) -> String {
        set("pivot='\(value.bpyIdentifier)'")
    }

    public static func proportional(_ on: Bool, editing: Bool) -> String {
        set("\(editing ? "proportional_edit" : "proportional_objects")=\(on ? "True" : "False")")
    }

    public static func connected(_ on: Bool) -> String {
        set("connected=\(on ? "True" : "False")")
    }

    public static func falloff(_ value: MeshEditor.ProportionalFalloff) -> String {
        set("falloff='\(value.bpyIdentifier)'")
    }

    public static func size(_ value: Float) -> String {
        let clamped = min(max(value, TransformToolSettings.sizeRange.lowerBound),
                          TransformToolSettings.sizeRange.upperBound)
        return set(String(format: "size=%.5f", clamped))
    }

    public static func autoMerge(_ on: Bool) -> String {
        set("automerge=\(on ? "True" : "False")")
    }

    /// Six places, Blender's own precision for it (`bl_rna` in 5.2.1).
    public static func mergeThreshold(_ value: Float) -> String {
        let range = TransformToolSettings.mergeThresholdRange
        return set(String(format: "merge_threshold=%.6f", min(max(value, range.lowerBound), range.upperBound)))
    }

    public static func snapSelf(_ on: Bool) -> String {
        set("snap_self=\(on ? "True" : "False")")
    }

    public static func snapNonEdited(_ on: Bool) -> String {
        set("snap_nonedit=\(on ? "True" : "False")")
    }

    public static func autoMergeSplit(_ on: Bool) -> String {
        set("automerge_split=\(on ? "True" : "False")")
    }

    public static func affectOnlyParents(_ on: Bool) -> String {
        set("skip_children=\(on ? "True" : "False")")
    }

    public static func affectOnlyOrigins(_ on: Bool) -> String {
        set("data_origin=\(on ? "True" : "False")")
    }

    public static func setCursor(_ position: SIMD3<Float>) -> String {
        preamble + String(format: "_blenderkit_tools.set_cursor(%.4f, %.4f, %.4f)",
                          position.x, position.y, position.z)
    }

    /// Blender's Shift+S menu. `_blenderkit_tools.snap` stands in for
    /// `bpy.ops.view3d.snap_*`, which cannot be called: measured in 5.2.1
    /// headless, they fail their poll with "Expected a view3d region".
    ///
    /// The two grid actions take the viewport's increment: Blender takes
    /// `ED_view3d_grid_view_scale`, a property of a view this app does not
    /// have.
    public static func snap(_ action: SnapAction, increment: Float = 1) -> String {
        let step = increment > 0 ? increment : 1
        switch action {
        case .selectionToGrid:
            return preamble + String(format: "_blenderkit_tools.snap('SELECTED_TO_GRID', step=%.4f)", step)
        case .selectionToCursor:
            return preamble + "_blenderkit_tools.snap('SELECTED_TO_CURSOR', use_offset=False)"
        case .selectionToCursorKeepingOffset:
            return preamble + "_blenderkit_tools.snap('SELECTED_TO_CURSOR', use_offset=True)"
        case .selectionToActive:
            return preamble + "_blenderkit_tools.snap('SELECTED_TO_ACTIVE')"
        case .cursorToSelection:
            return preamble + "_blenderkit_tools.snap('CURSOR_TO_SELECTED')"
        case .cursorToCenter:
            return preamble + "_blenderkit_tools.snap('CURSOR_TO_CENTER')"
        case .cursorToGrid:
            return preamble + String(format: "_blenderkit_tools.snap('CURSOR_TO_GRID', step=%.4f)", step)
        case .cursorToActive:
            return preamble + "_blenderkit_tools.snap('CURSOR_TO_ACTIVE')"
        }
    }

    /// INDIVIDUAL_ORIGINS, which one `center_override` cannot express: the
    /// helper runs one operator per object about that object's own origin.
    public static func transformIndividual(_ body: String) -> String {
        preamble + "_blenderkit_tools.transform_individual(\(body))"
    }
}

/// Blender's VIEW3D_MT_snap, in its order: read from 5.2.1's
/// scripts/startup/bl_ui/space_view3d.py, where the four Selection actions
/// come first, then a separator, then the four Cursor ones.
public enum SnapAction: String, CaseIterable, Identifiable, Sendable {
    case selectionToGrid, selectionToCursor, selectionToCursorKeepingOffset, selectionToActive
    case cursorToSelection, cursorToCenter, cursorToGrid, cursorToActive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .selectionToGrid:                return "Selection to Grid"
        case .selectionToCursor:              return "Selection to Cursor"
        case .selectionToCursorKeepingOffset: return "Selection to Cursor (Keep Offset)"
        case .selectionToActive:              return "Selection to Active"
        case .cursorToSelection:              return "Cursor to Selected"
        case .cursorToCenter:                 return "Cursor to World Origin"
        case .cursorToGrid:                   return "Cursor to Grid"
        case .cursorToActive:                 return "Cursor to Active"
        }
    }

    /// Whether it moves the cursor rather than the selection; Blender puts a
    /// separator between the two groups.
    public var movesCursor: Bool {
        switch self {
        case .cursorToSelection, .cursorToCenter, .cursorToGrid, .cursorToActive: return true
        default: return false
        }
    }

    /// Whether it needs something selected. The cursor's own two do not.
    public var needsSelection: Bool { self != .cursorToCenter && self != .cursorToGrid }

    /// Whether it needs an active object — the two "to Active" actions, which
    /// Blender cancels with "No active element found!" without one.
    public var needsActive: Bool { self == .selectionToActive || self == .cursorToActive }

    /// Whether the menus offer it now. In Edit Mode the two Active actions
    /// need an active vertex, edge or face — `_blenderkit_tools._active_point`
    /// reads `bmesh.select_history.active` — and the app's taps hand Blender
    /// a selection with no history (`BpyBridge.pushEditSelection` sets the
    /// flags only), so there they could only ever answer "No active element
    /// found!" (round 2's review).
    public func isOffered(in scene: BKScene) -> Bool {
        if needsSelection && scene.selection.isEmpty { return false }
        if needsActive && (scene.active == nil || scene.mode == .edit) { return false }
        return true
    }

    /// The undo step's name. Blender names one after the operator.
    public var undoName: String {
        movesCursor ? "Snap Cursor" : "Snap Selection"
    }
}

// MARK: - The mirror

/// What `_blenderkit_tools.report()` hands the interface, applied to the
/// display cache.
///
/// Kept out of Python/EmbeddedBpyRuntime.swift for the reason that file gives:
/// it names the C API, and the host test suites cannot compile it. These are
/// plain Swift.
public enum TransformToolsMirror {

    /// The eleven ints and five doubles `tool_state` carries, in their order.
    /// That order is written out four times — here, in `tool_state` in
    /// PythonBootstrap.c, in `_blenderkit_tools.report` and in the shim's
    /// `_TOOL_FIELDS` — so a field added to one and not the others shifts
    /// every value after it.
    public struct State: Equatable, Sendable {
        public var tools: TransformToolSettings
        public var cursor: SIMD3<Float>

        public init(tools: TransformToolSettings, cursor: SIMD3<Float>) {
            self.tools = tools
            self.cursor = cursor
        }
    }

    public static func state(of scene: BKScene) -> State {
        State(tools: scene.tools, cursor: scene.cursor)
    }

    public static func apply(_ state: State, to scene: BKScene) {
        // Compared before assigning, for the reason AnimationMirror gives:
        // `BKScene` is @Observable and a mirroring pass runs after every
        // command, so writing an unchanged value still redraws every reader.
        if scene.tools != state.tools { scene.tools = state.tools }
        if scene.cursor != state.cursor { scene.cursor = state.cursor }
    }

    // MARK: packing

    private static func set<T: RawRepresentable & CaseIterable & Hashable>(
        _ bits: Int, _ type: T.Type) -> Set<T> where T.RawValue == Int {
        Set(T.allCases.filter { bits & (1 << $0.rawValue) != 0 })
    }

    private static func bits<T: RawRepresentable & Hashable>(_ values: Set<T>) -> Int
        where T.RawValue == Int {
        values.reduce(0) { $0 | (1 << $1.rawValue) }
    }

    /// Unpacks what Python sent. Every enum falls back to its default rather
    /// than trapping: the scalars come from a Blender that may have grown an
    /// identifier this build does not know.
    public static func state(ints: [Int], doubles: [Double]) -> State? {
        guard ints.count >= 11, doubles.count >= 5 else { return nil }
        var tools = TransformToolSettings()
        tools.useSnap = ints[0] != 0
        tools.elements = set(ints[1], SnapElement.self)
        tools.individual = set(ints[2], SnapElementIndividual.self)
        tools.target = SnapTarget(rawValue: ints[3]) ?? .closest
        tools.pivot = TransformPivot(rawValue: ints[4]) ?? .medianPoint
        tools.proportionalEdit = ints[5] != 0
        tools.proportionalObjects = ints[6] != 0
        tools.connected = ints[7] != 0
        let falloffs = MeshEditor.ProportionalFalloff.allCases
        tools.falloff = ints[8] >= 0 && ints[8] < falloffs.count ? falloffs[ints[8]] : .smooth
        // A size of zero would make every proportional transform a no-op.
        let size = Float(doubles[0])
        tools.size = TransformToolSettings.sizeRange.contains(size) ? size : 1
        tools.autoMerge = ints[9] != 0
        tools.snapSelf = ints[10] & SnapTargetFlag.snapSelf != 0
        tools.snapNonEdited = ints[10] & SnapTargetFlag.nonEdited != 0
        tools.autoMergeSplit = ints[10] & SnapTargetFlag.autoMergeSplit != 0
        tools.affectOnlyParents = ints[10] & SnapTargetFlag.affectOnlyParents != 0
        tools.affectOnlyOrigins = ints[10] & SnapTargetFlag.affectOnlyOrigins != 0
        let threshold = Float(doubles[4])
        tools.mergeThreshold = TransformToolSettings.mergeThresholdRange.contains(threshold) ? threshold : 0.001
        return State(tools: tools,
                     cursor: SIMD3(Float(doubles[1]), Float(doubles[2]), Float(doubles[3])))
    }

    /// The same, the other way: what the shim reads back through
    /// `tool_state_get` before merging one change into it.
    public static func scalars(_ state: State) -> (ints: [Int], doubles: [Double]) {
        let t = state.tools
        let falloff = MeshEditor.ProportionalFalloff.allCases
            .firstIndex(of: t.falloff) ?? 0
        return (ints: [t.useSnap ? 1 : 0, bits(t.elements), bits(t.individual),
                       t.target.rawValue, t.pivot.rawValue,
                       t.proportionalEdit ? 1 : 0, t.proportionalObjects ? 1 : 0,
                       t.connected ? 1 : 0, falloff, t.autoMerge ? 1 : 0,
                       (t.snapSelf ? SnapTargetFlag.snapSelf : 0)
                           | (t.snapNonEdited ? SnapTargetFlag.nonEdited : 0)
                           | (t.autoMergeSplit ? SnapTargetFlag.autoMergeSplit : 0)
                           | (t.affectOnlyParents ? SnapTargetFlag.affectOnlyParents : 0)
                           | (t.affectOnlyOrigins ? SnapTargetFlag.affectOnlyOrigins : 0)],
                doubles: [Double(t.size), Double(state.cursor.x),
                          Double(state.cursor.y), Double(state.cursor.z),
                          Double(t.mergeThreshold)])
    }

    /// The bits of the eleventh int, as `_blenderkit_tools.SNAP_FLAGS` packs
    /// them.
    public enum SnapTargetFlag {
        public static let snapSelf = 1
        public static let nonEdited = 2
        public static let autoMergeSplit = 4
        public static let affectOnlyParents = 8
        public static let affectOnlyOrigins = 16
    }
}
