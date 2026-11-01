import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Pictures for the modkinds tests and the Blender check (round 4's review of
// group 8): made with ImageIO, as Photos and Files make theirs, so the files
// the app converts are the kinds a device hands it — HEIC, a JPEG with an
// EXIF orientation, a 16-bit PNG, a picture far bigger than Blender should
// decode, a Display P3 one.

enum Pictures {
    /// The four quarters' colours of the stored picture, top left, top
    /// right, bottom left, bottom right: red, blue, green, yellow. Four, so a
    /// turn or a flip shows (two halves could not tell a half turn).
    static let quarters: [[UInt8]] = [[255, 0, 0], [0, 0, 255], [0, 255, 0], [255, 255, 0]]

    /// A `width` × `height` picture in those four quarters, at 8 bits, sRGB
    /// (or `space`), stored top row first.
    static func quadrants(width: Int, height: Int, space: CGColorSpace? = nil, alpha: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let q = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let k = (y * width + x) * 4
                bytes[k] = quarters[q][0]; bytes[k + 1] = quarters[q][1]; bytes[k + 2] = quarters[q][2]
                bytes[k + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast
                                                                 : CGImageAlphaInfo.noneSkipLast).rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A `width` × `height` picture of one colour, its values `rgb` in `space`.
    static func solid(width: Int, height: Int, rgb: [UInt8], space: CGColorSpace) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for k in stride(from: 0, to: bytes.count, by: 4) {
            bytes[k] = rgb[0]; bytes[k + 1] = rgb[1]; bytes[k + 2] = rgb[2]
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A 16-bit-a-channel picture of the same quarters.
    static func sixteenBit(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.draw(quadrants(width: width, height: height), in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// `image` written as `type`, with `properties` (an orientation, say).
    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The stored type, width, height, bits a channel, orientation and
    /// colour profile ImageIO reads from `data`'s header.
    static func header(_ data: Data) -> (type: String, width: Int, height: Int, depth: Int, orientation: Int,
                                         profile: String?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        func int(_ k: CFString) -> Int { (p[k] as? NSNumber)?.intValue ?? 0 }
        return (type, int(kCGImagePropertyPixelWidth), int(kCGImagePropertyPixelHeight),
                int(kCGImagePropertyDepth), (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
                p[kCGImagePropertyProfileName] as? String)
    }

    /// `image`'s pixels as 8-bit RGBA, top row first, its values as stored
    /// (drawn into a context of its own colour space when that is RGB).
    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// The colour at the centre of each quarter of `image` (top left, top
    /// right, bottom left, bottom right).
    static func quarterColours(_ image: CGImage) -> [[Int]] {
        let w = image.width, h = image.height, bytes = rgba(image)
        return [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)].map { x, y in
            let k = (y * w + x) * 4
            return [Int(bytes[k]), Int(bytes[k + 1]), Int(bytes[k + 2])]
        }
    }

    /// The same for a file's picture as ImageIO decodes it, the EXIF
    /// orientation applied (`transform`, as Photos shows it) or not.
    static func decoded(_ data: Data, transform: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: transform,
                                        kCGImageSourceThumbnailMaxPixelSize: 100_000]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Whether two colours are the same within JPEG's loss.
    static func near(_ a: [Int], _ b: [UInt8], _ tolerance: Int = 48) -> Bool {
        a.count == 3 && zip(a, b).allSatisfy { abs($0 - Int($1)) <= tolerance }
    }
}
