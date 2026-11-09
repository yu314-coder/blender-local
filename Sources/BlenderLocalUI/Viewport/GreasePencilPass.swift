import Foundation
import Metal
import ObjectiveC
import simd

/// Matches `struct GPUniforms` in GreasePencil.metal.
struct GPUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var inverseViewProjection: simd_float4x4
    var viewport: SIMD4<Float>
    var plane: SIMD4<Float>
    var params: SIMD4<Float>
    var outline: SIMD4<Float>
}

/// A stroke being drawn, before Blender has it: drawn over everything, in
/// the view's points, the moment each sample arrives.
struct GPLiveStroke {
    /// Each sample's place in the view (points), radius (points) and colour.
    var points: [GreasePencilGeometry.Point] = []
    var isEmpty: Bool { points.isEmpty }
}

/// Draws every Grease Pencil object (GreasePencilGeometry builds what), the
/// selection's outline round a selected one, and the stroke under the finger.
///
/// A pass of its own beside the renderer, as the camera, light and empty
/// overlays are: its own pipeline, depth state and buffers. Each object's
/// buffers are built once per change of its drawings (`greasePencilVersion`)
/// and kept, so orbiting a 20,000-point drawing uploads nothing.
final class GreasePencilPass {
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState

    private struct Cached {
        var points: MTLBuffer
        var primitives: MTLBuffer
        var count: Int
        var ghosts: Int
        var version: Int
        var withGhosts: Bool
    }
    private var cache: [UUID: Cached] = [:]
    /// The live stroke's buffers, three in rotation as the GPU may still read
    /// last frame's.
    private var liveBuffers: [(MTLBuffer, MTLBuffer)?] = [nil, nil, nil]
    private var liveCapacity = [0, 0, 0]
    private var liveSlot = 0

