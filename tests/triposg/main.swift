import Foundation
import CoreGraphics
import Metal
import MetalPerformanceShadersGraph
import simd

// Image to 3D Model's full-3D pieces that need no weights. The network itself
// is checked against PyTorch by run-triposg-parity.sh, which needs them.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
let work = FileManager.default.temporaryDirectory.appendingPathComponent("blenderlocal-triposg-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
func floatBytes(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

print("== safetensors ==")
do {
    let matrix: [Float] = [1, 2, 3, 4, 5, 6]                     // 2 × 3
    let halfValues: [UInt16] = [0x3C00, 0xC000]                    // 1, -2
    let file = work.appendingPathComponent("small.safetensors")
    try Safetensors.write(to: file, entries: [("m", .float32, [2, 3]), ("h", .float16, [2])],
                          metadata: ["note": "test"]) { name in
        name == "m" ? floatBytes(matrix) : halfValues.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    let raw = try Data(contentsOf: file)
    var length = 0
    for k in 0..<8 { length |= Int(raw[k]) << (8 * k) }
    check("the header is padded to a multiple of 8", length % 8 == 0, "\(length)")
    let fromFile = try Safetensors(contentsOf: file), fromData = try Safetensors(data: raw)
    check("tensors, shapes and dtypes come back", fromFile.tensors["m"]?.shape == [2, 3] && fromFile.tensors["h"]?.dtype == .float16
          && fromData.tensors.count == 2)
    check("metadata comes back", fromFile.metadata == ["note": "test"])
    check("bytes read from the file and from memory agree with what was written",
          try fromFile.bytes("m") == floatBytes(matrix) && fromData.bytes("m") == floatBytes(matrix))
    check("an unknown tensor is refused", (try? fromFile.bytes("nope")) == nil)
    check("a file that is not safetensors is refused, not guessed",
          (try? Safetensors(data: Data("definitely not a safetensors file".utf8))) == nil)
    var truncated = raw; truncated.removeLast(3)
    check("a truncated file is refused", (try? Safetensors(data: truncated)) == nil)

    // Converting, as the download does: large weights to float16, norms and
    // biases kept, the transformer's Linear weights to int8.
    let rows = 256, columns = 256
    var large = (0..<(rows * columns)).map { Float(($0 * 7919) % 2001 - 1000) / 1000 }
    large[0] = 70000; large[1] = -1e9; large[2] = 0.5; large[3] = -1.25
    let source = work.appendingPathComponent("f32.safetensors"), converted = work.appendingPathComponent("vae/f16.safetensors")
    try Safetensors.write(to: source, entries: [("layer.weight", .float32, [rows, columns]), ("norm.weight", .float32, [5]),
                                                ("h", .float16, [2])]) { name in
        switch name {
        case "layer.weight": return floatBytes(large)
        case "norm.weight": return floatBytes([0.5, -1.25, 70000, 1e-7, 3.14159])
        default: return halfValues.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
    try TripoSGWeights.convert(source, to: converted, sourceSHA256: "abc123")
    let half = try Safetensors(contentsOf: converted)
    check("large weights become float16; norms stay float32; float16 is kept",
          half.tensors["layer.weight"]?.dtype == .float16 && half.tensors["norm.weight"]?.dtype == .float32
          && half.tensors["h"]?.dtype == .float16)
    check("the source's hash is recorded", half.metadata["converted_from_sha256"] == "abc123")
    check("no partial file is left", !FileManager.default.fileExists(atPath: converted.path + ".partial"))
    let weights = TripoSGWeights.File(path: "vae/f16.safetensors", byteCount: 1, sha256: "abc123")
    check("a converted file is recognised by its source's hash",
          TripoSGWeights.isConverted(weights, in: work)
          && !TripoSGWeights.isConverted(TripoSGWeights.File(path: "vae/f16.safetensors", byteCount: 1, sha256: "other"), in: work))

    // GraphWeights reads both files to the same values.
    let device = MTLCreateSystemDefaultDevice()!
    let graphWeights = GraphWeights(graph: MPSGraph(), device: device, sources: [half])
    let values = try graphWeights.floats("layer.weight")
    check("float16 values are exact where float16 can be, clamped where not",
          values[0] == 65504 && values[1] == -65504 && values[2] == 0.5 && values[3] == -1.25
          && zip(values.dropFirst(4), large.dropFirst(4)).allSatisfy { abs($0 - $1) < 1e-3 }, "\(values.prefix(5))")
    check("norms read exactly", try graphWeights.floats("norm.weight") == [0.5, -1.25, 70000, 1e-7, 3.14159])
    check("float32 values read as they are", try GraphWeights(graph: MPSGraph(), device: device, sources: [fromFile]).floats("m") == matrix)

    // Int8 in blocks: each block's largest magnitude is 127 steps of its scale.
    let blocks = TripoSGWeights.blockQuantized(floatBytes(Array(large.dropFirst(4)) + [0, 0, 0, 0]))
    let q = [Int8](blocks.values.map { Int8(bitPattern: $0) })
    let scales = blocks.scales.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    check("a scale per 64 weights", scales.count == rows * columns / 64 && q.count == rows * columns)
    var worst: Float = 0
    for (i, w) in (Array(large.dropFirst(4)) + [0, 0, 0, 0]).enumerated() {
        worst = max(worst, abs(Float(q[i]) * scales[i / 64] - w) / scales[i / 64])
    }
    check("int8 values are within half a step of the weights", worst <= 0.5 + 1e-3, "\(worst)")

    // A Linear layer from each kind of file: x · Wᵀ + b.
    let inputs = 128
    let linearWeights = (0..<(512 * inputs)).map { Float(($0 * 104729) % 1999 - 999) / 2000 }
    let bias = (0..<512).map { Float($0) / 100 }
    let x = (0..<inputs).map { Float(($0 * 31) % 17 - 8) / 8 }
    var expected = bias
    for r in 0..<512 { for c in 0..<inputs { expected[r] += linearWeights[r * inputs + c] * x[c] } }
    let linear = work.appendingPathComponent("linear.safetensors")
    try Safetensors.write(to: linear, entries: [("l.weight", .float32, [512, inputs]), ("l.bias", .float32, [512])]) { name in
        name == "l.weight" ? floatBytes(linearWeights) : floatBytes(bias)
    }
    let halfLinear = work.appendingPathComponent("linear16.safetensors")
    let int8Linear = work.appendingPathComponent("linear8.safetensors")
    try TripoSGWeights.convert(linear, to: halfLinear, sourceSHA256: "x")
    try TripoSGWeights.convert(linear, to: int8Linear, sourceSHA256: "x", quantize: true)
    check("with quantizing, a Linear weight is int8 with its scales",
          try Safetensors(contentsOf: int8Linear).tensors["l.weight"]?.dtype == .int8
          && Safetensors(contentsOf: int8Linear).tensors["l.weight_scale"]?.shape == [512, 2])
    // The graph computes in float16, whose steps near these outputs (up to
    // about 30) are 0.004; int8 adds up to half a step per weight. A wrong
    // transpose or scale is out by whole units.
    for (label, url, tolerance) in [("float32", linear, Float(0.01)), ("float16", halfLinear, 0.01), ("int8", int8Linear, 0.06)] {
        let graph = MPSGraph()
        let w = GraphWeights(graph: graph, device: device, sources: [try Safetensors(contentsOf: url)])
        let xt = graph.placeholder(shape: [1, inputs as NSNumber], dataType: .float16, name: nil)
        let y = graph.cast(try w.linear(xt, "l"), to: .float32, name: nil)
        let queue = device.makeCommandQueue()!
        let out = w.run(queue, feeds: [xt: GraphWeights.tensorData(device, x, shape: [1, inputs], half: true)], targets: [y])
        let result = GraphWeights.read(out[y]!, count: 512)
        let error = zip(result, expected).map { abs($0 - $1) }.max() ?? 1
        check("a Linear layer from \(label) weights", error < tolerance, "max error \(error)")
    }
} catch {
    check("safetensors round trip", false, "\(error)")
}

print("\n== DINOv2 position embeddings ==")
do {
    // One channel, 2×2 → 3×3 at scale 1.55 — values from torch's
    // F.interpolate(mode='bicubic', align_corners=False, scale_factor=1.55).
    let table: [Float] = [9, 1, 2, 3, 4]      // class token, then 2×2
    let out = TripoSGModel.bicubicPositions(table, dim: 1, from: 2, to: 3, scale: 1.55)
    let expected: [Float] = [9, 0.72989, 1.2836534, 1.886562, 1.8374163, 2.3911808, 2.9940886, 3.0432334, 3.596998, 4.1999054]
    check("bicubic matches torch on a small case", zip(out, expected).allSatisfy { abs($0 - $1) < 1e-4 }, "\(out)")
}

print("\n== the flow's inputs ==")
do {
    check("sigmas run from 1 to 0 in equal steps", TripoSGModel.sigmas(steps: 4) == [1, 0.75, 0.5, 0.25, 0])
    let t0 = TripoSGModel.Flow.sinusoid(0), t = TripoSGModel.Flow.sinusoid(500)
    check("the timestep embedding is sines then cosines", t0[0] == 0 && t0[1023] == 0 && t0[1024] == 1 && t0[2047] == 1
          && abs(t[0] - sin(500)) < 1e-4 && abs(t[1024] - cos(500)) < 1e-4)
    let a = TripoSGModel.noise(seed: 7), b = TripoSGModel.noise(seed: 7), c = TripoSGModel.noise(seed: 8)
    let mean = a.reduce(0, +) / Float(a.count)
    let variance = a.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(a.count)
    check("noise is the same for a seed and different for another", a == b && a != c)
    check("noise is standard normal", abs(mean) < 0.01 && abs(variance - 1) < 0.02, "\(mean) \(variance)")
}

print("\n== marching cubes ==")
do {
    let n = 48
    var field = [Float](repeating: 0, count: n * n * n)
    let origin = SIMD3<Float>(repeating: -1), spacing: Float = 2 / Float(n - 1), radius: Float = 0.6
    for x in 0..<n { for y in 0..<n { for z in 0..<n {
        let p = origin + SIMD3(Float(x), Float(y), Float(z)) * spacing
        field[(x * n + y) * n + z] = radius - length(p)        // positive inside
    } } }
    let mesh = MarchingCubes.extract(field: field, resolution: n, level: 0, origin: origin, spacing: spacing)
    check("a sphere gives a surface", mesh.triangleCount > 1000, "\(mesh.triangleCount)")
    let radii = mesh.positions.map { length($0) }
    check("its vertices lie on the sphere", radii.allSatisfy { abs($0 - radius) < spacing * 0.2 },
          "\(radii.min() ?? 0)...\(radii.max() ?? 0)")
    let volume = MarchingCubes.signedVolume(mesh)
    let exact = 4 / 3 * Float.pi * radius * radius * radius
    check("normals point outward, and the volume is the sphere's", volume > 0 && abs(volume - exact) / exact < 0.02,
          "\(volume) vs \(exact)")
    var edges: [UInt64: Int] = [:]
    for t in stride(from: 0, to: mesh.triangles.count, by: 3) {
        for (a, b) in [(0, 1), (1, 2), (2, 0)] {
            let u = UInt64(mesh.triangles[t + a]), v = UInt64(mesh.triangles[t + b])
            edges[min(u, v) << 32 | max(u, v), default: 0] += 1
        }
    }
    check("it is closed, with vertices shared", edges.values.allSatisfy { $0 == 2 },
          "\(edges.values.filter { $0 != 2 }.count) open edges")
    let empty = MarchingCubes.extract(field: .init(repeating: -1, count: n * n * n), resolution: n, level: 0,
                                      origin: origin, spacing: spacing)
    check("nothing inside gives nothing", empty.triangleCount == 0)
}

print("\n== the surface, coarse to fine ==")
do {
    // The decoder's convention: positive outside. A ball, and a thin plate
    // that a coarse grid alone would get wrong.
    func logits(_ points: [Float]) -> [Float] {
        stride(from: 0, to: points.count, by: 3).map { i in
            let p = SIMD3(points[i], points[i + 1], points[i + 2])
            let ball = length(p) - 0.5
            let plate = max(abs(p.y + 0.7) - 0.02, max(abs(p.x), abs(p.z)) - 0.3)
            return min(ball, plate) * 10
        }
    }
    let (band, queries) = TripoSGPipeline.surface(resolution: 128, logits: logits)
    let n = 129, bound = TripoSGModel.bound, spacing = 2 * bound / 128
    var grid = [Float](); grid.reserveCapacity(n * n * n * 3)
    for i in 0..<n { for j in 0..<n { for k in 0..<n {
        grid += [-bound + Float(i) * spacing, -bound + Float(j) * spacing, -bound + Float(k) * spacing]
    } } }
    let dense = MarchingCubes.extract(field: logits(grid).map { -$0 }, resolution: n, level: 0,
                                      origin: SIMD3(repeating: -bound), spacing: spacing)
    check("the band finds the same surface as the dense grid",
          band.positions.count == dense.positions.count && band.triangleCount == dense.triangleCount,
          "\(band.positions.count)/\(band.triangleCount) vs \(dense.positions.count)/\(dense.triangleCount)")
    check("with far fewer queries", queries < n * n * n / 3, "\(queries) of \(n * n * n)")
    check("the thin plate is found", band.positions.contains { $0.y < -0.6 })
    check("normals point outward", MarchingCubes.signedVolume(band) > 0)
    let empty = TripoSGPipeline.surface(resolution: 128) { points in [Float](repeating: 1, count: points.count / 3) }
    check("nothing inside gives nothing", empty.mesh.triangleCount == 0)
}

print("\n== the picture TripoSG sees ==")
do {
    // 300 × 200, red everywhere, with a 100 × 50 subject off centre.
    let w = 300, h = 200
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    for p in 0..<(w * h) { pixels[p * 4] = 255; pixels[p * 4 + 3] = 255 }
    let image = pixels.withUnsafeMutableBytes { buffer -> CGImage in
        CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    var coverage = [UInt8](repeating: 0, count: w * h)
    for y in 20..<70 { for x in 30..<130 { coverage[y * w + x] = 255 } }
    let prepared = TripoSGPipeline.prepare(image: image, mask: ImageToModel.Mask(width: w, height: h, values: coverage))!
    // The square is 100 + 2 × 10 = 120 wide: the subject is 5/6 of it.
    let m = TripoSGPipeline.Prepared.photoSize
    var lo = SIMD2<Int>(m, m), hi = SIMD2<Int>(-1, -1)
    for y in 0..<m { for x in 0..<m where prepared.alpha[y * m + x] > 0.5 {
        lo = simd_min(lo, SIMD2(x, y)); hi = simd_max(hi, SIMD2(x, y))
    } }
    let width = Float(hi.x - lo.x + 1), height = Float(hi.y - lo.y + 1)
    check("the subject fills the square but for 10% padding each side", abs(width - Float(m) * 100 / 120) < 3, "\(width)")
    check("its shape is kept, centred", abs(width / height - 2) < 0.05
          && abs(Float(lo.x + hi.x) / 2 - Float(m - 1) / 2) < 2 && abs(Float(lo.y + hi.y) / 2 - Float(m - 1) / 2) < 2, "\(lo) \(hi)")
    let s = TripoSGModel.imageSize
    func pixel(_ c: Int, _ x: Int, _ y: Int) -> Float { prepared.pixels[c * s * s + y * s + x] }
    // ImageNet normalisation: red (1, 0, 0) and white (1, 1, 1).
    check("DINOv2 sees the subject's colour, normalised", abs(pixel(0, 112, 112) - (1 - 0.485) / 0.229) < 0.05
          && abs(pixel(1, 112, 112) - (0 - 0.456) / 0.224) < 0.05, "\(pixel(0, 112, 112)) \(pixel(1, 112, 112))")
    check("and white around it", abs(pixel(1, 112, 2) - (1 - 0.456) / 0.224) < 0.05, "\(pixel(1, 112, 2))")
    check("an empty cut-out gives nothing",
          TripoSGPipeline.prepare(image: image, mask: ImageToModel.Mask(width: w, height: h, values: .init(repeating: 0, count: w * h))) == nil)
}

print("\n== the photo's viewpoint ==")
do {
    // An asymmetric shape: a long body, a head up at one end, a tail fin.
    var points: [SIMD3<Float>] = []
    func box(_ centre: SIMD3<Float>, _ half: SIMD3<Float>) {
        for _ in 0..<4000 {
            var p = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1))
            let axis = Int.random(in: 0..<3); p[axis] = p[axis] < 0 ? -1 : 1
            points.append(centre + p * half)
        }
    }
    box(SIMD3(0, 0, 0), SIMD3(0.2, 0.2, 0.6))
    box(SIMD3(0, 0.35, 0.5), SIMD3(0.15, 0.25, 0.15))
    box(SIMD3(0, 0.25, -0.6), SIMD3(0.02, 0.25, 0.1))
    let truth = TripoSGPipeline.Pose(azimuth: 60, elevation: 20, scale: 180, offset: SIMD2(250, 260), overlap: 1)
    let m = TripoSGPipeline.Prepared.photoSize
    var alpha = [Float](repeating: 0, count: m * m)
    for p in points {
        let q = truth.project(p)
        for dy in -3...3 { for dx in -3...3 {
            let x = Int(q.x) + dx, y = Int(q.y) + dy
            if x >= 0, y >= 0, x < m, y < m { alpha[y * m + x] = 1 }
        } }
    }
    let pose = TripoSGPipeline.fitPose(vertices: points, alpha: alpha)
    check("the azimuth and elevation are found", abs(pose.azimuth - 60) <= 10 && abs(pose.elevation - 20) <= 10,
          "\(pose.azimuth) \(pose.elevation)")
    check("with the scale and the silhouettes overlapping", abs(pose.scale - 180) < 20 && pose.overlap > 0.8,
          "\(pose.scale) \(pose.overlap)")
    let front = TripoSGPipeline.Pose(azimuth: 0, elevation: 0, scale: 100, offset: SIMD2(256, 256), overlap: 1)
    let q = front.project(SIMD3(0.5, 0.5, 0.5))
    check("from the front, +X is right, +Y up, +Z nearer", q.x == 306 && q.y == 206 && q.depth < front.project(.zero).depth)

    var mirrored = points
    mirrored += points.map { SIMD3(-$0.x, $0.y, $0.z) }
    let sideways = points.map { $0 + SIMD3<Float>(0.45, 0, 0) }
    check("a mirror-symmetric shape is found symmetric", TripoSGPipeline.mirrorSymmetry(vertices: mirrored) > 0.9)
    check("a lopsided one is not", TripoSGPipeline.mirrorSymmetry(vertices: sideways) < 0.3,
          "\(TripoSGPipeline.mirrorSymmetry(vertices: sideways))")
}

print("\n== baking a texture ==")
do {
    // Seen from +X (azimuth 90): a square facing the camera at x = 0.2, and
    // its mirror image facing away at x = -0.2, each with half the UV square.
    func quad(x: Float, facing: Float, uOffset: Float) -> ([SIMD3<Float>], [SIMD2<Float>]) {
        let a = SIMD3<Float>(x, -0.3, 0.3), b = SIMD3<Float>(x, -0.3, -0.3), c = SIMD3<Float>(x, 0.3, -0.3), d = SIMD3<Float>(x, 0.3, 0.3)
        let ua = SIMD2<Float>(uOffset, 0), ub = SIMD2<Float>(uOffset + 0.5, 0), uc = SIMD2<Float>(uOffset + 0.5, 1), ud = SIMD2<Float>(uOffset, 1)
        // (b - a) × (c - a) = (0, 0, -0.6) × (0, 0.6, -0.6) = (0.36, 0, 0): +X.
        return facing > 0 ? ([a, b, c, a, c, d], [ua, ub, uc, ua, uc, ud]) : ([a, c, b, a, d, c], [ua, uc, ub, ua, ud, uc])
    }
    let near = quad(x: 0.2, facing: 1, uOffset: 0), far = quad(x: -0.2, facing: -1, uOffset: 0.5)
    let unwrapped = TripoSGPipeline.Unwrapped(corners: near.0 + far.0, uvs: near.1 + far.1)
    let map = TripoSGPipeline.rasterise(unwrapped, size: 64)
    check("the layout covers its UV square", map.covered.filter { $0 }.count > 64 * 64 * 95 / 100,
          "\(map.covered.filter { $0 }.count)")
    check("texel positions interpolate the triangles", abs(map.position[32 * 64 + 16].x - 0.2) < 1e-5 && abs(map.position[32 * 64 + 16].y) < 0.03,
          "\(map.position[32 * 64 + 16])")

    // The photo: left half blue, right half red, the square cut out.
    let m = TripoSGPipeline.Prepared.photoSize
    let prepared = TripoSGPipeline.Prepared(
        pixels: [],
        photo: (0..<(m * m * 3)).map { i in
            let x = (i / 3) % m, channel = i % 3
            return x < m / 2 ? (channel == 2 ? 1 : 0) : (channel == 0 ? 1 : 0)
        },
        alpha: (0..<(m * m)).map { p in
            let x = p % m, y = p / m
            return (x > 106 && x < 406 && y > 106 && y < 406) ? 1 : 0
        })
    let pose = TripoSGPipeline.Pose(azimuth: 90, elevation: 0, scale: 500, offset: SIMD2(256, 256), overlap: 1)
    func texel(_ texture: TripoSGPipeline.Texture, _ x: Int, _ y: Int) -> SIMD3<Int> {
        let i = (y * 64 + x) * 4
        return SIMD3(Int(texture.rgba[i]), Int(texture.rgba[i + 1]), Int(texture.rgba[i + 2]))
    }
    // From +X, image right is -Z: the near square's u = 0 edge (z = 0.3) is
    // on the photo's blue left.
    let plain = TripoSGPipeline.bake(unwrapped, prepared: prepared, pose: pose, mirror: false, size: 64)
    check("the side facing the camera takes the photo, left and right",
          texel(plain, 4, 32).z > 200 && texel(plain, 4, 32).x < 50 && texel(plain, 28, 32).x > 200 && texel(plain, 28, 32).z < 50,
          "\(texel(plain, 4, 32)) \(texel(plain, 28, 32))")
    check("the side it cannot see takes the cut-out's average colour",
          abs(texel(plain, 36, 32).x - texel(plain, 36, 32).z) < 40 && texel(plain, 36, 32).x > 80, "\(texel(plain, 36, 32))")
    check("about half the texels come from the photo", plain.photoFraction > 0.3 && plain.photoFraction < 0.6, "\(plain.photoFraction)")
    let mirrored = TripoSGPipeline.bake(unwrapped, prepared: prepared, pose: pose, mirror: true, size: 64)
    // The far square's u = 0.5 edge is at z = 0.3 too: its mirror is blue.
    check("with mirroring, the hidden side takes its mirror image's colour",
          texel(mirrored, 36, 32).z > 200 && texel(mirrored, 36, 32).x < 50 && texel(mirrored, 60, 32).x > 200,
          "\(texel(mirrored, 36, 32)) \(texel(mirrored, 60, 32))")
    let png = work.appendingPathComponent("texture.png")
    try? mirrored.writePNG(to: png)
    check("the texture writes as a PNG", (try? Data(contentsOf: png))?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
}

print("\n== distance inside a cut-out ==")
do {
    var inside = [Bool](repeating: false, count: 11 * 11)
    for y in 1..<10 { for x in 1..<10 { inside[y * 11 + x] = true } }
    let d = TripoSGPipeline.chamfer(inside: inside, width: 11, height: 11)
    check("zero outside, one at the edge, most at the centre",
          d[0] == 0 && d[1 * 11 + 1] == 1 && d[5 * 11 + 5] == 5, "\(d[0]) \(d[12]) \(d[60])")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
