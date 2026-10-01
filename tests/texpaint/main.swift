import Foundation
import simd

// Texture Paint's engine, on the Mac: Blender's brush arithmetic, projection
// painting through a camera, seam bleed, pixels between Blender's floats and
// the viewport's bytes, and the simulator's stand-in for Blender's operators.
// The Python half is run by a real Blender in scripts/run-texpaint-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func section(_ title: String) { print("\n== \(title) ==") }

// MARK: - fixtures

/// Looking straight down -Z at the origin, orthographic: world x and y from -1
/// to 1 fill a 200-point square, so a world unit is 100 points.
func topCamera(points: Float = 200, pixelsPerPoint: Float = 1) -> TexturePaintCamera {
    let view = simd_float4x4.lookAt(eye: SIMD3(0, 0, 5), center: .zero, up: SIMD3(0, 1, 0))
    let projection = simd_float4x4.orthographic(halfWidth: 1, halfHeight: 1, near: -100, far: 100)
    return TexturePaintCamera(viewProjection: projection * view, size: SIMD2(points, points),
                              eye: SIMD3(0, 0, 5), forward: SIMD3(0, 0, -1), isOrthographic: true,
                              pixelsPerPoint: pixelsPerPoint)
}

/// A float image as the mirror hands one over: Blender's floats, bottom row
/// first, every texel (value, value, value, 1). Each gets a name of its own.
nonisolated(unsafe) var floatImages = 0
func floatImage(_ size: Int = 100, _ value: Float = 0.6) -> TextureImage {
    var values = [Float](repeating: value, count: size * size * 4)
    for i in stride(from: 3, to: values.count, by: 4) { values[i] = 1 }
    floatImages += 1
    let name = "Float \(floatImages)"
    values.withUnsafeBufferPointer {
        TexturePaintImages.receive(name: name, width: size, height: size, channels: 4, isFloat: true, floats: $0)
    }
    return TexturePaintImages.image(named: name)!
}

/// A float texel by Blender's coordinates.
func floatTexel(_ image: TextureImage, _ x: Int, _ y: Int) -> SIMD4<Float> {
    let i = ((image.height - 1 - y) * image.width + x) * 4
    let f = image.floats!
    return SIMD4(f[i], f[i + 1], f[i + 2], f[i + 3])
}

func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tolerance: Float = 2e-6) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
        && abs(a.z - b.z) <= tolerance && abs(a.w - b.w) <= tolerance
}

/// FNV-1a, for telling pixel buffers apart without keeping copies of them.
func fingerprint(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    bytes.withUnsafeBufferPointer { p in
        for b in p { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    }
    return h
}

/// The same view in perspective, from `distance` away.
func perspectiveCamera(distance: Float) -> TexturePaintCamera {
    let eye = SIMD3<Float>(0, 0, distance)
    let view = simd_float4x4.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
    let projection = simd_float4x4.perspective(fovY: 2 * atan(18.0 / 50.0), aspect: 1, near: 0.05, far: 1000)
    return TexturePaintCamera(viewProjection: projection * view, size: SIMD2(200, 200),
                              eye: eye, forward: SIMD3(0, 0, -1), isOrthographic: false)
}

struct Quad {
    var positions: [SIMD3<Float>]
    var indices: [UInt32]
    var uvs: [SIMD2<Float>]
}

/// A rectangle at depth `z` facing the camera (or away from it), with its UVs
/// spanning `uv0...uv1`.
func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, z: Float = 0,
          uv0: SIMD2<Float> = SIMD2(0, 0), uv1: SIMD2<Float> = SIMD2(1, 1),
          facing: Bool = true) -> Quad {
    let p = [SIMD3(x0, y0, z), SIMD3(x1, y0, z), SIMD3(x1, y1, z), SIMD3(x0, y1, z)]
    let t = [uv0, SIMD2(uv1.x, uv0.y), uv1, SIMD2(uv0.x, uv1.y)]
    let idx: [UInt32] = facing ? [0, 1, 2, 0, 2, 3] : [0, 2, 1, 0, 3, 2]
    return Quad(positions: p, indices: idx, uvs: idx.map { t[Int($0)] })
}

func grey(_ size: Int = 100) -> TextureImage {
    TextureImage(width: size, height: size, name: "T", fill: SIMD4(0.8, 0.8, 0.8, 1))
}

/// A texel by Blender's coordinates: x from the left, y from the bottom.
func texel(_ image: TextureImage, _ x: Int, _ y: Int) -> Texel {
    let i = ((image.height - 1 - y) * image.width + x) * 4
    return Texel(image.pixels[i], image.pixels[i + 1], image.pixels[i + 2], image.pixels[i + 3])
}

func settings(size: Float = 40, colour: SIMD3<Float> = SIMD3(1, 0, 0), tool: TexturePaintTool = .draw,
              falloff: TexturePaintFalloff? = nil, strength: Float? = nil,
              pressureSize: Bool? = nil, options: TexturePaintOptions? = nil) -> TexturePaintSettings {
    var s = TexturePaintSettings()
    s.size = size
    s.colour = colour
    var brush = s[tool]
    if let falloff { brush.falloff = falloff }
    if let strength { brush.strength = strength }
    if let pressureSize { brush.usePressureSize = pressureSize }
    s[tool] = brush
    if let options { s.options = options }
    return s
}

func stroke(_ q: Quad, _ image: TextureImage, camera: TexturePaintCamera = topCamera(),
            _ s: TexturePaintSettings, tool: TexturePaintTool = .draw,
            symmetry: MeshSymmetry = MeshSymmetry(), seams: Bool = true) -> TexturePaintStroke {
    let target = TexturePaintTarget(positions: q.positions, indices: q.indices, cornerUVs: q.uvs,
                                    images: [image], symmetry: symmetry,
                                    seams: seams ? TexturePaintSeams(indices: q.indices, cornerUVs: q.uvs,
                                                                     triangleSlots: []) : nil)
    return TexturePaintStroke(target: target, camera: camera, settings: s, tool: tool)!
}

let red = Texel(255, 0, 0, 255)
let untouched = Texel(204, 204, 204, 255)

