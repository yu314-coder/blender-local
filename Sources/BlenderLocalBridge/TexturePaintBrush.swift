import Foundation
import simd

// Texture Paint's brushes, and the byte arithmetic Blender paints with.
//
// Everything here is plain Swift over plain values, so it runs on the Mac:
// tests/texpaint/main.swift checks it, and tests/texpaint/blender/verify.py
// holds the brush settings and falloff tables against Blender 5.2.1 itself.

// MARK: - Tools

/// What a texture-paint stroke does to the texels under the brush.
///
/// Blender 5.2's brushes are assets, and a brush's type decides what a dab
/// does. Each tool starts from the Blender 5.2.1 essentials brush of that type,
/// read out of `datafiles/assets/brushes/essentials_brushes-mesh_texture.blend`:
///
///     tool     brush       type     strength  spacing  falloff  pressure
///     Draw     Paint Hard  DRAW     1.0       10 %     custom   —
///     Blur     Blur        SOFTEN   1.0       10 %     smooth   strength
///     Smear    Smear       SMEAR    0.6        5 %     smooth   strength
///
/// Those are all the types Blender's Texture Paint paints with that this app
/// has: `image_brush_type` is DRAW, SOFTEN, SMEAR, CLONE, FILL or MASK, and its
/// toolbar is Paint, Blur, Smear, Clone, Fill and Mask. There is no Average —
/// that is a vertex- and weight-paint brush — so Texture Paint has none either.
public enum TexturePaintTool: String, CaseIterable, Identifiable, Sendable {
    case draw, soften, smear

    public var id: String { rawValue }

    /// The essentials brush asset the tool's settings come from.
    public var blenderBrush: String {
        switch self {
        case .draw:    return "Paint Hard"
        case .soften:  return "Blur"
        case .smear:   return "Smear"
        }
    }

    /// `Brush.image_brush_type`.
    public var blenderType: String {
        switch self {
        case .draw:    return "DRAW"
        case .soften:  return "SOFTEN"
        case .smear:   return "SMEAR"
        }
    }
}

public extension ActiveTool {
    /// The brush a toolbar paint tool paints with in Texture Paint.
    var texturePaintTool: TexturePaintTool? {
        switch self {
        case .paintDraw:    return .draw
        case .paintBlur:    return .soften
        case .paintSmear:   return .smear
        default:            return nil
        }
    }
}

// MARK: - Falloff

/// How strength fades from the centre of the brush to its rim.
public enum TexturePaintFalloff: Equatable, Sendable {
    /// One of Blender's analytic curve presets.
    case preset(BrushFalloff)
    /// A custom curve, as the 257-entry table Blender evaluates it through.
    case curve([Float])

    /// `BKE_brush_curve_strength_clamped`: the strength at `distance` from the
    /// centre, zero at the radius and beyond.
    public func strength(distance: Float, radius: Float) -> Float {
        guard radius > 0, distance < radius else { return 0 }
        let t = distance / radius
        let value: Float
        switch self {
        case .preset(let falloff):
            value = falloff.weight(t)
        case .curve(let table):
            // BKE_curvemap_evaluateF: linear between table entries.
            guard table.count > 1 else { return 0 }
            let position = t * Float(table.count - 1)
            let i = min(Int(position), table.count - 2)
            let f = position - Float(i)
            value = (1 - f) * table[i] + f * table[i + 1]
        }
        return max(0, min(1, value))
    }

    public var label: String {
        switch self {
        case .preset(let falloff): return falloff.label
        case .curve:               return "Custom"
        }
    }

    /// `Brush.curve_distance_falloff_preset`.
    public var blenderPreset: String {
        switch self {
        case .preset(let falloff): return falloff.blenderPreset
        case .curve:               return "CUSTOM"
        }
    }
}

public extension BrushFalloff {
    /// `Brush.curve_distance_falloff_preset`.
    var blenderPreset: String {
        switch self {
        case .smooth:   return "SMOOTH"
        case .sphere:   return "SPHERE"
        case .root:     return "ROOT"
        case .sharp:    return "SHARP"
        case .linear:   return "LIN"
        case .constant: return "CONSTANT"
        }
    }
}

public extension BrushBlend {
    /// `Brush.blend`. Not `bpyValue`, which spells SUB and MUL out in full.
    var blenderBlend: String {
        switch self {
        case .mix:      return "MIX"
        case .add:      return "ADD"
        case .subtract: return "SUB"
        case .multiply: return "MUL"
        case .lighten:  return "LIGHTEN"
        case .darken:   return "DARKEN"
        }
    }
}

