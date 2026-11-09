import SwiftUI
import Metal
import AVKit

/// What opens the Render panel: Blender's Render menu (`TOPBAR_MT_render`)
/// and its keys — F12 Render Image, Ctrl+F12 Render Animation, F11 View
/// Render, Ctrl+F11 View Animation. Posted by the top bar's Render menu and
/// the Mac menu bar's; the 3D View's keys call the workspace directly.
public enum RenderPanelAction: String, Sendable {
    case renderImage, renderAnimation, viewRender, viewAnimation

    public static let notification = Notification.Name("BlenderLocal.renderPanelAction")

    /// Blender's row names.
    public var title: String {
        switch self {
        case .renderImage: return "Render Image"
        case .renderAnimation: return "Render Animation"
        case .viewRender: return "View Render"
        case .viewAnimation: return "View Animation"
        }
    }

    public func post() {
        NotificationCenter.default.post(name: Self.notification, object: nil, userInfo: ["action": rawValue])
    }

    public init?(_ note: Notification) {
        guard let raw = note.userInfo?["action"] as? String, let action = RenderPanelAction(rawValue: raw) else { return nil }
        self = action
    }
}

/// Where renders go: Documents/Renders, which the Files app shows as Blender
/// Local ▸ Renders. Debug builds take `-renders-in-tmp`, which keeps a test
/// run's renders out of the user's folder.
enum RenderFolder {
    static var url: URL {
        var base = SceneDocument.documentsURL
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-renders-in-tmp") {
            base = FileManager.default.temporaryDirectory
        }
        #endif
        let folder = base.appendingPathComponent("Renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The last animation, for View Animation: kept across launches by its
    /// name in the folder, and only while it is still there.
    static var lastAnimation: URL? {
        get {
            guard let name = UserDefaults.standard.string(forKey: "bl_last_animation") else { return nil }
            let url = self.url.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set { UserDefaults.standard.set(newValue?.lastPathComponent, forKey: "bl_last_animation") }
    }
}

/// Blender's Rendering workspace: the render result in an image editor, with
/// the controls that produce it.
///
/// Two things a render needs and a scene may not have — a camera, and a light —
/// are answered here rather than left to fail: the panel says which is missing
/// and offers the button that adds it, and renders can be taken through the 3D
/// View instead of a camera at all.
///
/// November 9: the engine, the samples and the size are the scene's own
/// (Render and Output Properties), which the chips here write; a render puts
/// back whatever it set for itself and records no undo step, as Blender's F12
/// does. Render Animation renders the scene's frame range into a video (or
/// numbered frames), with the frame and the samples as it goes, a Cancel that
/// stops after the frame in hand, and the result played here.
struct RenderingWorkspace: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera
    /// What opened it. Render Image and Render Animation start at once, as
    /// Blender's F12 and Ctrl+F12 do — except for Cycles' first render on this
    /// device, which compiles its kernels for minutes and is not begun without
    /// the panel's warning first.
    var opening: RenderPanelAction? = nil

    /// The scene's render settings, read from Blender.
    @State private var settings: RenderSettings?
    /// The simulator's stand-in renders the 3D View through the app's own
    /// renderer; these are its engine and size there.
    @State private var offlineSize = (width: 1920, height: 1080)
    /// Render the 3D View rather than the scene's camera. The shim has no
    /// Blender to render through, and its stand-in draws the view, so it is
    /// the only thing it can honestly offer.
    @State private var fromView = false
    @State private var rendering = false
    /// The render under way is an animation.
    @State private var renderingAnimation = false
    @State private var startedAt: Date?
    @State private var lastSeconds: Double?
    @State private var problem: String?
    /// Whether the problem is one a camera would fix, so the buttons that
    /// offer one are not chosen by reading the message back.
    @State private var problemWantsCamera = false
    @State private var savedName: String?
    @State private var renderPath: URL?
    /// What the last render ran on, as Blender reported it.
    @State private var device: String?
    /// Blender's own progress line while it renders, and the samples it has
    /// read out of it.
    @State private var progress: String?
    @State private var progressFraction: Double?
    /// Render Animation's frame in hand.
    @State private var animationFrame: RenderAnimationFrame?
    @State private var cancelling = false
    /// The render on disk, for the share sheet.
    @State private var savedURL: URL?
    /// Which result the panel shows: the still (View Render) or the animation
    /// (View Animation).
    @State private var showsAnimation = false
    /// The animation shown: a video, or a folder of frames.
    @State private var animationURL: URL?
    @State private var player: AVPlayer?
    /// Cycles compiles its Metal kernels the first time it renders on a
    /// device — minutes, once, cached afterwards. Remembered so the warning
    /// is shown before that render and not after.
    @AppStorage(CyclesKernels.builtKey) private var kernelsBuilt = false

    private var usesCamera: Bool { !fromView && session.usesRealBlender }

    /// The scene's engine; the stand-in's renderer is the viewport's own.
    private var engine: RenderRequest.Engine {
        session.usesRealBlender ? (settings?.renderEngine ?? .eevee) : .workbench
    }

    private var size: (width: Int, height: Int) {
        settings?.renderSize ?? offlineSize
    }

    /// Cycles on the GPU, whose first render builds its kernels.
    private var cyclesOnGPU: Bool { engine == .cycles && settings?.cycles?.device != "CPU" }

    private struct ReadKey: Equatable {
        var revision: Int
        var running: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsAnimation, let animationURL {
                animationViewer(animationURL)
            } else {
                ImageEditor(title: "Render Result",
                            image: scene.renderResult,
                            version: scene.renderVersion,
                            emptyMessage: emptyMessage,
                            headerContent: AnyView(header),
                            emptyAction: nil)
            }
            // Render Image and Render Animation in a bar of their own: in the
            // header beside the chips they pushed the sheet's contents past
            // its edges on a Mac-sized window (measured, the first run).
            HStack(spacing: 8) {
                renderButtons
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(BTheme.header)
            notes
        }
        .onChange(of: session.isRunning) { _, running in
            if !running && rendering && renderPath != nil { finishBlenderRender() }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            guard rendering else { return }
            if renderingAnimation,
               let text = try? String(contentsOf: Self.framesReport, encoding: .utf8) {
                animationFrame = RenderAnimationFrame(text)
            }
            if let line = try? String(contentsOf: Self.progressReport, encoding: .utf8), !line.isEmpty {
                let read = RenderingWorkspaceProgress.read(line)
                progress = read.text
                progressFraction = read.fraction
            }
            #if DEBUG
            debugProgress()
            #endif
        }
        .background(KeyedRefresh(key: { ReadKey(revision: session.backendRevision, running: session.isRunning) },
                                 refresh: readSettings))
        .onAppear {
            if !session.usesRealBlender { fromView = true }
            readSettings()
            open(opening)
        }
        .onReceive(NotificationCenter.default.publisher(for: RenderPanelAction.notification)) { note in
            // The top bar's Render menu while the panel is open.
            open(RenderPanelAction(note))
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func readSettings() {
        guard session.usesRealBlender, !session.isRunning, let bridge,
              let text = bridge.capture(RenderSettingsBpy.report),
              let read = RenderSettings.parse(text) else { return }
        if read != settings { settings = read }
    }

    /// What the panel was opened for, or asked for while open.
    private func open(_ action: RenderPanelAction?) {
        guard let action, !rendering else { return }
        switch action {
        case .renderImage:
            showsAnimation = false
            if !(session.usesRealBlender && cyclesOnGPU && !kernelsBuilt) { render(animation: false) }
        case .renderAnimation:
            if !(session.usesRealBlender && cyclesOnGPU && !kernelsBuilt) { render(animation: true) }
            else { showsAnimation = false }
        case .viewRender:
            showsAnimation = false
        case .viewAnimation:
            if let last = RenderFolder.lastAnimation {
                showAnimation(last)
            } else {
                showsAnimation = false
                problem = "No animation has been rendered yet. Render ▸ Render Animation (Ctrl F12) makes one."
            }
        }
    }

    private var emptyMessage: String {
        let size = "\(self.size.width) × \(self.size.height)"
        if rendering && renderingAnimation, let settings {
            return "Render Animation: frames \(settings.frameStart)–\(settings.frameEnd) through "
                + "\(scene.sceneCamera?.name ?? "the scene's camera") at \(size), as \(settings.animationOutput.summary).\n"
                + "It plays here when it is done."
        }
        if usesCamera {
            guard let name = scene.sceneCamera?.name else {
                return "No render yet.\nThis renders through the scene's camera — there isn't one yet."
            }
            return "No render yet.\nThis renders through \(name), at \(size)."
        }
        return "No render yet.\nThis renders the 3D Viewport's own viewpoint, at \(size)."
    }

    /// Render Image and Render Animation; while one runs, the bar under the
    /// picture has its progress and Cancel.
    private var renderButtons: some View {
        HStack(spacing: 6) {
            BButton(rendering && !renderingAnimation ? "Rendering…" : "Render Image", icon: "camera.aperture") {
                render(animation: false)
            }
            .disabled(rendering || session.isRunning)
            if session.usesRealBlender {
                BButton(rendering && renderingAnimation ? "Rendering…" : "Render Animation", icon: "film") {
                    render(animation: true)
                }
                .disabled(rendering || session.isRunning)
            }
        }
    }

    /// The chips, or the chips scrolling sideways when the editor is too
    /// narrow for them. As a fixed row alone, with Render Animation's title
    /// beside it, the row came out wider than the sheet, and the sheet then
    /// centred everything under it and cut both sides off — the title read
    /// "nimation" and the saved-as line under the video "orkbench on the
    /// GPU" (build 59's first screenshot, a Mac-sized window).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow
            ScrollView(.horizontal, showsIndicators: false) { headerRow }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            sourceMenu
            if session.usesRealBlender, let settings {
                Menu {
                    // Render Properties ▸ Render Engine, the scene's.
                    Picker("Render Engine", selection: Binding(
                        get: { settings.engine },
                        set: { write(RenderSettingsBpy.engine($0), undo: "Render Engine") })) {
                        ForEach(settings.engines) { Text($0.name).tag($0.identifier) }
                    }
                    Text(engine.summary)
                } label: { chip(settings.engines.first { $0.identifier == settings.engine }?.name ?? engine.label) }
                if engine != .workbench {
                    Menu {
                        // Draft, Good and Best set the engine's Render samples
                        // (Render Properties ▸ Sampling).
                        ForEach(RenderRequest.Quality.allCases) { value in
                            Button {
                                if let python = RenderSettingsBpy.quality(value, engine: engine) {
                                    write(python, undo: "Samples")
                                }
                            } label: {
                                Label(samplesLabel(value), systemImage: qualityChosen == value ? "checkmark" : "")
                            }
                        }
                    } label: { chip(qualityChip) }
                }
            }
            Menu {
                ForEach([(1920, 1080), (1280, 720), (960, 540)], id: \.0) { w, h in
                    Button("\(w) × \(h)") { setSize(w, h) }
                }
            } label: { chip(sizeChip) }

            if let savedURL, !rendering {
                ShareLink(item: savedURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .frame(height: 22)
                        .padding(.horizontal, 6)
                        .background(BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                }
                .accessibilityLabel(showsAnimation ? "Share the animation" : "Share the render")
            }
            if rendering, let startedAt {
                // SwiftUI's, not the app's own animation TimelineView.
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Int(Date().timeIntervalSince(startedAt)))s")
                        .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
                }
            } else if let lastSeconds {
                Text(lastSeconds < 1 ? String(format: "%.0f ms", lastSeconds * 1000)
                                     : String(format: "%.1f s", lastSeconds))
                    .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
            }
        }
        .fixedSize()
    }