func count(_ image: TextureImage, where test: (Texel) -> Bool) -> Int {
    var n = 0
    for y in 0..<image.height { for x in 0..<image.width where test(texel(image, x, y)) { n += 1 } }
    return n
}

// MARK: - Blender's arithmetic

section("Blender's byte blending, to the byte")
do {
    let base = Texel(204, 204, 204, 255)
    check("mix: half-strength red over grey is Blender's (230, 102, 102)",
          BlenderColor.mix(base, Texel(255, 0, 0, 128)) == Texel(230, 102, 102, 255),
          "\(BlenderColor.mix(base, Texel(255, 0, 0, 128)))")
    check("mix at full alpha is the brush colour", BlenderColor.mix(base, Texel(10, 20, 30, 255)) == Texel(10, 20, 30, 255))
    check("mix at zero alpha changes nothing", BlenderColor.mix(base, Texel(10, 20, 30, 0)) == base)
    check("add clamps at white", BlenderColor.add(Texel(200, 10, 0, 255), Texel(100, 100, 100, 255)) == Texel(255, 110, 100, 255))
    check("subtract clamps at black", BlenderColor.subtract(Texel(50, 200, 0, 255), Texel(100, 100, 100, 255)) == Texel(0, 100, 0, 255))
    check("multiply by white leaves the colour", BlenderColor.multiply(Texel(77, 150, 3, 255), Texel(255, 255, 255, 255)) == Texel(77, 150, 3, 255))
    check("lighten and darken pick per channel",
          BlenderColor.lighten(Texel(10, 200, 50, 255), Texel(100, 100, 100, 255)) == Texel(100, 200, 100, 255)
          && BlenderColor.darken(Texel(10, 200, 50, 255), Texel(100, 100, 100, 255)) == Texel(10, 100, 50, 255))
    check("interpolate runs from one end to the other",
          BlenderColor.interpolate(base, red, 0) == base && BlenderColor.interpolate(base, red, 1) == red)
    check("unit_float_to_uchar_clamp rounds, and saturates just below 1",
          BlenderColor.byte(0.8) == 204 && BlenderColor.byte(0.998) == 254 && BlenderColor.byte(0.999) == 255
          && BlenderColor.byte(-1) == 0 && BlenderColor.byte(.nan) == 0)
    let premul = BlenderColor.premultiplied(Texel(200, 100, 50, 128))
    check("premultiplied and back is the same texel", BlenderColor.straight(premul) == Texel(200, 100, 50, 128),
          "\(BlenderColor.straight(premul))")
    check("sRGB transfer both ways", abs(BlenderColor.srgbToLinear(BlenderColor.linearToSRGB(0.3)) - 0.3) < 1e-5
          && abs(BlenderColor.linearToSRGB(0.214) - 0.5) < 2e-3)
}

section("falloff")
do {
    let smooth = TexturePaintFalloff.preset(.smooth)
    check("smooth: 1 at the centre, 0.5 halfway, 0 at the rim",
          smooth.strength(distance: 0, radius: 10) == 1 && abs(smooth.strength(distance: 5, radius: 10) - 0.5) < 1e-6
          && smooth.strength(distance: 10, radius: 10) == 0)
    check("root is Blender's sqrt(1 - d/r)",
          abs(TexturePaintFalloff.preset(.root).strength(distance: 7.5, radius: 10) - 0.5) < 1e-6)
    let hard = TexturePaintFalloff.curve(TexturePaintCurves.paintHard)
    check("Paint Hard is full strength to three quarters of the radius",
          hard.strength(distance: 7.4, radius: 10) == 1 && hard.strength(distance: 9.9, radius: 10) < 0.06)
    var monotonic = true
    var previous: Float = 2
    for i in 0...100 {
        let v = hard.strength(distance: Float(i) / 100, radius: 1)
        if v > previous + 1e-6 { monotonic = false }
        previous = v
    }
    check("and never rises toward the rim", monotonic)
    check("a table is read linearly between its entries",
          abs(TexturePaintFalloff.curve([1, 0]).strength(distance: 0.25, radius: 1) - 0.75) < 1e-6)
}

section("the brushes start as Blender's essentials")
do {
    let s = TexturePaintSettings()
    check("unified size is a 100-pixel diameter, colour black", s.size == 100 && s.colour == .zero)
    let draw = s[.draw], blur = s[.soften], smear = s[.smear]
    check("Draw is Paint Hard: strength 1, spacing 10, no pressure",
          draw.strength == 1 && draw.spacing == 10 && !draw.usePressureSize && !draw.usePressureStrength
          && draw.falloff.blenderPreset == "CUSTOM")
    check("Blur is SOFTEN at strength 1 with pressure on strength", blur.strength == 1 && blur.usePressureStrength
          && blur.falloff == .preset(.smooth) && s[.soften].tool.blenderType == "SOFTEN")
    check("Smear is 0.6 at 5 % spacing", smear.strength == 0.6 && smear.spacing == 5)
    check("Texture Paint paints with Blender's DRAW, SOFTEN and SMEAR, and nothing else",
          TexturePaintTool.allCases.map(\.blenderType) == ["DRAW", "SOFTEN", "SMEAR"],
          "\(TexturePaintTool.allCases.map(\.blenderType))")
    check("Average is not a Texture Paint brush: picking it goes to Vertex Paint, and stays there",
          ActiveTool.paintAverage.texturePaintTool == nil
          && ActiveTool.paintAverage.mode(whenChosenFrom: .texturePaint) == .vertexPaint
          && ActiveTool.paintAverage.mode(whenChosenFrom: .vertexPaint) == nil)
    let live = ActiveTool.allCases.filter { $0.requiredMode == .texturePaint && $0.isImplemented }
    check("every live tool that goes to Texture Paint has a brush there",
          !live.isEmpty && live.allSatisfy { $0.texturePaintTool != nil }, "\(live)")
    check("the toolbar's Smear is implemented and paints with Smear",
          ActiveTool.paintSmear.isImplemented && ActiveTool.paintSmear.texturePaintTool == .smear
          && ActiveTool.paintBlur.texturePaintTool == .soften && ActiveTool.move.texturePaintTool == nil)
    check("Blender's blend names", BrushBlend.subtract.blenderBlend == "SUB" && BrushBlend.multiply.blenderBlend == "MUL")
}

