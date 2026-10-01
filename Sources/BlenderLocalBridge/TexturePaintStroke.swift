import Foundation
import simd

// Projection painting, the way Blender's texture paint does it
// (`editors/sculpt_paint/mesh/paint_image_proj.cc`), for a device where
// Blender's own operator cannot run: it needs a 3D View region, and there is
// none.
//
// The brush is a circle on the screen. Every texel of the surface under it is
// found by rasterizing each face in texture space and projecting the texel
// back onto the screen, which is what makes the brush round on the screen and
// its radius a screen distance, however the surface is unwrapped. As in
// Blender the work is split in two:
//
// - When the stroke starts, the mesh is projected once and its visible faces
//   are sorted into a grid of screen buckets.
// - The first time a dab reaches a bucket, the texels of every face in it are
//   found, with what does not change during a stroke: where each lands on the
//   screen, whether a nearer face hides it, how squarely its face looks at the
//   view, and its colour before the stroke. A dab then only has to measure
//   distances and blend.
//
// The screen is measured in the viewport's pixels, as Blender measures a
// region: the brush size, the spacing between dabs, the buckets and the reach
// of Blur's samples are all pixels. Touches arrive in points and are scaled on
// the way in.
//
// A byte image is painted in its bytes with Blender's byte arithmetic, a float
// image in its scene-linear, premultiplied floats with the float arithmetic —
// the `_f` functions beside each byte one — and its bytes are only remade for
// display.
//
// The loops over texels are scalar arithmetic over raw buffers. The app runs
// Debug builds on the iPad, and unoptimised Swift is thirty times slower over
// arrays of SIMD values than over plain floats behind a pointer.

/// The view a stroke is painted through.
public struct TexturePaintCamera: Sendable {
    /// World to clip space, as the viewport draws with.
    public var viewProjection: simd_float4x4
    /// The viewport, in the points a touch arrives in.
    public var size: SIMD2<Float>
    public var eye: SIMD3<Float>
    /// The direction the view looks, in world space.
    public var forward: SIMD3<Float>
    public var isOrthographic: Bool
    /// The viewport's display scale: pixels of its drawable per point. Blender
    /// measures a brush in region pixels, and so does a stroke, so a Size 100
    /// brush is 100 pixels across whatever the screen.
    public var pixelsPerPoint: Float

    public init(viewProjection: simd_float4x4, size: SIMD2<Float>, eye: SIMD3<Float>,
                forward: SIMD3<Float>, isOrthographic: Bool, pixelsPerPoint: Float = 1) {
        self.viewProjection = viewProjection
        self.size = size
        self.eye = eye
        self.forward = forward
        self.isOrthographic = isOrthographic
        self.pixelsPerPoint = pixelsPerPoint
    }
}

/// The mesh a stroke paints, as the viewport draws it.
public struct TexturePaintTarget {
    /// Object-space vertex positions.
    public var positions: [SIMD3<Float>]
    /// Triangles, three vertex indices each.
    public var indices: [UInt32]
    /// One UV per entry of `indices`.
    public var cornerUVs: [SIMD2<Float>]
    /// The material slot of each triangle; empty for all slot 0.
    public var triangleSlots: [UInt16]
    /// The image each slot paints, or nil for a slot with none.
    public var images: [TextureImage?]
    public var model: simd_float4x4
    /// Mesh symmetry: the stroke is painted again through each mirror.
    public var symmetry: MeshSymmetry
    /// Seam flags for bleed; nil paints no bleed.
    public var seams: TexturePaintSeams?

    public init(positions: [SIMD3<Float>], indices: [UInt32], cornerUVs: [SIMD2<Float>],
                triangleSlots: [UInt16] = [], images: [TextureImage?],
                model: simd_float4x4 = matrix_identity_float4x4,
                symmetry: MeshSymmetry = MeshSymmetry(), seams: TexturePaintSeams? = nil) {
        self.positions = positions
        self.indices = indices
        self.cornerUVs = cornerUVs
        self.triangleSlots = triangleSlots
        self.images = images
        self.model = model
        self.symmetry = symmetry
        self.seams = seams
    }
}

public final class TexturePaintStroke {
    public let brush: TexturePaintBrush
    /// The brush diameter at full pressure, in the viewport's pixels.
    public let diameter: Float
    public let options: TexturePaintOptions
    public private(set) var dabCount = 0
    /// How many texel writes the stroke has made, for telling a stroke that
    /// painted something from one that missed the model.
    public private(set) var paintedTexels = 0

    private let camera: TexturePaintCamera
    /// Pixels per point: `begin` and `move` take points, everything else is
    /// in pixels.
    private let scale: Float
    /// The viewport in pixels.
    private let screenWidth: Float
    private let screenHeight: Float
    private let model: simd_float4x4
    /// The colour a byte image is painted with: the swatch's sRGB bytes.
    private let colour: Texel
    /// The colour a float image is painted with: scene-linear.
    private let linearR: Float, linearG: Float, linearB: Float
    /// Each distinct image once, however many slots share it.
    private let uniqueImages: [TextureImage]
    private let seams: [UInt8]
    private var views: [View] = []
    private var lastPosition = SIMD2<Float>(0, 0)
    private var lastPressure: Float = 1
    private var started = false

    // The mesh and images, flattened.
    private let vertexCount: Int
    private let triangleCount: Int
    private let positions: UnsafeMutablePointer<Float>      // x, y, z per vertex
    private let indices: UnsafeMutablePointer<Int32>        // three per triangle
    private let uvs: UnsafeMutablePointer<Float>            // u, v per corner
    private let triangleImage: UnsafeMutablePointer<Int32>  // index into uniqueImages, or -1
    private let imageWidth: UnsafeMutablePointer<Int>
    private let imageHeight: UnsafeMutablePointer<Int>
    /// Painted in its floats rather than its bytes.
    private let imageIsFloat: UnsafeMutablePointer<Bool>
    private let hasFloat: Bool
    private let imagePainted: UnsafeMutablePointer<Bool>
    /// x0, y0, x1, y1 per image of what changed since the GPU was last told;
    /// x1 < 0 when nothing did.
    private let dirty: UnsafeMutablePointer<Int>
    /// Stands in for a byte image's float buffer, which nothing reads.
    private let noFloats: UnsafeMutablePointer<Float>

    // Blender's normal falloff, as `project_state_init` derives it.
    private let maskNormal: Bool
    private let angleOuter: Float
    private let angleRange: Float
    private let cosInner: Float
    private let cosOuter: Float

    /// The brush falloff: 0 smooth, 1 sphere, 2 root, 3 sharp, 4 linear,
    /// 5 constant, 6 a table, 7 nothing.
    private let falloffKind: Int
    private let falloffTable: UnsafeMutablePointer<Float>
    private let falloffTableCount: Int