    /// The quality the scene's samples are, if one of the three.
    private var qualityChosen: RenderRequest.Quality? {
        settings?.samples.flatMap { RenderRequest.Quality.matching(samples: $0, engine: engine) }
    }

    private var qualityChip: String {
        if let qualityChosen { return qualityChosen.rawValue }
        return settings?.samples.map { "\($0) samples" } ?? "Samples"
    }

    private var sizeChip: String {
        guard let settings else { return "\(size.width)×\(size.height)" }
        let base = "\(settings.resolutionX)×\(settings.resolutionY)"
        return settings.resolutionPercentage == 100 ? base : base + " \(settings.resolutionPercentage)%"
    }

    /// The samples a quality takes, in the engine that will use them.
    private func samplesLabel(_ value: RenderRequest.Quality) -> String {
        guard let samples = value.samples(for: engine) else { return value.rawValue }
        return "\(value.rawValue) · \(samples) samples"
    }

    /// The size chip's rows: Output Properties ▸ Format's Resolution X and Y
    /// at 100%, one step.
    private func setSize(_ width: Int, _ height: Int) {
        guard session.usesRealBlender else { offlineSize = (width, height); return }
        write([RenderSettingsBpy.set("render.resolution_x", int: width),
               RenderSettingsBpy.set("render.resolution_y", int: height),
               RenderSettingsBpy.set("render.resolution_percentage", int: 100)].joined(separator: "\n"),
              undo: "Format Presets")
    }

