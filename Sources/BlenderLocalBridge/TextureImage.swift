import Foundation
import simd

/// An RGBA8 image, used both as a paintable texture and as a render result.
///
/// Blender's `bpy.types.Image` is backed by an ImBuf with float and byte
/// variants, colour management and tiles. This is the byte buffer, which is
/// what painting and displaying actually need.
public final class TextureImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes per pixel.
    public private(set) var pixels: [UInt8]
    public var name: String
    /// Bumped on every change, so the renderer knows to re-upload.
    public private(set) var version: Int = 0

    // MARK: Texture Paint

    /// How Blender stores the image this buffer mirrors, so a stroke goes back
    /// in the layout it came from: `Image.channels` values per pixel, either
    /// scene-linear floats or bytes over 255.
    public var channels = 4
    public var isFloat = false
    /// A float image's own values, which Texture Paint paints: RGBA per texel,
    /// top row first like `pixels`, scene-linear and premultiplied as Blender's
    /// float buffer holds them. `pixels` is then only their display copy. Nil
    /// for a byte image.
    public var floats: [Float]?

    /// What changed in each recent version, so the GPU copy can take just the
    /// rectangle a dab covered rather than the whole image every frame.
    private var changes: [(version: Int, x0: Int, y0: Int, x1: Int, y1: Int)] = []

    /// An image made from pixels that already exist — Blender's, arriving
    /// through the mirror — without filling it first.
    public init(width: Int, height: Int, name: String, pixels: [UInt8]) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.name = name
        let count = self.width * self.height * 4
        self.pixels = pixels.count == count ? pixels : [UInt8](repeating: 255, count: count)
    }

    /// The bytes, for the paint engine to write in place.
    public func withMutablePixels<R>(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try pixels.withUnsafeMutableBufferPointer { try body($0) }
    }

    /// Records a change to columns `x0...x1` of rows `y0...y1`, rows counted
    /// from the top as `pixels` stores them.
    public func noteChanged(x0: Int, y0: Int, x1: Int, y1: Int) {
        version &+= 1
        changes.append((version, max(0, x0), max(0, y0), min(width - 1, x1), min(height - 1, y1)))
        if changes.count > 64 { changes.removeFirst(changes.count - 64) }
    }

    /// The rectangle that changed since `old`, as (x, y, width, height) from
    /// the top-left; zero-sized when nothing did. Nil when only a full copy
    /// will do: something changed the image without saying where, or the log
    /// no longer reaches back that far.
    public func changedRect(since old: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        if old == version { return (0, 0, 0, 0) }
        let recent = changes.filter { $0.version > old }
        guard old < version, recent.count == version - old, let first = recent.first else { return nil }
        var x0 = first.x0, y0 = first.y0, x1 = first.x1, y1 = first.y1
        for change in recent.dropFirst() {
            x0 = min(x0, change.x0); y0 = min(y0, change.y0)
            x1 = max(x1, change.x1); y1 = max(y1, change.y1)
        }
        return (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    /// A float image's values, for the paint engine to write in place. Empty
    /// for a byte image.
    public func withMutableFloats<R>(_ body: (UnsafeMutableBufferPointer<Float>) throws -> R) rethrows -> R {
        if floats == nil { return try body(UnsafeMutableBufferPointer(start: nil, count: 0)) }
        return try floats!.withUnsafeMutableBufferPointer { try body($0) }
    }

    public init(width: Int = 1024, height: Int = 1024,
                name: String = "Untitled",
                fill: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.name = name
        let count = self.width * self.height * 4
        pixels = [UInt8](repeating: 0, count: count)
        self.fill(with: fill)
    }

    public func fill(with colour: SIMD4<Float>) {
        let r = UInt8(max(0, min(colour.x, 1)) * 255)
        let g = UInt8(max(0, min(colour.y, 1)) * 255)
        let b = UInt8(max(0, min(colour.z, 1)) * 255)
        let a = UInt8(max(0, min(colour.w, 1)) * 255)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = a
        }
        version &+= 1
    }

    /// Blender's default new-image checker, so an unpainted texture is
    /// obviously a texture rather than a blank.
    public func fillChecker(squares: Int = 16) {
        let cell = max(1, width / squares)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let v: UInt8 = on ? 0xC0 : 0x60
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 255
            }
        }
        version &+= 1
    }

    /// One brush dab in UV space, with a soft edge.
    ///
    /// Blender projects the brush through the view onto the surface; this is
    /// handed the UV the ray already hit, so the stamp is round in UV space
    /// rather than in screen space. On a stretched unwrap that reads as a
    /// distorted dab — which is exactly what a stretched unwrap does.
    public func paint(at uv: SIMD2<Float>, radius: Float,
                      colour: SIMD4<Float>, strength: Float) {
        let cx = uv.x * Float(width)
        let cy = (1 - uv.y) * Float(height)     // image rows run top-down
        let r = max(radius * Float(min(width, height)), 1)
        let r2 = r * r

        let minX = max(0, Int(cx - r)), maxX = min(width - 1, Int(cx + r))
        let minY = max(0, Int(cy - r)), maxY = min(height - 1, Int(cy + r))
        guard minX <= maxX, minY <= maxY else { return }

        let src = SIMD3(colour.x, colour.y, colour.z)
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Float(x) - cx, dy = Float(y) - cy
                let d2 = dx * dx + dy * dy
                guard d2 <= r2 else { continue }
                // Smoothstep falloff, matching the sculpt brush's edge.
                let t = sqrt(d2) / r
                let w = (1 - (t * t * (3 - 2 * t))) * strength
                guard w > 0.001 else { continue }

                let i = (y * width + x) * 4
                for c in 0..<3 {
                    let existing = Float(pixels[i + c]) / 255
                    let mixed = existing + (src[c] - existing) * w
                    pixels[i + c] = UInt8(max(0, min(mixed, 1)) * 255)
                }
                pixels[i + 3] = 255
            }
        }
        version &+= 1
    }

    /// Replaces the buffer wholesale — how a render result arrives.
    public func replace(with bytes: [UInt8]) {
        guard bytes.count == pixels.count else { return }
        pixels = bytes
        version &+= 1
    }
}

