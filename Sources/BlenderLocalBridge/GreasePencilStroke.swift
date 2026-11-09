import Foundation
import simd

/// Draw Mode's settings as Blender holds them (`_blenderkit_gpencil.state`):
/// Stroke Placement, the Drawing Plane, Auto Keying and Additive Drawing, and
/// the active brush.
public struct GPDrawState: Equatable, Sendable {
    /// `gpencil_stroke_placement_view3d`: ORIGIN, CURSOR, SURFACE or STROKE.
    public var placement = "ORIGIN"
    /// `gpencil_sculpt.lock_axis`: VIEW, AXIS_Y (Front X-Z), AXIS_X (Side
    /// Y-Z), AXIS_Z (Top X-Y) or CURSOR.
    public var plane = "VIEW"
    public var autoKey = false
    public var additive = false
    public var cursor = SIMD3<Float>.zero
    /// The 3D cursor's rotation, rows as Blender writes `matrix.to_3x3()`.
    public var cursorRotation = matrix_identity_float3x3
    public var brush: GPBrush?

    public init() {}

    /// Read from `state()`'s JSON; nil for anything else.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        placement = root["placement"] as? String ?? placement
        plane = root["plane"] as? String ?? plane
        autoKey = root["auto_key"] as? Bool ?? false
        additive = root["additive"] as? Bool ?? false
        if let c = (root["cursor"] as? [NSNumber])?.map(\.floatValue), c.count == 3 { cursor = SIMD3(c[0], c[1], c[2]) }
        if let r = (root["cursor_rotation"] as? [NSNumber])?.map(\.floatValue), r.count == 9 {
            cursorRotation = simd_float3x3(rows: [SIMD3(r[0], r[1], r[2]), SIMD3(r[3], r[4], r[5]), SIMD3(r[6], r[7], r[8])])
        }
        if let b = root["brush"] as? [String: Any] { brush = GPBrush(b) }
    }
}

/// The Draw Mode brush's settings the stroke is made from.
public struct GPBrush: Equatable, Sendable {
    public var name = "Pencil"
    /// `gpencil_brush_type`: DRAW, ERASE, FILL or TINT.
    public var type = "DRAW"
    /// Size: a diameter in the view's pixels (Blender's `size`)…
    public var size: Float = 14
    /// …or in scene units (`unprojected_size`), when the Radius Unit
    /// (`use_locked_size`) is SCENE, as the Pencil's is.
    public var unprojectedSize: Float = 0.06
    public var sceneUnit = true
    public var strength: Float = 1
    public var usePressureSize = true
    public var usePressureStrength = true
    /// The pressure curves sampled evenly from 0 to 1.
    public var sizeCurve: [Float] = []
    public var strengthCurve: [Float] = []
    public var activeSmooth: Float = 0.35
    public var simplifyPixels: Float = 0.4
    public var hardness: Float = 1
    /// Erase brushes: SOFT (Dissolve), HARD (Point) or STROKE.
    public var eraserMode = "SOFT"

    public init() {}

    init(_ b: [String: Any]) {
        func f(_ key: String) -> Float? { (b[key] as? NSNumber)?.floatValue }
        name = b["name"] as? String ?? name
        type = b["type"] as? String ?? type
        size = f("size") ?? size
        unprojectedSize = f("unprojected_size") ?? unprojectedSize
        sceneUnit = (b["unit"] as? String ?? "SCENE") == "SCENE"
        strength = f("strength") ?? strength
        usePressureSize = b["use_pressure_size"] as? Bool ?? usePressureSize
        usePressureStrength = b["use_pressure_strength"] as? Bool ?? usePressureStrength
        sizeCurve = (b["size_curve"] as? [NSNumber])?.map(\.floatValue) ?? []
        strengthCurve = (b["strength_curve"] as? [NSNumber])?.map(\.floatValue) ?? []
        activeSmooth = f("active_smooth") ?? activeSmooth
        simplifyPixels = f("simplify_px") ?? simplifyPixels
        hardness = f("hardness") ?? hardness
        eraserMode = b["eraser_mode"] as? String ?? eraserMode
    }

    /// A pressure curve at `pressure`, between its samples; the identity
    /// where Blender sent none.
    public static func evaluate(_ curve: [Float], _ pressure: Float) -> Float {
        let p = min(max(pressure, 0), 1)
        guard curve.count >= 2 else { return p }
        let x = p * Float(curve.count - 1)
        let i = min(Int(x), curve.count - 2)
        let t = x - Float(i)
        return curve[i] + (curve[i + 1] - curve[i]) * t
    }

