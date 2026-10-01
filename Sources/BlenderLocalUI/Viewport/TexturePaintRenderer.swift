import Foundation
import Metal
import simd

/// Draws objects through their paint surfaces: each material slot's image,
/// laid on by the UV of every triangle corner.
///
/// Where Blender shows a paint image, this shows it:
/// - in Texture Paint with Solid shading, on the object being painted — the
///   workbench switches that object to its texture colour;
/// - in Material Preview, wherever an image feeds the Principled BSDF's Base
///   Color, as EEVEE shades it.
///
/// A stroke changes a few texels at a time, so each image lives on the GPU
/// once and only the rectangle a stroke changed is copied up each frame.
final class TexturePaintRenderer {
    private let device: MTLDevice
    private var solid: MTLRenderPipelineState?
    private var solidXray: MTLRenderPipelineState?
    private var material: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var blank: MTLTexture?

    private struct SlotCorners {
        let slot: Int
        let buffer: MTLBuffer
        let count: Int
    }

    private struct Buffers {
        let cornerUVs: MTLBuffer
        let cornerVertices: MTLBuffer
        let slots: [SlotCorners]
        let surface: Int
        let mesh: Int
    }

    private var buffers: [UUID: Buffers] = [:]

    private struct GPUImage {
        weak var image: TextureImage?
        let texture: MTLTexture
        /// The same storage read as sRGB, for Material Preview, which lights
        /// in linear space.
        let srgb: MTLTexture
        var version: Int
    }

    private var images: [ObjectIdentifier: GPUImage] = [:]

    init(device: MTLDevice) {
        self.device = device
        guard let library = device.makeDefaultLibrary() else { return }
        func pipeline(_ fragment: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "texpaint_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .sourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        solid = pipeline("texpaint_fragment", blend: false)
        solidXray = pipeline("texpaint_fragment", blend: true)
        material = pipeline("pbr_fragment", blend: false)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .repeat
        s.tAddressMode = .repeat
        sampler = device.makeSamplerState(descriptor: s)

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1,
                                                         mipmapped: false)
        d.usage = .shaderRead
        blank = device.makeTexture(descriptor: d)
        var white: [UInt8] = [255, 255, 255, 255]
        blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
    }

