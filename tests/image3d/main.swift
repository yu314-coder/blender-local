import Foundation
import simd

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

/// A mask with a filled circle, or ellipse, in it.
func ellipse(width: Int, height: Int, rx: Float, ry: Float) -> ImageToModel.Mask {
    var values = [UInt8](repeating: 0, count: width * height)
    let cx = Float(width) / 2, cy = Float(height) / 2
    for y in 0..<height {
        for x in 0..<width {
            let dx = (Float(x) + 0.5 - cx) / rx, dy = (Float(y) + 0.5 - cy) / ry
            if dx * dx + dy * dy <= 1 { values[y * width + x] = 255 }
        }
    }
    return ImageToModel.Mask(width: width, height: height, values: values)
}

/// Every edge, as an unordered pair, with how many faces use it.
func edgeUse(_ mesh: ImageToModel.Mesh) -> [UInt64: Int] {
    var use: [UInt64: Int] = [:]
    var start = 0
    for size in mesh.faceSizes.map(Int.init) {
        for k in 0..<size {
            let a = UInt64(mesh.faceIndices[start + k])
            let b = UInt64(mesh.faceIndices[start + (k + 1) % size])
            use[min(a, b) << 32 | max(a, b), default: 0] += 1
        }
        start += size
    }
    return use
}

func faceNormal(_ mesh: ImageToModel.Mesh, face: Int) -> SIMD3<Float> {
    var start = 0
    for f in 0..<face { start += Int(mesh.faceSizes[f]) }
    let p = (0..<Int(mesh.faceSizes[face])).map { mesh.positions[Int(mesh.faceIndices[start + $0])] }
    return normalize(cross(p[1] - p[0], p[2] - p[0]))
}

print("== nothing to build ==")
check("an empty mask builds nothing",
      ImageToModel.build(mask: .init(width: 8, height: 8, values: [UInt8](repeating: 0, count: 64))) == nil)
check("faint coverage below half is background",
      ImageToModel.build(mask: .init(width: 8, height: 8, values: [UInt8](repeating: 100, count: 64))) == nil)