    /// Nil when there is nothing a stroke could paint: no triangles, UVs that
    /// do not line up with them, or no image in any slot.
    public init?(target: TexturePaintTarget, camera: TexturePaintCamera,
                 settings: TexturePaintSettings, tool: TexturePaintTool) {
        let triangles = target.indices.count / 3
        guard triangles > 0, target.cornerUVs.count == triangles * 3,
              target.triangleSlots.isEmpty || target.triangleSlots.count == triangles,
              camera.size.x > 0, camera.size.y > 0, settings.size > 0,
              let highest = target.indices.max(), Int(highest) < target.positions.count,
              target.positions.count < Int(Int32.max)
        else { return nil }

        var unique: [TextureImage] = []
        var slotImage: [Int] = []
        for image in target.images {
            guard let image else { slotImage.append(-1); continue }
            if let i = unique.firstIndex(where: { $0 === image }) {
                slotImage.append(i)
            } else {
                unique.append(image)
                slotImage.append(unique.count - 1)
            }
        }
        guard !unique.isEmpty else { return nil }

        let chosen = settings[tool]
        self.brush = chosen
        self.diameter = settings.size
        self.options = settings.options
        self.camera = camera
        let ppp = camera.pixelsPerPoint
        let scale: Float = ppp.isFinite && ppp > 0 ? ppp : 1
        self.scale = scale
        screenWidth = camera.size.x * scale
        screenHeight = camera.size.y * scale
        self.model = target.model
        self.uniqueImages = unique
        self.seams = target.seams.map { $0.flags.count == triangles ? $0.flags : [] } ?? []
        self.colour = Texel(BlenderColor.byte(settings.colour.x), BlenderColor.byte(settings.colour.y),
                            BlenderColor.byte(settings.colour.z), 255)
        let linear = settings.linearColour
        linearR = linear.x
        linearG = linear.y
        linearB = linear.z

        vertexCount = target.positions.count
        triangleCount = triangles
        positions = .allocate(capacity: 3 * vertexCount)
        for (i, p) in target.positions.enumerated() {
            positions[3 * i] = p.x; positions[3 * i + 1] = p.y; positions[3 * i + 2] = p.z
        }
        indices = .allocate(capacity: 3 * triangles)
        for i in 0..<(3 * triangles) { indices[i] = Int32(target.indices[i]) }
        uvs = .allocate(capacity: 6 * triangles)
        for (i, uv) in target.cornerUVs.enumerated() { uvs[2 * i] = uv.x; uvs[2 * i + 1] = uv.y }
        triangleImage = .allocate(capacity: triangles)
        for t in 0..<triangles {
            let slot = t < target.triangleSlots.count ? Int(target.triangleSlots[t]) : 0
            triangleImage[t] = Int32(slot < slotImage.count ? slotImage[slot] : -1)
        }
        let n = unique.count
        // A float image is painted in floats only when it has them all.
        let floatFlags = unique.map { $0.isFloat && ($0.floats?.count ?? -1) == $0.width * $0.height * 4 }
        hasFloat = floatFlags.contains(true)
        imageWidth = .allocate(capacity: n)
        imageHeight = .allocate(capacity: n)
        imageIsFloat = .allocate(capacity: n)
        imagePainted = .allocate(capacity: n)
        dirty = .allocate(capacity: 4 * n)
        for (i, image) in unique.enumerated() {
            imageWidth[i] = image.width
            imageHeight[i] = image.height
            imageIsFloat[i] = floatFlags[i]
            imagePainted[i] = false
            dirty[4 * i] = Int.max; dirty[4 * i + 1] = Int.max; dirty[4 * i + 2] = -1; dirty[4 * i + 3] = -1
        }
        noFloats = .allocate(capacity: 4)
        noFloats.initialize(repeating: 0, count: 4)

        // normal_angle is where the fade begins; it ends halfway to 90°.
        let inner = settings.options.normalAngle * .pi / 180
        let outer = (settings.options.normalAngle + 90) * 0.5 * .pi / 180
        angleOuter = outer
        angleRange = outer - inner
        maskNormal = settings.options.normalFalloff && outer - inner > 0
        cosInner = cos(inner)
        cosOuter = cos(outer)

        switch chosen.falloff {
        case .preset(let preset):
            switch preset {
            case .smooth:   falloffKind = 0
            case .sphere:   falloffKind = 1
            case .root:     falloffKind = 2
            case .sharp:    falloffKind = 3
            case .linear:   falloffKind = 4
            case .constant: falloffKind = 5
            }
            falloffTable = .allocate(capacity: 1)
            falloffTableCount = 0
        case .curve(let table):
            falloffKind = table.count > 1 ? 6 : 7
            falloffTable = .allocate(capacity: max(1, table.count))
            for (i, value) in table.enumerated() { falloffTable[i] = value }
            falloffTableCount = table.count
        }

        // One view per mirror, as Blender runs one projection per symmetry
        // flip: the original, then each enabled axis and their combinations.
        var flips: [SIMD3<Float>] = [SIMD3(1, 1, 1)]
        for axis in 0..<3 where target.symmetry[axis] {
            flips += flips.map { flip -> SIMD3<Float> in
                var mirrored = flip
                mirrored[axis] = -mirrored[axis]
                return mirrored
            }
        }
        views = flips.map { makeView(flip: $0) }
    }

    deinit {
        positions.deallocate()
        indices.deallocate()
        uvs.deallocate()
        triangleImage.deallocate()
        imageWidth.deallocate()
        imageHeight.deallocate()
        imageIsFloat.deallocate()
        imagePainted.deallocate()
        dirty.deallocate()
        noFloats.deallocate()
        falloffTable.deallocate()
    }

    /// Every image the stroke has painted into.
    public var paintedImages: [TextureImage] {
        uniqueImages.indices.filter { imagePainted[$0] }.map { uniqueImages[$0] }
    }

    // MARK: - The stroke

    /// Touch down, at a point in the viewport: the first dab lands where the
    /// stroke starts, as a click paints a dot in Blender.
    public func begin(at point: SIMD2<Float>, pressure: Float) {
        started = true
        let position = point * scale
        lastPosition = position
        lastPressure = Self.clamp(pressure)
        dab(at: position, pressure: lastPressure, previous: position)
        flushChanges()
    }

    /// The touch moved, to a point in the viewport: dabs are laid at even
    /// spacing along the way, with pressure interpolated between them —
    /// `paint_space_stroke`. Whatever is left over carries into the next move.
    public func move(to point: SIMD2<Float>, pressure: Float) {
        guard started else { begin(at: point, pressure: pressure); return }
        let finalPressure = Self.clamp(pressure)
        var direction = point * scale - lastPosition
        var length = simd_length(direction)
        guard length > 0 else { return }
        direction /= length
        while length > 0 {
            let spacing = spacingDistance(pressureChange: finalPressure - lastPressure, length: length)
            guard length >= spacing else { break }
            let position = lastPosition + direction * spacing
            let dabPressure = lastPressure + (spacing / length) * (finalPressure - lastPressure)
            dab(at: position, pressure: dabPressure, previous: lastPosition)
            lastPosition = position
            lastPressure = dabPressure
            length -= spacing
        }
        flushChanges()
    }

    private static func clamp(_ pressure: Float) -> Float {
        pressure.isFinite ? max(0, min(1, pressure)) : 1
    }

    /// `paint_space_stroke_spacing`, in pixels: the spacing percentage of the
    /// radius at that pressure, clamped to a pixel, over 50 — so of the
    /// diameter over 100 — and never under a pixel.
    private func spacing(sizePressure: Float) -> Float {
        let radius = max(1, diameter * 0.5 * (brush.usePressureSize ? sizePressure : 1))
        return max(1, radius * brush.spacing / 50)
    }

    /// `paint_space_stroke_spacing_variable`: with pressure changing the size,
    /// the average of the spacing at this dab's size and the next, so circles
    /// neither gap nor pile up as the pressure changes.
    private func spacingDistance(pressureChange: Float, length: Float) -> Float {
        guard brush.usePressureSize else { return spacing(sizePressure: 1) }
        let s = spacing(sizePressure: 1)
        let q = s * pressureChange / (2 * length)
        let factor = (1 + q) / (1 - q)
        let last = spacing(sizePressure: lastPressure)
        let next = spacing(sizePressure: lastPressure * factor)
        return max(1, 0.5 * (last + next))
    }

    // MARK: - Views and buckets

    /// Per triangle in a view: corner 0 on the screen (0, 1), the edges to
    /// corners 1 and 2 (2…5), 1/det (6), each corner's nearness (7…9), their
    /// least and greatest (10, 11), the object-space normal (12…14) and det
    /// itself (15), zero for a triangle with no area on the screen.
    private static let faceStride = 16

