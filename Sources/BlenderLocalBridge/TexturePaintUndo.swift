import Foundation

// Texture Paint's pixels in the simulator's undo steps.
//
// On device an undo step is a .blend with the image packed into it. With the
// simulator's shim the viewport's images are the scene, so a step has to keep
// what it takes to put each image back. A full copy per step is 4 MB for a
// 1024² byte image — a quarter of a gigabyte over 64 steps, and five times that
// for a float image.
//
// Blender's own image undo keeps tiles (`ED_IMAGE_UNDO_TILE_SIZE`), and so
// does this. An image is cut into 64×64 tiles; a step holds references to
// tiles that never change; and a tile is copied only when its texels differ
// from the same tile the image was last captured with. A stroke costs the
// tiles it crossed. Undo and redo stay exact because every step still names a
// tile for every texel, so each rebuilds the whole image on its own.

/// The texels of one tile, bytes and, for a float image, floats. Never
/// changed once made, so any number of steps can share it.
public final class TexturePaintTile: @unchecked Sendable {
    let bytes: [UInt8]
    let floats: [Float]

    init(bytes: [UInt8], floats: [Float]) {
        self.bytes = bytes
        self.floats = floats
    }

    /// The memory the tile's texels take.
    var byteCount: Int { bytes.count + floats.count * MemoryLayout<Float>.stride }
}

/// One image as an undo step keeps it.
public struct TexturePaintUndoImage: @unchecked Sendable {
    /// Texels on a side of a tile.
    public static let tileSize = 64

    public let name: String
    public let width: Int
    public let height: Int
    public let channels: Int
    public let isFloat: Bool
    /// Row by row from the top, `tileSize` texels square except at the right
    /// and bottom edges.
    let tiles: [TexturePaintTile]

    private var tilesAcross: Int { (width + Self.tileSize - 1) / Self.tileSize }

    /// The image as it is now, sharing every tile that has not changed since
    /// it was last captured or restored.
    public static func capture(_ image: TextureImage) -> TexturePaintUndoImage {
        let size = tileSize
        let width = image.width, height = image.height
        let floats = image.isFloat && image.floats?.count == width * height * 4 ? image.floats : nil
        let key = ObjectIdentifier(image)
        Cache.prune()
        let previous: TexturePaintUndoImage? = Cache.entries[key].flatMap { entry in
            guard entry.image === image else { return nil }
            let state = entry.state
            guard state.width == width, state.height == height,
                  state.tiles.first.map({ !$0.floats.isEmpty }) == (floats != nil) else { return nil }
            return state
        }

        var tiles: [TexturePaintTile] = []
        tiles.reserveCapacity(((width + size - 1) / size) * ((height + size - 1) / size))
        image.pixels.withUnsafeBufferPointer { pixelBuffer in
            let noFloats: [Float] = []
            (floats ?? noFloats).withUnsafeBufferPointer { floatBuffer in
                guard let pixelBase = pixelBuffer.baseAddress else { return }
                // An empty array can still hand out an address; a byte image
                // has no floats to read there.
                let floatBase = floats == nil ? nil : floatBuffer.baseAddress
                for top in stride(from: 0, to: height, by: size) {
                    for left in stride(from: 0, to: width, by: size) {
                        let w = min(size, width - left), h = min(size, height - top)
                        if let old = previous?.tiles[tiles.count],
                           Self.same(old, pixelBase, floatBase, width, left, top, w, h) {
                            tiles.append(old)
                            continue
                        }
                        var bytes = [UInt8](repeating: 0, count: w * h * 4)
                        var values = [Float](repeating: 0, count: floatBase == nil ? 0 : w * h * 4)
                        bytes.withUnsafeMutableBufferPointer { out in
                            for row in 0..<h {
                                (out.baseAddress! + row * w * 4)
                                    .update(from: pixelBase + ((top + row) * width + left) * 4, count: w * 4)
                            }
                        }
                        if let floatBase {
                            values.withUnsafeMutableBufferPointer { out in
                                for row in 0..<h {
                                    (out.baseAddress! + row * w * 4)
                                        .update(from: floatBase + ((top + row) * width + left) * 4, count: w * 4)
                                }
                            }
                        }
                        tiles.append(TexturePaintTile(bytes: bytes, floats: values))
                    }
                }
            }
        }
        let state = TexturePaintUndoImage(name: image.name, width: width, height: height,
                                          channels: image.channels, isFloat: image.isFloat, tiles: tiles)
        Cache.entries[key] = Cache.Entry(image: image, state: state)
        return state
    }

