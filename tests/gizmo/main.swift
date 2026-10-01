import Foundation
import simd
import CoreGraphics

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) < eps }
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-3) -> Bool {
    close(a.x, b.x, eps) && close(a.y, b.y, eps) && close(a.z, b.z, eps)
}

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
var options = ViewportOptions()

/// No startup cube: `BKScene()` seeds Blender's default scene, and an extra
/// object at the origin makes `objects[0]` the wrong one to assert on.
func freshScene() -> (BKScene, BKObject) {
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = .zero
    s.selection = [o.id]
    s.activeID = o.id
    return (s, o)
}

print("== Euler round-trip ==")
for e in [SIMD3<Float>(0,0,0), SIMD3(0.3,-0.7,1.2), SIMD3(-1.1,0.2,-2.4), SIMD3(0.5,1.5,0.9)] {
    let back = simd_float3x3(simd_float4x4(eulerXYZ: e)).eulerXYZ
    // Compare the matrices, since distinct Euler triples can name one rotation.
    let m1 = simd_float4x4(eulerXYZ: e), m2 = simd_float4x4(eulerXYZ: back)
    let same = (0..<3).allSatisfy { close(m1.columns.0.xyz, m2.columns.0.xyz) &&
                                    close(m1.columns.1.xyz, m2.columns.1.xyz) &&
                                    close(m1.columns.2.xyz, m2.columns.2.xyz) && $0 >= 0 }
    check("euler \(e) -> \(back)", same)
}

print("\n== hit testing ==")
let (scene, _) = freshScene()
let g = TransformGizmo.make(mode: .translate, scene: scene, options: options,
                            camera: camera, size: size)!
let proj = TransformGizmo.Projection(camera: camera, size: size)
let centre = proj.project(g.origin)!
check("centre is the screen handle", g.hitTest(centre, projection: proj) == .screen,
      "\(String(describing: g.hitTest(centre, projection: proj)))")
for i in 0..<3 {
    // 70% along the shaft: past the plane quads, short of the arrow tip.
    let p = proj.project(g.origin + g.axes[i] * (g.radius * 0.7))!
    let hit = g.hitTest(p, projection: proj)
    check("shaft \(["X","Y","Z"][i]) -> axis(\(i))", hit == .axis(i), "\(String(describing: hit))")
}
for i in 0..<3 {
    let (j, k) = ((i + 1) % 3, (i + 2) % 3)
    let p = proj.project(g.origin + (g.axes[j] + g.axes[k]) * (g.radius * 0.42))!
    let hit = g.hitTest(p, projection: proj)
    check("plane quad normal \(["X","Y","Z"][i]) -> plane(\(i))", hit == .plane(i), "\(String(describing: hit))")
}
let far = CGPoint(x: centre.x + 400, y: centre.y + 300)
check("empty space -> nil", g.hitTest(far, projection: proj) == nil)

print("\n== translate: axis constraint ==")
for i in 0..<3 {
    let (s, obj) = freshScene()
    let gg = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let c = pr.project(gg.origin)!
    let tip = pr.project(gg.origin + gg.axes[i] * gg.radius)!
    let start = pr.project(gg.origin + gg.axes[i] * (gg.radius * 0.7))!
    // Drag half the shaft's on-screen length further along it.
    let unit = CGPoint(x: (tip.x - c.x) / hypot(tip.x - c.x, tip.y - c.y),
                       y: (tip.y - c.y) / hypot(tip.x - c.x, tip.y - c.y))
    let px = hypot(tip.x - c.x, tip.y - c.y) * 0.5
    let end = CGPoint(x: start.x + unit.x * px, y: start.y + unit.y * px)

    let sess = TransformGizmo.beginSession(handle: .axis(i), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size)
    let r = TransformGizmo.resolve(sess, at: end)!
    TransformGizmo.apply(r, session: sess)
    let loc = obj.location
    var expected = SIMD3<Float>.zero
    expected[i] = gg.radius * 0.5
    check("drag +\(["X","Y","Z"][i]) moves only that axis", close(loc, expected, 1e-2),
          "got \(loc) want \(expected)")
}

print("\n== translate: releasing where you started is a no-op ==")
do {
    let (s, obj) = freshScene()
    let gg = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let start = pr.project(gg.origin + gg.axes[0] * (gg.radius * 0.7))!
    let sess = TransformGizmo.beginSession(handle: .axis(0), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size)
    // Wander, then come home.
    _ = TransformGizmo.resolve(sess, at: CGPoint(x: start.x + 120, y: start.y - 60)).map {
        TransformGizmo.apply($0, session: sess) }
    let r = TransformGizmo.resolve(sess, at: start)!
    TransformGizmo.apply(r, session: sess)
    check("no drift after wandering back", close(obj.location, .zero, 1e-4),
          "\(obj.location)")
}

