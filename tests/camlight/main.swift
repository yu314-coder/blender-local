import Foundation
import simd
import CoreGraphics

// Cameras, lights and empties on the Mac: the record they travel in, the lines
// Blender's overlays draw for them, picking and box-selecting them, adding them,
// and keeping them through duplicate, undo and paste. What Blender itself makes
// of the same numbers is scripts/run-camlight-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func near(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) <= eps * max(1, abs(b)) }
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
    near(a.x, b.x, eps) && near(a.y, b.y, eps) && near(a.z, b.z, eps)
}
func endpoints(_ g: OverlayGeometry) -> [SIMD3<Float>] { g.lines.flatMap { [$0.a, $0.b] } }
func has(_ g: OverlayGeometry, _ p: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
    endpoints(g).contains { near($0, p, eps) }
}
func hasLine(_ g: OverlayGeometry, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
    g.lines.contains { (near($0.a, a) && near($0.b, b)) || (near($0.a, b) && near($0.b, a)) }
}
func cameraOf(_ d: ObjectDisplay?) -> CameraDisplay? { if case .camera(let c)? = d { return c }; return nil }
func lightOf(_ d: ObjectDisplay?) -> LightDisplay? { if case .light(let l)? = d { return l }; return nil }
func emptyOf(_ d: ObjectDisplay?) -> EmptyDisplay? { if case .empty(let e)? = d { return e }; return nil }

let size = CGSize(width: 1000, height: 800)
let viewport = ViewportCamera()
let view = OverlayView(camera: viewport, size: size)

/// A scene holding one camera, light or empty.
func sceneWith(_ display: ObjectDisplay, at location: SIMD3<Float> = .zero,
               selected: Bool = false) -> (BKScene, BKObject) {
    let s = BKScene(startupFile: false)
    let o = s.addObject(display, named: display.blenderType.capitalized, at: location, select: selected)
    return (s, o)
}
func geometry(_ display: ObjectDisplay, at location: SIMD3<Float> = .zero,
              rotation: SIMD3<Float> = .zero, scale: SIMD3<Float> = .one) -> OverlayGeometry {
    let (s, o) = sceneWith(display, at: location)
    o.rotation = rotation
    o.scale = scale
    return ObjectOverlays.geometry(for: o, in: s, view: view)
}

print("== the record a camera, light or empty travels in ==")
do {
    let c = cameraOf(ObjectDisplay(type: "CAMERA", dataName: "Camera", record: ""))
    check("an empty camera record is Blender 5.2.1's new camera",
          c?.lens == 50 && c?.sensorWidth == 36 && c?.sensorHeight == 24 && c?.sensorFit == .auto
          && c?.orthoScale == 6 && near(c?.clipStart ?? 0, 0.1) && c?.clipEnd == 1000
          && c?.displaySize == 1 && c?.aspectX == 1920 && c?.aspectY == 1080
          && c?.isSceneCamera == false && c?.projection == .perspective, "\(String(describing: c))")

    var changed = CameraDisplay()
    changed.dataName = "Lens; = odd"
    changed.lens = 35; changed.projection = .orthographic; changed.sensorFit = .vertical
    changed.shiftX = 0.125; changed.isSceneCamera = true; changed.showLimits = true
    let back = ObjectDisplay(type: "CAMERA", dataName: changed.dataName,
                             record: ObjectDisplay.camera(changed).record)
    check("a camera comes back from its record unchanged, its data name beside it",
          back == .camera(changed), "\(String(describing: back))")

    var lamp = LightDisplay()
    lamp.kind = .spot; lamp.color = SIMD3(0.5, 0.25, 1); lamp.spotSize = 1.2; lamp.showCone = true
    lamp.shape = .ellipse; lamp.cutoffDistance = 12
    check("so does a light",
          ObjectDisplay(type: "LIGHT", dataName: "Spot", record: ObjectDisplay.light(lamp).record)
            == .light({ var l = lamp; l.dataName = "Spot"; return l }()))
    check("a colour is three numbers", ObjectDisplay.light(lamp).record.contains("color=0.5,0.25,1.0"),
          ObjectDisplay.light(lamp).record)

    var axes = EmptyDisplay()
    axes.kind = .sphere; axes.size = 2.5; axes.imageOffset = SIMD2(0.25, -1)
    check("and an empty, which has no data",
          ObjectDisplay(type: "EMPTY", dataName: "ignored", record: ObjectDisplay.empty(axes).record)
            == .empty(axes) && ObjectDisplay.empty(axes).dataName == nil)

    let damaged = cameraOf(ObjectDisplay(type: "CAMERA", dataName: "C", record: "lens=abc;type=NOPE;shift_x=0.5"))
    check("a value that does not parse keeps Blender's default, and the rest still read",
          damaged?.lens == 50 && damaged?.projection == .perspective && damaged?.shiftX == 0.5)
    check("a mesh has no display", ObjectDisplay(type: "MESH", dataName: "", record: "") == nil)
}

