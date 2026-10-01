import Foundation
import simd
import CoreGraphics

// Blender's viewport overlays for cameras, lights and empties, as lines.
//
// Everything here follows Blender's overlay engine: the shapes in
// `draw/engines/overlay/overlay_shape.cc`, what `overlay_camera.hh`,
// `overlay_light.hh` and `overlay_empty.hh` hand them, and what
// `shaders/overlay_extra_vert.glsl` does with each vertex class. File and
// function names are cited where a number comes from, so a change in Blender
// can be followed here. Checked against the 5.3 sources, and the frame against
// Blender 5.2.1 itself (scripts/run-camlight-blender-check.sh).

/// The view an overlay is drawn in: what Blender's overlay shaders read from
/// `drw_view()` and their globals.
///
/// Part of an overlay faces the viewer or keeps a fixed size on screen — a
/// light's icon, the arrows' letters — so its lines depend on the view as well
/// as on the object, and are rebuilt for every frame and every tap.
public struct OverlayView {
    public let viewProjection: simd_float4x4
    /// The view's axes in world space: Blender's `viewinv[0]` and `[1]`.
    public let right: SIMD3<Float>
    public let up: SIMD3<Float>
    /// `viewinv[2]`: towards the viewer.
    public let back: SIMD3<Float>
    public let eye: SIMD3<Float>
    public let isPerspective: Bool
    /// The view's size in points.
    public let size: CGSize
    /// Blender's `rv3d->pixsize`, per point rather than per pixel: Blender's
    /// overlay sizes are multiplied by `U.pixelsize`, which on a high-density
    /// display makes its pixel a point.
    let pixelSize: Float

    public init(view: simd_float4x4, projection: simd_float4x4, size: CGSize) {
        viewProjection = projection * view
        let inverse = view.inverse
        right = normalize(inverse.columns.0.xyz)
        up = normalize(inverse.columns.1.xyz)
        back = normalize(inverse.columns.2.xyz)
        eye = inverse.columns.3.xyz
        isPerspective = abs(projection.columns.3.w) < 1e-6
        self.size = size
        // ED_view3d_update_viewmat: the shorter of the projection's x and y
        // scales, over the longer side of the region.
        let m = viewProjection
        let row0 = SIMD3(m.columns.0.x, m.columns.1.x, m.columns.2.x)
        let row1 = SIMD3(m.columns.0.y, m.columns.1.y, m.columns.2.y)
        let shortest = sqrt(max(min(simd_length_squared(row0), simd_length_squared(row1)), 1e-12))
        pixelSize = (2 / shortest) / Float(max(size.width, size.height, 1))
    }

    /// `mul_project_m4_v3_zfac` without the pixel factor: the projection's w.
    func depthFactor(_ p: SIMD3<Float>) -> Float {
        let m = viewProjection
        return m.columns.0.w * p.x + m.columns.1.w * p.y + m.columns.2.w * p.z + m.columns.3.w
    }

    /// World units per point of screen at a position.
    public func worldPerPoint(at p: SIMD3<Float>) -> Float { pixelSize * depthFactor(p) }

    /// How far in front of the eye a point is, along the view.
    public func distance(_ p: SIMD3<Float>) -> Float { dot(p - eye, -back) }

    /// `VCLASS_SCREENSPACE`: an offset in points, facing the viewer, the same
    /// size on screen however far away `centre` is.
    public func screenSpace(_ centre: SIMD3<Float>, _ offset: SIMD2<Float>) -> SIMD3<Float> {
        centre + (right * offset.x + up * offset.y) * worldPerPoint(at: centre)
    }

    /// `VCLASS_SCREENALIGNED`: an offset in world units, facing the viewer.
    public func screenAligned(_ centre: SIMD3<Float>, _ offset: SIMD2<Float>) -> SIMD3<Float> {
        centre + right * offset.x + up * offset.y
    }

    /// Where a point lands in the view, in points, or nil behind the eye.
    public func project(_ p: SIMD3<Float>) -> CGPoint? {
        let clip = viewProjection * SIMD4(p, 1)
        guard clip.w > Self.nearW else { return nil }
        return screen(clip)
    }

    func screen(_ clip: SIMD4<Float>) -> CGPoint {
        CGPoint(x: CGFloat(clip.x / clip.w * 0.5 + 0.5) * size.width,
                y: CGFloat(1 - (clip.y / clip.w * 0.5 + 0.5)) * size.height)
    }

    /// Nearer than this to the eye's plane, a point has no screen position.
    /// The overlay shader clips its lines at the same place.
    static let nearW: Float = 1e-5

