import UIKit
import simd

// Shift+B's gesture in the 3D View: the box, and the zoom when it lets go
// (the camera's half is ZoomRegion.swift).

extension MetalViewportView.Coordinator {

    /// Shift+B: the next drag draws the box (Blender waits for the press,
    /// `wait_for_input`). The view takes the keys meanwhile, Escape cancelling.
    func beginZoomRegion() {
        guard modal == nil, gizmo == nil, regionGesture == nil, let mtk = view as? ViewportMTKView else { return }
        zoomRegionPending = true
        zoomRegionStart = nil
        mtk.modal = self
        mtk.takeKeyboard()
        parent.scene.beginViewportDrag(.zoom, "Zoom Region")
    }

    /// A drag while Shift+B waits: the box from where it went down to where
    /// it is, and the zoom when it lets go. True when it took the gesture.
    func zoomRegionDrag(_ g: UIPanGestureRecognizer) -> Bool {
        guard zoomRegionPending || zoomRegionStart != nil, let view else { return false }
        let here = g.location(in: view)
        switch g.state {
        case .began:
            let t = g.translation(in: view)
            zoomRegionPending = false
            zoomRegionStart = CGPoint(x: here.x - t.x, y: here.y - t.y)
            parent.scene.selectionBox = BoxSelect.rect(from: zoomRegionStart!, to: here)
        case .changed:
            if let start = zoomRegionStart { parent.scene.selectionBox = BoxSelect.rect(from: start, to: here) }
        case .ended:
            endZoomRegion(zoomRegionStart.map { BoxSelect.rect(from: $0, to: here) })
        default:
            endZoomRegion(nil)
        }
        return true
    }

    /// Ends Shift+B, zooming in on `box` (view points), or with nil as it was.
    func endZoomRegion(_ box: CGRect?) {
        zoomRegionPending = false
        zoomRegionStart = nil
        parent.scene.selectionBox = nil
        parent.scene.endViewportDrag(.zoom)
        if let mtk = view as? ViewportMTKView, mtk.modal === self, modal == nil { mtk.modal = nil }
        guard let box, let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let size = view.bounds.size
        let camera = currentCamera
        guard let zoomed = camera.zoomedIn(on: box, size: size, depth: zoomRegionDepth(box, camera: camera, size: size))
        else {
            // Blender's report, in perspective with nothing under the box.
            if !camera.isOrthographic { parent.bridge?.showReport("Zoom Region", "Depth too large") }
            return
        }
        moveCamera(.zoom, readout: Self.zoomReadout) { $0 = zoomed }
        endCameraMove(.zoom)
    }

    /// The nearest surface's depth inside the box (`CursorTool.nearestDepth`):
    /// its vertices, and a 3 × 3 grid of rays across it, the middle among them.
    private func zoomRegionDepth(_ box: CGRect, camera: ViewportCamera, size: CGSize) -> Float? {
        let aspect = Float(size.width / size.height)
        let view = GeometrySnap.View(viewProjection: camera.viewProjection(aspect: aspect),
                                     size: SIMD2(Float(size.width), Float(size.height)))
        var rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)] = []
        let steps = 2
        for i in 0...steps {
            for j in 0...steps {
                let p = SIMD2(Float(box.minX + box.width * CGFloat(i) / CGFloat(steps)),
                              Float(box.minY + box.height * CGFloat(j) / CGFloat(steps)))
                if let ray = view.ray(p) { rays.append(ray) }
            }
        }
        let window = (lo: SIMD2(Float(box.minX), Float(box.minY)), hi: SIMD2(Float(box.maxX), Float(box.maxY)))
        let forward = simd_normalize(camera.target - camera.eye)
        return CursorTool.nearestDepth(objects: parent.scene.objects, rays: rays, window: window, view: view,
                                       eye: camera.eye, forward: forward)
    }
}
