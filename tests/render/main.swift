import Foundation
import simd

// The Render panel's decisions, without Blender: what it asks for, what it
// names the file, and what looking through a camera does to the 3D View.
// scripts/run-render-blender-check.sh runs the same requests through Blender.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

print("== what the render asks Blender for ==")
do {
    let request = RenderRequest(engine: .cycles, quality: .good, width: 1280, height: 720,
                                source: .sceneCamera, output: "/tmp/a b.png")
    let python = request.python
    check("the engine, size and file are set", python.contains("scene.render.engine = \"CYCLES\"")
          && python.contains("scene.render.resolution_x = 1280")
          && python.contains("scene.render.resolution_y = 720")
          && python.contains("scene.render.resolution_percentage = 100")
          && python.contains("scene.render.image_settings.file_format = 'PNG'"), python)
    check("a path with a space is quoted", python.contains("scene.render.filepath = \"/tmp/a b.png\""))
    check("it renders and writes the image", python.contains("bpy.ops.render.render(write_still=True)"))
    check("a missing camera is refused in words, not a traceback about None",
          python.contains("if scene.camera is None:") && python.contains("This scene has no camera."))
    check("samples are set for whichever engine runs, and only if it is there",
          python.contains("if hasattr(scene, 'cycles'):") && python.contains("scene.cycles.samples = 128")
          && python.contains("if hasattr(scene, 'eevee'):") && python.contains("scene.eevee.taa_render_samples = 64"))
    check("nothing is made or removed when the scene's camera is used",
          !python.contains("bpy.data.cameras.new") && !python.contains("objects.remove"))

    for (quality, cycles, eevee) in [(RenderRequest.Quality.draft, 16, 8), (.good, 128, 64), (.best, 1024, 256)] {
        check("\(quality.rawValue) is \(cycles) Cycles samples and \(eevee) Eevee",
              quality.cyclesSamples == cycles && quality.eeveeSamples == eevee)
    }
    check("Blender's own 4096-sample default is not what a tablet gets",
          RenderRequest.Quality.best.cyclesSamples < 4096)
    check("Solid needs no lights; the other two do",
          !RenderRequest.Engine.workbench.usesSceneLighting
          && RenderRequest.Engine.cycles.usesSceneLighting && RenderRequest.Engine.eevee.usesSceneLighting)
    check("the engine names are the ones this Blender has",
          RenderRequest.Engine.allCases.map(\.rawValue) == ["CYCLES", "BLENDER_EEVEE", "BLENDER_WORKBENCH"])
}

print("\n== which device renders ==")
do {
    let cycles = RenderRequest(engine: .cycles, output: "/tmp/a.png", deviceReport: "/tmp/dev.txt").python
    check("Cycles is pointed at Metal, because Blender starts at NONE and renders on the CPU",
          cycles.contains("_prefs.compute_device_type = 'METAL'")
          && cycles.contains("scene.cycles.device = 'GPU' if _metal else 'CPU'"), cycles)
    check("the devices are refreshed before they are read, and only Metal is used",
          cycles.contains("_prefs.refresh_devices()") && cycles.contains("_prefs.get_devices()")
          && cycles.contains("_d.use = _d.type == 'METAL'"))
    check("a machine with no Metal falls back rather than failing the render",
          cycles.contains("except Exception as _error:") && cycles.contains("scene.cycles.device = 'CPU'"))
    check("the device is written where the panel can read it",
          cycles.contains("open(\"/tmp/dev.txt\", 'w').write(_device)"), cycles)
    let eevee = RenderRequest(engine: .eevee, output: "/tmp/a.png").python
    check("Eevee needs no device set: it draws with the GPU either way",
          !eevee.contains("compute_device_type") && eevee.contains("_device = \"Eevee on the GPU\""), eevee)
    check("nothing is written when the panel did not ask",
          !RenderRequest(engine: .cycles, output: "/tmp/a.png").python.contains(".write(_device)"))
}

