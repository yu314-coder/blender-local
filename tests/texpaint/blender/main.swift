import Foundation
import simd

// What Texture Paint sends to Blender, and what it assumes about Blender,
// printed for a headless Blender to hold against itself: the Python calls,
// the brush settings and falloff it paints with, and a stroke the engine
// painted, as the bytes the viewport holds and the floats it hands to
// `pixels.foreach_set`.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func hex<T>(_ values: [T]) -> String {
    values.withUnsafeBytes { raw in raw.map { String(format: "%02x", $0) }.joined() }
}

// MARK: the calls

emit("ENTER_CUBE", TexturePaintBpy.enter(object: "Cube"))
emit("ENTER_BARE", TexturePaintBpy.enter(object: "Bare"))
emit("ENTER_CANVAS", TexturePaintBpy.enter(object: "Canvas", width: 64, height: 64))
emit("MADE", TexturePaintBpy.madeQuery)
// A plane with no material: Add Paint Slot names its image after the object.
emit("WRITE_CANVAS", TexturePaintBpy.write(images: ["Canvas Base Color"]))
emit("UNDO_NAMES", [TexturePaintBpy.undoName(for: ["Add Simple UVs", "Add Paint Slot"]) ?? "-",
                    TexturePaintBpy.undoName(for: ["Add Simple UVs"]) ?? "-",
                    TexturePaintBpy.undoName].joined(separator: "\n"))
emit("UNDO_NONE", TexturePaintBpy.undoName(for: []) ?? "none")

// MARK: the brushes

let defaults = TexturePaintSettings()
emit("UNIFIED", "\(defaults.size) \(defaults.colour.x) \(defaults.colour.y) \(defaults.colour.z)")
emit("OPTIONS", [defaults.options.occlude ? "1" : "0", defaults.options.backfaceCulling ? "1" : "0",
                 defaults.options.normalFalloff ? "1" : "0", String(defaults.options.normalAngle),
                 String(defaults.options.seamBleed)].joined(separator: " "))
emit("BRUSHES", TexturePaintTool.allCases.map { tool -> String in
    let b = defaults[tool]
    return [tool.blenderBrush, tool.blenderType, String(b.strength), String(b.spacing),
            b.falloff.blenderPreset, b.usePressureSize ? "1" : "0", b.usePressureStrength ? "1" : "0",
            b.blend.blenderBlend].joined(separator: "|")
}.joined(separator: "\n"))
emit("FALLOFF", TexturePaintTool.allCases.map { tool -> String in
    let falloff = defaults[tool].falloff
    return tool.blenderBrush + "|" + (0...64).map {
        String(format: "%.6f", falloff.strength(distance: Float($0) / 64, radius: 1))
    }.joined(separator: " ")
}.joined(separator: "\n"))

// MARK: a stroke

do {
    let image = TextureImage(width: 64, height: 64, name: "Canvas Base Color", fill: SIMD4(0.8, 0.8, 0.8, 1))
    let p: [SIMD3<Float>] = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
    let t: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
    let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
    let view = simd_float4x4.lookAt(eye: SIMD3(0, 0, 5), center: .zero, up: SIMD3(0, 1, 0))
    let camera = TexturePaintCamera(
        viewProjection: simd_float4x4.orthographic(halfWidth: 1, halfHeight: 1, near: -100, far: 100) * view,
        size: SIMD2(200, 200), eye: SIMD3(0, 0, 5), forward: SIMD3(0, 0, -1), isOrthographic: true)
    var settings = TexturePaintSettings()
    settings.size = 50
    settings.colour = SIMD3(0.1, 0.5, 0.9)
    let stroke = TexturePaintStroke(
        target: TexturePaintTarget(positions: p, indices: indices, cornerUVs: indices.map { t[Int($0)] },
                                   images: [image]),
        camera: camera, settings: settings, tool: .draw)!
    stroke.begin(at: SIMD2(40, 120), pressure: 1)
    stroke.move(to: SIMD2(170, 70), pressure: 1)
    emit("STROKE_BYTES", hex(image.pixels))
    emit("STROKE_FLOATS", hex(TexturePaintPixels.floats(from: image)))
}

// MARK: the brush measured in pixels

