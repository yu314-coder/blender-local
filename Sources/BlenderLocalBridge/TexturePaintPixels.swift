import Foundation
import Accelerate

/// Pixels between Blender's `Image.pixels` and the viewport's images.
///
/// A 1024² image is four million values each way — on entering, after every
/// undo, and whenever a stroke is kept — so the common case, a four-channel
/// byte image, goes through Accelerate a row at a time. That keeps it quick in
/// the Debug builds the device and the simulator run, where a Swift loop over
/// four million values is not. Other byte images take the general path in
/// TexturePaintSurface.swift.
///
/// A float image is not converted at all: its values are painted as they are,
/// and only reordered between Blender's rows, bottom first, and the viewport's,
/// top first. The bytes on screen are made from them for display.
public enum TexturePaintPixels {

    /// The viewport's bytes from a byte image's floats. These are its own
    /// bytes exactly: Blender stores `unit_float_to_uchar_clamp(v)`, which is
    /// 255·v + ½, clamped to 0…255, truncated.
    public static func bytes(from floats: UnsafeBufferPointer<Float>, width: Int, height: Int,
                             channels: Int) -> [UInt8] {
        guard channels == 4, width > 0, height > 0,
              floats.count >= width * height * 4, let source = floats.baseAddress
        else {
            return TexturePaintPixelsScalar.bytes(from: floats, width: width, height: height,
                                                  channels: channels)
        }
        let n = width * 4
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var row = [Float](repeating: 0, count: n)
        var scale: Float = 255, half: Float = 0.5, low: Float = 0, high: Float = 255
        out.withUnsafeMutableBufferPointer { dst in
            row.withUnsafeMutableBufferPointer { tmp in
                guard let target = dst.baseAddress, let scratch = tmp.baseAddress else { return }
                for y in 0..<height {
                    // Blender's rows run bottom up, the viewport's top down.
                    vDSP_vsmsa(source + y * n, 1, &scale, &half, scratch, 1, vDSP_Length(n))
                    vDSP_vclip(scratch, 1, &low, &high, scratch, 1, vDSP_Length(n))
                    vDSP_vfixu8(scratch, 1, target + (height - 1 - y) * n, 1, vDSP_Length(n))
                }
            }
        }
        return out
    }

    /// Blender's floats for `pixels.foreach_set`. For a byte image that is
    /// b · (1/255) — what Blender's own getter returns — so its setter gets
    /// back every byte. For a float image it is the painted values themselves,
    /// in Blender's row order and channel count: nothing passes through a byte,
    /// and a texel no stroke reached goes back bit for bit as it came.
    public static func floats(from image: TextureImage) -> [Float] {
        if image.isFloat, let values = image.floats {
            return blenderLayout(values, width: image.width, height: image.height, channels: image.channels)
        }
        let width = image.width, height = image.height
        guard image.channels == 4 else { return TexturePaintPixelsScalar.floats(from: image) }
        let n = width * 4
        var out = [Float](repeating: 0, count: width * height * 4)
        var inverse: Float = 1 / 255
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let source = src.baseAddress, let target = dst.baseAddress,
                      src.count >= width * height * 4 else { return }
                for y in 0..<height {
                    vDSP_vfltu8(source + (height - 1 - y) * n, 1, target + y * n, 1, vDSP_Length(n))
                }
                vDSP_vsmul(target, 1, &inverse, target, 1, vDSP_Length(dst.count))
            }
        }
        return out
    }

    // MARK: Float images

    /// A float image's values as the engine paints them — RGBA, top row
    /// first — from `Image.pixels`. Four channels are only reordered. Three
    /// gain an opaque alpha, and one or two a grey, so every image paints as
    /// RGBA; `blenderLayout` takes the extra channels off again.
    public static func paintLayout(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                   channels: Int) -> [Float] {
        let c = max(1, channels)
        var out = [Float](repeating: 0, count: width * height * 4)
        guard values.count >= width * height * c, let source = values.baseAddress else { return out }
        out.withUnsafeMutableBufferPointer { dst in
            guard let target = dst.baseAddress else { return }
            for y in 0..<height {
                let from = source + y * width * c
                let to = target + (height - 1 - y) * width * 4
                if c == 4 {
                    to.update(from: from, count: width * 4)
                    continue
                }
                for x in 0..<width {
                    let s = from + x * c, d = to + x * 4
                    if c >= 3 {
                        d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 1
                    } else {
                        d[0] = s[0]; d[1] = s[0]; d[2] = s[0]; d[3] = c == 2 ? s[1] : 1
                    }
                }
            }
        }
        return out
    }

    /// The inverse of `paintLayout`: Blender's row order and channel count.
    /// An image of one or two channels gets red back as its grey.
    public static func blenderLayout(_ values: [Float], width: Int, height: Int, channels: Int) -> [Float] {
        let c = max(1, channels)
        var out = [Float](repeating: 0, count: width * height * c)
        guard values.count >= width * height * 4 else { return out }
        values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let source = src.baseAddress, let target = dst.baseAddress else { return }
                for y in 0..<height {
                    let from = source + (height - 1 - y) * width * 4
                    let to = target + y * width * c
                    if c == 4 {
                        to.update(from: from, count: width * 4)
                        continue
                    }
                    for x in 0..<width {
                        let s = from + x * 4, d = to + x * c
                        if c >= 3 {
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]
                        } else {
                            d[0] = s[0]
                            if c == 2 { d[1] = s[3] }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Remakes the display bytes of columns `x0...x1`, rows `y0...y1` (from
    /// the top) of a float image from its values: premultiplied to straight,
    /// as Blender's display buffer divides alpha out, then through the sRGB
    /// curve and clamped to a byte. Nothing is painted in these bytes.
    public static func refreshDisplay(_ image: TextureImage, x0: Int, y0: Int, x1: Int, y1: Int) {
        guard image.floats != nil else { return }
        let width = image.width
        let lo = max(0, x0), hi = min(width - 1, x1), top = max(0, y0), bottom = min(image.height - 1, y1)
        guard lo <= hi, top <= bottom else { return }
        image.withMutableFloats { floats in
            guard let source = floats.baseAddress, floats.count >= width * image.height * 4 else { return }
            image.withMutablePixels { pixels in
                guard let target = pixels.baseAddress else { return }
                for y in top...bottom {
                    for x in lo...hi {
                        let i = (y * width + x) * 4
                        let (r, g, b, a) = BlenderColor.straightFloat(source[i], source[i + 1],
                                                                      source[i + 2], source[i + 3])
                        target[i] = BlenderColor.byte(BlenderColor.linearToSRGB(r))
                        target[i + 1] = BlenderColor.byte(BlenderColor.linearToSRGB(g))
                        target[i + 2] = BlenderColor.byte(BlenderColor.linearToSRGB(b))
                        target[i + 3] = BlenderColor.byte(a)
                    }
                }
            }
        }
    }
}
