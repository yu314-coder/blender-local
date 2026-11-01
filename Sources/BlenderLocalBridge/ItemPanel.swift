import Foundation
import simd

/// The N panel's Item tab in a mesh's Edit Mode: Blender's Transform panel
/// (`v3d_editvertex_buts`), as `_blenderkit_item.state` reads it from the
/// edit mesh.
///
/// Its labels are Blender's, colons and all, and change with the count as
/// Blender's do: Vertex: or Median:, Vertex Data: or Vertices Data:, Bevel
/// Weight: or Mean Bevel Weight:, Edge Data: or Edges Data:, Crease: or Mean
/// Crease:.
public struct EditItemState: Equatable, Sendable {
    public var object: String
    /// Selected vertices (`tot`).
    public var vertices: Int
    /// Selected edges (`totedgedata`).
    public var edges: Int
    /// Global or Local, as asked.
    public var median: SIMD3<Float>?
    public var bevelWeightVertex: Float?
    public var creaseVertex: Float?
    public var bevelWeightEdge: Float?
    public var creaseEdge: Float?

    public init(object: String, vertices: Int, edges: Int, median: SIMD3<Float>? = nil,
                bevelWeightVertex: Float? = nil, creaseVertex: Float? = nil,
                bevelWeightEdge: Float? = nil, creaseEdge: Float? = nil) {
        self.object = object; self.vertices = vertices; self.edges = edges; self.median = median
        self.bevelWeightVertex = bevelWeightVertex; self.creaseVertex = creaseVertex
        self.bevelWeightEdge = bevelWeightEdge; self.creaseEdge = creaseEdge
    }

    /// `_blenderkit_item.state()`'s JSON; nil when no mesh is being edited.
    public static func parse(_ text: String) -> EditItemState? {
        guard let line = text.split(separator: "\n").last,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["mesh"] as? Bool == true, let name = object["object"] as? String,
              let tot = object["tot"] as? Int, let edges = object["edges"] as? Int else { return nil }
        func number(_ key: String) -> Float? { ItemBpy.float(object[key]) }
        var state = EditItemState(object: name, vertices: tot, edges: edges)
        if let m = object["median"] as? [Any], m.count == 3 {
            let axes = m.compactMap(ItemBpy.float)
            if axes.count == 3 { state.median = SIMD3(axes[0], axes[1], axes[2]) }
        }
        state.bevelWeightVertex = number("bevel_weight_vert")
        state.creaseVertex = number("crease_vert")
        state.bevelWeightEdge = number("bevel_weight_edge")
        state.creaseEdge = number("crease_edge")
        return state
    }

    /// Blender's heading over X, Y and Z.
    public var medianTitle: String { vertices == 1 ? "Vertex:" : "Median:" }
    public var vertexDataTitle: String { vertices == 1 ? "Vertex Data:" : "Vertices Data:" }
    public var edgeDataTitle: String { edges == 1 ? "Edge Data:" : "Edges Data:" }

    /// The Vertex Data and Edge Data rows, each with Blender's label, in
    /// Blender's order. Vertex Data whenever a vertex is selected; Edge Data
    /// whenever an edge is.
    public var dataRows: [(row: ItemDataRow, label: String, value: Float)] {
        var rows: [(ItemDataRow, String, Float)] = []
        if vertices > 0 {
            rows.append((.bevelWeightVertex, vertices == 1 ? "Bevel Weight:" : "Mean Bevel Weight:",
                         bevelWeightVertex ?? 0))
            rows.append((.creaseVertex, vertices == 1 ? "Vertex Crease:" : "Mean Vertex Crease:",
                         creaseVertex ?? 0))
        }
        if edges > 0 {
            rows.append((.bevelWeightEdge, edges == 1 ? "Bevel Weight:" : "Mean Bevel Weight:",
                         bevelWeightEdge ?? 0))
            rows.append((.creaseEdge, edges == 1 ? "Crease:" : "Mean Crease:", creaseEdge ?? 0))
        }
        return rows
    }
}

/// One of the four weight rows, by the attribute it writes.
public enum ItemDataRow: String, CaseIterable, Sendable {
    case bevelWeightVertex = "bevel_weight_vert"
    case creaseVertex = "crease_vert"
    case bevelWeightEdge = "bevel_weight_edge"
    case creaseEdge = "crease_edge"
}

/// The Python the Item tab's fields send.
public enum ItemBpy {
    private static let preamble = "import _blenderkit_item\n"

    /// What the tab reads in Edit Mode.
    public static func state(global: Bool) -> String {
        preamble + "print(_blenderkit_item.state(\(global ? "True" : "False")))"
    }

    /// The Median or Vertex X, Y or Z, typed.
    public static func setMedian(axis: Int, to value: Float, global: Bool) -> String {
        preamble + "_blenderkit_item.set_median(\(axis), \(number(value)), \(global ? "True" : "False"))"
    }

    /// A Vertex Data or Edge Data row, typed.
    public static func setData(_ row: ItemDataRow, to value: Float) -> String {
        preamble + "_blenderkit_item.set_data('\(row.rawValue)', \(number(value)))"
    }

    /// A typed number as the call carries it, six places. A field can be
    /// typed past Float's range ("1e39" reads as infinity), and `%f` would
    /// print `inf`, a name Python does not have; as `float('inf')` it reaches
    /// the module, which refuses it in words.
    static func number(_ value: Float) -> String {
        guard value.isFinite else { return value.isNaN ? "float('nan')" : value > 0 ? "float('inf')" : "float('-inf')" }
        return String(format: "%.6f", value)
    }

    /// The object's Dimensions as Blender reports them.
    public static func dimensions(of name: String) -> String {
        preamble + "print(_blenderkit_item.dimensions(\(Bpy.quote(name))))"
    }

    /// One Dimensions field, typed.
    public static func setDimension(of name: String, axis: Int, to value: Float) -> String {
        preamble + "_blenderkit_item.set_dimension(\(Bpy.quote(name)), \(axis), \(number(value)))"
    }

    /// The step an edit makes: the field's own words, as the names
    /// convention has it for a field of Blender's interface (Blender records
    /// the button's text and its new value, "X:1 m", which a bpy module cannot
    /// press). docs/blender-names.md. The Median's X:, Y: and Z: and the
    /// Dimensions' X:, Y: and Z: alike — they are the same buttons' words.
    public static func undoName(axis: Int) -> String { ["X", "Y", "Z"][min(max(axis, 0), 2)] }

    public static func undoName(_ label: String) -> String {
        label.hasSuffix(":") ? String(label.dropLast()) : label
    }

    /// `[x, y, z]` as `_blenderkit_item.dimensions` prints it; nil for its
    /// `null`, an object Blender's Item tab draws no Dimensions for.
    public static func parseDimensions(_ text: String) -> SIMD3<Float>? {
        guard let line = text.split(separator: "\n").last,
              let data = line.data(using: .utf8),
              let numbers = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any],
              numbers.count == 3 else { return nil }
        let axes = numbers.compactMap(float)
        return axes.count == 3 ? SIMD3(axes[0], axes[1], axes[2]) : nil
    }

    /// One number of `_blenderkit_item`'s JSON: a number, or a non-finite
    /// one as Blender prints it ('inf', '-inf', 'nan') — JSON has no word
    /// for those, and the panels show what Blender holds.
    static func float(_ any: Any?) -> Float? {
        if let n = any as? NSNumber { return n.floatValue }
        if let s = any as? String { return Float(s) }
        return nil
    }
}
