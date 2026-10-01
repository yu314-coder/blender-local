import Foundation
import simd

/// How Blender draws an object that has no surface: a camera, a light or an
/// empty.
///
/// A mesh reaches the viewport as triangles. These three have none. Blender
/// draws them entirely in its overlay engine, from their settings
/// (`draw/engines/overlay/overlay_camera.hh`, `overlay_light.hh` and
/// `overlay_empty.hh`), so what the mirror carries for them is those settings,
/// and `ObjectOverlays` turns them into the lines Blender draws.
///
/// On the wire a display is a record of `key=value` pairs joined by `;`, keyed
/// by Blender's own property names (`_blenderkit_sync._display_record` writes
/// it, and so does the simulator's shim). The values are numbers and enum
/// identifiers, never text a user typed, so a record needs no escaping; the one
/// name a user can type, the data-block's, travels beside it.
public enum ObjectDisplay: Equatable, Sendable {
    case camera(CameraDisplay)
    case light(LightDisplay)
    case empty(EmptyDisplay)

    /// Blender's `Object.type` for this display.
    public var blenderType: String {
        switch self {
        case .camera: return "CAMERA"
        case .light:  return "LIGHT"
        case .empty:  return "EMPTY"
        }
    }

    /// The camera's or light's data-block. An empty has no data.
    public var dataName: String? {
        switch self {
        case .camera(let c): return c.dataName
        case .light(let l):  return l.dataName
        case .empty:         return nil
        }
    }

    /// The same display, holding a data-block of another name.
    public func withDataName(_ name: String?) -> ObjectDisplay {
        switch self {
        case .camera(var c):
            if let name { c.dataName = name }
            return .camera(c)
        case .light(var l):
            if let name { l.dataName = name }
            return .light(l)
        case .empty:
            return self
        }
    }

    /// Reads a record. Nil for a type Blender draws from its mesh.
    ///
    /// A key that is missing, or a value that does not parse, keeps Blender's
    /// default rather than failing the whole object: a camera drawn with one
    /// setting at its default is better than a camera not drawn at all.
    public init?(type: String, dataName: String, record: String) {
        let fields = DisplayRecord.fields(record)
        switch type {
        case "CAMERA": self = .camera(CameraDisplay(dataName: dataName, fields: fields))
        case "LIGHT":  self = .light(LightDisplay(dataName: dataName, fields: fields))
        case "EMPTY":  self = .empty(EmptyDisplay(fields: fields))
        default: return nil
        }
    }

    /// The record this display is written as — what the shim reads back.
    public var record: String {
        switch self {
        case .camera(let c): return DisplayRecord.format(c.fields)
        case .light(let l):  return DisplayRecord.format(l.fields)
        case .empty(let e):  return DisplayRecord.format(e.fields)
        }
    }

    /// The SF Symbol standing in for the icon Blender's Outliner gives the
    /// data-block (`outliner_draw.cc`, `tree_element_get_icon_from_id`):
    /// OUTLINER_DATA_CAMERA, and LIGHT_POINT, LIGHT_SUN, LIGHT_SPOT or
    /// LIGHT_AREA by the light's type.
    public var outlinerDataIcon: String {
        switch self {
        case .camera:       return "camera.fill"
        case .light(let l): return l.kind.icon
        case .empty:        return "plus"
        }
    }
}

/// The `key=value;key=value` form a display travels in.
enum DisplayRecord {
    static func fields(_ record: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in record.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return fields
    }

    static func format(_ fields: [(String, String)]) -> String {
        fields.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
    }

    static func number(_ v: Float) -> String { "\(v)" }
    static func flag(_ v: Bool) -> String { v ? "1" : "0" }
    static func vector(_ v: [Float]) -> String { v.map(number).joined(separator: ",") }

    static func float(_ fields: [String: String], _ key: String, _ fallback: Float) -> Float {
        fields[key].flatMap { Float($0) } ?? fallback
    }

    static func bool(_ fields: [String: String], _ key: String, _ fallback: Bool) -> Bool {
        guard let text = fields[key] else { return fallback }
        return text == "1" || text == "True" || text == "true"
    }

    static func floats(_ fields: [String: String], _ key: String, count: Int) -> [Float]? {
        guard let parts = fields[key]?.split(separator: ",").compactMap({ Float($0) }),
              parts.count == count else { return nil }
        return parts
    }

    static func choice<T: RawRepresentable>(_ fields: [String: String], _ key: String,
                                            _ fallback: T) -> T where T.RawValue == String {
        fields[key].flatMap(T.init(rawValue:)) ?? fallback
    }
}