// MARK: - projection painting

section("Draw through an orthographic view")
do {
    let image = grey()
    let brush = settings(falloff: .preset(.constant))
    let s = stroke(quad(-1, -1, 1, 1), image, brush)
    let before = image.version
    s.begin(at: SIMD2(100, 100), pressure: 1)
    let painted = count(image) { $0 == red }
    check("a 40-point brush over 2-point texels paints a disc about ten texels across",
          (290...340).contains(painted), "\(painted) texels")
    check("the centre is the brush colour", texel(image, 50, 50) == red, "\(texel(image, 50, 50))")
    check("a texel beyond the radius is untouched", texel(image, 64, 50) == untouched && texel(image, 50, 64) == untouched)
    check("nothing else changed colour", count(image) { $0 != red && $0 != untouched } == 0)
    if let rect = image.changedRect(since: before) {
        check("the GPU is told the rectangle that changed, not the whole image",
              rect.x <= 41 && rect.x + rect.width >= 60 && rect.width < 40, "\(rect)")
    } else {
        check("the GPU is told the rectangle that changed", false, "nil")
    }
}

section("strength is a ceiling within a stroke, as Blender's opacity masking makes it")
do {
    let image = grey()
    let brush = settings(falloff: .preset(.constant), strength: 0.5)
    let s = stroke(quad(-1, -1, 1, 1), image, brush)
    s.begin(at: SIMD2(100, 100), pressure: 1)
    let once = texel(image, 50, 50)
    s.begin(at: SIMD2(100, 100), pressure: 1)
    // Blender truncates the accumulated mask to a short and paints with that:
    // 0.5 · 65535 is kept as 32767, which is byte 127, not 128.
    check("half strength over grey is Blender's (229, 102, 102)", once == Texel(229, 102, 102, 255), "\(once)")
    check("a second dab of the same stroke adds nothing", texel(image, 50, 50) == once, "\(texel(image, 50, 50))")
    let next = stroke(quad(-1, -1, 1, 1), image, brush)
    next.begin(at: SIMD2(100, 100), pressure: 1)
    let twice = texel(image, 50, 50)
    check("a new stroke builds on the last", twice.r > once.r && twice.g < once.g, "\(twice)")
}

section("spacing and pressure")
do {
    let image = grey()
    let s = stroke(quad(-1, -1, 1, 1), image, settings())
    s.begin(at: SIMD2(50, 100), pressure: 1)
    s.move(to: SIMD2(150, 100), pressure: 1)
    check("10 % of a 40-point diameter is a dab every 4 points: 26 over 100 points", s.dabCount == 26, "\(s.dabCount)")
    s.move(to: SIMD2(151, 100), pressure: 1)
    check("a move shorter than the spacing lays nothing", s.dabCount == 26)
    s.move(to: SIMD2(154, 100), pressure: 1)
    check("and the remainder carries into the next move", s.dabCount == 27, "\(s.dabCount)")

    let small = grey(), full = grey()
    let pressured = settings(falloff: .preset(.constant), pressureSize: true)
    stroke(quad(-1, -1, 1, 1), small, pressured).begin(at: SIMD2(100, 100), pressure: 0.5)
    stroke(quad(-1, -1, 1, 1), full, pressured).begin(at: SIMD2(100, 100), pressure: 1)
    let a = count(small) { $0 == red }, b = count(full) { $0 == red }
    check("with size pressure, half pressure paints a quarter of the area", Double(a) / Double(b) > 0.2 && Double(a) / Double(b) < 0.3,
          "\(a) vs \(b)")
}

section("what the brush cannot see is not painted")
do {
    let back = grey(), front = grey()
    let behind = quad(-1, -1, 1, 1, z: 0)
    let over = quad(-1, -1, 0, 1, z: 1)
    let q = Quad(positions: behind.positions + over.positions,
                 indices: behind.indices + over.indices.map { $0 + 4 },
                 uvs: behind.uvs + over.uvs)
    let target = TexturePaintTarget(positions: q.positions, indices: q.indices, cornerUVs: q.uvs,
                                    triangleSlots: [0, 0, 1, 1], images: [back, front])
    let s = TexturePaintStroke(target: target, camera: topCamera(),
                               settings: settings(falloff: .preset(.constant)), tool: .draw)!
    s.begin(at: SIMD2(100, 100), pressure: 1)
    check("the far surface behind the near one stays clean", texel(back, 45, 50) == untouched, "\(texel(back, 45, 50))")
    check("the far surface where nothing covers it is painted", texel(back, 55, 50) == red)
    check("the near surface is painted", texel(front, 90, 50) == red, "\(texel(front, 90, 50))")
    check("and both images are reported as painted", s.paintedImages.count == 2)

    let away = grey()
    let reversed = stroke(quad(-1, -1, 1, 1, facing: false), away, settings())
    reversed.begin(at: SIMD2(100, 100), pressure: 1)
    check("a face turned away from the view is culled", reversed.paintedTexels == 0 && count(away) { $0 != untouched } == 0)
}

section("normal falloff: faces seen edge-on take less paint")
do {
    func tilted(_ degrees: Float) -> TextureImage {
        let image = grey()
        let angle = degrees * .pi / 180
        var q = quad(-1, -1, 1, 1)
        q.positions = q.positions.map { SIMD3($0.x, $0.y * cos(angle), $0.y * sin(angle)) }
        stroke(q, image, settings(falloff: .preset(.constant))).begin(at: SIMD2(100, 100), pressure: 1)
        return image
    }
    check("at 60° from the view, full strength", texel(tilted(60), 50, 50) == red)
    // Half of Blender's 80°-85° fade. Its mask is stored as `(ushort)(mask *
    // 65535)`, which truncates 0.5 to just under, so half strength lands one
    // byte short of an exact half: 229 rather than 230.
    let half = texel(tilted(82.5), 50, 50)
    check("at 82.5°, halfway through Blender's 80°-85° fade, about half strength",
          (228...230).contains(half.r) && (101...104).contains(half.g), "\(half)")
    check("at 86°, none", texel(tilted(86), 50, 50) == untouched)
}