print("\n== rotate ==")
do {
    let (s, obj) = freshScene()
    let gg = TransformGizmo.make(mode: .rotate, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let c = pr.project(gg.origin)!
    // A quarter turn measured on screen around the ring's centre.
    let start = CGPoint(x: c.x + 100, y: c.y)
    let end   = CGPoint(x: c.x, y: c.y + 100)
    let sess = TransformGizmo.beginSession(handle: .axis(2), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size)
    guard case .rotate(_, let angle, let idx)? = TransformGizmo.resolve(sess, at: end) else {
        check("rotate resolves", false); exit(1)
    }
    check("Z ring reports axis index 2", idx == 2)
    check("90 degrees of screen sweep -> 90 degrees", close(abs(angle), .pi / 2, 1e-3),
          "\(angle) rad")
    let r = TransformGizmo.resolve(sess, at: end)!
    TransformGizmo.apply(r, session: sess)
    let rot = obj.rotation
    check("rotation lands on Z only", close(rot.x, 0, 1e-3) && close(rot.y, 0, 1e-3)
                                      && close(abs(rot.z), .pi / 2, 1e-3), "\(rot)")
}

print("\n== rotate about the pivot carries a multi-selection ==")
do {
    let s = BKScene(startupFile: false)
    let a = s.add(.cube); a.location = SIMD3(2, 0, 0)
    let b = s.add(.cube); b.location = SIMD3(-2, 0, 0)
    s.selection = [a.id, b.id]; s.activeID = a.id
    let gg = TransformGizmo.make(mode: .rotate, scene: s, options: options,
                                 camera: camera, size: size)!
    check("pivot is the median", close(gg.origin, .zero, 1e-4), "\(gg.origin)")
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let c = pr.project(gg.origin)!
    let sess = TransformGizmo.beginSession(handle: .axis(2), at: CGPoint(x: c.x + 100, y: c.y),
                                           gizmo: gg, scene: s, camera: camera, size: size)
    let r = TransformGizmo.resolve(sess, at: CGPoint(x: c.x, y: c.y + 100))!
    TransformGizmo.apply(r, session: sess)
    // A quarter turn about Z takes (±2,0,0) to (0,∓2,0) or (0,±2,0).
    let swapped = close(abs(a.location.y), 2, 1e-2) && close(a.location.x, 0, 1e-2)
    check("both objects swing round the pivot", swapped && close(a.location, -b.location, 1e-2),
          "a=\(a.location) b=\(b.location)")
}

print("\n== scale ==")
for i in 0..<3 {
    let (s, obj) = freshScene()
    let gg = TransformGizmo.make(mode: .scale, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let c = pr.project(gg.origin)!
    let tip = pr.project(gg.origin + gg.axes[i] * gg.radius)!
    let len = hypot(tip.x - c.x, tip.y - c.y)
    let unit = CGPoint(x: (tip.x - c.x) / len, y: (tip.y - c.y) / len)
    let start = CGPoint(x: c.x + unit.x * len, y: c.y + unit.y * len)
    let end   = CGPoint(x: c.x + unit.x * len * 2, y: c.y + unit.y * len * 2)
    let sess = TransformGizmo.beginSession(handle: .axis(i), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size)
    let r = TransformGizmo.resolve(sess, at: end)!
    TransformGizmo.apply(r, session: sess)
    var want = SIMD3<Float>(repeating: 1); want[i] = 2
    check("doubling the reach doubles scale \(["X","Y","Z"][i])",
          close(obj.scale, want, 1e-2), "\(obj.scale)")
}

print("\n== snapping ==")
do {
    let (s, obj) = freshScene()
    // The magnet is Blender's, on the scene; the increment is the view's.
    s.tools.useSnap = true
    options.snapIncrement = 0.25
    let gg = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let start = pr.project(gg.origin + gg.axes[0] * (gg.radius * 0.7))!
    let sess = TransformGizmo.beginSession(handle: .axis(0), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size,
                                           options: options)
    let point = CGPoint(x: start.x + 37, y: start.y + 11)
    let r = TransformGizmo.snapped(TransformGizmo.resolve(sess, at: point)!, session: sess, at: point)
    TransformGizmo.apply(r, session: sess)
    let x = obj.location.x
    check("snapped position is a multiple of the increment",
          close(x / 0.25, (x / 0.25).rounded(), 1e-4), "x=\(x)")
    check("the magnet is only on because Increment is one of the snap elements",
          s.tools.snapsDrag)
}

print("\n== gizmo keeps a constant on-screen size ==")
do {
    let (s, _) = freshScene()
    var near = camera; near.distance = 3
    var far = camera;  far.distance = 40
    let gn = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: near, size: size)!
    let gf = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: far, size: size)!
    let pn = TransformGizmo.Projection(camera: near, size: size)
    let pf = TransformGizmo.Projection(camera: far, size: size)
    let ln = hypot(pn.project(gn.origin + gn.axes[0] * gn.radius)!.x - pn.project(gn.origin)!.x,
                   pn.project(gn.origin + gn.axes[0] * gn.radius)!.y - pn.project(gn.origin)!.y)
    let lf = hypot(pf.project(gf.origin + gf.axes[0] * gf.radius)!.x - pf.project(gf.origin)!.x,
                   pf.project(gf.origin + gf.axes[0] * gf.radius)!.y - pf.project(gf.origin)!.y)
    check("shaft length in points is zoom-independent", abs(ln - lf) < 3,
          "near=\(Int(ln))pt far=\(Int(lf))pt")
}