// MARK: - Camera

/// A camera's settings, as far as drawing it needs them.
///
/// The defaults are what `bpy.ops.object.camera_add` leaves on a new camera in
/// Blender 5.2.1, measured rather than read out of the DNA files.
public struct CameraDisplay: Equatable, Sendable {
    /// `Camera.type`.
    public enum Projection: String, CaseIterable, Sendable {
        case perspective = "PERSP", orthographic = "ORTHO", panoramic = "PANO"
    }

    /// `Camera.sensor_fit`.
    public enum SensorFit: String, CaseIterable, Sendable {
        case auto = "AUTO", horizontal = "HORIZONTAL", vertical = "VERTICAL"
    }

    public var dataName = "Camera"
    public var projection = Projection.perspective
    public var lens: Float = 50
    public var sensorFit = SensorFit.auto
    public var sensorWidth: Float = 36
    public var sensorHeight: Float = 24
    public var orthoScale: Float = 6
    public var clipStart: Float = 0.1
    public var clipEnd: Float = 1000
    public var shiftX: Float = 0
    public var shiftY: Float = 0
    /// `Camera.display_size`, Blender's `drawsize`.
    public var displaySize: Float = 1
    /// `Camera.show_limits`: the clipping range and focus point, drawn.
    public var showLimits = false
    /// `BKE_camera_object_dof_distance`: where the limits draw the focus cross.
    public var focusDistance: Float = 10
    /// The frame's shape, which is the scene's rather than the camera's:
    /// `render.resolution_x * render.pixel_aspect_x`, and the same for y.
    public var aspectX: Float = 1920
    public var aspectY: Float = 1080
    /// Whether this is `scene.camera`, which Blender marks with a filled
    /// triangle instead of an outlined one.
    public var isSceneCamera = false

    public init() {}

    init(dataName: String, fields f: [String: String]) {
        self.dataName = dataName
        projection = DisplayRecord.choice(f, "type", projection)
        lens = DisplayRecord.float(f, "lens", lens)
        sensorFit = DisplayRecord.choice(f, "sensor_fit", sensorFit)
        sensorWidth = DisplayRecord.float(f, "sensor_width", sensorWidth)
        sensorHeight = DisplayRecord.float(f, "sensor_height", sensorHeight)
        orthoScale = DisplayRecord.float(f, "ortho_scale", orthoScale)
        clipStart = DisplayRecord.float(f, "clip_start", clipStart)
        clipEnd = DisplayRecord.float(f, "clip_end", clipEnd)
        shiftX = DisplayRecord.float(f, "shift_x", shiftX)
        shiftY = DisplayRecord.float(f, "shift_y", shiftY)
        displaySize = DisplayRecord.float(f, "display_size", displaySize)
        showLimits = DisplayRecord.bool(f, "show_limits", showLimits)
        focusDistance = DisplayRecord.float(f, "focus_distance", focusDistance)
        aspectX = DisplayRecord.float(f, "aspect_x", aspectX)
        aspectY = DisplayRecord.float(f, "aspect_y", aspectY)
        isSceneCamera = DisplayRecord.bool(f, "scene_camera", isSceneCamera)
    }

    var fields: [(String, String)] {
        [("type", projection.rawValue), ("lens", DisplayRecord.number(lens)),
         ("sensor_fit", sensorFit.rawValue),
         ("sensor_width", DisplayRecord.number(sensorWidth)),
         ("sensor_height", DisplayRecord.number(sensorHeight)),
         ("ortho_scale", DisplayRecord.number(orthoScale)),
         ("clip_start", DisplayRecord.number(clipStart)),
         ("clip_end", DisplayRecord.number(clipEnd)),
         ("shift_x", DisplayRecord.number(shiftX)), ("shift_y", DisplayRecord.number(shiftY)),
         ("display_size", DisplayRecord.number(displaySize)),
         ("show_limits", DisplayRecord.flag(showLimits)),
         ("focus_distance", DisplayRecord.number(focusDistance)),
         ("aspect_x", DisplayRecord.number(aspectX)), ("aspect_y", DisplayRecord.number(aspectY)),
         ("scene_camera", DisplayRecord.flag(isSceneCamera))]
    }