    init?(device: MTLDevice, library: MTLLibrary? = nil) {
        guard let library = library ?? device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "gp_vertex"),
              let fragmentFunction = library.makeFunction(name: "gp_fragment")
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
        blend.sourceRGBBlendFactor = .sourceAlpha
        blend.sourceAlphaBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        let state = MTLDepthStencilDescriptor()
        state.depthCompareFunction = .less
        state.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: state) else { return nil }
        self.pipeline = pipeline
        self.depth = depth
    }

    /// Every visible Grease Pencil object, those Show In Front last.
    /// `playing`: the onion skins stay hidden, as Blender hides them during
    /// playback (and as the Onion Skins overlay off hides them).
    func draw(scene: BKScene, encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
              focal: Float, drawableSize: CGSize, pixelsPerPoint: Float, playing: Bool, overlays: Bool) {
        let objects = scene.objects.filter { $0.visible && $0.isGreasePencil && $0.greasePencilDrawings != nil }
        // Buffers of an object no longer drawn go.
        let drawn = Set(objects.map(\.id))
        for id in cache.keys where !drawn.contains(id) { cache[id] = nil }
        guard !objects.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        let ordered = objects.filter { $0.greasePencilInfo?.inFront != true }
            + objects.filter { $0.greasePencilInfo?.inFront == true }
        // Show In Front objects over each other in the order drawn: each a
        // depth band of its own (1e-5 apart, room for 40,000 strokes each).
        var frontIndex: Float = 0
        for obj in ordered {
            guard let info = obj.greasePencilInfo, let drawings = obj.greasePencilDrawings,
                  let cached = buffers(for: obj, info: info, drawings: drawings, ghosts: !playing,
                                       device: encoder.device), cached.count > 0
            else { continue }
            let model = obj.modelMatrix
            let origin = SIMD3(model.columns.3.x, model.columns.3.y, model.columns.3.z)
            var normal = SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z)
            normal = simd_length(normal) > 1e-9 ? simd_normalize(normal) : SIMD3(0, 1, 0)
            let scale = simd_length(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z))
            let mode: Float = info.inFront ? 2 : (info.depthOrder3D ? 1 : 0)
            var plane = SIMD4(normal, simd_dot(normal, origin))
            if info.inFront {
                // The band's base depth, where the drawing plane is not used.
                plane.w = max(1e-3 - frontIndex * 1e-5, 2e-4)
                frontIndex += 1
            }
            var u = GPUniforms(viewProjection: viewProjection, model: model,
                               inverseViewProjection: viewProjection.inverse,
                               viewport: SIMD4(Float(drawableSize.width), Float(drawableSize.height),
                                               focal, pixelsPerPoint),
                               plane: plane,
                               params: SIMD4(mode, 0, scale, 0.5),
                               outline: .zero)
            encoder.setVertexBuffer(cached.points, offset: 0, index: 0)
            encoder.setVertexBuffer(cached.primitives, offset: 0, index: 1)
            // Blender's outline round a selected object: its strokes a little
            // wider, in the selection's colours, under the strokes themselves.
            let selected = scene.selection.contains(obj.id)
            if overlays, selected || obj.id == scene.hoveredID, scene.mode == .object {
                var o = u
                o.params.y = 1.5 * pixelsPerPoint
                o.outline = !selected ? SIMD4(1.000, 0.627, 0.157, 0.45)
                    : (obj.id == scene.activeID ? SIMD4(1.000, 0.627, 0.157, 1) : SIMD4(0.929, 0.341, 0.000, 1))
                encoder.setVertexBytes(&o, length: MemoryLayout<GPUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&o, length: MemoryLayout<GPUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: cached.count - cached.ghosts, baseInstance: cached.ghosts)
            }
            encoder.setVertexBytes(&u, length: MemoryLayout<GPUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&u, length: MemoryLayout<GPUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: cached.count)
        }
    }

    /// The stroke under the finger, over everything.
    func drawLive(_ stroke: GPLiveStroke, encoder: MTLRenderCommandEncoder, drawableSize: CGSize,
                  pixelsPerPoint: Float) {
        guard !stroke.points.isEmpty else { return }
        var primitives: [GreasePencilGeometry.Primitive] = []
        let n = stroke.points.count
        if n == 1 {
            primitives.append(.init(a: 0, b: 0, c: 0, orderKind: 1, colour: .zero))
        } else {
            for i in 0..<(n - 1) {
                primitives.append(.init(a: UInt32(i), b: UInt32(i + 1), c: 0, orderKind: 1, colour: .zero))
            }
        }
        liveSlot = (liveSlot + 1) % liveBuffers.count
        let pointBytes = MemoryLayout<GreasePencilGeometry.Point>.stride * n
        let primitiveBytes = MemoryLayout<GreasePencilGeometry.Primitive>.stride * primitives.count
        if liveBuffers[liveSlot] == nil || liveCapacity[liveSlot] < max(pointBytes, primitiveBytes) {
            let capacity = max(max(pointBytes, primitiveBytes) * 2, 64 * 1024)
            if let a = encoder.device.makeBuffer(length: capacity, options: .storageModeShared),
               let b = encoder.device.makeBuffer(length: capacity, options: .storageModeShared) {
                liveBuffers[liveSlot] = (a, b)
                liveCapacity[liveSlot] = capacity
            }
        }
        guard let (pointBuffer, primitiveBuffer) = liveBuffers[liveSlot] else { return }
        stroke.points.withUnsafeBytes { pointBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: pointBytes) }
        primitives.withUnsafeBytes { primitiveBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: primitiveBytes) }
        var u = GPUniforms(viewProjection: matrix_identity_float4x4, model: matrix_identity_float4x4,
                           inverseViewProjection: matrix_identity_float4x4,
                           viewport: SIMD4(Float(drawableSize.width), Float(drawableSize.height), 1, pixelsPerPoint),
                           plane: .zero, params: SIMD4(3, 0, 1, 0.5), outline: .zero)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(primitiveBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&u, length: MemoryLayout<GPUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GPUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: primitives.count)
    }

    private func buffers(for obj: BKObject, info: GreasePencilInfo, drawings: GreasePencilDrawings,
                         ghosts: Bool, device: MTLDevice) -> Cached? {
        if let cached = cache[obj.id], cached.version == obj.greasePencilVersion, cached.withGhosts == ghosts {
            return cached
        }
        let built = GreasePencilGeometry.build(info: info, drawings: drawings, ghosts: ghosts)
        guard !built.points.isEmpty, !built.primitives.isEmpty,
              let points = device.makeBuffer(bytes: built.points,
                                             length: MemoryLayout<GreasePencilGeometry.Point>.stride * built.points.count,
                                             options: .storageModeShared),
              let primitives = device.makeBuffer(bytes: built.primitives,
                                                 length: MemoryLayout<GreasePencilGeometry.Primitive>.stride
                                                    * built.primitives.count,
                                                 options: .storageModeShared)
        else {
            cache[obj.id] = nil
            return nil
        }
        let cached = Cached(points: points, primitives: primitives, count: built.primitives.count,
                            ghosts: built.ghostPrimitives, version: obj.greasePencilVersion, withGhosts: ghosts)
        cache[obj.id] = cached
        return cached
    }

    fileprivate static var association: UInt8 = 0
}

