import Foundation
import simd

/// A material, holding the inputs Blender's Principled BSDF actually shades
/// with in a viewport preview.
///
/// Blender evaluates an arbitrary node graph; this carries the values that
/// graph would produce. That is the difference between "a material" and "a
/// shading system", and it is why the node editor here edits one node's inputs
/// rather than evaluating a tree.
public struct Material: Codable, Sendable {
    public var name: String = "Material"
    public var baseColor: SIMD4<Float> = SIMD4(0.8, 0.8, 0.8, 1)
    public var metallic: Float = 0
    public var roughness: Float = 0.5
    public var ior: Float = 1.45
    public var emission: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    public var emissionStrength: Float = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case name, baseColor, metallic, roughness, ior, emission, emissionStrength
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Material"
        let base = try c.decodeIfPresent([Float].self, forKey: .baseColor) ?? [0.8, 0.8, 0.8, 1]
        baseColor = SIMD4(base[0], base[1], base[2], base.count > 3 ? base[3] : 1)
        metallic = try c.decodeIfPresent(Float.self, forKey: .metallic) ?? 0
        roughness = try c.decodeIfPresent(Float.self, forKey: .roughness) ?? 0.5
        ior = try c.decodeIfPresent(Float.self, forKey: .ior) ?? 1.45
        let em = try c.decodeIfPresent([Float].self, forKey: .emission) ?? [0, 0, 0, 1]
        emission = SIMD4(em[0], em[1], em[2], em.count > 3 ? em[3] : 1)
        emissionStrength = try c.decodeIfPresent(Float.self, forKey: .emissionStrength) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode([baseColor.x, baseColor.y, baseColor.z, baseColor.w], forKey: .baseColor)
        try c.encode(metallic, forKey: .metallic)
        try c.encode(roughness, forKey: .roughness)
        try c.encode(ior, forKey: .ior)
        try c.encode([emission.x, emission.y, emission.z, emission.w], forKey: .emission)
        try c.encode(emissionStrength, forKey: .emissionStrength)
    }
}

/// The nodes the shader editor shows. Blender ships well over a hundred; these
/// are the two every material starts with, plus the two simplest inputs.
public enum ShaderNodeKind: String, Codable, CaseIterable, Sendable {
    case principledBSDF, materialOutput, rgb, value

    public var label: String {
        switch self {
        case .principledBSDF: return "Principled BSDF"
        case .materialOutput: return "Material Output"
        case .rgb:            return "RGB"
        case .value:          return "Value"
        }
    }

    /// Blender colours node headers by category: shaders green, output dark,
    /// inputs grey-blue.
    public var headerHex: UInt32 {
        switch self {
        case .principledBSDF: return 0x3C6E3C
        case .materialOutput: return 0x4B3450
        case .rgb, .value:    return 0x3B4A5A
        }
    }

    public var inputs: [String] {
        switch self {
        case .principledBSDF: return ["Base Color", "Metallic", "Roughness", "IOR",
                                      "Emission Color", "Emission Strength"]
        case .materialOutput: return ["Surface", "Volume", "Displacement"]
        case .rgb, .value:    return []
        }
    }

    public var outputs: [String] {
        switch self {
        case .principledBSDF: return ["BSDF"]
        case .materialOutput: return []
        case .rgb:            return ["Color"]
        case .value:          return ["Value"]
        }
    }
}

public struct ShaderNode: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var kind: ShaderNodeKind
    /// Position in the node editor's own coordinate space.
    public var x: Float
    public var y: Float

    public init(kind: ShaderNodeKind, x: Float, y: Float) {
        self.kind = kind; self.x = x; self.y = y
    }
}

public struct ShaderLink: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var from: UUID
    public var fromSocket: String
    public var to: UUID
    public var toSocket: String
}

/// A material's node graph. Every new material starts the way Blender's does:
/// a Principled BSDF wired into a Material Output.
public struct ShaderGraph: Codable, Sendable {
    public var nodes: [ShaderNode]
    public var links: [ShaderLink]

    public init() {
        let bsdf = ShaderNode(kind: .principledBSDF, x: 40, y: 60)
        let output = ShaderNode(kind: .materialOutput, x: 340, y: 110)
        nodes = [bsdf, output]
        links = [ShaderLink(from: bsdf.id, fromSocket: "BSDF",
                            to: output.id, toSocket: "Surface")]
    }

    public var principled: ShaderNode? { nodes.first { $0.kind == .principledBSDF } }
    public var output: ShaderNode? { nodes.first { $0.kind == .materialOutput } }

    /// True when the BSDF actually reaches the output — an unconnected graph
    /// renders black in Blender, and should here too.
    public var isConnected: Bool {
        guard let bsdf = principled, let out = output else { return false }
        return links.contains { $0.from == bsdf.id && $0.to == out.id }
    }
}