    /// The camera's frame in its own space: Blender's `BKE_camera_view_frame_ex`
    /// (`blenkernel/intern/camera.cc`), line for line.
    ///
    /// The corners come top-right, bottom-right, bottom-left, top-left, as
    /// Blender's do. The returned `drawSize` is the size the triangle above
    /// the frame is measured in.
    ///
    /// The overlay draws the frame at the camera's display size
    /// (`overlay_camera.hh` passes `cam.drawsize`), which is the default here.
    /// `Camera.view_frame(scene=…)` always passes 1 (`BKE_camera_view_frame`),
    /// so with `drawSize: 1` and a unit `scale` these are exactly its corners —
    /// which is how the Blender check holds this to Blender.
    public func viewFrame(drawSize requested: Float? = nil,
                          scale: SIMD3<Float> = .one) -> (corners: [SIMD3<Float>], drawSize: Float) {
        let displaySize = requested ?? self.displaySize
        let aspX = max(aspectX, 1e-6), aspY = max(aspectY, 1e-6)
        // BKE_camera_sensor_fit: AUTO follows the longer side of the render.
        let fit = sensorFit == .auto ? (aspX >= aspY ? SensorFit.horizontal : .vertical) : sensorFit
        let asp = fit == .horizontal ? SIMD2<Float>(1, aspY / aspX) : SIMD2<Float>(aspX / aspY, 1)

        let facX, facY, depth, drawSize: Float
        let shift: SIMD2<Float>
        if projection == .orthographic {
            facX = 0.5 * orthoScale * asp.x * scale.x
            facY = 0.5 * orthoScale * asp.y * scale.y
            shift = SIMD2(shiftX * orthoScale * scale.x, shiftY * orthoScale * scale.y)
            depth = -displaySize * scale.z
            drawSize = 0.5 * orthoScale
        } else {
            // The sensor Blender measures against is picked by the camera's
            // own fit, not the resolved one: AUTO uses the width.
            let halfSensor = 0.5 * (sensorFit == .vertical ? sensorHeight : sensorWidth)
            // Fixed size, variable depth, so it stays a reasonable size.
            drawSize = (displaySize / 2) / ((scale.x + scale.y + scale.z) / 3)
            depth = drawSize * lens / -max(halfSensor, 1e-6) * scale.z
            facX = drawSize * asp.x * scale.x
            facY = drawSize * asp.y * scale.y
            shift = SIMD2(shiftX * drawSize * 2 * scale.x, shiftY * drawSize * 2 * scale.y)
        }
        let corners = [SIMD3(shift.x + facX, shift.y + facY, depth),
                       SIMD3(shift.x + facX, shift.y - facY, depth),
                       SIMD3(shift.x - facX, shift.y - facY, depth),
                       SIMD3(shift.x - facX, shift.y + facY, depth)]
        return (corners, drawSize)
    }
}

// MARK: - Light

/// A light's settings, as far as drawing it needs them — plus colour and
/// energy, which the mirror carries so the shim's `bpy` can answer for them.
public struct LightDisplay: Equatable, Sendable {
    /// `Light.type`.
    public enum Kind: String, CaseIterable, Sendable {
        case point = "POINT", sun = "SUN", spot = "SPOT", area = "AREA"

        /// Blender's label, which is also the name `light_add` gives the
        /// object and its data (`get_light_defname` in `object_add.cc`).
        public var label: String {
            switch self {
            case .point: return "Point"
            case .sun:   return "Sun"
            case .spot:  return "Spot"
            case .area:  return "Area"
            }
        }

        /// SF Symbols standing in for LIGHT_POINT, LIGHT_SUN, LIGHT_SPOT and
        /// LIGHT_AREA.
        public var icon: String {
            switch self {
            case .point: return "lightbulb"
            case .sun:   return "sun.max"
            case .spot:  return "flashlight.on.fill"
            case .area:  return "light.panel"
            }
        }
    }

    /// `AreaLight.shape`.
    public enum Shape: String, CaseIterable, Sendable {
        case square = "SQUARE", rectangle = "RECTANGLE", disk = "DISK", ellipse = "ELLIPSE"

        public var label: String { rawValue.prefix(1) + rawValue.dropFirst().lowercased() }
    }

    public var dataName = "Point"
    public var kind = Kind.point
    public var color = SIMD3<Float>(1, 1, 1)
    public var energy: Float = 10
    /// `shadow_soft_size`, which Blender's C calls `radius`. 0 in 5.2.1.
    public var radius: Float = 0
    public var spotSize: Float = .pi / 4
    public var spotBlend: Float = 0.15
    public var showCone = false
    public var shape = Shape.square
    public var size: Float = 0.25
    public var sizeY: Float = 0.25
    /// `cutoff_distance` and `shadow_buffer_clip_start`, Blender's `att_dist`
    /// and `clipsta`: where a spot's or an area light's direction line starts
    /// and ends.
    public var cutoffDistance: Float = 40
    public var clipStart: Float = 0.05