/// Texture-paint settings, mirroring Blender's brush header.
public struct PaintSettings: Sendable {
    public var colour: SIMD4<Float> = SIMD4(0.85, 0.2, 0.15, 1)
    /// Fraction of the texture's smaller side.
    public var radius: Float = 0.04
    public var strength: Float = 0.8
    /// Weight-paint value, Blender's brush weight. 1.0 is full red.
    public var weight: Float = 1.0
    /// Blender's brush blend mode.
    public var blend: BrushBlend = .mix
    /// Blender's brush falloff curve.
    public var falloff: BrushFalloff = .smooth
    /// Texture Paint's brushes, with Blender's unified size and colour. Kept
    /// apart from the fields above, which vertex and weight paint read.
    public var texturePaint = TexturePaintSettings()
    public init() {}
}


/// Blender's weight-paint gradient: blue at 0, through green at 0.5, to red at
/// 1 — the ramp every rigger reads by eye.
///
/// Kept here rather than in the renderer because it is pure data, and because
/// anything inside the Metal layer cannot be exercised without a GPU.
public enum WeightRamp {
    private static let stops: [(Float, SIMD3<Float>)] = [
        (0.00, SIMD3(0.0, 0.0, 1.0)),
        (0.25, SIMD3(0.0, 1.0, 1.0)),
        (0.50, SIMD3(0.0, 1.0, 0.0)),
        (0.75, SIMD3(1.0, 1.0, 0.0)),
        (1.00, SIMD3(1.0, 0.0, 0.0)),
    ]

    public static func colour(_ weight: Float) -> SIMD4<Float> {
        let t = max(0, min(1, weight))
        for i in 0..<(stops.count - 1) where t <= stops[i + 1].0 {
            let (a, ca) = stops[i], (b, cb) = stops[i + 1]
            let f = b > a ? (t - a) / (b - a) : 0
            let c = ca + (cb - ca) * f
            return SIMD4(c.x, c.y, c.z, 1)
        }
        return SIMD4(1, 0, 0, 1)
    }
}


/// Blender's brush blend modes, the subset that means something for a colour
/// brush without a full compositing stack behind it.
public enum BrushBlend: String, CaseIterable, Identifiable, Sendable {
    case mix, add, subtract, multiply, lighten, darken

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    /// The string `brush.blend` takes.
    public var bpyValue: String { rawValue.uppercased() }

    /// Applies the mode to one channel triple. Alpha is carried, not blended:
    /// a brush changes colour, not coverage.
    public func apply(_ base: SIMD4<Float>, _ brush: SIMD4<Float>, _ amount: Float) -> SIMD4<Float> {
        let a = SIMD3(base.x, base.y, base.z)
        let b = SIMD3(brush.x, brush.y, brush.z)
        let mixed: SIMD3<Float>
        switch self {
        case .mix:      mixed = b
        case .add:      mixed = a + b
        case .subtract: mixed = a - b
        case .multiply: mixed = a * b
        case .lighten:  mixed = SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))
        case .darken:   mixed = SIMD3(min(a.x, b.x), min(a.y, b.y), min(a.z, b.z))
        }
        let out = a + (mixed - a) * amount
        return SIMD4(max(0, min(1, out.x)), max(0, min(1, out.y)), max(0, min(1, out.z)), base.w)
    }
}

/// Blender's brush falloff curves, from the Falloff popover.
public enum BrushFalloff: String, CaseIterable, Identifiable, Sendable {
    case smooth, sphere, root, sharp, linear, constant

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// Weight for a normalised distance in 0…1: 1 at the centre, 0 at the rim.
    public func weight(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        switch self {
        case .smooth:   return 1 - (x * x * (3 - 2 * x))
        case .sphere:   return sqrt(max(0, 1 - x * x))
        // Blender's BRUSH_CURVE_ROOT is `sqrtf(p)` with p = 1 - d/r. This was
        // `1 - sqrt(x)`, a different curve under the same name.
        case .root:     return sqrt(1 - x)
        case .sharp:    return (1 - x) * (1 - x)
        case .linear:   return 1 - x
        case .constant: return 1
        }
    }
}
