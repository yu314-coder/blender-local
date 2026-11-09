import Foundation
import simd

/// What the viewport draws a Grease Pencil object with: its points, each
/// with a radius and a colour, and its primitives in Blender's order — for
/// each stroke its fill, then the stroke itself as one screen-facing ribbon
/// segment per pair of points (GreasePencil.metal). Built in Swift, so the
/// host suites test what the GPU is handed.
///
/// The order is the drawing order of Blender's 2D Layers: layers bottom
/// first, strokes as the drawing holds them, a stroke's fill under its line,
/// the onion skins under everything of the current frame. The shader turns
/// each primitive's order into a depth just in front of the one before, so a
/// later stroke covers an earlier one, and a stroke never blends over itself
/// where its segments overlap (a semi-transparent stroke would otherwise
/// darken at every joint).
public enum GreasePencilGeometry {

    /// `GPPoint` in GreasePencil.metal: position (object space) and radius
    /// (world units), then the colour, display-referred and not premultiplied.
    public struct Point: Equatable {
        public var position: SIMD4<Float>
        public var colour: SIMD4<Float>
        public init(_ p: SIMD3<Float>, radius: Float, colour: SIMD4<Float>) {
            position = SIMD4(p, radius)
            self.colour = colour
        }
    }

    /// `GPPrim`: a segment from point `a` to `b` (a dot when they are the
    /// same point), or a fill triangle `a b c` in `colour`. `order` is its
    /// place in the drawing order, from 1; the top bit marks a fill.
    public struct Primitive: Equatable {
        public var a: UInt32
        public var b: UInt32
        public var c: UInt32
        public var orderKind: UInt32
        public var colour: SIMD4<Float>

        public var isFill: Bool { orderKind & Primitive.fillBit != 0 }
        public var order: UInt32 { orderKind & ~Primitive.fillBit }
        public static let fillBit: UInt32 = 1 << 31
    }

    public struct Built: Equatable {
        public var points: [Point] = []
        public var primitives: [Primitive] = []
        /// The highest order used: what the depth trick needs room for.
        public var maxOrder: UInt32 = 0
        /// How many of the primitives are onion skins (they come first).
        public var ghostPrimitives = 0
        public init() {}
    }

    /// Past this many points a fill is a fan from its centre rather than
    /// ear-clipped, which costs n² (a fill is redrawn only when its drawing
    /// changes, but one 20,000-point outline should not stall a frame).
    public static let earClippingLimit = 1500

    /// Builds what the viewport draws. `ghosts`: the onion skins too (not
    /// while playing back, as Blender hides them then).
    public static func build(info: GreasePencilInfo, drawings: GreasePencilDrawings,
                             ghosts: Bool = true) -> Built {
        var out = Built()
        var order: UInt32 = 0
        // Onion skins first, so the frame's own strokes cover them.
        if ghosts {
            for block in drawings.blocks where block.onion != 0 {
                guard info.layers.indices.contains(block.layer) else { continue }
                let tint = ghostTint(info.onion, onion: block.onion)
                append(block.drawing, layer: info.layers[block.layer], materials: info.materials,
                       ghost: tint, order: &order, into: &out)
            }
            out.ghostPrimitives = out.primitives.count
        }
        for block in drawings.blocks where block.onion == 0 {
            guard info.layers.indices.contains(block.layer) else { continue }
            append(block.drawing, layer: info.layers[block.layer], materials: info.materials,
                   ghost: nil, order: &order, into: &out)
        }
        out.maxOrder = order
        return out
    }

    /// An onion skin's colour and opacity: Blender's before or after colour
    /// when Custom Colors is on (rgb, and 1 in w to replace the stroke's own),
    /// and the onion Opacity, faded with distance when Fade is on.
    public static func ghostTint(_ onion: GPOnionSettings, onion id: Int) -> SIMD4<Float> {
        let range = Float(max(id < 0 ? onion.before : onion.after, 1))
        var alpha = onion.factor
        if onion.fade {
            alpha *= max(0, 1 - (Float(abs(id)) - 1) / range)
        }
        let colour = id < 0 ? onion.beforeColour : onion.afterColour
        return SIMD4(onion.customColours ? colour : SIMD3(repeating: -1), alpha)
    }

