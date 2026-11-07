import CoreGraphics
import simd

/// Shift+B, Blender's Zoom Region (`view3d.zoom_border`,
/// view3d_navigate_zoom_border.cc, 5.2.1): a box dragged over the view, and
/// the view zoomed in on what is inside it.
///
/// Blender's exec, step by step:
/// - The nearest surface inside the box, from the depth buffer
///   (`view3d_depth_near`): here the nearest hit of a grid of rays across it
///   (`CursorTool.nearestDepth`).
/// - The box made the view's shape about its middle (`BLI_rcti_resize_x/y`).
/// - In perspective, the view's centre goes to the box's middle at that depth
///   and the distance becomes half the box's diagonal there, times the lens
///   over the 36 mm sensor: with Blender's viewport zoom of 2
///   (`CAMERA_PARAM_ZOOM_INIT_PERSP`), the view's longer half then spans that
///   half-diagonal. Nothing under the box: Blender refuses, "Depth too large".
/// - In orthographic, the distance scales by the box's share of the view, and
///   the centre goes to the box's middle — at the surface's depth when there
///   is one, else in the plane of the old centre.
extension ViewportCamera {

    /// The box made the view's shape about its middle, as Blender widens or
    /// heightens it.
    static func zoomRegionRect(_ box: CGRect, size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let aspect = size.width / size.height
        var rect = box
        if box.width / box.height < aspect {
            let w = box.height * aspect
            rect = CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height)
        } else {
            let h = box.width / aspect
            rect = CGRect(x: box.minX, y: box.midY - h / 2, width: box.width, height: h)
        }
        return rect
    }

    /// The point `depth` ahead of the eye (along the view's direction) on the
    /// line through a view point (points, y down) of a view `size` across.
    func point(at p: CGPoint, depth: Float, size: CGSize) -> SIMD3<Float>? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ndc = SIMD2(Float(p.x / size.width) * 2 - 1, 1 - Float(p.y / size.height) * 2)
        let (o, d) = ray(atNDC: ndc, aspect: Float(size.width / size.height))
        let forward = simd_normalize(target - eye)
        let along = simd_dot(d, forward)
        guard along > 1e-6, o.x.isFinite else { return nil }
        let t = (depth - simd_dot(o - eye, forward)) / along
        return o + d * t
    }

    /// The view zoomed in on `box`, or nil where Blender changes nothing:
    /// a box with no area, or in perspective nothing under it.
    func zoomedIn(on box: CGRect, size: CGSize, depth: Float?) -> ViewportCamera? {
        guard size.width > 0, size.height > 0, box.width >= 1, box.height >= 1 else { return nil }
        let rect = Self.zoomRegionRect(box, size: size)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var out = self
        if isOrthographic {
            let scale = Float(max(rect.width / size.width, rect.height / size.height))
            out.distance = Self.zoomRegionDistance(distance * scale, near: near)
            let at = depth ?? simd_dot(target - eye, simd_normalize(target - eye))
            guard let p = point(at: centre, depth: at, size: size) else { return nil }
            out.target = p
        } else {
            guard let depth, depth > 0,
                  let p = point(at: centre, depth: depth, size: size),
                  let corner = point(at: CGPoint(x: rect.minX, y: rect.maxY), depth: depth, size: size)
            else { return nil }
            let halfDiagonal = simd_distance(p, corner)
            let aspect = Float(size.width / size.height)
            out.target = p
            out.distance = Self.zoomRegionDistance(halfDiagonal / (tan(fovY / 2) * max(aspect, 1)), near: near)
        }
        guard out.target.x.isFinite, out.distance.isFinite else { return nil }
        return out
    }

    /// Blender's soft range for the distance (`ED_view3d_dist_soft_range_get`
    /// keeps it past one and a half clip starts); the far end is the app's
    /// zoom's.
    static func zoomRegionDistance(_ d: Float, near: Float) -> Float {
        min(max(d, near * 1.5), 500)
    }
}