section("Blur and Smear move colour that is already there")
do {
    func halves() -> TextureImage {
        let image = grey()
        image.withMutablePixels { p in
            for y in 0..<100 { for x in 0..<100 {
                let i = (y * 100 + x) * 4
                let v: UInt8 = x < 50 ? 0 : 255
                p[i] = v; p[i + 1] = v; p[i + 2] = v; p[i + 3] = 255
            } }
        }
        return image
    }
    let blurred = halves()
    stroke(quad(-1, -1, 1, 1), blurred, settings(tool: .soften), tool: .soften)
        .begin(at: SIMD2(100, 100), pressure: 1)
    let left = texel(blurred, 49, 50).r, right = texel(blurred, 50, 50).r
    check("Blur softens the edge from both sides", left > 20 && left < 120 && right > 140 && right < 235,
          "\(left) \(right)")
    check("and leaves flat colour flat", texel(blurred, 40, 50).r == 0 && texel(blurred, 60, 50).r == 255)

    let smeared = halves()
    let smear = stroke(quad(-1, -1, 1, 1), smeared, settings(tool: .smear), tool: .smear)
    smear.begin(at: SIMD2(80, 100), pressure: 1)
    smear.move(to: SIMD2(130, 100), pressure: 1)
    check("Smear drags the dark side along the stroke", texel(smeared, 56, 50).r < 235, "\(texel(smeared, 56, 50))")
    check("but not against it", texel(smeared, 44, 50).r < 30, "\(texel(smeared, 44, 50))")
}

section("symmetry and seams")
do {
    let image = grey()
    let s = stroke(quad(-1, -1, 1, 1), image, settings(size: 20, falloff: .preset(.constant)),
                   symmetry: MeshSymmetry(x: true))
    // Screen x 60 is world x -0.4, texels 29-30; its reflection is texels 69-70.
    s.begin(at: SIMD2(60, 100), pressure: 1)
    check("mirror X paints the stroke and its reflection",
          texel(image, 29, 50) == red && texel(image, 70, 50) == red && texel(image, 50, 50) == untouched,
          "\(texel(image, 29, 50)) \(texel(image, 70, 50)) \(texel(image, 50, 50))")

    // A box's near and far sides, seen side-on. The stroke lands on the near
    // side; its mirror image lies on the far side, which faces away from the
    // view and is reached only through the mirror — as in Blender, whose
    // symmetry pass negates the object matrix and keeps the mesh's normals.
    let box = Quad(positions: [SIMD3(0.5, -1, -1), SIMD3(0.5, 1, -1), SIMD3(0.5, 1, 1), SIMD3(0.5, -1, 1),
                               SIMD3(-0.5, 1, -1), SIMD3(-0.5, -1, -1), SIMD3(-0.5, -1, 1), SIMD3(-0.5, 1, 1)],
                   indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                   uvs: [SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0.5, 1), SIMD2(0, 0), SIMD2(0.5, 1), SIMD2(0, 1),
                         SIMD2(0.5, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0.5, 0), SIMD2(1, 1), SIMD2(0.5, 1)])
    let sideView = simd_float4x4.lookAt(eye: SIMD3(5, 0, 0), center: .zero, up: SIMD3(0, 0, 1))
    let sideways = TexturePaintCamera(
        viewProjection: simd_float4x4.orthographic(halfWidth: 1, halfHeight: 1, near: -100, far: 100) * sideView,
        size: SIMD2(200, 200), eye: SIMD3(5, 0, 0), forward: SIMD3(-1, 0, 0), isOrthographic: true)
    for mirrored in [false, true] {
        let sides = grey()
        stroke(box, sides, camera: sideways, settings(size: 20, falloff: .preset(.constant)),
               symmetry: MeshSymmetry(x: mirrored)).begin(at: SIMD2(60, 100), pressure: 1)
        let near = texel(sides, 15, 50), far = texel(sides, 85, 50)
        if mirrored {
            check("on a closed shape, mirror X paints the far side's mirror image, which faces away",
                  near == red && far == red, "\(near) \(far)")
        } else {
            check("without it, only the near side is painted", near == red && far == untouched, "\(near) \(far)")
        }
    }

    // An island in the middle of the image: its outline is all seam.
    let island = quad(-0.5, -0.5, 0.5, 0.5, uv0: SIMD2(0.25, 0.25), uv1: SIMD2(0.75, 0.75))
    let bled = grey(), clipped = grey()
    stroke(island, bled, settings(falloff: .preset(.constant))).begin(at: SIMD2(150, 100), pressure: 1)
    stroke(island, clipped, settings(falloff: .preset(.constant)), seams: false).begin(at: SIMD2(150, 100), pressure: 1)
    check("seam bleed carries paint two texels past the island's edge",
          texel(bled, 74, 50) == red && texel(bled, 75, 50) == red && texel(bled, 76, 50) == red
          && texel(bled, 77, 50) == untouched, "\(texel(bled, 75, 50)) \(texel(bled, 76, 50)) \(texel(bled, 77, 50))")
    check("and without it stops at the edge", texel(clipped, 74, 50) == red && texel(clipped, 75, 50) == untouched)

    let seams = TexturePaintSeams(indices: island.indices, cornerUVs: island.uvs, triangleSlots: [])
    check("a quad's shared diagonal is not a seam; its outline is",
          seams.flags == [0b011, 0b110], "\(seams.flags.map { String($0, radix: 2) })")
}

section("perspective")
do {
    let image = grey()
    let s = stroke(quad(-1, -1, 1, 1), image, camera: perspectiveCamera(distance: 3),
                   settings(falloff: .preset(.constant)))
    s.begin(at: SIMD2(100, 100), pressure: 1)
    // 3 m away with Blender's 50 mm lens, 200 points span 2.16 m: a 20-point
    // radius is 10.8 texels, about 366 of them.
    let painted = count(image) { $0 == red }
    check("the brush is round on the screen, whatever the distance", (320...420).contains(painted), "\(painted)")
    check("and centred where it was placed", texel(image, 50, 50) == red && texel(image, 50, 62) == untouched)
}