    fileprivate final class Bucket {
        let count: Int
        let image: UnsafeMutablePointer<UInt16>
        let texel: UnsafeMutablePointer<Int32>
        let x: UnsafeMutablePointer<Float>
        let y: UnsafeMutablePointer<Float>
        /// Normal falloff, from a 16-bit mask as Blender keeps `ProjPixel.mask`.
        let custom: UnsafeMutablePointer<Float>
        /// How much this stroke has laid down on each texel, for Draw.
        let accumulated: UnsafeMutablePointer<UInt16>
        /// Each texel before the stroke, which Draw blends from: four bytes,
        /// and for a float image four floats — `ProjPixel.origColor`.
        let original: UnsafeMutablePointer<UInt8>
        let originalFloat: UnsafeMutablePointer<Float>
        let face: UnsafeMutablePointer<Int32>

        init(image: [UInt16], texel: [Int32], x: [Float], y: [Float], custom: [Float],
             original: [UInt8], originalFloat: [Float], face: [Int32]) {
            count = texel.count
            let n = max(1, count)
            self.image = .allocate(capacity: n)
            self.image.initialize(from: image, count: count)
            self.texel = .allocate(capacity: n)
            self.texel.initialize(from: texel, count: count)
            self.x = .allocate(capacity: n)
            self.x.initialize(from: x, count: count)
            self.y = .allocate(capacity: n)
            self.y.initialize(from: y, count: count)
            self.custom = .allocate(capacity: n)
            self.custom.initialize(from: custom, count: count)
            accumulated = .allocate(capacity: n)
            accumulated.initialize(repeating: 0, count: n)
            self.original = .allocate(capacity: 4 * n)
            self.original.initialize(from: original, count: 4 * count)
            self.originalFloat = .allocate(capacity: max(4, originalFloat.count))
            self.originalFloat.initialize(from: originalFloat, count: originalFloat.count)
            self.face = .allocate(capacity: n)
            self.face.initialize(from: face, count: count)
        }

        deinit {
            image.deallocate(); texel.deallocate(); x.deallocate(); y.deallocate()
            custom.deallocate(); accumulated.deallocate(); original.deallocate()
            originalFloat.deallocate(); face.deallocate()
        }
    }

    fileprivate final class View {
        let negative: Bool
        let eye: SIMD3<Float>
        let toViewer: SIMD3<Float>
        let clip: UnsafeMutablePointer<Float>       // x, y, z, w per vertex
        let screen: UnsafeMutablePointer<Float>     // x, y per vertex, in pixels
        /// Bigger is nearer: 1/w in perspective, -z in orthographic. Either
        /// interpolates linearly across the screen.
        let nearness: UnsafeMutablePointer<Float>
        let inverseW: UnsafeMutablePointer<Float>
        let projected: UnsafeMutablePointer<Bool>
        let face: UnsafeMutablePointer<Float>
        var bucketsX = 0, bucketsY = 0
        var bucketW: Float = 1, bucketH: Float = 1
        var faces: [[Int32]] = []
        var buckets: [Bucket?] = []

        init(negative: Bool, eye: SIMD3<Float>, toViewer: SIMD3<Float>, vertices: Int, triangles: Int) {
            self.negative = negative
            self.eye = eye
            self.toViewer = toViewer
            clip = .allocate(capacity: 4 * vertices)
            clip.initialize(repeating: 0, count: 4 * vertices)
            screen = .allocate(capacity: 2 * vertices)
            screen.initialize(repeating: 0, count: 2 * vertices)
            nearness = .allocate(capacity: vertices)
            nearness.initialize(repeating: 0, count: vertices)
            inverseW = .allocate(capacity: vertices)
            inverseW.initialize(repeating: 1, count: vertices)
            projected = .allocate(capacity: vertices)
            projected.initialize(repeating: false, count: vertices)
            face = .allocate(capacity: TexturePaintStroke.faceStride * triangles)
            face.initialize(repeating: 0, count: TexturePaintStroke.faceStride * triangles)
        }

        deinit {
            clip.deallocate(); screen.deallocate(); nearness.deallocate()
            inverseW.deallocate(); projected.deallocate(); face.deallocate()
        }
    }

    private func makeView(flip: SIMD3<Float>) -> View {
        // The mirror is in the matrix, as Blender's symmetry pass negates the
        // object matrix's axes; the vertices themselves stay as they are.
        let objectToWorld = model * simd_float4x4(diagonal: SIMD4(flip.x, flip.y, flip.z, 1))
        let inverse = objectToWorld.inverse
        let eye = (inverse * SIMD4(camera.eye, 1)).xyz
        var toViewer = (inverse * SIMD4(-camera.forward, 0)).xyz
        toViewer = simd_length(toViewer) > 0 ? simd_normalize(toViewer) : SIMD3(0, 0, 1)
        let view = View(negative: flip.x * flip.y * flip.z < 0, eye: eye, toViewer: toViewer,
                        vertices: vertexCount, triangles: triangleCount)
        let m = camera.viewProjection * objectToWorld
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        let (m00, m01, m02, m03) = (c0.x, c0.y, c0.z, c0.w)
        let (m10, m11, m12, m13) = (c1.x, c1.y, c1.z, c1.w)
        let (m20, m21, m22, m23) = (c2.x, c2.y, c2.z, c2.w)
        let (m30, m31, m32, m33) = (c3.x, c3.y, c3.z, c3.w)
        let width = screenWidth, height = screenHeight
        let ortho = camera.isOrthographic
        let positions = self.positions

        for i in 0..<vertexCount {
            let x = positions[3 * i], y = positions[3 * i + 1], z = positions[3 * i + 2]
            let cx = m00 * x + m10 * y + m20 * z + m30
            let cy = m01 * x + m11 * y + m21 * z + m31
            let cz = m02 * x + m12 * y + m22 * z + m32
            let cw = m03 * x + m13 * y + m23 * z + m33
            view.clip[4 * i] = cx; view.clip[4 * i + 1] = cy
            view.clip[4 * i + 2] = cz; view.clip[4 * i + 3] = cw
            if ortho {
                if cw == 0 { continue }
                view.screen[2 * i] = (cx / cw * 0.5 + 0.5) * width
                view.screen[2 * i + 1] = (0.5 - cy / cw * 0.5) * height
                view.nearness[i] = -cz / cw
            } else {
                if !(cw > 1e-6) { continue }
                let iw = 1 / cw
                view.screen[2 * i] = (cx * iw * 0.5 + 0.5) * width
                view.screen[2 * i + 1] = (0.5 - cy * iw * 0.5) * height
                view.nearness[i] = iw
                view.inverseW[i] = iw
            }
            view.projected[i] = true
        }

        // Blender sizes buckets at a quarter of the brush diameter, between 4
        // and 256 of them across (PROJ_BUCKET_BRUSH_DIV).
        let across = max(diameter / 4, 1)
        view.bucketsX = max(4, min(256, Int(width / across)))
        view.bucketsY = max(4, min(256, Int(height / across)))
        view.bucketW = width / Float(view.bucketsX)
        view.bucketH = height / Float(view.bucketsY)
        view.faces = Array(repeating: [], count: view.bucketsX * view.bucketsY)
        view.buckets = Array(repeating: nil, count: view.bucketsX * view.bucketsY)

        let fd = view.face, stride = Self.faceStride
        for t in 0..<triangleCount {
            let a = Int(indices[3 * t]), b = Int(indices[3 * t + 1]), c = Int(indices[3 * t + 2])
            let ax = positions[3 * a], ay = positions[3 * a + 1], az = positions[3 * a + 2]
            let e1x = positions[3 * b] - ax, e1y = positions[3 * b + 1] - ay, e1z = positions[3 * b + 2] - az
            let e2x = positions[3 * c] - ax, e2y = positions[3 * c + 1] - ay, e2z = positions[3 * c + 2] - az
            var nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x
            let area = (nx * nx + ny * ny + nz * nz).squareRoot()
            let o = stride * t
            fd[o + 11] = -.infinity
            guard area > 1e-12 else { continue }
            // The mesh's own normal. Seen through the mirrored matrix a face
            // points toward the view exactly when its mirror image does, so
            // only its winding on the screen turns over (`is_flip_object`).
            nx /= area; ny /= area; nz /= area
            fd[o + 12] = nx; fd[o + 13] = ny; fd[o + 14] = nz

            let sx0 = view.screen[2 * a], sy0 = view.screen[2 * a + 1]
            let s1x = view.screen[2 * b] - sx0, s1y = view.screen[2 * b + 1] - sy0
            let s2x = view.screen[2 * c] - sx0, s2y = view.screen[2 * c + 1] - sy0
            let det = s1x * s2y - s1y * s2x
            let n0 = view.nearness[a], n1 = view.nearness[b], n2 = view.nearness[c]
            fd[o] = sx0; fd[o + 1] = sy0
            fd[o + 2] = s1x; fd[o + 3] = s1y; fd[o + 4] = s2x; fd[o + 5] = s2y
            fd[o + 7] = n0; fd[o + 8] = n1; fd[o + 9] = n2
            if abs(det) > 1e-12 {
                fd[o + 6] = 1 / det
                fd[o + 15] = det
                fd[o + 10] = min(n0, min(n1, n2))
                fd[o + 11] = max(n0, max(n1, n2))
            }

            guard view.projected[a], view.projected[b], view.projected[c], triangleImage[t] >= 0,
                  !isCulled(view, a, b, c, nx, ny, nz)
            else { continue }

            let xs = (sx0, sx0 + s1x, sx0 + s2x), ys = (sy0, sy0 + s1y, sy0 + s2y)
            let loX = min(xs.0, min(xs.1, xs.2)), hiX = max(xs.0, max(xs.1, xs.2))
            let loY = min(ys.0, min(ys.1, ys.2)), hiY = max(ys.0, max(ys.1, ys.2))
            guard hiX >= 0, hiY >= 0, loX < width, loY < height else { continue }
            let x0 = max(0, Int(loX / view.bucketW)), x1 = min(view.bucketsX - 1, Int(hiX / view.bucketW))
            let y0 = max(0, Int(loY / view.bucketH)), y1 = min(view.bucketsY - 1, Int(hiY / view.bucketH))
            guard x0 <= x1, y0 <= y1 else { continue }
            for by in y0...y1 {
                for bx in x0...x1 { view.faces[by * view.bucketsX + bx].append(Int32(t)) }
            }
        }
        return view
    }

