import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// Round 4, group 8: a text object's body and settings, and Add ▸ Image's
// reference and background pictures. The Python is in _blenderkit_text.py and
// _blenderkit_images.py, which hold the measurements.

/// A text object's settings, as `_blenderkit_text.record` reads them and the
/// Data tab shows them: Blender's property names (properties_data_curve.py's
/// Shape, Geometry, Bevel, Transform, Alignment and Spacing panels).
public struct TextSettings: Equatable, Sendable {
    /// `data.body`, as Blender holds it.
    public var body: String
    public var values: [String: String]

    /// The settings the Data tab draws, by property name, with Blender's
    /// words and the panel each is in.
    public static let rows: [(panel: String, key: String, label: String)] = [
        ("Shape", "resolution_u", "Resolution Preview U"),
        ("Shape", "fill_mode", "Fill Mode"),
        ("Geometry", "offset", "Offset"),
        ("Geometry", "extrude", "Extrude"),
        ("Bevel", "bevel_depth", "Depth"),
        ("Bevel", "bevel_resolution", "Resolution"),
        ("Transform", "size", "Size"),
        ("Transform", "shear", "Shear"),
        ("Alignment", "align_x", "Horizontal"),
        ("Alignment", "align_y", "Vertical"),
        ("Spacing", "space_character", "Character Spacing"),
        ("Spacing", "space_word", "Word Spacing"),
        ("Spacing", "space_line", "Line Spacing"),
        ("Spacing", "offset_x", "Offset X"),
        ("Spacing", "offset_y", "Y"),
    ]

    /// The enums' items as Blender's RNA lists them (measured in 5.2.1). A
    /// text is 2D, so Fill Mode takes the 2D list (`rna_Curve_fill_mode_itemf`).
    public static let choices: [String: [(id: String, label: String)]] = [
        "align_x": [("LEFT", "Left"), ("CENTER", "Center"), ("RIGHT", "Right"),
                    ("JUSTIFY", "Justify"), ("FLUSH", "Flush")],
        "align_y": [("TOP", "Top"), ("TOP_BASELINE", "Top Baseline"), ("CENTER", "Middle"),
                    ("BOTTOM_BASELINE", "Bottom Baseline"), ("BOTTOM", "Bottom")],
        "fill_mode": [("NONE", "None"), ("BACK", "Back"), ("FRONT", "Front"), ("BOTH", "Both")],
    ]

    /// RNA's hard ranges, which the fields hold a draft to: measured in 5.2.1
    /// (`TextCurve.bl_rna.properties[…].hard_min`/`hard_max`). Extrude runs
    /// to FLT_MAX and Offset, Depth and Offset X and Y both ways; Offset X
    /// and Y's ±50 is only Blender's soft range, which a typed value passes.
    /// Round 4's review found those three clamped to ±50 and 1e6 here.
    public static let ranges: [String: ClosedRange<Float>] = [
        "size": 0.0001...10000, "extrude": 0...Float.greatestFiniteMagnitude,
        "bevel_depth": -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude,
        "offset": -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude,
        "shear": -1...1, "space_character": 0...10, "space_word": 0...10, "space_line": 0...10,
        "offset_x": -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude,
        "offset_y": -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude,
        "resolution_u": 1...1024, "bevel_resolution": 0...32,
    ]

    public static let integers: Set<String> = ["resolution_u", "bevel_resolution"]

    public func number(_ key: String) -> Float? { values[key].flatMap(Float.init) }

    static func parse(_ values: [String: String]) -> TextSettings? {
        guard let body = values["body"], values["size"] != nil else { return nil }
        var rest = values
        rest["body"] = nil
        if let font = rest["font"] { rest["font"] = font.removingPercentEncoding ?? font }
        return TextSettings(body: body.removingPercentEncoding ?? body, values: rest)
    }
}

/// The Python behind a text object's Body Text field and its Data tab rows.
public enum TextBpy {
    static let module = "import _blenderkit_text"

    /// Writes `body` to the text object `name`'s `data.body`, priced first
    /// (`_blenderkit_text.set_body`), from the letters' outlines as Blender
    /// lays them out: the price used to scale the vertices the app draws now,
    /// which changing the letters beat (round 4's review). The undo step is
    /// the property's name, as Blender's for any property edited in its
    /// interface.
    public static func setBody(_ body: String, object name: String) -> String {
        "\(module)\n_blenderkit_text.set_body(\(Bpy.quote(name)), \(Bpy.quote(body)))"
    }

