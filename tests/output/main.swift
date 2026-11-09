import Foundation

// Render Animation and the Render, Output and World tabs, without Blender:
// what the requests ask for, how the settings Blender reports are read, the
// Frame Rate menu's labels, the progress and outcome files, and the wiring a
// source scan can see (the keys, the menus, the tabs). Blender runs the same
// strings in scripts/run-renderanim-blender-check.sh.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

print("== Render Animation's request ==")
do {
    let animation = RenderRequest.Animation(video: true, frames: "/tmp/f.txt", cancel: "/tmp/c", result: "/tmp/r.json")
    let python = RenderRequest(engine: .eevee, source: .sceneCamera, output: "/tmp/Animation 1",
                               progressReport: "/tmp/p.txt", animation: animation).python
    check("it is Blender's own Render Animation, through the module",
          python.contains("_blenderkit_render.render_animation(\"/tmp/Animation 1\", video=True, "
                          + "frames=\"/tmp/f.txt\", cancel=\"/tmp/c\", result=\"/tmp/r.json\")"), python)
    check("not a still", !python.contains("write_still"))
    check("the output path is the module's to set, not the request's",
          !python.contains("scene.render.filepath ="), python)
    check("everything it sets is put back, even if it raises",
          python.contains("_bk_saved = _blenderkit_render.save(scene)")
          && python.contains("finally:\n    _blenderkit_render.restore(scene, _bk_saved)"), python)
    check("with no size or quality asked, the scene's own are used",
          !python.contains("resolution_x") && !python.contains("taa_render_samples ="), python)
    check("the scene's camera only, refused in words without one",
          python.contains("if scene.camera is None:") && python.contains("then Render Animation"))
    check("Blender's progress is read as it goes, and the handler taken off after",
          python.contains("bpy.app.handlers.render_stats.append(_bk_progress)")
          && python.contains("bpy.app.handlers.render_stats.remove(_bk_progress)"))
    check("a script with it starts Blender's GPU module on the main thread first (\"render.render\" in its text)",
          ScriptThread.mayStartGPU(python))
    check("and arms the first-Cycles-render warning, as a still render does", CyclesKernels.mayRender(python))
    let plain = RenderRequest(engine: .workbench, output: "/tmp/A",
                              animation: RenderRequest.Animation(video: false)).python
    check("the scene's own Output when it was chosen, and no files it was not given",
          plain.contains("video=False, frames=None, cancel=None, result=None"), plain)
    let ranged = RenderRequest(engine: .workbench, width: 64, height: 36, output: "/tmp/A",
                               animation: RenderRequest.Animation(video: true, range: 1...3)).python
    check("a range for this render only (Test All Features' three frames), put back by restore",
          ranged.contains("scene.frame_start = 1") && ranged.contains("scene.frame_end = 3")
          && ranged.contains("scene.frame_step = 1"), ranged)
    let site = source("Resources/python/site/_blenderkit_render.py")
    check("restore knows the range, the frame, the engine, the format and the samples",
          ["('scene', 'frame_start')", "('scene', 'frame_end')", "('scene', 'frame_current')",
           "('render', 'engine')", "('image_settings', 'media_type')", "('ffmpeg', 'codec')",
           "('cycles', 'samples')", "('render', 'filepath')"].allSatisfy(site.contains))
    check("the media type is put back before the format and the colour, which it resets",
          site.range(of: "('image_settings', 'media_type')")!.lowerBound
          < site.range(of: "('image_settings', 'file_format')")!.lowerBound
          && site.range(of: "('image_settings', 'file_format')")!.lowerBound
          < site.range(of: "('image_settings', 'color_mode')")!.lowerBound)
}