// MARK: - pixels, surfaces, the shim

section("pixels between Blender and the viewport")
do {
    // A byte image: every byte value, bottom row first, as Image.pixels holds it.
    let width = 16, height = 16
    var floats = [Float](repeating: 0, count: width * height * 4)
    // Every byte value, as Blender's own pixels getter gives them: b · (1/255).
    for i in 0..<floats.count { floats[i] = Float(i % 256) * (1.0 / 255.0) }
    let bytes = floats.withUnsafeBufferPointer {
        TexturePaintPixels.bytes(from: $0, width: width, height: height, channels: 4)
    }
    check("Blender's bottom row is the viewport's top row",
          bytes[(15 * 16) * 4] == UInt8(0) && bytes[0] == UInt8((15 * 16 * 4) % 256))
    let image = TextureImage(width: width, height: height, name: "B", pixels: bytes)
    check("a byte image comes back to Blender exactly", TexturePaintPixels.floats(from: image) == floats)

    // A float image, 2×2, bottom row first as Image.pixels holds it.
    let hdrValues: [Float] = [3.0, 0.5, 0.25, 1.0,   0.1, 0.2, 0.3, 1.0,
                              0.25, 0.25, 0.25, 0.5, -0.5, 0.0, 12.0, 1.0]
    hdrValues.withUnsafeBufferPointer {
        TexturePaintImages.receive(name: "HDR", width: 2, height: 2, channels: 4, isFloat: true, floats: $0)
    }
    let hdr = TexturePaintImages.image(named: "HDR")!
    check("a float image keeps its floats to paint in, Blender's bottom row as the top row",
          hdr.floats! == [0.25, 0.25, 0.25, 0.5, -0.5, 0.0, 12.0, 1.0, 3.0, 0.5, 0.25, 1.0, 0.1, 0.2, 0.3, 1.0],
          "\(hdr.floats ?? [])")
    check("and goes back to Blender value for value, above 1 and below 0 included",
          TexturePaintPixels.floats(from: hdr) == hdrValues, "\(TexturePaintPixels.floats(from: hdr))")
    check("it is shown through the sRGB curve, clamped to a byte", texel(hdr, 0, 0) == Texel(255, 188, 137, 255),
          "\(texel(hdr, 0, 0))")
    check("with alpha divided out first, as Blender's display buffer divides it",
          texel(hdr, 0, 1) == Texel(188, 188, 188, 128), "\(texel(hdr, 0, 1))")
    let rgb: [Float] = [0.5, 1.5, 2.5, 0.125, 0.25, 0.375]
    rgb.withUnsafeBufferPointer {
        TexturePaintImages.receive(name: "RGB", width: 2, height: 1, channels: 3, isFloat: true, floats: $0)
    }
    let three = TexturePaintImages.image(named: "RGB")!
    check("a three-channel float image paints as RGBA and goes back as three channels",
          three.floats! == [0.5, 1.5, 2.5, 1, 0.125, 0.25, 0.375, 1] && TexturePaintPixels.floats(from: three) == rgb)
}

section("brush size, spacing and reach are Blender's pixels, not points")
do {
    let brush = settings(falloff: .preset(.constant))
    let twice = grey(), once = grey(), inPoints = grey()
    stroke(quad(-1, -1, 1, 1), twice, camera: topCamera(points: 100, pixelsPerPoint: 2), brush)
        .begin(at: SIMD2(50, 50), pressure: 1)
    stroke(quad(-1, -1, 1, 1), once, camera: topCamera(points: 200), brush).begin(at: SIMD2(100, 100), pressure: 1)
    check("Size 40 on a 100-point, 2× view paints exactly what it paints on a 200-pixel, 1× one",
          twice.pixels == once.pixels && count(once) { $0 == red } > 250)
    stroke(quad(-1, -1, 1, 1), inPoints, camera: topCamera(points: 200, pixelsPerPoint: 2), brush)
        .begin(at: SIMD2(100, 100), pressure: 1)
    let ratio = Double(count(inPoints) { $0 == red }) / Double(count(once) { $0 == red })
    check("so on a 2× screen Size 40 is 20 points across: a quarter of the area 40 points would cover",
          ratio > 0.2 && ratio < 0.3, "\(ratio)")

    let at2 = stroke(quad(-1, -1, 1, 1), grey(), camera: topCamera(points: 100, pixelsPerPoint: 2), settings())
    at2.begin(at: SIMD2(25, 50), pressure: 1)
    at2.move(to: SIMD2(75, 50), pressure: 1)
    let at1 = stroke(quad(-1, -1, 1, 1), grey(), camera: topCamera(points: 100), settings())
    at1.begin(at: SIMD2(25, 50), pressure: 1)
    at1.move(to: SIMD2(75, 50), pressure: 1)
    check("spacing is 10 % of the 40-pixel diameter: 26 dabs over 50 points at 2×, 13 at 1×",
          at2.dabCount == 26 && at1.dabCount == 13, "\(at2.dabCount) \(at1.dabCount)")
}

