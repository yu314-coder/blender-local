import Foundation
import simd

/// Blender's geometry nodes, reduced to the ones that are a direct operation on
/// a triangle mesh.
///
/// Blender's system is a general field evaluator: nodes carry typed sockets,
/// fields evaluate per element, and geometry flows as instances and components.
/// This evaluates a straight chain of mesh operations. That covers the shape of
/// a simple modifier graph and none of the field logic — no attribute
/// capture, no per-point fields, no instancing.
public enum GeometryNodeKind: String, Codable, CaseIterable, Sendable {
    case groupInput, groupOutput
    case subdivide, transform, setPosition, scaleElements, extrude, triangulate

    public var label: String {
        switch self {
        case .groupInput:    return "Group Input"
        case .groupOutput:   return "Group Output"
        case .subdivide:     return "Subdivision Surface"
        case .transform:     return "Transform Geometry"
        case .setPosition:   return "Set Position"
        case .scaleElements: return "Scale Elements"
        case .extrude:       return "Extrude Mesh"
        case .triangulate:   return "Triangulate"
        }
    }

    /// Blender colours geometry node headers green, inputs and outputs dark.
    public var headerHex: UInt32 {
        switch self {
        case .groupInput, .groupOutput: return 0x4B3450
        default: return 0x3C6E5E
        }
    }

    public var parameters: [(name: String, range: ClosedRange<Float>, initial: Float)] {
        switch self {
        case .subdivide:     return [("Level", 0...3, 1)]
        case .transform:     return [("Translate Z", -3...3, 0), ("Rotate Z", -3.2...3.2, 0),
                                     ("Scale", 0.1...3, 1)]
        case .setPosition:   return [("Offset", -1...1, 0.15)]
        case .scaleElements: return [("Scale", 0.1...3, 1)]
        case .extrude:       return [("Offset", -1...1, 0.2)]
        case .groupInput, .groupOutput, .triangulate: return []
        }
    }
}

public struct GeometryNode: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var kind: GeometryNodeKind
    public var x: Float
    public var y: Float
    public var values: [String: Float] = [:]
    public var enabled = true

    public init(kind: GeometryNodeKind, x: Float, y: Float) {
        self.kind = kind; self.x = x; self.y = y
        for p in kind.parameters { values[p.name] = p.initial }
    }

    public func value(_ name: String) -> Float {
        values[name] ?? kind.parameters.first { $0.name == name }?.initial ?? 0
    }
}

/// A geometry node tree: a chain from Group Input to Group Output, which is
/// what Blender's new node group starts as.
public struct GeometryNodeTree: Codable, Sendable {
    public var nodes: [GeometryNode]
    /// Blender's modifier is off until a tree is assigned; this mirrors that.
    public var enabled = false

    public init() {
        nodes = [GeometryNode(kind: .groupInput, x: 20, y: 40),
                 GeometryNode(kind: .groupOutput, x: 420, y: 40)]
    }

    public mutating func insert(_ kind: GeometryNodeKind) {
        let index = max(1, nodes.count - 1)
        nodes.insert(GeometryNode(kind: kind, x: 0, y: 40), at: index)
        relayout()
        enabled = true
    }

    public mutating func remove(_ id: UUID) {
        guard let node = nodes.first(where: { $0.id == id }),
              node.kind != .groupInput, node.kind != .groupOutput else { return }
        nodes.removeAll { $0.id == id }
        relayout()
    }

    private mutating func relayout() {
        for (i, _) in nodes.enumerated() {
            nodes[i].x = 20 + Float(i) * 200
            nodes[i].y = 40
        }
    }

    /// True when there is something between input and output to evaluate.
    public var hasOperations: Bool { nodes.count > 2 }
}

/// Evaluates a geometry node tree over a mesh.
public enum GeometryNodeEvaluator {

    public static func evaluate(_ tree: GeometryNodeTree, on mesh: MeshData) -> MeshData {
        guard tree.enabled, tree.hasOperations else { return mesh }
        var current = mesh

        for node in tree.nodes where node.enabled {
            switch node.kind {
            case .groupInput, .groupOutput:
                continue

            case .subdivide:
                current = ModifierStack.subdivide(current, levels: Int(node.value("Level")))

            case .transform:
                // Blender's Transform Geometry moves the geometry itself, not
                // the object — so the object's own transform is untouched.
                let tz = node.value("Translate Z")
                let rz = node.value("Rotate Z")
                let s  = node.value("Scale")
                let m = simd_float4x4(translation: SIMD3(0, 0, tz))
                      * simd_float4x4(eulerXYZ: SIMD3(0, 0, rz))
                      * simd_float4x4(scale: SIMD3(repeating: s))
                let normalMatrix = m.inverse.transpose
                for i in current.vertices.indices {
                    current.vertices[i].position = (m * SIMD4(current.vertices[i].position, 1)).xyz
                    current.vertices[i].normal = normalize(
                        (normalMatrix * SIMD4(current.vertices[i].normal, 0)).xyz)
                }

            case .setPosition:
                // With no field input, Blender's Set Position needs an offset;
                // along the normal is the useful default here.
                current = ModifierStack.displace(current, strength: node.value("Offset"))

            case .scaleElements:
                current = ModifierStack.cast(current, factor: 0)   // no-op guard
                let s = node.value("Scale")
                for i in current.vertices.indices {
                    current.vertices[i].position *= s
                }
                ModifierStack.recomputeNormals(&current, welded: true)

            case .extrude:
                // Every face, since there is no selection field to narrow it.
                let faces = Set(0..<(current.indices.count / 3))
                let (out, _) = MeshEditor.extrude(current, faces: faces,
                                                  distance: node.value("Offset"))
                current = out

            case .triangulate:
                continue   // already triangles, as in Blender on a tri mesh
            }
        }
        return current
    }
}
