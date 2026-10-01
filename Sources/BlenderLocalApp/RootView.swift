import SwiftUI

/// The application shell: Blender's topbar, the current workspace, and the
/// status bar. The scene and the interpreter session are owned here so both
/// workspaces act on the same state — switching tabs never loses work.
struct RootView: View {
    @State private var scene = BKScene()
    @State private var session = BpySession(runtime: RootView.makeRuntime())
    @State private var camera = ViewportCamera()
    @State private var undo = UndoStack()
    /// Every interface action goes through here as Python. See BpyBridge:
    /// bpy owns the scene, and BKScene is the display cache it fills.
    @State private var bridge: BpyBridge?
    /// Keeps the scene on disk as the work happens. See `Autosave` for why the
    /// scene-phase hook on its own was not enough.
    @State private var autosave = Autosave(url: SceneDocument.autosaveURL)
    @State private var catalogue = OperatorCatalogue()
    @State private var showSearch = false
    @State private var showStatusBar = false
    @State private var workspace: Workspace = RootView.initialWorkspace
    @Environment(\.scenePhase) private var scenePhase

    /// Debug builds accept `-workspace Scripting` so a given tab can be brought
    /// up directly for screenshot verification, which the simulator's
    /// command-line tooling cannot do by tapping.
    static var initialWorkspace: Workspace {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-workspace"), i + 1 < args.count,
           let ws = Workspace(rawValue: args[i + 1]) {
            return ws
        }
        #endif
        return .layout
    }

    /// Debug builds accept `-eval64 <base64>` and run it once at launch, which
    /// is how the interpreter gets exercised end-to-end from the command line.
    /// Base64 so newlines and quotes survive the argument list intact.
    private func runLaunchScriptIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-eval64"), i + 1 < args.count,
              let data = Data(base64Encoded: args[i + 1]),
              let source = String(data: data, encoding: .utf8)
        else { return }
        // The script is already in the draft — `BlenderLocalApp.init` puts it
        // there, because by the time this runs the editor has read it.

