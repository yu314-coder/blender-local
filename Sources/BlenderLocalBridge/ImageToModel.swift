import Foundation
import simd

/// Image to 3D Model's relief: the subject's outline, given the depth of the
/// picture itself.
///
/// The depth comes from Depth Anything V2 on the device (DepthRelief in the
/// interface), a map of how near each pixel is. The front surface follows it,
/// so a beak stands out and eye sockets sink; the photo is its texture,
/// through UVs that are the picture's own coordinates, at full sharpness. The
/// last few cells before the outline round off to it, and the back is a
/// shallow rounded plate, so the model is closed. It is a relief: seen from
/// the side, what the camera never saw is guessed flat. The full 3D mode
/// (TripoSR) is the one that models the back.
///
/// Without a depth map — the host tests, or a device where the depth model
/// cannot load — the outline is inflated instead.
///
/// Pure arithmetic, so the host suite checks it; Vision, the picker and the
/// PNG live in BlenderLocalUI, and `_blenderkit_image3d.py` turns the arrays
/// into Blender's mesh, UVs and material.
public enum ImageToModel {

    /// Coverage per pixel, rows top to bottom: 0 is background, 255 subject.
    public struct Mask: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public var values: [UInt8]

        public init(width: Int, height: Int, values: [UInt8]) {
            precondition(values.count == width * height, "mask size")
            self.width = width; self.height = height; self.values = values
        }

        /// Everything: the whole picture as the subject.
        public static func whole(width: Int, height: Int) -> Mask {
            Mask(width: width, height: height,
                 values: [UInt8](repeating: 255, count: width * height))
        }