print("\n== the still render keeps the scene's settings ==")
do {
    let panel = RenderRequest(engine: .cycles, cyclesDevice: .cpu, source: .sceneCamera, output: "/tmp/a.png").python
    check("the panel's request sets no size and no samples: the scene's own",
          !panel.contains("resolution_x") && !panel.contains("cycles.samples"), panel)
    check("Cycles' Device CPU is the CPU, with no Metal set up",
          panel.contains("scene.cycles.device = 'CPU'") && !panel.contains("compute_device_type"), panel)
    check("a still is a PNG even from a video Output (Media Type first)",
          panel.contains("scene.render.image_settings.media_type = 'IMAGE'")
          && panel.contains("scene.render.image_settings.file_format = 'PNG'"), panel)
    check("and it is put back", panel.contains("_blenderkit_render.restore(scene, _bk_saved)"))
    let gpu = RenderRequest(engine: .cycles, output: "/tmp/a.png").python
    check("GPU Compute is Metal, as before", gpu.contains("_prefs.compute_device_type = 'METAL'"))
    check("the panel's file names: a still's and an animation's",
          RenderRequest.fileName(at: Date(timeIntervalSince1970: 0)).hasPrefix("Render ")
          && RenderRequest.animationName(at: Date(timeIntervalSince1970: 0)).hasPrefix("Animation ")
          && !RenderRequest.animationName().hasSuffix(".png") && !RenderRequest.animationName().contains(":"))
    let runtime = source("Sources/BlenderLocalBridge/BpyRuntime.swift")
    check("a render records no undo step (runScript's recordsUndo)",
          runtime.contains("public func runScript(_ source: String, scene: BKScene, recordsUndo: Bool)")
          && runtime.contains("if recordsUndo {\n            pushUndo(\"Run Script\")"))
    let panelSource = source("Sources/BlenderLocalUI/Workspaces/PaintRenderWorkspaces.swift")
    check("and the Render panel asks for none",
          panelSource.contains("session.runScript(request.python, scene: scene, recordsUndo: false)"))
}

print("\n== the Render panel's quick choices are the scene's settings ==")
do {
    for (quality, engine, expected) in [(RenderRequest.Quality.draft, RenderRequest.Engine.eevee,
                                         "bpy.context.scene.eevee.taa_render_samples = 8"),
                                        (.best, .cycles, "bpy.context.scene.cycles.samples = 1024")] {
        check("\(quality.rawValue) in \(engine.label) writes Render Properties ▸ Sampling",
              RenderSettingsBpy.quality(quality, engine: engine) == expected,
              RenderSettingsBpy.quality(quality, engine: engine) ?? "nil")
    }
    check("Workbench has no samples to set", RenderSettingsBpy.quality(.good, engine: .workbench) == nil)
    check("the chip reads the scene's samples back as a quality",
          RenderRequest.Quality.matching(samples: 64, engine: .eevee) == .good
          && RenderRequest.Quality.matching(samples: 128, engine: .cycles) == .good
          && RenderRequest.Quality.matching(samples: 300, engine: .cycles) == nil)
    let cycles = RenderSettingsBpy.engine("CYCLES")
    check("choosing Cycles also turns a CPU Device to GPU Compute, in the same step",
          cycles.hasPrefix("bpy.context.scene.render.engine = \"CYCLES\"")
          && cycles.contains("bpy.context.scene.cycles.device = 'GPU'"), cycles)
    check("other engines are just the engine",
          RenderSettingsBpy.engine("BLENDER_EEVEE") == "bpy.context.scene.render.engine = \"BLENDER_EEVEE\"")
}

