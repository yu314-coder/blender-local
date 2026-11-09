import SwiftUI
import UIKit
import simd

/// The Properties editor's Render, Output and World tabs (Blender's
/// `properties_render.py`, `properties_output.py`, `properties_world.py` and
/// Cycles' `ui.py`, 5.2.1): the scene's own settings, read from Blender
/// (`_blenderkit_render.settings`) and written one property at a time, each
/// edit one undo step named after the field's text, a number field's when the
/// finger lifts. What a render uses is what these show: the Render panel's
/// quick choices write the same properties, and a render changes none of them.
struct SceneRenderTabs: View {
    var tab: PropertiesTab
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    @State private var settings: RenderSettings?
    /// Custom picked from the Frame Rate menu: Blender then shows FPS and Base
    /// whatever the rate (`show_framerate` when the preset label is Custom).
    @State private var customRate = false

    private struct ReadKey: Equatable {
        var revision: Int
        var running: Bool
        var tab: PropertiesTab
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let settings {
                    switch tab {
                    case .render: renderTab(settings)
                    case .output: outputTab(settings)
                    case .world:  worldTab(settings)
                    default: EmptyView()
                    }
                } else {
                    Text(session.usesRealBlender ? "Reading the scene's settings from Blender…"
                                                 : "These settings are Blender's: they need the real Blender module.")
                        .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                        .padding(12)
                }
            }
            .padding(.bottom, 12)
        }
        .background(KeyedRefresh(key: { ReadKey(revision: session.backendRevision, running: session.isRunning, tab: tab) },
                                 refresh: read))
        #if DEBUG
        .task(id: bridge == nil) { await debugOps() }
        #endif
    }

    #if DEBUG
    /// `-render-tab-ops start=5,end=40,step=2,rate=25,format=FFMPEG,engine=CYCLES,
    /// strength=2.5,color=0.2;0.4;0.8,newworld,undo`: the tabs' own writes,
    /// in order, once a `-eval64` script has finished, each printed with the
    /// range the Timeline draws and Blender's undo history after it
    /// (`[bk-tab]`).
    private func debugOps() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-render-tab-ops"), i + 1 < args.count, bridge != nil else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        read()
        for op in args[i + 1].split(separator: ",").map(String.init) {
            let parts = op.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "start": setFrameStart(Int(value) ?? 1)
            case "end": setFrameEnd(Int(value) ?? 250)
            case "step": write(RenderSettingsBpy.set("frame_step", int: Int(value) ?? 1), undo: "Step")
            case "rate":
                if let preset = FrameRatePreset.all.first(where: { $0.name == value }) {
                    write(RenderSettingsBpy.frameRate(preset), undo: "Frame Rate")
                }
            case "format": write(RenderSettingsBpy.fileFormat(value), undo: "File Format")
            case "engine": write(RenderSettingsBpy.engine(value), undo: "Render Engine")
            case "strength": write(RenderSettingsBpy.worldStrength(Double(value) ?? 1), undo: "Strength")
            case "color":
                let c = value.split(separator: ";").compactMap { Double($0) }
                if c.count == 3 { write(RenderSettingsBpy.worldColor(SIMD3(c[0], c[1], c[2])), undo: "Color") }
            case "newworld": write(RenderSettingsBpy.newWorld, undo: RenderSettingsBpy.newWorldUndo)
            case "undo": session.performUndo(); read()
            default: break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            read()
            let h = session.backendHistory
            let s = settings
            print("[bk-tab] \(op): Timeline \(scene.frameStart)–\(scene.frameEnd) at \(TimelineView.rate(scene.animation.fps)) fps"
                  + " · Blender \(s.map { "\($0.frameStart)–\($0.frameEnd) step \($0.frameStep), \(FrameRatePreset.label(fps: $0.fps, base: $0.fpsBase)), \($0.mediaType)/\($0.fileFormat) \($0.ffmpegFormat)/\($0.ffmpegCodec), \($0.engine), world \($0.world.map { "\($0.name) strength \($0.strength)" } ?? "none")" } ?? "?")"
                  + " · undo '\(h.undoLabel)' (\(h.steps) steps)")
            fflush(stdout)
        }
        print("[bk-tab] all done")
        fflush(stdout)
    }
    #endif

    /// Blender's values, read again after every change (the revision moves).
    private func read() {
        guard let bridge, session.usesRealBlender, !session.isRunning,
              let text = bridge.capture(RenderSettingsBpy.report),
              let read = RenderSettings.parse(text) else { return }
        if read != settings { settings = read }
    }

    /// One property, one step.
    private func write(_ python: String, undo: String) {
        guard let bridge, !session.isRunning else { return }
        bridge.run(python, undo: undo)
        read()
    }

    // MARK: Render Properties

    @ViewBuilder private func renderTab(_ s: RenderSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingMenu(label: "Render Engine", choices: s.engines, selected: s.engine) {
                write(RenderSettingsBpy.engine($0), undo: "Render Engine")
            }
            if s.engine == "CYCLES", let c = s.cycles {
                SettingMenu(label: "Device", choices: RenderSettings.cyclesDevices, selected: c.device) {
                    write(RenderSettingsBpy.set("cycles.device", choice: $0), undo: "Device")
                }
                Text(c.device == "GPU" ? "GPU Compute is this device's Metal GPU."
                                       : "The CPU: Metal's GPU Compute is many times quicker.")
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)

        switch s.engine {
        case "CYCLES": if let c = s.cycles { cyclesPanels(s, c) }
        case "BLENDER_EEVEE": if let e = s.eevee { eeveePanels(s, e) }
        case "BLENDER_WORKBENCH": workbenchPanels(s)
        default: EmptyView()
        }
        colorManagement(s.color)
    }

    @ViewBuilder private func cyclesPanels(_ s: RenderSettings, _ c: RenderSettings.Cycles) -> some View {
        BPanel("Sampling") {
            SubHeading("Render")
            SettingToggleValue(label: "Noise Threshold", on: c.useAdaptiveSampling,
                               set: { write(RenderSettingsBpy.set("cycles.use_adaptive_sampling", bool: $0), undo: "Noise Threshold") },
                               value: c.adaptiveThreshold, step: 0.0005, unit: .fine) {
                write(RenderSettingsBpy.set("cycles.adaptive_threshold", float: min(max($0, 0), 1)), undo: "Noise Threshold")
            }
            SettingNumber(label: c.useAdaptiveSampling ? "Max Samples" : "Samples", value: Double(c.samples),
                          step: 1, unit: .count) {
                write(RenderSettingsBpy.set("cycles.samples", int: Int(min(max($0, 1), 16_777_216))),
                      undo: c.useAdaptiveSampling ? "Max Samples" : "Samples")
            }
            SettingNumber(label: "Time Limit", value: c.timeLimit, step: 0.1, unit: .fine) {
                write(RenderSettingsBpy.set("cycles.time_limit", float: max($0, 0)), undo: "Time Limit")
            }
            SubHeading("Denoise")
            SettingToggle(label: "Denoise", on: c.useDenoising) {
                write(RenderSettingsBpy.set("cycles.use_denoising", bool: $0), undo: "Denoise")
            }
            if c.useDenoising {
                SettingMenu(label: "Denoiser", choices: c.denoisers, selected: c.denoiser) {
                    write(RenderSettingsBpy.set("cycles.denoiser", choice: $0), undo: "Denoiser")
                }
            }
        }
        BPanel("Light Paths") {
            SubHeading("Max Bounces")
            SettingNumber(label: "Total", value: Double(c.maxBounces), step: 0.2, unit: .count) {
                write(RenderSettingsBpy.set("cycles.max_bounces", int: Int(min(max($0, 0), 1024))), undo: "Total")
            }
        }
        BPanel("Film") {
            SettingToggle(label: "Transparent", on: s.filmTransparent) {
                write(RenderSettingsBpy.set("render.film_transparent", bool: $0), undo: "Transparent")
            }
        }
    }

    @ViewBuilder private func eeveePanels(_ s: RenderSettings, _ e: RenderSettings.Eevee) -> some View {
        BPanel("Sampling") {
            SubHeading("Viewport")
            SettingNumber(label: "Samples", value: Double(e.taaSamples), step: 0.5, unit: .count) {
                write(RenderSettingsBpy.set("eevee.taa_samples", int: Int(max($0, 0))), undo: "Samples")
            }
            SubHeading("Render")
            SettingNumber(label: "Samples", value: Double(e.taaRenderSamples), step: 0.5, unit: .count) {
                write(RenderSettingsBpy.set("eevee.taa_render_samples", int: Int(max($0, 1))), undo: "Samples")
            }
            SubHeading("Shadows")
            SettingToggle(label: "Shadows", on: e.useShadows) {
                write(RenderSettingsBpy.set("eevee.use_shadows", bool: $0), undo: "Shadows")
            }
            if e.useShadows {
                SettingNumber(label: "Rays", value: Double(e.shadowRayCount), step: 0.1, unit: .count) {
                    write(RenderSettingsBpy.set("eevee.shadow_ray_count", int: Int(min(max($0, 1), 4))), undo: "Rays")
                }
                SettingNumber(label: "Steps", value: Double(e.shadowStepCount), step: 0.1, unit: .count) {
                    write(RenderSettingsBpy.set("eevee.shadow_step_count", int: Int(min(max($0, 1), 16))), undo: "Steps")
                }
            }
        }
        BPanel("Raytracing") {
            SettingToggle(label: "Raytracing", on: e.useRaytracing) {
                write(RenderSettingsBpy.set("eevee.use_raytracing", bool: $0), undo: "Raytracing")
            }
        }
        BPanel("Motion Blur") {
            SettingToggle(label: "Motion Blur", on: s.useMotionBlur) {
                write(RenderSettingsBpy.set("render.use_motion_blur", bool: $0), undo: "Motion Blur")
            }
        }
        BPanel("Film") {
            SettingToggle(label: "Transparent", on: s.filmTransparent) {
                write(RenderSettingsBpy.set("render.film_transparent", bool: $0), undo: "Transparent")
            }
        }
    }

    @ViewBuilder private func workbenchPanels(_ s: RenderSettings) -> some View {
        let w = s.workbench
        BPanel("Sampling") {
            SettingMenu(label: "Render", choices: RenderSettings.antiAliasing, selected: w.renderAa) {
                write(RenderSettingsBpy.set("display.render_aa", choice: $0), undo: "Render")
            }
        }
        BPanel("Lighting") {
            SettingSegments(choices: RenderSettings.workbenchLights, selected: w.light) {
                write(RenderSettingsBpy.set("display.shading.light", choice: $0), undo: "Lighting")
            }
        }
        BPanel("Object Color") {
            SettingSegments(choices: RenderSettings.workbenchColors, selected: w.colorType) {
                write(RenderSettingsBpy.set("display.shading.color_type", choice: $0), undo: "Color")
            }
            if w.colorType == "SINGLE", w.singleColor.count == 3 {
                LinearColorRow(label: "Color", linear: SIMD3(w.singleColor[0], w.singleColor[1], w.singleColor[2])) { c in
                    write(RenderSettingsBpy.set("display.shading.single_color",
                                                "(\(RenderSettingsBpy.number(c.x)), \(RenderSettingsBpy.number(c.y)), \(RenderSettingsBpy.number(c.z)))"),
                          undo: "Color")
                }
            }
        }
        BPanel("Film") {
            SettingToggle(label: "Transparent", on: s.filmTransparent) {
                write(RenderSettingsBpy.set("render.film_transparent", bool: $0), undo: "Transparent")
            }
        }
    }

    @ViewBuilder private func colorManagement(_ c: RenderSettings.ColorManagement) -> some View {
        BPanel("Color Management") {
            SettingMenu(label: "Display", choices: c.displayDevices, selected: c.displayDevice) {
                write(RenderSettingsBpy.set("display_settings.display_device", choice: $0), undo: "Display")
            }
            SettingMenu(label: "View", choices: c.viewTransforms, selected: c.viewTransform) {
                write(RenderSettingsBpy.set("view_settings.view_transform", choice: $0), undo: "View")
            }
            SettingMenu(label: "Look", choices: c.looks, selected: c.look) {
                write(RenderSettingsBpy.set("view_settings.look", choice: $0), undo: "Look")
            }
            SettingNumber(label: "Exposure", value: c.exposure, step: 0.01, unit: .none) {
                write(RenderSettingsBpy.set("view_settings.exposure", float: min(max($0, -32), 32)), undo: "Exposure")
            }
            SettingNumber(label: "Gamma", value: c.gamma, step: 0.01, unit: .none) {
                write(RenderSettingsBpy.set("view_settings.gamma", float: min(max($0, 0), 5)), undo: "Gamma")
            }
        }
    }

    // MARK: Output Properties

    @ViewBuilder private func outputTab(_ s: RenderSettings) -> some View {
        BPanel("Format") {
            SettingNumber(label: "Resolution X", value: Double(s.resolutionX), step: 1, unit: .pixels) {
                write(RenderSettingsBpy.set("render.resolution_x", int: Int(min(max($0, 4), 65536))), undo: "Resolution X")
            }
            SettingNumber(label: "Y", value: Double(s.resolutionY), step: 1, unit: .pixels) {
                write(RenderSettingsBpy.set("render.resolution_y", int: Int(min(max($0, 4), 65536))), undo: "Y")
            }
            SettingNumber(label: "%", value: Double(s.resolutionPercentage) / 100, step: 0.005, unit: .percent) {
                write(RenderSettingsBpy.set("render.resolution_percentage", int: Int(min(max(($0 * 100).rounded(), 1), 32767))),
                      undo: "%")
            }
            frameRate(s)
        }
        BPanel("Frame Range") {
            // The scene's range as the Timeline shows it: the mirror's,
            // set here as the Timeline's Start and End set it.
            SettingNumber(label: "Frame Start", value: Double(scene.frameStart), step: 0.2, unit: .count) {
                setFrameStart(Int($0))
            }
            SettingNumber(label: "End", value: Double(scene.frameEnd), step: 0.2, unit: .count) {
                setFrameEnd(Int($0))
            }
            SettingNumber(label: "Step", value: Double(s.frameStep), step: 0.1, unit: .count) {
                write(RenderSettingsBpy.set("frame_step", int: Int(min(max($0, 0), 1_048_574))), undo: "Step")
            }
        }
        BPanel("Output") {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(BTheme.textDim)
                Text("Files ▸ Blender Local ▸ Renders")
                    .font(BTheme.Font.mono(12)).foregroundStyle(BTheme.textDim)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .frame(height: BTheme.Metric.touchField)
            .padding(.horizontal, 8)
            .background(BTheme.field.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Output path: Renders, kept by the app")
            SettingSegments(choices: RenderSettings.mediaTypes, selected: s.mediaType == "VIDEO" ? "VIDEO" : "IMAGE") {
                write(RenderSettingsBpy.fileFormat($0 == "VIDEO" ? RenderSettings.videoFormat.identifier : "PNG"),
                      undo: "Media Type")
            }
            if s.mediaType == "VIDEO" {
                SettingMenu(label: "File Format", choices: [RenderSettings.videoFormat], selected: s.fileFormat) { _ in }
            } else {
                SettingMenu(label: "File Format", choices: RenderSettings.imageFormats, selected: s.fileFormat) {
                    write(RenderSettingsBpy.fileFormat($0), undo: "File Format")
                }
            }
            if s.outputUntouched && s.ffmpegAvailable {
                Text("Render Animation makes an MPEG-4 video until a format is chosen here.")
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingSegments(label: "Color", choices: s.colorModes, selected: s.colorMode) {
                write(RenderSettingsBpy.set("render.image_settings.color_mode", choice: $0), undo: "Color")
            }
            if s.colorDepths.count > 1 {
                SettingSegments(label: "Color Depth", choices: s.colorDepths, selected: s.colorDepth) {
                    write(RenderSettingsBpy.set("render.image_settings.color_depth", choice: $0), undo: "Color Depth")
                }
            }
            if s.fileFormat == "PNG" {
                SettingNumber(label: "Compression", value: Double(s.compression) / 100, step: 0.005, unit: .percent) {
                    write(RenderSettingsBpy.set("render.image_settings.compression", int: Int(min(max(($0 * 100).rounded(), 0), 100))),
                          undo: "Compression")
                }
            } else if s.fileFormat == "JPEG" {
                SettingNumber(label: "Quality", value: Double(s.quality) / 100, step: 0.005, unit: .percent) {
                    write(RenderSettingsBpy.set("render.image_settings.quality", int: Int(min(max(($0 * 100).rounded(), 0), 100))),
                          undo: "Quality")
                }
            } else if s.fileFormat == "OPEN_EXR" {
                SettingMenu(label: "Codec", choices: RenderSettings.exrCodecs, selected: s.exrCodec) {
                    write(RenderSettingsBpy.set("render.image_settings.exr_codec", choice: $0), undo: "Codec")
                }
            }
        }
        if s.mediaType == "VIDEO" {
            BPanel("Encoding") {
                SettingMenu(label: "Container", choices: RenderSettings.containers, selected: s.ffmpegFormat) {
                    write(RenderSettingsBpy.set("render.ffmpeg.format", choice: $0), undo: "Container")
                }
                SubHeading("Video")
                SettingMenu(label: "Video Codec", choices: RenderSettings.videoCodecs, selected: s.ffmpegCodec) {
                    write(RenderSettingsBpy.set("render.ffmpeg.codec", choice: $0), undo: "Video Codec")
                }
                SettingMenu(label: "Output Quality", choices: RenderSettings.outputQualities, selected: s.ffmpegCrf) {
                    write(RenderSettingsBpy.set("render.ffmpeg.constant_rate_factor", choice: $0), undo: "Output Quality")
                }
                SettingMenu(label: "Encoding Speed", choices: RenderSettings.encodingSpeeds, selected: s.ffmpegPreset) {
                    write(RenderSettingsBpy.set("render.ffmpeg.ffmpeg_preset", choice: $0), undo: "Encoding Speed")
                }
            }
        }
    }

    /// Blender's Frame Rate menu, labelled as its Format panel labels it, and
    /// FPS and Base under it for a rate none of the presets is (or Custom).
    @ViewBuilder private func frameRate(_ s: RenderSettings) -> some View {
        HStack {
            Text("Frame Rate").font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Menu {
                ForEach(FrameRatePreset.all) { preset in
                    Button {
                        customRate = false
                        write(RenderSettingsBpy.frameRate(preset), undo: "Frame Rate")
                    } label: {
                        Label(preset.name, systemImage: FrameRatePreset.preset(fps: s.fps, base: s.fpsBase) == preset
                              && !customRate ? "checkmark" : "")
                    }
                }
                Button("Custom") { customRate = true }
            } label: {
                SettingValueLabel(FrameRatePreset.label(fps: s.fps, base: s.fpsBase))
            }
            .menuStyle(BlenderMenuStyle())
        }
        .frame(minHeight: BTheme.Metric.touchField)
        if customRate || FrameRatePreset.isCustom(fps: s.fps, base: s.fpsBase) {
            SettingNumber(label: "FPS", value: Double(s.fps), step: 0.2, unit: .count) {
                write(RenderSettingsBpy.set("render.fps", int: Int(min(max($0, 1), 32767))), undo: "FPS")
            }
            SettingNumber(label: "Base", value: s.fpsBase, step: 0.001, unit: .fine) {
                write(RenderSettingsBpy.set("render.fps_base", float: min(max($0, 1e-5), 1e6)), undo: "Base")
            }
        }
    }

    /// The Timeline's own rule (`FrameRange`), so both show the same range at
    /// once; the mirror confirms it. The step is the field's text.
    private func setFrameStart(_ value: Int) {
        guard let bridge, !session.isRunning else { return }
        let range = FrameRange.settingStart(value, end: scene.frameEnd)
        bridge.run(BpyAnimation.setFrameStart(range.start), undo: "Frame Start")
        if scene.frameStart != range.start { scene.frameStart = range.start }
        if scene.frameEnd != range.end { scene.frameEnd = range.end }
        read()
    }

    private func setFrameEnd(_ value: Int) {
        guard let bridge, !session.isRunning else { return }
        let range = FrameRange.settingEnd(value, start: scene.frameStart)
        bridge.run(BpyAnimation.setFrameEnd(range.end), undo: "End")
        if scene.frameStart != range.start { scene.frameStart = range.start }
        if scene.frameEnd != range.end { scene.frameEnd = range.end }
        read()
    }

    // MARK: World Properties

    @ViewBuilder private func worldTab(_ s: RenderSettings) -> some View {
        if let w = s.world {
            HStack(spacing: 6) {
                Image(systemName: "globe.americas").font(.system(size: 12)).foregroundStyle(BTheme.textDim)
                Text(w.name).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            BPanel("Surface") {
                // The node on the World Output's Surface, named; the app
                // offers no other node here, so it is not drawn as a menu.
                labelled("Surface", w.nodeLabel ?? (w.node == nil ? "None" : w.node!))
                if w.background || w.node == nil {
                    if let linked = w.colorLinked {
                        labelled("Color", "from \(linked)")
                    } else if w.color.count == 3 {
                        LinearColorRow(label: "Color", linear: SIMD3(w.color[0], w.color[1], w.color[2])) {
                            write(RenderSettingsBpy.worldColor($0), undo: "Color")
                        }
                    }
                    if let linked = w.strengthLinked {
                        labelled("Strength", "from \(linked)")
                    } else {
                        SettingNumber(label: "Strength", value: w.strength, step: 0.01, unit: .none) {
                            write(RenderSettingsBpy.worldStrength($0), undo: "Strength")
                        }
                    }
                    if w.node == nil {
                        Text("Nothing is on the World Output's Surface: a Color or Strength makes a Background there.")
                            .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("The Surface is a \(w.nodeLabel ?? "node") rather than a Background: edit it in the Shading workspace's node editor.")
                        .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("What Cycles and EEVEE light the scene with and show behind it.")
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("This scene has no World.")
                    .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                // Blender's World field's New (`world.new`, "New World").
                BButton("New", icon: "plus") { write(RenderSettingsBpy.newWorld, undo: RenderSettingsBpy.newWorldUndo) }
                    .accessibilityLabel("New World")
            }
            .padding(14)
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text)
        }
        .frame(minHeight: BTheme.Metric.touchField)
    }
}

// MARK: - The rows

/// A sub-panel's name (Sampling ▸ Render, Light Paths ▸ Max Bounces), as a
/// line over its rows.
struct SubHeading: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(BTheme.Font.ui(12, weight: .semibold)).foregroundStyle(BTheme.textDim)
            .padding(.top, 4)
    }
}

/// A menu's current value, drawn as Blender's dropdown.
struct SettingValueLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BTheme.textDim)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 44, minHeight: BTheme.Metric.touchField)
        .background(BTheme.widget)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        .contentShape(Rectangle())
    }
}

