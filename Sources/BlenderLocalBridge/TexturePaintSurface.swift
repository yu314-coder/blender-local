import Foundation
import simd

// How an object's triangles reach the images Blender paints, and how those
// images travel between Blender's float arrays and the viewport's bytes.

// MARK: - The surface

/// The UV map and images one object is texture-painted through.
///
/// Blender stores UVs per face corner, so a seam is two UVs on one vertex. The
/// viewport's mesh has one vertex per Blender vertex — edit mode names
/// vertices to Blender by that index — so the UVs travel beside the mesh
/// instead of on it: one per triangle corner, in `MeshData.indices` order, and
/// only the texture-paint drawing expands them.
public struct PaintSurface: Sendable {
    /// One UV per entry of the mesh's `indices`.
    public var cornerUVs: [SIMD2<Float>]
    /// The material slot each triangle belongs to; empty when all use slot 0.
    public var triangleSlots: [UInt16]
    /// Per material slot, the name of the image Blender would paint for it —
    /// its paint canvas — or "" when the slot has none.
    public var slotImages: [String]
    /// Per slot, whether that image feeds the Principled BSDF's Base Color,
    /// which is when Material Preview shows it.
    public var baseColorLinked: [Bool]
    /// The active material slot, whose image the Image Editor shows.
    public var activeSlot: Int
    /// Mirrored from Blender, as opposed to made here for the simulator.
    public var fromBlender: Bool
    /// Changes whenever a surface is installed, for GPU buffers to follow.
    public let version: Int

    nonisolated(unsafe) private static var installed = 0

    public init(cornerUVs: [SIMD2<Float>], triangleSlots: [UInt16] = [],
                slotImages: [String], baseColorLinked: [Bool] = [],
                activeSlot: Int = 0, fromBlender: Bool) {
        self.cornerUVs = cornerUVs
        self.triangleSlots = triangleSlots
        self.slotImages = slotImages
        self.baseColorLinked = baseColorLinked
        self.activeSlot = activeSlot
        self.fromBlender = fromBlender
        Self.installed &+= 1
        version = Self.installed
    }

    /// Whether this surface still describes `mesh`: a corner UV per index and
    /// a slot per triangle. A mesh edited since it was mirrored does not.
    public func fits(_ mesh: MeshData) -> Bool {
        let triangles = mesh.indices.count / 3
        return triangles > 0 && cornerUVs.count == triangles * 3
            && (triangleSlots.isEmpty || triangleSlots.count == triangles)
    }

    public func slot(ofTriangle t: Int) -> Int {
        t < triangleSlots.count ? Int(triangleSlots[t]) : 0
    }

    /// The image of the active slot, or of the first slot that has one.
    public var activeImageName: String? {
        if activeSlot < slotImages.count, !slotImages[activeSlot].isEmpty {
            return slotImages[activeSlot]
        }
        return slotImages.first { !$0.isEmpty }
    }

    public func isBaseColor(slot: Int) -> Bool {
        slot < baseColorLinked.count && baseColorLinked[slot]
    }
}

/// The images Texture Paint has on screen, by Blender's image name.
///
/// One instance per image, however many objects use it: two objects sharing a
/// material paint and show the same pixels, as they do in Blender.
public enum TexturePaintImages {
    nonisolated(unsafe) public private(set) static var byName: [String: TextureImage] = [:]

    public static func image(named name: String) -> TextureImage? {
        name.isEmpty ? nil : byName[name]
    }

    public static func register(_ image: TextureImage, as name: String) {
        byName[name] = image
    }

    /// Forgets every image not in `names`.
    public static func keepOnly(_ names: Set<String>) {
        byName = byName.filter { names.contains($0.key) }
    }

    /// One image's pixels, arrived from Blender. An image already on screen at
    /// that size is updated in place, so everything holding it keeps holding
    /// the current pixels.
    public static func receive(name: String, width: Int, height: Int, channels: Int,
                               isFloat: Bool, floats: UnsafeBufferPointer<Float>) {
        // A float image keeps its values to paint in; its bytes are made from
        // them for display. A byte image is its bytes.
        let values = isFloat ? TexturePaintPixels.paintLayout(floats, width: width, height: height,
                                                              channels: channels) : nil
        let bytes = isFloat ? [UInt8](repeating: 0, count: width * height * 4)
            : TexturePaintPixels.bytes(from: floats, width: width, height: height, channels: channels)
        let image: TextureImage
        if let existing = byName[name], existing.width == width, existing.height == height {
            existing.replace(with: bytes)
            image = existing
        } else {
            image = TextureImage(width: width, height: height, name: name, pixels: bytes)
            byName[name] = image
        }
        image.channels = channels
        image.isFloat = isFloat
        image.floats = values
        if isFloat {
            TexturePaintPixels.refreshDisplay(image, x0: 0, y0: 0, x1: width - 1, y1: height - 1)
            image.noteChanged(x0: 0, y0: 0, x1: width - 1, y1: height - 1)
        }
    }