    /// A segment on screen, cut where it passes behind the eye: its two ends,
    /// the world points they came from, and their projective w.
    func projectSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>)
        -> (start: CGPoint, end: CGPoint, a: SIMD3<Float>, b: SIMD3<Float>, wa: Float, wb: Float)? {
        var ca = viewProjection * SIMD4(a, 1), cb = viewProjection * SIMD4(b, 1)
        var wa = a, wb = b
        if ca.w < Self.nearW && cb.w < Self.nearW { return nil }
        if ca.w < Self.nearW {
            let t = (Self.nearW - ca.w) / (cb.w - ca.w)
            ca += (cb - ca) * t
            wa += (b - a) * t
        }
        if cb.w < Self.nearW {
            let t = (Self.nearW - cb.w) / (ca.w - cb.w)
            cb += (ca - cb) * t
            wb += (wa - wb) * t
        }
        return (screen(ca), screen(cb), wa, wb, ca.w, cb.w)
    }

    /// The world ray under a point in the view.
    public func ray(through point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               1 - Float(point.y / size.height) * 2)
        let inverse = viewProjection.inverse
        let near = inverse * SIMD4(ndc.x, ndc.y, 0, 1)
        let far = inverse * SIMD4(ndc.x, ndc.y, 1, 1)
        guard abs(near.w) > 1e-12, abs(far.w) > 1e-12 else { return nil }
        let o = near.xyz / near.w
        let d = far.xyz / far.w - o
        guard simd_length_squared(d) > 0 else { return nil }
        return (o, normalize(d))
    }
}

/// Lines and filled triangles in world space, ready to draw or to pick.
public struct OverlayGeometry {
    public struct Line: Equatable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var color: SIMD4<Float>
    }

    public struct Triangle: Equatable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var c: SIMD3<Float>
        public var color: SIMD4<Float>
    }

    /// Opaque: depth-tested and written to depth, as Blender's extras are
    /// (`DRW_STATE_WRITE_DEPTH | DRW_STATE_DEPTH_LESS_EQUAL`).
    public var lines: [Line] = []
    /// Blended over what is behind them: the ground line under a light, in
    /// the theme's translucent light colour. Depth is tested and written as
    /// for the other lines (`overlay_light.hh`, the "ground_line" pass).
    public var translucentLines: [Line] = []
    /// The filled triangle on the scene's camera.
    public var triangles: [Triangle] = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty && translucentLines.isEmpty && triangles.isEmpty }

    public mutating func append(_ other: OverlayGeometry) {
        lines += other.lines
        translucentLines += other.translucentLines
        triangles += other.triangles
    }
}

public enum ObjectOverlays {

    /// Blender's default theme (`release/datafiles/userdef/userdef_default_theme.c`,
    /// `space_view3d`), picked the way `Resources::object_wire_theme_id` in
    /// `overlay_private.hh` picks: the active colour for the selected active
    /// object, the select colour for the rest of the selection, and otherwise
    /// the object type's own colour — which for cameras, lights and empties is
    /// black.
    public enum Theme {
        public static let camera = SIMD4<Float>(0, 0, 0, 1)
        public static let empty = SIMD4<Float>(0, 0, 0, 1)
        /// `.lamp` is 0x00000050; `overlay_light.hh` draws a light in its
        /// colour with the alpha set to one.
        public static let light = SIMD4<Float>(0, 0, 0, 1)
        /// The ground line keeps `.lamp`'s alpha.
        public static let groundLine = SIMD4<Float>(0, 0, 0, Float(0x50) / 255)
        /// `.select`, #ED5700.
        public static let select = SIMD4<Float>(Float(0xED) / 255, Float(0x57) / 255, 0, 1)
        /// `.active`, #FFA028.
        public static let active = SIMD4<Float>(1, Float(0xA0) / 255, Float(0x28) / 255, 1)
        /// The camera limits' ends and focus cross, from `overlay_extra_vert.glsl`,
        /// brighter on the scene's camera.
        public static let limits = SIMD4<Float>(0.5, 0.5, 0.25, 1)
        public static let limitsActive = SIMD4<Float>(1, 1, 0.5, 1)
    }

    /// The colour an object's overlay is drawn in.
    ///
    /// Active means selected and active: an active object that is not selected
    /// is drawn in its type's colour, as in Blender.
    public static func wireColor(for object: BKObject, in scene: BKScene) -> SIMD4<Float> {
        if scene.selection.contains(object.id) {
            return object.id == scene.activeID ? Theme.active : Theme.select
        }
        switch object.blenderType {
        case "CAMERA": return Theme.camera
        case "LIGHT":  return Theme.light
        default:       return Theme.empty
        }
    }

    /// Every visible camera, light and empty in the scene.
    public static func geometry(in scene: BKScene, view: OverlayView) -> OverlayGeometry {
        var all = OverlayGeometry()
        for object in scene.objects where object.visible && object.overlayDisplay != nil {
            all.append(geometry(for: object, in: scene, view: view))
        }
        return all
    }

