import Foundation
import Metal
import ObjectiveC
import simd

/// Matches `struct OverlayLineVertex` in ObjectOverlays.metal.
struct OverlayLineVertex {
    var position: SIMD4<Float>
    var other: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Matches `struct OverlayLineUniforms`.
struct OverlayLineUniforms {
    var viewProjection: simd_float4x4
    var viewport: SIMD4<Float>
}

/// Draws the lines `ObjectOverlays` builds for cameras, lights and empties.
///
/// A pass of its own, beside the viewport renderer rather than inside it: its
/// own pipeline, its own depth state, its own buffers. The renderer calls it
/// once per frame, straight after the grid.
///
/// That is before the surfaces, and it works out the same as Blender's order,
/// which draws extras after them: the lines write depth and test it at less or
/// equal (`DRW_STATE_WRITE_DEPTH | DRW_STATE_DEPTH_LESS_EQUAL`), so a surface
/// drawn afterwards covers a line only where it is nearer. Drawing here is what
/// lets one call serve wireframe, solid and Material Preview alike.
///
/// A light's ground line is translucent, and Blender draws it with that same
/// depth state and blending (`overlay_light.hh`, the "ground_line" pass). Drawn
/// before the surfaces it blends over the background rather than over a
/// surface behind it, so where it passes in front of one it reads darker than
/// in Blender. Leaving its depth unwritten instead would let that surface
/// paint over it, and the line would vanish where Blender shows it.
final class ObjectOverlayPass {
    /// Blender draws overlay wires `U.pixelsize` wide: a point.
    static let lineWidth: Float = 1

    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState

    /// Rebuilt every frame, so kept rather than reallocated; and three buffers
    /// in rotation, because the GPU may still be reading last frame's — the
    /// same arrangement as the renderer's own overlay buffers, for the same
    /// reason: `setVertexBytes` is capped at 4 KB.
    private var vertices: [OverlayLineVertex] = []
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var capacities = [0, 0, 0]
    private var slot = 0

    /// `library` is the app's default one unless given — a host tool compiles
    /// ObjectOverlays.metal itself.
    init?(device: MTLDevice, library: MTLLibrary? = nil) {
        guard let library = library ?? device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "overlay_line_vertex"),
              let fragmentFunction = library.makeFunction(name: "overlay_line_fragment")
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
        blend.sourceAlphaBlendFactor = .sourceAlpha
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }

        let state = MTLDepthStencilDescriptor()
        state.depthCompareFunction = .lessEqual
        state.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: state) else { return nil }
        self.pipeline = pipeline
        self.depth = depth
    }

    func draw(_ geometry: OverlayGeometry, encoder: MTLRenderCommandEncoder,
              viewProjection: simd_float4x4, drawableSize: CGSize, pixelsPerPoint: Float) {
        vertices.removeAll(keepingCapacity: true)
        for line in geometry.lines { appendRibbon(line) }
        for triangle in geometry.triangles {
            for corner in [triangle.a, triangle.b, triangle.c] {
                vertices.append(OverlayLineVertex(position: SIMD4(corner, 0), other: SIMD4(corner, 0),
                                                  color: triangle.color))
            }
        }
        // Last, so they blend over the lines they cross.
        for line in geometry.translucentLines { appendRibbon(line) }
        guard !vertices.isEmpty, let buffer = upload(device: encoder.device) else { return }

        var uniforms = OverlayLineUniforms(
            viewProjection: viewProjection,
            viewport: SIMD4(Float(drawableSize.width), Float(drawableSize.height),
                            Self.lineWidth * pixelsPerPoint, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OverlayLineUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    /// Two triangles per segment. The shader spreads a corner to the side its
    /// `w` names, measured from the end it is at towards the other end — so
    /// the far end's sides are the near end's, reversed.
    private func appendRibbon(_ line: OverlayGeometry.Line) {
        let a = line.a, b = line.b
        let aMinus = OverlayLineVertex(position: SIMD4(a, -1), other: SIMD4(b, 0), color: line.color)
        let aPlus = OverlayLineVertex(position: SIMD4(a, 1), other: SIMD4(b, 0), color: line.color)
        let bSameAsAPlus = OverlayLineVertex(position: SIMD4(b, -1), other: SIMD4(a, 0), color: line.color)
        let bSameAsAMinus = OverlayLineVertex(position: SIMD4(b, 1), other: SIMD4(a, 0), color: line.color)
        vertices += [aMinus, aPlus, bSameAsAPlus, aMinus, bSameAsAPlus, bSameAsAMinus]
    }

    private func upload(device: MTLDevice) -> MTLBuffer? {
        let needed = MemoryLayout<OverlayLineVertex>.stride * vertices.count
        slot = (slot + 1) % buffers.count
        if buffers[slot] == nil || capacities[slot] < needed {
            let capacity = max(needed * 2, 64 * 1024)
            buffers[slot] = device.makeBuffer(length: capacity, options: .storageModeShared)
            capacities[slot] = buffers[slot] == nil ? 0 : capacity
        }
        guard let buffer = buffers[slot] else { return nil }
        vertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: needed)
        }
        return buffer
    }

    /// Where a renderer keeps its pass: one per renderer, so two viewports on
    /// screen never write into each other's buffers mid-frame.
    fileprivate static var association: UInt8 = 0
}

extension ViewportRenderer {
    /// Cameras, lights and empties, as Blender's overlays draw them — unless
    /// the Overlays toggle is off, which hides them in Blender too.
    func drawObjectOverlays(_ encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4,
                            drawableSize: CGSize) {
        guard options.showOverlays, pointSize.width > 0, pointSize.height > 0 else { return }
        let view = OverlayView(camera: camera, size: pointSize)
        let geometry = ObjectOverlays.geometry(in: scene, view: view)
        guard !geometry.isEmpty, let pass = objectOverlayPass(device: encoder.device) else { return }
        pass.draw(geometry, encoder: encoder, viewProjection: viewProjection,
                  drawableSize: drawableSize,
                  pixelsPerPoint: Float(drawableSize.width / pointSize.width))
    }

    /// The camera, light or empty a tap at `ndc` takes: the nearest one whose
    /// lines or origin are within reach, unless a mesh face is in front of it
    /// there. Nil leaves the tap to the meshes.
    func overlayHitTest(ndc: SIMD2<Float>) -> BKObject? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let point = CGPoint(x: CGFloat(ndc.x + 1) * 0.5 * pointSize.width,
                            y: CGFloat(1 - ndc.y) * 0.5 * pointSize.height)
        // With the overlays hidden, wire objects are still drawn, and so
        // still taken, in Wireframe shading only (ObjectOverlayPicking says
        // where in Blender's source); cameras, lights and empties never.
        return ObjectOverlayPicking.object(at: point, in: scene,
                                           view: OverlayView(camera: camera, size: pointSize),
                                           overlays: options.showOverlays,
                                           wireframe: shading == .wireframe)
    }

    private func objectOverlayPass(device: MTLDevice) -> ObjectOverlayPass? {
        let stored = objc_getAssociatedObject(self, &ObjectOverlayPass.association)
        if let pass = stored as? ObjectOverlayPass { return pass }
        // A pipeline that failed to build once will fail again; say so once
        // and stop asking every frame.
        guard stored == nil else { return nil }
        let pass = ObjectOverlayPass(device: device)
        if pass == nil { print("[Blender Local] the camera, light and empty overlay pipeline did not build") }
        objc_setAssociatedObject(self, &ObjectOverlayPass.association, pass ?? NSNull(),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return pass
    }
}