print("\n== a camera's frame is Blender's ==")
do {
    // Camera.view_frame(scene) for a new camera and a 1920 x 1080 render,
    // measured in Blender 5.2.1.
    let frame = CameraDisplay().viewFrame().corners
    check("the default frame", near(frame[0], SIMD3(0.5, 0.28125, -1.388889))
          && near(frame[2], SIMD3(-0.5, -0.28125, -1.388889)), "\(frame)")

    var ortho = CameraDisplay(); ortho.projection = .orthographic
    let o = ortho.viewFrame()
    check("orthographic: half the scale wide, at the display size's depth",
          near(o.corners[0], SIMD3(3, 1.6875, -1)) && o.drawSize == 3, "\(o)")

    var sized = CameraDisplay(); sized.displaySize = 2.5
    check("the display size scales a perspective frame whole",
          near(sized.viewFrame().corners[0], SIMD3(1.25, 0.703125, -3.472222)), "\(sized.viewFrame().corners[0])")
    check("while Camera.view_frame measures at size 1, as BKE_camera_view_frame does",
          near(sized.viewFrame(drawSize: 1).corners[0], SIMD3(0.5, 0.28125, -1.388889)))
    var orthoSized = ortho; orthoSized.displaySize = 2
    check("and an orthographic frame only in depth",
          near(orthoSized.viewFrame().corners[0], SIMD3(3, 1.6875, -2)), "\(orthoSized.viewFrame().corners[0])")

    var vertical = CameraDisplay(); vertical.sensorFit = .vertical
    check("a vertical fit measures the sensor's height",
          near(vertical.viewFrame().corners[0], SIMD3(0.888889, 0.5, -2.083333)),
          "\(vertical.viewFrame().corners[0])")

    var portrait = CameraDisplay(); portrait.aspectX = 1080; portrait.aspectY = 1920
    check("AUTO on a portrait render fits the height, but still measures the width",
          near(portrait.viewFrame().corners[0], SIMD3(0.28125, 0.5, -1.388889)),
          "\(portrait.viewFrame().corners[0])")

    var shifted = CameraDisplay(); shifted.shiftX = 0.1; shifted.shiftY = -0.2
    check("shift moves the frame by the shift times its width",
          near(shifted.viewFrame().corners[0], SIMD3(0.6, 0.08125, -1.388889)),
          "\(shifted.viewFrame().corners[0])")
}