print("\n== python echo ==")
do {
    let (s, _) = freshScene()
    let gg = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let start = pr.project(gg.origin + gg.axes[1] * (gg.radius * 0.7))!
    let sess = TransformGizmo.beginSession(handle: .axis(1), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size)
    let r = TransformGizmo.resolve(sess, at: CGPoint(x: start.x + 40, y: start.y + 40))!
    let py = TransformGizmo.python(r, session: sess)
    print("      \(py)")
    check("Y drag constrains Y in the echo", py.contains("constraint_axis=(False, True, False)"))
}

print("\n== preview, roll back, commit once ==")
do {
    // A drag paints the display cache directly, because sending Python every
    // frame of a 60 fps gesture would not keep up. That makes it a preview, and
    // the preview has to be undone before the operator is applied — or the
    // transform lands twice.
    let (s, obj) = freshScene()
    let gg = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                 camera: camera, size: size)!
    let pr = TransformGizmo.Projection(camera: camera, size: size)
    let start = pr.project(gg.origin + gg.axes[2] * (gg.radius * 0.7))!
    let sess = TransformGizmo.beginSession(handle: .axis(2), at: start, gizmo: gg,
                                           scene: s, camera: camera, size: size)

    let end = CGPoint(x: start.x, y: start.y - 90)
    let result = TransformGizmo.resolve(sess, at: end)!
    TransformGizmo.apply(result, session: sess)
    let previewed = obj.location
    check("the preview moves the object", previewed.z > 0.01, "\(previewed)")

    TransformGizmo.rollBack(sess)
    check("rolling back returns it exactly to the start",
          close(obj.location.x, 0) && close(obj.location.y, 0) && close(obj.location.z, 0),
          "\(obj.location)")

    // Applying the committed transform once must land where the preview was —
    // not at twice the distance.
    guard case .translate(let delta) = result else { check("result is a translate", false); exit(1) }
    obj.location += delta
    check("committing once lands where the preview showed",
          close(obj.location.z, previewed.z, 1e-4),
          "committed \(obj.location.z) vs previewed \(previewed.z)")

    // And the reported Python carries that same delta, so the log matches.
    let python = TransformGizmo.python(result, session: sess)
    check("the emitted Python constrains to Z",
          python.contains("constraint_axis=(False, False, True)"), python)
}

print("\n== rolling back a rotation and a scale ==")
do {
    for mode in [TransformGizmo.Mode.rotate, .scale] {
        let (s, obj) = freshScene()
        obj.location = SIMD3(1, 0, 0)
        let before = (obj.location, obj.rotation, obj.scale)
        let gg = TransformGizmo.make(mode: mode, scene: s, options: options,
                                     camera: camera, size: size)!
        let pr = TransformGizmo.Projection(camera: camera, size: size)
        let c = pr.project(gg.origin)!
        let sess = TransformGizmo.beginSession(handle: .axis(2),
                                               at: CGPoint(x: c.x + 90, y: c.y),
                                               gizmo: gg, scene: s, camera: camera, size: size)
        if let r = TransformGizmo.resolve(sess, at: CGPoint(x: c.x, y: c.y + 90)) {
            TransformGizmo.apply(r, session: sess)
        }
        TransformGizmo.rollBack(sess)
        check("\(mode) rolls back location", close(obj.location, before.0, 1e-4), "\(obj.location)")
        check("\(mode) rolls back rotation", close(obj.rotation, before.1, 1e-4), "\(obj.rotation)")
        check("\(mode) rolls back scale",    close(obj.scale, before.2, 1e-4), "\(obj.scale)")
    }
}