    /// One object's overlay, in world space. Empty for an object Blender draws
    /// from its mesh.
    public static func geometry(for object: BKObject, in scene: BKScene,
                                view: OverlayView) -> OverlayGeometry {
        guard let display = object.overlayDisplay else { return OverlayGeometry() }
        var builder = OverlayBuilder(view: view, color: wireColor(for: object, in: scene))
        let m = object.modelMatrix
        switch display {
        case .camera(let c): camera(c, m, &builder)
        case .light(let l):  light(l, m, &builder)
        case .empty(let e):  empty(e, m, &builder)
        }
        return builder.geometry
    }

    // MARK: cameras

    /// `Cameras::object_sync_extras` in `overlay_camera.hh`, outside camera view:
    /// the frame, the wires to the origin, the triangle above the frame, and
    /// with Limits on the clipping range.
    static func camera(_ c: CameraDisplay, _ m: simd_float4x4, _ b: inout OverlayBuilder) {
        let view = b.view
        let scale = SIMD3(length(m.columns.0.xyz), length(m.columns.1.xyz), length(m.columns.2.xyz))
        // Blender draws nothing at all for a camera scaled to zero.
        guard scale.x != 0, scale.y != 0, scale.z != 0 else { return }
        // "Normalize matrix scale."
        var mat = m
        mat.columns.0 = SIMD4(m.columns.0.xyz / scale.x, 0)
        mat.columns.1 = SIMD4(m.columns.1.xyz / scale.y, 0)
        mat.columns.2 = SIMD4(m.columns.2.xyz / scale.z, 0)

        // The frame is worked out with the inverse scale and then scaled back:
        // it grows with the object, but keeps the render's proportions.
        let viewFrame = c.viewFrame(scale: 1 / scale)
        let vecs = viewFrame.corners.map { corner -> SIMD3<Float> in
            let v = corner * scale
            // "Project to z=-1 plane."
            return SIMD3(v.x / abs(v.z), v.y / abs(v.z), v.z)
        }
        let center = (SIMD2(vecs[0].x, vecs[0].y) + SIMD2(vecs[2].x, vecs[2].y)) * 0.5
        let corner = SIMD2(vecs[0].x, vecs[0].y) - center
        let depth = abs(vecs[0].z)
        guard depth > 0, depth.isFinite else { return }

        /// `VCLASS_CAMERA_FRAME`: z of 1 is at the frame's depth, z of 0 at the
        /// origin, and x and y spread with the depth.
        func framePoint(_ p: SIMD2<Float>, _ z: Float,
                        _ center: SIMD2<Float>, _ corner: SIMD2<Float>) -> SIMD3<Float> {
            let vz = z * -depth
            let xy = (center + corner * p) * abs(vz)
            return (mat * SIMD4(xy.x, xy.y, vz, 1)).xyz
        }

        // `camera_frame`: the rectangle, and a wire from each corner to the origin.
        let rect = [SIMD2<Float>(-1, -1), SIMD2(-1, 1), SIMD2(1, 1), SIMD2(1, -1)]
        b.loop(rect.map { framePoint($0, 1, center, corner) })
        for p in rect {
            b.line(framePoint(p, 1, center, corner), framePoint(p, 0, center, corner))
        }

        // `camera_tria`: above the frame, pointing up. Filled on the scene's
        // camera, outlined on every other one.
        let triaSize = 0.7 * viewFrame.drawSize / depth
        let triaMargin = 0.1 * viewFrame.drawSize / depth
        let triCenter = SIMD2(center.x, center.y + corner.y + triaMargin + triaSize)
        let triCorner = SIMD2<Float>(repeating: -triaSize)
        let tri = [SIMD2<Float>(-1, 1), SIMD2(1, 1), SIMD2(0, 0)]
            .map { framePoint($0, 1, triCenter, triCorner) }
        if c.isSceneCamera {
            b.geometry.triangles.append(.init(a: tri[0], b: tri[1], c: tri[2], color: b.color))
        } else {
            b.loop(tri)
        }

        // `camera_distances`, with `CAM_SHOWLIMITS`: a line through the clip
        // range, a pentagon at each end, and a cross at the focus distance.
        guard c.showLimits else { return }
        var limits = mat
        limits.columns.0 = mat.columns.0 * c.displaySize
        limits.columns.1 = mat.columns.1 * c.displaySize
        let tint = c.isSceneCamera ? Theme.limitsActive : Theme.limits
        let start = (limits * SIMD4(0, 0, -c.clipStart, 1)).xyz
        let end = (limits * SIMD4(0, 0, -c.clipEnd, 1)).xyz
        b.line(start, end)
        let pentagon = ring(1.5, 5)
        b.loop(pentagon.map { view.screenSpace(start, $0) }, color: tint)
        b.loop(pentagon.map { view.screenSpace(end, $0) }, color: tint)
        let focus = -c.focusDistance
        b.line((limits * SIMD4(1, 0, focus, 1)).xyz, (limits * SIMD4(-1, 0, focus, 1)).xyz, tint)
        b.line((limits * SIMD4(0, 1, focus, 1)).xyz, (limits * SIMD4(0, -1, focus, 1)).xyz, tint)
    }

