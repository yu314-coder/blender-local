import Foundation
import simd

// Writes the model folders the app would write, and prints the Python the app
// sends for each, for tests/image3d/blender/verify.py to run in Blender.
//   main <work directory>
let work = URL(fileURLWithPath: CommandLine.arguments[1])

func ellipse(width: Int, height: Int, rx: Float, ry: Float) -> ImageToModel.Mask {
    var values = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let dx = (Float(x) + 0.5 - Float(width) / 2) / rx
            let dy = (Float(y) + 0.5 - Float(height) / 2) / ry
            if dx * dx + dy * dy <= 1 { values[y * width + x] = 255 }
        }
    }
    return .init(width: width, height: height, values: values)
}

var out: [String] = []
for (label, mask, options, location) in [
    ("OVAL", ellipse(width: 256, height: 192, rx: 100, ry: 70), ImageToModel.Options(detail: 64), SIMD3<Float>(1, 2, 3)),
    ("WHOLE", ImageToModel.Mask.whole(width: 64, height: 128), ImageToModel.Options(detail: 32, thickness: 0.2), SIMD3<Float>(0, 0, 0)),
] {
    let folder = work.appendingPathComponent(label)
    let mesh = ImageToModel.build(mask: mask, options: options)!
    try! mesh.write(to: folder)
    let texture = folder.appendingPathComponent("texture.png").path
    out.append("### \(label)\n" + ImageToModel.python(folder: folder.path, texture: texture,
                                                     name: label == "OVAL" ? "Oval Photo" : "Whole",
                                                     location: location))
}
// Full 3D: a surface as TripoSGPipeline writes it — a ball with a bump on
// the model's front (+Z in TripoSG's frame) — and the two calls around the bake.
do {
    let surface = TripoSGPipeline.surface(resolution: 64) { points in
        stride(from: 0, to: points.count, by: 3).map { i in
            let p = SIMD3(points[i], points[i + 1], points[i + 2])
            return min(length(p) - 0.35, length(p - SIMD3(0, 0, 0.4)) - 0.12) * 100    // positive outside
        }
    }.mesh
    let folder = work.appendingPathComponent("FULL")
    try! TripoSGPipeline.write(surface, to: folder)
    out.append("### FULL_PREPARE\n" + TripoSGPipeline.preparePython(folder: folder.path, faces: 1500))
    out.append("### FULL_FINISH\n" + TripoSGPipeline.finishPython(folder: folder.path,
                                                                  texture: folder.appendingPathComponent("texture.png").path,
                                                                  name: "Ball", location: SIMD3(0, 0, 1)))
}
print(out.joined(separator: "\n#--\n"))
