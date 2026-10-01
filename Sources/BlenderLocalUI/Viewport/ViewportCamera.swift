import Foundation
import simd

/// Blender's turntable camera: the view orbits a pivot point, and Z stays up
/// no matter how far the view is tumbled. This is what makes navigation feel
/// like Blender rather than like a generic 3D viewer.
public struct ViewportCamera {
    /// The orbit pivot — Blender's "view location".
    public var target: SIMD3<Float> = .zero
    public var distance: Float = 11
    /// Rotation about the world Z axis, radians.
    public var azimuth: Float = .pi / 5.2
    /// Angle above the XY plane, radians. Clamped just short of the poles so
    /// the up vector never degenerates.
    public var elevation: Float = .pi / 6.4

    /// Blender's default 50 mm lens on a 36 mm sensor: 2·atan(18/50) ≈ 39.6°.
    public var fovY: Float = 2 * atan(18.0 / 50.0)
    public var near: Float = 0.05
    public var far: Float = 1000

    /// Numpad 5 in Blender. Orthographic drops the perspective divide, which is
    /// what makes the axis views usable for modelling.
    public var isOrthographic = false

    /// The named viewpoints on Blender's numpad.
    public enum Viewpoint: String, CaseIterable, Identifiable {
        case top, bottom, front, back, right, left
        public var id: String { rawValue }

        public var label: String { rawValue.capitalized }

        /// The numpad key Blender binds it to, shown in the menu as Blender
        /// shows it.
        public var shortcut: String {
            switch self {
            case .top:    return "Numpad 7"
            case .bottom: return "Ctrl Numpad 7"
            case .front:  return "Numpad 1"
            case .back:   return "Ctrl Numpad 1"
            case .right:  return "Numpad 3"
            case .left:   return "Ctrl Numpad 3"
            }
        }

        /// `bpy.ops.view3d.view_axis(type=…)`.
        public var bpyType: String { rawValue.uppercased() }
    }

    /// Straight up and straight down, exactly.
    ///
    /// This used to stop 0.02 rad short — 1.1° — because the view was built by
    /// crossing the view direction with world Z, and looking straight down
    /// makes that cross product zero. Top and Bottom were therefore never quite
    /// top and bottom. The camera's axes now come from its angles instead (see
    /// `right` and `trueUp`), which have an answer at the poles.
    private static let poleLimit: Float = .pi / 2

    public init() {}