print("\n== the gizmo is far too big for setVertexBytes ==")
do {
    // Metal caps setVertexBytes at 4 KB. Exceeding it is undefined: the
    // simulator tolerated it and a device did not, which is what made Move,
    // Rotate and Scale crash on hardware while every simulator sweep passed.
    // The renderer must upload this through an MTLBuffer, and this test exists
    // to say plainly that it can never go back.
    let (s, _) = freshScene()
    let stride = MemoryLayout<GridVertex>.stride
    for mode in [TransformGizmo.Mode.translate, .rotate, .scale] {
        guard let g = TransformGizmo.make(mode: mode, scene: s, options: options,
                                          camera: camera, size: size) else {
            check("\(mode) builds", false); continue
        }
        let bytes = g.triangles(eye: camera.eye, highlighted: nil).count * stride
        check("\(mode) exceeds the 4 KB inline cap — needs a buffer",
              bytes > 4096, "\(bytes) bytes")
    }
}

print("\n== a zero-sized view must not make a 700-metre gizmo ==")
do {
    // pointSize used to be pushed in from SwiftUI, which runs before layout;
    // when it never ran again the size stayed (0, 0) and the radius came out
    // around 700 metres — built, drawn, and entirely outside the frame, which
    // looked exactly like a gizmo that was never drawn at all.
    let (s, _) = freshScene()
    let real = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                   camera: camera, size: size)!
    let zero = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                   camera: camera, size: CGSize(width: 0, height: 0))!
    check("a sane view gives a sane radius", real.radius > 0.05 && real.radius < 5,
          "\(real.radius) m")
    check("a zero view is what produced the runaway radius", zero.radius > 100,
          "\(zero.radius) m — the renderer must read the size from the view")
}

print("\n== the drag says what it is doing ==")
do {
    // A drag with nothing on screen to show for it is indistinguishable from a
    // drag that never took hold — worst with a trackpad or a Pencil, where
    // there is no contact with the glass to feel. The readout is that signal,
    // so its wording has to name the right axis.
    let (s, _) = freshScene()

    func readout(_ mode: TransformGizmo.Mode, _ handle: TransformGizmo.Handle,
                 _ result: TransformGizmo.Result) -> String {
        let g = TransformGizmo.make(mode: mode, scene: s, options: options,
                                    camera: camera, size: size)!
        let session = TransformGizmo.beginSession(handle: handle, at: .zero, gizmo: g,
                                                  scene: s, camera: camera, size: size,
                                                  options: options)
        return TransformGizmo.readout(result, session: session)
    }

    // Axis drags report the component of the axis they are constrained to,
    // not the first non-zero one — dragging Y must not read as X.
    let dy = readout(.translate, .axis(1), .translate(SIMD3(0, 0.25, 0)))
    check("Y axis move names Y", dy.contains("along Y") && dy.contains("0.2500"), dy)
    let dz = readout(.translate, .axis(2), .translate(SIMD3(0, 0, -1.5)))
    check("Z axis move names Z and keeps the sign",
          dz.contains("along Z") && dz.contains("-1.5000"), dz)

    // A plane handle is named by the two axes it moves in, which are the ones
    // the handle's own index excludes.
    let plane = readout(.translate, .plane(1), .translate(SIMD3(0.5, 0, 0.25)))
    check("the XZ plane handle names XZ",
          plane.contains("XZ plane") && plane.contains("0.5000") && plane.contains("0.2500"),
          plane)

    let rot = readout(.rotate, .axis(2), .rotate(axis: SIMD3(0, 0, 1),
                                                 angle: .pi / 2, axisIndex: 2))
    check("rotation reports degrees, not radians",
          rot.contains("90.00°") && rot.contains("around Z"), rot)

    let view = readout(.rotate, .screen, .rotate(axis: SIMD3(0, 0, 1),
                                                 angle: .pi, axisIndex: nil))
    check("a view rotation says so", view.contains("view") && view.contains("180.00°"), view)

    let sc = readout(.scale, .axis(0), .scale(SIMD3(2.5, 1, 1)))
    check("scale names its axis and factor",
          sc.contains("along X") && sc.contains("2.5000"), sc)

    // Nothing is being dragged until something is.
    check("no drag, no readout", s.transformReadout == nil)
}