    /// The radius factor Blender takes from pressure
    /// (`radius_from_input_sample`): the Size curve when its pressure toggle
    /// is on, 1 otherwise.
    public func sizeFactor(_ pressure: Float) -> Float {
        usePressureSize ? Self.evaluate(sizeCurve, pressure) : 1
    }

    /// The point's opacity (`opacity_from_input_sample`): Strength, times the
    /// Strength curve when its pressure toggle is on.
    public func opacity(_ pressure: Float) -> Float {
        strength * (usePressureStrength ? Self.evaluate(strengthCurve, pressure) : 1)
    }
}

/// How the app's 3D View sees: what a stroke's screen points are projected
/// back through.
public struct GPView: Equatable, Sendable {
    public var viewProjection: simd_float4x4
    /// The view's size in points; a stroke's points are in the same units,
    /// top-left at the origin.
    public var size: SIMD2<Float>
    /// Toward what the view looks at: the normal of the View drawing plane.
    public var forward: SIMD3<Float>

    public init(viewProjection: simd_float4x4, size: SIMD2<Float>, forward: SIMD3<Float>) {
        self.viewProjection = viewProjection
        self.size = size
        self.forward = simd_normalize(forward)
    }

    public func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2)
    }

    /// The ray under a point of the view, from the near plane.
    public func ray(_ p: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let inverse = viewProjection.inverse
        let n = ndc(p)
        let near = inverse * SIMD4(n.x, n.y, 0, 1)
        let far = inverse * SIMD4(n.x, n.y, 1, 1)
        let a = SIMD3(near.x, near.y, near.z) / near.w
        let b = SIMD3(far.x, far.y, far.z) / far.w
        return (a, simd_normalize(b - a))
    }

    /// Where a world point is in the view, and its clip w (> 0 in front).
    public func project(_ world: SIMD3<Float>) -> (point: SIMD2<Float>, w: Float) {
        let c = viewProjection * SIMD4(world, 1)
        guard c.w > 1e-7 else { return (SIMD2(-1e6, -1e6), c.w) }
        let n = SIMD2(c.x / c.w, c.y / c.w)
        return (SIMD2((n.x + 1) / 2 * size.x, (1 - n.y) / 2 * size.y), c.w)
    }

    /// World units per view point at a world point: what a radius in points
    /// is there (Blender's `pixel_radius_to_world_space_radius`).
    public func worldPerPoint(at world: SIMD3<Float>) -> Float {
        let c = viewProjection * SIMD4(world, 1)
        guard c.w > 1e-7 else { return 0 }
        // A point is 2 / height of NDC, which at depth w is 2w / (P11 · height)
        // of the view's units (P11 the projection's vertical scale: the length
        // of the view-projection's second row, the view's rows being unit).
        // Unprojecting a moved point through the inverse instead lost 0.9 %
        // to float precision in depth (measured against Blender's
        // `region_2d_to_location_3d`).
        let p11 = simd_length(SIMD3(viewProjection[0][1], viewProjection[1][1], viewProjection[2][1]))
        guard p11 > 1e-9 else { return 0 }
        return 2 * c.w / (p11 * size.y)
    }
}

/// One sample of a stroke as the finger or Pencil gave it, in view points.
public struct GPSample: Equatable, Sendable {
    public var point: SIMD2<Float>
    public var pressure: Float
    public init(_ point: SIMD2<Float>, pressure: Float = 1) {
        self.point = point
        self.pressure = pressure
    }
}

/// What Draw Mode's Draw tool makes of a stroke, as Blender's draw operator
/// makes it (GPv3's `PaintOperation`), so the stroke written to Blender is
/// the one Blender would have made from the same input:
///
/// * samples closer than a point to the last one kept add nothing;
/// * Active Smooth evens the screen path (one pass at the brush's factor);
/// * Simplify (`simplify_pixel_threshold`) drops points within that many
///   pixels of the line through their neighbours (Ramer–Douglas–Peucker);
/// * each point is projected onto the drawing plane — Stroke Placement's
///   point (the object's origin, or the 3D cursor), the Drawing Plane's
///   normal (the view's, the object's X, Y or Z, or the cursor's Z) — and
///   taken into the layer's space;
/// * its radius is half the brush's Size, in scene units when the Radius
///   Unit is Scene or the size in pixels at the point's depth otherwise,
///   times the Size curve at its pressure; its opacity the Strength, times
///   the Strength curve.
public enum GreasePencilStroke {

    public struct Placement: Equatable {
        public var point: SIMD3<Float>
        public var normal: SIMD3<Float>
        public init(point: SIMD3<Float>, normal: SIMD3<Float>) {
            self.point = point
            self.normal = simd_normalize(normal)
        }
    }

