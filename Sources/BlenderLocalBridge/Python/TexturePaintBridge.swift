import Foundation
import simd

// The Swift half of `_blenderkit_paint` (TexturePaintModule.c). These only
// move data across; what they do with it lives in TexturePaintSurface.swift,
// where the host tests can reach it.

/// Surfaces reported during one mirroring pass, installed together at its end.
enum TexturePaintMirror {
    nonisolated(unsafe) static var pending: [String: PaintSurface] = [:]
    nonisolated(unsafe) static var reporting = false
}

@_cdecl("bk_paint_surface_begin")
func bk_paint_surface_begin() {
    onMain {
        TexturePaintMirror.pending = [:]
        TexturePaintMirror.reporting = true
    }
}

@_cdecl("bk_paint_surface_push")
func bk_paint_surface_push(_ name: UnsafePointer<CChar>?,
                           _ triangleLoops: UnsafePointer<UInt32>?, _ triangleLoopCount: Int32,
                           _ loopUVs: UnsafePointer<Float>?, _ loopUVCount: Int32,
                           _ triangleSlots: UnsafePointer<Int32>?, _ triangleSlotCount: Int32,
                           _ slotImages: UnsafePointer<CChar>?,
                           _ baseColor: UnsafePointer<UInt8>?, _ baseColorCount: Int32,
                           _ activeSlot: Int32) -> Int32 {
    onMain {
        guard TexturePaintMirror.reporting, let name = name.map({ String(cString: $0) }),
              triangleLoopCount >= 0, loopUVCount >= 0
        else { return -1 }
        let loops = UnsafeBufferPointer(start: triangleLoops, count: triangleLoops == nil ? 0 : Int(triangleLoopCount))
        let uvs = UnsafeBufferPointer(start: loopUVs, count: loopUVs == nil ? 0 : Int(loopUVCount))
        let slots = UnsafeBufferPointer(start: triangleSlots, count: triangleSlots == nil ? 0 : Int(triangleSlotCount))
        let linked = UnsafeBufferPointer(start: baseColor, count: baseColor == nil ? 0 : Int(baseColorCount))
        guard let surface = PaintSurface.reported(triangleLoops: loops, loopUVs: uvs, triangleSlots: slots,
                                                  slotImages: slotImages.map { String(cString: $0) } ?? "",
                                                  baseColor: linked, activeSlot: Int(activeSlot))
        else { return -2 }
        TexturePaintMirror.pending[name] = surface
        return 0
    }
}

@_cdecl("bk_paint_surface_end")
func bk_paint_surface_end() {
    onMain {
        defer {
            TexturePaintMirror.pending = [:]
            TexturePaintMirror.reporting = false
        }
        guard let scene = PythonSceneBridge.scene else { return }
        TexturePaintImages.install(TexturePaintMirror.pending, into: scene)
    }
}

@_cdecl("bk_paint_image_push")
func bk_paint_image_push(_ name: UnsafePointer<CChar>?, _ width: Int32, _ height: Int32,
                         _ channels: Int32, _ isFloat: Int32,
                         _ pixels: UnsafePointer<Float>?, _ count: Int32) -> Int32 {
    onMain {
        guard let name = name.map({ String(cString: $0) }), let pixels,
              width > 0, height > 0, channels > 0,
              Int(count) >= Int(width) * Int(height) * Int(channels)
        else { return -1 }
        TexturePaintImages.receive(name: name, width: Int(width), height: Int(height),
                                   channels: Int(channels), isFloat: isFloat != 0,
                                   floats: UnsafeBufferPointer(start: pixels, count: Int(count)))
        return 0
    }
}

@_cdecl("bk_paint_image_info")
func bk_paint_image_info(_ name: UnsafePointer<CChar>?, _ width: UnsafeMutablePointer<Int32>?,
                         _ height: UnsafeMutablePointer<Int32>?,
                         _ channels: UnsafeMutablePointer<Int32>?) -> Int32 {
    onMain {
        guard let name = name.map({ String(cString: $0) }),
              let image = TexturePaintImages.image(named: name)
        else { return -1 }
        width?.pointee = Int32(image.width)
        height?.pointee = Int32(image.height)
        channels?.pointee = Int32(max(1, image.channels))
        return 0
    }
}

@_cdecl("bk_paint_image_pixels")
func bk_paint_image_pixels(_ name: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<Float>?,
                           _ capacity: Int32) -> Int32 {
    onMain {
        guard let name = name.map({ String(cString: $0) }), let out,
              let image = TexturePaintImages.image(named: name)
        else { return -1 }
        let floats = TexturePaintPixels.floats(from: image)
        guard floats.count <= Int(capacity) else { return -2 }
        floats.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: floats.count) }
        return Int32(floats.count)
    }
}

/// Blender now holds the viewport's pixels for an image. Nothing is left to
/// reconcile: a float image's values are the ones Blender was handed, and a
/// byte image's bytes are what Blender stores.
@_cdecl("bk_paint_image_written")
func bk_paint_image_written(_ name: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let name = name.map({ String(cString: $0) }),
              TexturePaintImages.image(named: name) != nil
        else { return -1 }
        return 0
    }
}

@_cdecl("bk_paint_shim_enter")
func bk_paint_shim_enter(_ name: UnsafePointer<CChar>?, _ width: Int32, _ height: Int32,
                         _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let name = name.map({ String(cString: $0) }),
              let object = PythonSceneBridge.object(name),
              let out, capacity > 0
        else { return -1 }
        let made = TexturePaintImages.prepareShim(object, in: scene,
                                                  width: Int(width), height: Int(height))
        let bytes = Array(made.joined(separator: "\n").utf8.prefix(Int(capacity) - 1))
        out.withMemoryRebound(to: UInt8.self, capacity: Int(capacity)) { dst in
            for (i, byte) in bytes.enumerated() { dst[i] = byte }
            dst[bytes.count] = 0
        }
        return 0
    }
}