    /// Back-face culling as Blender does it with normal falloff on: a face is
    /// dropped only when every corner looks away past the outer normal angle.
    /// Without normal falloff, by its winding on the screen.
    private func isCulled(_ view: View, _ a: Int, _ b: Int, _ c: Int,
                          _ nx: Float, _ ny: Float, _ nz: Float) -> Bool {
        guard options.backfaceCulling else { return false }
        if maskNormal {
            for v in [a, b, c] {
                var tx = view.toViewer.x, ty = view.toViewer.y, tz = view.toViewer.z
                if !camera.isOrthographic {
                    tx = view.eye.x - positions[3 * v]
                    ty = view.eye.y - positions[3 * v + 1]
                    tz = view.eye.z - positions[3 * v + 2]
                    let length = (tx * tx + ty * ty + tz * tz).squareRoot()
                    guard length > 0 else { continue }
                    tx /= length; ty /= length; tz /= length
                }
                if tx * nx + ty * ny + tz * nz > cosOuter { return false }
            }
            return true
        }
        // `line_point_side_v2` in Blender's y-up region coordinates.
        let s0x = view.screen[2 * a], s0y = view.screen[2 * a + 1]
        let s1x = view.screen[2 * b], s1y = view.screen[2 * b + 1]
        let s2x = view.screen[2 * c], s2y = view.screen[2 * c + 1]
        let side = -((s0x - s2x) * (s1y - s2y) - (s1x - s2x) * (s0y - s2y))
        return (view.negative ? -side : side) < 0
    }

    /// A float as an index from 0 to `upper`, whatever it is — huge, infinite
    /// or not a number.
    private static func index(_ value: Float, _ upper: Int) -> Int {
        Int(max(0, min(Float(upper), value)))
    }

