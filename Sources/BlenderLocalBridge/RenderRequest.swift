import Foundation
import simd

/// What the Render panel asks Blender for, and the Python that asks it.
///
/// Kept apart from the panel so the strings can be checked against real
/// Blender (`scripts/run-render-blender-check.sh`) rather than only against
/// what they were expected to be.
public struct RenderRequest: Equatable, Sendable {

    /// Blender's engine identifiers. The bundled build offers exactly these
    /// three: BLENDER_EEVEE (not the 4.2 name BLENDER_EEVEE_NEXT, which does
    /// not exist here), BLENDER_WORKBENCH and CYCLES.
    public enum Engine: String, CaseIterable, Identifiable, Sendable {
        case cycles = "CYCLES"
        case eevee = "BLENDER_EEVEE"
        case workbench = "BLENDER_WORKBENCH"
        public var id: String { rawValue }
        /// The engine's name in Blender's Render Engine menu (5.2.1).
        public var label: String {
            switch self {
            case .cycles: return "Cycles"
            case .eevee: return "EEVEE"
            case .workbench: return "Workbench"
            }
        }
        /// What it is for, in the panel.
        public var summary: String {
            switch self {
            case .cycles: return "Ray traced: true light, slowest"
            case .eevee: return "Real-time engine: quick, close"
            case .workbench: return "The viewport's own shading, instant"
            }
        }
        /// Whether the scene's lights and materials light the image, so the
        /// panel can say when a render will come out black.
        public var usesSceneLighting: Bool { self != .workbench }
    }

    /// How many samples each engine takes. Blender's own default is 4096
    /// Cycles samples, which is minutes on a tablet; Good is the default here.
    public enum Quality: String, CaseIterable, Identifiable, Sendable {
        case draft = "Draft", good = "Good", best = "Best"
        public var id: String { rawValue }
        public var cyclesSamples: Int {
            switch self {
            case .draft: return 16
            case .good: return 128
            case .best: return 1024
            }
        }
        public var eeveeSamples: Int {
            switch self {
            case .draft: return 8
            case .good: return 64
            case .best: return 256
            }
        }
        /// The most an Eevee render's shadow pool may hold, in MB
        /// (`scene.eevee.shadow_pool_size`, Render ▸ Shadows ▸ Pool Size).
        /// Blender allocates the whole pool up front and its default is 512:
        /// measured on an M4, an Eevee render of the startup cube peaked at
        /// 1,475 MB with 512, 1,094 with 128 and 1,015 with 64, and desktop
        /// 5.2.1 rendering an 82-object scene at 960 × 540 the same (1,531,
        /// 1,079, 1,017 MB) — every picture identical to the 512 one. A scene
        /// that asks for less keeps its own; its setting is put back after.
        public var eeveeShadowPool: Int {
            switch self {
            case .draft: return 64
            case .good: return 128
            case .best: return 256
            }
        }

        /// The samples this quality gives an engine; nil for Workbench,
        /// whose anti-aliasing is not a sample count here.
        public func samples(for engine: Engine) -> Int? {
            switch engine {
            case .cycles: return cyclesSamples
            case .eevee: return eeveeSamples
            case .workbench: return nil
            }
        }

        /// The quality the scene's own samples are, if they are one of the
        /// three: the Render panel's chip reads the scene's Render Properties
        /// ▸ Sampling, and shows the number when it is none of them.
        public static func matching(samples: Int, engine: Engine) -> Quality? {
            allCases.first { $0.samples(for: engine) == samples }
        }
    }

    /// Which camera the image is taken from.
    public enum Source: Equatable, Sendable {
        /// `scene.camera`, as pressing F12 in Blender does.
        case sceneCamera
        /// A camera made to match the 3D View, used for this render and then
        /// removed — the view you are looking at, rendered.
        case view(ViewCamera)
    }

    /// Where the 3D View is and what it can see, in Blender's terms.
    public struct ViewCamera: Equatable, Sendable {
        public var location: SIMD3<Float>
        /// XYZ Euler, as `ObjectAdd.eulerXYZ` gives it for the view.
        public var rotation: SIMD3<Float>
        /// The vertical angle the viewport shows, radians.
        public var fovY: Float
        public var isOrthographic: Bool
        /// Height the orthographic view covers at the centre, metres.
        public var orthoScale: Float

        public init(location: SIMD3<Float>, rotation: SIMD3<Float>, fovY: Float,
                    isOrthographic: Bool = false, orthoScale: Float = 6) {
            self.location = location
            self.rotation = rotation
            self.fovY = fovY
            self.isOrthographic = isOrthographic
            self.orthoScale = orthoScale
        }
    }