print("\n== rendering the 3D View ==")
do {
    let view = RenderRequest.ViewCamera(location: SIMD3(1, -2, 3), rotation: SIMD3(0.5, 0, 0.25),
                                        fovY: 0.6911, isOrthographic: false, orthoScale: 6)
    let python = RenderRequest(engine: .eevee, source: .view(view), output: "/tmp/out.png").python
    check("a camera is made, linked, placed and turned",
          python.contains("bpy.data.cameras.new(\"3D View Render\")")
          && python.contains("scene.collection.objects.link(_camera)")
          && python.contains("_camera.location = (1.0000, -2.0000, 3.0000)")
          && python.contains("_camera.rotation_euler = (0.5000, 0.0000, 0.2500)"), python)
    check("it is fitted to the view's vertical angle",
          python.contains("_data.sensor_fit = 'VERTICAL'") && python.contains("_data.angle_y = 0.691100"))
    check("the scene's own camera is put back, and the temporary one removed, even if the render raises",
          python.contains("_was = scene.camera") && python.contains("try:") && python.contains("finally:")
          && python.contains("scene.camera = _was")
          && python.contains("bpy.data.objects.remove(_camera)")
          && python.contains("bpy.data.cameras.remove(_data)"), python)
    check("no camera guard, because it makes its own", !python.contains("if scene.camera is None:"))

    let ortho = RenderRequest(source: .view(RenderRequest.ViewCamera(
        location: .zero, rotation: .zero, fovY: 0.7, isOrthographic: true, orthoScale: 9)), output: "/tmp/o.png").python
    check("an orthographic view renders orthographic, at the size it shows",
          ortho.contains("_data.type = 'ORTHO'") && ortho.contains("_data.ortho_scale = 9.0000"))
}

print("\n== where the render goes ==")
do {
    let stamp = DateComponents(calendar: Calendar(identifier: .gregorian),
                               timeZone: TimeZone.current, year: 2026, month: 9, day: 18,
                               hour: 14, minute: 5, second: 9).date!
    let name = RenderRequest.fileName(at: stamp)
    check("named by date, so renders sort and none is overwritten",
          name == "Render 2026-09-18 at 14.05.09.png", name)
    check("no colons, which the Files app shows as slashes", !name.contains(":"))
}

print("\n== progress while it renders ==")
do {
    let request = RenderRequest(engine: .cycles, output: "/tmp/a.png", progressReport: "/tmp/p.txt")
    let python = request.python
    check("Blender's own progress is written where the panel can read it",
          python.contains("bpy.app.handlers.render_stats.append(_bk_progress)")
          && python.contains("open(\"/tmp/p.txt\", 'w')"), python)
    check("the handler is taken off again, even if the render raises",
          python.contains("finally:")
          && python.contains("bpy.app.handlers.render_stats.remove(_bk_progress)"))
    check("without it, no handler is added",
          !RenderRequest(engine: .cycles, output: "/tmp/a.png").python.contains("render_stats"))

    // The strings are Blender's own, taken from a running render rather than
    // from the manual: the two engines word it differently, and the Cycles
    // one leads with a clock, which the first version of this read as the
    // sample count.
    let cycles128 = RenderingWorkspaceProgress.read(
        "Remaining: 03:15.18 | Mem: 5976M | Sample 1/128 (Using optimized kernels)")
    check("Cycles' line is read past its clock and memory",
          cycles128.fraction.map { abs($0 - 1.0 / 128) < 1e-9 } == true, "\(cycles128)")
    check("and shown as the sample and the time left",
          cycles128.text == "Sample 1 of 128 · 3:15 left", cycles128.text)
    let eevee = RenderingWorkspaceProgress.read("Rendering 25 / 64 samples")
    check("Eevee words it differently and is read too",
          eevee.fraction.map { abs($0 - 25.0 / 64) < 1e-9 } == true && eevee.text == "Sample 25 of 64",
          "\(eevee)")
    let done = RenderingWorkspaceProgress.read("Time: 00:09.62 (Saving: 00:00.21)\n")
    check("the closing time line fills nothing", done.fraction == nil, "\(done)")
    let stage = RenderingWorkspaceProgress.read("Loading render kernels (may take a few minutes the first time)")
    check("a stage is shown as it is", stage.fraction == nil
          && stage.text.hasPrefix("Loading render kernels"), "\(stage)")
    check("a count beyond the total cannot overfill the bar",
          RenderingWorkspaceProgress.read("Sample 200/128").fraction == 1)
    check("an hour left reads as an hour",
          RenderingWorkspaceProgress.read("Remaining: 01:04:09.10 | Sample 2/4096").text
          == "Sample 2 of 4096 · 1:04:09 left",
          RenderingWorkspaceProgress.read("Remaining: 01:04:09.10 | Sample 2/4096").text)
}

