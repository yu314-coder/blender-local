import Foundation
import simd
import CoreGraphics

/// Which objects a dragged rectangle covers.
///
/// Box select is how selection is done in Blender — it is the default tool,
/// and tapping one object at a time is the exception rather than the rule. It
/// was missing here, and the button for it was hidden rather than built, which
/// left the viewport with no way to select more than one thing except by
/// tapping each with Extend held.
///
/// Kept out of the view layer and pure over its inputs so the part that
/// decides *what* gets selected can be tested without a Metal view, a camera
/// on screen, or a gesture.
public enum BoxSelect {

    /// Projects a world point into view coordinates, or nil when it is behind
    /// the eye.
    public static func project(_ world: SIMD3<Float>,
                               viewProjection: simd_float4x4,
                               size: CGSize) -> CGPoint? {
        let clip = viewProjection * SIMD4(world, 1)
        guard clip.w > 1e-5 else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        return CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * size.width,
                       y: CGFloat(1 - (ndc.y * 0.5 + 0.5)) * size.height)
    }

    /// The names of the objects the rectangle covers.
    ///
    /// An object counts when any part of it is inside, not only its origin.
    /// Blender's box select works on what you can see, and an origin test
    /// would miss a large object whose centre happens to sit outside the drag
    /// — which reads as the selection simply not working.
    ///
    /// The test is against the projected corners of the world-space bounding
    /// box: eight points, cheap, and right for anything that is not wildly
    /// concave. A per-vertex test would be exact and would also walk every
    /// vertex of every object on every drag.
    public static func objects(in rect: CGRect,
                               objects candidates: [(name: String,
                                                     bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                                                     visible: Bool)],
                               viewProjection: simd_float4x4,
                               size: CGSize) -> [String] {
        guard rect.width > 1, rect.height > 1 else { return [] }
        var hit: [String] = []
        for candidate in candidates where candidate.visible {
            let (lo, hi) = candidate.bounds
            var screen: [CGPoint] = []
            screen.reserveCapacity(8)
            for corner in 0..<8 {
                let p = SIMD3(corner & 1 == 0 ? lo.x : hi.x,
                              corner & 2 == 0 ? lo.y : hi.y,
                              corner & 4 == 0 ? lo.z : hi.z)
                if let point = project(p, viewProjection: viewProjection, size: size) {
                    screen.append(point)
                }
            }
            guard !screen.isEmpty else { continue }   // entirely behind the eye

            // Any corner inside the rectangle is a hit; so is a rectangle that
            // sits wholly inside the object's own screen extent, which is what
            // a small drag over a big object looks like.
            if screen.contains(where: { rect.contains($0) }) {
                hit.append(candidate.name)
                continue
            }
            let xs = screen.map(\.x), ys = screen.map(\.y)
            let extent = CGRect(x: xs.min()!, y: ys.min()!,
                                width: xs.max()! - xs.min()!,
                                height: ys.max()! - ys.min()!)
            if extent.intersects(rect) { hit.append(candidate.name) }
        }
        return hit
    }

    /// A rectangle from two touch points, in either drag direction.
    public static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}