    /// The texels whose centres land in one bucket, with everything about
    /// them that holds for the rest of the stroke.
    private func fillBucket(_ view: View, _ index: Int,
                            _ bases: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>,
                            _ floatBases: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) -> Bucket {
        let bx = index % view.bucketsX, by = index / view.bucketsX
        let rx0 = Float(bx) * view.bucketW, ry0 = Float(by) * view.bucketH
        let rx1 = Float(bx + 1) * view.bucketW, ry1 = Float(by + 1) * view.bucketH
        let width = screenWidth, height = screenHeight
        let ortho = camera.isOrthographic, occlude = options.occlude
        let backfaceCulling = options.backfaceCulling, maskNormal = self.maskNormal
        let cosInner = self.cosInner, cosOuter = self.cosOuter
        let angleOuter = self.angleOuter, angleRange = self.angleRange
        let bleedLimit = Float(max(0, options.seamBleed))
        let fd = view.face, stride = Self.faceStride
        let positions = self.positions, indices = self.indices, uvs = self.uvs
        let clip = view.clip, inverseW = view.inverseW
        let viewX = view.toViewer.x, viewY = view.toViewer.y, viewZ = view.toViewer.z
        let eyeX = view.eye.x, eyeY = view.eye.y, eyeZ = view.eye.z
        let keepFloats = hasFloat

        var outImage: [UInt16] = [], outTexel: [Int32] = [], outX: [Float] = [], outY: [Float] = []
        var outCustom: [Float] = [], outOriginal: [UInt8] = [], outFace: [Int32] = []
        var outOriginalFloat: [Float] = []

        view.faces[index].withUnsafeBufferPointer { list in
            let faceCount = list.count
            for entry in 0..<faceCount {
                let f = Int(list[entry])
                let ui = Int(triangleImage[f])
                if ui < 0 { continue }
                let iw = imageWidth[ui], ih = imageHeight[ui]
                let fw = Float(iw), fh = Float(ih)
                let i0 = Int(indices[3 * f]), i1 = Int(indices[3 * f + 1]), i2 = Int(indices[3 * f + 2])
                // UVs in texels, y up from the bottom row as Blender counts them.
                let u0 = uvs[6 * f] * fw, v0 = uvs[6 * f + 1] * fh
                let u1 = uvs[6 * f + 2] * fw, v1 = uvs[6 * f + 3] * fh
                let u2 = uvs[6 * f + 4] * fw, v2 = uvs[6 * f + 5] * fh
                let e1u = u1 - u0, e1v = v1 - v0, e2u = u2 - u0, e2v = v2 - v0
                let detUV = e1u * e2v - e1v * e2u
                if !(abs(detUV) > 1e-12) { continue }
                let invUV = 1 / detUV

                let seamFlags: UInt8 = f < seams.count ? seams[f] : 0
                let bleed: Float = seamFlags != 0 ? bleedLimit : 0
                var loU = min(u0, min(u1, u2)) - bleed, hiU = max(u0, max(u1, u2)) + bleed
                var loV = min(v0, min(v1, v2)) - bleed, hiV = max(v0, max(v1, v2)) + bleed
                // The texel box the bucket covers on this face's plane, so a
                // face much larger than a bucket is not scanned whole for each.
                let fo = stride * f
                if abs(fd[fo + 15]) > 1e-9 {
                    var sLoU = Float.greatestFiniteMagnitude, sHiU = -Float.greatestFiniteMagnitude
                    var sLoV = Float.greatestFiniteMagnitude, sHiV = -Float.greatestFiniteMagnitude
                    var behind = false
                    for corner in 0..<4 {
                        let dx = (corner & 1 == 0 ? rx0 : rx1) - fd[fo]
                        let dy = (corner & 2 == 0 ? ry0 : ry1) - fd[fo + 1]
                        let m1 = (dx * fd[fo + 5] - dy * fd[fo + 4]) * fd[fo + 6]
                        let m2 = (fd[fo + 2] * dy - fd[fo + 3] * dx) * fd[fo + 6]
                        let a0 = (1 - m1 - m2) * inverseW[i0], a1 = m1 * inverseW[i1], a2 = m2 * inverseW[i2]
                        let sum = a0 + a1 + a2
                        if !(sum > 1e-12) { behind = true; break }
                        let u = (u0 * a0 + u1 * a1 + u2 * a2) / sum
                        let v = (v0 * a0 + v1 * a1 + v2 * a2) / sum
                        sLoU = min(sLoU, u); sHiU = max(sHiU, u)
                        sLoV = min(sLoV, v); sHiV = max(sHiV, v)
                    }
                    if !behind {
                        loU = max(loU, sLoU - 1); hiU = min(hiU, sHiU + 1)
                        loV = max(loV, sLoV - 1); hiV = min(hiV, sHiV + 1)
                    }
                }
                let tx0 = Self.index((loU - 0.5).rounded(.down), iw)
                let tx1 = Self.index((hiU - 0.5).rounded(.up), iw - 1)
                let ty0 = Self.index((loV - 0.5).rounded(.down), ih)
                let ty1 = Self.index((hiV - 0.5).rounded(.up), ih - 1)
                if tx0 > tx1 || ty0 > ty1 { continue }

                let c0x = clip[4 * i0], c0y = clip[4 * i0 + 1], c0z = clip[4 * i0 + 2], c0w = clip[4 * i0 + 3]
                let c1x = clip[4 * i1], c1y = clip[4 * i1 + 1], c1z = clip[4 * i1 + 2], c1w = clip[4 * i1 + 3]
                let c2x = clip[4 * i2], c2y = clip[4 * i2 + 1], c2z = clip[4 * i2 + 2], c2w = clip[4 * i2 + 3]
                let p0x = positions[3 * i0], p0y = positions[3 * i0 + 1], p0z = positions[3 * i0 + 2]
                let p1x = positions[3 * i1], p1y = positions[3 * i1 + 1], p1z = positions[3 * i1 + 2]
                let p2x = positions[3 * i2], p2y = positions[3 * i2 + 1], p2z = positions[3 * i2 + 2]
                let nx = fd[fo + 12], ny = fd[fo + 13], nz = fd[fo + 14]
                let base = bases[ui]
                let fbase = floatBases[ui]
                let isFloat = imageIsFloat[ui]

                for ty in ty0...ty1 {
                    let qv = Float(ty) + 0.5
                    for tx in tx0...tx1 {
                        let qu = Float(tx) + 0.5
                        let du = qu - u0, dv = qv - v0
                        var l1 = (du * e2v - dv * e2u) * invUV
                        var l2 = (e1u * dv - e1v * du) * invUV
                        var l0 = 1 - l1 - l2
                        if l0 < -1e-6 || l1 < -1e-6 || l2 < -1e-6 {
                            // Outside the face: only seam bleed paints here,
                            // from the nearest point on a seam edge in reach.
                            if bleed <= 0 { continue }
                            var best = Float.greatestFiniteMagnitude, edge = -1
                            var b0: Float = 0, b1: Float = 0, b2: Float = 0
                            for k in 0..<3 {
                                let pu = k == 0 ? u0 : (k == 1 ? u1 : u2)
                                let pv = k == 0 ? v0 : (k == 1 ? v1 : v2)
                                let ru = k == 0 ? u1 : (k == 1 ? u2 : u0)
                                let rv = k == 0 ? v1 : (k == 1 ? v2 : v0)
                                let au = ru - pu, av = rv - pv
                                let lengthSquared = au * au + av * av
                                var s: Float = lengthSquared > 0
                                    ? ((qu - pu) * au + (qv - pv) * av) / lengthSquared : 0
                                s = max(0, min(1, s))
                                let cu = pu + au * s - qu, cv = pv + av * s - qv
                                let d = cu * cu + cv * cv
                                if d < best {
                                    best = d
                                    edge = k
                                    switch k {
                                    case 0:  b0 = 1 - s; b1 = s; b2 = 0
                                    case 1:  b0 = 0; b1 = 1 - s; b2 = s
                                    default: b0 = s; b1 = 0; b2 = 1 - s
                                    }
                                }
                            }
                            if edge < 0 || best > bleed * bleed || seamFlags & (1 << UInt8(edge)) == 0 { continue }
                            l0 = b0; l1 = b1; l2 = b2
                        }

                        // Where the texel lands: clip space is linear across
                        // the face, so its corners' clip coordinates carry it.
                        let cx = c0x * l0 + c1x * l1 + c2x * l2
                        let cy = c0y * l0 + c1y * l1 + c2y * l2
                        let cz = c0z * l0 + c1z * l1 + c2z * l2
                        let cw = c0w * l0 + c1w * l1 + c2w * l2
                        let sx: Float, sy: Float, near: Float
                        if ortho {
                            if cw == 0 { continue }
                            sx = (cx / cw * 0.5 + 0.5) * width
                            sy = (0.5 - cy / cw * 0.5) * height
                            near = -cz / cw
                        } else {
                            if !(cw > 1e-6) { continue }
                            let iwv = 1 / cw
                            sx = (cx * iwv * 0.5 + 0.5) * width
                            sy = (0.5 - cy * iwv * 0.5) * height
                            near = iwv
                        }
                        if !(sx >= rx0 && sx < rx1 && sy >= ry0 && sy < ry1) { continue }

                        if occlude {
                            // `project_bucket_point_occluded`: another face in
                            // the bucket covers the point and is nearer there.
                            let slack: Float = ortho ? 1e-6 : near * 1e-5
                            var hidden = false
                            for other in 0..<faceCount {
                                let g = Int(list[other])
                                if g == f { continue }
                                let go = stride * g
                                if fd[go + 11] < near { continue }
                                let dx = sx - fd[go], dy = sy - fd[go + 1]
                                let m1 = (dx * fd[go + 5] - dy * fd[go + 4]) * fd[go + 6]
                                let m2 = (fd[go + 2] * dy - fd[go + 3] * dx) * fd[go + 6]
                                let m0 = 1 - m1 - m2
                                if m0 < -1e-5 || m1 < -1e-5 || m2 < -1e-5 { continue }
                                if fd[go + 10] > near
                                    || m0 * fd[go + 7] + m1 * fd[go + 8] + m2 * fd[go + 9] > near + slack {
                                    hidden = true
                                    break
                                }
                            }
                            if hidden { continue }
                        }

                        var mask: Float = 1
                        if maskNormal {
                            var tvx = viewX, tvy = viewY, tvz = viewZ
                            if !ortho {
                                tvx = eyeX - (p0x * l0 + p1x * l1 + p2x * l2)
                                tvy = eyeY - (p0y * l0 + p1y * l1 + p2y * l2)
                                tvz = eyeZ - (p0z * l0 + p1z * l1 + p2z * l2)
                                let length = (tvx * tvx + tvy * tvy + tvz * tvz).squareRoot()
                                if !(length > 0) { continue }
                                tvx /= length; tvy /= length; tvz /= length
                            }
                            var facing = tvx * nx + tvy * ny + tvz * nz
                            if !backfaceCulling { facing = abs(facing) }
                            if !(facing > cosOuter) { continue }
                            if facing < cosInner { mask *= (angleOuter - acos(facing)) / angleRange }
                        }
                        let mask16 = UInt16(max(0, min(1, mask)) * 65535)
                        if mask16 == 0 { continue }

                        let texel = (ih - 1 - ty) * iw + tx
                        let o = texel * 4
                        outImage.append(UInt16(ui))
                        outTexel.append(Int32(texel))
                        outX.append(sx)
                        outY.append(sy)
                        outCustom.append(Float(mask16) * (1 / 65535))
                        outOriginal.append(base[o]); outOriginal.append(base[o + 1])
                        outOriginal.append(base[o + 2]); outOriginal.append(base[o + 3])
                        if keepFloats {
                            if isFloat {
                                outOriginalFloat.append(fbase[o]); outOriginalFloat.append(fbase[o + 1])
                                outOriginalFloat.append(fbase[o + 2]); outOriginalFloat.append(fbase[o + 3])
                            } else {
                                outOriginalFloat.append(0); outOriginalFloat.append(0)
                                outOriginalFloat.append(0); outOriginalFloat.append(0)
                            }
                        }
                        outFace.append(Int32(f))
                    }
                }
            }
        }
        return Bucket(image: outImage, texel: outTexel, x: outX, y: outY, custom: outCustom,
                      original: outOriginal, originalFloat: outOriginalFloat, face: outFace)
    }