    public static let bodyUndo = "Body Text"

    /// One Data tab row: `python` is the value's literal.
    public static func set(_ key: String, to python: String, object name: String) -> String {
        "\(module)\n_blenderkit_text.set_setting(\(Bpy.quote(name)), \(Bpy.quote(key)), \(python))"
    }

    /// The literal a row sends for `value` of setting `key`.
    public static func python(_ key: String, _ value: Float) -> String {
        TextSettings.integers.contains(key) ? "\(Int(value.rounded()))"
            : String(format: "%.6g", Double(value))
    }
}

/// Add ▸ Image's Reference, Background and Mesh Plane (`VIEW3D_MT_image_add`),
/// and the Empty panel's image rows.
public enum ReferenceImages {
    public enum Kind: String, CaseIterable, Sendable {
        case reference, background, plane
        /// Blender's rows, in its order, with the ellipsis of a file browser.
        public var label: String {
            switch self {
            case .reference: return "Reference..."
            case .background: return "Background..."
            case .plane: return "Mesh Plane..."
            }
        }
        public var icon: String {
            switch self {
            case .reference: return "photo"
            case .background: return "photo.on.rectangle"
            case .plane: return "rectangle"
            }
        }
        /// Blender's undo step for the row: its operator's name.
        public var undo: String { self == .plane ? ReferenceImages.planeUndo : ReferenceImages.undo }
    }

    /// Blender's undo step for Reference... and Background...: the operator's
    /// own name.
    public static let undo = "Add Empty Image/Drop Image to Empty"
    /// And for Mesh Plane... (`image.import_as_mesh_planes`, whose label it
    /// is): a core operator in 5.2 and in the app's bundled bpy, measured to
    /// run headless (_blenderkit_images.add_plane). It was left out as "an
    /// add-on's importer", which it has not been since 4.2.
    public static let planeUndo = "Import Images as Planes"

    /// Where a picked picture is copied before Blender reads it. Blender packs
    /// it into the .blend (`_blenderkit_images.add`), so this copy only has
    /// to outlive the add; it is the Caches folder, which the system may
    /// empty, and the viewport then draws from the packed bytes.
    public static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Reference Images", isDirectory: true)
    }

    /// Copies `data` (a picture from Photos or Files) into `folder` under
    /// `name`, keeping its extension, and returns the file.
    public static func store(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        base = base.replacingOccurrences(of: "/", with: "-")
        if base.isEmpty { base = "Image" }
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(String(format: "%@.%03d", base, n)).appendingPathExtension(ext)
            n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// What the row sends: the image at `path` added as Blender's row adds
    /// it, at `location`, turned by `rotation` (the view's, XYZ Euler) so it
    /// faces the view, and for Background hidden in perspective views when
    /// the view is orthographic, as Blender's operator decides. Mesh Plane...
    /// is Blender's own operator with its defaults: at Blender's 3D cursor
    /// (the app's, mirrored), facing the scene camera's main axis.
    public static func add(_ kind: Kind, path: String, location: SIMD3<Float>, rotation: SIMD3<Float>,
                           orthographic: Bool) -> String {
        func vector(_ v: SIMD3<Float>) -> String {
            String(format: "(%.6g, %.6g, %.6g)", Double(v.x), Double(v.y), Double(v.z))
        }
        if kind == .plane {
            return "import _blenderkit_images\n_blenderkit_images.add_plane(\(Bpy.quote(path)))"
        }
        return "import _blenderkit_images\n_blenderkit_images.add(\(Bpy.quote(path)), "
            + "\(kind == .background ? "True" : "False"), \(vector(location)), \(vector(rotation)), "
            + "\(orthographic ? "True" : "False"))"
    }

    /// One of the Empty panel's image rows (`_blenderkit_images.set_setting`):
    /// Depth, Side, Show In, Opacity and its slider, Offset X and Y.
    public static func set(_ key: String, to python: String, object name: String) -> String {
        "import _blenderkit_images\n_blenderkit_images.set_setting(\(Bpy.quote(name)), \(Bpy.quote(key)), \(python))"
    }

    /// The Empty panel's Display As and Size, which every empty has.
    public static func setEmpty(_ key: String, to python: String, object name: String) -> String {
        "bpy.data.objects[\(Bpy.quote(name))].\(key) = \(python)"
    }
}

