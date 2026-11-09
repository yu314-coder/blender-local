import Foundation
import simd

/// What the Properties editor's Render, Output and World tabs show, and the
/// Render panel's quick choices read: the scene's own settings, as
/// `_blenderkit_render.settings` reads them from Blender.
///
/// The Render panel used to keep its own engine, quality and size and stamp
/// them onto the scene at every render. Now there is one set, Blender's: the
/// panel's chips write the same properties the tabs write, and a render
/// changes none of them (`RenderRequest`, `_blenderkit_render.save`).
public struct RenderSettings: Decodable, Equatable, Sendable {

    /// An enum item: Blender's identifier and the name its menu draws.
    public struct Choice: Decodable, Equatable, Hashable, Sendable, Identifiable {
        public var identifier: String
        public var name: String
        public var id: String { identifier }

        public init(_ identifier: String, _ name: String) {
            self.identifier = identifier
            self.name = name
        }

        public init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            identifier = try pair.decode(String.self)
            name = try pair.decode(String.self)
        }
    }

    public struct Cycles: Decodable, Equatable, Sendable {
        public var device: String
        public var samples: Int
        public var useAdaptiveSampling: Bool
        public var adaptiveThreshold: Double
        public var timeLimit: Double
        public var useDenoising: Bool
        public var denoiser: String
        public var denoisers: [Choice]
        public var maxBounces: Int
    }

    public struct Eevee: Decodable, Equatable, Sendable {
        public var taaRenderSamples: Int
        public var taaSamples: Int
        public var useRaytracing: Bool
        public var useShadows: Bool
        public var shadowRayCount: Int
        public var shadowStepCount: Int
    }

    public struct Workbench: Decodable, Equatable, Sendable {
        public var light: String
        public var colorType: String
        public var singleColor: [Double]
        public var renderAa: String
    }

    public struct ColorManagement: Decodable, Equatable, Sendable {
        public var displayDevice: String
        public var displayDevices: [Choice]
        public var viewTransform: String
        public var viewTransforms: [Choice]
        public var look: String
        public var looks: [Choice]
        public var exposure: Double
        public var gamma: Double
    }

    public struct World: Decodable, Equatable, Sendable {
        public var name: String
        public var useNodes: Bool
        /// The node on the World Output's Surface, nil when nothing is linked.
        public var node: String?
        public var nodeLabel: String?
        /// Whether that node is a Background, whose Color and Strength follow.
        public var background: Bool
        /// Scene-linear, as Blender keeps it.
        public var color: [Double]
        public var strength: Double
        /// The node a socket is driven by, when it is linked.
        public var colorLinked: String?
        public var strengthLinked: String?
    }

    public var engine: String
    public var engines: [Choice]
    public var resolutionX: Int
    public var resolutionY: Int
    public var resolutionPercentage: Int
    public var fps: Int
    public var fpsBase: Double
    public var frameStart: Int
    public var frameEnd: Int
    public var frameStep: Int
    public var mediaType: String
    public var fileFormat: String
    public var colorMode: String
    public var colorModes: [Choice]
    public var colorDepth: String
    public var colorDepths: [Choice]
    public var quality: Int
    public var compression: Int
    public var exrCodec: String
    public var ffmpegFormat: String
    public var ffmpegCodec: String
    public var ffmpegCrf: String
    public var ffmpegPreset: String
    public var isMovie: Bool
    /// Blender's factory Output (`_blenderkit_render.output_untouched`):
    /// Render Animation makes an MPEG-4 video of it, the app's default.
    public var outputUntouched: Bool
    public var filmTransparent: Bool
    public var useMotionBlur: Bool
    public var hasCamera: Bool
    public var ffmpegAvailable: Bool
    public var cycles: Cycles?
    public var eevee: Eevee?
    public var workbench: Workbench
    public var color: ColorManagement
    public var world: World?

    /// The settings as `settings()` prints them: the last line of `text`.
    public static func parse(_ text: String) -> RenderSettings? {
        guard let line = text.split(separator: "\n").last, let data = line.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(RenderSettings.self, from: data)
    }

    /// The engine as the Render panel knows it.
    public var renderEngine: RenderRequest.Engine? { RenderRequest.Engine(rawValue: engine) }

    /// The size Blender renders at: Resolution X and Y times %.
    public var renderSize: (width: Int, height: Int) {
        (resolutionX * resolutionPercentage / 100, resolutionY * resolutionPercentage / 100)
    }

    /// The scene's own samples for its engine; nil for Workbench.
    public var samples: Int? {
        switch renderEngine {
        case .cycles?: return cycles?.samples
        case .eevee?: return eevee?.taaRenderSamples
        default: return nil
        }
    }

    /// The frames Render Animation renders: Start to End by Step.
    public var frameCount: Int {
        frameEnd < frameStart ? 0 : (frameEnd - frameStart) / max(frameStep, 1) + 1
    }

    /// What Render Animation will write, in words for the panel.
    public var animationOutput: AnimationOutput {
        if outputUntouched && ffmpegAvailable { return .video(container: "MPEG4", codec: "H264", isDefault: true) }
        if isMovie { return .video(container: ffmpegFormat, codec: ffmpegCodec, isDefault: false) }
        return .frames(format: fileFormat)
    }

    public enum AnimationOutput: Equatable, Sendable {
        case video(container: String, codec: String, isDefault: Bool)
        case frames(format: String)

        /// "MPEG-4 video, H.264", "PNG frames".
        public var summary: String {
            switch self {
            case .video(let container, let codec, _):
                let c = RenderSettings.containers.first { $0.identifier == container }?.name ?? container
                let v = RenderSettings.videoCodecs.first { $0.identifier == codec }?.name ?? codec
                return "\(c) video, \(v)"
            case .frames(let format):
                let name = RenderSettings.imageFormats.first { $0.identifier == format }?.name ?? format
                return "\(name) frames"
            }
        }

        /// Whether AVKit can play it in the panel.
        public var playable: Bool {
            if case .video(let container, _, _) = self {
                return ["MPEG4", "QUICKTIME"].contains(container)
            }
            return false
        }
    }

    // MARK: Blender's lists (5.2.1's RNA enum names)

    /// Output ▸ File Format's image formats the app offers: the three the
    /// brief asked for, by `ImageFormatSettings.file_format`'s names.
    public static let imageFormats = [Choice("PNG", "PNG"), Choice("JPEG", "JPEG"), Choice("OPEN_EXR", "OpenEXR")]
    /// Media Type ▸ Video's one format.
    public static let videoFormat = Choice("FFMPEG", "FFmpeg Video")
    /// `ImageFormatSettings.media_type`: Image and Video (Multi-Layer EXR is
    /// left out).
    public static let mediaTypes = [Choice("IMAGE", "Image"), Choice("VIDEO", "Video")]
    /// Encoding ▸ Container: the two AVKit plays in the Render panel.
    public static let containers = [Choice("MPEG4", "MPEG-4"), Choice("QUICKTIME", "QuickTime")]
    /// Encoding ▸ Video ▸ Video Codec: the ones this build encodes, measured
    /// in the app (VideoToolbox's H.264 and HEVC, FFmpeg's MPEG-4 part 2).
    public static let videoCodecs = [Choice("H264", "H.264"), Choice("H265", "H.265 / HEVC"),
                                     Choice("MPEG4", "MPEG-4 (divx)")]
    /// Encoding ▸ Video ▸ Output Quality (`constant_rate_factor`), without
    /// Constant Bitrate and Custom Quality, which need a bitrate and a number.
    public static let outputQualities = [Choice("LOSSLESS", "Lossless"), Choice("PERC_LOSSLESS", "Perceptually Lossless"),
                                         Choice("HIGH", "High Quality"), Choice("MEDIUM", "Medium Quality"),
                                         Choice("LOW", "Low Quality"), Choice("VERYLOW", "Very Low Quality"),
                                         Choice("LOWEST", "Lowest Quality")]
    /// Encoding ▸ Video ▸ Encoding Speed (`ffmpeg_preset`).
    public static let encodingSpeeds = [Choice("BEST", "Slowest"), Choice("GOOD", "Good"), Choice("REALTIME", "Realtime")]
    /// OpenEXR's Codec (`exr_codec`), 5.2.1's items.
    public static let exrCodecs = [Choice("NONE", "None"), Choice("ZIP", "ZIP"), Choice("PIZ", "PIZ"),
                                   Choice("DWAA", "DWAA (lossy)"), Choice("DWAB", "DWAB (lossy)"),
                                   Choice("HTJ2K", "HTJ2K"), Choice("ZIPS", "ZIPS"), Choice("RLE", "RLE"),
                                   Choice("PXR24", "Pxr24 (lossy)"), Choice("B44", "B44 (lossy)"),
                                   Choice("B44A", "B44A (lossy)")]
    /// Cycles' Device (`CyclesRenderSettings.device`).
    public static let cyclesDevices = [Choice("CPU", "CPU"), Choice("GPU", "GPU Compute")]
    /// Workbench's Lighting (`View3DShading.light`).
    public static let workbenchLights = [Choice("STUDIO", "Studio"), Choice("MATCAP", "MatCap"), Choice("FLAT", "Flat")]
    /// Workbench's Object Color (`View3DShading.color_type`), in 5.2.1's order.
    public static let workbenchColors = [Choice("MATERIAL", "Material"), Choice("OBJECT", "Object"),
                                         Choice("RANDOM", "Random"), Choice("VERTEX", "Attribute"),
                                         Choice("TEXTURE", "Texture"), Choice("SINGLE", "Custom")]
    /// Workbench's Sampling ▸ Render (`SceneDisplay.render_aa`).
    public static let antiAliasing = [Choice("OFF", "No Anti-Aliasing"), Choice("FXAA", "Single Pass Anti-Aliasing"),
                                      Choice("5", "5 Samples"), Choice("8", "8 Samples"), Choice("11", "11 Samples"),
                                      Choice("16", "16 Samples"), Choice("32", "32 Samples")]
}