    // MARK: - Dabs

    /// One dab, centred at a point in pixels.
    private func dab(at centre: SIMD2<Float>, pressure: Float, previous: SIMD2<Float>) {
        let radius = max(diameter * (brush.usePressureSize ? pressure : 1), 1) * 0.5
        let alpha = max(0, brush.strength * (brush.usePressureStrength ? pressure : 1))
        let radiusSquared = radius * radius
        let centreX = centre.x, centreY = centre.y
        let offsetX = centreX - previous.x, offsetY = centreY - previous.y
        dabCount += 1

        let tool = brush.tool, blend = brush.blend
        let falloffKind = self.falloffKind, table = falloffTable, tableLast = falloffTableCount - 1
        let colourR = Int(colour.r), colourG = Int(colour.g), colourB = Int(colour.b)
        let linR = linearR, linG = linearG, linB = linearB
        var painted = 0

        withPixels { bases, floatBases in
            for view in views {
                let bx0 = max(0, Int(((centreX - radius) / view.bucketW).rounded(.down)))
                let bx1 = min(view.bucketsX - 1, Int(((centreX + radius) / view.bucketW).rounded(.down)))
                let by0 = max(0, Int(((centreY - radius) / view.bucketH).rounded(.down)))
                let by1 = min(view.bucketsY - 1, Int(((centreY + radius) / view.bucketH).rounded(.down)))
                guard bx0 <= bx1, by0 <= by1 else { continue }

                // Soften and Smear read what the dab has not yet changed, so
                // their results wait until every texel is done — Blender's
                // softenPixels and smearPixels lists, and their `_f` twins.
                var laterImage: [Int] = [], laterTexel: [Int] = [], laterValue: [UInt8] = []
                var laterFloatImage: [Int] = [], laterFloatTexel: [Int] = [], laterFloat: [Float] = []

                for by in by0...by1 {
                    for bx in bx0...bx1 {
                        let index = by * view.bucketsX + bx
                        let bucket: Bucket
                        if let filled = view.buckets[index] {
                            bucket = filled
                        } else {
                            bucket = fillBucket(view, index, bases, floatBases)
                            view.buckets[index] = bucket
                        }
                        let xs = bucket.x, ys = bucket.y, customs = bucket.custom
                        let images = bucket.image, texels = bucket.texel, accumulated = bucket.accumulated
                        let originals = bucket.original, originalFloats = bucket.originalFloat
                        let faces = bucket.face
                        for k in 0..<bucket.count {
                            let dx = xs[k] - centreX, dy = ys[k] - centreY
                            let distanceSquared = dx * dx + dy * dy
                            if distanceSquared > radiusSquared { continue }
                            let distance = distanceSquared.squareRoot()
                            if !(distance < radius) { continue }
                            // BKE_brush_curve_strength_clamped.
                            let t = distance / radius
                            var falloff: Float
                            switch falloffKind {
                            case 0: falloff = 1 - t * t * (3 - 2 * t)
                            case 1: falloff = max(0, 1 - t * t).squareRoot()
                            case 2: falloff = (1 - t).squareRoot()
                            case 3: falloff = (1 - t) * (1 - t)
                            case 4: falloff = 1 - t
                            case 5: falloff = 1
                            case 6:
                                // BKE_curvemap_evaluateF: linear between entries.
                                let position = t * Float(tableLast)
                                let i = min(Int(position), tableLast - 1)
                                let fraction = position - Float(i)
                                falloff = (1 - fraction) * table[i] + fraction * table[i + 1]
                            default: falloff = 0
                            }
                            falloff = max(0, min(1, falloff))
                            if !(falloff > 0) { continue }

                            let custom = customs[k]
                            let ui = Int(images[k]), texel = Int(texels[k])
                            let isFloat = imageIsFloat[ui]
                            let base = bases[ui], fbase = floatBases[ui]
                            let o = texel * 4
                            let oo = 4 * k

                            switch tool {
                            case .draw:
                                // Opacity masking: each texel approaches the
                                // strength and never passes it, however many
                                // dabs of the stroke cross it.
                                let maxMask = alpha * custom * falloff * 65535
                                let before = Float(accumulated[k])
                                let mask = min(before + (maxMask - before * falloff), 65535)
                                let mask16 = UInt16(max(0, mask))
                                if mask16 <= accumulated[k] { continue }
                                accumulated[k] = mask16
                                // From the stored, truncated value, as Blender
                                // takes it: `mask_short * (1.0f / 65535.0f)`.
                                let m = Float(mask16) * (1 / 65535)
                                if isFloat {
                                    // do_projectpaint_draw_f: the linear colour
                                    // premultiplied by the mask, blended over
                                    // the texel as it was before the stroke.
                                    BlenderColor.blendFloat(blend, fbase + o, UnsafePointer(originalFloats + oo),
                                                            linR * m, linG * m, linB * m, m)
                                    noteWrite(ui, texel)
                                    painted += 1
                                    continue
                                }
                                let t8 = Int(BlenderColor.byte(m))
                                if blend == .mix {
                                    // blend_color_mix_byte, over the texel as
                                    // it was before the stroke.
                                    if t8 == 0 {
                                        base[o] = originals[oo]; base[o + 1] = originals[oo + 1]
                                        base[o + 2] = originals[oo + 2]; base[o + 3] = originals[oo + 3]
                                    } else {
                                        let mt = 255 - t8, a1 = Int(originals[oo + 3])
                                        let total = mt * a1 + t8 * 255
                                        let twice = 2 * total
                                        base[o] = UInt8(truncatingIfNeeded:
                                            (2 * (mt * a1 * Int(originals[oo]) + t8 * 255 * colourR) + total) / twice)
                                        base[o + 1] = UInt8(truncatingIfNeeded:
                                            (2 * (mt * a1 * Int(originals[oo + 1]) + t8 * 255 * colourG) + total) / twice)
                                        base[o + 2] = UInt8(truncatingIfNeeded:
                                            (2 * (mt * a1 * Int(originals[oo + 2]) + t8 * 255 * colourB) + total) / twice)
                                        base[o + 3] = UInt8(truncatingIfNeeded: (2 * total + 255) / 510)
                                    }
                                } else {
                                    let out = BlenderColor.blend(
                                        blend,
                                        Texel(originals[oo], originals[oo + 1], originals[oo + 2], originals[oo + 3]),
                                        Texel(colour.r, colour.g, colour.b, UInt8(t8)))
                                    base[o] = out.r; base[o + 1] = out.g; base[o + 2] = out.b; base[o + 3] = out.a
                                }
                                noteWrite(ui, texel)
                                painted += 1

                            case .soften:
                                // A 2×2 kernel one pixel out on each diagonal,
                                // equal weights (`paint_new_blur_kernel` for
                                // projection painting), sampled premultiplied
                                // and clamped to 0…1 as project_paint_PickColor
                                // hands them over.
                                let mask = alpha * custom * falloff
                                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0, samples: Float = 0
                                for corner in 0..<4 {
                                    let ox: Float = corner & 1 == 0 ? -1 : 1
                                    let oy: Float = corner & 2 == 0 ? -1 : 1
                                    guard let picked = pickFloat(view, xs[k] + ox, ys[k] + oy,
                                                                 prefer: Int(faces[k]), bases, floatBases)
                                    else { continue }
                                    r += picked.0; g += picked.1; b += picked.2; a += picked.3
                                    samples += 1
                                }
                                if samples == 0 { continue }
                                let inverse = 1 / samples
                                r *= inverse; g *= inverse; b *= inverse; a *= inverse
                                if isFloat {
                                    // do_projectpaint_soften_f:
                                    // blend_color_interpolate_float.
                                    let mt = 1 - mask
                                    laterFloatImage.append(ui)
                                    laterFloatTexel.append(texel)
                                    laterFloat.append(mt * fbase[o] + mask * r)
                                    laterFloat.append(mt * fbase[o + 1] + mask * g)
                                    laterFloat.append(mt * fbase[o + 2] + mask * b)
                                    laterFloat.append(mt * fbase[o + 3] + mask * a)
                                } else {
                                    // do_projectpaint_soften: the average as a
                                    // straight byte, then blend_color_interpolate_byte.
                                    let average = BlenderColor.straight(SIMD4(r, g, b, a))
                                    let out = BlenderColor.interpolate(
                                        Texel(base[o], base[o + 1], base[o + 2], base[o + 3]), average, mask)
                                    laterImage.append(ui)
                                    laterTexel.append(texel)
                                    laterValue.append(out.r); laterValue.append(out.g)
                                    laterValue.append(out.b); laterValue.append(out.a)
                                }

                            case .smear:
                                // The colour from where the brush was one dab
                                // ago, carried to where it is now.
                                let mask = alpha * custom * falloff
                                if isFloat {
                                    guard let from = pickFloat(view, xs[k] - offsetX, ys[k] - offsetY,
                                                               prefer: Int(faces[k]), bases, floatBases)
                                    else { continue }
                                    // do_projectpaint_smear_f.
                                    let mt = 1 - mask
                                    laterFloatImage.append(ui)
                                    laterFloatTexel.append(texel)
                                    laterFloat.append(mt * fbase[o] + mask * from.0)
                                    laterFloat.append(mt * fbase[o + 1] + mask * from.1)
                                    laterFloat.append(mt * fbase[o + 2] + mask * from.2)
                                    laterFloat.append(mt * fbase[o + 3] + mask * from.3)
                                } else {
                                    guard let from = pickTexel(view, xs[k] - offsetX, ys[k] - offsetY,
                                                               prefer: Int(faces[k]), bases, floatBases)
                                    else { continue }
                                    let out = BlenderColor.interpolate(
                                        Texel(base[o], base[o + 1], base[o + 2], base[o + 3]), from, mask)
                                    laterImage.append(ui)
                                    laterTexel.append(texel)
                                    laterValue.append(out.r); laterValue.append(out.g)
                                    laterValue.append(out.b); laterValue.append(out.a)
                                }
                            }
                        }
                    }
                }

                for i in 0..<laterImage.count {
                    let base = bases[laterImage[i]]
                    let o = laterTexel[i] * 4
                    base[o] = laterValue[4 * i]; base[o + 1] = laterValue[4 * i + 1]
                    base[o + 2] = laterValue[4 * i + 2]; base[o + 3] = laterValue[4 * i + 3]
                    noteWrite(laterImage[i], laterTexel[i])
                    painted += 1
                }
                for i in 0..<laterFloatImage.count {
                    let fbase = floatBases[laterFloatImage[i]]
                    let o = laterFloatTexel[i] * 4
                    fbase[o] = laterFloat[4 * i]; fbase[o + 1] = laterFloat[4 * i + 1]
                    fbase[o + 2] = laterFloat[4 * i + 2]; fbase[o + 3] = laterFloat[4 * i + 3]
                    noteWrite(laterFloatImage[i], laterFloatTexel[i])
                    painted += 1
                }
            }
        }
        paintedTexels += painted
    }