    private static func append(_ d: GPDrawing, layer: GPLayer, materials: [GPMaterial?],
                               ghost: SIMD4<Float>?, order: inout UInt32, into out: inout Built) {
        guard !layer.hidden, d.pointCount > 0 else { return }
        let base = UInt32(out.points.count)
        let matrix = layer.matrix
        // Each point once, with the colour its stroke's material gives it.
        var pointColour = [SIMD4<Float>](repeating: .zero, count: d.pointCount)
        for s in 0..<d.strokeCount {
            let m = d.materials[s]
            guard m >= 0, m < materials.count, let material = materials[m] else { continue }
            for i in d.points(of: s) {
                let vertex = d.vertexColours.isEmpty ? nil : d.vertexColours[i]
                pointColour[i] = strokeColour(material: material, vertexColour: vertex,
                                              opacity: d.opacities[i], layer: layer, ghost: ghost)
            }
        }
        out.points.reserveCapacity(out.points.count + d.pointCount)
        for i in 0..<d.pointCount {
            var p = d.positions[i]
            if let matrix { p = (matrix * SIMD4(p, 1)).xyz }
            out.points.append(Point(p, radius: max(d.radii[i], 0), colour: pointColour[i]))
        }
        for s in 0..<d.strokeCount {
            let m = d.materials[s]
            guard m >= 0, m < materials.count, let material = materials[m], !material.hidden else { continue }
            let range = d.points(of: s)
            guard !range.isEmpty else { continue }
            if material.showFill, d.fillIDs[s] != 0, range.count >= 3 {
                order += 1
                let fillVertex = d.fillColours.isEmpty ? nil : d.fillColours[s]
                let colour = fillColour(material: material, fillColour: fillVertex, layer: layer, ghost: ghost)
                let polygon = range.map { d.positions[$0] }
                for t in triangulate(polygon) {
                    out.primitives.append(Primitive(a: base + UInt32(range.lowerBound + t.0),
                                                    b: base + UInt32(range.lowerBound + t.1),
                                                    c: base + UInt32(range.lowerBound + t.2),
                                                    orderKind: order | Primitive.fillBit, colour: colour))
                }
            }
            if material.showStroke, !(d.hideStroke.indices.contains(s) && d.hideStroke[s]) {
                order += 1
                let first = base + UInt32(range.lowerBound)
                if range.count == 1 {
                    out.primitives.append(Primitive(a: first, b: first, c: first, orderKind: order, colour: .zero))
                    continue
                }
                for k in 0..<(range.count - 1) {
                    out.primitives.append(Primitive(a: first + UInt32(k), b: first + UInt32(k + 1),
                                                    c: 0, orderKind: order, colour: .zero))
                }
                if d.cyclic[s], range.count > 2 {
                    out.primitives.append(Primitive(a: first + UInt32(range.count - 1), b: first,
                                                    c: 0, orderKind: order, colour: .zero))
                }
            }
        }
    }

    /// A point's colour as Blender's Solid view draws it: the material's
    /// stroke colour, the point's vertex colour mixed over it by its alpha,
    /// the layer's tint over that; alpha the material's times the point's
    /// opacity times the layer's. Then display-referred (sRGB).
    public static func strokeColour(material: GPMaterial, vertexColour: SIMD4<Float>?, opacity: Float,
                                    layer: GPLayer, ghost: SIMD4<Float>? = nil) -> SIMD4<Float> {
        var rgb = material.stroke.xyz
        if let v = vertexColour { rgb = simd_mix(rgb, v.xyz, SIMD3(repeating: min(max(v.w, 0), 1))) }
        rgb = simd_mix(rgb, layer.tint.xyz, SIMD3(repeating: min(max(layer.tint.w, 0), 1)))
        var alpha = material.stroke.w * min(max(opacity, 0), 1) * layer.opacity
        if let ghost {
            if ghost.x >= 0 { rgb = ghost.xyz }
            alpha *= ghost.w
        }
        return SIMD4(display(rgb), min(max(alpha, 0), 1))
    }