    // MARK: lights

    /// `Lights::object_sync` in `overlay_light.hh`: the ground line, the icon,
    /// and the shape of the light's type.
    static func light(_ l: LightDisplay, _ m: simd_float4x4, _ b: inout OverlayBuilder) {
        let view = b.view
        let origin = m.columns.3.xyz

        // `ground_line`, drawn by `overlay_extra_groundline_vert.glsl` in the
        // theme's light colour whatever the selection: down to z = 0, with a
        // small diamond where it lands.
        let ground = SIMD3(origin.x, origin.y, 0)
        b.translucent(origin, ground)
        let landing = ring(1.35, 4).map { view.screenSpace(ground, $0) }
        for i in landing.indices { b.translucent(landing[i], landing[(i + 1) % landing.count]) }

        // The icon: `light_icon_inner_lines` — a diamond and a dashed ring —
        // and `light_icon_outer_lines`, a wider dashed ring. Both a fixed size
        // on screen.
        let r: Float = 9
        b.loop(ring(r * 0.3, 4).map { view.screenSpace(origin, $0) })
        b.loop(ring(r, 16).map { view.screenSpace(origin, $0) }, dashed: true)
        b.loop(ring(r * 1.33, 20).map { view.screenSpace(origin, $0) }, dashed: true)

        switch l.kind {
        case .point:
            // `light_point_lines`: the radius, facing the viewer. It does not
            // scale with the object.
            if l.radius > 0 {
                b.loop(ring(1, 32).map { view.screenAligned(origin, $0 * l.radius) })
            }

        case .sun:
            // `light_icon_sun_rays`, then `light_sun_lines`' direction line.
            for p in ring(r, 8) {
                b.line(view.screenSpace(origin, p * 1.6), view.screenSpace(origin, p * 1.9))
                b.line(view.screenSpace(origin, p * 2.2), view.screenSpace(origin, p * 2.5))
            }
            b.line(origin, (m * SIMD4(0, 0, -20, 1)).xyz)

        case .spot:
            spot(l, m, &b)
            direction(l, m, &b)

        case .area:
            // `light_area_square_lines` or `light_area_disk_lines`: square and
            // disk use Size both ways, rectangle and ellipse Size and Size Y.
            let sx = l.size
            let sy = (l.shape == .rectangle || l.shape == .ellipse) ? l.sizeY : l.size
            let outline: [SIMD2<Float>] = (l.shape == .square || l.shape == .rectangle)
                ? [SIMD2(-0.5, -0.5), SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5), SIMD2(0.5, -0.5)]
                : ring(0.5, 32)
            b.loop(outline.map { (m * SIMD4($0.x * sx, $0.y * sy, 0, 1)).xyz })
            direction(l, m, &b)
        }
    }

    /// `light_spot_lines`: the radius, the cone's rim and blend rim, and the
    /// cone's two silhouette edges.
    static func spot(_ l: LightDisplay, _ m: simd_float4x4, _ b: inout OverlayBuilder) {
        let view = b.view
        let origin = m.columns.3.xyz
        // "We use a fixed size of 10" (#72871): the cone is drawn ten units long.
        var cone = m
        cone.columns.0 = m.columns.0 * 10
        cone.columns.1 = m.columns.1 * 10
        cone.columns.2 = m.columns.2 * 10

        // Where the blend rim goes: the spot attenuation's roots, as
        // `overlay_light.hh` solves them.
        let cosine = cos(l.spotSize * 0.5)
        let sine = sqrt(max(0, 1 - cosine * cosine))
        let a2 = cosine * cosine
        let c = cosine * l.spotBlend - cosine - l.spotBlend
        let c2 = c * c
        let denominator = c2 - a2 * c2
        let blend = denominator > 0 ? sqrt(max(0, (a2 - a2 * c2) / denominator)) : 0

        func rim(_ p: SIMD2<Float>, _ reach: Float) -> SIMD3<Float> {
            (cone * SIMD4(p.x * reach, p.y * reach, -cosine, 1)).xyz
        }
        let unit = ring(1, 32)
        if l.radius > 0 {
            b.loop(unit.map { view.screenAligned(origin, $0 * l.radius) })
        }
        b.loop(unit.map { rim($0, sine) })
        b.loop(unit.map { rim($0, sine * blend) })

        // `VCLASS_LIGHT_SPOT_CONE`: a wire from the apex to each rim point,
        // kept only where the cone's surface turns from facing the viewer to
        // facing away — its silhouette. The shader's own step is 2 * 3.1415 / 32.
        let step: Float = 2 * 3.1415 / 32
        let (cs, sn) = (cos(step), sin(step))
        for p in unit {
            let here = rim(p, sine)
            let previous = rim(SIMD2(p.x * cs + p.y * sn, p.y * cs - p.x * sn), sine)
            let next = rim(SIMD2(p.x * cs - p.y * sn, p.y * cs + p.x * sn), sine)
            let edge = origin - here
            let n0 = normalize(cross(edge, previous - here))
            let n1 = normalize(cross(edge, here - next))
            let toViewer = view.isPerspective ? normalize(view.eye - here) : view.back
            if (dot(n0, toViewer) > 0) != (dot(n1, toViewer) > 0) {
                b.line(origin, here)
            }
        }
    }

    /// `light_append_direction_line`: from the shadow clip start to the cutoff
    /// distance along the light's direction, in world units whatever the
    /// object's scale, with a diamond at each end.
    static func direction(_ l: LightDisplay, _ m: simd_float4x4, _ b: inout OverlayBuilder) {
        let view = b.view
        let axis = m.columns.2.xyz
        let reach = length(axis)
        // A negative clip end hides it, as in the shader.
        guard reach > 0, l.cutoffDistance >= 0 else { return }
        let origin = m.columns.3.xyz
        let start = origin - axis / reach * l.clipStart
        let end = origin - axis / reach * l.cutoffDistance
        b.line(start, end)
        let diamond = ring(1.2, 4)
        b.loop(diamond.map { view.screenSpace(start, $0) })
        b.loop(diamond.map { view.screenSpace(end, $0) })
    }

    // MARK: empties

    /// `Empties::object_sync` in `overlay_empty.hh`, with the shapes from
    /// `overlay_shape.cc`, each scaled by the display size and then by the
    /// object.
    static func empty(_ e: EmptyDisplay, _ m: simd_float4x4, _ b: inout OverlayBuilder) {
        let s = e.size
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> { (m * SIMD4(p * s, 1)).xyz }

        switch e.kind {
        case .plainAxes:
            b.line(point(SIMD3(0, -1, 0)), point(SIMD3(0, 1, 0)))
            b.line(point(SIMD3(-1, 0, 0)), point(SIMD3(1, 0, 0)))
            b.line(point(SIMD3(0, 0, -1)), point(SIMD3(0, 0, 1)))

        case .singleArrow:
            // `single_arrow`: a shaft up Z and a four-sided head, built the way
            // Blender builds it by flipping two points around the tip.
            var p = [SIMD3<Float>(0, 0, 1), SIMD3(0.035, 0.035, 0.75), SIMD3(-0.035, 0.035, 0.75)]
            for side in 0..<4 {
                if side % 2 == 1 {
                    p[1].x = -p[1].x
                    p[2].y = -p[2].y
                } else {
                    p[1].y = -p[1].y
                    p[2].x = -p[2].x
                }
                b.line(point(p[0]), point(p[1]))
                b.line(point(p[1]), point(p[2]))
            }
            b.line(point(.zero), point(SIMD3(0, 0, 0.75)))

        case .cube:
            // `bone_box_verts` with y stretched to -1...1, and `bone_box_wire_lines`.
            let corners: [SIMD3<Float>] = [SIMD3(1, -1, 1), SIMD3(1, -1, -1), SIMD3(-1, -1, -1),
                                           SIMD3(-1, -1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, -1),
                                           SIMD3(-1, 1, -1), SIMD3(-1, 1, 1)]
            let edges = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
            for i in stride(from: 0, to: edges.count, by: 2) {
                b.line(point(corners[edges[i]]), point(corners[edges[i + 1]]))
            }

        case .circle:
            // `circle`: in the object's XZ plane.
            b.loop(ring(1, 64).map { point(SIMD3($0.x, 0, $0.y)) })

        case .sphere:
            // `empty_sphere`: one circle around each axis.
            let r = ring(1, 32)
            b.loop(r.map { point(SIMD3($0.x, $0.y, 0)) })
            b.loop(r.map { point(SIMD3($0.x, 0, $0.y)) })
            b.loop(r.map { point(SIMD3(0, $0.x, $0.y)) })

        case .cone:
            // `empty_cone`: an eight-sided base in XZ, the apex two up Y.
            let r = ring(1, 8)
            let apex = point(SIMD3(0, 2, 0))
            for i in r.indices {
                let here = point(SIMD3(r[i].x, 0, r[i].y))
                let next = point(SIMD3(r[(i + 1) % r.count].x, 0, r[(i + 1) % r.count].y))
                b.line(here, apex)
                b.line(here, next)
            }

        case .arrows:
            arrows(e, m, &b)

        case .image:
            // `image_sync`: the frame, sized by the image's proportions and
            // moved by its offset. The picture itself is not drawn.
            var frame = m
            frame.columns.0 = m.columns.0 * (e.imageAspect.x * 0.5 * s)
            frame.columns.1 = m.columns.1 * (e.imageAspect.y * 0.5 * s)
            frame.columns.3 = m.columns.3 + frame.columns.0 * (e.imageOffset.x * 2 + 1)
                                          + frame.columns.1 * (e.imageOffset.y * 2 + 1)
            let quad = [SIMD2<Float>(-1, -1), SIMD2(-1, 1), SIMD2(1, 1), SIMD2(1, -1)]
            b.loop(quad.map { (frame * SIMD4($0.x, $0.y, 0, 1)).xyz })
        }
    }

    /// `arrows`: a line along each axis, a stack of diamonds at its end and the
    /// axis's letter beyond it. The diamonds and letters face the viewer and
    /// scale with the axis (`VCLASS_EMPTY_AXES | VCLASS_SCREENALIGNED`).
    static func arrows(_ e: EmptyDisplay, _ m: simd_float4x4, _ b: inout OverlayBuilder) {
        let view = b.view
        let s = e.size
        let origin = m.columns.3.xyz
        let marker = [SIMD2<Float>(-1, 0), SIMD2(0, 1), SIMD2(0, 1), SIMD2(1, 0),
                      SIMD2(1, 0), SIMD2(0, -1), SIMD2(0, -1), SIMD2(-1, 0)]
        let x = SIMD2<Float>(0.0215, 0.025), y = SIMD2<Float>(0.0175, 0.025), z = SIMD2<Float>(0.02, 0.025)
        let letters: [[SIMD2<Float>]] = [
            [SIMD2(0.9, 1) * x, SIMD2(-1, -1) * x, SIMD2(-0.9, 1) * x, SIMD2(1, -1) * x],
            [SIMD2(-1, 1) * y, SIMD2(0, -0.1) * y, SIMD2(1, 1) * y, SIMD2(0, -0.1) * y,
             SIMD2(0, -0.1) * y, SIMD2(0, -1) * y],
            [SIMD2(-0.95, 1) * z, SIMD2(0.95, 1) * z, SIMD2(0.95, 1) * z, SIMD2(0.95, 0.9) * z,
             SIMD2(0.95, 0.9) * z, SIMD2(-1, -0.9) * z, SIMD2(-1, -0.9) * z, SIMD2(-1, -1) * z,
             SIMD2(-1, -1) * z, SIMD2(1, -1) * z],
        ]
        for axis in 0..<3 {
            var unit = SIMD3<Float>.zero
            unit[axis] = 1
            let tip = (m * SIMD4(unit * s, 1)).xyz
            b.line(origin, tip)
            let reach = length(m[axis].xyz) * s
            for layer in 1...6 {
                let k = 0.007 * 4 * Float(layer) / 6 * reach
                for i in stride(from: 0, to: marker.count, by: 2) {
                    b.line(view.screenAligned(tip, marker[i] * k),
                           view.screenAligned(tip, marker[i + 1] * k))
                }
            }
            let label = (m * SIMD4(unit * s * 1.25, 1)).xyz
            let glyph = letters[axis]
            for i in stride(from: 0, to: glyph.count, by: 2) {
                b.line(view.screenAligned(label, glyph[i] * 4 * reach),
                       view.screenAligned(label, glyph[i + 1] * 4 * reach))
            }
        }
    }
}