print("\n== a losing gesture must not wipe the winning one's readout ==")
do {
    // Several recognisers watch the viewport at once and the ones that lose
    // still report .failed or .cancelled, so a one-finger orbit fires the
    // pinch recogniser's end branch too. Clearing unconditionally there wipes
    // the readout of the drag that actually won — which looks exactly like the
    // readout never appearing, and is the whole reason for the owner token.
    let (s, _) = freshScene()
    check("nothing showing at rest", s.dragReadout == nil)

    s.beginViewportDrag(.orbit, "Orbit  30°, 20°")
    check("an orbit shows", s.dragReadout == "Orbit  30°, 20°", s.dragReadout ?? "nil")

    s.endViewportDrag(.zoom)      // the pinch recogniser failing
    check("a failing pinch leaves the orbit alone",
          s.dragReadout == "Orbit  30°, 20°", s.dragReadout ?? "nil")
    s.endViewportDrag(.pan)       // the two-finger pan failing
    check("a failing pan leaves the orbit alone",
          s.dragReadout == "Orbit  30°, 20°", s.dragReadout ?? "nil")

    s.endViewportDrag(.orbit)
    check("the owner can end it", s.dragReadout == nil, s.dragReadout ?? "nil")

    // A transform outranks a camera move: grabbing a handle is the more
    // specific answer to "what is this drag doing".
    s.beginViewportDrag(.orbit, "Orbit  30°, 20°")
    s.transformReadout = "D: 0.5000  along X"
    check("a transform wins over a camera move",
          s.dragReadout == "D: 0.5000  along X", s.dragReadout ?? "nil")
    s.clearViewportDrag()
    check("clearing the camera move leaves the transform",
          s.dragReadout == "D: 0.5000  along X", s.dragReadout ?? "nil")
    s.transformReadout = nil
    check("and then nothing is showing", s.dragReadout == nil, s.dragReadout ?? "nil")

    // Taking over mid-gesture: a pinch starting during an orbit is the live one.
    s.beginViewportDrag(.orbit, "Orbit")
    s.beginViewportDrag(.zoom, "Zoom  2.40 m")
    check("the newer gesture takes the readout", s.dragReadout == "Zoom  2.40 m",
          s.dragReadout ?? "nil")
    s.endViewportDrag(.orbit)
    check("and the older one cannot take it back down",
          s.dragReadout == "Zoom  2.40 m", s.dragReadout ?? "nil")
}

print("\n== a drag must move what the renderer draws ==")
do {
    // On device every object comes back from the mirror carrying Blender's
    // matrix_world, and modelMatrix prefers that matrix over
    // location/rotation/scale. A live drag moves the components — sending
    // Python per frame of a 60 fps gesture cannot keep up — so the stale
    // matrix pinned the object in place on screen, and it only moved when the
    // finger lifted. A move looked like a jump.
    //
    // Every check below reads modelMatrix, not location, because modelMatrix
    // is what the renderer draws through. Asserting on location is exactly the
    // mistake that let this ship.
    func origin(_ o: BKObject) -> SIMD3<Float> {
        let c = o.modelMatrix.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    let (s, obj) = freshScene()
    // Blender's own transform for the object, as the mirror installs it.
    obj.setMirroredTransform(simd_float4x4(translation: SIMD3(1, 2, 3)))
    check("a mirrored object draws where Blender put it",
          close(origin(obj), SIMD3(1, 2, 3)), "\(origin(obj))")
    check("and its fields report the same",
          close(obj.location, SIMD3(1, 2, 3)), "\(obj.location)")

    obj.location = SIMD3(1, 2, 4)
    check("moving it during a drag moves what is drawn",
          close(origin(obj), SIMD3(1, 2, 4)), "\(origin(obj))")

    obj.setMirroredTransform(simd_float4x4(translation: SIMD3(5, 5, 5)))
    obj.rotation = SIMD3(0, 0, .pi / 2)
    check("rotating during a drag rotates what is drawn",
          close(obj.modelMatrix.columns.0.xyz, SIMD3(0, 1, 0)),
          "\(obj.modelMatrix.columns.0.xyz)")

    obj.setMirroredTransform(simd_float4x4(translation: SIMD3(5, 5, 5)))
    obj.scale = SIMD3(repeating: 2)
    check("scaling during a drag scales what is drawn",
          close(length(obj.modelMatrix.columns.0.xyz), 2),
          "\(length(obj.modelMatrix.columns.0.xyz))")

    // The decomposition inside setMirroredTransform writes those same fields,
    // and must not throw away the matrix it is decomposing.
    let m = simd_float4x4(translation: SIMD3(-2, 0.5, 7))
    obj.setMirroredTransform(m)
    check("installing a mirrored transform survives its own decomposition",
          close(origin(obj), SIMD3(-2, 0.5, 7)), "\(origin(obj))")

    // And the whole gizmo drag, end to end, through the real session.
    let (s2, o2) = freshScene()
    o2.setMirroredTransform(simd_float4x4(translation: .zero))
    let g = TransformGizmo.make(mode: .translate, scene: s2, options: options,
                                camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(0), at: CGPoint(x: 400, y: 400),
                                              gizmo: g, scene: s2, camera: camera,
                                              size: size, options: options)
    TransformGizmo.apply(.translate(SIMD3(0.75, 0, 0)), session: session)
    check("a gizmo drag moves the drawn position",
          close(origin(o2), SIMD3(0.75, 0, 0)), "\(origin(o2))")
    _ = s
}

print("\n== the Move tool moves points, not the object holding them ==")
do {
    // A drag that misses every handle used to run its own code path, and that
    // path moved the object. In Edit Mode that slid the whole mesh instead of
    // the selected vertices — not what the Move tool means once you are
    // editing points and faces. It now begins a session on the view-plane
    // handle, which is the same path the handles use and already knew about
    // edit selections.
    let (s, obj) = freshScene()
    s.mode = .edit
    s.activeID = obj.id
    // Two of the cube's eight corners.
    let picked: Set<Int> = [0, 1]
    s.editSelection.vertices = picked

    let before = obj.mesh.vertices.map(\.position)
    let objectBefore = obj.location

    let g = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .screen, at: CGPoint(x: 400, y: 400),
                                              gizmo: g, scene: s, camera: camera,
                                              size: size, options: options)
    check("a view-plane drag in Edit Mode edits the mesh", session.edit != nil)

    TransformGizmo.apply(.translate(SIMD3(0, 0, 0.5)), session: session)

    let after = obj.mesh.vertices.map(\.position)
    let moved = (0..<min(before.count, after.count)).filter { !close(before[$0], after[$0]) }
    check("the selected points moved", !moved.isEmpty, "\(moved.count) moved")
    check("the unselected ones did not",
          moved.allSatisfy { picked.contains($0) },
          "moved \(moved.sorted()) but only \(picked.sorted()) were selected")
    check("and the object itself stayed put", close(obj.location, objectBefore),
          "\(obj.location)")

    // Object Mode is the other half: there the same drag moves the object.
    let (s2, o2) = freshScene()
    s2.mode = .object
    let g2 = TransformGizmo.make(mode: .translate, scene: s2, options: options,
                                 camera: camera, size: size)!
    let session2 = TransformGizmo.beginSession(handle: .screen, at: CGPoint(x: 400, y: 400),
                                               gizmo: g2, scene: s2, camera: camera,
                                               size: size, options: options)
    let meshBefore = o2.mesh.vertices.map(\.position)
    TransformGizmo.apply(.translate(SIMD3(0, 0, 0.5)), session: session2)
    check("in Object Mode the object moves", close(o2.location, SIMD3(0, 0, 0.5)),
          "\(o2.location)")
    check("and its mesh is left alone",
          zip(meshBefore, o2.mesh.vertices.map(\.position)).allSatisfy { close($0, $1) })
}