    private func write(_ python: String, undo: String) {
        guard let bridge, !session.isRunning, !rendering else { return }
        bridge.run(python, undo: undo)
        readSettings()
    }

    /// Which camera the render goes through, and — when the scene has more
    /// than one — which camera is the scene's.
    private var sourceMenu: some View {
        Menu {
            Button {
                fromView = false
            } label: {
                // Blender's Scene panel's Camera, the render's.
                Label(scene.sceneCamera.map { "Camera: \($0.name)" } ?? "Camera",
                      systemImage: usesCamera ? "checkmark" : "video")
            }
            .disabled(!session.usesRealBlender)
            Button {
                fromView = true
            } label: {
                // The editor's name in Blender: the 3D Viewport.
                Label("3D Viewport", systemImage: !usesCamera ? "checkmark" : "cube")
            }
            if scene.cameras.count > 1 {
                Divider()
                Section("Camera") {
                    ForEach(scene.cameras, id: \.id) { object in
                        Button(object.name) {
                            // The Scene panel's Camera field, which names the
                            // step it records.
                            _ = bridge?.run(Bpy.setSceneCamera(object.name), undo: "Camera")
                            fromView = false
                        }
                    }
                }
            }
        } label: {
            chip(usesCamera ? (scene.sceneCamera?.name ?? "Camera") : "3D Viewport")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    // MARK: the animation

    /// The finished animation: the video in AVKit's player, or the frames as
    /// a flip-book — Blender's View Animation.
    @ViewBuilder private func animationViewer(_ url: URL) -> some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "film").font(.system(size: 11)).foregroundStyle(BTheme.textDim)
                // The file's name is on the saved-as line under the player.
                Text("Animation").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                header
            }
            if isFolder(url) {
                FrameFlipbook(folder: url, fps: settings.map { Double($0.fps) / max($0.fpsBase, 1e-5) } ?? 24)
            } else if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel("The rendered animation")
            } else {
                Spacer()
            }
        }
        .background(Color(hex: 0x1D1D1D))
    }

    private func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private func showAnimation(_ url: URL) {
        animationURL = url
        showsAnimation = true
        savedURL = url
        player?.pause()
        if isFolder(url) {
            player = nil
        } else {
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
    }

    private func cancelAnimation() {
        guard rendering, renderingAnimation, !cancelling else { return }
        cancelling = true
        FileManager.default.createFile(atPath: Self.cancelFlag.path, contents: Data())
    }

    /// What stands between this scene and a picture, under the image.
    @ViewBuilder private var notes: some View {
        if let problem {
            note(problem, colour: .orange) {
                if problemWantsCamera {
                    BButton("Add Camera", icon: "video") { addCamera() }
                    if !renderingAnimation {
                        BButton("Render the 3D Viewport", icon: "cube") { fromView = true; render(animation: false) }
                    }
                }
            }
        } else if rendering {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progressText)
                        .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    if let fraction = renderingAnimation ? animationFrame?.fraction(within: progressFraction) : progressFraction {
                        ProgressView(value: fraction).frame(maxWidth: 260)
                    }
                }
                Spacer(minLength: 0)
                if renderingAnimation {
                    BButton(cancelling ? "Stopping…" : "Cancel", icon: "xmark") { cancelAnimation() }
                        .disabled(cancelling)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BTheme.header)
        } else if usesCamera && scene.sceneCamera == nil {
            note("This scene has no camera.", colour: BTheme.textDim) {
                BButton("Add Camera", icon: "video") { addCamera() }
                BButton("Render the 3D Viewport", icon: "cube") { fromView = true }
            }
        } else if engine.usesSceneLighting && scene.lights.isEmpty {
            note("Nothing lights this scene, so \(engine.label) will render it black.",
                 colour: BTheme.textDim) {
                BButton("Add Light", icon: "lightbulb") {
                    _ = bridge?.add(.light(.point), at: SIMD3(4, 1, 6), view: camera)
                }
                BButton("Use \(RenderRequest.Engine.workbench.label)", icon: "circle.lefthalf.filled") {
                    write(RenderSettingsBpy.engine(RenderRequest.Engine.workbench.rawValue), undo: "Render Engine")
                }
            }
        } else if cyclesOnGPU && !kernelsBuilt {
            note(CyclesKernels.warning, colour: BTheme.textDim) {
                BButton("Use \(RenderRequest.Engine.eevee.label)", icon: "bolt") {
                    write(RenderSettingsBpy.engine(RenderRequest.Engine.eevee.rawValue), undo: "Render Engine")
                }
            }
        } else if let savedName {
            note("\(device.map { $0 + ". " } ?? "")\(savedName)", colour: BTheme.textDim) { EmptyView() }
        } else if session.usesRealBlender, let settings {
            // What Render Animation will do, before it is pressed.
            note("Render Animation: frames \(settings.frameStart)–\(settings.frameEnd)"
                 + (settings.frameStep > 1 ? " by \(settings.frameStep)" : "")
                 + " (\(settings.frameCount)) at \(FrameRatePreset.label(fps: settings.fps, base: settings.fpsBase))"
                 + " through the scene's camera, as \(settings.animationOutput.summary)"
                 + (fromView ? "." : ". Output Properties change it."),
                 colour: BTheme.textDim) { EmptyView() }
        }
    }

    private var progressText: String {
        if cancelling, let frame = animationFrame {
            return "Stopping after frame \(frame.index) of \(frame.total)…"
        }
        if renderingAnimation {
            let frame = animationFrame?.text ?? "Starting"
            return frame + (progress.map { " · " + $0 } ?? "")
        }
        return progress ?? "Rendering with \(engine.label)…"
    }

    private func note<Content: View>(_ text: String, colour: Color,
                                     @ViewBuilder actions: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(BTheme.Font.ui(11)).foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BTheme.header)
    }

    private func addCamera() {
        problemWantsCamera = false
        // Blender aims a camera added from the 3D View the way the view looks,
        // and makes the first one the scene's — so this is the whole fix.
        _ = bridge?.add(.camera, at: camera.eye, view: camera)
        problem = nil
    }

    // MARK: rendering

    private func render(animation: Bool) {
        guard !session.isRunning, !rendering else { return }
        problem = nil
        problemWantsCamera = false
        savedName = nil
        guard session.usesRealBlender else {
            offlineRender()
            return
        }
        readSettings()
        guard let settings else {
            problem = "The scene's render settings could not be read from Blender."
            return
        }
        // Render Animation goes through the scene's camera, as Blender's does.
        if animation && scene.sceneCamera == nil {
            problem = "This scene has no camera. Add ▸ Camera, then Render Animation."
            problemWantsCamera = true
            renderingAnimation = true
            return
        }
        let base = RenderFolder.url
        let url = animation ? base.appendingPathComponent(RenderRequest.animationName())
                            : base.appendingPathComponent(RenderRequest.fileName())
        for report in [Self.deviceReport, Self.progressReport, Self.framesReport, Self.cancelFlag, Self.resultReport] {
            try? FileManager.default.removeItem(at: report)
        }
        let request = RenderRequest(
            engine: engine,
            cyclesDevice: settings.cycles?.device == "CPU" ? .cpu : .gpu,
            source: animation || usesCamera ? .sceneCamera : .view(camera.renderCamera),
            output: url.path, deviceReport: Self.deviceReport.path,
            progressReport: Self.progressReport.path,
            animation: animation ? RenderRequest.Animation(
                video: settings.outputUntouched && settings.ffmpegAvailable,
                frames: Self.framesReport.path, cancel: Self.cancelFlag.path,
                result: Self.resultReport.path) : nil)
        renderPath = url
        renderingAnimation = animation
        cancelling = false
        animationFrame = nil
        device = nil
        progress = nil
        progressFraction = nil
        rendering = true
        startedAt = Date()
        if animation { player?.pause() }
        // No undo step: the render puts back what it set (`_blenderkit_render`).
        session.runScript(request.python, scene: scene, recordsUndo: false)
        if !session.isRunning { finishBlenderRender() }
    }

    /// Where the render script writes the device it used, how far along it
    /// is, the frame in hand, and an animation's outcome; and the file Cancel
    /// writes. Temporary: read, removed, and no use afterwards.
    private static var deviceReport: URL { temporary("render-device.txt") }
    private static var progressReport: URL { temporary("render-progress.txt") }
    private static var framesReport: URL { temporary("render-frame.txt") }
    private static var resultReport: URL { temporary("render-animation.json") }
    private static var cancelFlag: URL { temporary("render-cancel") }

    private static func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func offlineRender() {
        rendering = true
        defer { rendering = false }
        let start = DispatchTime.now().uptimeNanoseconds
        guard let bytes = OfflineRenderer.render(scene: scene, camera: camera,
                                                 width: size.width, height: size.height)
        else {
            problem = "This device has no Metal GPU to render with."
            return
        }
        lastSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let image = TextureImage(width: size.width, height: size.height, name: "Render Result")
        image.replace(with: bytes)
        scene.renderResult = image
        scene.renderVersion &+= 1
        session.log("bpy.ops.render.render(write_still=False)")
    }

    private func finishBlenderRender() {
        let animation = renderingAnimation
        defer {
            rendering = false
            renderPath = nil
            cancelling = false
            try? FileManager.default.removeItem(at: Self.cancelFlag)
            try? FileManager.default.removeItem(at: Self.framesReport)
        }
        if let startedAt { lastSeconds = Date().timeIntervalSince(startedAt) }
        if let reported = try? String(contentsOf: Self.deviceReport, encoding: .utf8), !reported.isEmpty {
            device = reported
        }
        try? FileManager.default.removeItem(at: Self.deviceReport)
        if animation {
            finishAnimation()
            return
        }
        // The script's own error is the one worth showing: "no camera" reads
        // as a sentence, and a traceback's last line is the exception.
        if let failure = session.lastRun?.error {
            problem = session.lastRun?.errorMessage ?? failure
            problemWantsCamera = usesCamera && scene.sceneCamera == nil
            return
        }
        guard let url = renderPath, let image = UIImage(contentsOfFile: url.path)?.cgImage else {
            problem = "Blender finished but wrote no image."
            return
        }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { problem = "The render could not be read back."; return }
        let result = TextureImage(width: w, height: h, name: url.deletingPathExtension().lastPathComponent)
        result.replace(with: pixels)
        scene.renderResult = result
        scene.renderVersion &+= 1
        showsAnimation = false
        savedName = "Saved as \(url.lastPathComponent) in Files ▸ Blender Local ▸ Renders."
        savedURL = url
        noteKernels()
        session.note("Render saved: Renders/\(url.lastPathComponent)")
        #if DEBUG
        readSettings()
        debugFinished("Render Image \(url.lastPathComponent) \(w)×\(h)")
        #endif
    }

    private func finishAnimation() {
        let result = (try? String(contentsOf: Self.resultReport, encoding: .utf8)).flatMap(RenderAnimationResult.parse)
        try? FileManager.default.removeItem(at: Self.resultReport)
        #if DEBUG
        defer { if let problem { print("[bk-render] problem: \(problem)"); fflush(stdout) } }
        #endif
        if let failure = session.lastRun?.error, result?.frames ?? 0 == 0 {
            problem = session.lastRun?.errorMessage ?? failure
            problemWantsCamera = scene.sceneCamera == nil
            return
        }
        guard let result, result.frames > 0 else {
            problem = "Blender finished but rendered no frame."
            return
        }
        let url = URL(fileURLWithPath: result.path)
        RenderFolder.lastAnimation = url
        showAnimation(url)
        let what = result.isVideo ? url.lastPathComponent : "\(url.lastPathComponent) (\(result.frames) frames)"
        savedName = (result.cancelled ? "Cancelled after frame \(result.frames) of \(result.total). " : "")
            + "Saved as \(what) in Files ▸ Blender Local ▸ Renders."
        noteKernels()
        session.note("Animation saved: Renders/\(url.lastPathComponent)"
                     + (result.cancelled ? " (cancelled after \(result.frames) of \(result.total) frames)" : ""))
        #if DEBUG
        readSettings()
        debugFinished("Render Animation \(result.kind) \(url.path) · \(result.frames) of \(result.total) frames"
                      + (result.cancelled ? " · cancelled" : ""))
        #endif
    }

    #if DEBUG
    @State private var debugLastLine = ""

    /// What the panel shows as it renders, printed once per change
    /// (`[bk-render]`), and `-render-cancel-at <n>`: Cancel pressed once
    /// frame n is under way.
    private func debugProgress() {
        let line = progressText
        if line != debugLastLine {
            debugLastLine = line
            let at = startedAt.map { String(format: "+%.1fs ", Date().timeIntervalSince($0)) } ?? ""
            print("[bk-render] \(at)\(line)")
            fflush(stdout)
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-render-cancel-at"), i + 1 < args.count, let at = Int(args[i + 1]),
           let frame = animationFrame, frame.index >= at, !cancelling {
            print("[bk-render] Cancel pressed during frame \(frame.index) of \(frame.total)")
            fflush(stdout)
            cancelAnimation()
        }
    }

    private func debugFinished(_ what: String) {
        let h = session.backendHistory
        print("[bk-render] finished: \(what) · \(lastSeconds.map { String(format: "%.2f s", $0) } ?? "?")"
              + " · device \(device ?? "?") · undo step \(h.index) of \(h.steps), last '\(h.undoLabel)'"
              + " · frame \(scene.frameCurrent)")
        // `-render-done-exit`: the run's end for apprun.sh.
        if ProcessInfo.processInfo.arguments.contains("-render-done-exit") { print("[bk-render] ops: done") }
        if let settings {
            print("[bk-render] scene after: engine \(settings.engine), \(settings.resolutionX)×\(settings.resolutionY)"
                  + " \(settings.resolutionPercentage)%, \(settings.mediaType)/\(settings.fileFormat),"
                  + " ffmpeg \(settings.ffmpegFormat)/\(settings.ffmpegCodec), frames \(settings.frameStart)–\(settings.frameEnd)")
        }
        fflush(stdout)
    }
    #endif

    /// A Cycles render that finished on the GPU means its kernels are built.
    private func noteKernels() {
        if engine == .cycles, let device, device.contains("Cycles on"), !device.contains("CPU") {
            kernelsBuilt = true
        }
    }
}