/// Collects an object's lines in its wire colour.
struct OverlayBuilder {
    let view: OverlayView
    let color: SIMD4<Float>
    var geometry = OverlayGeometry()

    mutating func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tint: SIMD4<Float>? = nil) {
        geometry.lines.append(.init(a: a, b: b, color: tint ?? color))
    }

    mutating func translucent(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
        geometry.translucentLines.append(.init(a: a, b: b, color: ObjectOverlays.Theme.groundLine))
    }

    /// `append_line_loop` in `overlay_shape.cc`: each point to the next and the
    /// last back to the first — or, dashed, every other one of those segments.
    mutating func loop(_ points: [SIMD3<Float>], dashed: Bool = false, color tint: SIMD4<Float>? = nil) {
        let n = points.count
        guard n > 1 else { return }
        let step = dashed ? 2 : 1
        for i in 0..<(n / step) {
            line(points[(i * step) % n], points[(i * step + 1) % n], tint)
        }
    }
}

/// `ring_vertices` in `overlay_shape.cc`: `segments` points round a circle,
/// starting on +X.
func ring(_ radius: Float, _ segments: Int) -> [SIMD2<Float>] {
    (0..<segments).map { i in
        let angle = 2 * Float.pi * Float(i) / Float(segments)
        return SIMD2(cos(angle), sin(angle)) * radius
    }
}