    /// Installs the surfaces one mirroring pass reported, and takes surfaces
    /// away from objects Blender no longer paints. Surfaces made for the
    /// simulator are left alone; nothing reports those.
    public static func install(_ reported: [String: PaintSurface], into scene: BKScene) {
        for obj in scene.objects {
            if let surface = reported[obj.name] {
                if let old = obj.paintSurface, old.hasSameLayout(as: surface) {
                    // Unchanged: keep the old one, and its GPU buffers with it.
                } else {
                    obj.paintSurface = surface
                }
            } else if obj.paintSurface?.fromBlender == true {
                obj.paintSurface = nil
            } else {
                continue
            }
            let shown = obj.paintSurface?.activeImageName.flatMap { image(named: $0) }
            if obj.texture !== shown {
                obj.texture = shown
                obj.textureVersion &+= 1
            }
        }
        var used = Set<String>()
        for obj in scene.objects {
            for name in obj.paintSurface?.slotImages ?? [] where !name.isEmpty { used.insert(name) }
        }
        keepOnly(used)
    }

    /// The simulator's stand-in for entering Texture Paint, which on device is
    /// Blender's Add Simple UVs and Add Paint Slot. Returns what it made,
    /// under those operators' names.
    public static func prepareShim(_ obj: BKObject, in scene: BKScene,
                                   width: Int, height: Int) -> [String] {
        var made: [String] = []
        let existing = obj.paintSurface
        var imageName = existing?.activeImageName ?? ""
        if imageName.isEmpty || byName[imageName] == nil {
            // "<material> Base Color", made unique the way Blender suffixes a
            // datablock name, filled with the material's base colour.
            let taken = Set(scene.objects.filter { $0 !== obj }
                .flatMap { $0.paintSurface?.slotImages ?? [] })
            let base = "\(obj.material.name) Base Color"
            var candidate = base
            var n = 1
            while taken.contains(candidate) {
                candidate = String(format: "%@.%03d", base, n)
                n += 1
            }
            imageName = candidate
            let c = obj.material.baseColor
            byName[imageName] = TextureImage(width: max(1, width), height: max(1, height),
                                             name: imageName, fill: SIMD4(c.x, c.y, c.z, 1))
            made.append("Add Paint Slot")
        }
        var uvs = existing?.cornerUVs ?? []
        if existing.map({ !$0.fits(obj.mesh) }) ?? true {
            uvs = TexturePaintUV.simpleCornerUVs(obj.mesh)
            made.insert("Add Simple UVs", at: 0)
        }
        obj.paintSurface = PaintSurface(cornerUVs: uvs, slotImages: [imageName],
                                        baseColorLinked: [true], activeSlot: 0, fromBlender: false)
        obj.texture = byName[imageName]
        obj.textureVersion &+= 1
        return made
    }
}

public extension PaintSurface {
    /// A surface from what `_blenderkit_texpaint.report` sends: the loop
    /// behind each triangle corner, the UV of each loop, each triangle's
    /// material index, the slots' image names joined by newlines, and a byte
    /// per slot for whether its image feeds Base Color. Nil when a corner
    /// names a loop that has no UV.
    static func reported(triangleLoops: UnsafeBufferPointer<UInt32>, loopUVs: UnsafeBufferPointer<Float>,
                         triangleSlots: UnsafeBufferPointer<Int32>, slotImages: String,
                         baseColor: UnsafeBufferPointer<UInt8>, activeSlot: Int) -> PaintSurface? {
        let loops = loopUVs.count / 2
        var corners: [SIMD2<Float>] = []
        if loops > 0 {
            corners.reserveCapacity(triangleLoops.count)
            for loop in triangleLoops {
                guard Int(loop) < loops else { return nil }
                corners.append(SIMD2(loopUVs[2 * Int(loop)], loopUVs[2 * Int(loop) + 1]))
            }
        }
        var slots = triangleSlots.map { UInt16(clamping: max(0, $0)) }
        if slots.allSatisfy({ $0 == 0 }) { slots = [] }
        return PaintSurface(cornerUVs: corners, triangleSlots: slots,
                            slotImages: slotImages.components(separatedBy: "\n"),
                            baseColorLinked: baseColor.map { $0 != 0 },
                            activeSlot: activeSlot, fromBlender: true)
    }