section("float images are painted in float, with Blender's float arithmetic")
do {
    let s1 = SIMD4<Float>(0.5, 0.25, 2.0, 1.0)
    // The colour (0.8, 0.1, 0.3) at t = 0.5, premultiplied as do_projectpaint_draw_f makes it.
    let s2 = SIMD4<Float>(0.4, 0.05, 0.15, 0.5)
    let expected: [(BrushBlend, SIMD4<Float>)] = [
        (.mix, SIMD4(0.65, 0.175, 1.15, 1)), (.add, SIMD4(0.9, 0.3, 2.15, 1)),
        (.subtract, SIMD4(0.1, 0.2, 1.85, 1)), (.multiply, SIMD4(0.45, 0.1375, 1.3, 1)),
        (.lighten, SIMD4(0.65, 0.25, 2.0, 1)), (.darken, SIMD4(0.5, 0.175, 1.15, 1))]
    for (mode, want) in expected {
        let got = BlenderColor.blendFloat(mode, s1, s2)
        check("blend_color_\(mode.blenderBlend.lowercased())_float, worked by hand from Blender's source", near(got, want),
              "\(got) vs \(want)")
    }
    check("a brush of no strength leaves a float texel as it was",
          BlenderColor.blendFloat(.add, s1, SIMD4(1, 1, 1, 0)) == s1)
    check("blend_color_interpolate_float is a straight lerp of premultiplied values",
          near(BlenderColor.interpolateFloat(s1, SIMD4(1, 1, 1, 1), 0.25), SIMD4(0.625, 0.4375, 1.75, 1)))
    var swatch = TexturePaintSettings()
    swatch.colour = SIMD3(1, 0.5, 0)
    // 0.21404118835926056 is Blender 5.2.1's Color((0.5,)*3).from_srgb_to_scene_linear().
    check("the swatch is taken from display to scene-linear, as Blender stores it",
          abs(swatch.linearColour.x - 1) < 1e-6 && abs(swatch.linearColour.y - 0.21404119) < 1e-6
          && swatch.linearColour.z == 0, "\(swatch.linearColour)")

    let image = floatImage(100, 0.6)
    image.withMutableFloats { f in
        let i = ((99 - 90) * 100 + 90) * 4
        f[i] = 3; f[i + 1] = 3; f[i + 2] = 3
    }
    let before = image.floats!
    let version = image.version
    let s = stroke(quad(-1, -1, 1, 1), image, settings(colour: SIMD3(1, 0.5, 0), falloff: .preset(.constant),
                                                       strength: 0.5))
    s.begin(at: SIMD2(100, 100), pressure: 1)
    // Opacity masking keeps 0.5 as the short 32767, as for bytes.
    let m: Float = 32767.0 / 65535.0
    let want = SIMD4<Float>((1 - m) * 0.6 + m * 1, (1 - m) * 0.6 + m * 0.21404119, (1 - m) * 0.6, 1)
    let centre = floatTexel(image, 50, 50)
    check("half strength over 0.6 is (1 − m)·0.6 + m·linear colour, in float", near(centre, want, 1e-5),
          "\(centre) vs \(want)")
    let onByteGrid = (0...255).contains { abs(BlenderColor.srgbToLinear(Float($0) / 255) - centre.y) < 1e-5 }
    check("a value no sRGB byte holds, so nothing was painted in bytes", !onByteGrid, "\(centre.y)")
    check("an HDR texel the brush did not reach keeps 3.0 to the bit", floatTexel(image, 90, 90) == SIMD4(3, 3, 3, 1))
    var changed = 0, strayed = 0
    let after = image.floats!
    for i in stride(from: 0, to: after.count, by: 4)
    where after[i] != before[i] || after[i + 1] != before[i + 1] || after[i + 2] != before[i + 2]
        || after[i + 3] != before[i + 3] {
        changed += 1
        let x = (i / 4) % 100, y = 99 - (i / 4) / 100
        if (Float(x) + 0.5 - 50) * (Float(x) + 0.5 - 50) + (Float(y) + 0.5 - 50) * (Float(y) + 0.5 - 50) > 121 {
            strayed += 1
        }
    }
    check("only the texels under the brush changed, every other float is bit for bit what it was",
          (290...340).contains(changed) && strayed == 0, "\(changed) changed, \(strayed) outside")
    check("the viewport shows the painted floats through the sRGB curve",
          texel(image, 50, 50) == Texel(BlenderColor.byte(BlenderColor.linearToSRGB(want.x)),
                                        BlenderColor.byte(BlenderColor.linearToSRGB(want.y)),
                                        BlenderColor.byte(BlenderColor.linearToSRGB(want.z)), 255),
          "\(texel(image, 50, 50))")
    check("and only the rectangle that changed goes to the GPU",
          image.changedRect(since: version).map { $0.width < 40 && $0.width > 15 } ?? false)
    let handed = TexturePaintPixels.floats(from: image)
    check("Blender is handed the painted floats themselves, in its own row order",
          handed.count == 40_000 && handed[(50 * 100 + 50) * 4 + 1] == centre.y
          && handed[(90 * 100 + 90) * 4] == 3 && handed[(10 * 100 + 10) * 4] == 0.6)
    s.begin(at: SIMD2(100, 100), pressure: 1)
    check("a second dab of the stroke adds nothing to a float texel either", floatTexel(image, 50, 50) == centre)

    // Dark on the left, 4.0 on the right.
    func floatHalves() -> TextureImage {
        let image = floatImage(100, 0)
        image.withMutableFloats { f in
            for texel in 0..<10_000 where texel % 100 >= 50 { f[4 * texel] = 4; f[4 * texel + 1] = 4; f[4 * texel + 2] = 4 }
        }
        return image
    }
    let blurred = floatHalves()
    stroke(quad(-1, -1, 1, 1), blurred, settings(tool: .soften), tool: .soften).begin(at: SIMD2(100, 100), pressure: 1)
    let left = floatTexel(blurred, 49, 50).x, right = floatTexel(blurred, 50, 50).x
    let flat = floatTexel(blurred, 55, 50).x
    check("Blur softens a float edge from both sides", left > 0 && left < 1 && right < 4, "\(left) \(right)")
    check("with its samples clamped to 0…1, as Blender's PickColor clamps them: flat 4.0 under the brush comes down",
          flat < 3.9 && flat > 1, "\(flat)")
    check("and nothing outside the brush changes",
          floatTexel(blurred, 10, 50) == SIMD4(0, 0, 0, 1) && floatTexel(blurred, 90, 50) == SIMD4(4, 4, 4, 1))

    let smeared = floatHalves()
    let smear = stroke(quad(-1, -1, 1, 1), smeared, settings(tool: .smear), tool: .smear)
    smear.begin(at: SIMD2(80, 100), pressure: 1)
    smear.move(to: SIMD2(130, 100), pressure: 1)
    let dragged = floatTexel(smeared, 56, 50)
    check("Smear carries the dark side into the bright one, below what clamping alone would leave",
          dragged.x < 1 && dragged.w == 1, "\(dragged)")
}

