import Foundation
import simd

/// Blender's compositor, reduced to the image operations that run on a render
/// result without a tiled, multi-pass evaluator behind them.
///
/// Blender composites in float, over render passes, with a scheduler that
/// evaluates tiles in parallel. This works on the single RGBA8 buffer the
/// renderer produces — which is enough for a real chain of colour and filter
/// nodes, and not enough for passes, masks or multi-layer EXR.
public enum CompositorNodeKind: String, Codable, CaseIterable, Sendable {
    case renderLayers, composite, brightContrast, hueSaturation, blur, invert, glare, mix

    public var label: String {
        switch self {
        case .renderLayers:   return "Render Layers"
        case .composite:      return "Composite"
        case .brightContrast: return "Bright/Contrast"
        case .hueSaturation:  return "Hue/Saturation"
        case .blur:           return "Blur"
        case .invert:         return "Invert"
        case .glare:          return "Glare"
        case .mix:            return "Mix"
        }
    }

    /// Blender colours compositor node headers by category.
    public var headerHex: UInt32 {
        switch self {
        case .renderLayers, .composite: return 0x4B3450
        case .brightContrast, .hueSaturation, .invert, .mix: return 0x6E5E3C
        case .blur, .glare: return 0x3C5E6E
        }
    }

    /// Whether the node takes a value the editor should expose.
    public var parameters: [(name: String, range: ClosedRange<Float>, initial: Float)] {
        switch self {
        case .brightContrast: return [("Bright", -0.5...0.5, 0), ("Contrast", -1...1, 0)]
        case .hueSaturation:  return [("Hue", 0...1, 0.5), ("Saturation", 0...2, 1),
                                      ("Value", 0...2, 1)]
        case .blur:           return [("Size", 0...24, 6)]
        case .glare:          return [("Threshold", 0...1, 0.7), ("Mix", 0...1, 0.5)]
        case .mix:            return [("Fac", 0...1, 0.5)]
        case .invert:         return [("Fac", 0...1, 1)]
        case .renderLayers, .composite: return []
        }
    }
}

public struct CompositorNode: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var kind: CompositorNodeKind
    public var x: Float
    public var y: Float
    /// Values by parameter name, seeded from the kind's defaults.
    public var values: [String: Float] = [:]
    public var enabled: Bool = true

    public init(kind: CompositorNodeKind, x: Float, y: Float) {
        self.kind = kind; self.x = x; self.y = y
        for p in kind.parameters { values[p.name] = p.initial }
    }

    public func value(_ name: String) -> Float {
        values[name] ?? kind.parameters.first { $0.name == name }?.initial ?? 0
    }
}

/// The compositor graph: a straight chain from Render Layers to Composite,
/// which is what Blender's default graph is and what evaluating in order needs.
public struct CompositorGraph: Codable, Sendable {
    public var nodes: [CompositorNode]

    public init() {
        nodes = [CompositorNode(kind: .renderLayers, x: 20, y: 40),
                 CompositorNode(kind: .composite, x: 520, y: 40)]
    }

    /// Insert before the Composite node, so the chain stays in order.
    public mutating func insert(_ kind: CompositorNodeKind) {
        let index = max(1, nodes.count - 1)
        var node = CompositorNode(kind: kind, x: 0, y: 0)
        node.x = 20 + Float(index) * 190
        node.y = 40
        nodes.insert(node, at: index)
        // Re-lay the chain so it reads left to right.
        for (i, _) in nodes.enumerated() {
            nodes[i].x = 20 + Float(i) * 190
            nodes[i].y = 40
        }
    }

    public mutating func remove(_ id: UUID) {
        guard let node = nodes.first(where: { $0.id == id }),
              node.kind != .renderLayers, node.kind != .composite else { return }
        nodes.removeAll { $0.id == id }
        for (i, _) in nodes.enumerated() { nodes[i].x = 20 + Float(i) * 190 }
    }
}

/// Runs a compositor graph over an image.
public enum Compositor {

    public static func evaluate(_ graph: CompositorGraph, on source: TextureImage) -> TextureImage {
        let out = TextureImage(width: source.width, height: source.height,
                               name: "Composite")
        var pixels = source.pixels

        for node in graph.nodes where node.enabled {
            switch node.kind {
            case .renderLayers, .composite:
                continue
            case .brightContrast:
                brightContrast(&pixels, bright: node.value("Bright"),
                               contrast: node.value("Contrast"))
            case .hueSaturation:
                hueSaturation(&pixels, hue: node.value("Hue"),
                              saturation: node.value("Saturation"),
                              value: node.value("Value"))
            case .invert:
                invert(&pixels, factor: node.value("Fac"))
            case .blur:
                pixels = blur(pixels, width: source.width, height: source.height,
                              radius: Int(node.value("Size")))
            case .glare:
                pixels = glare(pixels, width: source.width, height: source.height,
                               threshold: node.value("Threshold"), mix: node.value("Mix"))
            case .mix:
                // Blender's Mix with no second input mixes toward grey.
                mixToward(&pixels, target: 128, factor: node.value("Fac"))
            }
        }
        out.replace(with: pixels)
        return out
    }