// MARK: - Brush and settings

/// One brush's own settings — what Blender keeps on the brush rather than in
/// the unified paint settings.
public struct TexturePaintBrush: Equatable, Sendable {
    public var tool: TexturePaintTool
    /// `Brush.strength`.
    public var strength: Float
    /// `Brush.spacing`: the distance between dabs, as a percentage of the
    /// brush diameter.
    public var spacing: Float
    public var falloff: TexturePaintFalloff
    /// `Brush.blend`. Only Draw blends; the other tools move existing colour.
    public var blend: BrushBlend
    public var usePressureSize: Bool
    public var usePressureStrength: Bool

    public init(tool: TexturePaintTool, strength: Float, spacing: Float,
                falloff: TexturePaintFalloff, blend: BrushBlend = .mix,
                usePressureSize: Bool = false, usePressureStrength: Bool = false) {
        self.tool = tool
        self.strength = strength
        self.spacing = spacing
        self.falloff = falloff
        self.blend = blend
        self.usePressureSize = usePressureSize
        self.usePressureStrength = usePressureStrength
    }

    /// The Blender 5.2.1 essentials brush a tool starts from.
    public static func essentials(_ tool: TexturePaintTool) -> TexturePaintBrush {
        switch tool {
        case .draw:
            return TexturePaintBrush(tool: .draw, strength: 1, spacing: 10,
                                     falloff: .curve(TexturePaintCurves.paintHard))
        case .soften:
            return TexturePaintBrush(tool: .soften, strength: 1, spacing: 10,
                                     falloff: .preset(.smooth), usePressureStrength: true)
        case .smear:
            return TexturePaintBrush(tool: .smear, strength: 0.6, spacing: 5,
                                     falloff: .preset(.smooth), usePressureStrength: true)
        }
    }
}

/// Blender's `ImagePaint` options: how the brush reaches the surface.
public struct TexturePaintOptions: Equatable, Sendable {
    /// `use_occlude`: only paint what is not hidden behind other faces.
    public var occlude = true
    /// `use_backface_culling`: ignore faces pointing away from the view.
    public var backfaceCulling = true
    /// `use_normal_falloff`: paint less on faces seen at a glancing angle.
    public var normalFalloff = true
    /// `normal_angle`, in degrees.
    public var normalAngle: Float = 80
    /// `seam_bleed`: how far paint extends past a UV island's edge, in pixels.
    public var seamBleed = 2

    public init() {}
}

/// Everything a texture-paint stroke is painted with.
public struct TexturePaintSettings: Sendable {
    /// Blender's unified `size`: the brush *diameter* — Blender 5 measures it
    /// across, not from the centre — in region pixels (`PIXEL_DIAMETER`). The
    /// viewport's pixels, not the points a touch arrives in: on a 2× iPad a
    /// Size 100 brush is 50 points across, as it is 100 pixels across in
    /// Blender on a 2× display. 100, as in factory settings.
    public var size: Float = 100
    /// Blender's unified colour, as the swatch shows it (sRGB). Blender stores
    /// `color` scene-linear since 5.0: a byte image is painted with the sRGB
    /// value, a float image with `linearColour`. Black, as in factory settings.
    public var colour: SIMD3<Float> = .zero

    /// The colour a float image is painted with: the swatch taken from display
    /// to scene-linear, `srgb_to_linearrgb`, which is what Blender keeps in
    /// `color` and hands `do_projectpaint_draw_f` as `paint_color_linear`.
    public var linearColour: SIMD3<Float> {
        SIMD3(BlenderColor.srgbToLinear(max(0, min(1, colour.x))),
              BlenderColor.srgbToLinear(max(0, min(1, colour.y))),
              BlenderColor.srgbToLinear(max(0, min(1, colour.z))))
    }
    public var options = TexturePaintOptions()
    private var brushes: [TexturePaintTool: TexturePaintBrush] = [:]

    public init() {}

    /// The brush for a tool — its essentials settings until changed.
    public subscript(tool: TexturePaintTool) -> TexturePaintBrush {
        get { brushes[tool] ?? .essentials(tool) }
        set { brushes[tool] = newValue }
    }
}

// MARK: - Blender's byte colour arithmetic

/// One RGBA byte texel, straight alpha.
public struct Texel: Equatable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// The byte blending Blender's projection painter uses on byte images, from
/// `blenlib/intern/math_color_blend_inline.cc` and `math_color_inline.cc`.
/// Integer arithmetic throughout, so the results are Blender's to the byte.
public enum BlenderColor {