    // MARK: - Picking colour

    /// Where a screen point lands in an image — the face and UV behind
    /// `project_paint_PickColor`. The face the texel itself came from is tried
    /// first; a sample one pixel away is almost always still on it.
    private func pickUV(_ view: View, _ px: Float, _ py: Float, prefer: Int) -> (image: Int, u: Float, v: Float)? {
        guard px >= 0, py >= 0, px < screenWidth, py < screenHeight else { return nil }
        let fd = view.face, stride = Self.faceStride
        var face = -1
        var m0: Float = 0, m1: Float = 0, m2: Float = 0
        if let own = Self.barycentric(fd, prefer, px, py) {
            face = prefer
            (m0, m1, m2) = own
        } else {
            // `project_paint_PickFace`: the nearest face in the bucket.
            let bx = min(view.bucketsX - 1, Int(px / view.bucketW))
            let by = min(view.bucketsY - 1, Int(py / view.bucketH))
            var bestNear = -Float.greatestFiniteMagnitude
            for g32 in view.faces[by * view.bucketsX + bx] {
                let g = Int(g32)
                guard let found = Self.barycentric(fd, g, px, py) else { continue }
                let go = stride * g
                let near = found.0 * fd[go + 7] + found.1 * fd[go + 8] + found.2 * fd[go + 9]
                if near > bestNear {
                    bestNear = near
                    face = g
                    (m0, m1, m2) = found
                }
            }
            guard face >= 0 else { return nil }
        }

        // The UV there, perspective-corrected.
        let i0 = Int(indices[3 * face]), i1 = Int(indices[3 * face + 1]), i2 = Int(indices[3 * face + 2])
        let w0 = m0 * view.inverseW[i0], w1 = m1 * view.inverseW[i1], w2 = m2 * view.inverseW[i2]
        let sum = w0 + w1 + w2
        var u = uvs[6 * face], v = uvs[6 * face + 1]
        if sum != 0 {
            u = (uvs[6 * face] * w0 + uvs[6 * face + 2] * w1 + uvs[6 * face + 4] * w2) / sum
            v = (uvs[6 * face + 1] * w0 + uvs[6 * face + 3] * w1 + uvs[6 * face + 5] * w2) / sum
        }
        let ui = Int(triangleImage[face])
        guard ui >= 0 else { return nil }
        return (ui, u, v)
    }

    /// `project_paint_PickColor` for bytes: a byte image's own bilinear bytes,
    /// or a float image's clamped sample as straight bytes.
    private func pickTexel(_ view: View, _ px: Float, _ py: Float, prefer: Int,
                           _ bases: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>,
                           _ floatBases: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) -> Texel? {
        guard let at = pickUV(view, px, py, prefer: prefer) else { return nil }
        if imageIsFloat[at.image] {
            let c = sampleFloat(at.image, at.u, at.v, floatBases)
            return BlenderColor.straight(SIMD4(c.0, c.1, c.2, c.3))
        }
        return sample(at.image, at.u, at.v, bases)
    }

