import SwiftUI

/// The bpy workspace — and, since bpy owns the scene, the primary way in.
///
/// Laid out the way ManimStudio lays out its workspace, because the job is the
/// same: write Python against a real library, run it, watch what came out.
/// Editor on the left, live 3D preview on the right, console beneath, and a
/// controls strip along the top. The splits are draggable and remembered, so
/// the proportions you want for writing and the ones you want for watching are
/// both a drag away.
struct ScriptingWorkspace: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera

    /// The backend's operator list, for completion in the editor.
    var catalogue: OperatorCatalogue
    @State private var document = ScriptDocument.restored()
    @State private var options = ViewportOptions()
    @State private var shading: ViewportShading = .solid
    @State private var showFiles = false
    @AppStorage(BpySession.offMainThreadKey) private var scriptsOffMainThread = true
    @State private var editor = MonacoController()
    @State private var metadata = "{}"
    /// The text as typed, and its pending save. Held by reference rather than
    /// in `document`: Monaco reports a change after every pause in typing, and
    /// writing each one into view state re-ran this whole tab — the console,
    /// the preview, and the menu bar's keyboard commands — while the reader
    /// was typing. The main thread stalled under it, so a key's release came
    /// late and repeated the key, and a click on the editor could still send
    /// keys to the console.
    @State private var draft = ScriptDraft()
    @Environment(\.scenePhase) private var scenePhase
    /// Bumped to put the keyboard at the console prompt.
    @State private var consoleFocusRequest = 0
    /// The editor's text size, kept between launches: ⌘+, ⌘− and ⌘0.
    @AppStorage("bl_editor_font_size") private var editorFontSize = 14
    /// The console's own size, as BenchCode keeps its terminal's apart from
    /// its editor's: ⌘+ sizes whichever of the two has the keyboard.
    @AppStorage("bl_console_font_size") private var consoleFontSize = 14

    /// Remembered across launches: the proportions someone sets for writing are
    /// rarely the ones they want for watching.
    @AppStorage("bl_script_hsplit") private var hSplit: Double = 0.52
    @AppStorage("bl_script_vsplit") private var vSplit: Double = 0.62

    var body: some View {
        #if DEBUG
        let _ = FocusLog.count("scripting body")
        #endif
        VStack(spacing: 0) {
            controlBar

            GeometryReader { outer in
                HStack(spacing: 0) {
                    // Editor
                    MonacoScriptEditor(documentID: document.id, source: document.text,
                                       metadata: metadata, controller: editor,
                                       onChange: { text in
                                           draft.text = text
                                           scheduleSave()
                                       }, onRun: run, fontSize: editorFontSize)
                    .frame(width: outer.size.width * hSplit)

                    BSplitHandle(.vertical) { delta in
                        hSplit = min(max(hSplit + delta / outer.size.width, 0.2), 0.8)
                    }

                    // Preview over console, as ManimStudio stacks preview over
                    // its render log.
                    VStack(spacing: 0) {
                        preview
                            .frame(height: outer.size.height * vSplit)
                        BSplitHandle(.horizontal) { delta in
                            vSplit = min(max(vSplit + delta / outer.size.height, 0.2), 0.85)
                        }
                        ConsoleTerminalPane(scene: scene, session: session,
                                            focusRequest: consoleFocusRequest,
                                            fontSize: consoleFontSize)

                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task { refreshMetadata() }
        .onDisappear {
            draft.saveTask?.cancel()
            var draft = document
            editor.source { source in draft.text = source; draft.saveDraft() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                editor.source { source in document.text = source; document.saveDraft() }
            }
        }
        .onChange(of: session.isRunning) { _, running in
            // A run that starts makes the last one's error stale: the line it
            // names may not even hold the same code any more.
            if running {
                if session.runKind == .script { editor.clearError() }
                return
            }
            // A console command's outcome is the console's: an error there has
            // no line in this script to point at.
            guard session.lastRunKind == .script else {
                refreshMetadata()
                if camera.framesPoorly(scene.objects) { camera.frameAll(scene.objects) }
                return
            }
            // Show the reader where it stopped, and why, beside the code it is
            // about. The console carries the same traceback, but the console
            // is on the other side of the screen from the code.
            if let outcome = session.lastRun, outcome.error != nil,
               let line = outcome.errorLine {
                editor.markError(line: line, name: outcome.errorName,
                                 message: outcome.errorMessage,
                                 frames: outcome.frames, fileName: document.name)
            } else {
                editor.clearError()
            }
            refreshMetadata()
            if camera.framesPoorly(scene.objects) { camera.frameAll(scene.objects) }
        }
        // Another document's text replaces what was typed into the last one.
        .onChange(of: document.id) { _, _ in draft.text = nil }
        // The keyboard: see KeyboardCommands.swift.
        .focusedSceneValue(\.scriptingKeys, scriptingKeys)
    }

    /// Everything the Scripting tab's keys can do, published while it is on
    /// screen. The keys themselves are in KeyboardCommands.swift.
    private var scriptingKeys: ScriptingKeyActions {
        ScriptingKeyActions(
            isRunning: session.isRunning,
            run: { editor.source(run) },
            stop: { session.stopScript() },
            newScript: { document = ScriptDocument() },
            save: {
                // Say what happened. A silent Save cannot be told from a
                // failed one.
                editor.source { source in document.text = source; session.note(document.save()) }
            },
            clearConsole: { session.clearConsole() },
            switchEditorAndConsole: {
                if let console = ConsoleTerminal.focused {
                    _ = console.resignFirstResponder()
                    editor.focus()
                } else {
                    consoleFocusRequest += 1
                }
            },
            editor: { editor.trigger($0) },
            textSize: { step in
                // Whichever pane has the keyboard: the console and the code
                // are read differently, and each keeps its own size.
                func stepped(_ size: Int) -> Int { step == 0 ? 14 : min(max(size + step, 9), 32) }
                if ConsoleTerminal.focused != nil {
                    consoleFontSize = stepped(consoleFontSize)
                } else {
                    editorFontSize = stepped(editorFontSize)
                }
            })
    }

    private func scheduleSave() {
        draft.saveTask?.cancel()
        let current: ScriptDocument = {
            var typed = document
            if let text = draft.text { typed.text = text }
            return typed
        }()
        draft.saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { current.saveDraft() }.value
        }
    }

    private func refreshMetadata() {
        guard !session.isRunning else { return }
        // A single cached snapshot, never a request from the keystroke path.
        if let result = session.capture("import _blenderkit_sync as _bkui; import json; print(json.dumps(_bkui.editor_metadata()))") {
            metadata = result
        }
    }

    // MARK: control bar

    /// The file, the examples, and Run.
    ///
    /// New and Save were two more buttons of the same weight as Run, in a strip
    /// where Run is the reason for being here. They live with the file they act
    /// on now, in the file menu, and Run is the one filled button.
    private var controlBar: some View {
        HStack(spacing: 6) {
            Button { showFiles.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text(document.name).font(BTheme.Font.ui(11)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .popover(isPresented: $showFiles) { fileList }

            // Ten worked scripts that were still in the bundle and had
            // stopped being reachable — the menu went with the old editor's
            // header. They are the fastest way to see what the app can do, and
            // one of them is the bike.
            Menu {
                ForEach(ScriptExample.allCases) { example in
                    Button {
                        document = ScriptDocument(name: example.rawValue, text: example.source)
                    } label: {
                        if example.needsRealBpy {
                            Label(example.rawValue + " (device only)", systemImage: "iphone")
                        } else {
                            Text(example.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "book").font(.system(size: 11))
                    Text("Examples").font(BTheme.Font.ui(11))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }

            // The one setting about how scripts run. It lived in a Window menu
            // that nothing put on screen, so from build 20 until build 34 it
            // could not be changed — while the temp_override warning told
            // people to change it.
            Menu {
                Toggle("Run Scripts Off the Main Thread", isOn: $scriptsOffMainThread)
                Text("Off: scripts run on the main thread, and the interface waits for each one.")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape").font(.system(size: 11))
                    Text("Options").font(BTheme.Font.ui(11))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }

            Spacer(minLength: 12)

            if session.isRunning {
                BButton("Stop", icon: "stop.fill") { session.stopScript() }
            } else {
                // ⌘R lives in the Script menu now; a second binding here would
                // fight it for the key.
                BPrimaryButton("Run", icon: "play.fill", shortcut: "⌘R") { editor.source(run) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(BTheme.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BTheme.editorOutline).frame(height: BTheme.Metric.hairline)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileAction("New Script", icon: "plus") {
                document = ScriptDocument()
                showFiles = false
            }
            fileAction("Save", icon: "square.and.arrow.down") {
                // Say what happened. A silent Save cannot be told from a
                // failed one.
                editor.source { source in document.text = source; session.note(document.save()) }
                showFiles = false
            }
            Divider()
            Text("Scripts").font(BTheme.Font.ui(11, weight: .medium))
                .foregroundStyle(BTheme.textDim)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if ScriptDocument.saved().isEmpty {
                Text("Nothing saved yet")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    .padding(10)
            } else {
                ForEach(ScriptDocument.saved(), id: \.self) { url in
                    Button {
                        document = ScriptDocument(url: url)
                        ScriptDocument.remember(url)
                        showFiles = false
                    } label: {
                        HStack {
                            Image(systemName: "doc.text").font(.system(size: 10))
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(BTheme.Font.ui(11))
                            Spacer()
                        }
                        .foregroundStyle(BTheme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                .hoverEffect(.highlight)
                }
            }
            Divider()
            Menu("Examples") {
                ForEach(ScriptExample.allCases) { e in
                    Button(e.needsRealBpy ? "\(e.rawValue) (device only)" : e.rawValue) {
                        document = ScriptDocument(name: e.rawValue, text: e.source)
                        showFiles = false
                    }
                }
            }
            .font(BTheme.Font.ui(11))
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 240)
        .background(BTheme.header)
    }

    private func fileAction(_ title: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                Text(title).font(BTheme.Font.ui(12))
                Spacer()
            }
            .foregroundStyle(BTheme.text)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: preview

    /// Whether the viewport is showing the scene from before the run in
    /// progress. Blender's bpy is mirrored into the display cache when a run
    /// ends, not as it goes; the shim changes the display cache directly, call
    /// by call, so there the view is never behind.
    private var showsSceneFromBeforeRun: Bool { session.isRunning && session.usesRealBlender }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            MetalViewportView(scene: scene, camera: $camera,
                              shading: shading, options: options,
                              onSelectionChange: { _ in })
                .opacity(showsSceneFromBeforeRun ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Showcase").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        ForEach(ViewportShading.allCases) { mode in
                            Button(mode.rawValue) { shading = mode }.disabled(!mode.isImplemented)
                        }
                    } label: { Image(systemName: "circle.lefthalf.filled").frame(width: 36, height: 36) }
                    Button { camera.frameAll(scene.objects) } label: {
                        Image(systemName: "viewfinder").frame(width: 36, height: 36)
                    }.accessibilityLabel("Frame showcase")
                }.padding(.horizontal, 12).background(BTheme.header.opacity(0.92))
                Spacer()
                // What is in the scene. How the last run went is in the top
                // bar and, when it failed, under the failing line — not here
                // in a corner as "See console for error".
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(scene.active?.name ?? "Scene").font(.system(size: 12, weight: .medium))
                        // Vertices of what is drawn, as the status bar counts
                        // them: a hidden object keeps its last-drawn mesh.
                        Text("\(scene.objects.count) objects · \(scene.objects.filter(\.visible).reduce(0) { $0 + $1.mesh.vertices.count }) vertices")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Spacer()
                }.padding(12).background(BTheme.header.opacity(0.9))
            }.foregroundStyle(BTheme.text)

            if showsSceneFromBeforeRun {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(BTheme.active)
                        .scaleEffect(0.7).frame(width: 12, height: 12)
                    Text("The view updates when the run finishes")
                }
                .font(BTheme.Font.ui(12))
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(BTheme.header.opacity(0.92))
                .clipShape(Capsule())
                .overlay { Capsule().strokeBorder(BTheme.outline, lineWidth: 1) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
    }

    private func run(_ source: String) {
        draft.text = source
        scheduleSave()
        session.runScript(source, scene: scene)
        // Building something off-camera is the commonest way for a script to
        // look like it did nothing.
        if camera.framesPoorly(scene.objects) {
            camera.frameAll(scene.objects)
        }
    }
}

/// What has been typed into the open script since it was opened, and the save
/// that is waiting to write it. A reference, so changing it redraws nothing.
final class ScriptDraft {
    var text: String?
    var saveTask: Task<Void, Never>?
}

/// One script, in memory or on disk.
struct ScriptDocument: Sendable {
    let id = UUID()
    var name: String
    var text: String
    var url: URL?

    init() {
        name = "untitled.py"
        text = ScriptExample.starterSource
    }

    init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func saved() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "py" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// Writes the script, returning what to tell the user.
    ///
    /// The error used to be swallowed by `try?`, so a failed save was
    /// indistinguishable from a successful one — and since the editor always
    /// opened on the starter example, a save that *did* work still looked lost
    /// after a relaunch.
    @discardableResult
    mutating func save() -> String {
        let target = url ?? Self.directory.appendingPathComponent(
            name.hasSuffix(".py") ? name : name + ".py")
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            url = target
            name = target.lastPathComponent
            Self.remember(target)
            return "Saved \(name)"
        } catch {
            return "Could not save \(name): \(error.localizedDescription)"
        }
    }

    /// The buffer is kept between launches whether or not it was ever saved,
    /// the way the scene is autosaved — losing an unsaved script to a relaunch
    /// is not a trade anyone would choose.
    static let draftURL = directory.appendingPathComponent(".draft.py")
    private static let lastOpenedKey = "bl_script_last_opened"

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.lastPathComponent, forKey: lastOpenedKey)
    }

    func saveDraft() {
        try? text.write(to: Self.draftURL, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(name, forKey: Self.lastOpenedKey)
    }

    /// What to open on launch: the file last opened if it is still there, the
    /// unsaved draft if there is one, otherwise the starter example.
    static func restored() -> ScriptDocument {
        if let draft = try? String(contentsOf: draftURL, encoding: .utf8) {
            return ScriptDocument(name: UserDefaults.standard.string(forKey: lastOpenedKey) ?? "untitled.py", text: draft)
        }
        if let last = UserDefaults.standard.string(forKey: lastOpenedKey) {
            let candidate = directory.appendingPathComponent(last)
            if FileManager.default.fileExists(atPath: candidate.path) { return ScriptDocument(url: candidate) }
        }
        return ScriptDocument()
    }
}

/// A draggable divider between two panes.
struct BSplitHandle: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let onDrag: (Double) -> Void

    init(_ axis: Axis, onDrag: @escaping (Double) -> Void) {
        self.axis = axis
        self.onDrag = onDrag
    }

    @State private var dragging = false
    @State private var previousTranslation: Double = 0

    var body: some View {
        Rectangle()
            .fill(dragging ? BTheme.active.opacity(0.5) : BTheme.editorOutline)
            .frame(width: axis == .vertical ? 6 : nil,
                   height: axis == .horizontal ? 6 : nil)
            .overlay(
                Capsule().fill(dragging ? BTheme.active : BTheme.textDim.opacity(0.35))
                    .frame(width: axis == .vertical ? (dragging ? 3 : 2) : (dragging ? 40 : 26),
                           height: axis == .horizontal ? (dragging ? 3 : 2) : (dragging ? 40 : 26))
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .overlay { SplitPointerShape(axis: axis).allowsHitTesting(false) }
            .gesture(
                DragGesture()
                    .onChanged { g in
                        dragging = true
                        let total = axis == .vertical ? g.translation.width : g.translation.height
                        onDrag(total - previousTranslation)
                        previousTranslation = total
                    }
                    .onEnded { _ in dragging = false; previousTranslation = 0 }
            )
    }
}

/// Morphs a trackpad pointer into a beam across the divider.
///
/// The divider between two editors is the one control a trackpad user expects
/// to change the cursor, because every other app's does. SwiftUI's
/// `pointerStyle` has the resize shapes but marks them unavailable on iOS, so
/// this drops to `UIPointerInteraction`, which is what iPadOS actually offers:
/// the pointer takes the shape you hand it rather than picking from a set of
/// system cursors.
private struct SplitPointerShape: UIViewRepresentable {
    let axis: BSplitHandle.Axis

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.axis = axis
    }

    func makeCoordinator() -> Coordinator { Coordinator(axis: axis) }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        var axis: BSplitHandle.Axis
        init(axis: BSplitHandle.Axis) { self.axis = axis }

        func pointerInteraction(_ interaction: UIPointerInteraction,
                                styleFor region: UIPointerRegion) -> UIPointerStyle? {
            // A beam laid along the divider: a vertical bar for a left/right
            // split, a horizontal one for a top/bottom split. Constraining the
            // pointer to that axis is what makes it feel latched to the
            // divider while you drag.
            let shape: UIPointerShape = axis == .vertical
                ? .verticalBeam(length: 28)
                : .horizontalBeam(length: 28)
            return UIPointerStyle(shape: shape,
                                  constrainedAxes: axis == .vertical ? .vertical : .horizontal)
        }
    }
}
