import SwiftUI
import Metal

/// Blender's Rendering workspace: the render result in an image editor, with
/// the controls that produce it.
///
/// Two things a render needs and a scene may not have — a camera, and a light —
/// are answered here rather than left to fail: the panel says which is missing
/// and offers the button that adds it, and renders can be taken through the 3D
/// View instead of a camera at all.
struct RenderingWorkspace: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera

    @State private var engine = RenderRequest.Engine.cycles
    @State private var quality = RenderRequest.Quality.good
    @State private var width = 1920
    @State private var height = 1080
    /// Render the 3D View rather than the scene's camera. The shim has no
    /// Blender to render through, and its stand-in draws the view, so it is
    /// the only thing it can honestly offer.
    @State private var fromView = false
    @State private var rendering = false
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
    /// The render on disk, for the share sheet.
    @State private var savedURL: URL?
    /// Cycles compiles its Metal kernels the first time it renders on a
    /// device — minutes, once, cached afterwards. Remembered so the warning
    /// is shown before that render and not after.
    @AppStorage("bl_cycles_kernels_built") private var kernelsBuilt = false

    private var usesCamera: Bool { !fromView && session.usesRealBlender }

    var body: some View {
        VStack(spacing: 0) {
            ImageEditor(title: "Render Result",
                        image: scene.renderResult,
                        version: scene.renderVersion,
                        emptyMessage: emptyMessage,
                        headerContent: AnyView(header),
                        emptyAction: AnyView(renderButton))
            notes
        }
        .onChange(of: session.isRunning) { _, running in
            if !running && rendering && renderPath != nil { finishBlenderRender() }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            guard rendering,
                  let line = try? String(contentsOf: Self.progressReport, encoding: .utf8),
                  !line.isEmpty else { return }
            let read = RenderingWorkspaceProgress.read(line)
            progress = read.text
            progressFraction = read.fraction
        }
        .onAppear { if !session.usesRealBlender { fromView = true } }
    }

    private var emptyMessage: String {
        let size = "\(width) × \(height)"
        if usesCamera {
            guard let name = scene.sceneCamera?.name else {
                return "No render yet.\nThis renders through the scene's camera — there isn't one yet."
            }
            return "No render yet.\nThis renders through \(name), at \(size)."
        }
        return "No render yet.\nThis renders the 3D View's own viewpoint, at \(size)."
    }

    private var renderButton: some View {
        BButton(rendering ? "Rendering…" : "Render Image", icon: "camera.aperture") { render() }
            .disabled(rendering || session.isRunning)
    }

    private var header: some View {
        HStack(spacing: 6) {
            sourceMenu
            if session.usesRealBlender {
                Menu {
                    Picker("Engine", selection: $engine) {
                        ForEach(RenderRequest.Engine.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    Text(engine.summary)
                } label: { chip(engine.label) }
                Menu {
                    Picker("Quality", selection: $quality) {
                        ForEach(RenderRequest.Quality.allCases) { value in
                            Text(samplesLabel(value)).tag(value)
                        }
                    }
                } label: { chip(quality.rawValue) }
            }
            Menu {
                Button("1920 × 1080") { width = 1920; height = 1080 }
                Button("1280 × 720")  { width = 1280; height = 720 }
                Button("960 × 540")   { width = 960;  height = 540 }
            } label: { chip("\(width)×\(height)") }

            if let savedURL, !rendering {
                ShareLink(item: savedURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .frame(height: 22)
                        .padding(.horizontal, 6)
                        .background(BTheme.widget)
                        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                }
                .accessibilityLabel("Share the render")
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

            renderButton
        }
    }

    /// The samples a quality takes, in the engine that will use them.
    private func samplesLabel(_ value: RenderRequest.Quality) -> String {
        let samples = engine == .cycles ? value.cyclesSamples : value.eeveeSamples
        return engine == .workbench ? value.rawValue : "\(value.rawValue) · \(samples) samples"
    }

    /// Which camera the render goes through, and — when the scene has more
    /// than one — which camera is the scene's.
    private var sourceMenu: some View {
        Menu {
            Button {
                fromView = false
            } label: {
                Label(scene.sceneCamera.map { "Camera: \($0.name)" } ?? "Scene Camera",
                      systemImage: usesCamera ? "checkmark" : "video")
            }
            .disabled(!session.usesRealBlender)
            Button {
                fromView = true
            } label: {
                Label("3D View", systemImage: !usesCamera ? "checkmark" : "cube")
            }
            if scene.cameras.count > 1 {
                Divider()
                Section("Scene Camera") {
                    ForEach(scene.cameras, id: \.id) { object in
                        Button(object.name) {
                            _ = bridge?.run(Bpy.setSceneCamera(object.name), undo: "Set Scene Camera")
                            fromView = false
                        }
                    }
                }
            }
        } label: {
            chip(usesCamera ? (scene.sceneCamera?.name ?? "Camera") : "3D View")
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

    /// What stands between this scene and a picture, under the image.
    @ViewBuilder private var notes: some View {
        if let problem {
            note(problem, colour: .orange) {
                if problemWantsCamera {
                    BButton("Add Camera", icon: "video") { addCamera() }
                    BButton("Render the 3D View", icon: "cube") { fromView = true; render() }
                }
            }
        } else if rendering {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress ?? "Rendering with \(engine.label) at \(quality.rawValue)…")
                        .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    if let progressFraction {
                        ProgressView(value: progressFraction).frame(maxWidth: 260)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BTheme.header)
        } else if usesCamera && scene.sceneCamera == nil {
            note("This scene has no camera.", colour: BTheme.textDim) {
                BButton("Add Camera", icon: "video") { addCamera() }
                BButton("Render the 3D View", icon: "cube") { fromView = true }
            }
        } else if engine.usesSceneLighting && scene.lights.isEmpty {
            note("Nothing lights this scene, so \(engine.label) will render it black.",
                 colour: BTheme.textDim) {
                BButton("Add Light", icon: "lightbulb") {
                    _ = bridge?.add(.light(.point), at: SIMD3(4, 1, 6), view: camera)
                }
                BButton("Use Solid", icon: "circle.lefthalf.filled") { engine = .workbench }
            }
        } else if engine == .cycles && !kernelsBuilt {
            note("Cycles renders on the GPU. The first one builds its shaders, which takes a few "
                 + "minutes once; every render after that is quick. Eevee needs no wait.",
                 colour: BTheme.textDim) {
                BButton("Use Eevee", icon: "bolt") { engine = .eevee }
            }
        } else if let savedName {
            note("\(device.map { $0 + ". " } ?? "")Saved as \(savedName) in Files ▸ Blender Local ▸ Renders.",
                 colour: BTheme.textDim) { EmptyView() }
        }
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

    private func render() {
        guard !session.isRunning else { return }
        problem = nil
        problemWantsCamera = false
        savedName = nil
        guard session.usesRealBlender else {
            offlineRender()
            return
        }
        let url = renderURL()
        let request = RenderRequest(engine: engine, quality: quality, width: width, height: height,
                                    source: usesCamera ? .sceneCamera : .view(camera.renderCamera),
                                    output: url.path, deviceReport: Self.deviceReport.path,
                                    progressReport: Self.progressReport.path)
        renderPath = url
        device = nil
        progress = nil
        progressFraction = nil
        try? FileManager.default.removeItem(at: Self.deviceReport)
        try? FileManager.default.removeItem(at: Self.progressReport)
        rendering = true
        startedAt = Date()
        session.runScript(request.python, scene: scene)
        if !session.isRunning { finishBlenderRender() }
    }

    /// Renders are kept together and named by date, so a folder of them reads
    /// in order — rather than a `render-<uuid>.png` per press loose in
    /// Documents, which is what the Files app used to show.
    private func renderURL() -> URL {
        let folder = SceneDocument.documentsURL.appendingPathComponent("Renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(RenderRequest.fileName())
    }

    /// Where the render script writes the device it used, and how far along it
    /// is. Temporary: both are read and removed, and are no use afterwards.
    private static var deviceReport: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("render-device.txt")
    }

    private static var progressReport: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("render-progress.txt")
    }

    private func offlineRender() {
        rendering = true
        defer { rendering = false }
        let start = DispatchTime.now().uptimeNanoseconds
        guard let bytes = OfflineRenderer.render(scene: scene, camera: camera,
                                                 width: width, height: height)
        else {
            problem = "This device has no Metal GPU to render with."
            return
        }
        lastSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let image = TextureImage(width: width, height: height, name: "Render Result")
        image.replace(with: bytes)
        scene.renderResult = image
        scene.renderVersion &+= 1
        session.log("bpy.ops.render.render(write_still=False)")
    }

    private func finishBlenderRender() {
        defer { rendering = false; renderPath = nil }
        if let startedAt { lastSeconds = Date().timeIntervalSince(startedAt) }
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
        savedName = url.lastPathComponent
        savedURL = url
        if let reported = try? String(contentsOf: Self.deviceReport, encoding: .utf8),
           !reported.isEmpty {
            device = reported
            if engine == .cycles, reported.contains("Cycles on"), !reported.contains("CPU") {
                kernelsBuilt = true
            }
        }
        try? FileManager.default.removeItem(at: Self.deviceReport)
        session.note("Render saved: Renders/\(url.lastPathComponent)")
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