    /// Render Animation (Ctrl+F12): Blender's `render.render(animation=True)`
    /// over the scene's frame range, through `_blenderkit_render.render_animation`.
    public struct Animation: Equatable, Sendable {
        /// An MPEG-4 H.264 video whatever the Output says — the app's default
        /// while the scene's Output is Blender's untouched one
        /// (`RenderSettings.outputUntouched`); otherwise the scene's own
        /// File Format: a video, or a folder of numbered frames.
        public var video: Bool
        /// A file the frame being rendered is written to ("index total frame").
        public var frames: String?
        /// A file whose existence stops the render after the frame in hand.
        public var cancel: String?
        /// A file the outcome is written to, as JSON (`RenderAnimationResult`).
        public var result: String?
        /// Frame Start and End for this render only (Test All Features' three
        /// frames); nil renders the scene's own range, as the panel does.
        public var range: ClosedRange<Int>?

        public init(video: Bool, frames: String? = nil, cancel: String? = nil, result: String? = nil,
                    range: ClosedRange<Int>? = nil) {
            self.video = video
            self.frames = frames
            self.cancel = cancel
            self.result = result
            self.range = range
        }
    }

    /// Cycles' Device (Render Properties ▸ Device): GPU Compute, which is
    /// Metal here, or the CPU.
    public enum CyclesDevice: String, Sendable {
        case gpu = "GPU", cpu = "CPU"
    }

    public var engine: Engine = .cycles
    /// The samples for this render only; nil renders with the scene's own
    /// (Render Properties ▸ Sampling), which is what the Render panel does.
    public var quality: Quality?
    /// The size for this render only; nil renders at the scene's own
    /// Resolution X, Y and % (Output Properties ▸ Format).
    public var width: Int?
    public var height: Int?
    /// Cycles' device for this render. The panel passes the scene's own.
    public var cyclesDevice: CyclesDevice = .gpu
    public var source: Source = .sceneCamera
    /// Where the PNG goes; for an animation, the path without an extension
    /// (`Animation`).
    public var output: String
    /// A file the script writes the device it rendered on into, for the panel
    /// to show. Nothing is written when it is nil.
    public var deviceReport: String?
    /// A file Blender's own render progress is written to as it goes —
    /// "Rendering 25 / 128 samples" — for the panel to read while it waits.
    public var progressReport: String?
    /// Render Animation rather than Render Image.
    public var animation: Animation?

    public init(engine: Engine = .cycles, quality: Quality? = nil,
                width: Int? = nil, height: Int? = nil,
                cyclesDevice: CyclesDevice = .gpu,
                source: Source = .sceneCamera, output: String,
                deviceReport: String? = nil, progressReport: String? = nil,
                animation: Animation? = nil) {
        self.engine = engine
        self.quality = quality
        self.width = width
        self.height = height
        self.cyclesDevice = cyclesDevice
        self.source = source
        self.output = output
        self.deviceReport = deviceReport
        self.progressReport = progressReport
        self.animation = animation
    }

    /// The name a render is saved under: the date, so a folder of them reads
    /// in order and nothing is overwritten.
    public static func fileName(at date: Date = Date()) -> String {
        "Render \(stamp(date)).png"
    }

    /// An animation's name, without its extension: Blender adds the video's
    /// (.mp4, .mov), or it is the folder its numbered frames go in.
    public static func animationName(at date: Date = Date()) -> String {
        "Animation \(stamp(date))"
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }

    /// Cycles renders on the CPU unless its Metal device is turned on.
    ///
    /// Blender starts with `compute_device_type` at NONE and
    /// `scene.cycles.device` at CPU, so until this ran every Cycles render in
    /// the app was a CPU render — measured, and 2.9× slower than Metal on the
    /// same scene. Eevee and Workbench draw with the GPU by their nature.
    ///
    /// Everything is wrapped: a build without Cycles, or a device with no
    /// Metal, falls back to the CPU and says so rather than failing the render.
    var deviceLines: [String] {
        guard engine == .cycles else {
            return ["_device = \(Bpy.quote(engine.label + " on the GPU"))"]
        }
        // The scene's Device: CPU renders on the CPU, as in Blender.
        guard cyclesDevice == .gpu else {
            return ["scene.cycles.device = 'CPU'",
                    "_device = 'Cycles on the CPU'",
                    "print('Render device:', _device)"]
        }
        return [
            "_device = 'CPU'",
            "try:",
            "    _prefs = bpy.context.preferences.addons['cycles'].preferences",
            "    _prefs.compute_device_type = 'METAL'",
            "    if hasattr(_prefs, 'refresh_devices'):",
            "        _prefs.refresh_devices()",
            "    else:",
            "        _prefs.get_devices()",
            "    for _d in _prefs.devices:",
            "        _d.use = _d.type == 'METAL'",
            "    _metal = [_d for _d in _prefs.devices if _d.type == 'METAL']",
            "    scene.cycles.device = 'GPU' if _metal else 'CPU'",
            "    _device = ('Cycles on ' + _metal[0].name) if _metal else 'Cycles on the CPU: no Metal device'",
            "except Exception as _error:",
            "    scene.cycles.device = 'CPU'",
            "    _device = 'Cycles on the CPU: %s' % _error",
            "print('Render device:', _device)",
        ]
    }