    public var eye: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let offset = SIMD3(ce * sin(azimuth), -ce * cos(azimuth), se)
        return target + offset * distance
    }

    /// World Z is up — Blender's convention, and the reason models exported
    /// from it look "rotated" in Y-up engines.
    public var up: SIMD3<Float> { SIMD3(0, 0, 1) }

    /// Built on the camera's own up rather than world Z. Wherever world Z would
    /// work the two give the same matrix; at the poles only this one exists.
    public var viewMatrix: simd_float4x4 {
        .lookAt(eye: eye, center: target, up: trueUp)
    }

    public func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let a = max(aspect, 0.01)
        guard isOrthographic else {
            return .perspective(fovY: fovY, aspect: a, near: near, far: far)
        }
        // Match the framing of the perspective view at the pivot distance, so
        // toggling does not jump the scene's apparent size.
        let halfHeight = distance * tan(fovY * 0.5)
        return .orthographic(halfWidth: halfHeight * a, halfHeight: halfHeight,
                             near: -far, far: far)
    }

    /// Blender's numpad views. Orthographic is switched on, as Blender does,
    /// because an axis view in perspective is not much use for modelling.
    public mutating func snap(to viewpoint: Viewpoint) {
        switch viewpoint {
        case .top:    azimuth = 0;         elevation = Self.poleLimit
        case .bottom: azimuth = 0;         elevation = -Self.poleLimit
        case .front:  azimuth = 0;         elevation = 0
        case .back:   azimuth = .pi;       elevation = 0
        case .right:  azimuth = .pi / 2;   elevation = 0
        case .left:   azimuth = -.pi / 2;  elevation = 0
        }
        isOrthographic = true
    }

    public func viewProjection(aspect: Float) -> simd_float4x4 {
        projectionMatrix(aspect: aspect) * viewMatrix
    }

    /// Camera basis vectors, used to pan in screen space.
    ///
    /// Written from the angles, so they exist looking straight down: right is
    /// the azimuth's own horizontal, and up is what is left of the view once
    /// right and the view direction are taken out.
    public var right: SIMD3<Float> {
        SIMD3(cos(azimuth), sin(azimuth), 0)
    }
    public var trueUp: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        return SIMD3(-se * sin(azimuth), se * cos(azimuth), ce)
    }

    // MARK: navigation

    /// Middle-mouse-drag on desktop; one-finger drag here.
    public mutating func orbit(dx: Float, dy: Float) {
        azimuth += dx
        elevation = min(max(elevation + dy, -Self.poleLimit), Self.poleLimit)
    }

    /// Shift+middle-drag on desktop; two-finger drag here. Panning scales with
    /// distance so the scene tracks the finger at any zoom level.
    public mutating func pan(dx: Float, dy: Float) {
        let scale = distance * 0.0016
        target += right * (-dx * scale) + trueUp * (dy * scale)
    }

    /// Scroll wheel on desktop; pinch here.
    public mutating func dolly(factor: Float) {
        distance = min(max(distance * factor, 0.4), 500)
    }

    /// `View > Frame All` (Home). Fits every object the viewport draws.
    ///
    /// Hidden objects are left out, as Blender's View All leaves them out
    /// (`BASE_VISIBLE` in view3d_all_exec). Measured in desktop 5.2.1 through
    /// a 3D View override, a 2 m cube and a 100 m plane: distance 160.4 with
    /// both shown, 3.208 with the plane hidden by H or disabled in viewports,
    /// and with everything hidden the view stayed where it was. This counted
    /// every object once, and since a hidden object keeps the mesh it was last
    /// drawn with (`SceneMirror.merge`), hiding the ground and pressing Home
    /// zoomed out to the ground: 294.66 against 7.22 in round 2's review.
    ///
    /// An object with no vertices here (an empty, a camera, a light) counts
    /// by its origin, as `BKE_object_minmax` counts an empty.
    public mutating func frameAll(_ objects: [BKObject]) {
        guard !objects.isEmpty else {
            target = .zero; distance = 11; return
        }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        for obj in objects where obj.visible {
            let m = obj.modelMatrix
            if obj.mesh.vertices.isEmpty {
                let w = m.columns.3.xyz
                lo = min(lo, w); hi = max(hi, w)
            }
            for v in obj.mesh.vertices {
                let w = (m * SIMD4(v.position, 1)).xyz
                lo = min(lo, w); hi = max(hi, w)
            }
            found = true
        }
        // Nothing drawn: Blender's View All returns FINISHED and moves nothing.
        guard found else { return }
        frame(lo: lo, hi: hi)
    }

    /// `View > Frame Selected` (numpad period). Fits the selected objects, or
    /// while editing the selected vertices. With nothing selected the view
    /// stays where it is, as Blender's does, and this returns false.
    @discardableResult
    public mutating func frameSelected(in scene: BKScene) -> Bool {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        if let (obj, cage) = scene.editedPoints {
            // A curve's or a lattice's selected control points.
            for w in cage.selectedWorld(model: obj.modelMatrix) {
                lo = min(lo, w); hi = max(hi, w)
                found = true
            }
        } else if scene.mode == .edit, let obj = scene.active {
            let m = obj.modelMatrix
            let cage = obj.editCage
            for i in scene.editSelection.vertices where i < cage.vertices.count {
                let w = (m * SIMD4(cage.vertices[i].position, 1)).xyz
                lo = min(lo, w); hi = max(hi, w)
                found = true
            }
        } else {
            for obj in scene.objects where scene.selection.contains(obj.id) {
                let b = obj.worldBounds
                lo = min(lo, b.min); hi = max(hi, b.max)
                found = true
            }
        }
        guard found else { return false }
        frame(lo: lo, hi: hi)
        return true
    }

    private mutating func frame(lo: SIMD3<Float>, hi: SIMD3<Float>) {
        target = (lo + hi) * 0.5
        let radius = max(length(hi - lo) * 0.5, 0.5)
        distance = radius / tan(fovY * 0.5) * 1.5
    }

    /// Whether `objects` sit badly in the current view — overflowing it,
    /// off to one side, or shrunk to a speck.
    ///
    /// Used after a script runs. Building something you cannot see is the
    /// commonest way for a script to look like it did nothing at all, and
    /// Blender's answer (press Home) assumes a keyboard.
    func framesPoorly(_ objects: [BKObject]) -> Bool {
        let visible = objects.filter { $0.visible && !$0.mesh.vertices.isEmpty }
        guard !visible.isEmpty else { return false }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for obj in visible {
            let m = obj.modelMatrix
            for v in obj.mesh.vertices {
                let w = (m * SIMD4(v.position, 1)).xyz
                lo = min(lo, w); hi = max(hi, w)
            }
        }
        let centre = (lo + hi) * 0.5
        let radius = max(length(hi - lo) * 0.5, 0.0001)
        // Half-height of the view at the pivot, in world units.
        let reach = max(distance * tan(fovY * 0.5), 0.0001)

        if radius > reach * 0.95 { return true }          // spills off the edges
        // `frameAll` leaves the ratio at 1/1.5 = 0.67, so anything under 0.3 is
        // well past "a little loose" — it is a model lost in empty grid, which
        // is what a script that built something small looks like.
        if radius < reach * 0.30 { return true }          // a speck in the middle
        if length(centre - target) > reach * 0.6 { return true }   // off to one side
        return false
    }

    // MARK: picking

    /// Turns a point in view coordinates into a world-space ray, so a tap can
    /// select an object.
    public func ray(atNDC ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let invVP = viewProjection(aspect: aspect).inverse
        let nearPoint = invVP * SIMD4(ndc.x, ndc.y, 0, 1)
        let farPoint  = invVP * SIMD4(ndc.x, ndc.y, 1, 1)
        let o = nearPoint.xyz / nearPoint.w
        let f = farPoint.xyz / farPoint.w
        return (o, normalize(f - o))
    }
}