print("\n== typing into a number field ==")
do {
    check("a value edits without its unit or trailing zeros",
          NumberFieldUnit.meters.editable(2.5) == "2.5" && NumberFieldUnit.none.editable(0.25) == "0.25"
          && NumberFieldUnit.count.editable(7.4) == "7", NumberFieldUnit.meters.editable(2.5))
    check("a rotation edits in the degrees it is shown in",
          NumberFieldUnit.degrees.editable(.pi / 2) == "90", NumberFieldUnit.degrees.editable(.pi / 2))
    check("a percentage too", NumberFieldUnit.percent.editable(0.25) == "25")
    check("typing a number reads it back",
          NumberFieldUnit.none.typed("1250") == 1250 && NumberFieldUnit.meters.typed("0.35") == 0.35)
    check("with the unit typed too, or a comma, or spaces",
          NumberFieldUnit.meters.typed(" 0.35 m ") == 0.35 && NumberFieldUnit.none.typed("1,5") == 1.5
          && NumberFieldUnit.percent.typed("50%") == 0.5)
    check("degrees come back as radians",
          NumberFieldUnit.degrees.typed("90").map { abs($0 - .pi / 2) < 1e-6 } == true)
    check("a negative number is a number", NumberFieldUnit.none.typed("-2.5") == -2.5)
    check("nonsense leaves the value alone rather than reading as zero",
          NumberFieldUnit.none.typed("") == nil && NumberFieldUnit.none.typed("abc") == nil
          && NumberFieldUnit.none.typed("1.2.3") == nil)
    check("and so does an infinity", NumberFieldUnit.none.typed("inf") == nil)
    check("what a field shows at rest still carries its unit",
          NumberFieldUnit.meters.format(0.35) == "0.350 m" && NumberFieldUnit.degrees.format(.pi) == "180.0°")
}