// MARK: - Picking

/// Which camera, light or empty a tap or a dragged box takes.
///
/// Blender selects these by drawing them into a selection buffer, so what
/// counts is the lines on screen. This measures the same thing directly: the
/// screen distance from the touch to the object's lines and origin.
public enum ObjectOverlayPicking {

    /// How near a line or an origin a tap has to land, in points.
    ///
    /// Blender tries a 14-pixel box round the cursor first, then 9 and 5 to
    /// break ties (`mixed_bones_object_selectbuffer` in `view3d_select.cc`). A
    /// fingertip covers more than that, so this is the transform gizmo's reach.
    public static let reach: CGFloat = 22

    /// The camera, light, empty or wire object whose lines are nearest the
    /// point, if any is within reach — unless a mesh's face is in front of it
    /// there, in which case the tap belongs to the mesh and this returns nil.
    ///
    /// A wire object — a circle with no fill, an unfilled curve — has no face
    /// for the renderer's ray to meet, so without its lines here it could be
    /// selected from the Outliner and never by tapping it.
    ///
    /// With the overlays hidden (`overlays` false) nothing is a candidate
    /// unless the shading is Wireframe. Blender draws loose edges and curve
    /// wires in its wireframe overlay, which runs only when
    /// `state.is_wireframe_mode || !state.hide_overlays`
    /// (overlay_instance.cc, read in the 5.3 source; a `-b` session has no 3D
    /// View to measure it in), and it selects by what it drew. The app used to
    /// keep them drawn and tappable in Solid with the overlays off.
    public static func object(at point: CGPoint, in scene: BKScene, view: OverlayView,
                              reach: CGFloat = reach, overlays: Bool = true,
                              wireframe: Bool = false) -> BKObject? {
        var best: (object: BKObject, distance: CGFloat, depth: Float)?
        for object in scene.objects where object.visible
            && ((overlays && object.overlayDisplay != nil)
                || ((overlays || wireframe) && object.overlayDisplay == nil && object.mesh.isWire)) {
            guard let hit = nearest(to: point, on: object, in: scene, view: view),
                  hit.distance <= reach,
                  best == nil || hit.distance < best!.distance
            else { continue }
            best = (object, hit.distance, hit.depth)
        }
        guard let best else { return nil }
        // A face in front takes it. Blender's selection is depth-tested the
        // same way, so a camera behind a wall cannot be picked through it.
        if let surface = surfaceDistance(at: point, in: scene, view: view),
           surface < best.depth - max(1e-4, abs(best.depth) * 1e-4) {
            return nil
        }
        return best.object
    }