section("the simulator's undo keeps only what a step changed")
do {
    let scene = BKScene()
    let cube = scene.objects[0]
    _ = TexturePaintImages.prepareShim(cube, in: scene, width: 1024, height: 1024)
    func current() -> TextureImage { TexturePaintImages.image(named: "Material Base Color")! }
    let view = simd_float4x4.lookAt(eye: SIMD3(0, 0, 6), center: .zero, up: SIMD3(0, 1, 0))
    let camera = TexturePaintCamera(viewProjection: simd_float4x4.orthographic(halfWidth: 2, halfHeight: 2, near: -100, far: 100) * view,
                                    size: SIMD2(200, 200), eye: SIMD3(0, 0, 6), forward: SIMD3(0, 0, -1), isOrthographic: true)
    // Dabs on an 8×8 grid over the cube's top face, red and blue by turns.
    func paint(_ i: Int, colour: SIMD3<Float>? = nil) -> Int {
        let obj = scene.objects.first { $0.name == "Cube" }!
        guard let target = obj.paintTarget else { return 0 }
        let s = TexturePaintStroke(target: TexturePaintTarget(positions: obj.mesh.vertices.map(\.position),
                                                              indices: obj.mesh.indices,
                                                              cornerUVs: target.surface.cornerUVs, images: target.images),
                                   camera: camera,
                                   settings: settings(colour: colour ?? (i % 2 == 0 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1))),
                                   tool: .draw)!
        s.begin(at: SIMD2(62 + Float(i % 8) * 11, 62 + Float(i / 8 % 8) * 11), pressure: 1)
        return s.paintedTexels
    }
    let undo = UndoStack()
    undo.seed(scene)
    var snapshots = [scene.snapshot()]
    var prints = [fingerprint(current().pixels)]
    var middle: [UInt8] = []
    var painted = true
    for i in 0..<64 {
        if paint(i) == 0 { painted = false }
        undo.push("Texture Paint", scene)
        snapshots.append(scene.snapshot())
        prints.append(fingerprint(current().pixels))
        if i + 1 == 32 { middle = current().pixels }
    }
    let retained = SceneSnapshot.paintBytes(snapshots)
    print(String(format: "        65 steps of a 1024² image hold %.1f MB; full copies would be %.1f MB",
                 Double(retained) / 1e6, Double(65 * 1024 * 1024 * 4) / 1e6))
    check("64 strokes on a 1024² image, each a step: every stroke painted, and all 65 steps hold under 24 MB",
          painted && retained >= 1024 * 1024 * 4 && retained < 24_000_000, "\(retained) bytes")
    check("each stroke's step differs from the last", Set(prints).count == 65)

    var undone = 0, exact = true, middleExact = false
    while undo.undo(into: scene) != nil {
        undone += 1
        if fingerprint(current().pixels) != prints[64 - undone] { exact = false }
        if 64 - undone == 32 { middleExact = current().pixels == middle }
    }
    check("63 undos put back each step's pixels exactly", exact && undone == 63 && middleExact, "\(undone) \(exact) \(middleExact)")
    var redone = 0
    exact = true
    while undo.redo(into: scene) != nil {
        redone += 1
        if fingerprint(current().pixels) != prints[1 + redone] { exact = false }
    }
    check("and 63 redos bring each stroke back exactly", exact && redone == 63, "\(redone) \(exact)")
    undo.undo(into: scene)
    let green = paint(27, colour: SIMD3(0, 1, 0))
    check("painting after an undo changes the image", green > 0 && fingerprint(current().pixels) != prints[63])
    undo.redo(into: scene)
    undo.undo(into: scene)
    check("but not the step it came back to", fingerprint(current().pixels) == prints[63])
    scene.restore(snapshots[0])
    check("the first snapshot still rebuilds the unpainted image", count(current()) { $0 != untouched } == 0)

    let hdr = floatImage(256, 0.25)
    let first = TexturePaintUndoImage.capture(hdr)
    hdr.withMutableFloats { $0[4 * (100 * 256 + 100)] = 7 }
    let second = TexturePaintUndoImage.capture(hdr)
    check("a float image's steps share tiles: one changed float costs one 64² tile of bytes and floats",
          TexturePaintUndoImage.retainedBytes([first, second]) == 256 * 256 * 4 * 5 + 64 * 64 * 4 * 5,
          "\(TexturePaintUndoImage.retainedBytes([first, second]))")
    let old = first.restore().floats!, new = second.restore().floats!
    var oldExact = old.count == 256 * 256 * 4
    for i in stride(from: 0, to: old.count, by: 4)
    where old[i] != 0.25 || old[i + 1] != 0.25 || old[i + 2] != 0.25 || old[i + 3] != 1 { oldExact = false }
    check("and each step restores its own floats to the bit",
          oldExact && new[4 * (100 * 256 + 100)] == 7 && new[4 * (100 * 256 + 101)] == 0.25)
}

section("the shim's bpy.ops.paint.image_paint still paints")
do {
    let image = TextureImage(width: 64, height: 64, name: "Shim")
    image.fillChecker()
    let before = image.version
    image.paint(at: SIMD2(0.5, 0.5), radius: 0.1, colour: SIMD4(1, 0, 0, 1), strength: 1)
    let i = (32 * 64 + 32) * 4
    check("_bk.paint, which the shim and tests/bpy_conformance.py call, stamps into the image",
          image.pixels[i] == 255 && image.pixels[i + 1] == 0 && image.version != before)
}