print("\n== a round subject ==")
do {
    let mask = ellipse(width: 200, height: 200, rx: 60, ry: 60)
    let options = ImageToModel.Options(detail: 48, thickness: 0.5, size: 2)
    guard let mesh = ImageToModel.build(mask: mask, options: options) else {
        check("a circle builds", false); exit(1)
    }
    check("a circle builds", true)
    let xs = mesh.positions.map(\.x), ys = mesh.positions.map(\.y), zs = mesh.positions.map(\.z)
    let width = (xs.max() ?? 0) - (xs.min() ?? 0)
    let tall = (zs.max() ?? 0) - (zs.min() ?? 0)
    check("its longer side is the size asked for, within a cell", abs(width - 2) < 2.0 / 48 * 2.5, "\(width)")
    check("a circle is as tall as it is wide", abs(width - tall) < 0.1, "\(width) x \(tall)")
    check("it is centred", abs((xs.max()! + xs.min()!) / 2) < 0.05 && abs((zs.max()! + zs.min()!) / 2) < 0.05)
    // Half the thickness each side: 0.5 × the 2 m diameter / 2.
    check("the front reaches half the depth toward -Y", abs((ys.min() ?? 0) + 0.5) < 0.03, "\(ys.min() ?? 0)")
    check("the back mirrors it toward +Y", abs((ys.max() ?? 0) - 0.5) < 0.03, "\(ys.max() ?? 0)")
    check("it has front and back faces", mesh.frontFaces > 0 && mesh.faceCount > mesh.frontFaces,
          "\(mesh.frontFaces) of \(mesh.faceCount)")
    check("faces are triangles and quads", mesh.faceSizes.allSatisfy { $0 == 3 || $0 == 4 })
    check("one UV per face corner", mesh.uvs.count == mesh.faceIndices.count)
    check("every index is a vertex", mesh.faceIndices.allSatisfy { Int($0) < mesh.positions.count && $0 >= 0 })
    check("UVs stay inside the picture", mesh.uvs.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
    // The picture's centre is the model's centre, in UV terms too.
    let centre = mesh.positions.indices.min { length(mesh.positions[$0] * SIMD3(1, 0, 1)) < length(mesh.positions[$1] * SIMD3(1, 0, 1)) }!
    var cornerOfCentre = 0
    for (k, index) in mesh.faceIndices.enumerated() where Int(index) == centre { cornerOfCentre = k; break }
    let uv = mesh.uvs[cornerOfCentre]
    check("the model's centre shows the picture's centre", abs(uv.x - 0.5) < 0.03 && abs(uv.y - 0.5) < 0.03, "\(uv)")

    let use = edgeUse(mesh)
    check("no edge is used by more than two faces", use.values.allSatisfy { $0 <= 2 },
          "\(use.values.filter { $0 > 2 }.count) over-used")
    let open = use.values.filter { $0 == 1 }.count
    check("the model is closed but for a handful of edges", Double(open) / Double(use.count) < 0.02,
          "\(open) of \(use.count) open")

    // The front's faces look toward -Y, the back's toward +Y, on average.
    let front = (0..<mesh.frontFaces).map { faceNormal(mesh, face: $0).y }.reduce(0, +) / Float(mesh.frontFaces)
    let back = (mesh.frontFaces..<mesh.faceCount).map { faceNormal(mesh, face: $0).y }.reduce(0, +)
        / Float(mesh.faceCount - mesh.frontFaces)
    check("the front faces the viewer, along -Y", front < -0.5, "\(front)")
    check("the back faces away, along +Y", back > 0.5, "\(back)")
}

print("\n== options ==")
do {
    let mask = ellipse(width: 160, height: 80, rx: 70, ry: 30)
    let low = ImageToModel.build(mask: mask, options: .init(detail: 24))!
    let high = ImageToModel.build(mask: mask, options: .init(detail: 96))!
    check("more detail means more faces", high.faceCount > low.faceCount * 8, "\(low.faceCount) -> \(high.faceCount)")
    let flat = ImageToModel.build(mask: mask, options: .init(thickness: 0))!
    check("thickness 0 is a flat card on one side", flat.positions.allSatisfy { $0.y == 0 } && flat.faceCount == flat.frontFaces)
    let wide = ImageToModel.build(mask: mask, options: .init(detail: 48, size: 3))!
    let xs = wide.positions.map(\.x)
    check("size sets the longer side", abs((xs.max()! - xs.min()!) - 3) < 0.2, "\(xs.max()! - xs.min()!)")
    let zs = wide.positions.map(\.z)
    check("a wide subject stays wide", (zs.max()! - zs.min()!) < 1.5, "\(zs.max()! - zs.min()!)")
    check("detail is clamped", ImageToModel.build(mask: mask, options: .init(detail: 100_000))!.faceCount
          == ImageToModel.build(mask: mask, options: .init(detail: 256))!.faceCount)
}

print("\n== the whole picture ==")
do {
    let mesh = ImageToModel.build(mask: .whole(width: 64, height: 32), options: .init(detail: 32))!
    let uvs = mesh.uvs
    check("the whole picture spans the texture",
          uvs.map(\.x).min()! < 0.05 && uvs.map(\.x).max()! > 0.95 && uvs.map(\.y).min()! < 0.05 && uvs.map(\.y).max()! > 0.95)
    check("coverage of the whole picture is 1", ImageToModel.Mask.whole(width: 4, height: 4).coverage == 1)
}

print("\n== two subjects ==")
do {
    var values = [UInt8](repeating: 0, count: 100 * 50)
    for y in 10..<40 { for x in 5..<35 { values[y * 100 + x] = 255 }; for x in 65..<95 { values[y * 100 + x] = 255 } }
    let mesh = ImageToModel.build(mask: .init(width: 100, height: 50, values: values), options: .init(detail: 45))!
    let xs = mesh.positions.map(\.x)
    let gap = xs.filter { abs($0) < 0.25 }.count
    check("both are built, with nothing between them", xs.min()! < -0.8 && xs.max()! > 0.8 && gap == 0, "\(gap) in the gap")
}

print("\n== a relief from depth ==")
do {
    // A 100×100 subject whose left half is near and right half far.
    let mask = ImageToModel.Mask(width: 100, height: 100, values: [UInt8](repeating: 255, count: 10_000))
    var nearness = [Float](repeating: 0, count: 50 * 50)
    for y in 0..<50 { for x in 0..<50 { nearness[y * 50 + x] = x < 25 ? 1 : 0 } }
    let depth = ImageToModel.Depth(width: 50, height: 50, values: nearness)
    let options = ImageToModel.Options(detail: 40, thickness: 0.5, size: 2)
    let relief = ImageToModel.build(mask: mask, depth: depth, options: options)!
    let front = relief.positions.filter { $0.y < 0 }
    let nearSide = front.filter { $0.x < -0.3 }.map { -$0.y }, farSide = front.filter { $0.x > 0.3 }.map { -$0.y }
    let near = nearSide.reduce(0, +) / Float(max(nearSide.count, 1)), far = farSide.reduce(0, +) / Float(max(farSide.count, 1))
    check("the near half stands further out than the far half", near > far * 3, "\(near) vs \(far)")
    let back = relief.positions.map(\.y).max() ?? 0, forward = -(relief.positions.map(\.y).min() ?? 0)
    check("the back is a shallow plate", back > 0 && back < forward * 0.3, "\(back) vs \(forward)")
    let flat = ImageToModel.build(mask: mask, depth: ImageToModel.Depth(width: 2, height: 2, values: [0.5, 0.5, 0.5, 0.5]),
                                  options: options)!
    check("a uniform depth still gives a closed relief with a front",
          flat.frontFaces > 0 && flat.faceCount > flat.frontFaces && (flat.positions.map(\.y).min() ?? 0) < 0)
    let use = edgeUse(relief)
    check("the relief is closed", use.values.filter { $0 == 1 }.count * 50 < use.count && use.values.allSatisfy { $0 <= 2 })
    check("the relief keeps the picture's UVs", relief.uvs.count == relief.faceIndices.count)
}

print("\n== files for Blender ==")
do {
    let mesh = ImageToModel.build(mask: ellipse(width: 50, height: 50, rx: 20, ry: 20), options: .init(detail: 20))!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("image3d-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        try mesh.write(to: folder)
        let positions = try Data(contentsOf: folder.appendingPathComponent("positions.bin"))
        let indices = try Data(contentsOf: folder.appendingPathComponent("indices.bin"))
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as! [String: Int]
        check("positions are three float32s a vertex", positions.count == mesh.positions.count * 12)
        check("indices are an int32 a corner", indices.count == mesh.faceIndices.count * 4)
        check("meta.json has the counts", meta["vertices"] == mesh.positions.count && meta["faces"] == mesh.faceCount
              && meta["loops"] == mesh.faceIndices.count && meta["front_faces"] == mesh.frontFaces, "\(meta)")
        let first = positions.withUnsafeBytes { $0.load(as: Float.self) }
        check("little-endian floats read back", first == mesh.positions[0].x)
    } catch {
        check("the files are written", false, "\(error)")
    }
}

print("\n== names and Python ==")
check("a file's stem names the object", ImageToModel.objectName(forFile: "Cat photo.HEIC") == "Cat photo")
check("no file name is Picture", ImageToModel.objectName(forFile: nil) == "Picture" && ImageToModel.objectName(forFile: ".png") == "Picture")
check("a long name is cut to Blender's 63 bytes", ImageToModel.objectName(forFile: String(repeating: "猫", count: 40) + ".png").utf8.count <= 63)
let python = ImageToModel.python(folder: "/tmp/a \"b\"", texture: "/tmp/t.png", name: "It's", location: SIMD3(1, 2, 3))
check("the Python quotes what it is given",
      python.contains("_bk_image3d.build(\"/tmp/a \\\"b\\\"\", \"/tmp/t.png\", \"It's\", (1.0, 2.0, 3.0))"), python)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