    /// The temporary camera's name. Blender makes the name unique if it is
    /// taken, and the script removes the object it made rather than one found
    /// by name, so a clash cannot delete the user's camera.
    static let viewCameraName = "3D View Render"

    /// The whole render, as one script.
    ///
    /// The view camera is made, used and removed here rather than through the
    /// interface, so a failed render cannot leave it behind: the removal and
    /// the restored `scene.camera` are in a `finally`.
    public var python: String {
        // What the render sets for itself is put back after it
        // (`_blenderkit_render.save`/`restore`): Blender's F12 and Ctrl+F12
        // change no setting, and the panel's renders used to leave the
        // engine, size, samples, format and output path as they set them.
        var lines = ["import bpy", "import _blenderkit_render", "scene = bpy.context.scene"]
        switch source {
        case .sceneCamera:
            lines.append("if scene.camera is None:")
            lines.append(animation == nil
                ? "    raise RuntimeError(\"This scene has no camera. Add ▸ Camera, or render from the 3D Viewport.\")"
                : "    raise RuntimeError(\"This scene has no camera. Add ▸ Camera, then Render Animation.\")")
        case .view(let view):
            lines += [
                "_data = bpy.data.cameras.new(\(Bpy.quote(Self.viewCameraName)))",
                // The viewport shows a vertical angle, so the camera is fitted
                // vertically: what the 3D View has top to bottom is what the
                // render has, and a wider frame shows more to the sides.
                "_data.sensor_fit = 'VERTICAL'",
                String(format: "_data.angle_y = %.6f", view.fovY),
                "_data.type = \(view.isOrthographic ? "'ORTHO'" : "'PERSP'")",
                String(format: "_data.ortho_scale = %.4f", view.orthoScale),
                "_camera = bpy.data.objects.new(\(Bpy.quote(Self.viewCameraName)), _data)",
                "scene.collection.objects.link(_camera)",
                String(format: "_camera.location = (%.4f, %.4f, %.4f)",
                       view.location.x, view.location.y, view.location.z),
                String(format: "_camera.rotation_euler = (%.4f, %.4f, %.4f)",
                       view.rotation.x, view.rotation.y, view.rotation.z),
                "_was = scene.camera",
                "scene.camera = _camera",
            ]
        }
        lines += ["_bk_saved = _blenderkit_render.save(scene)",
                  "scene.render.engine = \(Bpy.quote(engine.rawValue))"]
        if let width, let height {
            lines += ["scene.render.resolution_x = \(width)",
                      "scene.render.resolution_y = \(height)",
                      "scene.render.resolution_percentage = 100"]
        }
        if let range = animation?.range {
            lines += ["scene.frame_start = \(range.lowerBound)",
                      "scene.frame_end = \(range.upperBound)",
                      "scene.frame_step = 1"]
        }
        if animation == nil {
            // A still is read back as a PNG. In 5.x a video Output has to
            // become an image one first: PNG is refused while the media type
            // is Video.
            lines += ["if getattr(scene.render.image_settings, 'media_type', 'IMAGE') != 'IMAGE':",
                      "    scene.render.image_settings.media_type = 'IMAGE'",
                      "scene.render.image_settings.file_format = 'PNG'",
                      "scene.render.filepath = \(Bpy.quote(output))"]
        }
        if let quality {
            lines += [
                // Cycles is an add-on: its settings are only there once it is
                // the engine, and a build without it has none at all.
                "if hasattr(scene, 'cycles'):",
                "    scene.cycles.samples = \(quality.cyclesSamples)",
                "    scene.cycles.use_adaptive_sampling = True",
                "if hasattr(scene, 'eevee'):",
                "    scene.eevee.taa_render_samples = \(quality.eeveeSamples)",
            ]
        }
        // Eevee's shadow pool, held to a size for this render
        // (`Quality.eeveeShadowPool`; Good's 128 MB with the scene's own
        // samples — the pool changes no pixel, measured, only the memory)
        // and put back after, even if it raises.
        var cleanup = ["    _blenderkit_render.restore(scene, _bk_saved)"]
        if engine == .eevee {
            let pool = (quality ?? .good).eeveeShadowPool
            lines += [
                "_bk_pool = getattr(getattr(scene, 'eevee', None), 'shadow_pool_size', None)",
                "if _bk_pool is not None and int(_bk_pool) > \(pool):",
                "    scene.eevee.shadow_pool_size = '\(pool)'",
            ]
            cleanup += ["    if _bk_pool is not None:",
                        "        scene.eevee.shadow_pool_size = _bk_pool"]
        }
        lines += deviceLines
        if let deviceReport {
            lines += ["try:",
                      "    open(\(Bpy.quote(deviceReport)), 'w').write(_device)",
                      "except Exception:",
                      "    pass"]
        }
        // Blender says how far along it is — "Rendering 25 / 128 samples" —
        // through the render_stats handler, on the thread the render blocks.
        // Written to a file because that thread is not the interface's.
        if let progressReport {
            lines += [
                "def _bk_progress(_text, _extra=None):",
                "    try:",
                "        with open(\(Bpy.quote(progressReport)), 'w') as _f:",
                "            _f.write(str(_text))",
                "    except Exception:",
                "        pass",
                "bpy.app.handlers.render_stats.append(_bk_progress)",
            ]
            // A handler left behind would write into a stale file for every
            // later render, so it goes even if the render raises.
            cleanup += ["    if _bk_progress in bpy.app.handlers.render_stats:",
                        "        bpy.app.handlers.render_stats.remove(_bk_progress)"]
        }
        if case .view = source {
            cleanup += ["    scene.camera = _was",
                        "    bpy.data.objects.remove(_camera)",
                        "    bpy.data.cameras.remove(_data)"]
        }
        let render: String
        if let animation {
            func optional(_ path: String?) -> String { path.map(Bpy.quote) ?? "None" }
            render = "_blenderkit_render.render_animation(\(Bpy.quote(output)), "
                + "video=\(animation.video ? "True" : "False"), frames=\(optional(animation.frames)), "
                + "cancel=\(optional(animation.cancel)), result=\(optional(animation.result)))"
        } else {
            render = "bpy.ops.render.render(write_still=True)"
        }
        lines += ["try:", "    " + render, "finally:"] + cleanup
        return lines.joined(separator: "\n")
    }
}