    /// The plane a stroke is drawn on (`DrawingPlacement`): through the
    /// layer's origin in the world (Origin) or the 3D cursor (3D Cursor);
    /// Surface and Stroke placement need Blender's depth buffer and are drawn
    /// at the origin. `toWorld` is the object's world matrix times the
    /// layer's own.
    public static func placement(_ state: GPDrawState, toWorld: simd_float4x4, view: GPView) -> Placement {
        let origin = SIMD3(toWorld.columns.3.x, toWorld.columns.3.y, toWorld.columns.3.z)
        let point = state.placement == "CURSOR" ? state.cursor : origin
        // An axis plane follows the layer's axes: the normal is taken by the
        // transpose of the inverse, as Blender takes it.
        let normalMatrix = simd_float3x3(SIMD3(toWorld.columns.0.x, toWorld.columns.0.y, toWorld.columns.0.z),
                                         SIMD3(toWorld.columns.1.x, toWorld.columns.1.y, toWorld.columns.1.z),
                                         SIMD3(toWorld.columns.2.x, toWorld.columns.2.y, toWorld.columns.2.z))
            .inverse.transpose
        let normal: SIMD3<Float>
        switch state.plane {
        case "AXIS_Y": normal = normalMatrix * SIMD3(0, 1, 0)
        case "AXIS_X": normal = normalMatrix * SIMD3(1, 0, 0)
        case "AXIS_Z": normal = normalMatrix * SIMD3(0, 0, 1)
        case "CURSOR": normal = state.cursorRotation * SIMD3(0, 0, 1)
        default:       normal = view.forward
        }
        let length = simd_length(normal)
        return Placement(point: point, normal: length > 1e-9 ? normal : view.forward)
    }

    /// Where a point of the view lands on the plane; on the plane through
    /// `placement.point` facing the view where the ray runs along it.
    public static func project(_ p: SIMD2<Float>, onto placement: Placement, view: GPView) -> SIMD3<Float> {
        let ray = view.ray(p)
        if let hit = intersect(ray, placement.point, placement.normal) { return hit }
        return intersect(ray, placement.point, view.forward) ?? placement.point
    }

