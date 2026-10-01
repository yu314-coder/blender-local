import Foundation

/// What a click does to the existing selection — Blender's `mode` argument to
/// `view3d.select` and `mesh.select`, and the five buttons at the left of the
/// tool-settings row.
///
/// These are set operations, which is why they can be written once and used for
/// objects and for mesh components alike.
public enum SelectAction: String, CaseIterable, Identifiable, Sendable {
    case set, extend, subtract, difference, intersect

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .set:        return "Set"
        case .extend:     return "Extend"
        case .subtract:   return "Subtract"
        case .difference: return "Difference"
        case .intersect:  return "Intersect"
        }
    }

    /// The value `bpy.ops.view3d.select(mode=…)` takes. Blender spells the last
    /// two after the set operations rather than the button labels.
    public var bpyValue: String {
        switch self {
        case .set:        return "SET"
        case .extend:     return "EXTEND"
        case .subtract:   return "SUBTRACT"
        case .difference: return "XOR"
        case .intersect:  return "AND"
        }
    }

    public var icon: String {
        switch self {
        case .set:        return "square.dashed"
        case .extend:     return "plus.square.dashed"
        case .subtract:   return "minus.square.dashed"
        case .difference: return "square.dashed.inset.filled"
        case .intersect:  return "square.on.square.dashed"
        }
    }

    /// Combines what was already selected with what was just clicked.
    ///
    /// An empty `hit` means the click landed on nothing. Blender clears the
    /// selection in that case only for Set — the other four leave it alone,
    /// because subtracting or intersecting with nothing is not a request to
    /// throw the selection away.
    public func apply<T: Hashable>(_ current: Set<T>, hit: Set<T>) -> Set<T> {
        guard !hit.isEmpty else { return self == .set ? [] : current }
        switch self {
        case .set:        return hit
        case .extend:     return current.union(hit)
        case .subtract:   return current.subtracting(hit)
        case .difference: return current.symmetricDifference(hit)
        case .intersect:  return current.intersection(hit)
        }
    }
}