    /// Whether two surfaces describe the same UVs, slots and images.
    func hasSameLayout(as other: PaintSurface) -> Bool {
        fromBlender == other.fromBlender && activeSlot == other.activeSlot
            && slotImages == other.slotImages && baseColorLinked == other.baseColorLinked
            && triangleSlots == other.triangleSlots && cornerUVs == other.cornerUVs
    }
}

public extension BKObject {
    /// What a stroke can paint and the viewport can draw — the surface and one
    /// image per material slot — or nil when there is nothing usable.
    var paintTarget: (surface: PaintSurface, images: [TextureImage?])? {
        guard let surface = paintSurface, surface.fits(mesh) else { return nil }
        let images = surface.slotImages.map { TexturePaintImages.image(named: $0) }
        guard images.contains(where: { $0 != nil }) else { return nil }
        return (surface, images)
    }
}

// MARK: - A UV map for the simulator's shim

public enum TexturePaintUV {

    /// One UV per triangle corner, laid out the way Blender's Add Simple UVs
    /// lays a map out: a cube projection, whose six islands are packed into
    /// the unit square without overlapping.
    ///
    /// Only the simulator uses this. On device Blender runs its own operator;
    /// the shim has no UV packer, and a projection whose islands overlapped
    /// would paint one face's stroke onto its opposite.
    public static func simpleCornerUVs(_ mesh: MeshData, margin: Float = 0.005) -> [SIMD2<Float>] {
        let triangles = mesh.indices.count / 3
        guard triangles > 0 else { return [] }
        var projected = [SIMD2<Float>](repeating: .zero, count: triangles * 3)
        var island = [Int](repeating: 0, count: triangles)
        var lo = [SIMD2<Float>](repeating: SIMD2(repeating: .greatestFiniteMagnitude), count: 6)
        var hi = [SIMD2<Float>](repeating: SIMD2(repeating: -.greatestFiniteMagnitude), count: 6)

        for t in 0..<triangles {
            let p = (0..<3).map { mesh.vertices[Int(mesh.indices[3 * t + $0])].position }
            let n = cross(p[1] - p[0], p[2] - p[0])
            let a = abs(n)
            let axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
            let positive = n[axis] >= 0
            let id = axis * 2 + (positive ? 0 : 1)
            island[t] = id
            for k in 0..<3 {
                let q = p[k]
                // Seen from outside along the axis: right, then up.
                let uv: SIMD2<Float>
                switch axis {
                case 0:  uv = SIMD2(positive ? q.y : -q.y, q.z)
                case 1:  uv = SIMD2(positive ? -q.x : q.x, q.z)
                default: uv = SIMD2(q.x, positive ? q.y : -q.y)
                }
                projected[3 * t + k] = uv
                lo[id] = simd.min(lo[id], uv)
                hi[id] = simd.max(hi[id], uv)
            }
        }

        // One scale for every island, so texel density stays even, sized for
        // the largest to fit a cell of a three-by-two grid.
        let cell = SIMD2<Float>(1.0 / 3.0, 0.5)
        var widest: Float = 0, tallest: Float = 0
        for id in 0..<6 where hi[id].x >= lo[id].x {
            widest = max(widest, hi[id].x - lo[id].x)
            tallest = max(tallest, hi[id].y - lo[id].y)
        }
        let scale = min((cell.x - 2 * margin) / max(widest, 1e-6),
                        (cell.y - 2 * margin) / max(tallest, 1e-6))
        var uvs = projected
        for t in 0..<triangles {
            let id = island[t]
            let origin = SIMD2(Float(id % 3) * cell.x, Float(id / 3) * cell.y)
            for k in 0..<3 {
                uvs[3 * t + k] = origin + margin + (projected[3 * t + k] - lo[id]) * scale
            }
        }
        return uvs
    }
}

// MARK: - Seams

/// Which triangle edges are UV seams, for seam bleed.
///
/// Blender's `check_seam`: an edge is a seam unless the first other triangle
/// sharing both its vertices paints the same image with the same UVs at those
/// vertices (within 0.00075) and the same UV winding. Bit `k` of a triangle's
/// flags is the edge from corner `k` to corner `k + 1`.
public final class TexturePaintSeams {
    public let flags: [UInt8]