    /// Whether any of an object's lines, or its origin, falls inside a
    /// rectangle — what Blender's box select tests an object's drawing against.
    public static func touches(_ object: BKObject, rect: CGRect, in scene: BKScene,
                               view: OverlayView) -> Bool {
        guard object.visible, object.overlayDisplay != nil else { return false }
        if let origin = view.project(object.modelMatrix.columns.3.xyz), rect.contains(origin) {
            return true
        }
        let geometry = ObjectOverlays.geometry(for: object, in: scene, view: view)
        for line in geometry.lines + geometry.translucentLines {
            guard let s = view.projectSegment(line.a, line.b) else { continue }
            if segment(s.start, s.end, crosses: rect) { return true }
        }
        for tri in geometry.triangles {
            guard let a = view.project(tri.a), let b = view.project(tri.b),
                  let c = view.project(tri.c) else { continue }
            if segment(a, b, crosses: rect) || segment(b, c, crosses: rect)
                || segment(c, a, crosses: rect)
                || contains(CGPoint(x: rect.midX, y: rect.midY), a, b, c) {
                return true
            }
        }
        return false
    }

    /// The nearest point of an object's overlay to `point`: how far it is on
    /// screen, and how far in front of the eye.
    static func nearest(to point: CGPoint, on object: BKObject, in scene: BKScene,
                        view: OverlayView) -> (distance: CGFloat, depth: Float)? {
        var best: (distance: CGFloat, depth: Float)?
        func offer(_ distance: CGFloat, _ depth: Float) {
            if best == nil || distance < best!.distance { best = (distance, depth) }
        }
        if object.overlayDisplay == nil {
            // A wire object is picked by its edges, as Blender picks it by
            // what it draws; its origin is not part of the drawing.
            let mesh = object.mesh, m = object.modelMatrix
            var e = 0
            while e + 1 < mesh.edges.count {
                let a = (m * SIMD4(mesh.vertices[Int(mesh.edges[e])].position, 1)).xyz
                let b = (m * SIMD4(mesh.vertices[Int(mesh.edges[e + 1])].position, 1)).xyz
                e += 2
                guard let s = view.projectSegment(a, b) else { continue }
                let (distance, fraction) = closest(point, s.start, s.end)
                let blended = (1 - fraction) * CGFloat(s.wb) + fraction * CGFloat(s.wa)
                let t = blended > 0 ? Float(fraction * CGFloat(s.wa) / blended) : Float(fraction)
                offer(distance, view.distance(s.a + (s.b - s.a) * t))
            }
            return best
        }
        let origin = object.modelMatrix.columns.3.xyz
        if let p = view.project(origin) { offer(hypot(p.x - point.x, p.y - point.y), view.distance(origin)) }

        let geometry = ObjectOverlays.geometry(for: object, in: scene, view: view)
        for line in geometry.lines + geometry.translucentLines {
            guard let s = view.projectSegment(line.a, line.b) else { continue }
            let (distance, fraction) = closest(point, s.start, s.end)
            // Screen position is linear in 1/w, not in w: convert the fraction
            // along the screen segment back to one along the world segment.
            let blended = (1 - fraction) * CGFloat(s.wb) + fraction * CGFloat(s.wa)
            let t = blended > 0 ? Float(fraction * CGFloat(s.wa) / blended) : Float(fraction)
            offer(distance, view.distance(s.a + (s.b - s.a) * t))
        }
        for tri in geometry.triangles {
            guard let a = view.project(tri.a), let b = view.project(tri.b),
                  let c = view.project(tri.c) else { continue }
            let depth = view.distance((tri.a + tri.b + tri.c) / 3)
            if contains(point, a, b, c) {
                offer(0, depth)
            } else {
                offer(min(closest(point, a, b).0, closest(point, b, c).0, closest(point, c, a).0), depth)
            }
        }
        return best
    }