    public init() {}

    init(dataName: String, fields f: [String: String]) {
        self.dataName = dataName
        kind = DisplayRecord.choice(f, "type", kind)
        if let c = DisplayRecord.floats(f, "color", count: 3) { color = SIMD3(c[0], c[1], c[2]) }
        energy = DisplayRecord.float(f, "energy", energy)
        radius = DisplayRecord.float(f, "shadow_soft_size", radius)
        spotSize = DisplayRecord.float(f, "spot_size", spotSize)
        spotBlend = DisplayRecord.float(f, "spot_blend", spotBlend)
        showCone = DisplayRecord.bool(f, "show_cone", showCone)
        shape = DisplayRecord.choice(f, "shape", shape)
        size = DisplayRecord.float(f, "size", size)
        sizeY = DisplayRecord.float(f, "size_y", sizeY)
        cutoffDistance = DisplayRecord.float(f, "cutoff_distance", cutoffDistance)
        clipStart = DisplayRecord.float(f, "shadow_buffer_clip_start", clipStart)
    }

    var fields: [(String, String)] {
        [("type", kind.rawValue), ("color", DisplayRecord.vector([color.x, color.y, color.z])),
         ("energy", DisplayRecord.number(energy)),
         ("shadow_soft_size", DisplayRecord.number(radius)),
         ("spot_size", DisplayRecord.number(spotSize)),
         ("spot_blend", DisplayRecord.number(spotBlend)),
         ("show_cone", DisplayRecord.flag(showCone)),
         ("shape", shape.rawValue), ("size", DisplayRecord.number(size)),
         ("size_y", DisplayRecord.number(sizeY)),
         ("cutoff_distance", DisplayRecord.number(cutoffDistance)),
         ("shadow_buffer_clip_start", DisplayRecord.number(clipStart))]
    }
}

// MARK: - Empty

/// An empty's display type and size.
public struct EmptyDisplay: Equatable, Sendable {
    /// `Object.empty_display_type`, in Blender's order.
    public enum Kind: String, CaseIterable, Sendable {
        case plainAxes = "PLAIN_AXES", arrows = "ARROWS", singleArrow = "SINGLE_ARROW"
        case circle = "CIRCLE", cube = "CUBE", sphere = "SPHERE", cone = "CONE", image = "IMAGE"

        public var label: String {
            switch self {
            case .plainAxes:   return "Plain Axes"
            case .arrows:      return "Arrows"
            case .singleArrow: return "Single Arrow"
            case .circle:      return "Circle"
            case .cube:        return "Cube"
            case .sphere:      return "Sphere"
            case .cone:        return "Cone"
            case .image:       return "Image"
            }
        }

        /// SF Symbols standing in for the icons `VIEW3D_MT_empty_add` uses:
        /// EMPTY_AXIS, EMPTY_ARROWS, EMPTY_SINGLE_ARROW, MESH_CIRCLE, CUBE,
        /// SPHERE and CONE.
        public var icon: String {
            switch self {
            case .plainAxes:   return "plus"
            case .arrows:      return "move.3d"
            case .singleArrow: return "arrow.up"
            case .circle:      return "circle"
            case .cube:        return "cube"
            case .sphere:      return "globe"
            case .cone:        return "cone"
            case .image:       return "photo"
            }
        }

        /// What Blender's Add ▸ Empty menu offers: every type but Image, which
        /// has an Add ▸ Image menu of its own (`VIEW3D_MT_empty_add`).
        public static var addMenu: [Kind] { allCases.filter { $0 != .image } }
    }

    public var kind = Kind.plainAxes
    /// `Object.empty_display_size`.
    public var size: Float = 1
    /// `Object.empty_image_offset`, for an image empty's frame.
    public var imageOffset = SIMD2<Float>(-0.5, -0.5)
    /// The image's proportions, as `calc_image_aspect` in `overlay_empty.hh`
    /// works them out: 1 along the longer side.
    public var imageAspect = SIMD2<Float>(1, 1)
    /// `instance_type` is COLLECTION and `instance_collection` is set: the one
    /// kind of empty Set Origin moves (`Bpy.originReach`).
    public var instancesCollection = false

    public init() {}