print("\n== what a drag sends to Blender ==")
do {
    let (s, obj) = freshScene()
    obj.rotation = SIMD3(0, 0, .pi / 4)
    let g = TransformGizmo.make(mode: .scale, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(0), at: .zero, gizmo: g,
                                              scene: s, camera: camera, size: size)
    let scale = TransformGizmo.python(.scale(SIMD3(2, 1, 1)), session: session)
    check("a scale is in the local axes its handles are drawn along",
          scale.contains("orient_type='LOCAL'"), scale)

    func rows(in python: String) -> [SIMD3<Float>]? {
        guard let start = python.range(of: "orient_matrix=("),
              let end = python.range(of: "), orient_matrix_type") else { return nil }
        let numbers = python[start.upperBound..<end.lowerBound]
            .split(whereSeparator: { "(), ".contains($0) })
            .compactMap { Float($0) }
        guard numbers.count == 9 else { return nil }
        return [SIMD3(numbers[0], numbers[1], numbers[2]),
                SIMD3(numbers[3], numbers[4], numbers[5]),
                SIMD3(numbers[6], numbers[7], numbers[8])]
    }
    for axis in [normalize(SIMD3<Float>(1, -2, 1.5)), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)] {
        let python = "bpy.ops.transform.rotate("
            + TransformGizmo.viewRotationArguments(axis: axis, angle: 0.5)
                .joined(separator: ", ") + ")"
        check("a view rotation never names an axis called VIEW (\(axis))",
              !python.contains("orient_axis='VIEW'") && python.contains("orient_axis='Z'")
                && python.contains("orient_type='VIEW'") && python.contains("orient_matrix_type='VIEW'"),
              python)
        guard let r = rows(in: python) else { check("its orientation reads back", false, python); continue }
        check("its orientation's Z is the view axis", close(r[2], axis, 1e-5), "\(r[2])")
        check("in a right-handed orthonormal frame",
              close(length(r[0]), 1, 1e-5) && close(length(r[1]), 1, 1e-5)
                && close(dot(r[0], r[1]), 0, 1e-5) && close(cross(r[0], r[1]), r[2], 1e-5))
    }
    let screen = TransformGizmo.beginSession(handle: .screen, at: .zero,
                                             gizmo: TransformGizmo.make(mode: .rotate, scene: s,
                                                                        options: options, camera: camera,
                                                                        size: size)!,
                                             scene: s, camera: camera, size: size)
    let freeDrag = TransformGizmo.python(.rotate(axis: SIMD3(0, 1, 0), angle: 0.3, axisIndex: nil),
                                         session: screen)
    // The same call, with the pivot the drag was taken about appended: every
    // pivot names its own centre now, because a headless Blender's default is
    // the bounds centre and the gizmo previews about the median.
    let bare = "bpy.ops.transform.rotate("
        + TransformGizmo.viewRotationArguments(axis: SIMD3(0, 1, 0), angle: 0.3)
            .joined(separator: ", ")
    check("and the free drag and outer ring send exactly that",
          freeDrag.hasPrefix(bare)
              && freeDrag.hasSuffix(", center_override=(0.0000, 0.0000, 0.0000))"), freeDrag)
}