        /// What fraction of the picture is subject, 0...1.
        public var coverage: Double {
            guard !values.isEmpty else { return 0 }
            return Double(values.lazy.filter { $0 >= 128 }.count) / Double(values.count)
        }
    }

    /// How near each pixel is, 0 (far) to 1 (near), in the mask's pixel grid.
    public struct Depth: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public var values: [Float]

        public init(width: Int, height: Int, values: [Float]) {
            precondition(values.count == width * height, "depth size")
            self.width = width; self.height = height; self.values = values
        }
    }

    public struct Options: Sendable, Equatable {
        /// Lattice cells across the subject's longer side.
        public var detail: Int
        /// Front-to-back depth at the thickest point, as a fraction of the
        /// subject's shorter side.
        public var thickness: Float
        /// The subject's longer side, in metres: a default cube's size.
        public var size: Float

        public init(detail: Int = 96, thickness: Float = 0.5, size: Float = 2) {
            self.detail = detail; self.thickness = thickness; self.size = size
        }

        public static let detailRange = 16...256
        public static let thicknessRange: ClosedRange<Float> = 0...2
    }

    /// Blender's layout: one position per vertex, faces as sizes plus corner
    /// indices, and one UV per face corner.
    public struct Mesh: Sendable, Equatable {
        public var positions: [SIMD3<Float>] = []
        public var faceSizes: [Int32] = []
        public var faceIndices: [Int32] = []
        public var uvs: [SIMD2<Float>] = []
        /// How many of the faces, from the start, are the front.
        public var frontFaces = 0

        public var faceCount: Int { faceSizes.count }
    }

    /// The model, or nil when the mask has no subject in it.
    public static func build(mask: Mask, depth: Depth? = nil, options: Options = Options()) -> Mesh? {
        // The subject's bounds, in pixels.
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<mask.height {
            let row = y * mask.width
            for x in 0..<mask.width where mask.values[row + x] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // Pixel centres, so a one-pixel subject still has an extent.
        let boundsWidth = Float(maxX - minX + 1)
        let boundsHeight = Float(maxY - minY + 1)
        let longer = max(boundsWidth, boundsHeight)
        let shorter = min(boundsWidth, boundsHeight)

        let detail = min(max(options.detail, Options.detailRange.lowerBound),
                         Options.detailRange.upperBound)
        let step = longer / Float(detail)
        // One cell of background all round, so the outline is always inside
        // the lattice and every edge of the subject meets an outside vertex.
        let originX = Float(minX) - step
        let originY = Float(minY) - step
        let columns = Int((boundsWidth / step).rounded(.up)) + 3
        let rows = Int((boundsHeight / step).rounded(.up)) + 3

        var inside = [Bool](repeating: false, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let px = originX + Float(i) * step
                let py = originY + Float(j) * step
                inside[j * columns + i] = sample(mask, px, py) >= 128
            }
        }
        guard inside.contains(true) else { return nil }

        // Distance to the background, in cells: two chamfer passes.
        let far = Float.greatestFiniteMagnitude / 4
        var distance = inside.map { $0 ? far : 0 }
        let diagonal = Float(2).squareRoot()
        func relax(_ i: Int, _ j: Int, _ di: Int, _ dj: Int, _ cost: Float) {
            let ni = i + di, nj = j + dj
            guard ni >= 0, nj >= 0, ni < columns, nj < rows else { return }
            let candidate = distance[nj * columns + ni] + cost
            if candidate < distance[j * columns + i] { distance[j * columns + i] = candidate }
        }
        for j in 0..<rows {
            for i in 0..<columns where inside[j * columns + i] {
                relax(i, j, -1, 0, 1); relax(i, j, 0, -1, 1)
                relax(i, j, -1, -1, diagonal); relax(i, j, 1, -1, diagonal)
            }
        }
        for j in stride(from: rows - 1, through: 0, by: -1) {
            for i in stride(from: columns - 1, through: 0, by: -1) where inside[j * columns + i] {
                relax(i, j, 1, 0, 1); relax(i, j, 0, 1, 1)
                relax(i, j, 1, 1, diagonal); relax(i, j, -1, 1, diagonal)
            }
        }
        let deepest = distance.max() ?? 1

        // Metres per pixel, and the picture's centre of the subject.
        let scale = options.size / longer
        let centreX = Float(minX) + boundsWidth / 2
        let centreY = Float(minY) + boundsHeight / 2
        let thickness = min(max(options.thickness, Options.thicknessRange.lowerBound),
                            Options.thicknessRange.upperBound)
        let halfDepth = thickness * shorter * scale / 2

        // Depth, where there is some: sampled at each lattice point inside,
        // and stretched so the subject's own 2nd to 98th percentile spans 0...1.
        var nearness: [Float]? = nil
        if let depth {
            var values = [Float](repeating: 0, count: columns * rows)
            var inner: [Float] = []
            for index in 0..<(columns * rows) where inside[index] {
                let i = index % columns, j = index / columns
                let v = sampleDepth(depth, mask: mask, originX + Float(i) * step, originY + Float(j) * step)
                values[index] = v
                inner.append(v)
            }
            inner.sort()
            if !inner.isEmpty {
                let lo = inner[Int(Float(inner.count - 1) * 0.02)], hi = inner[Int(Float(inner.count - 1) * 0.98)]
                let span = max(hi - lo, 1e-4)
                nearness = values.map { min(max(($0 - lo) / span, 0), 1) }
            }
        }

        // A vertex one cell from the background is on the outline: height 0,
        // and one vertex for both sides. With depth, only the last few cells
        // round off to it; without, the whole distance does (the inflation).
        let edgeCells = max(Float(2), Float(detail) * 0.04)
        func rounding(_ index: Int, over cells: Float) -> Float {
            let t = min(max((distance[index] - 1) / max(cells, 1e-3), 0), 1)
            return (t * (2 - t)).squareRoot()
        }
        func frontHeight(_ index: Int) -> Float {
            guard deepest > 1 else { return 0 }
            if let nearness {
                // Most of the height is the depth's variation; a tenth is a
                // base, so the farthest parts still stand off the back.
                return halfDepth * (0.1 + 0.9 * nearness[index]) * rounding(index, over: edgeCells)
            }
            return halfDepth * rounding(index, over: deepest - 1)
        }
        func backHeight(_ index: Int) -> Float {
            guard deepest > 1 else { return 0 }
            if nearness != nil { return halfDepth * 0.15 * rounding(index, over: edgeCells) }
            return halfDepth * rounding(index, over: deepest - 1)
        }

        var mesh = Mesh()
        var frontID = [Int32](repeating: -1, count: columns * rows)
        var backID = [Int32](repeating: -1, count: columns * rows)
        func vertex(_ index: Int, front: Bool) -> Int32 {
            let h = front ? frontHeight(index) : backHeight(index)
            let shared = frontHeight(index) == 0
            if front || shared {
                if frontID[index] >= 0 { return frontID[index] }
            } else if backID[index] >= 0 {
                return backID[index]
            }
            let i = index % columns, j = index / columns
            let px = originX + Float(i) * step
            let py = originY + Float(j) * step
            // Blender's front view looks along +Y, so the front faces -Y.
            let y = front ? -h : h
            mesh.positions.append(SIMD3((px - centreX) * scale, y, (centreY - py) * scale))
            let id = Int32(mesh.positions.count - 1)
            if front || shared { frontID[index] = id }
            if !front || shared { backID[index] = id }
            return id
        }
        func uv(_ index: Int) -> SIMD2<Float> {
            let i = index % columns, j = index / columns
            let px = originX + Float(i) * step
            let py = originY + Float(j) * step
            return SIMD2(px / Float(mask.width), 1 - py / Float(mask.height))
        }

        // Corners in picture order: top-left, top-right, bottom-right,
        // bottom-left. That order runs clockwise seen from the front, so the
        // front's faces take it reversed and the back's as it is.
        var cells: [[Int]] = []
        for j in 0..<(rows - 1) {
            for i in 0..<(columns - 1) {
                let corners = [j * columns + i, j * columns + i + 1,
                               (j + 1) * columns + i + 1, (j + 1) * columns + i]
                let kept = corners.filter { inside[$0] }
                if kept.count >= 3 { cells.append(kept) }
            }
        }
        for corners in cells {
            let ring = Array(corners.reversed())
            mesh.faceSizes.append(Int32(ring.count))
            for index in ring {
                mesh.faceIndices.append(vertex(index, front: true))
                mesh.uvs.append(uv(index))
            }
        }
        mesh.frontFaces = mesh.faceCount
        for corners in cells {
            // Where every corner is on the outline the back would lie exactly
            // on the front.
            if corners.allSatisfy({ frontHeight($0) == 0 }) { continue }
            mesh.faceSizes.append(Int32(corners.count))
            for index in corners {
                mesh.faceIndices.append(vertex(index, front: false))
                mesh.uvs.append(uv(index))
            }
        }
        return mesh
    }

    /// Bilinear depth at a mask pixel position, the depth map being the mask's
    /// picture at its own resolution.
    private static func sampleDepth(_ depth: Depth, mask: Mask, _ x: Float, _ y: Float) -> Float {
        let fx = x * Float(depth.width) / Float(mask.width) - 0.5
        let fy = y * Float(depth.height) / Float(mask.height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ px: Int, _ py: Int) -> Float {
            depth.values[min(max(py, 0), depth.height - 1) * depth.width + min(max(px, 0), depth.width - 1)]
        }
        let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Bilinear coverage at a pixel position. Background beyond the picture's
    /// edge; up to the edge itself, the edge pixels — otherwise a subject that
    /// fills the picture, or runs off it, loses a cell all round.
    private static func sample(_ mask: Mask, _ x: Float, _ y: Float) -> Float {
        guard x >= 0, y >= 0, x <= Float(mask.width), y <= Float(mask.height) else { return 0 }
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ px: Int, _ py: Int) -> Float {
            let cx = min(max(px, 0), mask.width - 1), cy = min(max(py, 0), mask.height - 1)
            return Float(mask.values[cy * mask.width + cx])
        }
        let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }
}

