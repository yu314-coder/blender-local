import Foundation

/// What the keys say during Blender's G, R and S: the move, turn or scale that
/// follows the pointer until a click or Return confirms it and Escape or a
/// right-click puts everything back (`transform.translate`, `rotate` and
/// `resize` invoked from the keymap, transform.cc's modal map, 5.2.1).
///
/// Two things are kept here, apart from the drag itself, so the host suite
/// can hold them to Blender's code without a 3D View:
///
/// - **The constraint.** X, Y or Z holds the transform to that axis, and
///   Shift with one to the plane across it — Blender's AXIS_X…PLANE_Z.
///   Pressing the same letter again cycles the orientation as
///   `transform_event_xyz_constraint` does: the scene's Transform
///   Orientation first (`orient[O_SCENE]`), then the other one
///   (`orient[O_SET]`: Local when the scene's is Global, Global otherwise),
///   then none. A different letter starts over at the scene's. The letter is
///   what counts, not axis or plane: Shift+X then X goes to the second
///   orientation on the X axis, as `constraintModeToChar` gives both 'X'.
/// - **Typed numbers** (Blender's NumInput): digits, a point, minus to
///   negate, Backspace, and Tab to the next value. Once a number is typed the
///   pointer no longer decides; with every character deleted it does again.
///   Move takes metres along the constraint, or X, Y, Z with none; Rotate
///   degrees; Scale a factor, the one value for every axis it acts on until
///   Tab gives each its own.
public struct ModalTransformInput: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case translate, rotate, scale
        /// R pressed again during Rotate (TFM_TRACKBALL): the selection turns
        /// about the view's horizontal and vertical axes, and R once more goes
        /// back to Rotate.
        case trackball
        /// G pressed again during Move in Edit Mode (TFM_EDGE_SLIDE): the
        /// selected edges slide along the faces beside them. Where they
        /// cannot, a single vertex slides along one of its edges
        /// (TFM_VERT_SLIDE).
        case edgeSlide, vertexSlide

        /// Blender's operator names, which its header shows.
        public var label: String {
            switch self {
            case .translate:   return "Move"
            case .rotate:      return "Rotate"
            case .scale:       return "Scale"
            case .trackball:   return "Trackball"
            case .edgeSlide:   return "Edge Slide"
            case .vertexSlide: return "Vertex Slide"
            }
        }

        /// X, Y and Z hold nothing here: Trackball and the slides set
        /// T_NO_CONSTRAINT.
        public var takesConstraint: Bool {
            switch self {
            case .translate, .rotate, .scale: return true
            case .trackball, .edgeSlide, .vertexSlide: return false
            }
        }
    }

    /// The orientation a constraint is in: the scene's, or the other one.
    public enum Space: Equatable, Sendable { case scene, alternate }

    public enum Constraint: Equatable, Sendable {
        case none
        /// Along axis 0, 1 or 2 of the space.
        case axis(Int, Space)
        /// In the plane across axis 0, 1 or 2 — named by its normal, as the
        /// gizmo's plane handles are.
        case plane(Int, Space)

        public var space: Space? {
            switch self {
            case .none: return nil
            case .axis(_, let s), .plane(_, let s): return s
            }
        }

        /// The letter that set it: X, Y or Z.
        public var letter: Int? {
            switch self {
            case .none: return nil
            case .axis(let i, _), .plane(let i, _): return i
            }
        }

        /// The axes it leaves free, in order.
        public var freeAxes: [Int] {
            switch self {
            case .none:              return [0, 1, 2]
            case .axis(let i, _):    return [i]
            case .plane(let i, _):   return (0..<3).filter { $0 != i }
            }
        }
    }

    public private(set) var mode: Mode
    public private(set) var constraint: Constraint = .none
    /// The text typed for each value; nil while the pointer decides.
    public private(set) var typed: [String]?
    /// The value Tab is on.
    public private(set) var component = 0
    /// Whether Tab has moved past the first value: until then a Scale's one
    /// number is every axis's.
    public private(set) var tabbed = false

    public init(mode: Mode) { self.mode = mode }

    // MARK: X, Y and Z

    /// X, Y or Z (`axis` 0, 1, 2), with Shift for the plane across it.
    public mutating func press(axis: Int, plane: Bool) {
        guard (0..<3).contains(axis), mode.takesConstraint else { return }
        // orient_curr: 0 none (O_DEFAULT), 1 the scene's, 2 the other.
        let current: Int
        switch constraint.space {
        case nil:          current = 0
        case .scene?:      current = 1
        case .alternate?:  current = 2
        }
        let next: Int
        if current == 0 || constraint.letter == axis {
            next = (current + 1) % 3
        } else {
            next = 1
        }
        switch next {
        case 0:  constraint = .none
        case 1:  constraint = plane ? .plane(axis, .scene) : .axis(axis, .scene)
        default: constraint = plane ? .plane(axis, .alternate) : .axis(axis, .alternate)
        }
        component = min(component, max(valueCount - 1, 0))
    }

    /// G, R or S during another: Blender puts the selection back and starts
    /// the new one (`restoreTransObjects`, then `transform_mode_init`), with
    /// no constraint and nothing typed.
    public mutating func switchMode(_ new: Mode) {
        mode = new
        constraint = .none
        typed = nil
        component = 0
        tabbed = false
    }

    // MARK: typed numbers

    /// How many values can be typed: one for a turn and for one axis, two
    /// for a plane, three for a move or a scale with no constraint.
    public var valueCount: Int {
        switch mode {
        case .rotate, .edgeSlide, .vertexSlide: return 1
        case .trackball: return 2
        case .translate, .scale: return constraint.freeAxes.count
        }
    }

    public var isTyping: Bool { typed != nil }

    /// A digit, a point or minus. Anything else is not Blender's number.
    public mutating func type(_ character: Character) {
        var texts = typed ?? Array(repeating: "", count: 3)
        var text = texts[component]
        switch character {
        case "0"..."9":
            text.append(character)
        case ".":
            guard !text.contains(".") else { return }
            text.append(character)
        case "-":
            // Blender's minus negates the value, wherever the caret is.
            if text.hasPrefix("-") { text.removeFirst() } else { text.insert("-", at: text.startIndex) }
        default:
            return
        }
        texts[component] = text
        typed = texts
    }

    public mutating func backspace() {
        guard var texts = typed else { return }
        if !texts[component].isEmpty { texts[component].removeLast() }
        // Every value empty: the pointer decides again.
        typed = texts.allSatisfy(\.isEmpty) ? nil : texts
        if typed == nil {
            component = 0
            tabbed = false
        }
    }

    /// Tab: the next value, round to the first.
    public mutating func nextValue() {
        guard valueCount > 1 else { return }
        if typed == nil { typed = Array(repeating: "", count: 3) }
        component = (component + 1) % valueCount
        tabbed = true
    }

    /// The typed values, one per `valueCount`: a value left empty is 0 for
    /// a move or a turn and 1 for a scale — except a Scale's first value,
    /// which is every value it acts on until Tab is used.
    public var values: [Double]? {
        guard let typed else { return nil }
        let empty: Double = mode == .scale ? 1 : 0
        let read = (0..<valueCount).map { i -> Double? in Self.number(typed[i]) }
        if mode == .scale, !tabbed, let first = read[0] {
            return Array(repeating: first, count: valueCount)
        }
        return read.map { $0 ?? empty }
    }

    /// A typed text as a number: "-" alone is minus nothing, ".5" a half.
    public static func number(_ text: String) -> Double? {
        let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
        guard !body.isEmpty, body != "." else { return text.hasPrefix("-") ? -0.0 : nil }
        guard let value = Double(body.hasPrefix(".") ? "0" + body : body) else { return nil }
        return text.hasPrefix("-") ? -value : value
    }

    /// What the header shows of the typed values: the one being typed in
    /// brackets with Blender's caret, the rest as typed or their default.
    public var shownValues: [String] {
        guard let typed else { return [] }
        let empty = mode == .scale ? "1" : "0"
        return (0..<valueCount).map { i in
            let text = typed[i]
            if i == component { return "[\(text)|]" }
            if mode == .scale, !tabbed, i > 0, !typed[0].isEmpty { return typed[0] }
            return text.isEmpty ? empty : text
        }
    }
}