print("\n== reading the settings Blender reports ==")
let sample = """
{"engine": "BLENDER_EEVEE", "engines": [["BLENDER_EEVEE", "EEVEE"], ["BLENDER_WORKBENCH", "Workbench"], ["CYCLES", "Cycles"]], \
"resolution_x": 1920, "resolution_y": 1080, "resolution_percentage": 50, "fps": 30, "fps_base": 1.001, \
"frame_start": 1, "frame_end": 250, "frame_step": 3, "media_type": "IMAGE", "file_format": "PNG", \
"color_mode": "RGBA", "color_modes": [["BW", "BW"], ["RGB", "RGB"], ["RGBA", "RGBA"]], "color_depth": "8", \
"color_depths": [["8", "8"], ["16", "16"]], "quality": 90, "compression": 15, "exr_codec": "ZIP", \
"ffmpeg_format": "MPEG1", "ffmpeg_codec": "NONE", "ffmpeg_crf": "NONE", "ffmpeg_preset": "GOOD", \
"is_movie": false, "output_untouched": true, "film_transparent": false, "use_motion_blur": false, \
"has_camera": true, "ffmpeg_available": true, \
"cycles": {"device": "CPU", "samples": 4096, "use_adaptive_sampling": true, "adaptive_threshold": 0.01, \
"time_limit": 0.0, "use_denoising": true, "denoiser": "OPENIMAGEDENOISE", \
"denoisers": [["OPENIMAGEDENOISE", "OpenImageDenoise"]], "max_bounces": 12}, \
"eevee": {"taa_render_samples": 64, "taa_samples": 16, "use_raytracing": false, "use_shadows": true, \
"shadow_ray_count": 1, "shadow_step_count": 6}, \
"workbench": {"light": "STUDIO", "color_type": "MATERIAL", "single_color": [0.8, 0.8, 0.8], "render_aa": "8"}, \
"color": {"display_device": "sRGB", "display_devices": [["sRGB", "sRGB"]], "view_transform": "AgX", \
"view_transforms": [["Standard", "Standard"], ["AgX", "AgX"]], "look": "None", \
"looks": [["None", "None"], ["AgX - Punchy", "Punchy"]], "exposure": 0.0, "gamma": 1.0}, \
"world": {"name": "World", "use_nodes": true, "node": "Background", "node_label": "Background", \
"background": true, "color": [0.05, 0.05, 0.05], "strength": 1.0, "color_linked": null, "strength_linked": null}}
"""
do {
    let parsed = RenderSettings.parse("a line Blender printed first\n" + sample)
    check("the last line is the settings", parsed != nil)
    if let s = parsed {
        check("the engine, its menu and the panel's engine", s.engine == "BLENDER_EEVEE" && s.engines.count == 3
              && s.engines[2].name == "Cycles" && s.renderEngine == .eevee)
        check("a look's identifier and the name its menu draws",
              s.color.looks[1] == RenderSettings.Choice("AgX - Punchy", "Punchy"))
        check("the size Blender renders at is X and Y times %", s.renderSize == (960, 540) ? true : false,
              "\(s.renderSize)")
        check("the samples of the engine in use", s.samples == 64)
        check("frames 1 to 250 by 3 are 84", s.frameCount == 84, "\(s.frameCount)")
        check("an untouched Output renders an MPEG-4 video, the app's default",
              s.animationOutput == .video(container: "MPEG4", codec: "H264", isDefault: true)
              && s.animationOutput.summary == "MPEG-4 video, H.264" && s.animationOutput.playable,
              s.animationOutput.summary)
        var chosen = s
        chosen.outputUntouched = false
        check("a chosen PNG renders PNG frames", chosen.animationOutput == .frames(format: "PNG")
              && chosen.animationOutput.summary == "PNG frames" && !chosen.animationOutput.playable)
        chosen.isMovie = true
        chosen.ffmpegFormat = "QUICKTIME"
        chosen.ffmpegCodec = "H265"
        check("a chosen video, as chosen", chosen.animationOutput.summary == "QuickTime video, H.265 / HEVC"
              && chosen.animationOutput.playable)
        chosen.ffmpegAvailable = false
        chosen.outputUntouched = true
        chosen.isMovie = false
        check("no video by default where Blender has no FFmpeg", chosen.animationOutput == .frames(format: "PNG"))
        check("the World's Background", s.world?.background == true && s.world?.strength == 1
              && s.world?.colorLinked == nil)
    }
    let worldStart = sample.range(of: "\"world\": {")!.lowerBound
    let noWorld = String(sample[..<worldStart]) + "\"world\": null}"
    check("a scene with no World reads as none", RenderSettings.parse(noWorld).map { $0.world == nil } == true)
    check("a line that is not the settings is no settings", RenderSettings.parse("Traceback …") == nil)
}