print("\n== several objects scale apart along their own axes ==")
do {
    let s = BKScene(startupFile: false)
    let a = s.add(.cube); a.location = SIMD3(2, 0, 0); a.rotation = SIMD3(0, 0, .pi / 4)
    let b = s.add(.cube); b.location = SIMD3(-2, 1, 0); b.rotation = SIMD3(0, 0, .pi / 6)
    s.selection = [a.id, b.id]; s.activeID = a.id
    let g = TransformGizmo.make(mode: .scale, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(0), at: .zero, gizmo: g,
                                              scene: s, camera: camera, size: size)
    TransformGizmo.apply(.scale(SIMD3(2, 1, 1)), session: session)
    // Blender 5.2.1, the same two objects:
    // resize(value=(2, 1, 1), constraint_axis=(True, False, False), orient_type='LOCAL')
    check("the first lands where Blender puts it", close(a.location, SIMD3(2.75, 0.75, 0), 1e-3),
          "\(a.location)")
    check("and so does the second", close(b.location, SIMD3(-3.2835, 0.259, 0), 1e-3), "\(b.location)")
    check("each scaled along its own X", close(a.scale, SIMD3(2, 1, 1)) && close(b.scale, SIMD3(2, 1, 1)))
}

print("\n== Top and Bottom look straight down and up ==")
do {
    var top = ViewportCamera()
    top.snap(to: .top)
    let down = normalize(top.target - top.eye)
    check("Top looks straight down, not 1.1° off", close(down, SIMD3(0, 0, -1), 1e-6), "\(down)")
    check("with X to the right", close(top.right, SIMD3(1, 0, 0), 1e-6), "\(top.right)")
    check("and Y up the screen", close(top.trueUp, SIMD3(0, 1, 0), 1e-6), "\(top.trueUp)")
    let vp = top.viewProjection(aspect: 1.25)
    check("and a view matrix with nothing undefined in it",
          (0..<4).allSatisfy { c in (0..<4).allSatisfy { r in vp[c][r].isFinite } })
    let projection = TransformGizmo.Projection(camera: top, size: size)
    let origin = projection.project(.zero)!, x = projection.project(SIMD3(1, 0, 0))!
    check("so the X axis lies level across the screen", abs(x.y - origin.y) < 0.01 && x.x > origin.x,
          "\(origin) -> \(x)")

    var bottom = ViewportCamera()
    bottom.snap(to: .bottom)
    check("Bottom looks straight up", close(normalize(bottom.target - bottom.eye), SIMD3(0, 0, 1), 1e-6))
    check("with Y down the screen, as Blender's does", close(bottom.trueUp, SIMD3(0, -1, 0), 1e-6))

    // Everywhere the old construction had an answer, the answer is unchanged.
    for (azimuth, elevation) in [(Float(0.6), Float(0.5)), (2.4, -0.9), (-1.3, 1.2)] {
        var cam = ViewportCamera()
        cam.azimuth = azimuth
        cam.elevation = elevation
        let f = normalize(cam.target - cam.eye)
        let oldRight = normalize(cross(f, SIMD3<Float>(0, 0, 1)))
        let oldUp = normalize(cross(oldRight, f))
        check("at \(azimuth), \(elevation) the camera's axes are what they were",
              close(cam.right, oldRight, 1e-5) && close(cam.trueUp, oldUp, 1e-5))
    }
    var orbiting = ViewportCamera()
    orbiting.orbit(dx: 0, dy: 10)
    check("orbiting stops at straight down rather than going over",
          close(orbiting.elevation, .pi / 2, 1e-6), "\(orbiting.elevation)")
}

