import Foundation
import ImageIO
import simd

// Image to 3D Model's full 3D mode with TripoSG end to end, with desktop
// Blender standing in for the app's module between the Swift steps:
//   endtoend shape <weights folder> <cut-out RGBA png> <folder> [latents.bin]
//   (Blender: _blenderkit_image3d.prepare_full(folder))
//   endtoend bake <folder>
//   (Blender: _blenderkit_image3d.finish_full(folder, folder/texture.png, name))
// `latents.bin` skips DINOv2 and the flow, for work on the later steps.
let args = CommandLine.arguments
func save(_ values: [Float], _ url: URL) throws { try values.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url) }
func load(_ url: URL) throws -> [Float] { try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
var clock = Date()
func lap(_ what: String) { print(String(format: "  %@ %.2f s", what, Date().timeIntervalSince(clock))); fflush(stdout); clock = Date() }

switch args[1] {
case "shape":
    let model = try TripoSGModel(folder: URL(fileURLWithPath: args[2]))
    let folder = URL(fileURLWithPath: args[4])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("read the picture") }
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes {
        let context = CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let mask = ImageToModel.Mask(width: w, height: h, values: (0..<(w * h)).map { rgba[$0 * 4 + 3] })
    guard let prepared = TripoSGPipeline.prepare(image: image, mask: mask) else { fatalError("prepare") }
    lap("prepare")
    let latents: [Float]
    if args.count > 5 {
        latents = try load(URL(fileURLWithPath: args[5]))
    } else {
        let embeds = try model.imageEmbeddings(pixels: prepared.pixels)
        lap("DINOv2")
        let flow = try model.flow(embeds: embeds)
        latents = flow.sample(noise: TripoSGModel.noise(seed: 42), steps: 20) { step in
            if step % 5 == 0 { lap("flow step \(step)") }
        }
    }
    let geometry = try model.geometry(latents: latents)
    let (mesh, queries) = TripoSGPipeline.surface(resolution: 256, logits: geometry.query)
    lap("surface: \(queries) queries, \(mesh.positions.count) vertices, \(mesh.triangleCount) triangles")
    try TripoSGPipeline.write(mesh, to: folder)
    try save(latents, folder.appendingPathComponent("latents.bin"))
    try save(prepared.photo, folder.appendingPathComponent("photo.bin"))
    try save(prepared.alpha, folder.appendingPathComponent("alpha.bin"))
    try save(prepared.pixels, folder.appendingPathComponent("pixels.bin"))
case "bake":
    let folder = URL(fileURLWithPath: args[2])
    let prepared = TripoSGPipeline.Prepared(pixels: try load(folder.appendingPathComponent("pixels.bin")),
                                            photo: try load(folder.appendingPathComponent("photo.bin")),
                                            alpha: try load(folder.appendingPathComponent("alpha.bin")))
    let unwrapped = try TripoSGPipeline.Unwrapped(folder: folder)
    lap("read \(unwrapped.triangleCount) unwrapped triangles")
    let pose = TripoSGPipeline.fitPose(vertices: unwrapped.corners, alpha: prepared.alpha)
    lap(String(format: "pose: azimuth %.0f, elevation %.0f, overlap %.3f", pose.azimuth, pose.elevation, pose.overlap))
    let symmetry = TripoSGPipeline.mirrorSymmetry(vertices: unwrapped.corners)
    lap(String(format: "mirror symmetry %.3f", symmetry))
    let texture = TripoSGPipeline.bake(unwrapped, prepared: prepared, pose: pose, mirror: symmetry > 0.8, size: 1024)
    lap(String(format: "bake, %.0f%% of texels from the photo", texture.photoFraction * 100))
    try texture.writePNG(to: folder.appendingPathComponent("texture.png"))
default:
    fatalError("shape or bake")
}
