import Foundation
import Metal
import simd

// The viewport's line shader, compiled from the app's own Shaders.metal and
// drawn on this Mac's GPU: what reaches the screen for the normals Blender
// really sends. The mirror suites give every vertex the normal (0,0,1), so a
// NaN made from Blender's (0,0,0) — a wire or loose vertex at the object's
// origin, measured in 5.2.1 — could not show in any of them.
//
// Usage: run [path to Shaders.metal]

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "Sources/BlenderLocalUI/Viewport/Shaders.metal"
guard let device = MTLCreateSystemDefaultDevice() else {
    print("  SKIP  no Metal device")
    exit(0)
}
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("  FAIL  cannot read \(path)")
    exit(1)
}

/// `struct Uniforms` in Shaders.metal, as ViewportRenderer.swift fills it.
struct Uniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var normalMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var params: SIMD4<Float>
}

let side = 64
/// Draws one line with `outline_vertex`, as drawWires, Wireframe shading and
/// the edit-mode wire do, and counts the pixels it lit.
func litPixels(_ library: MTLLibrary, from a: SIMD3<Float>, normal na: SIMD3<Float>,
               to b: SIMD3<Float>, normal nb: SIMD3<Float>, extrusion: Float) -> Int {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "outline_vertex")
    d.fragmentFunction = library.makeFunction(name: "outline_fragment")
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return -1 }

    let texture = device.makeTexture(descriptor: {
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side,
                                                         height: side, mipmapped: false)
        t.usage = .renderTarget
        t.storageMode = .private
        return t
    }())!
    // MeshVertex: position, normal and uv, each padded to 16 bytes.
    let vertices: [Float] = [a.x, a.y, a.z, 0, na.x, na.y, na.z, 0, 0, 0, 0, 0,
                             b.x, b.y, b.z, 0, nb.x, nb.y, nb.z, 0, 0, 0, 0, 0]
    let vb = device.makeBuffer(bytes: vertices, length: vertices.count * 4)!
    let ib = device.makeBuffer(bytes: [UInt32(0), 1], length: 8)!
    let readback = device.makeBuffer(length: side * side * 4, options: .storageModeShared)!

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    let queue = device.makeCommandQueue()!
    let commands = queue.makeCommandBuffer()!
    let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    // The object's origin half way into the depth range, so the vertex at the
    // origin is inside the view rather than on its near plane.
    var model = matrix_identity_float4x4
    model.columns.3 = SIMD4(0, 0, 0.5, 1)
    var u = Uniforms(viewProjection: matrix_identity_float4x4, model: model,
                     normalMatrix: model.inverse.transpose, baseColor: SIMD4(1, 1, 1, 1),
                     params: SIMD4(extrusion, 10, 0, 0))
    encoder.setVertexBuffer(vb, offset: 0, index: 0)
    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.drawIndexedPrimitives(type: .line, indexCount: 2, indexType: .uint32,
                                  indexBuffer: ib, indexBufferOffset: 0)
    encoder.endEncoding()
    let blit = commands.makeBlitCommandEncoder()!
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: side, height: side, depth: 1),
              to: readback, destinationOffset: 0, destinationBytesPerRow: side * 4,
              destinationBytesPerImage: side * side * 4)
    blit.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    let bytes = readback.contents().bindMemory(to: UInt32.self, capacity: side * side)
    return (0..<side * side).filter { bytes[$0] != 0 }.count
}

let origin = SIMD3<Float>(0, 0, 0)
let far = SIMD3<Float>(0.8, 0.6, 0)
let up = SIMD3<Float>(0, 0, 1)
let none = SIMD3<Float>(0, 0, 0)

for fast in [true, false] {
    let options = MTLCompileOptions()
    options.mathMode = fast ? .fast : .safe
    let library: MTLLibrary
    do { library = try device.makeLibrary(source: source, options: options) } catch {
        check("Shaders.metal compiles", false, "\(error)")
        continue
    }
    print("\n  \(fast ? "fast" : "safe") math, on \(device.name)")
    let reference = litPixels(library, from: origin, normal: up, to: far, normal: up, extrusion: 0)
    check("a line between two vertices with normals is drawn", reference > 10, "\(reference) px")
    let fromOrigin = litPixels(library, from: origin, normal: none, to: far, normal: up, extrusion: 0)
    check("so is one from a vertex Blender gives the normal (0,0,0), as a wire at the origin",
          fromOrigin == reference, "\(fromOrigin) px against \(reference)")
    let both = litPixels(library, from: origin, normal: none, to: far, normal: none, extrusion: 0)
    check("and one with that normal at both ends, as loose edges have", both == reference,
          "\(both) px against \(reference)")
    let outlined = litPixels(library, from: origin, normal: none, to: far, normal: up, extrusion: 0.02)
    check("the outline's extrusion leaves such a vertex where it is rather than losing the line",
          outlined > 10, "\(outlined) px")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