extension ViewportRenderer {
    /// Grease Pencil objects and the stroke being drawn (`gpLiveStroke`),
    /// after the surfaces: their strokes are depth-tested against them.
    func drawGreasePencil(_ encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                          drawableSize: CGSize) {
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        let hasObjects = scene.objects.contains { $0.isGreasePencil && $0.visible }
        guard hasObjects || !gpLiveStroke.isEmpty, let pass = greasePencilPass(device: encoder.device) else { return }
        let ppp = Float(drawableSize.width / pointSize.width)
        let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        // Pixels per world unit at w = 1: the projection's vertical scale
        // times half the height.
        let focal = camera.projectionMatrix(aspect: aspect)[1][1] * Float(drawableSize.height) / 2
        if hasObjects {
            pass.draw(scene: scene, encoder: encoder, viewProjection: viewProjection, focal: focal,
                      drawableSize: drawableSize, pixelsPerPoint: ppp, playing: scene.playbackRunning || !options.showOnionSkins,
                      overlays: options.showOverlays)
        }
        pass.drawLive(gpLiveStroke, encoder: encoder, drawableSize: drawableSize, pixelsPerPoint: ppp)
    }

    /// The Grease Pencil object a tap at `ndc` takes: the one whose strokes
    /// (or fills) are nearest, within a fingertip's reach.
    func greasePencilHitTest(ndc: SIMD2<Float>, aspect: Float) -> BKObject? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let size = SIMD2(Float(pointSize.width), Float(pointSize.height))
        let point = SIMD2((ndc.x + 1) / 2 * size.x, (1 - ndc.y) / 2 * size.y)
        let viewProjection = camera.viewProjection(aspect: aspect)
        let focal = camera.projectionMatrix(aspect: aspect)[1][1] * size.y / 2
        var best: (BKObject, Float)?
        for obj in scene.objects where obj.visible && obj.isGreasePencil {
            guard let info = obj.greasePencilInfo, let drawings = obj.greasePencilDrawings else { continue }
            let model = obj.modelMatrix
            let scale = simd_length(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z))
            if let d = GreasePencilGeometry.pickDistance(point, info: info, drawings: drawings,
                                                         toClip: viewProjection * model, size: size,
                                                         scale: scale, focal: focal, reach: 12),
               best == nil || d < best!.1 {
                best = (obj, d)
            }
        }
        return best?.0
    }

    private func greasePencilPass(device: MTLDevice) -> GreasePencilPass? {
        let stored = objc_getAssociatedObject(self, &GreasePencilPass.association)
        if let pass = stored as? GreasePencilPass { return pass }
        guard stored == nil else { return nil }
        let pass = GreasePencilPass(device: device)
        if pass == nil { print("[Blender Local] the Grease Pencil pipeline did not build") }
        objc_setAssociatedObject(self, &GreasePencilPass.association, pass ?? NSNull(),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return pass
    }
}