print("\n== the camera's overlay ==")
do {
    let g = geometry(.camera(CameraDisplay()))
    check("frame, four wires and an outlined triangle: eleven lines", g.lines.count == 11 && g.triangles.isEmpty,
          "\(g.lines.count) lines, \(g.triangles.count) triangles")
    check("the frame's corners", has(g, SIMD3(0.5, 0.28125, -1.388889)) && has(g, SIMD3(-0.5, -0.28125, -1.388889)))
    check("a wire from each corner to the camera",
          hasLine(g, SIMD3(0.5, 0.28125, -1.388889), .zero) && hasLine(g, SIMD3(-0.5, 0.28125, -1.388889), .zero))
    // 0.7 and 0.1 of Blender's draw size above the frame's top edge.
    check("the triangle stands a tenth of the draw size above the frame",
          hasLine(g, SIMD3(0.35, 0.33125, -1.388889), SIMD3(-0.35, 0.33125, -1.388889)))
    check("and points up", has(g, SIMD3(0, 0.68125, -1.388889)))

    var scene = CameraDisplay(); scene.isSceneCamera = true
    let active = geometry(.camera(scene))
    check("the scene's camera has its triangle filled", active.triangles.count == 1 && active.lines.count == 8)
    check("where the outline was", near(active.triangles.first?.c ?? .zero, SIMD3(0, 0.68125, -1.388889)))

    let big = geometry(.camera(CameraDisplay()), scale: SIMD3(repeating: 2))
    check("it scales with the object", has(big, SIMD3(1, 0.5625, -2.777778)))
    // Blender works the frame out with the inverse scale and then scales it
    // back, so a stretched camera keeps the render's proportions.
    let stretched = geometry(.camera(CameraDisplay()), scale: SIMD3(2, 1, 1))
    check("a stretched camera keeps its frame's proportions", has(stretched, SIMD3(0.6, 0.3375, -1.666667)),
          "\(endpoints(stretched).prefix(2))")
    check("a camera scaled to zero draws nothing", geometry(.camera(CameraDisplay()), scale: SIMD3(1, 0, 1)).isEmpty)
    var orthographic = CameraDisplay(); orthographic.projection = .orthographic
    check("an orthographic frame is its scale in world units, whatever the object's scale",
          has(geometry(.camera(orthographic), scale: SIMD3(repeating: 2)), SIMD3(3, 1.6875, -1)))

    let moved = geometry(.camera(CameraDisplay()), at: SIMD3(1, 2, 3), rotation: SIMD3(0, 0, .pi / 2))
    check("and moves and turns with it", has(moved, SIMD3(1 - 0.28125, 2 + 0.5, 3 - 1.388889)),
          "\(endpoints(moved).prefix(2))")

    var limits = CameraDisplay(); limits.showLimits = true; limits.focusDistance = 7
    let l = geometry(.camera(limits))
    check("Limits draws the clipping range", hasLine(l, SIMD3(0, 0, -0.1), SIMD3(0, 0, -1000)))
    check("and a cross at the focus distance, the display size across",
          hasLine(l, SIMD3(1, 0, -7), SIMD3(-1, 0, -7)) && hasLine(l, SIMD3(0, 1, -7), SIMD3(0, -1, -7)))
    check("with its ends in Blender's clip colour",
          l.lines.contains { $0.color == ObjectOverlays.Theme.limits })
}

print("\n== lights ==")
do {
    var point = LightDisplay(); point.radius = 0.5
    let origin = SIMD3<Float>(1, 2, 3)
    let g = geometry(.light(point), at: origin)
    let unit = view.worldPerPoint(at: origin)
    let ringLines = g.lines.filter { near(length($0.a - origin), 0.5, 1e-3) && near(length($0.b - origin), 0.5, 1e-3) }
    check("a point light's radius, as a circle", ringLines.count == 32, "\(ringLines.count)")
    check("facing the viewer", ringLines.allSatisfy { abs(dot($0.a - origin, view.back)) < 1e-3 })
    let inner = g.lines.filter { near(length($0.a - origin), 9 * unit, 1e-3) }
    let outer = g.lines.filter { near(length($0.a - origin), 11.97 * unit, 1e-3) }
    check("a dashed ring nine points across: eight dashes", inner.count == 8, "\(inner.count)")
    check("a wider one: ten dashes", outer.count == 10, "\(outer.count)")
    check("and a diamond in the middle", g.lines.filter { near(length($0.a - origin), 2.7 * unit, 1e-3) }.count == 4)
    check("the ground line, down to the floor in the light theme's translucent black",
          g.translucentLines.contains { near($0.a, origin) && near($0.b, SIMD3(1, 2, 0)) }
          && g.translucentLines.allSatisfy { $0.color == ObjectOverlays.Theme.groundLine }
          && near(ObjectOverlays.Theme.groundLine.w, 0x50 / 255))

    let sun = geometry(.light({ var l = LightDisplay(); l.kind = .sun; return l }()), scale: SIMD3(repeating: 2))
    check("a sun's direction, twenty units down its Z", hasLine(sun, .zero, SIMD3(0, 0, -40)))
    // The icon's diamond and two dashed rings (4 + 8 + 10), the direction line,
    // and eight rays of two dashes each.
    check("and eight rays, two dashes each", sun.lines.count == 22 + 1 + 16, "\(sun.lines.count)")

    var spot = LightDisplay(); spot.kind = .spot
    let s = geometry(.light(spot))
    let cosine = cos(Float.pi / 8), sine = sin(Float.pi / 8)
    let a2 = cosine * cosine, c = cosine * 0.15 - cosine - 0.15
    let blend = sqrt((a2 - a2 * c * c) / (c * c - a2 * c * c))
    check("a spot's rim, on a cone ten units long", has(s, SIMD3(10 * sine, 0, -10 * cosine), 1e-3))
    check("its blend rim inside it", has(s, SIMD3(10 * sine * blend, 0, -10 * cosine), 1e-3),
          "blend \(blend)")
    let silhouette = s.lines.filter { near($0.a, .zero) && near(length($0.b), 10, 1e-3) }
    check("the cone's two silhouette edges, and only those", silhouette.count == 2, "\(silhouette.count)")
    check("the direction line, from the shadow clip start to the cutoff distance",
          hasLine(s, SIMD3(0, 0, -0.05), SIMD3(0, 0, -40)))

    var area = LightDisplay(); area.kind = .area; area.size = 2
    check("a square area light", has(geometry(.light(area)), SIMD3(1, 1, 0)))
    area.shape = .rectangle; area.sizeY = 1
    let rect = geometry(.light(area))
    check("a rectangle, Size by Size Y", has(rect, SIMD3(1, 0.5, 0)) && has(rect, SIMD3(-1, -0.5, 0)))
    area.shape = .disk
    check("a disk", geometry(.light(area)).lines.contains { near(length($0.a), 1, 1e-3) && near($0.a.z, 0) })
    area.shape = .ellipse
    let ellipse = geometry(.light(area)).lines.filter { abs($0.a.z) < 1e-5 && length($0.a) > 0.3 && length($0.a) < 1.1 }
    check("an ellipse", !ellipse.isEmpty && ellipse.allSatisfy { abs($0.a.y) <= 0.5 + 1e-4 }
          && ellipse.contains { near(abs($0.a.x), 1, 1e-3) })
    check("with its direction line", hasLine(rect, SIMD3(0, 0, -0.05), SIMD3(0, 0, -40)))
}