    /// `project_paint_PickColor` for floats: premultiplied, a float image's
    /// sample clamped to 0…1, a byte image's through
    /// `straight_uchar_to_premul_float`.
    private func pickFloat(_ view: View, _ px: Float, _ py: Float, prefer: Int,
                           _ bases: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>,
                           _ floatBases: UnsafeMutablePointer<UnsafeMutablePointer<Float>>)
        -> (Float, Float, Float, Float)? {
        guard let at = pickUV(view, px, py, prefer: prefer) else { return nil }
        if imageIsFloat[at.image] { return sampleFloat(at.image, at.u, at.v, floatBases) }
        let t = sample(at.image, at.u, at.v, bases)
        let alpha = Float(t.a) * (1 / 255)
        let fac = alpha * (1 / 255)
        return (Float(t.r) * fac, Float(t.g) * fac, Float(t.b) * fac, alpha)
    }

    /// Screen barycentrics of a point in a view's triangle `g`, when it is
    /// inside, edges included as `isect_point_tri_v2` counts them. A function
    /// of its own rather than a closure over the caller's variables: those
    /// are heap-allocated on every call in an unoptimised build.
    private static func barycentric(_ fd: UnsafeMutablePointer<Float>, _ g: Int,
                                    _ px: Float, _ py: Float) -> (Float, Float, Float)? {
        let go = faceStride * g
        guard abs(fd[go + 15]) > 1e-12 else { return nil }
        let dx = px - fd[go], dy = py - fd[go + 1]
        let m1 = (dx * fd[go + 5] - dy * fd[go + 4]) * fd[go + 6]
        let m2 = (fd[go + 2] * dy - fd[go + 3] * dx) * fd[go + 6]
        let m0 = 1 - m1 - m2
        guard m0 >= -1e-5, m1 >= -1e-5, m2 >= -1e-5 else { return nil }
        return (m0, m1, m2)
    }

    /// The four texels around a UV and the weights between them, with
    /// `uvco_to_wrapped_pxco`'s half-texel offset, wrapping as
    /// `InterpWrapMode::Repeat` does. Rows counted from the bottom.
    private func around(_ ui: Int, _ uIn: Float, _ vIn: Float)
        -> (x1: Int, x2: Int, y1: Int, y2: Int, a: Float, b: Float) {
        let width = imageWidth[ui], height = imageHeight[ui]
        var u = uIn.truncatingRemainder(dividingBy: 1)
        if u < 0 { u += 1 }
        var v = vIn.truncatingRemainder(dividingBy: 1)
        if v < 0 { v += 1 }
        var x = (u * Float(width) - 0.5).truncatingRemainder(dividingBy: Float(width))
        if x < 0 { x += Float(width) }
        var y = (v * Float(height) - 0.5).truncatingRemainder(dividingBy: Float(height))
        if y < 0 { y += Float(height) }
        let x1 = min(width - 1, Self.index(x, width - 1)), y1 = min(height - 1, Self.index(y, height - 1))
        let x2 = x1 + 1 >= width ? 0 : x1 + 1
        let y2 = y1 + 1 >= height ? 0 : y1 + 1
        return (x1, x2, y1, y2, x - Float(x1), y - Float(y1))
    }

    /// `imbuf::interpolate_bilinear_wrap_byte` at a UV.
    private func sample(_ ui: Int, _ u: Float, _ v: Float,
                        _ bases: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>) -> Texel {
        let width = imageWidth[ui], height = imageHeight[ui]
        let (x1, x2, y1, y2, a, b) = around(ui, u, v)
        let base = bases[ui]
        // Rows are stored top first; Blender's y counts from the bottom.
        let r1 = (height - 1 - y1) * width, r2 = (height - 1 - y2) * width
        let p11 = (r1 + x1) * 4, p21 = (r1 + x2) * 4, p12 = (r2 + x1) * 4, p22 = (r2 + x2) * 4
        let w11 = (1 - a) * (1 - b), w21 = a * (1 - b), w12 = (1 - a) * b, w22 = a * b
        func channel(_ k: Int) -> UInt8 {
            let value = w11 * Float(base[p11 + k]) + w21 * Float(base[p21 + k])
                + w12 * Float(base[p12 + k]) + w22 * Float(base[p22 + k])
            return UInt8(min(255, max(0, value + 0.5)))
        }
        return Texel(channel(0), channel(1), channel(2), channel(3))
    }

    /// `imbuf::interpolate_bilinear_wrap_fl` at a UV, clamped to 0…1 as
    /// `project_paint_PickColor` clamps it.
    private func sampleFloat(_ ui: Int, _ u: Float, _ v: Float,
                             _ floatBases: UnsafeMutablePointer<UnsafeMutablePointer<Float>>)
        -> (Float, Float, Float, Float) {
        let width = imageWidth[ui], height = imageHeight[ui]
        let (x1, x2, y1, y2, a, b) = around(ui, u, v)
        let base = floatBases[ui]
        let r1 = (height - 1 - y1) * width, r2 = (height - 1 - y2) * width
        let p11 = (r1 + x1) * 4, p21 = (r1 + x2) * 4, p12 = (r2 + x1) * 4, p22 = (r2 + x2) * 4
        let maMb = (1 - a) * (1 - b), aMb = a * (1 - b), maB = (1 - a) * b, aB = a * b
        func channel(_ k: Int) -> Float {
            let value = maMb * base[p11 + k] + aMb * base[p21 + k] + maB * base[p12 + k] + aB * base[p22 + k]
            return min(max(value, 0), 1)
        }
        return (channel(0), channel(1), channel(2), channel(3))
    }

    // MARK: - Bookkeeping

    private func noteWrite(_ ui: Int, _ texel: Int) {
        imagePainted[ui] = true
        let width = imageWidth[ui]
        let x = texel % width, y = texel / width
        let d = dirty + 4 * ui
        if x < d[0] { d[0] = x }
        if y < d[1] { d[1] = y }
        if x > d[2] { d[2] = x }
        if y > d[3] { d[3] = y }
    }

    /// Tells each painted image which rectangle changed, for the GPU copy —
    /// remaking a float image's display bytes there first.
    private func flushChanges() {
        for ui in uniqueImages.indices {
            let d = dirty + 4 * ui
            guard d[2] >= 0 else { continue }
            if imageIsFloat[ui] {
                TexturePaintPixels.refreshDisplay(uniqueImages[ui], x0: d[0], y0: d[1], x1: d[2], y1: d[3])
            }
            uniqueImages[ui].noteChanged(x0: d[0], y0: d[1], x1: d[2], y1: d[3])
            d[0] = Int.max; d[1] = Int.max; d[2] = -1; d[3] = -1
        }
    }

    /// Every distinct image's bytes, and a float image's floats, held for the
    /// length of one dab.
    private func withPixels(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>,
                                     UnsafeMutablePointer<UnsafeMutablePointer<Float>>) -> Void) {
        let count = uniqueImages.count
        let bases = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>.allocate(capacity: count)
        let floatBases = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: count)
        defer { bases.deallocate(); floatBases.deallocate() }
        func hold(_ i: Int) {
            if i == count { body(bases, floatBases); return }
            uniqueImages[i].withMutablePixels { buffer in
                guard let base = buffer.baseAddress else { return }
                bases[i] = base
                guard imageIsFloat[i] else {
                    floatBases[i] = noFloats
                    hold(i + 1)
                    return
                }
                uniqueImages[i].withMutableFloats { floats in
                    guard let fbase = floats.baseAddress else { return }
                    floatBases[i] = fbase
                    hold(i + 1)
                }
            }
        }
        hold(0)
    }
}