print("\n== Blender's Frame Rate menu ==")
do {
    check("the presets, in the menu's natural sort",
          FrameRatePreset.all.map(\.name) == ["6", "8", "12", "23.98", "24", "25", "29.97", "30", "50", "59.94",
                                              "60", "120", "240"])
    for (fps, base, label) in [(24, 1.0, "24 fps"), (24, 1.001, "23.98 fps"), (30, 1.001, "29.97 fps"),
                               (60, 1.001, "59.94 fps"), (120, 1.0, "120 fps"), (14, 1.0, "Custom (14 fps)"),
                               (30, 1.5, "Custom (20 fps)"), (25, 1.002, "Custom (24.95 fps)")] {
        check("\(fps) over \(base) reads \"\(label)\"", FrameRatePreset.label(fps: fps, base: base) == label,
              FrameRatePreset.label(fps: fps, base: base))
    }
    check("a preset's rate is no custom one, and shows no FPS and Base",
          !FrameRatePreset.isCustom(fps: 30, base: 1.001) && FrameRatePreset.isCustom(fps: 14, base: 1))
    check("a preset is found by its two values", FrameRatePreset.preset(fps: 24, base: 1.001)?.name == "23.98"
          && FrameRatePreset.preset(fps: 24, base: 1)?.name == "24" && FrameRatePreset.preset(fps: 14, base: 1) == nil)
    check("choosing one runs its preset file's two lines",
          RenderSettingsBpy.frameRate(FrameRatePreset.all[3])
          == "bpy.context.scene.render.fps = 24\nbpy.context.scene.render.fps_base = 1.001",
          RenderSettingsBpy.frameRate(FrameRatePreset.all[3]))
}

print("\n== the other writes ==")
do {
    check("a whole number for an int", RenderSettingsBpy.set("render.resolution_x", int: 1280)
          == "bpy.context.scene.render.resolution_x = 1280")
    check("a float always reads as one", RenderSettingsBpy.set("view_settings.exposure", float: 1)
          == "bpy.context.scene.view_settings.exposure = 1.0")
    check("a choice is quoted", RenderSettingsBpy.set("view_settings.look", choice: "AgX - Punchy")
          == "bpy.context.scene.view_settings.look = \"AgX - Punchy\"")
    check("a non-finite number never reaches Blender", RenderSettingsBpy.set("view_settings.gamma", float: .nan)
          == "bpy.context.scene.view_settings.gamma = 0.0")
    check("File Format goes through the module (Media Type first)",
          RenderSettingsBpy.fileFormat("FFMPEG").contains("_blenderkit_render.set_file_format(\"FFMPEG\")"))
    check("New World is the module's, and its step Blender's operator name",
          RenderSettingsBpy.newWorld.contains("_blenderkit_render.world_new()")
          && RenderSettingsBpy.newWorldUndo == "New World")
    check("the World's Color is written scene-linear, clamped below at 0",
          RenderSettingsBpy.worldColor(SIMD3(0.5, -1, 2)).contains("world_background(color=(0.5, 0.0, 2.0))"),
          RenderSettingsBpy.worldColor(SIMD3(0.5, -1, 2)))
    check("its Strength, never below 0", RenderSettingsBpy.worldStrength(-3).contains("strength=0.0"))
    var worst = 0.0
    for i in 0...100 {
        let c = Double(i) / 100
        worst = max(worst, abs(RenderSettingsBpy.sRGB(fromLinear: RenderSettingsBpy.linear(fromSRGB: c)) - c))
    }
    check("sRGB to linear and back is the same colour", worst < 1e-9, "\(worst)")
    check("Blender's 0.05 grey World is 0.248 in sRGB, as its picker shows it",
          abs(RenderSettingsBpy.sRGB(fromLinear: 0.05) - 0.2480) < 1e-3, "\(RenderSettingsBpy.sRGB(fromLinear: 0.05))")
}

print("\n== the frame in hand and the outcome ==")
do {
    let frame = RenderAnimationFrame("12 250 23\n")
    check("\"index total frame\" is read", frame?.index == 12 && frame?.total == 250 && frame?.frame == 23)
    check("and said as the panel says it", frame?.text == "Frame 12 of 250")
    check("the bar is the frames done and the samples of the one in hand",
          abs((frame?.fraction(within: 0.5) ?? 0) - 11.5 / 250) < 1e-12)
    check("a frame's own bar cannot overfill the whole", RenderAnimationFrame("3 3 3")?.fraction(within: 2) == 1)
    check("a half-written file is nothing", RenderAnimationFrame("12 ") == nil && RenderAnimationFrame("1 0 1") == nil)
    let video = RenderAnimationResult.parse("""
    {"kind": "video", "path": "/x/Animation 1.mp4", "frames": 2, "total": 10, "cancelled": true, \
    "last": null, "error": null, "fps": 24.0}
    """)
    check("the outcome: a video, cancelled after 2 of 10", video?.isVideo == true && video?.frames == 2
          && video?.total == 10 && video?.cancelled == true && video?.fps == 24)
    let frames = RenderAnimationResult.parse("""
    {"kind": "images", "path": "/x/Animation 1", "frames": 3, "total": 3, "cancelled": false, \
    "last": "/x/Animation 1/0003.png", "error": null, "fps": 29.97002997002997}
    """)
    check("or a folder of frames", frames?.isVideo == false && frames?.last == "/x/Animation 1/0003.png")
}

