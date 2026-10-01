import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Image to 3D Model's full 3D mode with TripoSG, around the network:
///
/// 1. `prepare`: the subject on white, cropped with 10% padding to a square
///    (TripoSG's own preparation), then DINOv2's 256² resize and 224² centre
///    crop; and the same square kept at 512² with its coverage, for the
///    texture.
/// 2. TripoSGModel: DINOv2, the flow, the decoder.
/// 3. `surface`: the decoder queried coarse to fine — a 65³ grid, then only
///    the cells near the surface at 129³ and 257³ — and marching cubes. The
///    shape is in TripoSG's frame: Y up, facing +Z.
/// 4. Blender decimates and unwraps it (`prepare_full`).
/// 5. `fitPose`: TripoSG faces its shape forward whatever the photo's
///    viewpoint, so the view is found by matching the shape's silhouette to
///    the cut-out over azimuth and elevation.
/// 6. `bake`: the photo where that view sees the surface; the photo again,
///    mirrored, on the other side of the shape's symmetry plane; the nearest
///    painted colour everywhere else.
/// 7. `finish_full` turns Y up into Blender's Z up, the front to -Y.
public enum TripoSGPipeline {

    // MARK: 1. The picture

    public struct Prepared: Sendable {
        /// 3 × 224 × 224, normalised: what DINOv2 sees.
        public var pixels: [Float]
        /// 512² × 3 colour and 512² coverage of the padded square, rows top to
        /// bottom.
        public var photo: [Float]
        public var alpha: [Float]
        public static let photoSize = 512
    }

    public static func prepare(image: CGImage, mask: ImageToModel.Mask) -> Prepared? {
        let w = image.width, h = image.height
        guard mask.width == w, mask.height == h else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where mask.values[y * w + x] > 12 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { b -> Bool in
            guard let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: space, bitmapInfo: info) else { return false }
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return nil }
        for p in 0..<(w * h) {
            let a = UInt32(mask.values[p])
            for c in 0..<3 { rgba[p * 4 + c] = UInt8(UInt32(rgba[p * 4 + c]) * a / 255) }
            rgba[p * 4 + 3] = UInt8(a)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cutout = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let crop = cutout.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }

