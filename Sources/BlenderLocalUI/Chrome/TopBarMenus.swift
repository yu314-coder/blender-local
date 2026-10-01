import SwiftUI
import UniformTypeIdentifiers

/// A menu entry Blender has that Blender Local does not implement.
///
/// Shown in place, disabled, so the menus have Blender's real shape and it is
/// obvious what exists versus what this app does. Hiding them would make the
/// menus look arbitrarily short; enabling them would be a lie.
struct BUnavailable: View {
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).disabled(true)
    }
}

/// Blender's File menu (`TOPBAR_MT_file`).
struct FileMenu: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var savedFiles: [URL]
    @State private var choosingFile = false
    @State private var importing = false
    @State private var namingSave = false
    @State private var saveName = "Scene"
    @State private var lastSavedURL: URL?

    var body: some View {
        Menu("File") {
            Menu("New") {
                Button("General") { newScene() }
                BUnavailable("2D Animation")
                BUnavailable("Sculpting")
                BUnavailable("VFX")
                BUnavailable("Video Editing")
            }
            Button("Open…") { importing = false; choosingFile = true }
                .disabled(session.isRunning)
            Menu("Open Recent") {
                if savedFiles.isEmpty {
                    Text("No recent files").disabled(true)
                } else {
                    ForEach(savedFiles, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            session.openDocument(url, scene: scene)
                        }
                    }
                }
            }
            Button("Revert") {
                let url = session.usesRealBlender
                    ? SceneDocument.documentsURL.appendingPathComponent("autosave.blend")
                    : SceneDocument.autosaveURL
                session.openDocument(url, scene: scene)
            }
            BUnavailable("Recover")

            Divider()
            Button("Save") { save() }
            Button("Save As…") { namingSave = true }
            if let lastSavedURL { ShareLink("Share Saved File…", item: lastSavedURL) }

            Divider()
            BUnavailable("Link…")
            BUnavailable("Append…")
            BUnavailable("Data Previews")

            Divider()
            Button("Import Model…") { importing = true; choosingFile = true }
                .disabled(!session.usesRealBlender || session.isRunning)
            Menu("Export") {
                ForEach(BpySession.exporters, id: \.ext) { exporter in
                    Button(exporter.label) { exportModel(exporter.op, ext: exporter.ext) }
                }
            }.disabled(!session.usesRealBlender || session.isRunning)

            Divider()
            Menu("External Data") {
                BUnavailable("Automatically Pack Resources")
                Button("Pack Resources") { session.submit("bpy.ops.file.pack_all()", scene: scene) }
                    .disabled(!session.usesRealBlender)
                BUnavailable("Unpack Resources")
                Button("Make Paths Relative") { session.submit("bpy.ops.file.make_paths_relative()", scene: scene) }
                    .disabled(!session.usesRealBlender)
                BUnavailable("Make Paths Absolute")
                BUnavailable("Report Missing Files")
                BUnavailable("Find Missing Files…")
            }
            Menu("Clean Up") {
                BUnavailable("Purge Unused Data…")
                BUnavailable("Manage Unused Data…")
            }

            Divider()
            Menu("Defaults") {
                BUnavailable("Save Startup File")
                Button("Load Factory Settings") { newScene() }
            }
        }
        .menuStyle(BlenderMenuStyle())
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if importing { importModel(url) }
                else { session.openDocument(url, scene: scene) }
            case .failure(let error): session.note("Open failed: \(error.localizedDescription)")
            }
        }
        .alert("Save Scene", isPresented: $namingSave) {
            TextField("Name", text: $saveName)
            Button("Save") { save(named: saveName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Save a new copy in the app's Documents folder.") }
    }

    /// Import runs where the menus run, not on the script thread.
    ///
    /// Blender's own importers — `wm.obj_import` and the rest — poll for a
    /// window, and a script thread has none: sent through `submit`, six of the
    /// seven formats answered "context is incorrect" and nothing arrived. Only
    /// glTF worked, because its importer is a Python add-on that does not ask.
    private func importModel(_ url: URL) {
        guard let op = BpySession.importers[url.pathExtension.lowercased()] else {
            session.note("Choose OBJ, GLB/glTF, USD, STL, PLY, FBX or Alembic."); return
        }
        guard let bridge else { session.note("Import needs Blender."); return }
        let before = scene.objects.count
        let outcome = bridge.run(BpySession.importPython(op, from: url.path), undo: "Import Model")
        if outcome.succeeded, scene.objects.count > before {
            session.note("Imported \(url.lastPathComponent).")
        } else {
            session.note("Import failed: " + (outcome.error ?? "nothing arrived."))
        }
    }

    private func exportModel(_ op: String, ext: String) {
        guard let url = session.exportModel(op, ext: ext) else {
            session.note("Export failed. See the console for the Blender error."); return
        }
        lastSavedURL = url
        session.note("Exported \(url.lastPathComponent). Use File > Share Saved File to export it from the app.")
    }

    /// File > New: Blender's startup scene, in the app's own screen.
    ///
    /// `read_homefile` has to run on the main thread. Loading a file takes
    /// Blender's screen down first — `ED_screen_exit` for every window, whatever
    /// `load_ui` says — and that reads the window from the context, which
    /// Blender gives out on the main thread only. From a script on the script
    /// thread it read NULL, and the app crashed in
    /// `WM_event_modal_handler_region_replace` (reports
    /// BlenderLocal-2026-09-22-100656 and -100743). File > New was never on that
    /// thread: `session.submit`, which it used before, evaluates on its caller,
    /// and `bridge.run` does too. A script that loads a file is moved to the
    /// main thread by `ScriptThread.needsMainThread`, and refused off it by
    /// `_blenderkit_context.guard_file_reads`.
    ///
    /// `load_ui=False` keeps the app's screen rather than the startup file's,
    /// as File > Open does: Knife Project, sculpting and hiding borrow that
    /// screen's 3D View, and a file's own screen may have none. Measured in
    /// desktop Blender 5.2.1 with the app's context (undo stack, gpu.init, a
    /// view override): it resets to Cube, Light and Camera, leaves Edit Mode,
    /// keeps the screen, and an undo push and a view override both work
    /// straight after, twice in a row.
    ///
    /// No undo label: loading a file ends Blender's undo history, and
    /// `_blenderkit_undo` saves the scene being replaced first (its load_pre
    /// handler), so the step before New can still be returned to.
    private func newScene() {
        guard let bridge, !session.isRunning else { return }
        bridge.run("bpy.ops.wm.read_homefile(load_ui=False)")
    }

    /// Blender prompts for a path; without a document browser this picks the
    /// next free numbered name in Documents.
    private func save(named name: String? = nil) {
        guard !session.isRunning else { return }
        let ext = session.usesRealBlender ? "blend" : SceneDocument.fileExtension
        let existing = Set(SceneDocument.listSaved().map(\.lastPathComponent))
        let base = (name ?? "Scene").components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_" )).inverted).joined()
        let safeName = base.isEmpty ? "Scene" : base
        var candidate = safeName + "." + ext
        var n = 2
        while existing.contains(candidate) { candidate = "\(safeName) \(n).\(ext)"; n += 1 }
        let url = SceneDocument.documentsURL.appendingPathComponent(candidate)
        session.saveDocument(url, scene: scene)
        savedFiles = SceneDocument.listSaved()
        if FileManager.default.fileExists(atPath: url.path) { lastSavedURL = url }
    }
}

/// Blender's Edit menu (`TOPBAR_MT_edit`).
struct EditMenu: View {
    var scene: BKScene
    var session: BpySession
    var undo: UndoStack

    var body: some View {
        Menu("Edit") {
            Button(undo.undoName.map { "Undo \($0)" } ?? "Undo") { session.performUndo() }
                .disabled(session.isRunning || session.gestureHold != nil
                          || (session.usesRealBlender ? !session.backendCanUndo : !undo.canUndo))
            Button(undo.redoName.map { "Redo \($0)" } ?? "Redo") { session.performRedo() }
                .disabled(session.isRunning || session.gestureHold != nil
                          || (session.usesRealBlender ? !session.backendCanRedo : !undo.canRedo))
            BUnavailable("Undo History")

            Divider()
            BUnavailable("Adjust Last Operation…")
            BUnavailable("Repeat Last")
            BUnavailable("Repeat History…")

            Divider()
            BUnavailable("Menu Search…")
            BUnavailable("Operator Search…")

            Divider()
            BUnavailable("Rename Active Item…")
            BUnavailable("Batch Rename…")

            Divider()
            BUnavailable("Lock Object Modes")

            Divider()
            BUnavailable("Preferences…")
        }
        .menuStyle(BlenderMenuStyle())
    }
}

/// Blender's Render menu (`TOPBAR_MT_render`).
struct RenderMenu: View {
    var onRender: () -> Void = {}

    var body: some View {
        Menu("Render") {
            Button("Render Image") { onRender() }
            BUnavailable("Render Animation")
            Divider()
            BUnavailable("Render Audio…")
            Divider()
            BUnavailable("View Render")
            BUnavailable("View Animation")
            Divider()
            BUnavailable("Lock Interface")
            Divider()
            Text("Renders with the viewport's PBR pass — no ray tracing, "
                 + "shadows or global illumination").disabled(true)
        }
        .menuStyle(BlenderMenuStyle())
    }
}

/// Blender's Window menu (`TOPBAR_MT_window`).
struct WindowMenu: View {
    @Binding var showStatusBar: Bool
    @Binding var workspace: Workspace

    var body: some View {
        Menu("Window") {
            // Blender's own documentation says the Python API should be
            // called from the main thread. Exactly one thread ever touches it
            // here, which is a different thing — but Blender's GPU code does
            // assert which thread it is on, so a script that renders is the
            // case that might disagree. Turning this off puts scripts back on
            // the main thread, at the cost of the interface freezing while
            // they run.
            Toggle("Run Scripts Off the Main Thread", isOn: Binding(
                get: { BpySession.runsOffMainThread },
                set: { BpySession.runsOffMainThread = $0 }))
            BUnavailable("New Window")
            BUnavailable("New Main Window")
            Divider()
            BUnavailable("Toggle Window Fullscreen")
            Divider()
            Button("Next Workspace") { cycle(1) }
            Button("Previous Workspace") { cycle(-1) }
            Divider()
            Toggle("Show Status Bar", isOn: $showStatusBar)
            Divider()
            BUnavailable("Save Screenshot…")
            BUnavailable("Toggle System Console")
        }
        .menuStyle(BlenderMenuStyle())
    }

    private func cycle(_ step: Int) {
        let all = Workspace.allCases
        guard let i = all.firstIndex(of: workspace) else { return }
        workspace = all[(i + step + all.count) % all.count]
    }
}

/// Blender's Help menu (`TOPBAR_MT_help`). Every entry opens a web page, and
/// Blender Local does not open web pages, so they are listed and disabled.
struct HelpMenu: View {
    var session: BpySession

    var body: some View {
        Menu("Help") {
            BUnavailable("Manual")
            BUnavailable("Support")
            BUnavailable("User Communities")
            BUnavailable("Developer Community")
            BUnavailable("Python API Reference")
            Divider()
            BUnavailable("Report a Bug")
            Divider()
            Button("Save System Info") {
                session.submit(
                    "import sys, platform\n"
                    + "print('Python', sys.version)\n"
                    + "print('Platform', platform.platform())\n"
                    + "import bpy; print('bpy', getattr(bpy.app, 'version_string', 'shim'))",
                    scene: BKScene(startupFile: false))
            }
            Divider()
            Text("Help links open the web; Blender Local works offline")
                .disabled(true)
        }
        .menuStyle(BlenderMenuStyle())
    }
}