    /// The solid pass's hook. Draws the object being texture-painted with its
    /// images and returns true; returns false, having drawn nothing, for
    /// anything the solid pass should draw as usual. `resume` is bound again
    /// before returning, since the solid pass sets its pipeline once.
    func drawSolid(_ obj: BKObject, vertices: MTLBuffer, encoder: MTLRenderCommandEncoder,
                   scene: BKScene, viewProjection: simd_float4x4, xray: Bool,
                   resume: MTLRenderPipelineState) -> Bool {
        guard scene.mode == .texturePaint, obj.id == scene.activeID,
              let target = obj.paintTarget,
              let pipeline = xray ? solidXray : solid,
              let buffers = buffers(for: obj, target.surface)
        else { return false }

        encoder.setRenderPipelineState(pipeline)
        var u = Uniforms(viewProjection: viewProjection, model: obj.modelMatrix,
                         normalMatrix: obj.modelMatrix.inverse.transpose,
                         baseColor: SIMD4(0.80, 0.80, 0.80, xray ? 0.4 : 1),
                         params: .zero)
        bind(buffers, vertices: vertices, encoder: encoder)
        for slot in buffers.slots {
            let image = slot.slot < target.images.count ? target.images[slot.slot] : nil
            let texture = image.flatMap { gpu($0)?.texture }
            u.params.z = texture == nil ? 0 : 1
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture ?? blank, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: slot.count, indexType: .uint32,
                                          indexBuffer: slot.buffer, indexBufferOffset: 0)
        }
        encoder.setRenderPipelineState(resume)
        return true
    }

    /// Material Preview's hook: an object whose paint image feeds Base Color
    /// is shaded with that image as its base colour, which replaces the
    /// socket's own value as a link does in Blender.
    func drawMaterial(_ obj: BKObject, vertices: MTLBuffer, encoder: MTLRenderCommandEncoder,
                      viewProjection: simd_float4x4, eye: SIMD3<Float>, cameraDistance: Float,
                      resume: MTLRenderPipelineState) -> Bool {
        guard let target = obj.paintTarget, target.surface.baseColorLinked.contains(true),
              let pipeline = material,
              let buffers = buffers(for: obj, target.surface)
        else { return false }

        encoder.setRenderPipelineState(pipeline)
        bind(buffers, vertices: vertices, encoder: encoder)
        let m = obj.material
        let connected = obj.shaderGraph.isConnected
        for slot in buffers.slots {
            let linked = target.surface.isBaseColor(slot: slot.slot)
            let image = linked && slot.slot < target.images.count ? target.images[slot.slot] : nil
            let texture = image.flatMap { gpu($0)?.srgb }
            let base: SIMD4<Float> = !connected ? SIMD4(0, 0, 0, 1) : (texture != nil ? SIMD4(1, 1, 1, 1) : m.baseColor)
            var u = PBRUniforms(viewProjection: viewProjection, model: obj.modelMatrix,
                                normalMatrix: obj.modelMatrix.inverse.transpose,
                                baseColor: base,
                                emission: SIMD4(m.emission.x, m.emission.y, m.emission.z,
                                                connected ? m.emissionStrength : 0),
                                params: SIMD4(m.metallic, m.roughness, m.ior, cameraDistance),
                                cameraPos: SIMD4(eye.x, eye.y, eye.z, texture == nil ? 0 : 1))
            encoder.setVertexBytes(&u, length: MemoryLayout<PBRUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PBRUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture ?? blank, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: slot.count, indexType: .uint32,
                                          indexBuffer: slot.buffer, indexBufferOffset: 0)
        }
        encoder.setRenderPipelineState(resume)
        return true
    }

    private func bind(_ b: Buffers, vertices: MTLBuffer, encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBuffer(b.cornerUVs, offset: 0, index: 2)
        encoder.setVertexBuffer(b.cornerVertices, offset: 0, index: 3)
        encoder.setFragmentSamplerState(sampler, index: 0)
    }

    /// The corner buffers for an object, rebuilt when its surface or its mesh
    /// is replaced.
    private func buffers(for obj: BKObject, _ surface: PaintSurface) -> Buffers? {
        if let cached = buffers[obj.id], cached.surface == surface.version, cached.mesh == obj.meshVersion {
            return cached
        }
        let mesh = obj.mesh
        guard surface.fits(mesh),
              let uvs = device.makeBuffer(bytes: surface.cornerUVs,
                                          length: MemoryLayout<SIMD2<Float>>.stride * surface.cornerUVs.count,
                                          options: .storageModeShared),
              let corners = device.makeBuffer(bytes: mesh.indices,
                                              length: MemoryLayout<UInt32>.stride * mesh.indices.count,
                                              options: .storageModeShared)
        else { return nil }
        var bySlot: [Int: [UInt32]] = [:]
        for t in 0..<(mesh.indices.count / 3) {
            let first = UInt32(3 * t)
            bySlot[surface.slot(ofTriangle: t), default: []] += [first, first + 1, first + 2]
        }
        let slots = bySlot.keys.sorted().compactMap { slot -> SlotCorners? in
            let list = bySlot[slot]!
            guard let buffer = device.makeBuffer(bytes: list, length: MemoryLayout<UInt32>.stride * list.count,
                                                 options: .storageModeShared) else { return nil }
            return SlotCorners(slot: slot, buffer: buffer, count: list.count)
        }
        if buffers.count > 32 { buffers.removeAll() }
        let entry = Buffers(cornerUVs: uvs, cornerVertices: corners, slots: slots,
                            surface: surface.version, mesh: obj.meshVersion)
        buffers[obj.id] = entry
        return entry
    }

    /// An image's texture, with whatever changed since the last frame copied
    /// up — only the rectangle when the image knows it.
    private func gpu(_ image: TextureImage) -> GPUImage? {
        let key = ObjectIdentifier(image)
        if var entry = images[key], entry.image === image,
           entry.texture.width == image.width, entry.texture.height == image.height {
            guard entry.version != image.version else { return entry }
            let rect = image.changedRect(since: entry.version)
                ?? (0, 0, image.width, image.height)
            upload(image, to: entry.texture, rect)
            entry.version = image.version
            images[key] = entry
            return entry
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                         height: image.height, mipmapped: false)
        d.usage = [.shaderRead, .pixelFormatView]
        guard let texture = device.makeTexture(descriptor: d),
              let srgb = texture.makeTextureView(pixelFormat: .rgba8Unorm_srgb)
        else { return nil }
        upload(image, to: texture, (0, 0, image.width, image.height))
        images = images.filter { $0.value.image != nil }
        let entry = GPUImage(image: image, texture: texture, srgb: srgb, version: image.version)
        images[key] = entry
        return entry
    }

    private func upload(_ image: TextureImage, to texture: MTLTexture,
                        _ rect: (x: Int, y: Int, width: Int, height: Int)) {
        guard rect.width > 0, rect.height > 0 else { return }
        image.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                            mipmapLevel: 0,
                            withBytes: base + (rect.y * image.width + rect.x) * 4,
                            bytesPerRow: image.width * 4)
        }
    }
}
