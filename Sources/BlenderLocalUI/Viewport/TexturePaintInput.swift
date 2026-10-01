import UIKit
import MetalKit
import simd

/// A texture-paint stroke in progress in one viewport.
///
/// Blender's paint operators need a 3D View region, and the bpy module on an
/// iPad has none, so the stroke is painted here — into the viewport's copy of
/// the images, where it shows as it happens — and handed to Blender once, when
/// the touch lifts.
final class TexturePaintInput {
    var stroke: TexturePaintStroke?
    weak var object: BKObject?
    /// Seam flags for the surface last painted, kept while it and its mesh
    /// stay the same: working them out walks every triangle.
    var seams: (object: UUID, surface: Int, mesh: Int, flags: TexturePaintSeams)?
}

/// Entering Texture Paint and keeping its strokes, through bpy.
enum TexturePaintSetup {

    /// Objects entering could not make paintable, with the mesh version they
    /// had then, so touching one again does not send Blender the same request
    /// — and the scene through a mirroring pass — on every touch.
    nonisolated(unsafe) private static var refused: [UUID: Int] = [:]

    /// Gives the object a UV map and an image to paint if it lacks either —
    /// Blender's Add Simple UVs and Add Paint Slot, run in Blender or by the
    /// simulator's stand-in — and returns whether it can now be painted.
    @discardableResult
    static func prepare(_ obj: BKObject, scene: BKScene, bridge: BpyBridge?) -> Bool {
        guard obj.paintTarget == nil else { return true }
        guard let bridge, obj.blenderType == "MESH" else { return false }
        // A script is running — one that switched to Texture Paint, say — and
        // the bridge runs nothing until it ends. That is not a refusal, which
        // would turn away every stroke until the mesh changed; the 3D View
        // tries again when the script finishes.
        guard !bridge.isRunningScript else { return false }
        bridge.enterTexturePaint(object: obj.name)
        let ready = obj.paintTarget != nil
        refused[obj.id] = ready ? nil : obj.meshVersion
        return ready
    }

    /// The same when a stroke starts, except for an object that was refused
    /// and has not changed since.
    static func prepareForStroke(_ obj: BKObject, scene: BKScene, bridge: BpyBridge?) -> Bool {
        guard obj.paintTarget == nil else { return true }
        if refused[obj.id] == obj.meshVersion { return false }
        return prepare(obj, scene: scene, bridge: bridge)
    }

    /// Writes a finished stroke's images into Blender, packed, as one
    /// "Texture Paint" undo step.
    static func keep(_ images: [TextureImage], bridge: BpyBridge?) {
        guard let bridge, !images.isEmpty else { return }
        bridge.keepTexturePaint(TexturePaintBpy.write(images: images.map(\.name)))
    }
}

extension MetalViewportView.Coordinator {

    /// A finger or Pencil drag in Texture Paint: the whole stroke, from touch
    /// down to lift. Returns false, having done nothing, in any other mode.
    func handleTexturePaint(_ g: UIPanGestureRecognizer, pressure: Float) -> Bool {
        guard parent.scene.mode == .texturePaint, let view else { return false }
        switch g.state {
        case .began:
            // A pan is recognised only once the touch has travelled a little;
            // the stroke starts where it came down, as Blender's does.
            let now = g.location(in: view)
            let travelled = g.translation(in: view)
            beginTexturePaint(at: CGPoint(x: now.x - travelled.x, y: now.y - travelled.y),
                              in: view, pressure: pressure)
            moveTexturePaint(to: now, pressure: pressure)
        case .changed:
            moveTexturePaint(to: g.location(in: view), pressure: pressure)
        case .ended:
            moveTexturePaint(to: g.location(in: view), pressure: pressure)
            endTexturePaint()
        case .cancelled, .failed:
            // Interrupted, but what it painted still happened, and is kept.
            endTexturePaint()
        default:
            break
        }
        return true
    }

    /// A tap in Texture Paint is a stroke of one dab, as a click is in Blender.
    func texturePaintTap(_ g: UITapGestureRecognizer) -> Bool {
        guard parent.scene.mode == .texturePaint, let view else { return false }
        beginTexturePaint(at: g.location(in: view), in: view, pressure: 1)
        endTexturePaint()
        return true
    }