/// Blender's Frame Rate menu (`RENDER_MT_framerate_presets`): its presets,
/// in the menu's natural sort, and the label the Format panel draws.
public enum FrameRatePreset {
    public struct Preset: Equatable, Sendable, Identifiable {
        /// The preset's file name, which is the row's text.
        public var name: String
        public var fps: Int
        public var base: Double
        public var id: String { name }
    }

    /// scripts/presets/framerate/*.py, 5.2.1, in `path_menu`'s natural sort.
    public static let all: [Preset] = [
        Preset(name: "6", fps: 6, base: 1), Preset(name: "8", fps: 8, base: 1),
        Preset(name: "12", fps: 12, base: 1), Preset(name: "23.98", fps: 24, base: 1.001),
        Preset(name: "24", fps: 24, base: 1), Preset(name: "25", fps: 25, base: 1),
        Preset(name: "29.97", fps: 30, base: 1.001), Preset(name: "30", fps: 30, base: 1),
        Preset(name: "50", fps: 50, base: 1), Preset(name: "59.94", fps: 60, base: 1.001),
        Preset(name: "60", fps: 60, base: 1), Preset(name: "120", fps: 120, base: 1),
        Preset(name: "240", fps: 240, base: 1),
    ]

    /// The rates `RENDER_PT_format._draw_framerate_label` knows.
    static let known: [Double] = [6, 8, 12, 23.98, 24, 25, 29.97, 30, 50, 59.94, 60, 120, 240]