    /// A fill's colour: the material's fill colour with the stroke's own fill
    /// colour (`fill_color`) mixed over it by its alpha, the layer's tint.
    public static func fillColour(material: GPMaterial, fillColour: SIMD4<Float>?, layer: GPLayer,
                                  ghost: SIMD4<Float>? = nil) -> SIMD4<Float> {
        var rgb = material.fill.xyz
        if let f = fillColour { rgb = simd_mix(rgb, f.xyz, SIMD3(repeating: min(max(f.w, 0), 1))) }
        rgb = simd_mix(rgb, layer.tint.xyz, SIMD3(repeating: min(max(layer.tint.w, 0), 1)))
        var alpha = material.fill.w * layer.opacity
        if let ghost {
            if ghost.x >= 0 { rgb = ghost.xyz }
            alpha *= ghost.w
        }
        return SIMD4(display(rgb), min(max(alpha, 0), 1))
    }

    /// Scene-linear to the display's sRGB, as Blender's Standard view
    /// transform shows a colour.
    public static func display(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        func one(_ c: Float) -> Float {
            let x = min(max(c, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return SIMD3(one(linear.x), one(linear.y), one(linear.z))
    }

    /// The inverse of `display`, for a colour picked on screen.
    public static func linear(_ display: SIMD3<Float>) -> SIMD3<Float> {
        func one(_ c: Float) -> Float {
            let x = min(max(c, 0), 1)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(one(display.x), one(display.y), one(display.z))
    }

    // MARK: fills

    /// The triangles that fill a stroke's outline, as indices into it: ear
    /// clipping in the plane the outline lies closest to (Newell's normal),
    /// so a concave shape fills as drawn. A shape with no area fills nothing.
    public static func triangulate(_ polygon: [SIMD3<Float>]) -> [(Int, Int, Int)] {
        let n = polygon.count
        guard n >= 3 else { return [] }
        // Newell's normal, then the axis it leans on most is dropped.
        var normal = SIMD3<Float>.zero
        for i in 0..<n {
            let a = polygon[i], b = polygon[(i + 1) % n]
            normal.x += (a.y - b.y) * (a.z + b.z)
            normal.y += (a.z - b.z) * (a.x + b.x)
            normal.z += (a.x - b.x) * (a.y + b.y)
        }
        let size = simd_length(normal)
        guard size > 1e-12 else { return [] }
        let absolute = simd_abs(normal)
        let drop = absolute.x >= absolute.y && absolute.x >= absolute.z ? 0 : (absolute.y >= absolute.z ? 1 : 2)
        let flip: Float = normal[drop] < 0 ? -1 : 1
        let flat: [SIMD2<Float>] = polygon.map {
            switch drop {
            case 0: return SIMD2($0.y * flip, $0.z)
            case 1: return SIMD2($0.z * flip, $0.x)
            default: return SIMD2($0.x * flip, $0.y)
            }
        }
        // Points that repeat the one before add nothing and break the tests.
        var kept: [Int] = []
        kept.reserveCapacity(n)
        let epsilon: Float = 1e-12
        for i in 0..<n where kept.isEmpty || simd_distance_squared(flat[kept.last!], flat[i]) > epsilon {
            kept.append(i)
        }
        if kept.count > 1, simd_distance_squared(flat[kept[0]], flat[kept.last!]) <= epsilon { kept.removeLast() }
        guard kept.count >= 3 else { return [] }
        // Counter-clockwise, so an ear is a left turn.
        var area: Float = 0
        for k in 0..<kept.count {
            let a = flat[kept[k]], b = flat[kept[(k + 1) % kept.count]]
            area += a.x * b.y - b.x * a.y
        }
        if area < 0 { kept.reverse() }
        if kept.count > earClippingLimit { return fan(kept, flat) }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func inside(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
        }
        var ring = kept
        var out: [(Int, Int, Int)] = []
        out.reserveCapacity(ring.count - 2)
        var i = 0
        var misses = 0
        while ring.count > 3 {
            let count = ring.count
            let ia = ring[(i + count - 1) % count], ib = ring[i % count], ic = ring[(i + 1) % count]
            let a = flat[ia], b = flat[ib], c = flat[ic]
            var ear = cross(a, b, c) > 0
            if ear {
                for k in ring where k != ia && k != ib && k != ic {
                    let p = flat[k]
                    // Only a point at a different place can block the ear.
                    if p == a || p == b || p == c { continue }
                    if inside(p, a, b, c) { ear = false; break }
                }
            }
            if ear || misses >= count {
                // No ear in a whole turn: a self-crossing outline. One is cut
                // anyway, so the loop ends.
                out.append((ia, ib, ic))
                ring.remove(at: i % count)
                misses = 0
                if i >= ring.count { i = 0 }
            } else {
                i = (i + 1) % count
                misses += 1
            }
        }
        out.append((ring[0], ring[1], ring[2]))
        return out
    }

    private static func fan(_ ring: [Int], _ flat: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        for k in 1..<(ring.count - 1) { out.append((ring[0], ring[k], ring[k + 1])) }
        return out
    }
}

// MARK: - Picking

public extension GreasePencilGeometry {
    /// How far a point of the view (in points, top-left origin) is from a
    /// Grease Pencil object's strokes as drawn at the current frame: 0 inside
    /// a filled stroke or within a stroke's own radius, the distance past it
    /// otherwise; nil when nothing is within `reach`. `toClip` takes the
    /// object's space to clip space (view-projection times the object's
    /// matrix), `scale` the object's, `focal` the view's points per world
    /// unit at w = 1. A tap in Object Mode selects the nearest such object,
    /// as a click on a stroke selects it in Blender.
    static func pickDistance(_ point: SIMD2<Float>, info: GreasePencilInfo, drawings: GreasePencilDrawings,
                             toClip: simd_float4x4, size: SIMD2<Float>, scale: Float, focal: Float,
                             reach: Float) -> Float? {
        func screen(_ p: SIMD3<Float>) -> (SIMD2<Float>, Float)? {
            let c = toClip * SIMD4(p, 1)
            guard c.w > 1e-6 else { return nil }
            return (SIMD2((c.x / c.w + 1) / 2 * size.x, (1 - c.y / c.w) / 2 * size.y), c.w)
        }
        var best: Float?
        for block in drawings.blocks where block.onion == 0 {
            guard info.layers.indices.contains(block.layer), !info.layers[block.layer].hidden else { continue }
            let layer = info.layers[block.layer]
            let d = block.drawing
            let projected: [(SIMD2<Float>, Float)?] = d.positions.map { position in
                screen(layer.matrix.map { m in (m * SIMD4(position, 1)).xyz } ?? position)
            }
            for s in 0..<d.strokeCount {
                let m = d.materials[s]
                guard m >= 0, m < info.materials.count, let material = info.materials[m], !material.hidden
                else { continue }
                let range = d.points(of: s)
                if material.showFill, d.fillIDs[s] != 0, range.count >= 3 {
                    let polygon = range.compactMap { projected[$0]?.0 }
                    if polygon.count == range.count, contains(polygon, point) { return 0 }
                }
                guard material.showStroke, !(d.hideStroke.indices.contains(s) && d.hideStroke[s]) else { continue }
                var indices = Array(range)
                if d.cyclic[s], range.count > 2 { indices.append(range.lowerBound) }
                for k in 0..<max(indices.count - 1, 1) {
                    let i = indices[k], j = indices[min(k + 1, indices.count - 1)]
                    guard let (a, wa) = projected[i], let (b, _) = projected[j] else { continue }
                    let radius = d.radii[i] * scale * focal / wa
                    let distance = max(0, segmentDistance(point, a, b) - radius)
                    if distance <= reach, best == nil || distance < best! { best = distance }
                }
            }
        }
        return best
    }

    static func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = b - a
        let l2 = simd_length_squared(d)
        let t = l2 > 1e-12 ? min(max(simd_dot(p - a, d) / l2, 0), 1) : 0
        return simd_distance(p, a + d * t)
    }

    /// Even-odd: whether `p` is inside the outline.
    static func contains(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
