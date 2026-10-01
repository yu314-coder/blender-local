import Foundation
import simd

/// Turns the gizmo into triangles.
///
/// Metal has no line width, so every shaft, ring and outline is a camera-facing
/// ribbon: a quad twisted to keep its flat side toward the eye. That is what
/// gives the gizmo an even apparent thickness from any angle, and it is the
/// same trick Blender's own overlay shaders use.
extension TransformGizmo {

    /// World units per on-screen point, derived from the gizmo's own size so
    /// handle thicknesses can be written in points and stay honest at any zoom.
    private var pointScale: Float { radius / Self.screenRadius }

    private func colour(for handle: Handle, highlighted: Handle?) -> SIMD4<Float> {
        if handle == highlighted { return Self.highlightColour }
        switch handle {
        case .axis(let i):  return Self.axisColours[i]
        case .plane(let i): return Self.axisColours[i]
        case .screen:       return Self.screenColour
        }
    }

    /// Every triangle of the gizmo, ready to hand to the grid pipeline.
    func triangles(eye: SIMD3<Float>, highlighted: Handle? = nil) -> [GridVertex] {
        var out: [GridVertex] = []
        let toEye = normalize(eye - origin)

        switch mode {
        case .translate:
            for i in 0..<3 {
                let c = colour(for: .axis(i), highlighted: highlighted)
                let wide = highlighted == .axis(i)
                let start = origin + axes[i] * (radius * 0.16)
                let end = origin + axes[i] * (radius * 0.86)
                ribbon(start, end, width: (wide ? 5 : 3) * pointScale, eye: eye, colour: c, into: &out)
                // A flat, camera-facing arrowhead reads as a cone from every
                // angle and costs three vertices instead of a fan.
                arrowhead(at: end, along: axes[i], length: 15 * pointScale,
                          half: (wide ? 7 : 5.5) * pointScale, eye: eye, colour: c, into: &out)
            }
            planeHandles(eye: eye, highlighted: highlighted, into: &out)
            disc(centre: origin, radius: 7 * pointScale, normal: toEye,
                 colour: colour(for: .screen, highlighted: highlighted), into: &out)

        case .scale:
            for i in 0..<3 {
                let c = colour(for: .axis(i), highlighted: highlighted)
                let wide = highlighted == .axis(i)
                let start = origin + axes[i] * (radius * 0.16)
                let end = origin + axes[i] * (radius * 0.88)
                ribbon(start, end, width: (wide ? 5 : 3) * pointScale, eye: eye, colour: c, into: &out)
                quad(centre: end, normal: toEye, half: (wide ? 7 : 5.5) * pointScale,
                     colour: c, into: &out)
            }
            planeHandles(eye: eye, highlighted: highlighted, into: &out)
            disc(centre: origin, radius: 7 * pointScale, normal: toEye,
                 colour: colour(for: .screen, highlighted: highlighted), into: &out)

        case .rotate:
            for i in 0..<3 {
                let c = colour(for: .axis(i), highlighted: highlighted)
                let wide = highlighted == .axis(i)
                ring(ringPoints(axisIndex: i, scale: 0.95),
                     width: (wide ? 5 : 3) * pointScale, eye: eye, colour: c, into: &out)
            }
            // The view-aligned ring, drawn last so it sits over the others.
            let c = colour(for: .screen, highlighted: highlighted)
            let u = normalize(cross(toEye, abs(toEye.z) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)))
            let v = cross(toEye, u)
            let r = radius * 1.18
            let pts = (0...64).map { s -> SIMD3<Float> in
                let t = Float(s) / 64 * 2 * .pi
                return origin + (u * cos(t) + v * sin(t)) * r
            }
            ring(pts, width: (highlighted == .screen ? 4 : 2) * pointScale,
                 eye: eye, colour: c, into: &out)
        }
        return out
    }

    private func planeHandles(eye: SIMD3<Float>, highlighted: Handle?, into out: inout [GridVertex]) {
        for i in 0..<3 {
            let (j, k) = ((i + 1) % 3, (i + 2) % 3)
            let centre = origin + (axes[j] + axes[k]) * (radius * 0.42)
            let half = radius * 0.14
            var c = colour(for: .plane(i), highlighted: highlighted)
            // Blender's plane handles are translucent fills with a solid edge,
            // so they read as a surface rather than as a third arrow.
            let fill = SIMD4(c.x, c.y, c.z, highlighted == .plane(i) ? 0.55 : 0.28)
            let a = centre - axes[j] * half - axes[k] * half
            let b = centre + axes[j] * half - axes[k] * half
            let d = centre + axes[j] * half + axes[k] * half
            let e = centre - axes[j] * half + axes[k] * half
            out += [GridVertex(position: a, color: fill), GridVertex(position: b, color: fill),
                    GridVertex(position: d, color: fill),
                    GridVertex(position: a, color: fill), GridVertex(position: d, color: fill),
                    GridVertex(position: e, color: fill)]
            c.w = 1
            for (p, q) in [(a, b), (b, d), (d, e), (e, a)] {
                ribbon(p, q, width: 1.6 * pointScale, eye: eye, colour: c, into: &out)
            }
        }
    }

    // MARK: primitive builders

    /// A quad from `a` to `b`, rotated so its face points at the eye.
    private func ribbon(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float,
                        eye: SIMD3<Float>, colour: SIMD4<Float>, into out: inout [GridVertex]) {
        let along = b - a
        guard length(along) > 1e-6 else { return }
        let toEye = eye - (a + b) * 0.5
        var side = cross(along, toEye)
        // Dead-on: the segment points at the eye and there is no unique side.
        // Any perpendicular will do, because the ribbon is a dot on screen.
        if length(side) < 1e-6 { side = cross(along, SIMD3(0, 0, 1)) }
        if length(side) < 1e-6 { side = cross(along, SIMD3(1, 0, 0)) }
        let s = normalize(side) * (width * 0.5)
        out += [GridVertex(position: a - s, color: colour),
                GridVertex(position: a + s, color: colour),
                GridVertex(position: b + s, color: colour),
                GridVertex(position: a - s, color: colour),
                GridVertex(position: b + s, color: colour),
                GridVertex(position: b - s, color: colour)]
    }

    private func ring(_ points: [SIMD3<Float>], width: Float, eye: SIMD3<Float>,
                      colour: SIMD4<Float>, into out: inout [GridVertex]) {
        for i in 0..<max(points.count - 1, 0) {
            ribbon(points[i], points[i + 1], width: width, eye: eye, colour: colour, into: &out)
        }
    }

    private func arrowhead(at base: SIMD3<Float>, along dir: SIMD3<Float>, length len: Float,
                           half: Float, eye: SIMD3<Float>, colour: SIMD4<Float>,
                           into out: inout [GridVertex]) {
        let toEye = eye - base
        var side = cross(dir, toEye)
        if length(side) < 1e-6 { side = cross(dir, SIMD3(0, 0, 1)) }
        if length(side) < 1e-6 { side = cross(dir, SIMD3(1, 0, 0)) }
        let s = normalize(side) * half
        let tip = base + normalize(dir) * len
        out += [GridVertex(position: base - s, color: colour),
                GridVertex(position: base + s, color: colour),
                GridVertex(position: tip, color: colour)]
    }

    /// A camera-facing square, used for the scale gizmo's handle caps.
    private func quad(centre: SIMD3<Float>, normal: SIMD3<Float>, half: Float,
                      colour: SIMD4<Float>, into out: inout [GridVertex]) {
        var u = cross(normal, SIMD3(0, 0, 1))
        if length(u) < 1e-6 { u = cross(normal, SIMD3(1, 0, 0)) }
        u = normalize(u) * half
        let v = normalize(cross(normal, u)) * half
        let a = centre - u - v, b = centre + u - v, c = centre + u + v, d = centre - u + v
        out += [GridVertex(position: a, color: colour), GridVertex(position: b, color: colour),
                GridVertex(position: c, color: colour),
                GridVertex(position: a, color: colour), GridVertex(position: c, color: colour),
                GridVertex(position: d, color: colour)]
    }

    private func disc(centre: SIMD3<Float>, radius r: Float, normal: SIMD3<Float>,
                      colour: SIMD4<Float>, into out: inout [GridVertex]) {
        var u = cross(normal, SIMD3(0, 0, 1))
        if length(u) < 1e-6 { u = cross(normal, SIMD3(1, 0, 0)) }
        u = normalize(u)
        let v = normalize(cross(normal, u))
        let segments = 20
        for i in 0..<segments {
            let t0 = Float(i) / Float(segments) * 2 * .pi
            let t1 = Float(i + 1) / Float(segments) * 2 * .pi
            out += [GridVertex(position: centre, color: colour),
                    GridVertex(position: centre + (u * cos(t0) + v * sin(t0)) * r, color: colour),
                    GridVertex(position: centre + (u * cos(t1) + v * sin(t1)) * r, color: colour)]
        }
    }
}