print("\n== looking through a camera ==")
do {
    let scene = BKScene()
    let object = BKObject(name: "Camera", kind: .cube)
    object.location = SIMD3(4, -6, 3)
    // Pointing down at the origin: the rotation Blender gives a camera aligned
    // to a view from there.
    let toOrigin = simd_normalize(SIMD3<Float>(0, 0, 0) - object.location)
    let back = -toOrigin
    let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), back))
    let up = simd_cross(back, right)
    object.rotation = ObjectAddition.eulerXYZ(simd_float3x3(right, up, back))
    var display = CameraDisplay(dataName: "Camera", fields: [:])
    display.lens = 50
    display.sensorWidth = 36
    display.aspectX = 1920
    display.aspectY = 1080
    object.install(.camera(display))
    scene.objects = [object]

    check("the scene finds its cameras", scene.cameras.count == 1 && scene.lights.isEmpty)
    check("and knows there is no scene camera until Blender says so", scene.sceneCamera == nil)

    var view = ViewportCamera()
    view.distance = 10
    check("looking through it succeeds", view.look(through: object))
    let eye = view.eye
    check("the view stands where the camera stands", simd_distance(eye, object.location) < 1e-3,
          "\(eye) vs \(object.location)")
    let direction = simd_normalize(view.target - eye)
    check("and looks the way the camera looks", simd_dot(direction, toOrigin) > 0.9999,
          "\(direction) vs \(toOrigin)")
    // A 50 mm lens on a 36 mm sensor at 16:9: 39.6° across, 22.9° down.
    let expected = 2 * atan(tan(2 * atan(Float(18) / 50) / 2) / (1920.0 / 1080.0))
    check("and shows what it shows, top to bottom", abs(view.fovY - expected) < 1e-4,
          "\(view.fovY) vs \(expected)")
    check("it is perspective, as the camera is", !view.isOrthographic)

    var portrait = display
    portrait.aspectX = 1080
    portrait.aspectY = 1920
    check("a portrait frame fits the sensor the other way",
          abs(portrait.verticalAngle - 2 * atan(Float(18) / 50)) < 1e-5, "\(portrait.verticalAngle)")
    var vertical = display
    vertical.sensorFit = .vertical
    vertical.sensorHeight = 24
    check("a vertically fitted camera uses its sensor height",
          abs(vertical.verticalAngle - 2 * atan(Float(12) / 50)) < 1e-5, "\(vertical.verticalAngle)")

    var orthoDisplay = display
    orthoDisplay.projection = .orthographic
    orthoDisplay.orthoScale = 8
    object.install(.camera(orthoDisplay))
    check("an orthographic camera turns the view orthographic", view.look(through: object) && view.isOrthographic)
    let halfHeight = view.distance * tan(view.fovY / 2)
    check("showing the height it covers", abs(halfHeight * 2 - 8 / (1920.0 / 1080.0)) < 1e-3, "\(halfHeight * 2)")

    let mesh = BKObject(name: "Cube", kind: .cube)
    check("looking through something that is not a camera does nothing", !view.look(through: mesh))
}

print("\n== the view as a camera ==")
do {
    var view = ViewportCamera()
    view.azimuth = 0.9
    view.elevation = 0.45
    view.distance = 12
    view.target = SIMD3(1, 2, 0)
    let render = view.renderCamera
    check("it is taken from where the view is", simd_distance(render.location, view.eye) < 1e-5)
    check("turned the way Blender aligns an object to the view",
          render.rotation == ObjectAddition.eulerXYZ(view.objectRotation))
    check("with the view's own angle", render.fovY == view.fovY)
    var ortho = view
    ortho.isOrthographic = true
    check("an orthographic view carries the height it covers",
          abs(ortho.renderCamera.orthoScale - 2 * 12 * tan(view.fovY / 2)) < 1e-4)
}

print("\n== the Python the panel and the menus write ==")
do {
    check("setting the scene camera", Bpy.setSceneCamera("Camera 2")
          == "bpy.context.scene.camera = bpy.data.objects[\"Camera 2\"]")
    let aim = Bpy.alignCameraToView("Camera", RenderRequest.ViewCamera(
        location: SIMD3(1, 2, 3), rotation: SIMD3(0.1, 0.2, 0.3), fovY: 0.7))
    check("aiming a camera at the view moves and turns it",
          aim.contains("bpy.data.objects[\"Camera\"].location = (1.0000, 2.0000, 3.0000)")
          && aim.contains("bpy.data.objects[\"Camera\"].rotation_euler = (0.1000, 0.2000, 0.3000)"), aim)
    check("a light's power", Bpy.setObjectData("Point", "energy", 250)
          == "bpy.data.objects[\"Point\"].data.energy = 250.0000")
    check("a light's colour", Bpy.setObjectData("Point", "color", colour: SIMD3(1, 0.5, 0.25))
          == "bpy.data.objects[\"Point\"].data.color = (1.0000, 0.5000, 0.2500)")
    check("a light's type", Bpy.setObjectData("Point", "type", choice: "SUN")
          == "bpy.data.objects[\"Point\"].data.type = \"SUN\"")
    check("a camera's focal length", Bpy.setObjectData("Camera", "lens", 35)
          == "bpy.data.objects[\"Camera\"].data.lens = 35.0000")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