// MARK: - Handing it to Blender

public extension ImageToModel.Mesh {
    /// The files `_blenderkit_image3d.build` reads, little-endian: positions
    /// and UVs as float32, face sizes and corner indices as int32, and a
    /// meta.json with the counts to check them against.
    func write(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func data<T>(_ array: [T]) -> Data { array.withUnsafeBufferPointer { Data(buffer: $0) } }
        try data(positions.flatMap { [$0.x, $0.y, $0.z] })
            .write(to: folder.appendingPathComponent("positions.bin"))
        try data(uvs.flatMap { [$0.x, $0.y] }).write(to: folder.appendingPathComponent("uvs.bin"))
        try data(faceSizes).write(to: folder.appendingPathComponent("sizes.bin"))
        try data(faceIndices).write(to: folder.appendingPathComponent("indices.bin"))
        let meta: [String: Int] = ["vertices": positions.count, "faces": faceCount,
                                   "loops": faceIndices.count, "front_faces": frontFaces]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("meta.json"))
    }
}

public extension ImageToModel {
    /// The Python that builds the model from a folder `Mesh.write` filled and
    /// the texture beside it, printing a JSON line with the object's name.
    static func python(folder: String, texture: String, name: String,
                       location: SIMD3<Float>) -> String {
        "import _blenderkit_image3d as _bk_image3d; print(_bk_image3d.build("
            + "\(Bpy.quote(folder)), \(Bpy.quote(texture)), \(Bpy.quote(name)), "
            + "(\(location.x), \(location.y), \(location.z))))"
    }

    /// A Blender name from a file name: its stem, or "Picture".
    static func objectName(forFile file: String?) -> String {
        // ".png" is all extension: NSString keeps it as the stem.
        let stem = file.map { name -> String in
            let s = (name as NSString).deletingPathExtension
            return s.hasPrefix(".") && !s.dropFirst().contains(".") ? "" : s
        } ?? ""
        let cleaned = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Picture" }
        // Blender caps names at 63 bytes.
        var name = ""
        for character in cleaned {
            if (name + String(character)).utf8.count > 63 { break }
            name.append(character)
        }
        return name
    }
}