    /// `unit_float_to_uchar_clamp`.
    @inline(__always)
    public static func byte(_ f: Float) -> UInt8 {
        if !(f > 0) { return 0 }
        if f > 1 - 0.5 / 255 { return 255 }
        return UInt8(255 * f + 0.5)
    }

    /// `divide_round_i`.
    @inline(__always)
    static func divideRound(_ a: Int, _ b: Int) -> Int { (2 * a + b) / (2 * b) }

    /// `IMB_blend_color_byte` for the blend modes the brush offers.
    public static func blend(_ mode: BrushBlend, _ s1: Texel, _ s2: Texel) -> Texel {
        switch mode {
        case .mix:      return mix(s1, s2)
        case .add:      return add(s1, s2)
        case .subtract: return subtract(s1, s2)
        case .multiply: return multiply(s1, s2)
        case .lighten:  return lighten(s1, s2)
        case .darken:   return darken(s1, s2)
        }
    }

    /// `blend_color_mix_byte`: straight "over", with `s2.a` as the amount.
    public static func mix(_ s1: Texel, _ s2: Texel) -> Texel {
        guard s2.a != 0 else { return s1 }
        let t = Int(s2.a), mt = 255 - t, a1 = Int(s1.a)
        let total = mt * a1 + t * 255
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: divideRound(mt * a1 * Int(c1) + t * 255 * Int(c2), total))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b),
                     UInt8(clamping: divideRound(total, 255)))
    }

    /// `blend_color_add_byte`.
    public static func add(_ s1: Texel, _ s2: Texel) -> Texel {
        guard s2.a != 0 else { return s1 }
        let t = Int(s2.a)
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: min(divideRound(Int(c1) * 255 + Int(c2) * t, 255), 255))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b), s1.a)
    }

    /// `blend_color_sub_byte`.
    public static func subtract(_ s1: Texel, _ s2: Texel) -> Texel {
        guard s2.a != 0 else { return s1 }
        let t = Int(s2.a)
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: max(divideRound(Int(c1) * 255 - Int(c2) * t, 255), 0))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b), s1.a)
    }

    /// `blend_color_mul_byte`.
    public static func multiply(_ s1: Texel, _ s2: Texel) -> Texel {
        guard s2.a != 0 else { return s1 }
        let t = Int(s2.a), mt = 255 - t
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: divideRound(mt * Int(c1) * 255 + t * Int(c1) * Int(c2), 255 * 255))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b), s1.a)
    }

    /// `blend_color_lighten_byte`.
    public static func lighten(_ s1: Texel, _ s2: Texel) -> Texel {
        guard s2.a != 0 else { return s1 }
        let t = Int(s2.a), mt = 255 - t
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: divideRound(mt * Int(c1) + t * Int(max(c1, c2)), 255))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b), s1.a)
    }

    /// `blend_color_darken_byte`.
    public static func darken(_ s1: Texel, _ s2: Texel) -> Texel {
        guard s2.a != 0 else { return s1 }
        let t = Int(s2.a), mt = 255 - t
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: divideRound(mt * Int(c1) + t * Int(min(c1, c2)), 255))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b), s1.a)
    }

    /// `blend_color_interpolate_byte`: from `s1` toward `s2` by `ft`, in
    /// premultiplied space so colour under zero alpha has no say.
    public static func interpolate(_ s1: Texel, _ s2: Texel, _ ft: Float) -> Texel {
        let t = Int(255 * max(0, min(1, ft))), mt = 255 - t
        let total = mt * Int(s1.a) + t * Int(s2.a)
        guard total > 0 else { var out = s1; out.a = 0; return out }
        func channel(_ c1: UInt8, _ c2: UInt8) -> UInt8 {
            UInt8(clamping: divideRound(mt * Int(c1) * Int(s1.a) + t * Int(c2) * Int(s2.a), total))
        }
        return Texel(channel(s1.r, s2.r), channel(s1.g, s2.g), channel(s1.b, s2.b),
                     UInt8(clamping: divideRound(total, 255)))
    }

    /// `straight_uchar_to_premul_float`.
    public static func premultiplied(_ t: Texel) -> SIMD4<Float> {
        let alpha = Float(t.a) / 255
        let fac = alpha / 255
        return SIMD4(Float(t.r) * fac, Float(t.g) * fac, Float(t.b) * fac, alpha)
    }

    /// `premul_float_to_straight_uchar`.
    public static func straight(_ c: SIMD4<Float>) -> Texel {
        if c.w == 0 || c.w == 1 {
            return Texel(byte(c.x), byte(c.y), byte(c.z), byte(c.w))
        }
        let inverse = 1 / c.w
        return Texel(byte(c.x * inverse), byte(c.y * inverse), byte(c.z * inverse), byte(c.w))
    }

    // MARK: Float images
    //
    // A float image is painted in its own scene-linear, premultiplied values,
    // with `IMB_blend_color_float` and `blend_color_interpolate_float` from
    // the same two files. The engine calls these over raw buffers; the SIMD
    // forms below are for reading and testing.

    /// `IMB_blend_color_float`, into `dst` from `src1` and a brush colour
    /// `(r, g, b, t)` whose colour is already premultiplied by `t`, as
    /// `do_projectpaint_draw_f` makes it. `dst` may be `src1`.
    @inline(__always)
    public static func blendFloat(_ mode: BrushBlend, _ dst: UnsafeMutablePointer<Float>,
                                  _ src1: UnsafePointer<Float>,
                                  _ r: Float, _ g: Float, _ b: Float, _ t: Float) {
        let r1 = src1[0], g1 = src1[1], b1 = src1[2], a1 = src1[3]
        guard t != 0 else {
            dst[0] = r1; dst[1] = g1; dst[2] = b1; dst[3] = a1
            return
        }
        let mt = 1 - t
        switch mode {
        case .mix:
            // blend_color_mix_float: premultiplied "over".
            dst[0] = mt * r1 + r; dst[1] = mt * g1 + g; dst[2] = mt * b1 + b
            dst[3] = mt * a1 + t
        case .add:
            dst[0] = r1 + r * a1; dst[1] = g1 + g * a1; dst[2] = b1 + b * a1
            dst[3] = a1
        case .subtract:
            dst[0] = maxFF(r1 - r * a1, 0); dst[1] = maxFF(g1 - g * a1, 0); dst[2] = maxFF(b1 - b * a1, 0)
            dst[3] = a1
        case .multiply:
            dst[0] = mt * r1 + r1 * r * a1; dst[1] = mt * g1 + g1 * g * a1; dst[2] = mt * b1 + b1 * b * a1
            dst[3] = a1
        case .lighten:
            let map = a1 / t
            dst[0] = mt * r1 + t * maxFF(r1, r * map); dst[1] = mt * g1 + t * maxFF(g1, g * map)
            dst[2] = mt * b1 + t * maxFF(b1, b * map)
            dst[3] = a1
        case .darken:
            let map = a1 / t
            dst[0] = mt * r1 + t * minFF(r1, r * map); dst[1] = mt * g1 + t * minFF(g1, g * map)
            dst[2] = mt * b1 + t * minFF(b1, b * map)
            dst[3] = a1
        }
    }

    /// `max_ff` and `min_ff`, which compare the way C does.
    @inline(__always) static func maxFF(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
    @inline(__always) static func minFF(_ a: Float, _ b: Float) -> Float { a < b ? a : b }

    /// `IMB_blend_color_float` on values.
    public static func blendFloat(_ mode: BrushBlend, _ s1: SIMD4<Float>, _ s2: SIMD4<Float>) -> SIMD4<Float> {
        var src = [s1.x, s1.y, s1.z, s1.w]
        var out = [Float](repeating: 0, count: 4)
        src.withUnsafeMutableBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                blendFloat(mode, d.baseAddress!, UnsafePointer(s.baseAddress!), s2.x, s2.y, s2.z, s2.w)
            }
        }
        return SIMD4(out[0], out[1], out[2], out[3])
    }

    /// `blend_color_interpolate_float`: premultiplied, so a straight lerp.
    public static func interpolateFloat(_ s1: SIMD4<Float>, _ s2: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        let mt = 1 - t
        return SIMD4(mt * s1.x + t * s2.x, mt * s1.y + t * s2.y, mt * s1.z + t * s2.z, mt * s1.w + t * s2.w)
    }

    /// `premul_to_straight_v4_v4`.
    @inline(__always)
    public static func straightFloat(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> (Float, Float, Float, Float) {
        if a == 0 || a == 1 { return (r, g, b, a) }
        let inverse = 1 / a
        return (r * inverse, g * inverse, b * inverse, a)
    }

    /// `linearrgb_to_srgb`.
    public static func linearToSRGB(_ c: Float) -> Float {
        if c < 0.0031308 { return c < 0 ? 0 : c * 12.92 }
        return 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// `srgb_to_linearrgb`.
    public static func srgbToLinear(_ c: Float) -> Float {
        if c < 0.04045 { return c < 0 ? 0 : c / 12.92 }
        return pow((c + 0.055) / 1.055, 2.4)
    }
}
