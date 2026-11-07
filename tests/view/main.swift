import Foundation
import CoreGraphics
import simd

// The view's own keys build 58 added (docs/blender-local.md, "November 8"),
// held to Blender 5.2.1: Roll Left and Right (`view3d.view_roll`), Align View
// to Active (`view3d.view_axis` with align_active) and Zoom Region
// (`view3d.zoom_border`). The numbers Blender gave are its own, measured with
// a 3D View override in desktop Blender (the session's notes): from Front,
// Roll Right took world X to the screen's (0.966, -0.259); an object turned
// (0.3, 0.2, 0.7) aligned the views as below.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func near(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) <= eps }
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-3) -> Bool { simd_distance(a, b) <= eps }
func f(_ v: SIMD3<Float>) -> String { String(format: "(%.4f, %.4f, %.4f)", v.x, v.y, v.z) }
let step: Float = 15 * .pi / 180

print("== Roll (view3d.view_roll) ==")
do {
    var c = ViewportCamera()
    c.snap(to: .front)
    c.roll(by: step)
    let x = SIMD3<Float>(1, 0, 0)
    let screen = SIMD2(simd_dot(x, c.right), simd_dot(x, c.trueUp))
    check("Roll Right from Front: world X to (0.966, -0.259), as Blender's",
          near(screen.x, 0.9659) && near(screen.y, -0.2588), "\(screen)")
    let back = simd_normalize(c.eye - c.target)
    check("the eye stays where it was", near(back, SIMD3(0, -1, 0)), f(back))
    check("right, up and back stay square",
          near(simd_dot(c.right, c.trueUp), 0, 1e-5) && near(simd_dot(c.right, back), 0, 1e-5))
    c.roll(by: -2 * step)
    check("Roll Left twice back: the other way", near(c.roll, -step, 1e-6), "\(c.roll)")
    c.roll(by: 200 * .pi / 180)
    check("past a half turn it wraps", c.roll > -.pi && c.roll <= .pi, "\(c.roll)")
    c.snap(to: .top)
    check("an axis view takes the roll away", c.roll == 0)
    var o = ViewportCamera()
    o.roll(by: step)
    let before = o.roll
    o.orbit(dx: 0.3, dy: 0.1)
    check("orbiting keeps it", o.roll == before)
}

print("== Align View to Active (view3d.view_axis, align_active) ==")
do {
    // Blender's object turned (0.3, 0.2, 0.7): its world axes.
    let ox = SIMD3<Float>(0.7496, 0.6314, -0.1987)
    let oy = SIMD3<Float>(-0.5705, 0.7685, 0.2896)
    let oz = SIMD3<Float>(0.3355, -0.1038, 0.9363)
    let axes = simd_float3x3(ox, oy, oz)
    func aligned(_ v: ViewportCamera.Viewpoint) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        var c = ViewportCamera()
        c.align(v, to: axes)
        return (c.right, c.trueUp, simd_normalize(c.eye - c.target))
    }
    var (r, u, b) = aligned(.front)
    check("Front: its X right, its Z up, its -Y toward the eye", near(r, ox) && near(u, oz) && near(b, -oy),
          f(r) + f(u) + f(b))
    (r, u, b) = aligned(.top)
    check("Top: X right, Y up, Z toward the eye", near(r, ox) && near(u, oy) && near(b, oz), f(r) + f(u) + f(b))
    (r, u, b) = aligned(.right)
    check("Right: Y right, Z up, X toward the eye", near(r, oy) && near(u, oz) && near(b, ox), f(r) + f(u) + f(b))
    (r, u, b) = aligned(.bottom)
    check("Bottom: X right, -Y up, -Z toward the eye", near(r, ox) && near(u, -oy) && near(b, -oz),
          f(r) + f(u) + f(b))
    var c = ViewportCamera()
    c.target = SIMD3(1, 2, 3)
    c.distance = 7
    c.align(.front, to: matrix_identity_float3x3)
    check("unturned, Front aligned is Front", near(c.right, SIMD3(1, 0, 0)) && near(c.trueUp, SIMD3(0, 0, 1)))
    check("the centre and the distance stay", c.target == SIMD3(1, 2, 3) && c.distance == 7)
}

print("== Zoom Region (view3d.zoom_border) ==")
do {
    let size = CGSize(width: 1000, height: 500)
    check("a square box widened to the view's shape",
          ViewportCamera.zoomRegionRect(CGRect(x: 100, y: 100, width: 100, height: 100), size: size)
            == CGRect(x: 50, y: 100, width: 200, height: 100))
    check("a wide box made taller", ViewportCamera.zoomRegionRect(CGRect(x: 0, y: 0, width: 400, height: 100), size: size)
            == CGRect(x: 0, y: -50, width: 400, height: 200))
    var ortho = ViewportCamera()
    ortho.snap(to: .front)
    ortho.distance = 10
    let middle = CGRect(x: 250, y: 125, width: 500, height: 250)
    let zoomed = ortho.zoomedIn(on: middle, size: size, depth: nil)
    check("orthographic: half the view across is half the distance, the centre kept",
          zoomed.map { near($0.distance, 5) && near($0.target, ortho.target) } == true,
          zoomed.map { "\($0.distance) \(f($0.target))" } ?? "nil")
    let corner = ortho.zoomedIn(on: CGRect(x: 0, y: 0, width: 500, height: 250), size: size, depth: nil)
    let half = Float(10 * tan(ortho.fovY / 2))
    check("orthographic: a corner box moves the centre to its middle",
          corner.map { near($0.target, ortho.target + SIMD3(-half, 0, half / 2)) } == true,
          corner.map { f($0.target) } ?? "nil")
    var persp = ViewportCamera()
    persp.snap(to: .front)
    persp.isOrthographic = false
    persp.distance = 10
    check("perspective with nothing under the box: nothing (Depth too large)",
          persp.zoomedIn(on: middle, size: size, depth: nil) == nil)
    if let z = persp.zoomedIn(on: middle, size: size, depth: 10) {
        // At depth 10 the box's half-diagonal; the zoomed view's longer half
        // spans exactly that (Blender's lens over its 36 mm sensor, zoom 2).
        let p = persp.point(at: CGPoint(x: 500, y: 250), depth: 10, size: size)!
        let c = persp.point(at: CGPoint(x: 250, y: 375), depth: 10, size: size)!
        let halfDiagonal = simd_distance(p, c)
        let shown = z.distance * tan(z.fovY / 2) * Float(size.width / size.height)
        check("perspective: the view's longer half spans the box's half-diagonal",
              near(shown, halfDiagonal, 1e-3), "\(shown) \(halfDiagonal)")
        check("perspective: centred on the box's middle at that depth", near(z.target, p, 1e-4), f(z.target))
    } else {
        check("perspective zoom", false, "nil")
    }
    check("a box with no area: nothing", persp.zoomedIn(on: CGRect(x: 5, y: 5, width: 0, height: 9), size: size,
                                                        depth: 3) == nil)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