print("\n== View Selected frames the selection ==")
do {
    let s = BKScene(startupFile: false)
    let a = s.add(.cube); a.location = SIMD3(10, 0, 0)
    let b = s.add(.cube); b.location = SIMD3(-10, 0, 0)
    s.selection = [a.id]; s.activeID = a.id
    var selected = ViewportCamera()
    check("it frames the selected object", selected.frameSelected(in: s)
            && close(selected.target, SIMD3(10, 0, 0), 1e-4), "\(selected.target)")
    var all = ViewportCamera()
    all.frameAll(s.objects)
    check("closer in than Frame All", selected.distance < all.distance,
          "\(selected.distance) vs \(all.distance)")

    s.selection = []
    var none = ViewportCamera()
    let before = none.target
    check("with nothing selected it moves nothing", !none.frameSelected(in: s) && none.target == before)

    s.selection = [a.id]; s.activeID = a.id
    s.mode = .edit
    s.editSelection.vertices = [0]
    var editing = ViewportCamera()
    check("while editing it frames the selected vertices",
          editing.frameSelected(in: s)
            && close(editing.target, a.mesh.vertices[0].position + a.location, 1e-4),
          "\(editing.target)")
    _ = b
}

print("\n== Edit Mode with nothing selected has no gizmo ==")
do {
    // Round 2's review: the gizmo fell through to the object branch, so the
    // preview moved the edited cube (and, proportional, its neighbour) while
    // Blender 5.2.1 answered the committed translate with CANCELLED.
    let (s, obj) = freshScene()
    let neighbour = s.add(.cube); neighbour.location = SIMD3(3, 0, 0)
    s.selection = [obj.id, neighbour.id]; s.activeID = obj.id
    s.mode = .edit
    s.editSelection.clear()
    for mode in [TransformGizmo.Mode.translate, .rotate, .scale] {
        check("no \(mode) gizmo with no vertex selected",
              TransformGizmo.make(mode: mode, scene: s, options: options, camera: camera, size: size) == nil)
    }
    s.editSelection.vertices = [0]
    let one = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)
    check("and one on the vertex once one is selected",
          one.map { close($0.origin, obj.mesh.vertices[0].position, 1e-5) } == true,
          "\(String(describing: one?.origin))")
    s.mode = .object
    check("object mode still has its gizmo on the selection",
          TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size) != nil)
}

print("\n== Frame All frames what is drawn, as Blender's View All does ==")
do {
    // Round 2's review: a 2 m cube and a 100 m ground, the ground hidden with
    // H. A hidden object keeps the mesh it was last drawn with, and Home
    // framed it too (294.66 against 7.22). Blender 5.2.1's View All through a
    // 3D View override: 160.4 with both shown, 3.208 with the plane hidden or
    // disabled in viewports, and the view left alone with everything hidden.
    let s = BKScene(startupFile: false)
    s.objects = []
    let cube = s.add(.cube)
    let ground = s.add(.plane); ground.scale = SIMD3(50, 50, 1); ground.location = SIMD3(0, 0, -1)
    var both = ViewportCamera(); both.frameAll(s.objects)
    ground.visible = false
    var hidden = ViewportCamera(); hidden.frameAll(s.objects)
    var cubeOnly = ViewportCamera(); cubeOnly.frameAll([cube])
    check("a hidden ground is left out: the view fits the cube alone",
          close(hidden.distance, cubeOnly.distance, 1e-4) && hidden.distance < both.distance / 10,
          "\(hidden.distance) vs cube \(cubeOnly.distance), both \(both.distance)")
    cube.visible = false
    var stays = ViewportCamera(); stays.target = SIMD3(1, 2, 3); stays.distance = 7
    stays.frameAll(s.objects)
    check("with everything hidden the view stays where it was",
          stays.target == SIMD3(1, 2, 3) && stays.distance == 7, "\(stays.target) \(stays.distance)")
}

print("\n== a transform drag starts on the selection, or it orbits ==")
do {
    let (s, obj) = freshScene()
    let projection = TransformGizmo.Projection(camera: camera, size: size)
    let onCube = projection.project(.zero)!
    let emptySpace = CGPoint(x: 8, y: 8)
    check("a drag that starts on the selected object moves it",
          TransformGizmo.startsOnSelection(onCube, scene: s, camera: camera, size: size))
    check("one that starts on empty space orbits",
          !TransformGizmo.startsOnSelection(emptySpace, scene: s, camera: camera, size: size))
    s.selection = []
    check("and so does one on an object that is not selected",
          !TransformGizmo.startsOnSelection(onCube, scene: s, camera: camera, size: size))

    s.selection = [obj.id]
    s.mode = .edit
    s.editSelection.vertices = [0]
    let corner = projection.project(obj.mesh.vertices[0].position)!
    check("while editing, on a selected vertex",
          TransformGizmo.startsOnSelection(corner, scene: s, camera: camera, size: size))
    check("but not off in empty space",
          !TransformGizmo.startsOnSelection(emptySpace, scene: s, camera: camera, size: size))
    s.editSelection.vertices = []
    check("and not with nothing selected in the mesh",
          !TransformGizmo.startsOnSelection(corner, scene: s, camera: camera, size: size))
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