section("surfaces from the mirror")
do {
    let scene = BKScene()
    let cube = scene.objects[0]
    let triangles = cube.mesh.indices.count / 3
    // Loop k of the cube has UV (k, 0) / 100, and triangle corner c uses loop c.
    let loops = (0..<(triangles * 3)).map { UInt32($0) }
    let uvs: [Float] = (0..<(triangles * 3)).flatMap { [Float($0) / 100, Float(0)] }
    let slots = [Int32](repeating: 0, count: triangles)
    let base: [UInt8] = [1]
    let surface = loops.withUnsafeBufferPointer { l in
        uvs.withUnsafeBufferPointer { u in
            slots.withUnsafeBufferPointer { s in
                base.withUnsafeBufferPointer { b in
                    PaintSurface.reported(triangleLoops: l, loopUVs: u, triangleSlots: s,
                                          slotImages: "Material Base Color", baseColor: b, activeSlot: 0)
                }
            }
        }
    }
    check("a corner's UV is its loop's", surface?.cornerUVs[7] == SIMD2(0.07, 0))
    let floats = [Float](repeating: 0.8, count: 4 * 4 * 4)
    floats.withUnsafeBufferPointer {
        TexturePaintImages.receive(name: "Material Base Color", width: 4, height: 4, channels: 4, isFloat: false, floats: $0)
    }
    let first = TexturePaintImages.image(named: "Material Base Color")
    TexturePaintImages.install(["Cube": surface!], into: scene)
    check("installing gives the object its surface and texture",
          cube.paintSurface != nil && cube.texture === first && cube.paintTarget != nil)
    let kept = cube.paintSurface?.version
    TexturePaintImages.install(["Cube": surface!], into: scene)
    check("the same layout again keeps the installed surface", cube.paintSurface?.version == kept)
    floats.withUnsafeBufferPointer {
        TexturePaintImages.receive(name: "Material Base Color", width: 4, height: 4, channels: 4, isFloat: false, floats: $0)
    }
    check("new pixels at the same size update the image in place", TexturePaintImages.image(named: "Material Base Color") === first)
    TexturePaintImages.install([:], into: scene)
    check("an object Blender stops reporting loses its surface, and the image is forgotten",
          cube.paintSurface == nil && cube.texture == nil && TexturePaintImages.image(named: "Material Base Color") == nil)
    let misnamed: [UInt32] = [99]
    let refused = misnamed.withUnsafeBufferPointer { l in
        uvs.withUnsafeBufferPointer { u in
            PaintSurface.reported(triangleLoops: l, loopUVs: u, triangleSlots: UnsafeBufferPointer(start: nil, count: 0),
                                  slotImages: "", baseColor: UnsafeBufferPointer(start: nil, count: 0), activeSlot: 0)
        }
    }
    check("a corner naming a loop with no UV is refused", refused == nil)
}

section("the simulator's stand-in")
do {
    let scene = BKScene()
    let cube = scene.objects[0]
    let made = TexturePaintImages.prepareShim(cube, in: scene, width: 64, height: 64)
    check("entering makes a UV map and a paint slot, under Blender's operator names",
          made == ["Add Simple UVs", "Add Paint Slot"], "\(made)")
    check("the image is Blender's default: <material> Base Color, 0.8 grey",
          cube.texture?.name == "Material Base Color" && cube.texture.map { texel($0, 3, 3) } == untouched)
    check("entering again makes nothing", TexturePaintImages.prepareShim(cube, in: scene, width: 64, height: 64).isEmpty)

    let uvs = cube.paintSurface!.cornerUVs
    check("its UVs are all inside the image", uvs.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
    var boxes: [Int: (SIMD2<Float>, SIMD2<Float>)] = [:]
    for t in 0..<(uvs.count / 3) {
        let face = t / 2
        let lo = simd_min(uvs[3 * t], simd_min(uvs[3 * t + 1], uvs[3 * t + 2]))
        let hi = simd_max(uvs[3 * t], simd_max(uvs[3 * t + 1], uvs[3 * t + 2]))
        let old = boxes[face] ?? (lo, hi)
        boxes[face] = (simd_min(old.0, lo), simd_max(old.1, hi))
    }
    var overlap = false
    for a in boxes.keys { for b in boxes.keys where a < b {
        let p = boxes[a]!, q = boxes[b]!
        if p.0.x < q.1.x && q.0.x < p.1.x && p.0.y < q.1.y && q.0.y < p.1.y { overlap = true }
    } }
    check("and the cube's six faces do not overlap in them", !overlap && boxes.count == 6)

    let other = scene.add(.cube)
    _ = TexturePaintImages.prepareShim(other, in: scene, width: 8, height: 8)
    check("a second object's image takes Blender's .001 suffix", other.texture?.name == "Material Base Color.001",
          other.texture?.name ?? "nil")

    // Paint the cube from above, then undo it through a snapshot.
    let before = scene.snapshot()
    guard let target = cube.paintTarget else { check("a stand-in surface is paintable", false); exit(1) }
    let view = simd_float4x4.lookAt(eye: SIMD3(0, 0, 6), center: .zero, up: SIMD3(0, 1, 0))
    let camera = TexturePaintCamera(viewProjection: simd_float4x4.orthographic(halfWidth: 2, halfHeight: 2, near: -100, far: 100) * view,
                                    size: SIMD2(200, 200), eye: SIMD3(0, 0, 6), forward: SIMD3(0, 0, -1), isOrthographic: true)
    let paint = TexturePaintStroke(target: TexturePaintTarget(positions: cube.mesh.vertices.map(\.position),
                                                              indices: cube.mesh.indices,
                                                              cornerUVs: target.surface.cornerUVs,
                                                              images: target.images),
                                   camera: camera, settings: settings(size: 60), tool: .draw)!
    paint.begin(at: SIMD2(100, 100), pressure: 1)
    let image = cube.texture!
    let paintedCount = count(image) { $0.g < 150 }
    check("a stroke on the stand-in's top face lands in its image", paintedCount > 20 && paint.paintedTexels > 0, "\(paintedCount)")
    scene.restore(before)
    let restored = scene.objects.first { $0.name == "Cube" }!.texture!
    check("undo puts the pixels back", count(restored) { $0.g < 150 } == 0)
    check("and the object still has its surface", scene.objects.first { $0.name == "Cube" }!.paintTarget != nil)
}

section("a 1024² image")
do {
    let image = grey(1024)
    let s = stroke(quad(-1, -1, 1, 1), image, settings(size: 100))
    let start = Date()
    s.begin(at: SIMD2(20, 20), pressure: 1)
    for i in 1...160 { s.move(to: SIMD2(20 + Float(i), 20 + Float(i)), pressure: 1) }
    let ms = Date().timeIntervalSince(start) * 1000
    print(String(format: "        %d dabs across a 1024² image in %.1f ms, %.2f ms a dab",
                 s.dabCount, ms, ms / Double(max(1, s.dabCount))))
    check("a stroke across it paints", s.paintedTexels > 10_000)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