public extension ViewportCamera {
    /// The rotation Blender gives an object it aligns to this view: its X, Y
    /// and Z are the view's right, up and back, so the object looks the way
    /// the view looks (`ED_object_rotation_from_view`).
    var objectRotation: simd_float3x3 {
        let ce = cos(elevation), se = sin(elevation)
        let back = SIMD3(ce * sin(azimuth), -ce * cos(azimuth), se)
        return simd_float3x3(right, trueUp, back)
    }
}

public extension ViewportCamera {
    /// Whether the view still stands where it was put. Blender leaves camera
    /// view as soon as you orbit; this is how that is noticed, without the
    /// viewport having to report every drag.
    func stillAt(_ other: ViewportCamera) -> Bool {
        abs(azimuth - other.azimuth) < 1e-5 && abs(elevation - other.elevation) < 1e-5
            && abs(distance - other.distance) < 1e-4 && abs(fovY - other.fovY) < 1e-5
            && simd_distance(target, other.target) < 1e-4
            && isOrthographic == other.isOrthographic
    }

    /// The 3D View as a camera Blender can render through.
    var renderCamera: RenderRequest.ViewCamera {
        RenderRequest.ViewCamera(location: eye,
                                 rotation: ObjectAddition.eulerXYZ(objectRotation),
                                 fovY: fovY,
                                 isOrthographic: isOrthographic,
                                 orthoScale: 2 * distance * tan(fovY * 0.5))
    }

    /// Looks through a camera object: the view moves to where it is, faces the
    /// way it faces, and shows what it shows from top to bottom. A viewport
    /// wider than the frame shows more to the sides, as Blender's does around
    /// the camera's border.
    ///
    /// The pivot keeps its distance ahead of the view, so orbiting afterwards
    /// turns around what the camera was pointed at rather than snapping back.
    mutating func look(through object: BKObject) -> Bool {
        guard case .camera(let display)? = object.overlayDisplay else { return false }
        let m = object.modelMatrix
        let back = simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        guard back.x.isFinite, simd_length(back) > 0.5 else { return false }
        elevation = asin(min(max(back.z, -1), 1))
        azimuth = atan2(back.x, -back.y)
        fovY = min(max(display.verticalAngle, 0.02), 3.0)
        isOrthographic = display.projection == .orthographic
        if isOrthographic {
            distance = max(display.verticalExtent / 2 / tan(fovY * 0.5), 0.01)
        }
        target = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) - back * distance
        return true
    }
}

public extension OverlayView {
    /// The overlay view for this camera in a viewport `size` points across.
    init(camera: ViewportCamera, size: CGSize) {
        self.init(view: camera.viewMatrix,
                  projection: camera.projectionMatrix(aspect: Float(size.width / max(size.height, 1))),
                  size: size)
    }
}