print("\n== empties ==")
do {
    func empty(_ kind: EmptyDisplay.Kind, _ size: Float = 2) -> OverlayGeometry {
        var e = EmptyDisplay(); e.kind = kind; e.size = size
        return geometry(.empty(e))
    }
    let axes = empty(.plainAxes)
    check("plain axes: three lines, the display size each way",
          axes.lines.count == 3 && hasLine(axes, SIMD3(0, -2, 0), SIMD3(0, 2, 0)))
    let arrows = empty(.arrows)
    check("arrows: three axes, six diamonds each, and the letters X, Y and Z",
          arrows.lines.count == 3 + 3 * 6 * 4 + (2 + 3 + 5) && hasLine(arrows, .zero, SIMD3(0, 0, 2)),
          "\(arrows.lines.count)")
    let single = empty(.singleArrow)
    check("single arrow: a shaft and a four-sided head", single.lines.count == 9
          && hasLine(single, .zero, SIMD3(0, 0, 1.5)) && has(single, SIMD3(0, 0, 2)))
    let circle = empty(.circle)
    check("circle: in the XZ plane", circle.lines.count == 64
          && endpoints(circle).allSatisfy { abs($0.y) < 1e-5 && near(length($0), 2, 1e-3) })
    let cube = empty(.cube)
    check("cube: twelve edges", cube.lines.count == 12 && has(cube, SIMD3(2, -2, 2)))
    check("sphere: three circles", empty(.sphere).lines.count == 96)
    let cone = empty(.cone)
    check("cone: eight sides up Y to twice the size", cone.lines.count == 16 && has(cone, SIMD3(0, 4, 0)))
    let image = empty(.image)
    check("image: a frame the display size across, centred by the default offset",
          image.lines.count == 4 && has(image, SIMD3(1, 1, 0)) && has(image, SIMD3(-1, -1, 0)))
}