/// An image-sequence animation, played as Blender's View Animation plays one:
/// a frame at a time at the scene's rate, read from disk as it is shown.
struct FrameFlipbook: View {
    var folder: URL
    var fps: Double

    @State private var frames: [URL] = []
    @State private var index = 0
    @State private var playing = true
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                if let image {
                    Image(uiImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            HStack(spacing: 8) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause" : "Play")
                if frames.count > 1 {
                    Slider(value: Binding(get: { Double(index) },
                                          set: { index = Int($0.rounded()); playing = false; load() }),
                           in: 0...Double(frames.count - 1))
                }
                Text(frames.isEmpty ? "" : "\(index + 1) / \(frames.count)")
                    .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .onAppear {
            frames = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["png", "jpg", "jpeg", "exr", "tif", "tiff", "webp"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            index = 0
            load()
        }
        .onReceive(Timer.publish(every: 1 / max(min(fps, 60), 1), on: .main, in: .common).autoconnect()) { _ in
            guard playing, frames.count > 1 else { return }
            index = (index + 1) % frames.count
            load()
        }
    }

    private func load() {
        guard frames.indices.contains(index) else { image = nil; return }
        image = UIImage(contentsOfFile: frames[index].path)
    }
}

/// Renders without a viewport.
///
/// Rendering only needs a Metal device and the scene, not an on-screen view —
/// and the Rendering workspace has no viewport of its own, so routing the
/// request through the viewport's draw loop would mean it never fired.
enum OfflineRenderer {
    static func render(scene: BKScene, camera: ViewportCamera,
                       width: Int, height: Int) -> [UInt8]? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = ViewportRenderer(device: device, scene: scene, camera: camera)
        else { return nil }
        return renderer.renderOffscreen(width: width, height: height)
    }
}