    /// How far in front of the eye the nearest mesh face under the point is.
    static func surfaceDistance(at point: CGPoint, in scene: BKScene, view: OverlayView) -> Float? {
        guard let (origin, direction) = view.ray(through: point) else { return nil }
        var nearest: Float?
        for object in scene.objects where object.visible && object.overlayDisplay == nil {
            let mesh = object.mesh
            guard mesh.indices.count >= 3 else { continue }
            let inverse = object.modelMatrix.inverse
            // Not normalised, so the ray keeps its world parameter in object space.
            let o = (inverse * SIMD4(origin, 1)).xyz
            let d = (inverse * SIMD4(direction, 0)).xyz
            var i = 0
            while i + 2 < mesh.indices.count {
                if let t = rayTriangle(o, d,
                                       mesh.vertices[Int(mesh.indices[i])].position,
                                       mesh.vertices[Int(mesh.indices[i + 1])].position,
                                       mesh.vertices[Int(mesh.indices[i + 2])].position), t > 0 {
                    let depth = view.distance(origin + direction * t)
                    if nearest == nil || depth < nearest! { nearest = depth }
                }
                i += 3
            }
        }
        return nearest
    }

    /// Distance from a point to a segment, and how far along the segment the
    /// nearest point is.
    static func closest(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGFloat) {
        let vx = b.x - a.x, vy = b.y - a.y
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 1e-9 else { return (hypot(p.x - a.x, p.y - a.y), 0) }
        let t = max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared))
        return (hypot(p.x - (a.x + vx * t), p.y - (a.y + vy * t)), t)
    }

    /// Liang–Barsky: whether any part of the segment lies in the rectangle.
    static func segment(_ a: CGPoint, _ b: CGPoint, crosses r: CGRect) -> Bool {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
                continue
            }
            let t = q / p
            if p < 0 {
                if t > t1 { return false }
                t0 = max(t0, t)
            } else {
                if t < t0 { return false }
                t1 = min(t1, t)
            }
        }
        return t0 <= t1
    }

    static func contains(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        func side(_ u: CGPoint, _ v: CGPoint) -> CGFloat { (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x) }
        let s1 = side(a, b), s2 = side(b, c), s3 = side(c, a)
        return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
    }

    /// Möller–Trumbore, two-sided, as the renderer's picking does it.
    static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>,
                            _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = cross(d, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-9 else { return nil }
        let invDet = 1 / det
        let t0 = o - a
        let u = dot(t0, p) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let q = cross(t0, e1)
        let v = dot(d, q) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        return dot(e2, q) * invDet
    }
}

public extension Array where Element == String {
    /// A box select's names with cameras, lights and empties decided by their
    /// lines rather than their bounds.
    ///
    /// Box select measures a mesh by its bounding box. One of these has only a
    /// point for bounds, so without this a box over a camera's frame missed it
    /// unless it also covered the origin — and a spot light's ten-unit cone
    /// would be hit by any box near its bounds. The names keep scene order.
    ///
    /// With the overlays hidden (`drawn` false) a box takes none of them:
    /// Blender selects by drawing, and `Instance::object_sync` in
    /// `overlay_instance.cc` skips empties, cameras and lights when overlays
    /// are hidden, in the selection pass as in the viewport.
    func includingObjectOverlays(in rect: CGRect, scene: BKScene, view: OverlayView,
                                 drawn: Bool = true) -> [String] {
        guard rect.width > 1, rect.height > 1 else { return self }
        let meshes = Set(self)
        return scene.objects.compactMap { object in
            guard object.overlayDisplay != nil else {
                return meshes.contains(object.name) ? object.name : nil
            }
            return drawn && ObjectOverlayPicking.touches(object, rect: rect, in: scene, view: view)
                ? object.name : nil
        }
    }
}
