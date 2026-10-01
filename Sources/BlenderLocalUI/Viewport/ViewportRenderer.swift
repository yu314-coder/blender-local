import Foundation
import Metal
import MetalKit
import simd

/// Matches `struct Uniforms` in Shaders.metal. Every member is 16-byte aligned,
/// so the Swift and MSL layouts agree without explicit padding.
struct Uniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var normalMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Matches `struct PBRUniforms` in Shaders.metal.
struct PBRUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var normalMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var emission: SIMD4<Float>
    var params: SIMD4<Float>
    var cameraPos: SIMD4<Float>
}

/// Matches `struct GridIn`.
struct GridVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

/// Draws the 3D viewport in Blender's Solid shading mode.
///
/// Order matters: the grid goes down first without writing depth, then the
/// selection outlines, then the shaded surfaces on top — which is how the
/// inverted hull ends up visible only around each silhouette.
final class ViewportRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var meshPipeline: MTLRenderPipelineState!
    /// Same shader, alpha-blended, for Blender's X-Ray.
    private var meshXrayPipeline: MTLRenderPipelineState!
    private var outlinePipeline: MTLRenderPipelineState!
    private var gridPipeline: MTLRenderPipelineState!
    /// Edit-mode vertex dots.
    private var pointPipeline: MTLRenderPipelineState!
    /// Material Preview's metallic/roughness shading.
    private var pbrPipeline: MTLRenderPipelineState!
    /// Per-vertex colour, for Vertex Paint and Weight Paint.
    private var attributePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var gridDepthState: MTLDepthStencilState!
    /// Always passes and never writes: for overlays that must stay on top.
    private var overlayDepthState: MTLDepthStencilState!
    /// Passes at equal depth, for geometry drawn exactly on top of geometry
    /// already in the buffer — a `.less` test rejects a coplanar overlay
    /// outright, which is why the selected-face fill drew nothing at first.
    private var coplanarDepthState: MTLDepthStencilState!

    private var gridBuffer: MTLBuffer?
    private var gridVertexCount = 0

    /// Scratch buffers for overlay geometry that is rebuilt every frame.
    ///
    /// `setVertexBytes` is capped at 4 KB. The transform gizmo is well past
    /// that — the rotate rings alone come to 48 KB — and exceeding the cap is
    /// undefined: the simulator tolerated it and the device did not, which is
    /// why selecting Move, Rotate or Scale crashed on hardware while every
    /// simulator sweep passed.
    ///
    /// Three buffers in rotation, because the GPU may still be reading last
    /// frame's while this frame is being written.
    private var overlayBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var overlayCapacities = [0, 0, 0]
    private var overlaySlot = 0

    private struct MeshBuffers {
        var vertex: MTLBuffer
        /// Nil for a mesh with no faces — a wire circle, an unfilled curve —
        /// which is drawn by its edges alone (`drawWires`).
        var index: MTLBuffer?
        var count: Int
        var edges: MTLBuffer?
        var edgeCount: Int
        /// Only the edges Blender has, for edit mode's wireframe.
        var realEdges: MTLBuffer?
        var realEdgeCount: Int
        /// Blender's seam edges, two vertex indices each, drawn in edit mode.
        var seams: MTLBuffer?
        var seamCount: Int
        /// The vertices edit mode gives a dot, when Blender has hidden some;
        /// nil means all of them.
        var shownVertices: MTLBuffer?
        var shownVertexCount: Int
        var hiddenVertexCount: Int
        var version: Int
    }

    /// Keyed by object, not by primitive kind: a modifier stack makes each
    /// object's mesh its own, and `meshVersion` tells us when to re-upload.
    private var meshCache: [UUID: MeshBuffers] = [:]
    /// Edit mode's overlay buffers for an object whose cage is not the mesh
    /// drawn — the simulator's, under a Swift modifier stack (`editCage`).
    private var cageCache: [UUID: MeshBuffers] = [:]
    /// Painted textures, re-uploaded when the image's version changes.
    private var textureCache: [UUID: (texture: MTLTexture, version: Int)] = [:]
    private var attributeCache: [UUID: (buffer: MTLBuffer, version: Int)] = [:]
    private var maskCache: [UUID: (buffer: MTLBuffer, version: Int)] = [:]
    private var linearSampler: MTLSamplerState!
    /// Texture Paint's images and the per-corner UVs they are drawn through.
    private lazy var texturePaint = TexturePaintRenderer(device: device)

    /// Blender's grid extends 1 km; matching that would fade to nothing on a
    /// tablet, so it is sized to a comfortable working area.
    private let gridExtent: Float = 20

    var scene: BKScene
    var camera: ViewportCamera
    var shading: ViewportShading = .solid
    var options = ViewportOptions()
    /// Which transform gizmo to draw, or nil for none. Set from the active
    /// toolbar tool.
    var gizmoMode: TransformGizmo.Mode?
    /// The handle under the finger or hovering Pencil, drawn in white.
    var gizmoHighlight: TransformGizmo.Handle?
    /// The view's size in points. `drawableSize` is in pixels, and the gizmo
    /// must be sized in the same units the touch handlers hit-test in or the
    /// handles land where they are not drawn.
    ///
    /// Read from the view at the top of every `draw`, not pushed in from
    /// SwiftUI: `updateUIView` can run before the view has been laid out, and
    /// when it does not run again the value stays (0, 0). A zero height made
    /// the gizmo about 700 metres across — built, drawn, and entirely outside
    /// the frame, which looked exactly like a gizmo that was never drawn.
    private(set) var pointSize: CGSize = .zero

    init?(device: MTLDevice, scene: BKScene, camera: ViewportCamera) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.scene = scene
        self.camera = camera
        super.init()
        guard buildPipelines() else { return nil }
        buildGrid()
    }

    // MARK: setup

    private func buildPipelines() -> Bool {
        guard let library = device.makeDefaultLibrary() else { return false }

        func pipeline(_ vertexFn: String, _ fragmentFn: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertexFn)
            d.fragmentFunction = library.makeFunction(name: fragmentFn)
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

        guard let mx = pipeline("mesh_vertex", "mesh_fragment", blend: true),
              let m = pipeline("mesh_vertex", "mesh_fragment", blend: false),
              let o = pipeline("outline_vertex", "outline_fragment", blend: false),
              let g = pipeline("grid_vertex", "grid_fragment", blend: true),
              let pt = pipeline("point_vertex", "point_fragment", blend: true),
              let pbr = pipeline("pbr_vertex", "pbr_fragment", blend: false),
              let attr = pipeline("attribute_vertex", "attribute_fragment", blend: false)
        else { return false }
        attributePipeline = attr
        pointPipeline = pt
        pbrPipeline = pbr
        meshPipeline = m; meshXrayPipeline = mx; outlinePipeline = o; gridPipeline = g

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .repeat
        sd.tAddressMode = .repeat
        linearSampler = device.makeSamplerState(descriptor: sd)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)

        // The grid is depth-tested against geometry but does not occlude it.
        let gd = MTLDepthStencilDescriptor()
        gd.depthCompareFunction = .less
        gd.isDepthWriteEnabled = false
        gridDepthState = device.makeDepthStencilState(descriptor: gd)

        let od = MTLDepthStencilDescriptor()
        od.depthCompareFunction = .always
        od.isDepthWriteEnabled = false
        overlayDepthState = device.makeDepthStencilState(descriptor: od)

        let cd = MTLDepthStencilDescriptor()
        cd.depthCompareFunction = .lessEqual
        cd.isDepthWriteEnabled = false
        coplanarDepthState = device.makeDepthStencilState(descriptor: cd)

        return true
    }

    /// Uploads per-frame overlay vertices and returns the buffer to draw from.
    ///
    /// Grows on demand and never shrinks: a gizmo that gains a few vertices
    /// should not cause an allocation every frame.
    private func overlayBuffer(_ verts: [GridVertex]) -> MTLBuffer? {
        guard !verts.isEmpty else { return nil }
        let needed = MemoryLayout<GridVertex>.stride * verts.count
        overlaySlot = (overlaySlot + 1) % overlayBuffers.count

        if overlayBuffers[overlaySlot] == nil || overlayCapacities[overlaySlot] < needed {
            let capacity = max(needed * 2, 64 * 1024)
            overlayBuffers[overlaySlot] = device.makeBuffer(length: capacity,
                                                            options: .storageModeShared)
            overlayCapacities[overlaySlot] = overlayBuffers[overlaySlot] == nil ? 0 : capacity
        }
        guard let buffer = overlayBuffers[overlaySlot] else { return nil }
        verts.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: needed)
        }
        return buffer
    }

    /// Blender's floor grid: 1 m lines, with the X and Y axes drawn in the
    /// standard red and green.
    private func buildGrid() {
        var verts: [GridVertex] = []
        let n = Int(gridExtent)
        let plain = SIMD4<Float>(0.33, 0.33, 0.33, 0.85)
        let axisX = SIMD4<Float>(0.898, 0.282, 0.416, 1.0)   // BTheme.axisX
        let axisY = SIMD4<Float>(0.482, 0.776, 0.161, 1.0)   // BTheme.axisY

        for i in -n...n {
            let f = Float(i)
            // Lines running along Y; the one at x == 0 is the Y axis.
            let cy = (i == 0) ? axisY : plain
            verts.append(GridVertex(position: SIMD3(f, -gridExtent, 0), color: cy))
            verts.append(GridVertex(position: SIMD3(f,  gridExtent, 0), color: cy))
            // Lines running along X; the one at y == 0 is the X axis.
            let cx = (i == 0) ? axisX : plain
            verts.append(GridVertex(position: SIMD3(-gridExtent, f, 0), color: cx))
            verts.append(GridVertex(position: SIMD3( gridExtent, f, 0), color: cx))
        }

        gridVertexCount = verts.count
        gridBuffer = device.makeBuffer(bytes: verts,
                                       length: MemoryLayout<GridVertex>.stride * verts.count,
                                       options: .storageModeShared)
    }

    /// Uploads an object's painted texture, reusing it until the image changes.
    private func texture(for obj: BKObject) -> MTLTexture? {
        guard let image = obj.texture else { return nil }
        if let cached = textureCache[obj.id], cached.version == image.version {
            return cached.texture
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: image.width, height: image.height,
            mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        image.pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
                        mipmapLevel: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: image.width * 4)
        }
        textureCache[obj.id] = (tex, image.version)
        return tex
    }

    /// One float4 per vertex: the colour attribute directly, or Blender's
    /// blue-to-red weight ramp. Rebuilt when the paint version changes.
    private func attributeBuffer(for obj: BKObject) -> MTLBuffer? {
        let key = obj.id
        let version = obj.textureVersion &* 31 &+ obj.meshVersion &+ (scene.mode == .weightPaint ? 1 : 0)
        if let cached = attributeCache[key], cached.version == version { return cached.buffer }

        obj.ensurePaintAttributes()
        let colours: [SIMD4<Float>]
        if scene.mode == .weightPaint {
            colours = (0..<obj.mesh.vertices.count).map { WeightRamp.colour(obj.vertexWeight(at: $0)) }
        } else {
            colours = (0..<obj.mesh.vertices.count).map { obj.vertexColour(at: $0) }
        }
        guard !colours.isEmpty,
              let buffer = device.makeBuffer(bytes: colours,
                                             length: MemoryLayout<SIMD4<Float>>.stride * colours.count,
                                             options: .storageModeShared)
        else { return nil }
        attributeCache[key] = (buffer, version)
        return buffer
    }

    /// One float4 per vertex for a sculpt mask: `surface` darkened by 0.75 of
    /// the mask, or nil when the object has no mask to draw.
    private func maskBuffer(for obj: BKObject, surface: SIMD4<Float>) -> MTLBuffer? {
        guard let mask = obj.drawnSculptMask else { return nil }
        let version = obj.sculptMaskVersion &* 31 &+ obj.meshVersion
        if let cached = maskCache[obj.id], cached.version == version { return cached.buffer }
        let colours = mask.map { m -> SIMD4<Float> in
            let shade = 1 - 0.75 * min(max(m, 0), 1)
            return SIMD4(surface.x * shade, surface.y * shade, surface.z * shade, 1)
        }
        guard !colours.isEmpty,
              let buffer = device.makeBuffer(bytes: colours,
                                             length: MemoryLayout<SIMD4<Float>>.stride * colours.count,
                                             options: .storageModeShared)
        else { return nil }
        maskCache[obj.id] = (buffer, version)
        return buffer
    }

    /// Edit mode's overlay — wire, seams, selection and dots — is drawn on
    /// the cage, the mesh the edit selection numbers, as Blender draws it on
    /// its edit mesh. On device, and with no Swift stack, that is the mesh.
    private func editBuffers(for obj: BKObject) -> MeshBuffers? {
        guard !obj.meshIsEvaluated, !obj.modifiers.isEmpty else { return buffers(for: obj) }
        if let cached = cageCache[obj.id], cached.version == obj.meshVersion { return cached }
        guard let entry = makeBuffers(for: obj, mesh: obj.editCage, realEdgeCount: 0, hiddenVertexCount: 0)
        else { return nil }
        cageCache[obj.id] = entry
        if cageCache.count > scene.objects.count * 2 {
            let live = Set(scene.objects.map(\.id))
            cageCache = cageCache.filter { live.contains($0.key) }
        }
        return entry
    }

    private func buffers(for obj: BKObject) -> MeshBuffers? {
        // The real-edge list arrives with the edit-mode mirror, which can
        // happen without the mesh itself changing, so its size is part of what
        // makes a cached entry still the right one.
        let realEdgeCount = (obj.editTopology?.realEdges.count ?? 0) * 2
        // Hiding vertices changes neither the mesh's version nor its edges.
        let hiddenVertexCount = obj.editTopology?.hiddenVertices.count ?? 0
        if let cached = meshCache[obj.id], cached.version == obj.meshVersion,
           cached.realEdgeCount == realEdgeCount, cached.hiddenVertexCount == hiddenVertexCount {
            return cached
        }
        guard let entry = makeBuffers(for: obj, mesh: obj.mesh, realEdgeCount: realEdgeCount,
                                      hiddenVertexCount: hiddenVertexCount)
        else { return nil }
        meshCache[obj.id] = entry

        // Objects deleted from the scene would otherwise keep their buffers
        // alive for the lifetime of the renderer.
        if meshCache.count > scene.objects.count * 2 {
            let live = Set(scene.objects.map(\.id))
            meshCache = meshCache.filter { live.contains($0.key) }
        }
        return entry
    }

    private func makeBuffers(for obj: BKObject, mesh: MeshData, realEdgeCount: Int,
                             hiddenVertexCount: Int) -> MeshBuffers? {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty || !mesh.edges.isEmpty,
              let vb = device.makeBuffer(bytes: mesh.vertices,
                                         length: MemoryLayout<MeshVertex>.stride * mesh.vertices.count,
                                         options: .storageModeShared)
        else { return nil }
        let ib = mesh.indices.isEmpty ? nil
            : device.makeBuffer(bytes: mesh.indices,
                                length: MemoryLayout<UInt32>.stride * mesh.indices.count,
                                options: .storageModeShared)
        if !mesh.indices.isEmpty && ib == nil { return nil }

        let eb = mesh.edges.isEmpty ? nil
            : device.makeBuffer(bytes: mesh.edges,
                                length: MemoryLayout<UInt32>.stride * mesh.edges.count,
                                options: .storageModeShared)

        var real: [UInt32] = []
        if let topology = obj.editTopology, !topology.realEdges.isEmpty {
            real.reserveCapacity(realEdgeCount)
            for e in topology.realEdges.sorted() where e * 2 + 1 < mesh.edges.count {
                real += [mesh.edges[e * 2], mesh.edges[e * 2 + 1]]
            }
        }
        let rb = real.isEmpty ? nil
            : device.makeBuffer(bytes: real,
                                length: MemoryLayout<UInt32>.stride * real.count,
                                options: .storageModeShared)

        // Seams arrive with the mesh (`SceneMirror.installUVs`), and a change
        // to them is a new mesh version, so the cache key already covers them.
        let seamBuffer = mesh.seamEdges.isEmpty ? nil
            : device.makeBuffer(bytes: mesh.seamEdges,
                                length: MemoryLayout<UInt32>.stride * mesh.seamEdges.count,
                                options: .storageModeShared)

        var shown: [UInt32] = []
        if let hidden = obj.editTopology?.hiddenVertices, !hidden.isEmpty {
            shown = mesh.vertices.indices.filter { !hidden.contains($0) }.map { UInt32($0) }
        }
        let sb = shown.isEmpty ? nil
            : device.makeBuffer(bytes: shown,
                                length: MemoryLayout<UInt32>.stride * shown.count,
                                options: .storageModeShared)

        return MeshBuffers(vertex: vb, index: ib, count: mesh.indices.count,
                           edges: eb, edgeCount: mesh.edges.count,
                           realEdges: rb, realEdgeCount: real.count,
                           seams: seamBuffer, seamCount: seamBuffer == nil ? 0 : mesh.seamEdges.count,
                           shownVertices: sb, shownVertexCount: shown.count,
                           hiddenVertexCount: hiddenVertexCount,
                           version: obj.meshVersion)
    }

    // MARK: draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        pointSize = view.bounds.size
        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let viewProjection = camera.viewProjection(aspect: aspect)

        // MeshBuilder winds faces counter-clockwise when seen from outside,
        // whereas Metal treats clockwise as front-facing by default. Without
        // this the cull modes invert: the solid pass keeps interior faces and
        // the outline pass covers the whole object.
        encoder.setFrontFacing(.counterClockwise)

        // ---- grid (part of Blender's overlays)
        if let gridBuffer, options.showOverlays {
            var u = Uniforms(viewProjection: viewProjection,
                             model: matrix_identity_float4x4,
                             normalMatrix: matrix_identity_float4x4,
                             baseColor: .one,
                             params: SIMD4(gridExtent, 0, 0, 0))
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setDepthStencilState(gridDepthState)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }
        drawObjectOverlays(encoder, viewProjection: viewProjection, drawableSize: size)

        if shading == .wireframe {
            // Blender's wireframe draws every edge unshaded, with the
            // selection picked out in orange. Reuses the outline pipeline with
            // zero extrusion, since it already emits a flat colour.
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setDepthStencilState(gridDepthState)
            encoder.setCullMode(.none)
            for obj in scene.objects where obj.visible {
                guard let b = buffers(for: obj), let edges = b.edges else { continue }
                let selected = scene.selection.contains(obj.id)
                let colour: SIMD4<Float> = selected
                    ? (obj.id == scene.activeID ? SIMD4(1.000, 0.627, 0.157, 1)
                                                : SIMD4(0.929, 0.341, 0.000, 1))
                    : SIMD4(0.55, 0.55, 0.55, 1)
                var u = Uniforms(viewProjection: viewProjection,
                                 model: obj.modelMatrix,
                                 normalMatrix: obj.modelMatrix.inverse.transpose,
                                 baseColor: colour,
                                 params: SIMD4(0, camera.distance, 0, 0))
                encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .line, indexCount: b.edgeCount,
                                              indexType: .uint32, indexBuffer: edges,
                                              indexBufferOffset: 0)
            }
            drawEditedPoints(encoder, viewProjection: viewProjection)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
            return
        }

        // ---- selection outlines (back faces of a slightly inflated hull)
        encoder.setRenderPipelineState(outlinePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.front)
        for obj in scene.objects where obj.visible
            && (scene.selection.contains(obj.id) || obj.id == scene.hoveredID) {
            // A wire object has no hull to inflate; `drawWires` colours its
            // lines instead, as Blender does.
            guard let b = buffers(for: obj), let index = b.index else { continue }
            let isActive = obj.id == scene.activeID
            let isSelected = scene.selection.contains(obj.id)
            // A hovered-but-unselected object gets a dimmer rim, so the Pencil
            // shows what it is about to hit without implying a selection.
            let colour: SIMD4<Float> = !isSelected
                ? SIMD4(1.000, 0.627, 0.157, 0.45)
                : (isActive ? SIMD4(1.000, 0.627, 0.157, 1)    // BTheme.active  #FFA028
                            : SIMD4(0.929, 0.341, 0.000, 1))   // BTheme.select  #ED5700
            var u = Uniforms(viewProjection: viewProjection,
                             model: obj.modelMatrix,
                             normalMatrix: obj.modelMatrix.inverse.transpose,
                             baseColor: colour,
                             params: SIMD4(0.0018, camera.distance, 0, 0))
            encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: b.count,
                                          indexType: .uint32, indexBuffer: index,
                                          indexBufferOffset: 0)
        }

        // ---- Material Preview: the real PBR pass
        if shading == .material && !options.xray {
            encoder.setRenderPipelineState(pbrPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.back)
            let eye = camera.eye
            for obj in scene.objects where obj.visible {
                guard let b = buffers(for: obj), let index = b.index else { continue }
                if texturePaint.drawMaterial(obj, vertices: b.vertex, encoder: encoder, viewProjection: viewProjection, eye: eye, cameraDistance: camera.distance, resume: pbrPipeline) { continue }
                let m = obj.material
                // An unconnected graph renders black in Blender; matching that
                // is what makes the node editor's link mean something.
                let connected = obj.shaderGraph.isConnected
                let albedo = texture(for: obj)
                var u = PBRUniforms(
                    viewProjection: viewProjection,
                    model: obj.modelMatrix,
                    normalMatrix: obj.modelMatrix.inverse.transpose,
                    baseColor: connected ? m.baseColor : SIMD4(0, 0, 0, 1),
                    emission: SIMD4(m.emission.x, m.emission.y, m.emission.z,
                                    connected ? m.emissionStrength : 0),
                    params: SIMD4(m.metallic, m.roughness, m.ior, camera.distance),
                    // w flags whether a painted texture is bound.
                    cameraPos: SIMD4(eye.x, eye.y, eye.z, albedo == nil ? 0 : 1))
                encoder.setFragmentTexture(albedo, index: 0)
                encoder.setFragmentSamplerState(linearSampler, index: 0)
                encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<PBRUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<PBRUniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: b.count,
                                              indexType: .uint32, indexBuffer: index,
                                              indexBufferOffset: 0)
            }
            drawWires(encoder, viewProjection: viewProjection)
            drawEditedPoints(encoder, viewProjection: viewProjection)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
            return
        }

        // ---- vertex attribute display (Vertex Paint / Weight Paint)
        //
        // Blender replaces the surface shading in these modes so you see the
        // attribute you are painting rather than the material. Drawn instead of
        // the solid pass, not on top of it.
        if scene.mode == .vertexPaint || scene.mode == .weightPaint {
            encoder.setRenderPipelineState(attributePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.back)
            for obj in scene.objects where obj.visible {
                guard let b = buffers(for: obj), let index = b.index,
                      let colours = attributeBuffer(for: obj)
                else { continue }
                var u = Uniforms(viewProjection: viewProjection,
                                 model: obj.modelMatrix,
                                 normalMatrix: obj.modelMatrix.inverse.transpose,
                                 baseColor: .one,
                                 params: SIMD4(0, camera.distance, 0, 0))
                encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setVertexBuffer(colours, offset: 0, index: 2)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: b.count,
                                              indexType: .uint32, indexBuffer: index,
                                              indexBufferOffset: 0)
            }
            drawWires(encoder, viewProjection: viewProjection)
            drawGizmoAndFinish(encoder: encoder, commands: commands, drawable: drawable,
                               viewProjection: viewProjection)
            return
        }

        // ---- shaded surfaces
        encoder.setRenderPipelineState(options.xray ? meshXrayPipeline : meshPipeline)
        // X-Ray draws every surface without writing depth, so back faces show
        // through the front ones — which is the point of it.
        encoder.setDepthStencilState(options.xray ? gridDepthState : depthState)
        encoder.setCullMode(options.xray ? .none : .back)
        for obj in scene.objects where obj.visible {
            guard let b = buffers(for: obj), let index = b.index else { continue }
            if texturePaint.drawSolid(obj, vertices: b.vertex, encoder: encoder, scene: scene, viewProjection: viewProjection, xray: options.xray, resume: options.xray ? meshXrayPipeline : meshPipeline) { continue }
            // Solid mode uses Blender's uniform surface grey regardless of the
            // object colour; Material Preview is where the colour shows.
            var surface: SIMD4<Float> = shading == .material
                ? obj.color
                : SIMD4(0.80, 0.80, 0.80, 1)
            if options.xray { surface.w = 0.4 }
            var u = Uniforms(viewProjection: viewProjection,
                             model: obj.modelMatrix,
                             normalMatrix: obj.modelMatrix.inverse.transpose,
                             baseColor: surface,
                             params: SIMD4(0, camera.distance, 0, 0))
            encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            // Sculpt Mode's mask, drawn as Blender's mask overlay draws it:
            // the surface darkened where it is masked (overlay opacity 0.75,
            // Blender's default), with the same studio light as vertex paint.
            let masked = scene.mode == .sculpt && !options.xray ? maskBuffer(for: obj, surface: surface) : nil
            if let masked {
                encoder.setRenderPipelineState(attributePipeline)
                encoder.setVertexBuffer(masked, offset: 0, index: 2)
            }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: b.count,
                                          indexType: .uint32, indexBuffer: index,
                                          indexBufferOffset: 0)
            if masked != nil {
                encoder.setRenderPipelineState(meshPipeline)
            }
        }
        drawWires(encoder, viewProjection: viewProjection)

        // ---- edit mode: Blender overlays the mesh's own elements on top of
        // the shaded surface, so the geometry stays readable while editing.
        // A curve's or a lattice's Edit Mode draws its control points instead
        // (`drawControlCage`): the mesh overlay here would put a vertex dot on
        // every point of the tessellated wire, which Blender cannot select.
        if scene.mode == .edit, let obj = scene.active, obj.visible, !obj.editsPoints,
           let b = editBuffers(for: obj), let edges = b.edges {
            // The cage: what the selection's indices name (`editBuffers`).
            let cage = obj.editCage
            let model = obj.modelMatrix
            let normalMatrix = model.inverse.transpose

            // Wireframe over the surface, so every edge is visible — Blender's
            // edges, not the diagonals triangulation left in the viewport's own
            // edge list. A cube edited in Blender has twelve lines on it, and
            // this used to draw eighteen.
            var wire = Uniforms(viewProjection: viewProjection,
                                model: model, normalMatrix: normalMatrix,
                                baseColor: SIMD4(0.05, 0.05, 0.05, 0.9),
                                params: SIMD4(0, camera.distance, 0, 0))
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setDepthStencilState(gridDepthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
            encoder.setVertexBytes(&wire, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&wire, length: MemoryLayout<Uniforms>.stride, index: 1)
            if let real = b.realEdges, b.realEdgeCount > 0 {
                encoder.drawIndexedPrimitives(type: .line, indexCount: b.realEdgeCount,
                                              indexType: .uint32, indexBuffer: real,
                                              indexBufferOffset: 0)
            } else {
                encoder.drawIndexedPrimitives(type: .line, indexCount: b.edgeCount,
                                              indexType: .uint32, indexBuffer: edges,
                                              indexBufferOffset: 0)
            }

            // Seams, in Blender's Edge Seam colour (#DB2512), over the wire
            // and under the selection: a selected seam shows as selected, as
            // in Blender. Mark Seam used to change nothing on screen at all.
            if let seams = b.seams, b.seamCount > 0 {
                var seam = wire
                seam.baseColor = SIMD4(0.859, 0.145, 0.071, 1)
                encoder.setDepthStencilState(coplanarDepthState)
                encoder.setVertexBytes(&seam, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&seam, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .line, indexCount: b.seamCount,
                                              indexType: .uint32, indexBuffer: seams,
                                              indexBufferOffset: 0)
                encoder.setDepthStencilState(gridDepthState)
                encoder.setVertexBytes(&wire, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&wire, length: MemoryLayout<Uniforms>.stride, index: 1)
            }

            // Selected edges. Nothing was drawn for these at all, so in Edge
            // mode a tap that worked looked exactly like a tap that did not —
            // the whole mode appeared dead. Orange over the black wire, with a
            // dot at each end: a one-pixel line is thin to aim a finger at, and
            // the dots say which edge of the two meeting at a corner is the
            // selected one.
            if !scene.editSelection.edges.isEmpty {
                var ends: [UInt32] = []
                ends.reserveCapacity(scene.editSelection.edges.count * 2)
                for e in scene.editSelection.edges.sorted() {
                    let base = e * 2
                    guard base + 1 < cage.edges.count else { continue }
                    ends += [cage.edges[base], cage.edges[base + 1]]
                }
                if !ends.isEmpty,
                   let ib = device.makeBuffer(bytes: ends,
                                              length: MemoryLayout<UInt32>.stride * ends.count,
                                              options: .storageModeShared) {
                    var lit = wire
                    lit.baseColor = SIMD4(1.0, 0.627, 0.157, 1)   // BTheme.active
                    encoder.setDepthStencilState(coplanarDepthState)
                    encoder.setVertexBytes(&lit, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&lit, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.drawIndexedPrimitives(type: .line, indexCount: ends.count,
                                                  indexType: .uint32, indexBuffer: ib,
                                                  indexBufferOffset: 0)
                    var dots = lit
                    dots.params.x = 6
                    encoder.setRenderPipelineState(pointPipeline)
                    encoder.setVertexBytes(&dots, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&dots, length: MemoryLayout<Uniforms>.stride, index: 1)
                    for v in Set(ends) where Int(v) < cage.vertices.count {
                        encoder.drawPrimitives(type: .point, vertexStart: Int(v), vertexCount: 1)
                    }
                    encoder.setRenderPipelineState(outlinePipeline)
                    encoder.setDepthStencilState(gridDepthState)
                }
            }

            // Selected faces, tinted on top of the surface. Blender fills them
            // so a face selection is visible without hunting for orange dots at
            // its corners.
            if !scene.editSelection.faces.isEmpty {
                var picked: [UInt32] = []
                picked.reserveCapacity(scene.editSelection.faces.count * 3)
                for f in scene.editSelection.faces {
                    let base = f * 3
                    guard base + 2 < cage.indices.count else { continue }
                    picked += [cage.indices[base], cage.indices[base + 1],
                               cage.indices[base + 2]]
                }
                if !picked.isEmpty,
                   let ib = device.makeBuffer(bytes: picked,
                                              length: MemoryLayout<UInt32>.stride * picked.count,
                                              options: .storageModeShared) {
                    var fill = Uniforms(viewProjection: viewProjection,
                                        model: model, normalMatrix: normalMatrix,
                                        baseColor: SIMD4(1.0, 0.63, 0.16, 0.45),
                                        params: SIMD4(0, camera.distance, 0, 0))
                    encoder.setRenderPipelineState(meshXrayPipeline)
                    encoder.setDepthStencilState(coplanarDepthState)
                    encoder.setCullMode(.back)
                    encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
                    encoder.setVertexBytes(&fill, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&fill, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: picked.count,
                                                  indexType: .uint32, indexBuffer: ib,
                                                  indexBufferOffset: 0)
                }
            }

            // Vertex dots. Blender shows them black when unselected and orange
            // when selected, so the two passes differ only in colour.
            if scene.selectMode == .vertex {
                var dots = Uniforms(viewProjection: viewProjection,
                                    model: model, normalMatrix: normalMatrix,
                                    baseColor: SIMD4(0.0, 0.0, 0.0, 1),
                                    params: SIMD4(5, camera.distance, 0, 0))
                encoder.setRenderPipelineState(pointPipeline)
                encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
                encoder.setVertexBytes(&dots, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&dots, length: MemoryLayout<Uniforms>.stride, index: 1)
                if b.hiddenVertexCount > 0 {
                    // Blender draws no dot for a hidden vertex.
                    if let shown = b.shownVertices, b.shownVertexCount > 0 {
                        encoder.drawIndexedPrimitives(type: .point, indexCount: b.shownVertexCount,
                                                      indexType: .uint32, indexBuffer: shown,
                                                      indexBufferOffset: 0)
                    }
                } else {
                    encoder.drawPrimitives(type: .point, vertexStart: 0,
                                           vertexCount: cage.vertices.count)
                }

                // Selected vertices, drawn one at a time so only they light up.
                if !scene.editSelection.vertices.isEmpty {
                    var lit = dots
                    lit.baseColor = SIMD4(1.0, 0.627, 0.157, 1)   // BTheme.active
                    lit.params.x = 7
                    encoder.setVertexBytes(&lit, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&lit, length: MemoryLayout<Uniforms>.stride, index: 1)
                    for v in scene.editSelection.vertices where v < cage.vertices.count {
                        encoder.drawPrimitives(type: .point, vertexStart: v, vertexCount: 1)
                    }
                }
            }
        }

        drawEditedPoints(encoder, viewProjection: viewProjection)

        // ---- 3D cursor: Blender draws a crosshair at it, and it is where new
        // objects spawn, so it has to be visible to be useful.
        if options.showOverlays {
            let c = scene.cursor
            let r = camera.distance * 0.03
            let red = SIMD4<Float>(0.85, 0.15, 0.15, 1)
            let white = SIMD4<Float>(0.95, 0.95, 0.95, 1)
            var verts: [GridVertex] = []
            for (axis, colour) in [(SIMD3<Float>(1, 0, 0), red),
                                   (SIMD3<Float>(0, 1, 0), white),
                                   (SIMD3<Float>(0, 0, 1), red)] {
                verts.append(GridVertex(position: c - axis * r, color: colour))
                verts.append(GridVertex(position: c + axis * r, color: colour))
            }
            var u = Uniforms(viewProjection: viewProjection,
                             model: matrix_identity_float4x4,
                             normalMatrix: matrix_identity_float4x4,
                             baseColor: .one,
                             params: SIMD4(camera.far, 0, 0, 0))
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setDepthStencilState(gridDepthState)
            encoder.setCullMode(.none)
            if let cursorBuffer = overlayBuffer(verts) {
                encoder.setVertexBuffer(cursorBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: verts.count)
            }
        }

        drawGizmoAndFinish(encoder: encoder, commands: commands, drawable: drawable,
                           viewProjection: viewProjection)
    }

    // MARK: curve and lattice Edit Mode

    /// The edited curve's or lattice's cage, in every shading: Wireframe and
    /// Material Preview returned before the Solid pass drew it, while a tap
    /// still picked those points and the Move tool still dragged them.
    private func drawEditedPoints(_ encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4) {
        if let (obj, cage) = scene.editedPoints, obj.visible {
            drawControlCage(encoder, cage: cage, model: obj.modelMatrix, viewProjection: viewProjection)
        }
    }

    /// The control points of the curve or lattice being edited, its handles
    /// and its grid (`ControlCageOverlay`), over everything: they are what a
    /// tap and the gizmo act on, and a point hidden behind the surface it
    /// bevels would be one nobody can reach.
    private func drawControlCage(_ encoder: MTLRenderCommandEncoder, cage: ControlCage,
                                 model: simd_float4x4, viewProjection: simd_float4x4) {
        guard cage.count > 0 else { return }
        let overlay = ControlCageOverlay(cage)
        let world = cage.positions.map { (model * SIMD4($0, 1)).xyz }
        var lines: [GridVertex] = []
        lines.reserveCapacity(overlay.lines.count * 2)
        for line in overlay.lines {
            lines.append(GridVertex(position: world[line.a], color: line.colour))
            lines.append(GridVertex(position: world[line.b], color: line.colour))
        }
        var u = Uniforms(viewProjection: viewProjection, model: matrix_identity_float4x4,
                         normalMatrix: matrix_identity_float4x4, baseColor: .one,
                         // The grid shader fades by distance from the world
                         // origin; a huge radius keeps these at full strength.
                         params: SIMD4(1e9, 0, 0, 0))
        encoder.setCullMode(.none)
        if let buffer = overlayBuffer(lines) {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
        }

        // The dots: one draw per colour, through an index buffer of the
        // visible points that wear it.
        let vertices = world.map { MeshVertex($0, SIMD3(0, 0, 1)) }
        guard let vertexBuffer = device.makeBuffer(bytes: vertices,
                                                   length: MemoryLayout<MeshVertex>.stride * vertices.count,
                                                   options: .storageModeShared) else { return }
        encoder.setRenderPipelineState(pointPipeline)
        encoder.setDepthStencilState(overlayDepthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        for group in overlay.dots where !group.points.isEmpty {
            guard let ib = device.makeBuffer(bytes: group.points,
                                             length: MemoryLayout<UInt32>.stride * group.points.count,
                                             options: .storageModeShared) else { continue }
            var dots = Uniforms(viewProjection: viewProjection, model: matrix_identity_float4x4,
                                normalMatrix: matrix_identity_float4x4, baseColor: group.colour,
                                params: SIMD4(group.colour == ControlCageOverlay.selected ? 9 : 7, 0, 0, 0))
            encoder.setVertexBytes(&dots, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&dots, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .point, indexCount: group.points.count, indexType: .uint32,
                                          indexBuffer: ib, indexBufferOffset: 0)
        }
    }

    /// The gizmo overlay and the present/commit tail, shared by the solid
    /// path and the vertex-attribute path so neither can forget one of them.
    private func drawGizmoAndFinish(encoder: MTLRenderCommandEncoder,
                                    commands: MTLCommandBuffer,
                                    drawable: CAMetalDrawable,
                                    viewProjection: simd_float4x4) {
        // ---- transform gizmo
        //
        // Drawn last and with depth testing off, so it stays reachable even
        // when it is buried inside the model it is transforming. Blender does
        // the same: a gizmo you cannot grab is not a gizmo.
        if options.showGizmos, let mode = gizmoMode,
           let gizmo = TransformGizmo.make(mode: mode, scene: scene, options: options,
                                           camera: camera, size: pointSize) {
            let verts = gizmo.triangles(eye: camera.eye, highlighted: gizmoHighlight)
            if let vertexBuffer = overlayBuffer(verts) {
                var u = Uniforms(viewProjection: viewProjection,
                                 model: matrix_identity_float4x4,
                                 normalMatrix: matrix_identity_float4x4,
                                 baseColor: .one,
                                 // The grid shader fades by distance from the
                                 // world origin; a huge radius pins the gizmo
                                 // at full opacity wherever the object sits.
                                 params: SIMD4(1e9, 0, 0, 0))
                encoder.setRenderPipelineState(gridPipeline)
                encoder.setDepthStencilState(overlayDepthState)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            }
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()

    }


    // MARK: offscreen render

    /// Renders the scene to an image at an arbitrary size.
    ///
    /// This is the viewport's own PBR pass at higher resolution, not a render
    /// engine: no ray tracing, no shadows, no global illumination. It is closer
    /// in spirit to Eevee's rasteriser than to Cycles, and much simpler than
    /// either — worth saying, because "Render" implies more than this does.
    func renderOffscreen(width: Int, height: Int) -> [UInt8]? {
        let colourDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colourDesc.usage = [.renderTarget, .shaderRead]
        colourDesc.storageMode = .shared

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colour = device.makeTexture(descriptor: colourDesc),
              let depth = device.makeTexture(descriptor: depthDesc),
              let commands = queue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Blender's default world grey, so the render is not on a viewport grid.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05,
                                                            blue: 0.05, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setFrontFacing(.counterClockwise)
        encoder.setRenderPipelineState(pbrPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)

        let aspect = Float(width) / Float(max(height, 1))
        let viewProjection = camera.viewProjection(aspect: aspect)
        let eye = camera.eye

        // `hide_render` is honoured here and nowhere else: an object hidden
        // from renders still draws in the viewport, which is exactly what
        // separates the Outliner's camera column from its eye.
        for obj in scene.objects where obj.visible && !obj.hideRender {
            // Loose edges do not render in Blender either.
            guard let b = buffers(for: obj), let index = b.index else { continue }
            let m = obj.material
            let connected = obj.shaderGraph.isConnected
            let albedo = texture(for: obj)
            var u = PBRUniforms(
                viewProjection: viewProjection,
                model: obj.modelMatrix,
                normalMatrix: obj.modelMatrix.inverse.transpose,
                baseColor: connected ? m.baseColor : SIMD4(0, 0, 0, 1),
                emission: SIMD4(m.emission.x, m.emission.y, m.emission.z,
                                connected ? m.emissionStrength : 0),
                params: SIMD4(m.metallic, m.roughness, m.ior, camera.distance),
                cameraPos: SIMD4(eye.x, eye.y, eye.z, albedo == nil ? 0 : 1))
            encoder.setFragmentTexture(albedo, index: 0)
            encoder.setFragmentSamplerState(linearSampler, index: 0)
            encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<PBRUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PBRUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: b.count,
                                          indexType: .uint32, indexBuffer: index,
                                          indexBufferOffset: 0)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        // Read back and swap BGRA to RGBA, which is what TextureImage holds.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            colour.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes.swapAt(i, i + 2)
        }
        return bytes
    }

    /// Objects with edges and no faces — a wire circle, an unfilled curve,
    /// an edge-only mesh — drawn as lines, the only way they can be seen.
    ///
    /// Blender's colours for a wire object in object mode: the theme's Wire
    /// (black) when unselected, Object Selected and Active Object orange when
    /// selected, the same two the selection outline uses. Edit mode draws the
    /// active one's edges again on top, as it does for any mesh.
    private func drawWires(_ encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4) {
        // Blender's wireframe overlay draws these, and only Wireframe shading
        // (which draws every edge before this is reached) shows them with the
        // overlays hidden. See ObjectOverlayPicking.object, which takes them
        // by the same rule.
        guard options.showOverlays else { return }
        var pipelineSet = false
        for obj in scene.objects where obj.visible && obj.mesh.isWire {
            guard let b = buffers(for: obj), b.index == nil, let edges = b.edges else { continue }
            if !pipelineSet {
                encoder.setRenderPipelineState(outlinePipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setCullMode(.none)
                pipelineSet = true
            }
            let selected = scene.selection.contains(obj.id)
            let colour: SIMD4<Float> = selected
                ? (obj.id == scene.activeID ? SIMD4(1.000, 0.627, 0.157, 1)
                                            : SIMD4(0.929, 0.341, 0.000, 1))
                // Hover: the active orange at 45% over the wire's black, mixed
                // here. outlinePipeline does not blend, so an alpha of 0.45
                // was dropped and a hovered wire drew as the active object.
                : (obj.id == scene.hoveredID ? SIMD4(0.45, 0.282, 0.071, 1)
                                             : SIMD4(0, 0, 0, 1))
            var u = Uniforms(viewProjection: viewProjection,
                             model: obj.modelMatrix,
                             normalMatrix: obj.modelMatrix.inverse.transpose,
                             baseColor: colour,
                             params: SIMD4(0, camera.distance, 0, 0))
            encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .line, indexCount: b.edgeCount,
                                          indexType: .uint32, indexBuffer: edges,
                                          indexBufferOffset: 0)
        }
    }

    // MARK: picking

    /// Ray-casts into the scene and returns the nearest object under the point.
    /// The ray is transformed into each object's local space so the test runs
    /// against the untransformed mesh.
    func hitTest(ndc: SIMD2<Float>, aspect: Float) -> BKObject? {
        if let overlay = overlayHitTest(ndc: ndc) { return overlay }
        let (origin, direction) = camera.ray(atNDC: ndc, aspect: aspect)
        var best: (obj: BKObject, t: Float)?

        for obj in scene.objects where obj.visible {
            let inv = obj.modelMatrix.inverse
            let lo = (inv * SIMD4(origin, 1)).xyz
            let ld = normalize((inv * SIMD4(direction, 0)).xyz)
            let mesh = obj.mesh
            var i = 0
            while i + 2 < mesh.indices.count {
                let a = mesh.vertices[Int(mesh.indices[i])].position
                let b = mesh.vertices[Int(mesh.indices[i + 1])].position
                let c = mesh.vertices[Int(mesh.indices[i + 2])].position
                if let t = rayTriangle(lo, ld, a, b, c), t > 0 {
                    if best == nil || t < best!.t { best = (obj, t) }
                }
                i += 3
            }
        }
        return best?.obj
    }

    /// Picks a mesh element on the active object, for edit mode.
    ///
    /// The choosing is `MeshPicker`'s, which measures in points rather than in
    /// clip space so the radius is a fingertip and the same size in both
    /// directions; this puts the tap into the object's own space for it.
    func hitTestElement(ndc: SIMD2<Float>, aspect: Float, mode: MeshSelectMode,
                        viewSize: SIMD2<Float>) -> MeshPicker.Hit {
        guard let obj = scene.active else { return MeshPicker.Hit() }
        let model = obj.modelMatrix
        let inv = model.inverse
        let (origin, direction) = camera.ray(atNDC: ndc, aspect: aspect)
        let localRay = (origin: (inv * SIMD4(origin, 1)).xyz,
                        direction: normalize((inv * SIMD4(direction, 0)).xyz))
        // On the cage, as Blender picks on its edit mesh: in the simulator the
        // Swift stack's output numbers its vertices differently — a Mirror
        // with Bisect renumbered 22 of the first 24, and a drag moved a hidden
        // base vertex instead of the one tapped (round 2's review).
        return MeshPicker.pick(mesh: obj.editCage, topology: obj.editTopology, mode: mode,
                               ndc: ndc, viewSize: viewSize,
                               viewProjection: camera.viewProjection(aspect: aspect) * model,
                               eye: (inv * SIMD4(camera.eye, 1)).xyz,
                               viewDirection: camera.isOrthographic ? localRay.direction : nil,
                               ray: localRay)
    }

    /// The nearest point where a ray meets one object's surface, in that
    /// object's local space, with the face normal there. Sculpting needs both.
    func surfaceHit(ndc: SIMD2<Float>, aspect: Float,
                    on obj: BKObject) -> (localPoint: SIMD3<Float>, normal: SIMD3<Float>)? {
        let (origin, direction) = camera.ray(atNDC: ndc, aspect: aspect)
        let model = obj.modelMatrix
        let inv = model.inverse
        let lo = (inv * SIMD4(origin, 1)).xyz
        let ld = normalize((inv * SIMD4(direction, 0)).xyz)

        let mesh = obj.mesh
        var best: (t: Float, normal: SIMD3<Float>)?
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])].position
            let b = mesh.vertices[Int(mesh.indices[i + 1])].position
            let c = mesh.vertices[Int(mesh.indices[i + 2])].position
            if let t = rayTriangle(lo, ld, a, b, c), t > 0 {
                if best == nil || t < best!.t {
                    best = (t, normalize(cross(b - a, c - a)))
                }
            }
            i += 3
        }
        guard let best else { return nil }
        // Return the normal in world space; the caller maps it back.
        let worldNormal = normalize((model.inverse.transpose * SIMD4(best.normal, 0)).xyz)
        return (lo + ld * best.t, worldNormal)
    }

    /// Möller–Trumbore, two-sided so back faces still register a hit.
    private func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>,
                             _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = cross(d, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-7 else { return nil }
        let invDet = 1 / det
        let t0 = o - a
        let u = dot(t0, p) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let q = cross(t0, e1)
        let v = dot(d, q) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        return dot(e2, q) * invDet
    }
}