    init(fields f: [String: String]) {
        kind = DisplayRecord.choice(f, "empty_display_type", kind)
        size = DisplayRecord.float(f, "empty_display_size", size)
        if let o = DisplayRecord.floats(f, "empty_image_offset", count: 2) { imageOffset = SIMD2(o[0], o[1]) }
        if let a = DisplayRecord.floats(f, "image_aspect", count: 2) { imageAspect = SIMD2(a[0], a[1]) }
        instancesCollection = DisplayRecord.bool(f, "instances_collection", instancesCollection)
    }

    var fields: [(String, String)] {
        [("empty_display_type", kind.rawValue),
         ("empty_display_size", DisplayRecord.number(size)),
         ("empty_image_offset", DisplayRecord.vector([imageOffset.x, imageOffset.y])),
         ("image_aspect", DisplayRecord.vector([imageAspect.x, imageAspect.y])),
         ("instances_collection", DisplayRecord.flag(instancesCollection))]
    }
}

// MARK: - On objects

public extension BKObject {
    /// The display, while it still describes what Blender says this object is.
    ///
    /// A mirroring pass copies the type and the display over separately, and an
    /// object can come back as something else under the same name, so the two
    /// are checked against each other rather than trusted.
    var overlayDisplay: ObjectDisplay? {
        guard let display, display.blenderType == blenderType else { return nil }
        return display
    }

    /// One vertex at the origin and no faces: what the mirror sends for an
    /// object Blender draws without a surface. It gives the object bounds and a
    /// pivot without inventing geometry to pick or render.
    static var originOnly: MeshData {
        MeshData(vertices: [MeshVertex(.zero, SIMD3(0, 0, 1))], indices: [])
    }

    /// Makes this object a camera, a light or an empty.
    func install(_ display: ObjectDisplay) {
        blenderType = display.blenderType
        self.display = display
        if !(isMirrored && mesh.indices.isEmpty && mesh.vertices.count == 1) {
            setMirroredMesh(Self.originOnly)
        }
    }

    /// A duplicate's display: the source's, with a data-block of its own, as
    /// Blender's Duplicate gives a camera or light (Preferences ▸ Editing ▸
    /// Duplicate Data has both on by default).
    func copyDisplay(from source: BKObject, in scene: BKScene) {
        guard let display = source.overlayDisplay else { return }
        install(display.withDataName(scene.uniqueDataName(display.dataName,
                                                          type: display.blenderType)))
    }
}

public extension BKScene {
    /// A data-block name no other camera, or no other light, already has.
    ///
    /// Blender keeps names unique per kind of data, and numbers a copy from the
    /// name without its suffix: a copy of `Camera.001` is `Camera.002`, not
    /// `Camera.001.001`.
    func uniqueDataName(_ name: String?, type: String) -> String? {
        guard let name else { return nil }
        let taken = Set(objects.compactMap { obj -> String? in
            guard let display = obj.overlayDisplay, display.blenderType == type else { return nil }
            return display.dataName
        })
        guard taken.contains(name) else { return name }
        var base = name
        if let dot = name.lastIndex(of: "."),
           name[name.index(after: dot)...].count == 3,
           name[name.index(after: dot)...].allSatisfy(\.isNumber) {
            base = String(name[..<dot])
        }
        var n = 1
        while taken.contains(String(format: "%@.%03d", base, n)) { n += 1 }
        return String(format: "%@.%03d", base, n)
    }

    /// Adds a camera, light or empty — the shim's `object.camera_add` and its
    /// siblings. Selected and active, as an add leaves it in Blender.
    @discardableResult
    func addObject(_ display: ObjectDisplay, named base: String,
                   at location: SIMD3<Float>, select: Bool = true) -> BKObject {
        let obj = BKObject(name: uniqueName(base), kind: .cube, location: location)
        obj.install(display.withDataName(uniqueDataName(display.dataName, type: display.blenderType)))
        objects.append(obj)
        if select { self.select(only: obj.id) }
        return obj
    }
}

public extension ObjectState {
    /// The display an undo step or the clipboard kept for this object.
    var overlayDisplay: ObjectDisplay? {
        guard let displayType else { return nil }
        return ObjectDisplay(type: displayType, dataName: displayData ?? "",
                             record: displayRecord ?? "")
    }

    /// This state, carrying the object's display too.
    func carryingDisplay(of object: BKObject) -> ObjectState {
        guard let display = object.overlayDisplay else { return self }
        var state = self
        state.displayType = display.blenderType
        state.displayData = display.dataName
        state.displayRecord = display.record
        return state
    }
}