print("\n== Blender's colours ==")
do {
    let (s, o) = sceneWith(.camera(CameraDisplay()))
    check("unselected: the camera theme's black", ObjectOverlays.wireColor(for: o, in: s) == SIMD4(0, 0, 0, 1))
    s.activeID = o.id
    check("active but not selected is still black", ObjectOverlays.wireColor(for: o, in: s) == SIMD4(0, 0, 0, 1))
    s.selection = [o.id]
    check("selected and active: #FFA028", ObjectOverlays.wireColor(for: o, in: s) == ObjectOverlays.Theme.active
          && near(ObjectOverlays.Theme.active.y, 0xA0 / 255))
    s.activeID = nil
    check("selected: #ED5700", ObjectOverlays.wireColor(for: o, in: s) == ObjectOverlays.Theme.select
          && near(ObjectOverlays.Theme.select.x, 0xED / 255))
    check("and every line is drawn in it",
          ObjectOverlays.geometry(for: o, in: s, view: view).lines.allSatisfy { $0.color == ObjectOverlays.Theme.select })
}

print("\n== a screen-space size is a size on screen ==")
do {
    let p = SIMD3<Float>(2, -1, 0.5)
    let a = view.project(p)!, b = view.project(p + view.right * view.worldPerPoint(at: p) * 50)!
    check("fifty points of offset land fifty points away", abs(hypot(b.x - a.x, b.y - a.y) - 50) < 0.5,
          "\(hypot(b.x - a.x, b.y - a.y))")
}

print("\n== tapping ==")
do {
    var axes = EmptyDisplay()
    axes.kind = .plainAxes
    let (s, e) = sceneWith(.empty(axes), at: SIMD3(3, 0, 0))
    let onLine = view.project(SIMD3(3.8, 0, 0))!
    check("a tap on an empty's line takes it", ObjectOverlayPicking.object(at: onLine, in: s, view: view) === e)
    check("so does one on its origin", ObjectOverlayPicking.object(at: view.project(SIMD3(3, 0, 0))!, in: s, view: view) === e)
    let far = CGPoint(x: onLine.x + 90, y: onLine.y - 120)
    let reach = ObjectOverlayPicking.nearest(to: far, on: e, in: s, view: view)?.distance ?? 0
    check("one out of reach takes nothing", reach > ObjectOverlayPicking.reach
          && ObjectOverlayPicking.object(at: far, in: s, view: view) == nil, "nearest line \(reach) pt away")
    let close = CGPoint(x: onLine.x + 8, y: onLine.y + 8)
    check("a fingertip's width off still takes it", ObjectOverlayPicking.object(at: close, in: s, view: view) === e)

    // A cube between the eye and the empty, over its origin.
    let wall = s.add(.cube)
    wall.location = SIMD3(3, 0, 0) + (viewport.eye - SIMD3(3, 0, 0)) * 0.5
    wall.scale = SIMD3(repeating: 0.5)
    s.selection = []
    check("a mesh in front has the tap", ObjectOverlayPicking.object(at: view.project(SIMD3(3, 0, 0))!, in: s, view: view) == nil)
    wall.location = SIMD3(3, 0, 0) - (viewport.eye - SIMD3(3, 0, 0)) * 0.3
    check("a mesh behind does not", ObjectOverlayPicking.object(at: view.project(SIMD3(3, 0, 0))!, in: s, view: view) === e)

    e.visible = false
    check("a hidden empty cannot be tapped", ObjectOverlayPicking.object(at: onLine, in: s, view: view) == nil)
    e.visible = true

    let other = s.addObject(.empty(axes), named: "Empty", at: SIMD3(3.2, 0, 0), select: false)
    let nearer = view.project(SIMD3(3.2, 0.9, 0))!
    check("of two, the nearer on screen wins", ObjectOverlayPicking.object(at: nearer, in: s, view: view) === other)
}

print("\n== box select ==")
do {
    var axes = EmptyDisplay(); axes.kind = .plainAxes
    let (s, _) = sceneWith(.empty(axes), at: SIMD3(3, 0, 0))
    let cube = s.add(.cube)
    cube.location = SIMD3(-3, 0, 0)
    let p = view.project(SIMD3(3.8, 0, 0))!
    let overLine = CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
    check("a box over an empty's line, clear of its origin, takes it",
          [String]().includingObjectOverlays(in: overLine, scene: s, view: view) == ["Empty"])
    check("a box over nothing takes nothing",
          [String]().includingObjectOverlays(in: CGRect(x: 5, y: 5, width: 20, height: 20), scene: s, view: view).isEmpty)
    check("a mesh box select found is kept, in scene order",
          ["Cube"].includingObjectOverlays(in: overLine, scene: s, view: view) == ["Empty", "Cube"])
    check("with the overlays hidden a box takes none of them, even by their origin, as in Blender",
          ["Empty", "Cube"].includingObjectOverlays(in: overLine, scene: s, view: view, drawn: false) == ["Cube"])

    var shot = CameraDisplay(); shot.displaySize = 2
    let camera = s.addObject(.camera(shot), named: "Camera", at: SIMD3(0, 3, 1), select: false)
    let corner = ObjectOverlays.geometry(for: camera, in: s, view: view).lines[0]
    let mid = view.project((corner.a + corner.b) * 0.5)!
    check("a box across a camera's frame takes the camera",
          [String]().includingObjectOverlays(in: CGRect(x: mid.x - 6, y: mid.y - 6, width: 12, height: 12),
                                             scene: s, view: view).contains("Camera"))
}