    private static func intersect(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                  _ point: SIMD3<Float>, _ normal: SIMD3<Float>) -> SIMD3<Float>? {
        let denominator = simd_dot(normal, ray.direction)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = simd_dot(normal, point - ray.origin) / denominator
        // Behind the eye: not where anything is drawn.
        guard t >= 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    /// Samples closer than `minimum` points to the last kept one dropped (the
    /// last sample is always kept).
    public static func thinned(_ samples: [GPSample], minimum: Float = 1) -> [GPSample] {
        guard samples.count > 2 else { return samples }
        var out = [samples[0]]
        for s in samples.dropFirst().dropLast() where simd_distance(s.point, out.last!.point) >= minimum {
            out.append(s)
        }
        if let last = samples.last {
            if out.count > 1, simd_distance(last.point, out.last!.point) < minimum { out[out.count - 1] = last }
            else { out.append(last) }
        }
        return out
    }

    /// One pass of smoothing toward the neighbours' midpoint, `factor` of
    /// the way, the ends held: the brush's Active Smooth.
    public static func smoothed(_ samples: [GPSample], factor: Float) -> [GPSample] {
        guard samples.count > 2, factor > 0 else { return samples }
        var out = samples
        for i in 1..<(samples.count - 1) {
            let mid = (samples[i - 1].point + samples[i + 1].point) / 2
            out[i].point = samples[i].point + (mid - samples[i].point) * min(factor, 1)
        }
        return out
    }

    /// Ramer–Douglas–Peucker over the screen path: points within `epsilon`
    /// points of the line through the ones kept either side go — and, given
    /// each sample's radius in points, within `epsilon` of the radius
    /// interpolated there too, so a straight stroke whose pressure changes
    /// keeps the points its width changes at.
    public static func simplified(_ samples: [GPSample], epsilon: Float, radii: [Float]? = nil) -> [GPSample] {
        guard samples.count > 2, epsilon > 0 else { return samples }
        let radii = radii?.count == samples.count ? radii : nil
        var keep = [Bool](repeating: false, count: samples.count)
        keep[0] = true
        keep[samples.count - 1] = true
        var stack = [(0, samples.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let pa = samples[a].point, pb = samples[b].point
            let d = pb - pa
            let length = simd_length(d)
            var worst = -Float.infinity
            var index = a
            for i in (a + 1)..<b {
                let p = samples[i].point
                var distance = length < 1e-9 ? simd_distance(p, pa) : abs(d.x * (pa.y - p.y) - d.y * (pa.x - p.x)) / length
                if let radii {
                    let t = length < 1e-9 ? 0 : min(max(simd_dot(p - pa, d) / (length * length), 0), 1)
                    distance = max(distance, abs(radii[i] - (radii[a] + (radii[b] - radii[a]) * t)))
                }
                if distance > worst { worst = distance; index = i }
            }
            if worst > epsilon {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return samples.indices.filter { keep[$0] }.map { samples[$0] }
    }

    /// One point of the stroke Blender is handed: in the layer's space, with
    /// its radius and opacity.
    public struct Made: Equatable {
        public var position: SIMD3<Float>
        public var radius: Float
        public var opacity: Float
        /// Where it lies in the world, for the live preview.
        public var world: SIMD3<Float>
    }

    /// A sample made into a point of the stroke.
    public static func point(_ sample: GPSample, brush: GPBrush, placement: Placement,
                             toWorld: simd_float4x4, view: GPView) -> Made {
        let world = project(sample.point, onto: placement, view: view)
        let local = toWorld.inverse * SIMD4(world, 1)
        let scale = simd_length(SIMD3(toWorld.columns.0.x, toWorld.columns.0.y, toWorld.columns.0.z))
        let radius: Float
        if brush.sceneUnit {
            radius = brush.unprojectedSize / 2
        } else {
            radius = brush.size / 2 * view.worldPerPoint(at: world) / max(scale, 1e-9)
        }
        return Made(position: SIMD3(local.x, local.y, local.z) / max(local.w, 1e-9),
                    radius: radius * brush.sizeFactor(sample.pressure),
                    opacity: min(max(brush.opacity(sample.pressure), 0), 1), world: world)
    }

    /// The whole stroke, from the samples as they came.
    public static func make(_ samples: [GPSample], state: GPDrawState, toWorld: simd_float4x4,
                            view: GPView) -> [Made] {
        guard !samples.isEmpty else { return [] }
        let brush = state.brush ?? GPBrush()
        var path = thinned(samples)
        path = smoothed(path, factor: brush.activeSmooth)
        let plane = placement(state, toWorld: toWorld, view: view)
        var made = path.map { point($0, brush: brush, placement: plane, toWorld: toWorld, view: view) }
        // Simplify sees each point's radius in points as well as its place.
        let scale = simd_length(SIMD3(toWorld.columns.0.x, toWorld.columns.0.y, toWorld.columns.0.z))
        let radii = made.map { m -> Float in
            let perPoint = view.worldPerPoint(at: m.world)
            return perPoint > 0 ? m.radius * scale / perPoint : 0
        }
        let kept = simplified(path, epsilon: brush.simplifyPixels, radii: radii)
        if kept.count != path.count {
            var keep = Set<Int>()
            var j = 0
            for (i, sample) in path.enumerated() where j < kept.count && sample == kept[j] {
                keep.insert(i)
                j += 1
            }
            made = made.indices.filter { keep.contains($0) }.map { made[$0] }
        }
        return made
    }

    /// The bytes `_blenderkit_gpencil.draw_stroke` reads: x, y, z, radius,
    /// opacity, five little-endian floats a point.
    public static func payload(_ points: [Made]) -> Data {
        var values: [Float] = []
        values.reserveCapacity(points.count * 5)
        for p in points { values += [p.position.x, p.position.y, p.position.z, p.radius, p.opacity] }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The Python that writes the stroke as one call
    /// (`_blenderkit_gpencil.draw_stroke`), the points as a bytes literal in
    /// base64.
    public static func python(object: String, points: [Made]) -> String {
        let encoded = payload(points).base64EncodedString()
        return "import _blenderkit_gpencil, base64\n"
            + "_blenderkit_gpencil.draw_stroke(\(Bpy.quote(object)), base64.b64decode('\(encoded)'), \(points.count))"
    }

    /// The Python that erases along a path (`_blenderkit_gpencil.erase`).
    public static func erasePython(object: String, view: GPView, path: [SIMD2<Float>], radius: Float,
                                   mode: String, strength: Float, activeLayerOnly: Bool) -> String {
        let vp = view.viewProjection
        var rows: [Float] = []
        for r in 0..<4 { for c in 0..<4 { rows.append(vp[c][r]) } }
        func n(_ v: Float) -> String { String(format: "%.9g", Double(v)) }
        let matrix = rows.map(n).joined(separator: ", ")
        let trail = path.flatMap { [$0.x, $0.y] }.map(n).joined(separator: ", ")
        return "import _blenderkit_gpencil\n"
            + "_blenderkit_gpencil.erase(\(Bpy.quote(object)), [\(matrix)], (\(n(view.size.x)), \(n(view.size.y))), "
            + "[\(trail)], \(n(radius)), mode='\(mode)', strength=\(n(strength)), "
            + "active_layer_only=\(activeLayerOnly ? "True" : "False"))"
    }
}