/// Cycles' Metal kernels: compiled the first time Cycles renders on the GPU
/// of a device — minutes, once, cached afterwards. The Render panel warns
/// before that render; a script's render is warned in the console, by the
/// same words, through `_blenderkit_cycles` (BpySession arms it before a run
/// that may render and reads it back after).
public enum CyclesKernels {
    /// The defaults key both remember it under: the Render panel's
    /// `@AppStorage` and the scripts' warning.
    public static let builtKey = "bl_cycles_kernels_built"

    /// The Render panel's warning, word for word.
    public static let warning = "Cycles renders on the GPU. The first one builds its shaders, which takes a few "
        + "minutes once; every render after that is quick. EEVEE needs no wait."

    /// Whether a Cycles render has finished on this device's GPU.
    public static var built: Bool {
        get { UserDefaults.standard.bool(forKey: builtKey) }
        set { UserDefaults.standard.set(newValue, forKey: builtKey) }
    }

    /// Whether `source` may render: as blunt as `ScriptThread.mayStartGPU`,
    /// since a false match only arms a handler that never fires.
    public static func mayRender(_ source: String) -> Bool {
        source.contains("render.render")
    }

    /// Run before such a script: the warning goes out before its first Cycles
    /// render on the GPU (a `render_pre` handler).
    public static var arm: String {
        "import _blenderkit_cycles\n_blenderkit_cycles.arm(\(Bpy.quote(warning)))"
    }

    /// Run after it: prints True when a Cycles render finished on the GPU.
    public static let disarm = "import _blenderkit_cycles\nprint(_blenderkit_cycles.disarm())"

    /// Whether `disarm` said a render finished on the GPU.
    public static func finishedOnGPU(_ printed: [String]) -> Bool {
        printed.contains { $0.trimmingCharacters(in: .whitespaces) == "True" }
    }
}

public extension Bpy {
    /// `scene.camera = <object>`, which is what a render goes through.
    static func setSceneCamera(_ name: String) -> String {
        "bpy.context.scene.camera = bpy.data.objects[\(quote(name))]"
    }