    /// Whether a tile holds exactly the texels at `left, top` in the image,
    /// compared as memory: a float is the same only when every bit is.
    private static func same(_ tile: TexturePaintTile, _ pixels: UnsafePointer<UInt8>,
                             _ floats: UnsafePointer<Float>?, _ width: Int,
                             _ left: Int, _ top: Int, _ w: Int, _ h: Int) -> Bool {
        guard tile.bytes.count == w * h * 4, tile.floats.count == (floats == nil ? 0 : w * h * 4) else {
            return false
        }
        let bytesMatch = tile.bytes.withUnsafeBufferPointer { kept -> Bool in
            for row in 0..<h where memcmp(kept.baseAddress! + row * w * 4,
                                          pixels + ((top + row) * width + left) * 4, w * 4) != 0 {
                return false
            }
            return true
        }
        guard bytesMatch, let floats else { return bytesMatch }
        return tile.floats.withUnsafeBufferPointer { kept -> Bool in
            let length = w * 4 * MemoryLayout<Float>.stride
            for row in 0..<h where memcmp(kept.baseAddress! + row * w * 4,
                                          floats + ((top + row) * width + left) * 4, length) != 0 {
                return false
            }
            return true
        }
    }

    /// A new image with this step's texels. The next capture of it shares
    /// these tiles again.
    public func restore() -> TextureImage {
        let size = Self.tileSize
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var values = [Float](repeating: 0, count: isFloat && tiles.first.map({ !$0.floats.isEmpty }) == true
                             ? width * height * 4 : 0)
        pixels.withUnsafeMutableBufferPointer { out in
            values.withUnsafeMutableBufferPointer { floatOut in
                for (index, tile) in tiles.enumerated() {
                    let left = (index % tilesAcross) * size, top = (index / tilesAcross) * size
                    let w = min(size, width - left), h = min(size, height - top)
                    tile.bytes.withUnsafeBufferPointer { kept in
                        for row in 0..<h {
                            (out.baseAddress! + ((top + row) * width + left) * 4)
                                .update(from: kept.baseAddress! + row * w * 4, count: w * 4)
                        }
                    }
                    guard !tile.floats.isEmpty, let floatBase = floatOut.baseAddress else { continue }
                    tile.floats.withUnsafeBufferPointer { kept in
                        for row in 0..<h {
                            (floatBase + ((top + row) * width + left) * 4)
                                .update(from: kept.baseAddress! + row * w * 4, count: w * 4)
                        }
                    }
                }
            }
        }
        let image = TextureImage(width: width, height: height, name: name, pixels: pixels)
        image.channels = channels
        image.isFloat = isFloat
        image.floats = values.isEmpty ? nil : values
        Cache.prune()
        Cache.entries[ObjectIdentifier(image)] = Cache.Entry(image: image, state: self)
        return image
    }

    /// The memory the texels of all these images take, each tile counted once
    /// however many steps share it.
    public static func retainedBytes<S: Sequence>(_ images: S) -> Int where S.Element == TexturePaintUndoImage {
        var seen = Set<ObjectIdentifier>()
        var total = 0
        for image in images {
            for tile in image.tiles where seen.insert(ObjectIdentifier(tile)).inserted {
                total += tile.byteCount
            }
        }
        return total
    }

    /// The state each live image was last captured or restored with, which
    /// its next capture compares against.
    private enum Cache {
        final class Entry {
            weak var image: TextureImage?
            let state: TexturePaintUndoImage
            init(image: TextureImage, state: TexturePaintUndoImage) {
                self.image = image
                self.state = state
            }
        }

        nonisolated(unsafe) static var entries: [ObjectIdentifier: Entry] = [:]

        static func prune() {
            if entries.values.contains(where: { $0.image == nil }) {
                entries = entries.filter { $0.value.image != nil }
            }
        }
    }
}

public extension SceneSnapshot {
    /// The memory the paint of these snapshots holds, shared tiles once.
    static func paintBytes(_ snapshots: [SceneSnapshot]) -> Int {
        TexturePaintUndoImage.retainedBytes(snapshots.flatMap { $0.paint.values.flatMap { $0.images.values } })
    }
}