    // MARK: operations

    private static func brightContrast(_ px: inout [UInt8], bright: Float, contrast: Float) {
        // Blender's formula: contrast pivots around mid-grey, then brightness
        // shifts. Doing it the other way round changes the result.
        let c = 1 + contrast
        for i in stride(from: 0, to: px.count, by: 4) {
            for k in 0..<3 {
                var v = Float(px[i + k]) / 255
                v = (v - 0.5) * c + 0.5 + bright
                px[i + k] = UInt8(max(0, min(v, 1)) * 255)
            }
        }
    }

    private static func hueSaturation(_ px: inout [UInt8], hue: Float,
                                      saturation: Float, value: Float) {
        for i in stride(from: 0, to: px.count, by: 4) {
            var (h, s, v) = rgbToHSV(Float(px[i]) / 255,
                                     Float(px[i + 1]) / 255,
                                     Float(px[i + 2]) / 255)
            // Blender's Hue input is an offset around 0.5, not an absolute hue.
            h = (h + (hue - 0.5)).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            s = max(0, min(s * saturation, 1))
            v = max(0, min(v * value, 1))
            let (r, g, b) = hsvToRGB(h, s, v)
            px[i] = UInt8(r * 255); px[i + 1] = UInt8(g * 255); px[i + 2] = UInt8(b * 255)
        }
    }

    private static func invert(_ px: inout [UInt8], factor: Float) {
        for i in stride(from: 0, to: px.count, by: 4) {
            for k in 0..<3 {
                let v = Float(px[i + k]) / 255
                px[i + k] = UInt8(max(0, min(v + (1 - v - v) * factor, 1)) * 255)
            }
        }
    }

    private static func mixToward(_ px: inout [UInt8], target: UInt8, factor: Float) {
        for i in stride(from: 0, to: px.count, by: 4) {
            for k in 0..<3 {
                let v = Float(px[i + k]), t = Float(target)
                px[i + k] = UInt8(max(0, min(v + (t - v) * factor, 255)))
            }
        }
    }

    /// Separable box blur, run twice — two box passes approximate a gaussian
    /// closely enough for a preview and stay linear in the radius.
    private static func blur(_ px: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return px }
        var a = px, b = px
        for _ in 0..<2 {
            boxPass(a, into: &b, width: width, height: height, radius: radius, horizontal: true)
            boxPass(b, into: &a, width: width, height: height, radius: radius, horizontal: false)
        }
        return a
    }

    private static func boxPass(_ src: [UInt8], into dst: inout [UInt8],
                                width: Int, height: Int, radius: Int, horizontal: Bool) {
        let outer = horizontal ? height : width
        let inner = horizontal ? width : height
        for o in 0..<outer {
            for i in 0..<inner {
                var sum = SIMD3<Int>(0, 0, 0)
                var count = 0
                for k in -radius...radius {
                    let j = i + k
                    guard j >= 0, j < inner else { continue }
                    let idx = horizontal ? (o * width + j) * 4 : (j * width + o) * 4
                    sum &+= SIMD3(Int(src[idx]), Int(src[idx + 1]), Int(src[idx + 2]))
                    count += 1
                }
                let idx = horizontal ? (o * width + i) * 4 : (i * width + o) * 4
                dst[idx]     = UInt8(sum.x / max(count, 1))
                dst[idx + 1] = UInt8(sum.y / max(count, 1))
                dst[idx + 2] = UInt8(sum.z / max(count, 1))
                dst[idx + 3] = src[idx + 3]
            }
        }
    }

    /// Blender's Glare, Fog Glow style: isolate the bright pixels, blur them,
    /// add back.
    private static func glare(_ px: [UInt8], width: Int, height: Int,
                              threshold: Float, mix: Float) -> [UInt8] {
        var bright = [UInt8](repeating: 0, count: px.count)
        let cut = threshold * 255
        for i in stride(from: 0, to: px.count, by: 4) {
            let luma = 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2])
            let keep = luma > cut
            for k in 0..<3 { bright[i + k] = keep ? px[i + k] : 0 }
            bright[i + 3] = 255
        }
        let bloom = blur(bright, width: width, height: height, radius: 12)

        var out = px
        for i in stride(from: 0, to: px.count, by: 4) {
            for k in 0..<3 {
                let v = Float(out[i + k]) + Float(bloom[i + k]) * mix
                out[i + k] = UInt8(max(0, min(v, 255)))
            }
        }
        return out
    }

    // MARK: colour space

    private static func rgbToHSV(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == r      { h = (g - b) / d / 6 }
            else if mx == g { h = (2 + (b - r) / d) / 6 }
            else            { h = (4 + (r - g) / d) / 6 }
            if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    private static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        guard s > 1e-6 else { return (v, v, v) }
        let i = Int(h * 6) % 6
        let f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