        // TripoSG's padding: 10% of the longer side on each end of it, the
        // shorter side centred.
        let cw = crop.width, ch = crop.height
        let side = max(cw, ch) + 2 * Int(Double(max(cw, ch)) * 0.1)
        func square(_ n: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: n * n * 4)
            let ok = out.withUnsafeMutableBytes { b -> Bool in
                guard let c = CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                        space: space, bitmapInfo: info) else { return false }
                c.interpolationQuality = .high
                let s = CGFloat(n) / CGFloat(side)
                let dw = CGFloat(cw) * s, dh = CGFloat(ch) * s
                c.draw(crop, in: CGRect(x: (CGFloat(n) - dw) / 2, y: (CGFloat(n) - dh) / 2, width: dw, height: dh))
                return true
            }
            return ok ? out : nil
        }
        // DINOv2's processor: shortest edge to 256, centre 224.
        guard let at256 = square(256), let at512 = square(Prepared.photoSize) else { return nil }
        let n = TripoSGModel.imageSize
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        var pixels = [Float](repeating: 0, count: 3 * n * n)
        for y in 0..<n { for x in 0..<n {
            let p = ((y + 16) * 256 + (x + 16)) * 4
            let a = Float(at256[p + 3]) / 255
            for c in 0..<3 {
                let onWhite = Float(at256[p + c]) / 255 + (1 - a)
                pixels[c * n * n + y * n + x] = (onWhite - mean[c]) / std[c]
            }
        } }
        let m = Prepared.photoSize
        var photo = [Float](repeating: 1, count: m * m * 3), alpha = [Float](repeating: 0, count: m * m)
        for p in 0..<(m * m) {
            let a = Float(at512[p * 4 + 3]) / 255
            alpha[p] = a
            for c in 0..<3 { photo[p * 3 + c] = a > 1e-3 ? min(Float(at512[p * 4 + c]) / 255 / a, 1) : 1 }
        }
        return Prepared(pixels: pixels, photo: photo, alpha: alpha)
    }

    // MARK: 3. The surface

    /// The shape's surface, queried coarse to fine. `logits` answers the
    /// decoder's logits (positive outside) for N × 3 positions.
    public static func surface(resolution: Int = 256, progress: ((Double) -> Void)? = nil,
                               logits: ([Float]) -> [Float]) -> (mesh: MarchingCubes.Mesh, queries: Int) {
        // Positive inside, as marching cubes takes it.
        func query(_ points: [Float]) -> [Float] { logits(points).map { -$0 } }
        let bound = TripoSGModel.bound
        var levels = [64]
        while levels.last! < resolution { levels.append(levels.last! * 2) }
        var field: [Float] = []
        var queries = 0
        var previous = 0
        for (index, cells) in levels.enumerated() {
            let n = cells + 1
            let spacing = 2 * bound / Float(cells)
            func position(_ i: Int, _ j: Int, _ k: Int) -> [Float] {
                [-bound + Float(i) * spacing, -bound + Float(j) * spacing, -bound + Float(k) * spacing]
            }
            if index == 0 {
                var points = [Float](); points.reserveCapacity(n * n * n * 3)
                for i in 0..<n { for j in 0..<n { for k in 0..<n { points += position(i, j, k) } } }
                field = query(points)
                queries += n * n * n
            } else {
                // Upsample the coarser field, then re-query every fine point of
                // a cell whose coarse parent crossed the surface, or touches one.
                let pn = previous + 1
                var fine = [Float](repeating: 0, count: n * n * n)
                @inline(__always) func coarse(_ i: Int, _ j: Int, _ k: Int) -> Float { field[(i * pn + j) * pn + k] }
                for i in 0..<n { for j in 0..<n { for k in 0..<n {
                    let ci = i / 2, cj = j / 2, ck = k / 2
                    let ti = i % 2, tj = j % 2, tk = k % 2
                    var v: Float = 0
                    for di in 0...ti { for dj in 0...tj { for dk in 0...tk {
                        v += coarse(min(ci + di, pn - 1), min(cj + dj, pn - 1), min(ck + dk, pn - 1))
                    } } }
                    fine[(i * n + j) * n + k] = v / Float((ti + 1) * (tj + 1) * (tk + 1))
                } } }
                var crossing = [Bool](repeating: false, count: previous * previous * previous)
                for i in 0..<previous { for j in 0..<previous { for k in 0..<previous {
                    var inside = false, outside = false
                    for di in 0...1 { for dj in 0...1 { for dk in 0...1 {
                        if coarse(i + di, j + dj, k + dk) > 0 { inside = true } else { outside = true }
                    } } }
                    if inside && outside { crossing[(i * previous + j) * previous + k] = true }
                } } }
                var band = [Bool](repeating: false, count: previous * previous * previous)
                for i in 0..<previous { for j in 0..<previous { for k in 0..<previous
                where crossing[(i * previous + j) * previous + k] {
                    for di in -1...1 { for dj in -1...1 { for dk in -1...1 {
                        let a = i + di, b = j + dj, c = k + dk
                        if a >= 0, b >= 0, c >= 0, a < previous, b < previous, c < previous {
                            band[(a * previous + b) * previous + c] = true
                        }
                    } } }
                } } }
                var marked = [Bool](repeating: false, count: n * n * n)
                var indices: [Int] = []
                var points: [Float] = []
                for i in 0..<previous { for j in 0..<previous { for k in 0..<previous
                where band[(i * previous + j) * previous + k] {
                    for di in 0...2 { for dj in 0...2 { for dk in 0...2 {
                        let fi = 2 * i + di, fj = 2 * j + dj, fk = 2 * k + dk
                        let f = (fi * n + fj) * n + fk
                        if !marked[f] { marked[f] = true; indices.append(f); points += position(fi, fj, fk) }
                    } } }
                } } }
                let values = query(points)
                queries += indices.count
                for (f, v) in zip(indices, values) { fine[f] = v }
                field = fine
            }
            previous = cells
            progress?(Double(index + 1) / Double(levels.count))
        }
        let cells = levels.last!
        let mesh = MarchingCubes.extract(field: field, resolution: cells + 1, level: 0,
                                         origin: SIMD3(repeating: -bound), spacing: 2 * bound / Float(cells))
        return (mesh, queries)
    }

    /// positions.bin (float32 × 3 per vertex), triangles.bin (int32 × 3 per
    /// triangle) and meta.json, for `_blenderkit_image3d.prepare_full`.
    public static func write(_ mesh: MarchingCubes.Mesh, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try mesh.positions.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: folder.appendingPathComponent("positions.bin"))
        try mesh.triangles.map { Int32($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: folder.appendingPathComponent("triangles.bin"))
        let meta = ["vertices": mesh.positions.count, "triangles": mesh.triangleCount]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("meta.json"))
    }

    // MARK: 4. Blender

    /// Blender's unwrapped triangles, as `prepare_full` wrote them: each
    /// triangle's three corners (float32 × 9) and their UVs (float32 × 6).
    public struct Unwrapped: Sendable {
        public var corners: [SIMD3<Float>]
        public var uvs: [SIMD2<Float>]
        public var triangleCount: Int { corners.count / 3 }

        public init(corners: [SIMD3<Float>], uvs: [SIMD2<Float>]) {
            self.corners = corners; self.uvs = uvs
        }

        public init(folder: URL) throws {
            let c = try Data(contentsOf: folder.appendingPathComponent("unwrapped_positions.bin"))
            let u = try Data(contentsOf: folder.appendingPathComponent("unwrapped_uvs.bin"))
            let cf: [Float] = c.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let uf: [Float] = u.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard cf.count % 9 == 0, uf.count * 3 == cf.count * 2 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            corners = stride(from: 0, to: cf.count, by: 3).map { SIMD3(cf[$0], cf[$0 + 1], cf[$0 + 2]) }
            uvs = stride(from: 0, to: uf.count, by: 2).map { SIMD2(uf[$0], uf[$0 + 1]) }
        }
    }

    public static func preparePython(folder: String, faces: Int) -> String {
        "import _blenderkit_image3d as _bk_image3d; print(_bk_image3d.prepare_full(\(Bpy.quote(folder)), \(faces)))"
    }

    public static func finishPython(folder: String, texture: String, name: String,
                                    location: SIMD3<Float>) -> String {
        "import _blenderkit_image3d as _bk_image3d; print(_bk_image3d.finish_full("
            + "\(Bpy.quote(folder)), \(Bpy.quote(texture)), \(Bpy.quote(name)), "
            + "(\(location.x), \(location.y), \(location.z))))"
    }

    // MARK: 5. The photo's viewpoint

    public struct Pose: Sendable, Equatable {
        /// Degrees about the shape's up axis (0 is the front, +Z) and above
        /// the horizon.
        public var azimuth: Float
        public var elevation: Float
        /// Picture pixels per unit and the shape's origin in the picture.
        public var scale: Float
        public var offset: SIMD2<Float>
        /// How well the silhouettes overlap, 0...1.
        public var overlap: Float

        /// Where a shape point lands in the 512² picture, and its depth
        /// (smaller is nearer). Orthographic.
        public func project(_ p: SIMD3<Float>) -> (x: Float, y: Float, depth: Float) {
            let a = azimuth * .pi / 180, e = elevation * .pi / 180
            // The camera sits in direction (sin a · cos e, sin e, cos a · cos e).
            let right = SIMD3<Float>(cos(a), 0, -sin(a))
            let toward = SIMD3<Float>(sin(a) * cos(e), sin(e), cos(a) * cos(e))
            let up = cross(toward, right)
            return (dot(p, right) * scale + offset.x, -dot(p, up) * scale + offset.y, -dot(p, toward))
        }

        public var viewDirection: SIMD3<Float> {
            let a = azimuth * .pi / 180, e = elevation * .pi / 180
            return SIMD3(sin(a) * cos(e), sin(e), cos(a) * cos(e))
        }
    }

    /// The azimuth and elevation whose silhouette best overlaps the cut-out,
    /// with scale and offset fitted from the bounds.
    public static func fitPose(vertices: [SIMD3<Float>], alpha: [Float], size: Int = Prepared.photoSize) -> Pose {
        let grid = 96
        let down = Float(size) / Float(grid)
        var target = [Bool](repeating: false, count: grid * grid)
        var tlo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), thi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for y in 0..<size { for x in 0..<size where alpha[y * size + x] > 0.5 {
            target[(y * grid / size) * grid + x * grid / size] = true
            tlo = simd_min(tlo, SIMD2(Float(x), Float(y))); thi = simd_max(thi, SIMD2(Float(x), Float(y)))
        } }
        guard thi.x > tlo.x else { return Pose(azimuth: 0, elevation: 0, scale: Float(size) / 2.4, offset: SIMD2(repeating: Float(size) / 2), overlap: 0) }
        // A sample of the vertices is enough for a silhouette.
        let stride = max(1, vertices.count / 20_000)
        let sample = Swift.stride(from: 0, to: vertices.count, by: stride).map { vertices[$0] }

        func evaluate(_ azimuth: Float, _ elevation: Float) -> Pose {
            var pose = Pose(azimuth: azimuth, elevation: elevation, scale: 1, offset: .zero, overlap: 0)
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for p in sample { let q = pose.project(p); lo = simd_min(lo, SIMD2(q.x, q.y)); hi = simd_max(hi, SIMD2(q.x, q.y)) }
            let s = ((thi.x - tlo.x) / max(hi.x - lo.x, 1e-6) + (thi.y - tlo.y) / max(hi.y - lo.y, 1e-6)) / 2
            pose.scale = s
            pose.offset = (thi + tlo) / 2 - s * (hi + lo) / 2
            var mine = [Bool](repeating: false, count: grid * grid)
            for p in sample {
                let q = pose.project(p)
                let gx = Int(q.x / down), gy = Int(q.y / down)
                for dy in -1...1 { for dx in -1...1 {
                    let x = gx + dx, y = gy + dy
                    if x >= 0, y >= 0, x < grid, y < grid { mine[y * grid + x] = true }
                } }
            }
            var both = 0, either = 0
            for i in 0..<(grid * grid) { if mine[i] && target[i] { both += 1 }; if mine[i] || target[i] { either += 1 } }
            pose.overlap = Float(both) / Float(max(either, 1))
            return pose
        }
        // A symmetric shape seen from azimuth a and from 180° - a has the same
        // silhouette, so front and back cannot be told apart by outline.
        // TripoSG turns the shape's front towards the picture, so the front
        // half wins unless the back half fits clearly better.
        var front = evaluate(0, 0), back = evaluate(180, 0)
        for elevation in Swift.stride(from: Float(-10), through: 40, by: 10) {
            for azimuth in Swift.stride(from: Float(-170), through: 180, by: 10) {
                let p = evaluate(azimuth, elevation)
                if abs(azimuth) <= 90 {
                    if p.overlap > front.overlap { front = p }
                } else if p.overlap > back.overlap { back = p }
            }
        }
        var best = back.overlap > front.overlap + 0.05 ? back : front
        for elevation in Swift.stride(from: best.elevation - 6, through: best.elevation + 6, by: 3) {
            for azimuth in Swift.stride(from: best.azimuth - 8, through: best.azimuth + 8, by: 2) {
                let p = evaluate(azimuth, elevation)
                if p.overlap > best.overlap { best = p }
            }
        }
        return best
    }

    /// How nearly the shape is its own mirror image across x = 0, 0...1: the
    /// overlap of the voxels its surface passes through with their mirrors.
    public static func mirrorSymmetry(vertices: [SIMD3<Float>]) -> Float {
        let cells = 48
        let bound = TripoSGModel.bound
        func index(_ p: SIMD3<Float>) -> Int {
            let v = (p + SIMD3(repeating: bound)) / (2 * bound) * Float(cells)
            let x = min(max(Int(v.x), 0), cells - 1), y = min(max(Int(v.y), 0), cells - 1)
            let z = min(max(Int(v.z), 0), cells - 1)
            return (x * cells + y) * cells + z
        }
        var occupied = [Bool](repeating: false, count: cells * cells * cells)
        var mirrored = [Bool](repeating: false, count: cells * cells * cells)
        for p in vertices {
            occupied[index(p)] = true
            mirrored[index(SIMD3(-p.x, p.y, p.z))] = true
        }
        // A voxel either way counts as matching, so a surface lying on a
        // voxel boundary is not taken for asymmetry.
        var both = 0, either = 0
        for x in 0..<cells { for y in 0..<cells { for z in 0..<cells {
            let i = (x * cells + y) * cells + z
            guard occupied[i] || mirrored[i] else { continue }
            either += 1
            var near = false
            for dx in -1...1 where !near {
                let nx = x + dx
                guard nx >= 0, nx < cells else { continue }
                let j = (nx * cells + y) * cells + z
                if occupied[i] ? mirrored[j] : occupied[j] { near = true }
            }
            if near { both += 1 }
        } } }
        return Float(both) / Float(max(either, 1))
    }

    // MARK: 6. The texture

    public struct Texture: Sendable {
        public let size: Int
        /// size² × 4 RGBA8, rows top to bottom (V = 1 is the top row).
        public var rgba: [UInt8]
        /// Of the texels on the model, the fraction taken from the photo.
        public var photoFraction: Float

        public func writePNG(to url: URL) throws {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Texel positions and normals, rasterised from the UV layout.
    struct SurfaceMap {
        var position: [SIMD3<Float>]
        var normal: [SIMD3<Float>]
        var covered: [Bool]
        /// The triangle each texel was taken from, and its weights for the
        /// triangle's corners.
        var triangle: [Int32]
        var weights: [SIMD3<Float>]
    }

    static func rasterise(_ unwrapped: Unwrapped, size t: Int) -> SurfaceMap {
        var map = SurfaceMap(position: .init(repeating: .zero, count: t * t),
                             normal: .init(repeating: .zero, count: t * t),
                             covered: .init(repeating: false, count: t * t),
                             triangle: .init(repeating: -1, count: t * t),
                             weights: .init(repeating: .zero, count: t * t))
        let tf = Float(t)
        for k in 0..<unwrapped.triangleCount {
            let p0 = unwrapped.corners[k * 3], p1 = unwrapped.corners[k * 3 + 1], p2 = unwrapped.corners[k * 3 + 2]
            let n = cross(p1 - p0, p2 - p0)
            let len = length(n)
            guard len > 1e-12 else { continue }
            let normal = n / len
            // Texel centres; V up, so row 0 is V = 1.
            let a = SIMD2(unwrapped.uvs[k * 3].x * tf - 0.5, (1 - unwrapped.uvs[k * 3].y) * tf - 0.5)
            let b = SIMD2(unwrapped.uvs[k * 3 + 1].x * tf - 0.5, (1 - unwrapped.uvs[k * 3 + 1].y) * tf - 0.5)
            let c = SIMD2(unwrapped.uvs[k * 3 + 2].x * tf - 0.5, (1 - unwrapped.uvs[k * 3 + 2].y) * tf - 0.5)
            let den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            guard abs(den) > 1e-12 else { continue }
            let x0 = max(Int((min(a.x, b.x, c.x)).rounded(.down)), 0), x1 = min(Int((max(a.x, b.x, c.x)).rounded(.up)), t - 1)
            let y0 = max(Int((min(a.y, b.y, c.y)).rounded(.down)), 0), y1 = min(Int((max(a.y, b.y, c.y)).rounded(.up)), t - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            // A little past the edges, so texels a seam crosses are filled.
            let slack: Float = -0.02
            for y in y0...y1 {
                for x in x0...x1 {
                    let px = Float(x), py = Float(y)
                    let w0 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / den
                    let w1 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / den
                    let w2 = 1 - w0 - w1
                    guard w0 >= slack, w1 >= slack, w2 >= slack else { continue }
                    let i = y * t + x
                    map.position[i] = p0 * w0 + p1 * w1 + p2 * w2
                    map.normal[i] = normal
                    map.covered[i] = true
                    map.triangle[i] = Int32(k)
                    map.weights[i] = SIMD3(w0, w1, w2)
                }
            }
        }
        return map
    }

    /// Distance to the nearest outside pixel, in pixels (chamfer 1, √2).
    static func chamfer(inside: [Bool], width w: Int, height h: Int) -> [Float] {
        let far = Float(w + h)
        var d = inside.map { $0 ? far : 0 }
        let diagonal = Float(2).squareRoot()
        for y in 0..<h {
            for x in 0..<w where inside[y * w + x] {
                var v = d[y * w + x]
                if x > 0 { v = min(v, d[y * w + x - 1] + 1) } else { v = min(v, 1) }
                if y > 0 { v = min(v, d[(y - 1) * w + x] + 1) } else { v = min(v, 1) }
                if x > 0, y > 0 { v = min(v, d[(y - 1) * w + x - 1] + diagonal) }
                if x < w - 1, y > 0 { v = min(v, d[(y - 1) * w + x + 1] + diagonal) }
                d[y * w + x] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where inside[y * w + x] {
                var v = d[y * w + x]
                if x < w - 1 { v = min(v, d[y * w + x + 1] + 1) } else { v = min(v, 1) }
                if y < h - 1 { v = min(v, d[(y + 1) * w + x] + 1) } else { v = min(v, 1) }
                if x < w - 1, y < h - 1 { v = min(v, d[(y + 1) * w + x + 1] + diagonal) }
                if x > 0, y < h - 1 { v = min(v, d[(y + 1) * w + x - 1] + diagonal) }
                d[y * w + x] = v
            }
        }
        return d
    }

    /// `mirror` also paints each point from its mirror image across x = 0,
    /// for shapes `mirrorSymmetry` finds symmetric.
    public static func bake(_ unwrapped: Unwrapped, prepared: Prepared, pose: Pose,
                            mirror: Bool, size t: Int = 1024) -> Texture {
        let map = rasterise(unwrapped, size: t)
        let n = Prepared.photoSize
        let indices = map.covered.indices.filter { map.covered[$0] }

        // The depth the camera sees, splatted from the triangles.
        var zbuffer = [Float](repeating: .greatestFiniteMagnitude, count: n * n)
        for k in 0..<unwrapped.triangleCount {
            let a = pose.project(unwrapped.corners[k * 3]), b = pose.project(unwrapped.corners[k * 3 + 1])
            let c = pose.project(unwrapped.corners[k * 3 + 2])
            let den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            guard abs(den) > 1e-9 else { continue }
            let x0 = max(Int(min(a.x, b.x, c.x).rounded(.down)), 0), x1 = min(Int(max(a.x, b.x, c.x).rounded(.up)), n - 1)
            let y0 = max(Int(min(a.y, b.y, c.y).rounded(.down)), 0), y1 = min(Int(max(a.y, b.y, c.y).rounded(.up)), n - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let w0 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / den
                let w1 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / den
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                let z = w0 * a.depth + w1 * b.depth + w2 * c.depth
                if z < zbuffer[y * n + x] { zbuffer[y * n + x] = z }
            } }
        }
        let inner = chamfer(inside: prepared.alpha.map { $0 > 0.5 }, width: n, height: n)
        let view = pose.viewDirection
        func sample(_ q: (x: Float, y: Float, depth: Float)) -> SIMD3<Float> {
            let fx = min(max(q.x - 0.5, 0), Float(n) - 1.001), fy = min(max(q.y - 0.5, 0), Float(n) - 1.001)
            let x0 = Int(fx), y0 = Int(fy), ax = fx - Float(x0), ay = fy - Float(y0)
            func px(_ x: Int, _ y: Int) -> SIMD3<Float> {
                let j = (y * n + x) * 3
                return SIMD3(prepared.photo[j], prepared.photo[j + 1], prepared.photo[j + 2])
            }
            return px(x0, y0) * ((1 - ax) * (1 - ay)) + px(x0 + 1, y0) * (ax * (1 - ay))
                + px(x0, y0 + 1) * ((1 - ax) * ay) + px(x0 + 1, y0 + 1) * (ax * ay)
        }
        // How much a point with a normal can take the photo: seen, facing the
        // camera, and well inside the cut-out.
        func weight(_ p: SIMD3<Float>, _ normal: SIMD3<Float>) -> (Float, (x: Float, y: Float, depth: Float)) {
            let q = pose.project(p)
            let ix = Int(q.x), iy = Int(q.y)
            guard q.x >= 0, q.y >= 0, ix < n, iy < n, q.depth <= zbuffer[iy * n + ix] + 0.015 else { return (0, q) }
            let facing = min(max((dot(normal, view) - 0.2) / 0.3, 0), 1)
            let edge = min(max((inner[iy * n + ix] - 1.5) / 4, 0), 1)
            return (facing * edge, q)
        }
        /// The photo's colour for a point, from the point and its mirror, and
        /// how much of it to take.
        func photo(_ p: SIMD3<Float>, _ normal: SIMD3<Float>) -> (SIMD3<Float>, Float, direct: Float) {
            let (direct, q) = weight(p, normal)
            let (reflected, mq) = mirror ? weight(SIMD3(-p.x, p.y, p.z), SIMD3(-normal.x, normal.y, normal.z)) : (0, q)
            let wd = direct, wm = reflected * (1 - direct)
            guard wd + wm > 1e-4 else { return (.zero, 0, 0) }
            return ((sample(q) * wd + sample(mq) * wm) / (wd + wm), wd + wm, direct)
        }

        // Where the photo cannot reach, colour spreads over the surface from
        // where it can: per vertex, from the painted vertices outwards in
        // breadth-first order, then smoothed.
        var vertexOf: [SIMD3<Float>: Int32] = [:]
        var positions: [SIMD3<Float>] = []
        var cornerVertex = [Int32](repeating: 0, count: unwrapped.corners.count)
        for (c, p) in unwrapped.corners.enumerated() {
            if let v = vertexOf[p] { cornerVertex[c] = v; continue }
            let v = Int32(positions.count)
            vertexOf[p] = v; positions.append(p); cornerVertex[c] = v
        }
        let vertexCount = positions.count
        var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var neighbours = [[Int32]](repeating: [], count: vertexCount)
        for k in 0..<unwrapped.triangleCount {
            let a = Int(cornerVertex[k * 3]), b = Int(cornerVertex[k * 3 + 1]), c = Int(cornerVertex[k * 3 + 2])
            // Area-weighted.
            let face = cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += face; normals[b] += face; normals[c] += face
            for (u, v) in [(a, b), (b, c), (c, a)] {
                if !neighbours[u].contains(Int32(v)) { neighbours[u].append(Int32(v)) }
                if !neighbours[v].contains(Int32(u)) { neighbours[v].append(Int32(u)) }
            }
        }
        var colour = [SIMD3<Float>](repeating: SIMD3(repeating: 0.5), count: vertexCount)
        var known = [Bool](repeating: false, count: vertexCount)
        var queue: [Int] = []
        for v in 0..<vertexCount {
            let length = simd_length(normals[v])
            guard length > 0 else { continue }
            let (c, w, _) = photo(positions[v], normals[v] / length)
            if w > 0.3 { colour[v] = c; known[v] = true; queue.append(v) }
        }
        let seeded = known
        // Parts the photo reaches nowhere on — a loose piece, or the whole
        // model if nothing was seen — take the cut-out's average colour.
        var total = SIMD3<Float>.zero, count: Float = 0
        for p in 0..<(n * n) where prepared.alpha[p] > 0.5 {
            total += SIMD3(prepared.photo[p * 3], prepared.photo[p * 3 + 1], prepared.photo[p * 3 + 2]); count += 1
        }
        let average = count > 0 ? total / count : SIMD3<Float>(repeating: 0.6)
        var head = 0
        while head < queue.count {
            let v = queue[head]; head += 1
            for u in neighbours[v] where !known[Int(u)] {
                var total = SIMD3<Float>.zero, count: Float = 0
                for w in neighbours[Int(u)] where known[Int(w)] { total += colour[Int(w)]; count += 1 }
                colour[Int(u)] = total / count
                known[Int(u)] = true
                queue.append(Int(u))
            }
        }
        for v in 0..<vertexCount where !known[v] { colour[v] = average }
        for _ in 0..<24 {
            var next = colour
            for v in 0..<vertexCount where !seeded[v] && !neighbours[v].isEmpty {
                var total = colour[v]
                for u in neighbours[v] { total += colour[Int(u)] }
                next[v] = total / Float(neighbours[v].count + 1)
            }
            colour = next
        }

        // Each texel: the photo where it reaches, blended into the spread
        // colour at its edges.
        var texel = [SIMD3<Float>](repeating: SIMD3(repeating: 0.5), count: t * t)
        var fromPhoto = 0
        for i in indices {
            let k = Int(map.triangle[i]), b = map.weights[i]
            let spread = colour[Int(cornerVertex[k * 3])] * b.x + colour[Int(cornerVertex[k * 3 + 1])] * b.y
                + colour[Int(cornerVertex[k * 3 + 2])] * b.z
            let (c, w, direct) = photo(map.position[i], map.normal[i])
            let amount = min(w * 2, 1)
            texel[i] = spread * (1 - amount) + c * amount
            if direct > 0.5 { fromPhoto += 1 }
        }

        // Bleed into the gaps between UV islands, so mipmaps and filtering
        // at island edges pick up the model's colours, not black.
        var filled = map.covered
        var frontier = indices
        var pass = 0
        while !frontier.isEmpty, pass < 16 {
            var next: [Int] = []
            var updates: [(Int, SIMD3<Float>)] = []
            var seen = Set<Int>()
            for i in frontier {
                let x = i % t, y = i / t
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < t, ny < t else { continue }
                    let j = ny * t + nx
                    if filled[j] || seen.contains(j) { continue }
                    seen.insert(j); updates.append((j, texel[i])); next.append(j)
                }
            }
            for (j, c) in updates { texel[j] = c; filled[j] = true }
            frontier = next
            pass += 1
        }
        var rgba = [UInt8](repeating: 255, count: t * t * 4)
        for i in 0..<(t * t) {
            let c = simd_clamp(texel[i], SIMD3(repeating: 0), SIMD3(repeating: 1))
            rgba[i * 4] = UInt8((c.x * 255).rounded()); rgba[i * 4 + 1] = UInt8((c.y * 255).rounded())
            rgba[i * 4 + 2] = UInt8((c.z * 255).rounded())
        }
        return Texture(size: t, rgba: rgba,
                                       photoFraction: indices.isEmpty ? 0 : Float(fromPhoto) / Float(indices.count))
    }
}