/// An enum property as Blender's dropdown.
struct SettingMenu: View {
    var label: String
    var choices: [RenderSettings.Choice]
    var selected: String
    var set: (String) -> Void

    var body: some View {
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Menu {
                ForEach(choices) { choice in
                    Button {
                        if choice.identifier != selected { set(choice.identifier) }
                    } label: {
                        Label(choice.name, systemImage: choice.identifier == selected ? "checkmark" : "")
                    }
                }
            } label: {
                SettingValueLabel(choices.first { $0.identifier == selected }?.name ?? selected)
            }
            .menuStyle(BlenderMenuStyle())
            .accessibilityLabel(label)
        }
        .frame(minHeight: BTheme.Metric.touchField)
    }
}

/// An enum drawn expanded, as Blender's row of buttons (Color: BW RGB RGBA).
struct SettingSegments: View {
    var label: String? = nil
    var choices: [RenderSettings.Choice]
    var selected: String
    var set: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            }
            HStack(spacing: 2) {
                ForEach(choices) { choice in
                    let on = choice.identifier == selected
                    Button {
                        if !on { set(choice.identifier) }
                    } label: {
                        Text(choice.name)
                            .font(BTheme.Font.ui(12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : BTheme.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: BTheme.Metric.touchField)
                            .background(on ? BTheme.select : BTheme.widget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
    }
}

/// A checkbox property.
struct SettingToggle: View {
    var label: String
    var on: Bool
    var set: (Bool) -> Void

    var body: some View {
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Toggle(label, isOn: Binding(get: { on }, set: { if $0 != on { set($0) } }))
                .labelsHidden()
        }
        .frame(minHeight: BTheme.Metric.touchField)
    }
}

/// A number property that lives in Blender: dragged from a draft, written
/// once when the finger lifts (or a typed number is entered).
struct SettingNumber: View {
    var label: String
    var value: Double
    var step: Float
    var unit: BNumberField.Unit
    var write: (Double) -> Void

    @State private var draft: Float?

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? Float(value) }, set: { draft = $0 }),
                     step: step, unit: unit) { final in
            draft = nil
            if Double(final) != value { write(Double(final)) }
        }
    }
}