    /// The rate as the label rounds it: whole with a base of 1, else to two places.
    public static func rate(fps: Int, base: Double) -> Double {
        if base == 1 { return Double(fps) }
        return (Double(fps) / base * 100).rounded() / 100
    }

    /// Whether the rate is none of the presets: then Blender's label reads
    /// "Custom (… fps)" and the FPS and Base fields show.
    public static func isCustom(fps: Int, base: Double) -> Bool {
        !known.contains(rate(fps: fps, base: base))
    }

    /// The menu's label: "24 fps", "29.97 fps", "Custom (14 fps)" — Python's
    /// `{:.4g}`, which drops trailing zeros.
    public static func label(fps: Int, base: Double) -> String {
        let value = rate(fps: fps, base: base)
        let text = fourSignificant(value)
        return isCustom(fps: fps, base: base) ? "Custom (\(text) fps)" : "\(text) fps"
    }

    static func fourSignificant(_ value: Double) -> String {
        var s = String(format: "%.4g", value)
        if s.contains("."), !s.contains("e") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// The preset a rate is, if any.
    public static func preset(fps: Int, base: Double) -> Preset? {
        all.first { $0.fps == fps && abs($0.base - base) < 1e-6 }
    }
}

/// The Python each setting is written with, and the undo step it makes: the
/// field's own text, as Blender names a field's step (`ui_apply_but_undo`) and
/// the app's other fields are named.
public enum RenderSettingsBpy {

    /// The tabs' one read.
    public static let report = "import _blenderkit_render\nprint(_blenderkit_render.settings())"

    /// A value written on the scene: `path` from `bpy.context.scene`.
    public static func set(_ path: String, _ value: String) -> String {
        "bpy.context.scene.\(path) = \(value)"
    }