    private func beginTexturePaint(at point: CGPoint, in view: MTKView, pressure: Float) {
        endTexturePaint()
        let scene = parent.scene
        guard let obj = scene.active, obj.visible else { return }
        // Entering made the canvas; an object made active since, or a mesh
        // whose topology changed, gets one now.
        if obj.paintTarget == nil {
            _ = TexturePaintSetup.prepareForStroke(obj, scene: scene, bridge: parent.bridge)
        }
        let bounds = view.bounds
        guard let target = obj.paintTarget, bounds.width > 0, bounds.height > 0 else { return }

        let camera = parent.camera
        // Blender measures the brush in region pixels, so the stroke is told
        // how many of the drawable's pixels make a point.
        let pixelsPerPoint = view.drawableSize.width > 0
            ? Float(view.drawableSize.width / bounds.width) : Float(view.contentScaleFactor)
        let paintCamera = TexturePaintCamera(
            viewProjection: camera.viewProjection(aspect: Float(bounds.width / bounds.height)),
            size: SIMD2(Float(bounds.width), Float(bounds.height)),
            eye: camera.eye,
            forward: simd_normalize(camera.target - camera.eye),
            isOrthographic: camera.isOrthographic,
            pixelsPerPoint: pixelsPerPoint)
        let paintTarget = TexturePaintTarget(
            positions: obj.mesh.vertices.map(\.position), indices: obj.mesh.indices,
            cornerUVs: target.surface.cornerUVs, triangleSlots: target.surface.triangleSlots,
            images: target.images, model: obj.modelMatrix, symmetry: obj.symmetry,
            seams: seams(for: obj, target.surface))
        let tool = parent.tool.texturePaintTool ?? .draw
        guard let stroke = TexturePaintStroke(target: paintTarget, camera: paintCamera,
                                              settings: scene.paint.texturePaint, tool: tool)
        else { return }
        texturePaintInput.stroke = stroke
        texturePaintInput.object = obj
        stroke.begin(at: SIMD2(Float(point.x), Float(point.y)), pressure: pressure)
        scene.beginViewportDrag(.brush, "Texture Paint  \(parent.tool.label)")
    }

    private func moveTexturePaint(to point: CGPoint, pressure: Float) {
        texturePaintInput.stroke?.move(to: SIMD2(Float(point.x), Float(point.y)), pressure: pressure)
    }

    /// The touch lifted: whatever the stroke painted goes into Blender.
    func endTexturePaint() {
        guard let stroke = texturePaintInput.stroke else { return }
        texturePaintInput.stroke = nil
        texturePaintInput.object = nil
        parent.scene.endViewportDrag(.brush)
        guard stroke.paintedTexels > 0 else { return }
        TexturePaintSetup.keep(stroke.paintedImages, bridge: parent.bridge)
    }

    #if DEBUG
    /// Debug builds accept `-paint-stroke`: once the active object has a canvas
    /// in Texture Paint, one stroke is painted across the middle of the view
    /// through the calls a drag makes, and kept as a lift keeps it. The
    /// simulator's command line cannot drag, and this is how painting gets
    /// photographed rather than only its setup.
    func paintLaunchStrokeIfRequested(tries: Int = 60) {
        guard ProcessInfo.processInfo.arguments.contains("-paint-stroke") else { return }
        guard tries > 0 else {
            print("[bk] paint-stroke: no canvas to paint")
            fflush(stdout)
            return
        }
        guard let view, parent.scene.mode == .texturePaint,
              parent.scene.active?.paintTarget != nil,
              parent.bridge?.isRunningScript == false,
              view.bounds.width > 0
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.paintLaunchStrokeIfRequested(tries: tries - 1)
            }
            return
        }
        let b = view.bounds
        let from = CGPoint(x: b.midX - b.width * 0.18, y: b.midY - b.height * 0.06)
        let to = CGPoint(x: b.midX + b.width * 0.18, y: b.midY + b.height * 0.04)
        beginTexturePaint(at: from, in: view, pressure: 1)
        for step in 1...48 {
            let t = CGFloat(step) / 48
            moveTexturePaint(to: CGPoint(x: from.x + (to.x - from.x) * t,
                                         y: from.y + (to.y - from.y) * t), pressure: 1)
        }
        let painted = texturePaintInput.stroke?.paintedTexels ?? 0
        endTexturePaint()
        print("[bk] paint-stroke: \(painted) texels painted")
        fflush(stdout)
    }
    #endif

    private func seams(for obj: BKObject, _ surface: PaintSurface) -> TexturePaintSeams {
        if let cached = texturePaintInput.seams, cached.object == obj.id,
           cached.surface == surface.version, cached.mesh == obj.meshVersion {
            return cached.flags
        }
        let flags = TexturePaintSeams(indices: obj.mesh.indices, cornerUVs: surface.cornerUVs,
                                      triangleSlots: surface.triangleSlots, slotImages: surface.slotImages)
        texturePaintInput.seams = (obj.id, surface.version, obj.meshVersion, flags)
        return flags
    }
}