    /// Aims a camera the way the 3D View is looking, as Blender's
    /// Align Active Camera to View does: the view's world placement is
    /// written as the object's world matrix (`BKE_object_apply_mat4`, which
    /// Blender's operator and `matrix_world` both use), so it goes through
    /// the camera's parent and into whatever rotation mode it uses.
    ///
    /// The view's world values were written into the local channels, which
    /// is right only for an unparented camera rotated by XYZ Euler. Round 3's
    /// review measured 10.2 m and 78.1° off on a parented camera, and 63° on
    /// one rotated by quaternion (`rotation_euler` is not what turns it).
    /// The simulator's stand-in has neither parents nor rotation modes, and
    /// no world matrix to write: it takes the channels as before.
    static func alignCameraToView(_ name: String, _ view: RenderRequest.ViewCamera) -> String {
        let l = view.location, r = view.rotation
        return """
        _bk_o = bpy.data.objects[\(quote(name))]
        _bk_loc = \(String(format: "(%.6f, %.6f, %.6f)", l.x, l.y, l.z))
        _bk_rot = \(String(format: "(%.6f, %.6f, %.6f)", r.x, r.y, r.z))
        if hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type'):
            from mathutils import Euler as _bk_Euler, Matrix as _bk_Matrix
            # The parent's world matrix as Blender holds it now, not as the
            # last evaluation left it.
            bpy.context.view_layer.update()
            _bk_o.matrix_world = _bk_Matrix.Translation(_bk_loc) @ _bk_Euler(_bk_rot, 'XYZ').to_matrix().to_4x4()
        else:
            _bk_o.location = _bk_loc
            _bk_o.rotation_euler = _bk_rot
        """
    }

    /// A value on the data-block a camera or light object carries — `energy`,
    /// `lens`, `spot_size` and the rest. `bpy.data.objects[…].data` is the
    /// data-block itself, so one form covers both and matches what the mirror
    /// reads back.
    static func setObjectData(_ name: String, _ key: String, _ value: Float) -> String {
        String(format: "bpy.data.objects[%@].data.%@ = %.4f", quote(name), key, value)
    }

    static func setObjectData(_ name: String, _ key: String, choice: String) -> String {
        "bpy.data.objects[\(quote(name))].data.\(key) = \(quote(choice))"
    }

    static func setObjectData(_ name: String, _ key: String, colour: SIMD3<Float>) -> String {
        String(format: "bpy.data.objects[%@].data.%@ = (%.4f, %.4f, %.4f)",
               quote(name), key, colour.x, colour.y, colour.z)
    }
}

public extension CameraDisplay {
    /// The vertical angle this camera sees, at its own frame's aspect.
    ///
    /// Blender fits the sensor to the frame: `sensor_width` across for a
    /// landscape frame, and for a portrait one the same number becomes the
    /// height (`BKE_camera_sensor_size`).
    var verticalAngle: Float {
        let aspect = max(aspectX, 1e-6) / max(aspectY, 1e-6)
        let lens = max(self.lens, 1e-6)
        let fitsHorizontally: Bool
        switch sensorFit {
        case .horizontal: fitsHorizontally = true
        case .vertical:   fitsHorizontally = false
        case .auto:       fitsHorizontally = aspect >= 1
        }
        if fitsHorizontally {
            let horizontal = 2 * atan(sensorWidth / 2 / lens)
            return 2 * atan(tan(horizontal / 2) / aspect)
        }
        let sensor = sensorFit == .vertical ? sensorHeight : sensorWidth
        return 2 * atan(sensor / 2 / lens)
    }

    /// How much an orthographic camera shows top to bottom, metres.
    /// `ortho_scale` is the frame's longer side.
    var verticalExtent: Float {
        let aspect = max(aspectX, 1e-6) / max(aspectY, 1e-6)
        return aspect >= 1 ? orthoScale / aspect : orthoScale
    }
}

public extension BKScene {
    /// Every camera in the scene, in the order the outliner shows them.
    var cameras: [BKObject] {
        objects.filter { if case .camera = $0.overlayDisplay { return true } else { return false } }
    }

    /// The camera a render goes through — Blender's `scene.camera`, which the
    /// mirror marks on the object it belongs to.
    var sceneCamera: BKObject? {
        cameras.first { if case .camera(let c)? = $0.overlayDisplay { return c.isSceneCamera } else { return false } }
    }

    var lights: [BKObject] {
        objects.filter { if case .light = $0.overlayDisplay { return true } else { return false } }
    }
}