    public init(indices: [UInt32], cornerUVs: [SIMD2<Float>], triangleSlots: [UInt16],
                slotImages: [String] = []) {
        let triangles = indices.count / 3
        guard triangles > 0, cornerUVs.count == triangles * 3 else { flags = []; return }
        func image(_ t: Int) -> String {
            let slot = t < triangleSlots.count ? Int(triangleSlots[t]) : 0
            return slot < slotImages.count ? slotImages[slot] : String(slot)
        }

        // Triangles around each vertex, compressed row storage.
        let vertexCount = Int(indices.max() ?? 0) + 1
        var start = [Int](repeating: 0, count: vertexCount + 1)
        for v in indices { start[Int(v) + 1] += 1 }
        for i in 0..<vertexCount { start[i + 1] += start[i] }
        var fill = start
        var around = [Int32](repeating: 0, count: indices.count)
        for (corner, v) in indices.enumerated() {
            around[fill[Int(v)]] = Int32(corner / 3)
            fill[Int(v)] += 1
        }

        var clockwise = [Bool](repeating: false, count: triangles)
        for t in 0..<triangles {
            let a = cornerUVs[3 * t], b = cornerUVs[3 * t + 1], c = cornerUVs[3 * t + 2]
            clockwise[t] = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) < 0
        }
        func same(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Bool {
            abs(p.x - q.x) < 0.00075 && abs(p.y - q.y) < 0.00075
        }

        var out = [UInt8](repeating: 0, count: triangles)
        for t in 0..<triangles {
            for k in 0..<3 {
                let va = indices[3 * t + k], vb = indices[3 * t + (k + 1) % 3]
                var seam = true
                for slot in start[Int(va)]..<start[Int(va) + 1] {
                    let g = Int(around[slot])
                    guard g != t else { continue }
                    guard let gb = (0..<3).first(where: { indices[3 * g + $0] == vb }),
                          let ga = (0..<3).first(where: { indices[3 * g + $0] == va })
                    else { continue }
                    if image(g) == image(t),
                       same(cornerUVs[3 * t + k], cornerUVs[3 * g + ga]),
                       same(cornerUVs[3 * t + (k + 1) % 3], cornerUVs[3 * g + gb]) {
                        seam = clockwise[g] != clockwise[t]
                    }
                    break
                }
                if seam { out[t] |= 1 << UInt8(k) }
            }
        }
        flags = out
    }
}

// MARK: - Pixels between Blender and the viewport

/// The conversions for byte images of any channel count, a value at a time.
/// `TexturePaintPixels` takes four-channel byte images — every image Add Paint
/// Slot makes — through Accelerate, and hands the rest to these. Float images
/// are never converted; see `TexturePaintPixels.paintLayout`.
///
/// `Image.pixels` is floats, bottom row first, `channels` per pixel — bytes
/// over 255 for a byte image. The viewport's `TextureImage` is RGBA bytes, top
/// row first, as a display wants.
enum TexturePaintPixelsScalar {

    /// The viewport's bytes from a byte image's floats: its bytes over 255,
    /// recovered exactly.
    public static func bytes(from floats: UnsafeBufferPointer<Float>, width: Int, height: Int,
                             channels: Int) -> [UInt8] {
        let c = max(1, channels)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        guard floats.count >= width * height * c else { return out }
        func colour(_ v: Float) -> UInt8 { BlenderColor.byte(v) }
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let row = (height - 1 - y) * width
                for x in 0..<width {
                    let s = (y * width + x) * c
                    let d = (row + x) * 4
                    if c >= 3 {
                        dst[d] = colour(floats[s])
                        dst[d + 1] = colour(floats[s + 1])
                        dst[d + 2] = colour(floats[s + 2])
                        dst[d + 3] = c >= 4 ? BlenderColor.byte(floats[s + 3]) : 255
                    } else {
                        let v = colour(floats[s])
                        dst[d] = v; dst[d + 1] = v; dst[d + 2] = v
                        dst[d + 3] = c == 2 ? BlenderColor.byte(floats[s + 1]) : 255
                    }
                }
            }
        }
        return out
    }

    /// Blender's floats from a byte image's bytes — what `pixels.foreach_set`
    /// is handed when a stroke is kept.
    public static func floats(from image: TextureImage) -> [Float] {
        let width = image.width, height = image.height, c = max(1, image.channels)
        var out = [Float](repeating: 0, count: width * height * c)
        func value(_ b: UInt8) -> Float { Float(b) / 255 }
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = (height - 1 - y) * width
                    for x in 0..<width {
                        let d = (y * width + x) * c
                        let s = (row + x) * 4
                        if c >= 3 {
                            dst[d] = value(src[s])
                            dst[d + 1] = value(src[s + 1])
                            dst[d + 2] = value(src[s + 2])
                            if c >= 4 { dst[d + 3] = Float(src[s + 3]) / 255 }
                        } else {
                            dst[d] = value(src[s])
                            if c == 2 { dst[d + 1] = Float(src[s + 3]) / 255 }
                        }
                    }
                }
            }
        }
        return out
    }
}