    public static func set(_ path: String, int value: Int) -> String { set(path, String(value)) }
    public static func set(_ path: String, bool value: Bool) -> String { set(path, value ? "True" : "False") }
    public static func set(_ path: String, choice: String) -> String { set(path, Bpy.quote(choice)) }
    public static func set(_ path: String, float value: Double) -> String {
        set(path, Self.number(value))
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        let s = String(format: "%.6g", value)
        return s.contains(".") || s.contains("e") ? s : s + ".0"
    }

    /// The Render Engine. Choosing Cycles here also turns its Device to GPU
    /// Compute when it was the CPU, in the same step — the app's default:
    /// Cycles on this iPad's Metal GPU is many times quicker (measured 2.9x on
    /// one scene), and Blender starts every scene on the CPU. The Device row
    /// puts it back.
    public static func engine(_ engine: String) -> String {
        var lines = [set("render.engine", choice: engine)]
        if engine == RenderRequest.Engine.cycles.rawValue {
            lines += ["if hasattr(bpy.context.scene, 'cycles') and bpy.context.scene.cycles.device == 'CPU':",
                      "    bpy.context.scene.cycles.device = 'GPU'"]
        }
        return lines.joined(separator: "\n")
    }

    /// A frame rate preset: the two lines its preset file runs.
    public static func frameRate(_ preset: FrameRatePreset.Preset) -> String {
        set("render.fps", int: preset.fps) + "\n" + set("render.fps_base", float: preset.base)
    }

    /// Output ▸ File Format (and Media Type), through the module: a video
    /// needs Media Type ▸ Video first (`_blenderkit_render.set_file_format`).
    public static func fileFormat(_ format: String) -> String {
        "import _blenderkit_render\n_blenderkit_render.set_file_format(\(Bpy.quote(format)))"
    }

    /// The Render panel's Draft, Good and Best: the samples of the engine in
    /// use, as Render Properties ▸ Sampling holds them, one step.
    public static func quality(_ quality: RenderRequest.Quality, engine: RenderRequest.Engine) -> String? {
        switch engine {
        case .cycles: return set("cycles.samples", int: quality.cyclesSamples)
        case .eevee: return set("eevee.taa_render_samples", int: quality.eeveeSamples)
        case .workbench: return nil
        }
    }

    /// World ▸ New (`world.new`).
    public static let newWorld = "import _blenderkit_render\n_blenderkit_render.world_new()"
    public static let newWorldUndo = "New World"

    /// World ▸ Surface ▸ Color, scene-linear.
    public static func worldColor(_ linear: SIMD3<Double>) -> String {
        "import _blenderkit_render\n_blenderkit_render.world_background(color=("
            + [linear.x, linear.y, linear.z].map { number(min(max($0, 0), 1e6)) }.joined(separator: ", ") + "))"
    }

    /// World ▸ Surface ▸ Strength.
    public static func worldStrength(_ value: Double) -> String {
        "import _blenderkit_render\n_blenderkit_render.world_background(strength=\(number(max(value, 0))))"
    }

    /// sRGB (what a colour picker shows) to scene-linear (what Blender's
    /// colour sockets hold), and back: the sRGB transfer function.
    public static func linear(fromSRGB c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func sRGB(fromLinear c: Double) -> Double {
        let c = max(c, 0)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}

/// What `_blenderkit_render.render_animation` wrote when it finished.
public struct RenderAnimationResult: Decodable, Equatable, Sendable {
    /// "video" or "images".
    public var kind: String
    /// The video file, or the folder of frames.
    public var path: String
    public var frames: Int
    public var total: Int
    public var cancelled: Bool
    /// The last frame written, for an image sequence.
    public var last: String?
    public var error: String?
    public var fps: Double

    public var isVideo: Bool { kind == "video" }

    public static func parse(_ text: String) -> RenderAnimationResult? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RenderAnimationResult.self, from: data)
    }
}

/// The frame Render Animation is on, as its `render_pre` handler writes it:
/// "index total frame".
public struct RenderAnimationFrame: Equatable, Sendable {
    public var index: Int
    public var total: Int
    public var frame: Int

    public init?(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        guard parts.count == 3, parts[1] > 0 else { return nil }
        index = parts[0]; total = parts[1]; frame = parts[2]
    }

    /// "Frame 12 of 250".
    public var text: String { "Frame \(index) of \(total)" }

    /// How far the whole animation is, with the frame in hand `within` done.
    public func fraction(within: Double?) -> Double {
        let done = Double(max(index - 1, 0)) + min(max(within ?? 0, 0), 1)
        return min(max(done / Double(total), 0), 1)
    }
}