        // Wait for the first frame before running.
        //
        // Pressing Run happens in an app that is already on screen; running at
        // launch happens in one that has not drawn yet. The difference matters
        // for anything that redraws *during* a run — live console output could
        // not be photographed at all here, because there was no laid-out UI to
        // redraw. A short delay makes the hook a fair stand-in for the button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            runLaunchScript(source, args: args)
        }
        #endif
    }

    /// Debug builds accept `-add <kind>` and `-adjust <key>=<value>` so the
    /// redo panel can be photographed from the command line.
    ///
    /// It goes through `perform` and `readjust` — the same two calls the Add
    /// menu and the panel's own sliders make. A hook that built the panel's
    /// state directly would photograph the panel without testing anything that
    /// puts it there, which is the failure mode the last three of these
    /// harnesses had.
    private func runLaunchOperatorIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // `-mesh <name>` performs a mesh operator through the same call the
        // menu makes, which is the only way to exercise that path without a
        // menu to tap.
        if let m = args.firstIndex(of: "-mesh"), m + 1 < args.count,
           let op = LastOperator.Mesh(rawValue: args[m + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let before = scene.active?.mesh.vertices.count ?? 0
                let outcome = bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location, symmetry: scene.active?.symmetry))
                let after = scene.active?.mesh.vertices.count ?? 0
                print("[bk] \(op.rawValue): succeeded=\(outcome?.succeeded ?? false) "
                      + "verts \(before) -> \(after) "
                      + "adjustable=\(bridge?.adjustable?.name ?? "no") "
                      + "error=\(outcome?.error ?? "none")")
                fflush(stdout)
            }
            return
        }
        // `-export <ext|all>` runs File ▸ Export's exporters the way the menu
        // runs them — on the main thread, where Blender has the window its
        // exporters poll for. A script thread does not, which is why the same
        // call from the console answers "context is incorrect".
        if let e = args.firstIndex(of: "-export"), e + 1 < args.count {
            let want = args[e + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for exporter in BpySession.exporters where want == "all" || want == exporter.ext {
                    let url = session.exportModel(exporter.op, ext: exporter.ext,
                                                  name: "hook-" + exporter.ext)
                    let size = url.flatMap {
                        try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int
                    } ?? 0
                    print("[bk] export \(exporter.ext): "
                          + (url == nil ? "FAILED" : "wrote \(size ?? 0) bytes"))
                    // And straight back in, through the call the Import Model…
                    // item makes: a format that writes but cannot be read is
                    // only half a feature.
                    guard let url, let op = BpySession.importers[exporter.ext] else { continue }
                    let before = scene.objects.count
                    let outcome = bridge?.run(BpySession.importPython(op, from: url.path),
                                              undo: "Import Model")
                    print("[bk] import \(exporter.ext): "
                          + (outcome?.succeeded == true && scene.objects.count > before
                             ? "read back, \(before) -> \(scene.objects.count) objects"
                             : "FAILED " + (outcome?.error ?? "nothing arrived")))
                }
                fflush(stdout)
            }
            return
        }
        guard let i = args.firstIndex(of: "-add"), i + 1 < args.count,
              let kind = PrimitiveKind(rawValue: args[i + 1]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let op = LastOperator.add(kind, at: scene.cursor)
            let outcome = bridge?.perform(op)
            // The failure is worth printing in full. When bpy cannot be
            // imported every operator fails with a NameError and the interface
            // simply does nothing, which from the outside is indistinguishable
            // from the feature under test being broken.
            if outcome?.succeeded == true {
                print("[bk] add: \(op.python)")
            } else {
                print("[bk] add FAILED: \(outcome?.error ?? "no bridge") — \(op.python)")
            }
            camera.frameAll(scene.objects)
            for (j, arg) in args.enumerated() where arg == "-adjust" && j + 1 < args.count {
                let parts = args[j + 1].split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let value = Double(parts[1]),
                      var op = bridge?.adjustable else { continue }
                op[String(parts[0])] = value
                if let updated = bridge?.readjust(op) {
                    print("[bk] adjusted: \(updated.python)")
                } else {
                    print("[bk] adjustment REJECTED: \(op.python)")
                }
            }
            print("[bk] scene: " + scene.objects
                .map { "\($0.name) \($0.mesh.vertices.count)v" }.joined(separator: ", "))
            // `-undo <n>` and then `-redo <n>`: the undo history end to end,
            // through the calls the top bar's buttons make, saying what each
            // step left on screen. With `-undo-checkpoints`, the fallback's.
            for (flag, step) in [("-undo", { session.performUndo() }), ("-redo", { session.performRedo() })] {
                guard let k = args.firstIndex(of: flag), k + 1 < args.count,
                      let count = Int(args[k + 1]) else { continue }
                for _ in 0..<count {
                    step()
                    print("[bk] \(flag.dropFirst()): " + scene.objects
                        .map { "\($0.name) \($0.mesh.vertices.count)v" }.joined(separator: ", ")
                        + " · undo \(session.backendCanUndo) redo \(session.backendCanRedo)"
                        + " · \(session.backendHistory.mode)")
                }
            }
            fflush(stdout)
        }
        #endif
    }

    /// Debug builds accept `-modifier-dump` and `-modifier-steps <steps>`: the
    /// Modifiers panel, driven from the command line on the active object.
    ///
    /// `-modifier-dump` prints the stack as the panel holds it — what the
    /// mirror brought back from Blender — once the scene is up. `-modifier-steps`
    /// then runs each comma-separated step and prints the stack after it: a
    /// step `Name:action` is one of the controls every row has
    /// (`viewport`, `render`, `up`, `down`, `apply`, `remove`, or a Multires
    /// operation — `subdivide`, `unsubdivide`, `deleteHigher`, `applyBase`),
    /// sent through `ModifierRowAction`, which is what the row's buttons call;
    /// a step `Name:key=value;key=value` is a settings edit by Blender's
    /// property names, sent through `Bpy.modifierEdit`, which is what the
    /// row's fields call; a step `+kind` (a `ModifierKind` raw value, e.g.
    /// `+weightedNormal`) is Add Modifier, through `Bpy.addModifier(_:on:)`
    /// as the Add Modifier menu sends it. A hook with its own Python would
    /// test nothing a button sends.
    ///
    /// Two steps set the object up as other controls would: `@mode=SCULPT`
    /// (any mode) is F3's Run on `object.mode_set` (`BlenderOperatorForm`),
    /// and `@hide=1` / `@hide=0` is the Object tab's Show in Viewports
    /// switch (`Bpy.setDisabledInViewports`) — the path round 3's review took
    /// to an object Blender will not take out of Sculpt Mode. Each step also
    /// prints the banner the interface would show.
    ///
    /// It waits for a `-eval64` script to finish first: `bridge.run` refuses
    /// while a script runs ("A script is running."), so a step sent during
    /// one would report a failure the panel never has.
    private func runModifierStepsIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let steps = args.firstIndex(of: "-modifier-steps")
            .flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        guard steps != nil || args.contains("-modifier-dump") else { return }
        func describe(_ m: Modifier) -> String {
            let settings = (Bpy.modifierSettings(m)).map { line -> String in
                guard let dot = line.range(of: "].") else { return line }
                return line[dot.upperBound...].replacingOccurrences(of: " = ", with: "=")
            }
            var extra: [String] = []
            if m.kind == .multires { extra.append("total_levels=\(m.totalLevels)") }
            if m.kind == .correctiveSmooth { extra.append("rest_source=\(m.restSource)") }
            return "\(m.name) [\(m.blenderType) \"\(m.typeLabel)\" \(m.kind.rawValue)] "
                + "viewport=\(m.showInViewport ? 1 : 0) render=\(m.showInRender ? 1 : 0)"
                + ((settings + extra).isEmpty ? "" : " " + (settings + extra).joined(separator: " "))
        }
        func dump(_ label: String) {
            guard let obj = scene.active else { print("[bk] modifiers \(label): no active object"); return }
            print("[bk] modifiers \(label) on \(obj.name), \(obj.mesh.vertices.count) verts, "
                  + "\(obj.modifiers.count) rows, \(scene.mode) mode:")
            for (i, m) in obj.modifiers.enumerated() { print("[bk]   \(i) \(describe(m))") }
        }
        func whenIdle(_ body: @escaping () -> Void) {
            guard !session.isRunning else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenIdle(body) }
                return
            }
            body()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { whenIdle {
            // What the Lattice row's picker and the Boolean and Shrinkwrap
            // pickers choose from: each object by the type the mirror gave it.
            print("[bk] objects: " + scene.objects.map { "\($0.name):\($0.blenderType)" }
                .joined(separator: " "))
            dump("at launch")
            func banner() -> String {
                bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none"
            }
            for step in (steps ?? "").split(separator: ",") {
                if step.hasPrefix("@mode="), let obj = scene.active {
                    let mode = String(step.dropFirst("@mode=".count))
                    let path = "object.mode_set"
                    // Undo named as F3 names it: the operator's own label.
                    let outcome = bridge?.run(BlenderOperatorForm.command(path: path, json: "{\"mode\":\"\(mode)\"}"),
                                              undo: "Set Object Mode")
                    print("[bk] step \(step): F3 \(path) on \(obj.name) "
                          + (outcome?.succeeded == true ? "succeeded" : "FAILED \(outcome?.error ?? "no bridge")")
                          + "; now \(scene.mode.bpyMode); banner: \(banner())")
                    continue
                }
                if step.hasPrefix("@hide="), let obj = scene.active {
                    let outcome = bridge?.run(Bpy.setDisabledInViewports(obj.name, step.hasSuffix("1")),
                                              undo: "Show in Viewports")
                    print("[bk] step \(step): Show in Viewports on \(obj.name) "
                          + (outcome?.succeeded == true ? "succeeded" : "FAILED \(outcome?.error ?? "no bridge")")
                          + "; disabled \(obj.disabledInViewports); banner: \(banner())")
                    continue
                }
                if step.hasPrefix("+") {
                    guard let obj = scene.active,
                          let kind = ModifierKind(rawValue: String(step.dropFirst())),
                          ModifierKind.addable.contains(kind) else {
                        print("[bk] step \(step): no active object, or not a kind Add Modifier offers")
                        continue
                    }
                    let outcome = bridge?.run(Bpy.addModifier(kind, on: obj.mesh), undo: "Add Modifier")
                    print("[bk] step \(step): Add Modifier "
                          + (outcome?.succeeded == true ? "succeeded" : "FAILED \(outcome?.error ?? "no bridge")"))
                    dump("after \(step)")
                    continue
                }
                guard let colon = step.firstIndex(of: ":"), let obj = scene.active else { continue }
                let name = String(step[step.startIndex..<colon])
                let rest = step[step.index(after: colon)...]
                guard let modifier = obj.modifiers.first(where: { $0.name == name }) else {
                    print("[bk] step \(step): no modifier \(name) in the panel")
                    continue
                }
                let command: (lines: [String], undo: String)?
                if rest.contains("=") {
                    var changed = modifier
                    changed.read(Modifier.fields(rest))
                    command = (Bpy.modifierEdit(from: modifier, to: changed), "Edit Modifier")
                } else if let action = ModifierRowAction(hookName: String(rest)) {
                    command = action.command(for: modifier, in: obj.modifiers)
                } else {
                    print("[bk] step \(step): unknown action")
                    continue
                }
                guard let command, !command.lines.isEmpty else {
                    print("[bk] step \(step): the row sends nothing")
                    continue
                }
                let outcome = bridge?.run(command.lines, undo: command.undo)
                print("[bk] step \(step): \(command.undo) "
                      + (outcome?.succeeded == true ? "succeeded" : "FAILED \(outcome?.error ?? "no bridge")")
                      + " — " + command.lines.joined(separator: " / ").replacingOccurrences(of: "\n", with: " ⏎ ")
                      + (outcome?.succeeded == true ? "" : "; banner: \(banner())"))
                dump("after \(step)")
            }
            print("[bk] modifier steps done")
            fflush(stdout)
        } }
        #endif
    }

    /// Debug builds accept `-opsearch <path>` (arguments as JSON in
    /// `-opsearch-args`), `-uv-row <UVOperator>` and `-dump-state`, each run
    /// once a `-eval64` script has finished.
    ///
    /// `-opsearch` reads the operator's form (`BlenderOperatorForm.infoCall`)
    /// and presses its Run (`BlenderOperatorForm.command`, through
    /// `bridge.run`, as the button does); `-uv-row` runs a UV menu row as the
    /// menu does (`Bpy.uv`). Each prints the outcome and the report the banner
    /// would show. `-dump-state` prints the mirrored tool switches and what the
    /// UV Editor would draw for the active object, before and after.
    private func runProbesIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let opsearch = value("-opsearch"), uvRow = value("-uv-row")
        guard opsearch != nil || uvRow != nil || args.contains("-dump-state") else { return }
        func whenIdle(_ body: @escaping () -> Void) {
            guard !session.isRunning else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenIdle(body) }
                return
            }
            body()
        }
        func dump(_ label: String) {
            let t = scene.tools
            print("[bk] state \(label): \(scene.mode.bpyMode) mode; automerge \(t.autoMerge) split \(t.autoMergeSplit), "
                  + "affect only parents \(t.affectOnlyParents) origins \(t.affectOnlyOrigins)")
            guard let obj = scene.active else { print("[bk] state \(label): no active object"); return }
            let map = obj.uvLayout ?? obj.mesh
            let lines = map.uvEditorLines()
            print("[bk] state \(label): \(obj.name) drawn with \(obj.mesh.vertices.count) verts, "
                  + "\(obj.mesh.indices.count) corners, UVs \(obj.mesh.hasUVs); the UV Editor draws "
                  + (obj.uvLayout == nil ? "the drawn mesh's map" : "the map before the modifiers")
                  + " '\(map.uvMapName)', \(map.indices.count) corners, \(lines.edges.count + lines.seams.count) polygon sides")
        }
        func said(_ outcome: BpyBridge.Outcome?) -> String {
            (outcome?.succeeded == true ? "succeeded" : "FAILED: \(outcome?.error ?? "no bridge")")
                + "; banner: \(bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none")"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { whenIdle {
            dump("before")
            if let path = opsearch {
                let json = value("-opsearch-args") ?? "{}"
                if let info = BlenderRNAInfo.read(BlenderOperatorForm.infoCall(path: path), bridge: bridge) {
                    print("[bk] opsearch form for \(path): available \(info.available), runs in "
                          + "\(info.mode ?? "the mode Blender is in") (now \(info.currentMode ?? "?")), "
                          + "refused: \(info.refused ?? "no")")
                } else {
                    print("[bk] opsearch form for \(path): could not be read")
                }
                let outcome = bridge?.run(BlenderOperatorForm.command(path: path, json: json), undo: path)
                print("[bk] opsearch Run \(path) \(json): \(said(outcome)); now in \(scene.mode.bpyMode) mode")
            }
            if let name = uvRow {
                if let op = UVOperator(rawValue: name) {
                    let outcome = bridge?.run(Bpy.uv(op), undo: op.label)
                    print("[bk] uv row \(op.label): \(said(outcome)); now in \(scene.mode.bpyMode) mode")
                } else {
                    print("[bk] uv row \(name): no such row")
                }
            }
            dump("after")
            print("[bk] probes done")
            fflush(stdout)
        } }
        #endif
    }

    /// Debug builds accept `-image3d <path>`: Add ▸ Image to 3D Model on that
    /// picture, through the same prepare and create the sheet calls, printing
    /// where the shape came from and what was built. `-image3d-mode relief`
    /// makes a relief instead of full 3D; `-image3d-whole` turns the cut-out
    /// off; `-image3d-detail low|medium|high`.
    private func runImageToModelIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-image3d"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let cutOut = !args.contains("-image3d-whole")
        let relief = args.firstIndex(of: "-image3d-mode").map { $0 + 1 < args.count && args[$0 + 1] == "relief" } ?? false
        let detail = args.firstIndex(of: "-image3d-detail").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "medium"
        let faces = ["low": 20_000, "medium": 50_000, "high": 100_000][detail] ?? 50_000
        let cells = ["low": 48, "medium": 96, "high": 160][detail] ?? 96
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                defer { fflush(stdout) }
                guard let bridge else { print("[bk] image3d FAILED: no bridge"); return }
                let started = Date()
                do {
                    let prepared = try await ImageToModelImport.prepare(
                        data: try Data(contentsOf: url), fileName: url.lastPathComponent)
                    let made: ImageToModelImport.Made
                    if relief {
                        made = try await ImageToModelImport.createRelief(
                            prepared, cutOut: cutOut, options: .init(detail: cells),
                            bridge: bridge, session: session, scene: scene)
                    } else {
                        made = try await ImageToModelImport.createFull(
                            prepared, cutOut: cutOut, resolution: detail == "low" ? 128 : 256, faces: faces,
                            textureSize: detail == "high" ? 2048 : 1024, seed: 42,
                            bridge: bridge, session: session, scene: scene) { stage in
                                print("[bk] image3d stage: \(stage)"); fflush(stdout)
                            }
                    }
                    let mesh = scene.active?.mesh
                    print("[bk] image3d: mode=\(relief ? "relief" : "full") object=\(made.name) source=\(made.source) "
                          + "image=\(prepared.image.width)x\(prepared.image.height) "
                          + "verts=\(mesh?.vertices.count ?? 0) tris=\((mesh?.indices.count ?? 0) / 3) "
                          + String(format: "total=%.1fs ", Date().timeIntervalSince(started)) + "(\(made.detail))")
                } catch {
                    print("[bk] image3d FAILED: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }

    private func runLaunchScript(_ source: String, args: [String]) {
        let before = session.console.count
        // The same entry point the Run button uses, so the launch path
        // exercises what a user actually presses rather than a second route
        // with its own echoing and error handling.
        session.runScript(source, scene: scene)
        // Frame the result, as pressing Run does. Without this the launch path
        // exercises the interpreter but not what the user actually sees.
        if camera.framesPoorly(scene.objects) {
            camera.frameAll(scene.objects)
        }

        // `-render` renders once at launch, which is how the Rendering
        // workspace gets exercised from the command line.
        if args.contains("-render"),
           let bytes = OfflineRenderer.render(scene: scene, camera: camera,
                                              width: 1280, height: 720) {
            let image = TextureImage(width: 1280, height: 720, name: "Render Result")
            image.replace(with: bytes)
            scene.renderResult = image
            scene.renderVersion &+= 1
            print("[bk] rendered 1280x720")
        }
        // Echo to stdout as well, so `devicectl process launch --console`
        // shows the result — the in-app console is not the process's stdout.
        //
        // After the run finishes, not straight away: a script now runs on its
        // own thread and `runScript` returns immediately, so printing here
        // showed the header and nothing else. That looked exactly like a
        // deadlock, and I spent a while sampling the process for one before
        // noticing the app's own console had the whole output.
        func echoWhenDone() {
            guard !session.isRunning else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: echoWhenDone)
                return
            }
            for line in session.console.dropFirst(before) {
                print("[bk] \(line.text)")
            }
            fflush(stdout)
        }
        echoWhenDone()
    }

    /// Real CPython, embedded from the copy staged into the app bundle. If it
    /// cannot start, the console falls back to the command subset and says so
    /// rather than appearing to work.
    static func makeRuntime() -> BpyRuntime {
        #if DEBUG
        // `-stub` forces the command subset. The simulator's Python is staged
        // without its standard library, so `import bpy` fails there and every
        // operator NameErrors — which makes the whole interface unexercisable
        // on the one machine that can be photographed from a script. The subset
        // does not need Python at all.
        if ProcessInfo.processInfo.arguments.contains("-stub") {
            return StubBpyRuntime(fallbackReason: "-stub was passed on the command line")
        }
        #endif
        do {
            return try EmbeddedBpyRuntime()
        } catch {
            return StubBpyRuntime(fallbackReason: "\(error)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(workspace: $workspace, scene: scene, session: session,
                   undo: undo, showStatusBar: $showStatusBar, renderCamera: camera,
                   catalogue: catalogue, bridge: bridge, showSearch: $showSearch)

            switch workspace {
            case .layout:
                LayoutWorkspace(scene: scene, session: session, undo: undo, bridge: bridge, camera: $camera,
                                searchOpen: showSearch)
            case .scripting:
                ScriptingWorkspace(scene: scene, session: session, bridge: bridge,
                                   camera: $camera, catalogue: catalogue)
            case .shading:
                ShadingWorkspace(scene: scene, session: session, bridge: bridge, camera: $camera)
            case .uvEditing:
                UVEditingWorkspace(scene: scene, session: session, bridge: bridge, camera: $camera)
            case .rendering:
                RenderingWorkspace(scene: scene, session: session, bridge: bridge, camera: $camera)
            case .compositing:
                CompositingWorkspace(scene: scene, session: session)
            case .geometryNodes:
                GeometryNodesWorkspace(scene: scene, session: session, camera: $camera)
            case .modeling, .sculpting, .uvEditing, .texturePaint,
                 .compositing, .geometryNodes, .animation:
                // Blender's Modeling and Sculpting workspaces are the Layout
                // arrangement in a different mode and without the timeline.
                LayoutWorkspace(scene: scene, session: session, undo: undo, bridge: bridge,
                                camera: $camera, timeline: false, searchOpen: showSearch)
            case .animation:
                // Animation keeps the timeline; that is the point of it.
                LayoutWorkspace(scene: scene, session: session, undo: undo, bridge: bridge, camera: $camera,
                                searchOpen: showSearch)
            default:
                // The other nine tabs are disabled in the topbar, so this is
                // unreachable; Layout is the safe landing if it is ever hit.
                LayoutWorkspace(scene: scene, session: session, undo: undo, bridge: bridge, camera: $camera,
                                searchOpen: showSearch)
            }

            if showStatusBar {
                StatusBar(scene: scene, workspace: workspace, session: session)
            }
        }
        .background(BTheme.topbar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // ⌘1 and ⌘2 for the tabs, ⇧⌘P for the operator search — the commands
        // that exist whichever tab is showing.
        .focusedSceneValue(\.appKeys, AppKeyActions(
            workspace: workspace,
            searchVisible: showSearch,
            showWorkspace: { workspace = $0 },
            searchOperators: { showSearch = true }))
        .overlay {
            if showSearch {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { showSearch = false }
                    OperatorSearch(catalogue: catalogue, bridge: bridge,
                                   isPresented: $showSearch)
                }
            }
        }
        .onAppear {
            // Restore whatever was on screen when the app was last closed,
            // then bind undo so the first operator is undoable.
            if !session.usesRealBlender { try? SceneDocument.read(SceneDocument.autosaveURL, into: scene) }
            session.bind(scene: scene, undo: undo)
            // From here on the scene keeps itself on disk as it changes, rather
            // than only when the app is put away.
            session.autosave = autosave
            bridge = BpyBridge(session: session, scene: scene, undo: undo)
            if session.usesRealBlender {
                let recovery = SceneDocument.documentsURL.appendingPathComponent("autosave.blend")
                if FileManager.default.fileExists(atPath: recovery.path) {
                    // Read recovery before the first checkpoint replaces it.
                    _ = session.evaluate("bpy.ops.wm.open_mainfile(filepath=\(Bpy.quote(recovery.path)), load_ui=False)", scene: scene)
                }
            }
            runLaunchScriptIfRequested()
            runLaunchOperatorIfRequested()
            runImageToModelIfRequested()
            runModifierStepsIfRequested()
            runProbesIfRequested()
            #if DEBUG
            // `-timeline` opens the docked Timeline at launch. It is shown from
            // the More menu, which the simulator's command line cannot tap.
            if ProcessInfo.processInfo.arguments.contains("-timeline") {
                scene.animation.showsTimeline = true
            }
            FocusLog.startIfRequested()
            #endif
        }
        .onChange(of: workspace) { _, ws in
            // Blender's workspaces each carry an object_mode and switch into it.
            switch ws {
            case .uvEditing: if scene.active != nil { scene.setMode(.edit) }
            case .sculpting:            if scene.active != nil { scene.setMode(.sculpt) }
            case .texturePaint: if scene.active != nil { scene.setMode(.texturePaint) }
            case .shading, .animation, .rendering,
                 .compositing, .geometryNodes:
                scene.setMode(.object)
            case .layout, .modeling, .scripting:
                // The merged 3D View keeps whatever mode you were in. Forcing
                // object mode here would undo a mode switch every time the tab
                // regained focus. Scripting keeps it too: Blender is still in
                // that mode, and saying otherwise here left the interface and
                // Blender disagreeing until the next command. A script that
                // needs object mode is put there when it runs.
                break
            default: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Going away is the one moment worth not waiting two seconds for.
            guard phase != .active else { return }
            if session.usesRealBlender { session.flushBackendAutosave() }
            else { autosave.flush(scene) }
        }
    }
}