public extension ReferenceImages {
    /// The longest side Blender is handed a picture at, and the most it may
    /// decode to (`_blenderkit_images.MAX_SIDE`, `MAX_PIXEL_BYTES`).
    static let maxSide = 4096

    enum PictureError: Error, LocalizedError, Equatable {
        case unreadable
        case unencodable
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "the system cannot read it as a picture"
            case .unencodable: return "it could not be written as a PNG or a JPEG"
            }
        }
    }

    /// What Blender is handed for `data`, a picture from Photos or Files, and
    /// the name to store it under (round 4's review of group 8).
    ///
    /// Blender reads PNG and JPEG here, not HEIC — measured in 5.2.1, a HEIC
    /// is "unknown file-format", 0 × 0, the frame drawn with no picture, and
    /// HEIC is what Photos gives for a camera's picture. It ignores a JPEG's
    /// EXIF orientation (a 64 × 32 picture tagged to turn a quarter loads
    /// unturned) and an embedded colour profile, taking the values as sRGB.
    /// And it decodes the whole picture: a 6,000 × 6,000 PNG of 644 KB took
    /// it from 310 to 522 MB. So a PNG or JPEG is handed over as it is only
    /// when it is already the right way up, at most `maxSide` on its longer
    /// side, 8 bits a channel and sRGB (or untagged); anything else is
    /// decoded by the system, turned the way it shows it, scaled to
    /// `maxSide`, converted to sRGB at 8 bits, and written as a PNG (a PNG,
    /// or anything with transparency) or a JPEG.
    static func prepare(_ data: Data, name: String) throws -> (data: Data, name: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else { throw PictureError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        func int(_ key: CFString) -> Int? { (properties[key] as? NSNumber)?.intValue }
        let width = int(kCGImagePropertyPixelWidth) ?? 0, height = int(kCGImagePropertyPixelHeight) ?? 0
        let orientation = int(kCGImagePropertyOrientation) ?? 1
        let depth = int(kCGImagePropertyDepth) ?? 8
        let alpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let profile = properties[kCGImagePropertyProfileName] as? String
        var base = (name as NSString).deletingPathExtension
        if base.isEmpty { base = "Image" }
        let isPNG = type == UTType.png.identifier, isJPEG = type == UTType.jpeg.identifier
        let sRGB = profile == nil || profile!.localizedCaseInsensitiveContains("sRGB")
        if (isPNG || isJPEG) && orientation == 1 && depth <= 8 && width > 0 && height > 0
            && max(width, height) <= maxSide && sRGB {
            return (data, base + (isPNG ? ".png" : ".jpg"))
        }
        let longest = max(width, height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longest > 0 ? min(longest, maxSide) : maxSide]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PictureError.unreadable
        }
        let keepsAlpha = alpha || isPNG
        let w = decoded.width, h = decoded.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: keepsAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                             : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PictureError.unencodable }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = context.makeImage() else { throw PictureError.unencodable }
        let out = NSMutableData()
        let outType = keepsAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(out, outType.identifier as CFString, 1, nil)
        else { throw PictureError.unencodable }
        var written: [CFString: Any] = [:]
        if !keepsAlpha { written[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, flat, written as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PictureError.unencodable }
        return (out as Data, base + (keepsAlpha ? ".png" : ".jpg"))
    }

    /// The most pixels the viewport decodes a picture from. ImageIO decodes
    /// a PNG whole before scaling it: a picture Blender holds from an opened
    /// file at 16,000 × 16,000 would take a gigabyte in the app for a
    /// 2,048-pixel texture. Past this the frame is drawn without it.
    static let viewportMaxPixels = 8192 * 8192

    /// The picture at `path` as the viewport draws it: as Blender reads the
    /// file — its stored pixels the way they are stored, the EXIF orientation
    /// ignored (round 4's review: a JPEG tagged to turn a quarter was drawn
    /// turned and stretched over Blender's unturned frame), and its values
    /// taken as sRGB, its colour profile ignored — scaled to `maxSide`.
    static func viewportImage(at path: String, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width * height <= viewportMaxPixels else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height)),
                                        kCGImageSourceCreateThumbnailWithTransform: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // The same values read as sRGB, as Blender reads them; a picture
        // whose model is not RGB (grey) keeps its own.
        if let space = CGColorSpace(name: CGColorSpace.sRGB), image.colorSpace?.model == .rgb,
           let reread = image.copy(colorSpace: space) {
            return reread
        }
        return image
    }
}