do {
    // A 200-texel image on a plane that fills a 100-point view on a 2× screen:
    // one texel per pixel.
    let image = TextureImage(width: 200, height: 200, name: "Pixels", fill: SIMD4(0.8, 0.8, 0.8, 1))
    let p: [SIMD3<Float>] = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
    let t: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
    let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
    let view = simd_float4x4.lookAt(eye: SIMD3(0, 0, 5), center: .zero, up: SIMD3(0, 1, 0))
    let camera = TexturePaintCamera(
        viewProjection: simd_float4x4.orthographic(halfWidth: 1, halfHeight: 1, near: -100, far: 100) * view,
        size: SIMD2(100, 100), eye: SIMD3(0, 0, 5), forward: SIMD3(0, 0, -1), isOrthographic: true,
        pixelsPerPoint: 2)
    var settings = TexturePaintSettings()
    settings.colour = SIMD3(1, 0, 0)
    var brush = settings[.draw]
    brush.falloff = .preset(.constant)
    settings[.draw] = brush
    let stroke = TexturePaintStroke(
        target: TexturePaintTarget(positions: p, indices: indices, cornerUVs: indices.map { t[Int($0)] },
                                   images: [image]),
        camera: camera, settings: settings, tool: .draw)!
    stroke.begin(at: SIMD2(50, 50), pressure: 1)
    var painted = 0
    for i in stride(from: 0, to: image.pixels.count, by: 4) where image.pixels[i + 1] < 100 { painted += 1 }
    emit("PIXELS", "\(settings.size) \(2 * (Double(painted) / Double.pi).squareRoot()) 2")
}

// MARK: a float stroke

do {
    let width = 64, height = 64
    // Blender's layout, bottom row first: a ramp, blue past 1 toward the top,
    // and one texel at 3.0 in a corner the stroke does not reach.
    var before = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            before[i] = 0.05 + Float(x) / 64 * 0.9
            before[i + 1] = 0.3
            before[i + 2] = Float(y) / 32
            before[i + 3] = 1
        }
    }
    before[(60 * width + 4) * 4] = 3
    before.withUnsafeBufferPointer {
        TexturePaintImages.receive(name: "Canvas Float", width: width, height: height, channels: 4,
                                   isFloat: true, floats: $0)
    }
    let image = TexturePaintImages.image(named: "Canvas Float")!
    let p: [SIMD3<Float>] = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
    let t: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
    let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
    let view = simd_float4x4.lookAt(eye: SIMD3(0, 0, 5), center: .zero, up: SIMD3(0, 1, 0))
    let camera = TexturePaintCamera(
        viewProjection: simd_float4x4.orthographic(halfWidth: 1, halfHeight: 1, near: -100, far: 100) * view,
        size: SIMD2(200, 200), eye: SIMD3(0, 0, 5), forward: SIMD3(0, 0, -1), isOrthographic: true)
    var settings = TexturePaintSettings()
    settings.size = 50
    settings.colour = SIMD3(0.1, 0.5, 0.9)
    let stroke = TexturePaintStroke(
        target: TexturePaintTarget(positions: p, indices: indices, cornerUVs: indices.map { t[Int($0)] },
                                   images: [image]),
        camera: camera, settings: settings, tool: .draw)!
    stroke.begin(at: SIMD2(40, 120), pressure: 1)
    stroke.move(to: SIMD2(170, 70), pressure: 1)
    emit("FLOAT_BEFORE", hex(before))
    emit("FLOAT_AFTER", hex(TexturePaintPixels.floats(from: image)))
    emit("FLOAT_COLOUR", "\(settings.colour.x) \(settings.colour.y) \(settings.colour.z)")
}

// MARK: the tools

emit("TEXTURE_TOOLS", TexturePaintTool.allCases.map(\.blenderType).joined(separator: " "))
emit("TOOLBAR", ActiveTool.allCases.filter { $0.requiredMode == .texturePaint }.map { tool in
    [tool.label, tool.isImplemented ? "1" : "0", tool.texturePaintTool?.blenderType ?? "-"].joined(separator: "|")
}.joined(separator: "\n"))
emit("AVERAGE_MODE", ActiveTool.paintAverage.requiredMode?.bpyMode ?? "none")

print(out.joined(separator: "\n#--\n"))