print("\n== Cycles' stage lines ==")
do {
    let kernels = RenderingWorkspaceProgress.read(
        "Mem:5825.27M, Peak:5825.27M | Loading render kernels (may take a few minutes the first time)")
    check("the stage is shown, not the memory before it", kernels.text.hasPrefix("Loading render kernels")
          && kernels.fraction == nil, kernels.text)
    check("a line of bookkeeping alone is shown as it is",
          RenderingWorkspaceProgress.read("Mem: 1M").text == "Mem: 1M")
    check("the closing time line is still the time line",
          RenderingWorkspaceProgress.read("Time: 00:09.62 (Saving: 00:00.21)").text.hasPrefix("Time:"))
}

print("\n== the wiring ==")
do {
    let keymap = source("Sources/BlenderLocalApp/ViewportKeymap.swift")
    for (chord, title, action) in [("f12", "Render Image", "renderImage"), ("ctrl+f12", "Render Animation", "renderAnimation"),
                                   ("f11", "View Render", "viewRender"), ("ctrl+f11", "View Animation", "viewAnimation")] {
        check("\(chord) is Blender's \(title)",
              keymap.contains("ViewportKey(chord: \"\(chord)\", title: \"\(title)\"")
              && keymap.contains("$0.renderAction?(.\(action))"))
    }
    check("F11 is a key the 3D View carries", keymap.contains("case \"f11\": input = UIKeyCommand.f11"))
    let menus = source("Sources/BlenderLocalUI/Chrome/TopBarMenus.swift")
    let topBar = source("Sources/BlenderLocalUI/Chrome/TopBar.swift")
    check("the top bar draws Blender's Render menu, beside File", topBar.contains("RenderMenu(session: session)"))
    check("with its four rows live, and Render Audio… still greyed",
          ["RenderPanelAction.renderImage.post()", "RenderPanelAction.renderAnimation.post()",
           "RenderPanelAction.viewRender.post()", "RenderPanelAction.viewAnimation.post()",
           "BUnavailable(\"Render Audio…\")"].allSatisfy(menus.contains)
          && !menus.contains("BUnavailable(\"Render Animation\")") && !menus.contains("BUnavailable(\"View Render\")"))
    let app = source("Sources/BlenderLocalApp/BlenderLocalApp.swift")
    check("and the Mac menu bar has it", app.contains("RenderCommands()")
          && source("Sources/BlenderLocalApp/RenderCommands.swift").contains("CommandMenu(\"Render\")"))
    let tabs = source("Sources/BlenderLocalUI/Editors/PropertiesTabs.swift")
    check("the Render, Output and World tabs are built", tabs.contains("case .render, .output, .scene, .world,"))
    let view = source("Sources/BlenderLocalUI/Editors/PropertiesView.swift")
    check("and drawn", view.contains("case .render, .output, .world:")
          && view.contains("SceneRenderTabs(tab: tab, scene: scene, session: session, bridge: bridge)"))
    let tabsSource = source("Sources/BlenderLocalUI/Editors/RenderPropertiesTabs.swift")
    check("the Output tab's frame range is the Timeline's (FrameRange's rule, Frame Start and End)",
          tabsSource.contains("FrameRange.settingStart(value, end: scene.frameEnd)")
          && tabsSource.contains("undo: \"Frame Start\"") && tabsSource.contains("scene.frameStart = range.start"))
    check("every number field writes when the drag ends (SettingNumber's commit), none per sample",
          !tabsSource.contains("BNumberField(label, value: Binding(get: { draft ?? Float(value) }, set: { draft = $0; write")
          && tabsSource.contains("draft = nil\n            if Double(final) != value { write(Double(final)) }"))
}

print()
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASS")
