import Foundation
import simd
import CoreGraphics

var failures = 0
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-3) -> Bool {
    abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

let size = CGSize(width: 800, height: 600)
var camera = ViewportCamera()
camera.target = .zero
camera.distance = 12
let vp = camera.viewProjection(aspect: Float(size.width / size.height))

/// A unit cube centred on a point.
func cube(_ name: String, at c: SIMD3<Float>, half: Float = 0.5, visible: Bool = true)
-> (name: String, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), visible: Bool) {
    (name, (c - SIMD3(repeating: half), c + SIMD3(repeating: half)), visible)
}

func cube2(_ name: String, lo: SIMD3<Float>, hi: SIMD3<Float>)
-> (name: String, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), visible: Bool) {
    (name, (lo, hi), true)
}

func selected(_ rect: CGRect, _ objs: [(name: String, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), visible: Bool)]) -> [String] {
    BoxSelect.objects(in: rect, objects: objs, viewProjection: vp, size: size)
}

print("== a rectangle over the whole view takes everything visible ==")
let scene = [cube("A", at: SIMD3(-3, 0, 0)), cube("B", at: .zero), cube("C", at: SIMD3(3, 0, 0))]
let all = selected(CGRect(x: 0, y: 0, width: 800, height: 600), scene)
check("all three", Set(all) == ["A", "B", "C"], "\(all)")

print("\n== it selects what it covers, and nothing else ==")
// Find where each cube lands so the test does not assume a camera angle.
let centres = scene.map { o -> (String, CGPoint) in
    let mid = (o.bounds.min + o.bounds.max) / 2
    return (o.name, BoxSelect.project(mid, viewProjection: vp, size: size) ?? .zero)
}
for (name, point) in centres {
    let tight = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
    let got = selected(tight, scene)
    check("a small box on \(name) takes \(name)", got == [name], "\(got)")
}

print("\n== an object counts when any part is inside, not just its origin ==")
// A wide slab whose centre is off to the left of the drag.
let slab = [cube2("Slab", lo: SIMD3<Float>(-6, -0.5, -0.5), hi: SIMD3<Float>(6, 0.5, 0.5))]
let originPoint = BoxSelect.project(.zero, viewProjection: vp, size: size)!
let overRightEnd = CGRect(x: originPoint.x + 60, y: originPoint.y - 20, width: 60, height: 40)
let slabHit = selected(overRightEnd, slab)
check("a drag over one end of a long object selects it", slabHit == ["Slab"], "\(slabHit)")

print("\n== hidden objects are not selected ==")
let mixed = [cube("Shown", at: .zero), cube("Hidden", at: .zero, visible: false)]
let vis = selected(CGRect(x: 0, y: 0, width: 800, height: 600), mixed)
check("only the visible one", vis == ["Shown"], "\(vis)")

print("\n== degenerate drags select nothing ==")
check("a zero rect", selected(.zero, scene).isEmpty)
check("a one-pixel drag is a tap, not a box",
      selected(CGRect(x: 400, y: 300, width: 1, height: 1), scene).isEmpty)
check("an empty scene", selected(CGRect(x: 0, y: 0, width: 800, height: 600), []).isEmpty)

print("\n== the rectangle comes out the same whichever way you drag ==")
let a = CGPoint(x: 100, y: 80), b = CGPoint(x: 300, y: 240)
check("down-right", BoxSelect.rect(from: a, to: b) == CGRect(x: 100, y: 80, width: 200, height: 160))
check("up-left is the same rectangle", BoxSelect.rect(from: b, to: a) == BoxSelect.rect(from: a, to: b))
check("mixed diagonal",
      BoxSelect.rect(from: CGPoint(x: 300, y: 80), to: CGPoint(x: 100, y: 240))
        == CGRect(x: 100, y: 80, width: 200, height: 160))

print("\n== things behind the camera are not selected ==")
// Far behind the eye along the view direction.
let eye: SIMD3<Float> = camera.eye
let away: SIMD3<Float> = eye * 3          // well past the camera, opposite the scene
let half3 = SIMD3<Float>(repeating: 0.5)
let behind = [cube2("Behind", lo: away - half3, hi: away + half3)]
let behindHit = selected(CGRect(x: 0, y: 0, width: 800, height: 600), behind)
check("an object behind the eye is skipped", behindHit.isEmpty, "\(behindHit)")

print("\n== world bounds, which box select measures against ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)          // MeshBuilder's cube is 2 units across
    obj.location = .zero
    obj.rotation = .zero
    obj.scale = .one
    var b = obj.worldBounds
    check("an unrotated cube measures its own size",
          close(b.min, SIMD3(-1, -1, -1)) && close(b.max, SIMD3(1, 1, 1)),
          "\(b.min) .. \(b.max)")

    obj.location = SIMD3(5, 0, 0)
    b = obj.worldBounds
    check("moving it moves the bounds",
          close(b.min, SIMD3(4, -1, -1)) && close(b.max, SIMD3(6, 1, 1)),
          "\(b.min) .. \(b.max)")

    // A cube turned 45° about Z is wider in world space than it is in its own.
    obj.location = .zero
    obj.rotation = SIMD3(0, 0, .pi / 4)
    b = obj.worldBounds
    let widened = b.max.x
    check("a rotated cube is wider than its local size",
          widened > 1.35 && widened < 1.5, "half-width \(widened), expected ~1.414")

    obj.rotation = .zero
    obj.scale = SIMD3(repeating: 3)
    b = obj.worldBounds
    check("scale is included", close(b.max, SIMD3(3, 3, 3)), "\(b.max)")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