/// Cycles' Noise Threshold: a checkbox and its value on one row.
struct SettingToggleValue: View {
    var label: String
    var on: Bool
    var set: (Bool) -> Void
    var value: Double
    var step: Float
    var unit: BNumberField.Unit
    var write: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(label, isOn: Binding(get: { on }, set: { if $0 != on { set($0) } }))
                .labelsHidden()
            SettingNumber(label: label, value: value, step: step, unit: unit, write: write)
                .opacity(on ? 1 : 0.45)
                .disabled(!on)
        }
    }
}

/// A colour Blender keeps scene-linear (a node socket, Workbench's single
/// colour), shown and picked in sRGB as Blender's colour picker shows it.
///
/// The system picker sends every point of a drag across its wheel; each one
/// written would be a Python call and an undo step. The colour shows at once
/// from a draft and is written when the picking pauses — one step, as a
/// number field writes when the finger lifts.
struct LinearColorRow: View {
    var label: String
    var linear: SIMD3<Double>
    var set: (SIMD3<Double>) -> Void

    @State private var draft: SIMD3<Double>?
    @State private var pending: DispatchWorkItem?

    var body: some View {
        let shown = draft ?? linear
        HStack {
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            ColorPicker(label, selection: Binding(
                get: {
                    Color(.sRGB, red: RenderSettingsBpy.sRGB(fromLinear: shown.x),
                          green: RenderSettingsBpy.sRGB(fromLinear: shown.y),
                          blue: RenderSettingsBpy.sRGB(fromLinear: shown.z))
                },
                set: { picked in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    guard UIColor(picked).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                    let next = SIMD3(RenderSettingsBpy.linear(fromSRGB: min(max(Double(r), 0), 1)),
                                     RenderSettingsBpy.linear(fromSRGB: min(max(Double(g), 0), 1)),
                                     RenderSettingsBpy.linear(fromSRGB: min(max(Double(b), 0), 1)))
                    guard simd_distance(next, shown) > 1e-4 else { return }
                    draft = next
                    pending?.cancel()
                    let work = DispatchWorkItem {
                        pending = nil
                        let value = draft ?? next
                        draft = nil
                        if simd_distance(value, linear) > 1e-4 { set(value) }
                    }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44, height: BTheme.Metric.touchField)
        }
        .frame(minHeight: BTheme.Metric.touchField)
    }
}
