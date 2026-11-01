import Foundation
import ImageIO
import Metal
import ObjectiveC
import simd

/// Matches `struct ImageEmptyVertex` in ObjectOverlays.metal.
struct ImageEmptyVertex {
    var position: SIMD4<Float>
    var uv: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}

/// Matches `struct ImageEmptyUniforms`.
struct ImageEmptyUniforms {
    var viewProjection: simd_float4x4
    var tint: SIMD4<Float>
    var flags: SIMD4<Float>
}

/// Draws the pictures on image empties (`ImageEmptyDraw`), in Blender's four
/// passes: Back before the grid and everything else, with neither depth test
/// nor write (Blender draws them at the far plane where nothing else is);
/// Default without Opacity with the overlays, before the surfaces, depth
/// tested and written, so a surface behind it is hidden as in Blender; Default
/// with Opacity after the surfaces, depth tested, not written, back to front;
/// Front and In Front last, over everything. One pipeline, premultiplied
/// blending (`DRW_STATE_BLEND_ALPHA_PREMUL`): the opaque pass's alpha is 1.
///
/// The picture is read from the file the mirror names (`EmptyDisplay
/// .imageFile`: the image's own, or its packed bytes written to a cache) and
/// kept as a texture until the file changes. It is drawn at most 2048 pixels
/// along its longer side: a 12-megapixel photograph is 48 MB as RGBA, for a
/// reference image the viewport shows a fraction of that.
final class ImageEmptyPass {
    static let maxSide = 2048

    private let pipeline: MTLRenderPipelineState
    private var depthStates: [ImageEmptyDraw.Pass: MTLDepthStencilState] = [:]
    private var textures: [String: (texture: MTLTexture, stamp: Date?)] = [:]
    private var failed: Set<String> = []

    init?(device: MTLDevice, library: MTLLibrary? = nil) {
        guard let library = library ?? device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "image_empty_vertex"),
              let fragmentFunction = library.makeFunction(name: "image_empty_fragment")
        else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertexFunction
        d.fragmentFunction = fragmentFunction
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.depthAttachmentPixelFormat = .depth32Float
        let blend = d.colorAttachments[0]!
        blend.isBlendingEnabled = true
        blend.rgbBlendOperation = .add
        blend.alphaBlendOperation = .add
        blend.sourceRGBBlendFactor = .one
        blend.sourceAlphaBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.pipeline = pipeline
        for (pass, compare, write) in [(ImageEmptyDraw.Pass.back, MTLCompareFunction.always, false),
                                       (.scene, .less, true), (.blended, .lessEqual, false),
                                       (.front, .always, false)] {
            let state = MTLDepthStencilDescriptor()
            state.depthCompareFunction = compare
            state.isDepthWriteEnabled = write
            depthStates[pass] = device.makeDepthStencilState(descriptor: state)
        }
    }

    /// Draws the quads of `pass` among `quads`.
    func draw(_ quads: [ImageEmptyDraw.Quad], pass: ImageEmptyDraw.Pass,
              encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4) {
        let these = quads.filter { $0.pass == pass }
        guard !these.isEmpty, let depth = depthStates[pass] else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        for quad in these {
            guard let texture = texture(for: quad.file, device: encoder.device) else { continue }
            let uvs = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
            let order = [0, 1, 2, 0, 2, 3]
            var vertices = order.map { ImageEmptyVertex(position: SIMD4(quad.corners[$0], 1), uv: uvs[$0]) }
            var uniforms = ImageEmptyUniforms(viewProjection: viewProjection, tint: quad.tint,
                                              flags: SIMD4(quad.alphaBlend ? 1 : 0,
                                                           quad.premultiplied ? 1 : 0, 0, 0))
            encoder.setVertexBytes(&vertices, length: MemoryLayout<ImageEmptyVertex>.stride * vertices.count,
                                   index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ImageEmptyUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImageEmptyUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    /// The texture for `path`, loaded once and again when the file changes.
    func texture(for path: String, device: MTLDevice) -> MTLTexture? {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = textures[path], cached.stamp == stamp { return cached.texture }
        let key = path + "|" + (stamp.map { "\($0.timeIntervalSince1970)" } ?? "")
        guard !failed.contains(key) else { return nil }
        guard let texture = Self.load(path, device: device) else {
            failed.insert(key)
            print("[Blender Local] the picture at \(path) could not be read for the viewport")
            return nil
        }
        textures[path] = (texture, stamp)
        return texture
    }

    /// Decodes `path` to premultiplied RGBA8, scaled to `maxSide`, as Blender
    /// reads the file (`ReferenceImages.viewportImage`: its EXIF orientation
    /// and colour profile ignored, which Blender ignores too), into an sRGB
    /// context so the values stay the file's.
    static func load(_ path: String, device: MTLDevice) -> MTLTexture? {
        guard let image = ReferenceImages.viewportImage(at: path, maxSide: maxSide),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    fileprivate static var association: UInt8 = 0
}

extension ViewportRenderer {
    /// The pictures this frame draws, worked out once per frame.
    func imageEmptyQuads() -> [ImageEmptyDraw.Quad] {
        guard options.showOverlays, pointSize.width > 0, pointSize.height > 0 else { return [] }
        return ImageEmptyDraw.quads(in: scene, view: OverlayView(camera: camera, size: pointSize))
    }

    func drawImageEmpties(_ quads: [ImageEmptyDraw.Quad], pass: ImageEmptyDraw.Pass,
                          encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4) {
        guard quads.contains(where: { $0.pass == pass }),
              let images = imageEmptyPass(device: encoder.device) else { return }
        images.draw(quads, pass: pass, encoder: encoder, viewProjection: viewProjection)
    }

    private func imageEmptyPass(device: MTLDevice) -> ImageEmptyPass? {
        let stored = objc_getAssociatedObject(self, &ImageEmptyPass.association)
        if let pass = stored as? ImageEmptyPass { return pass }
        guard stored == nil else { return nil }
        let pass = ImageEmptyPass(device: device)
        if pass == nil { print("[Blender Local] the image empty pipeline did not build") }
        objc_setAssociatedObject(self, &ImageEmptyPass.association, pass ?? NSNull(),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return pass
    }
}