print("\n== the transform tools take hold of them ==")
do {
    var axes = EmptyDisplay(); axes.kind = .plainAxes
    let (s, e) = sceneWith(.empty(axes), at: SIMD3(3, 0, 0), selected: true)
    let onLine = view.project(SIMD3(3.8, 0, 0))!
    check("a drag that starts on a selected empty's line moves it",
          TransformGizmo.startsOnSelection(onLine, scene: s, camera: viewport, size: size))
    s.selection = []
    check("one on an unselected empty's line does not",
          !TransformGizmo.startsOnSelection(onLine, scene: s, camera: viewport, size: size))
    s.selection = [e.id]; s.activeID = e.id
    let g = TransformGizmo.make(mode: .translate, scene: s, options: ViewportOptions(), camera: viewport, size: size)
    check("the gizmo sits on its origin", g.map { near($0.origin, SIMD3(3, 0, 0)) } ?? false)
}

print("\n== adding them ==")
do {
    let plain = LastOperator.add(.camera, at: SIMD3(1, 2, 3))
    check("Add Camera, named as Blender names the undo step", plain.name == "Add Camera")
    check("at the cursor, and made the scene's camera if there is none",
          plain.python == "bpy.ops.object.camera_add(location=(1, 2, 3))\n"
          + "if bpy.context.scene.camera is None: bpy.context.scene.camera = bpy.context.object", plain.python)
    var turned = ViewportCamera(); turned.azimuth = 0.9; turned.elevation = 0.45
    let aligned = LastOperator.add(.camera, at: .zero, viewRotation: turned.objectRotation)
    check("facing the way the view faces, as Blender's 3D View adds one",
          aligned.python.hasPrefix("bpy.ops.object.camera_add(align='VIEW', rotation=(") , aligned.python)

    let spot = LastOperator.add(.light(.spot), at: .zero)
    check("Add Light ▸ Spot", spot.name == "Add Light"
          && spot.python == "bpy.ops.object.light_add(type='SPOT', radius=1, location=(0, 0, 0))", spot.python)
    check("Type and Radius, as Blender 5.2.1's light_add takes them",
          spot.parameters.map(\.key) == ["type", "radius"] && spot["radius"] == 1
          && spot.parameters[1].softMin == 0.001 && spot.parameters[1].softMax == 100)
    if case .choice(let options) = spot.parameters[0].kind {
        check("the four types, in Blender's order", options.map(\.identifier) == ["POINT", "SUN", "SPOT", "AREA"]
              && options.map(\.label) == ["Point", "Sun", "Spot", "Area"])
    }
    let cone = LastOperator.add(.empty(.cone), at: .zero)
    check("Add Empty ▸ Cone", cone.name == "Add Empty"
          && cone.python == "bpy.ops.object.empty_add(type='CONE', radius=1, location=(0, 0, 0))", cone.python)
    if case .choice(let options) = cone.parameters[0].kind {
        check("the panel offers every display type, Image too", options.count == 8 && options.last?.identifier == "IMAGE")
    }
    check("the Add menu offers seven, as VIEW3D_MT_empty_add does",
          EmptyDisplay.Kind.addMenu.map(\.label) == ["Plain Axes", "Arrows", "Single Arrow", "Circle", "Cube", "Sphere", "Cone"])

    var again = LastOperator.add(.camera, at: .zero)
    again.subject = "Camera"
    check("adjusting removes the camera's data from cameras, where it lives",
          again.rerunPython.contains("bpy.data.cameras.remove(_d)"), again.rerunPython)
    var lamp = LastOperator.add(.light(.point), at: .zero)
    lamp.subject = "Point"
    check("a light's from lights", lamp.rerunPython.contains("bpy.data.lights.remove(_d)"))
    var box = LastOperator.add(.cube, at: .zero)
    box.subject = "Cube"
    check("and a primitive's from meshes, as before", box.rerunPython.contains("bpy.data.meshes.remove(_d)"))

    for (azimuth, elevation) in [(Float(0.9), Float(0.45)), (2.5, -0.7), (-1.2, 1.4), (0, 0), (3.1, 0.2)] {
        var c = ViewportCamera(); c.azimuth = azimuth; c.elevation = elevation
        let r = c.objectRotation
        let back = simd_float3x3(simd_float4x4(eulerXYZ: ObjectAddition.eulerXYZ(r)))
        let same = near(back.columns.0, r.columns.0, 1e-3) && near(back.columns.1, r.columns.1, 1e-3)
            && near(back.columns.2, r.columns.2, 1e-3)
        check("the view rotation survives its Euler angles (\(azimuth), \(elevation))", same)
        check("and a camera turned by it looks where the view looks",
              near(-r.columns.2, normalize(c.target - c.eye), 1e-4))
    }
}

