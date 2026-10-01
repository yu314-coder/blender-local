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
        public var label: String {
            switch self {
            case .cycles: return "Cycles"
            case .eevee: return "Eevee"
            case .workbench: return "Solid"
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

    public var engine: Engine = .cycles
    public var quality: Quality = .good
    public var width = 1920
    public var height = 1080
    public var source: Source = .sceneCamera
    /// Where the PNG goes.
    public var output: String
    /// A file the script writes the device it rendered on into, for the panel
    /// to show. Nothing is written when it is nil.
    public var deviceReport: String?
    /// A file Blender's own render progress is written to as it goes —
    /// "Rendering 25 / 128 samples" — for the panel to read while it waits.
    public var progressReport: String?

    public init(engine: Engine = .cycles, quality: Quality = .good,
                width: Int = 1920, height: Int = 1080,
                source: Source = .sceneCamera, output: String,
                deviceReport: String? = nil, progressReport: String? = nil) {
        self.engine = engine
        self.quality = quality
        self.width = width
        self.height = height
        self.source = source
        self.output = output
        self.deviceReport = deviceReport
        self.progressReport = progressReport
    }

    /// The name a render is saved under: the date, so a folder of them reads
    /// in order and nothing is overwritten.
    public static func fileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Render \(f.string(from: date)).png"
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
        var lines = ["import bpy", "scene = bpy.context.scene"]
        switch source {
        case .sceneCamera:
            lines.append("if scene.camera is None:")
            lines.append("    raise RuntimeError(\"This scene has no camera. Add ▸ Camera, or render from the 3D View.\")")
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
        lines += [
            "scene.render.engine = \(Bpy.quote(engine.rawValue))",
            "scene.render.resolution_x = \(width)",
            "scene.render.resolution_y = \(height)",
            "scene.render.resolution_percentage = 100",
            "scene.render.image_settings.file_format = 'PNG'",
            "scene.render.filepath = \(Bpy.quote(output))",
            // Cycles is an add-on: its settings are only there once it is the
            // engine, and a build without it has none at all.
            "if hasattr(scene, 'cycles'):",
            "    scene.cycles.samples = \(quality.cyclesSamples)",
            "    scene.cycles.use_adaptive_sampling = True",
            "if hasattr(scene, 'eevee'):",
            "    scene.eevee.taa_render_samples = \(quality.eeveeSamples)",
        ]
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
        var cleanup: [String] = []
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
        let render = "bpy.ops.render.render(write_still=True)"
        if cleanup.isEmpty {
            lines.append(render)
        } else {
            lines += ["try:", "    " + render, "finally:"] + cleanup
        }
        return lines.joined(separator: "\n")
    }
}

public extension Bpy {
    /// `scene.camera = <object>`, which is what a render goes through.
    static func setSceneCamera(_ name: String) -> String {
        "bpy.context.scene.camera = bpy.data.objects[\(quote(name))]"
    }

    /// Aims a camera the way the 3D View is looking, as Blender's
    /// Align Active Camera to View does.
    static func alignCameraToView(_ name: String, _ view: RenderRequest.ViewCamera) -> String {
        [setLocation(name, view.location), setRotation(name, view.rotation)].joined(separator: "\n")
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