print("\n== in the scene, and kept ==")
do {
    let s = BKScene(startupFile: false)
    let first = s.addObject(.camera(CameraDisplay()), named: "Camera", at: SIMD3(1, 2, 3))
    check("an added camera is a camera", first.blenderType == "CAMERA" && first.overlayDisplay != nil)
    check("with one vertex and no faces, as the mirror sends it",
          first.mesh.vertices.count == 1 && first.mesh.indices.isEmpty)
    check("selected and active, where it was put",
          s.selection == [first.id] && s.activeID == first.id && near(first.location, SIMD3(1, 2, 3)))
    let second = s.addObject(.camera(CameraDisplay()), named: "Camera", at: .zero)
    check("a second is Camera.001, holding Camera.001",
          second.name == "Camera.001" && second.overlayDisplay?.dataName == "Camera.001")
    check("the suffix is not stacked", s.uniqueDataName("Camera.001", type: "CAMERA") == "Camera.002")

    let copies = s.duplicateSelection()
    check("a duplicate is a camera too, with data of its own",
          copies.count == 1 && copies[0].blenderType == "CAMERA" && copies[0].overlayDisplay?.dataName == "Camera.002",
          "\(copies.map { ($0.name, $0.blenderType, $0.overlayDisplay?.dataName ?? "-") })")

    var spot = LightDisplay(); spot.kind = .spot; spot.spotSize = 1; spot.dataName = "Spot"
    let light = s.addObject(.light(spot), named: "Spot", at: .zero)
    let snapshot = s.snapshot()
    s.objects = []
    s.restore(snapshot)
    let restored = s.objects.first { $0.name == "Spot" }
    check("undo brings a light back as a light", lightOf(restored?.overlayDisplay)?.spotSize == 1
          && restored?.mesh.indices.isEmpty == true)

    let data = try! JSONEncoder().encode(snapshot)
    let decoded = try! JSONDecoder().decode(SceneSnapshot.self, from: data)
    s.restore(decoded)
    check("so does a saved file", lightOf(s.objects.first { $0.name == "Spot" }?.overlayDisplay)?.spotSize == 1)
    let old = #"{"version":1,"objects":[{"name":"Cube","kind":"cube","location":[0,0,0],"rotation":[0,0,0],"scale":[1,1,1],"color":[1,1,1,1],"visible":true,"modifiers":[]}],"selection":[],"active":null}"#
    check("and a file from before still opens",
          (try? JSONDecoder().decode(SceneSnapshot.self, from: Data(old.utf8)))?.objects.first?.overlayDisplay == nil)

    s.selection = Set(s.objects.filter { $0.name == "Spot" }.map(\.id))
    s.copySelection()
    s.pasteClipboard()
    let pasted = s.objects.last
    check("a pasted light is a light", pasted?.blenderType == "LIGHT" && pasted?.name == "Spot.001"
          && pasted?.overlayDisplay?.dataName == "Spot.001", "\(String(describing: pasted?.name))")
    _ = light

    first.blenderType = "MESH"
    check("an object that has become a mesh is drawn as one", first.overlayDisplay == nil)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
