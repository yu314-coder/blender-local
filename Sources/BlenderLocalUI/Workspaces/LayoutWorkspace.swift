import SwiftUI
import simd

/// A viewport-first workspace. Detailed tools are presented only on request.
struct LayoutWorkspace: View {
    var scene: BKScene
    var session: BpySession
    var undo: UndoStack
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera
    var timeline: Bool = false
    /// The operator search is open over the whole window. Its field is where
    /// the keyboard's letters go, so the 3D View's keys stand down.
    var searchOpen: Bool = false
    @State private var tool: ActiveTool = .select
    @State private var shading: ViewportShading = .solid
    @State private var options = ViewportOptions()
    /// Circle select's radius in view points, Blender's tool setting
    /// (default 25). The drag draws with it and selects with it.
    @State private var circleRadius: CGFloat = 25
    /// What a Box, Circle or Lasso drag does without Shift or Ctrl — Blender's
    /// tool-header mode buttons, here in the Select tool menu, so a touch-only
    /// iPad can extend, subtract or intersect too.
    @State private var regionAction: SelectAction = .set
    /// Select ▸ Select Pattern…, asking for the pattern.
    @State private var askingPattern = false
    @State private var pattern = "*"
    @State private var panel: String?
    /// Set by Look Through Camera: the frame the render will take, and the
    /// view it was set from. The guide is drawn while the view has not moved.
    @State private var cameraView: (aspect: CGFloat, camera: ViewportCamera, name: String)?
    @State private var showOperations = false
    @State private var catalogue = OperatorCatalogue()
    /// The failure on screen, until it times out or is tapped away.
    @State private var shownReport: BpyBridge.Report?

    /// Picks a tool, and takes the view to the mode it needs.
    ///
    /// The reader never picks a mode. A sculpt brush can only mean sculpting,
    /// so choosing one says so; and choosing Select, Box or a transform after a
    /// brush can only mean leaving it, which is Blender's Object Mode. Before
    /// that second half, Move lit up after a brush while every drag still
    /// pushed the mesh around.
    ///
    /// Painting is the app's own mode, deliberately *not* Blender's: the brush
    /// works on the display cache and each finished stroke is written into
    /// Blender's mesh, while Blender stays in object mode.
    ///
    /// Sculpt Mode, with the real Blender, is Blender's own: its brushes,
    /// dynamic topology, masks and Multires work on the mesh in Blender's
    /// Sculpt Mode (`_blenderkit_sculpt`), so choosing a sculpt tool runs
    /// `mode_set(mode='SCULPT')` as an undo step, and leaving runs it back.
    /// The reason it used to stay out — measured in 5.2.1, in Blender's sculpt
    /// mode `object.select_all`, `object.delete`, `mesh.bevel` and
    /// `mesh.subdivide` fail their poll and `primitive_cube_add` crashes the
    /// process — is handled where those are sent: `BpyModeGuard` and
    /// `LastOperator.entryPython` run them in the mode they need and put the
    /// mode back. On the simulator's stand-in the Swift brushes still sculpt
    /// the display cache, as an approximation.
    private func choose(_ t: ActiveTool) {
        // While a sculpt stroke is down the tool and the mode wait for its
        // lift, as Blender's do under its modal brush: a mode left under the
        // finger used to leave the stroke open (BpySession.sculptStrokeOpen).
        if let held = session.gestureHold {
            bridge?.showReport(t.label, held)
            return
        }
        if let next = t.mode(whenChosenFrom: scene.mode) {
            if next == .sculpt, session.usesRealBlender {
                bridge?.run(SculptBpy.enter, undo: SculptBpy.modeUndo)
            } else if next.isBrushMode {
                // Out of Blender's edit mode first, as its own Sculpt Mode
                // leaves it. Out of its Sculpt Mode too, for a paint mode.
                if editing { bridge?.run(Bpy.setMode(.object), undo: "Toggle Edit Mode") }
                if scene.mode == .sculpt, session.usesRealBlender {
                    bridge?.run(SculptBpy.leave, undo: SculptBpy.modeUndo)
                }
                scene.setMode(next)
            } else if scene.mode == .sculpt, session.usesRealBlender {
                bridge?.run(SculptBpy.leave, undo: SculptBpy.modeUndo)
            } else {
                scene.setMode(next)
                // A sculpt or paint mode Blender is really in — a script put
                // it there — has to end too, or the mirror would bring it back.
                if session.isRealRuntime { bridge?.run(Bpy.leaveBrushMode, quiet: true) }
            }
        }
        if let brush = t.sculptBrush { scene.sculpt.brush = brush }
        // A sculpt tool that could not take Blender into Sculpt Mode leaves
        // the tool where it was: the drag would otherwise orbit under a lit
        // brush button.
        if t.requiredMode == .sculpt, session.usesRealBlender, scene.mode != .sculpt { return }
        tool = t
    }

    /// Editing a mesh is the one state that changes what every tool acts on —
    /// vertices instead of objects — so it is the one state the bar spells
    /// out.
    ///
    /// It is Blender's mode, not the interface's: the mirror reports it after
    /// every command. It used to be set only by the simulator's shim, so on a
    /// device Edit Mesh put Blender into edit mode and this never noticed —
    /// no chip, no Bevel, and no Done to get back out.
    private var editing: Bool { scene.mode == .edit }

    /// Whether Edit Mesh would mean anything right now.
    ///
    /// A light or a camera has no edit mode, and pressing it with one active
    /// used to send Blender `mode_set(mode='EDIT')` and show what came back:
    /// `enum "EDIT" not found in ('OBJECT')`, which says nothing about the Sun
    /// that was selected.
    private var canEdit: Bool { scene.active?.hasEditMode == true }

    /// Whether the active object is a curve or a lattice, whose Edit Mode is
    /// its control points (ControlPoints.swift) rather than a mesh's.
    private var canEditPoints: Bool { scene.active?.editsPoints == true }

    /// Editing a curve's or a lattice's points: the mesh tools stand down and
    /// the Curve or Lattice menu takes their place.
    private var editingPoints: Bool { editing && canEditPoints }

    /// The active object is a lattice, in its Edit Mode or not.
    private var activeIsLattice: Bool { scene.active?.blenderType == "LATTICE" }

    /// Runs a Curve or Lattice menu row, a CANCELLED said in words.
    private func runPoints(_ command: PointsBpy.Command) {
        guard let bridge, !session.isRunning else { return }
        bridge.run(command.python, undo: command.undo, executing: command.executed)
    }

    /// Select All, None or Invert, by what is being edited.
    private func selectAllCommand(_ action: String) -> String {
        if editingPoints { return PointsBpy.selectAll(action, lattice: activeIsLattice) }
        switch action {
        case "SELECT": return Bpy.selectAll(editing: editing)
        case "DESELECT": return Bpy.deselectAll(editing: editing)
        default: return Bpy.invertSelection(editing: editing)
        }
    }

    /// Edit Mesh and Done: into and out of Blender's edit mode.
    private func setEditing(_ on: Bool) {
        bridge?.run(Bpy.setMode(on ? .edit : .object), undo: "Toggle Edit Mode")
    }

    /// Tab: toggles by Blender's own mode, read when the key is pressed.
    private func toggleEditing() {
        bridge?.run(Bpy.toggleEditMode, undo: "Toggle Edit Mode")
    }

    /// Vertex, edge or face: Blender's header buttons, and 1, 2, 3.
    private func setSelectMode(_ mode: MeshSelectMode) {
        guard mode != scene.selectMode else { return }
        // Only Blender's own mesh has a select mode to set. The simulator's
        // shim reads the interface's.
        if session.usesRealBlender {
            bridge?.run(Bpy.setSelectMode(mode))
        }
        scene.selectMode = mode
    }

    /// Whether the tool in hand is a sculpt or paint brush, which the Sculpt
    /// button then shows: picking one changes what a drag does, and nothing
    /// else on screen said so.
    private var brushActive: Bool { tool.isBrush }

    /// Whether the 3D View's keys may act: nothing covers the view, and
    /// nothing is being typed into.
    private var keysLive: Bool {
        panel == nil && !showOperations && !searchOpen && !TextEntryFocus.shared.isEditing
    }

    var body: some View {
        VStack(spacing: 0) {
            toolRow

            ZStack(alignment: .topTrailing) {
                MetalViewportView(scene: scene, camera: $camera, tool: tool,
                                  shading: shading, options: options,
                                  circleRadius: circleRadius,
                                  regionAction: regionAction, bridge: bridge,
                                  onSelectionChange: { _ in },
                                  onTransform: { session.log($0) },
                                  onCommit: { name in if !session.usesRealBlender { undo.push(name, scene) } },
                                  onCycleTool: { choose(tool.next) },
                                  onToggleEditing: keysLive ? toggleEditingFromKeyboard : nil,
                                  onStrokeEnd: keepStroke)
                // The rectangle a box-select drag is sweeping. Screen-space
                // and changing every frame, so it is drawn here rather than in
                // the renderer's 3D pass.
                if let box = scene.selectionBox, box.width > 1, box.height > 1 {
                    GeometryReader { _ in
                        Rectangle()
                            .fill(BTheme.select.opacity(0.14))
                            .overlay(Rectangle().strokeBorder(BTheme.select, lineWidth: 1))
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                    }
                    .allowsHitTesting(false)
                }
                // A Circle select's painted stroke or a Lasso's outline, from
                // the region the selection is then made from.
                if let stroke = scene.selectionStroke {
                    SelectionStrokeOverlay(region: stroke)
                        .allowsHitTesting(false)
                }

                // What the render will take in, while the view stands where
                // Look Through Camera put it. A viewport is rarely the frame's
                // shape, so without this the view shows more than the picture
                // will.
                if let cameraView, camera.stillAt(cameraView.camera) {
                    GeometryReader { geometry in
                        let size = geometry.size
                        let fitted = size.width / size.height > cameraView.aspect
                            ? CGSize(width: size.height * cameraView.aspect * 0.94, height: size.height * 0.94)
                            : CGSize(width: size.width * 0.94, height: size.width / cameraView.aspect * 0.94)
                        ZStack {
                            // Blender's passepartout: everything outside the
                            // frame dimmed, the frame itself untouched.
                            Rectangle().fill(Color.black.opacity(0.35))
                                .mask {
                                    ZStack {
                                        Rectangle()
                                        Rectangle()
                                            .frame(width: fitted.width, height: fitted.height)
                                            .blendMode(.destinationOut)
                                    }
                                    .compositingGroup()
                                }
                            Rectangle()
                                .strokeBorder(BTheme.active.opacity(0.9), lineWidth: 1)
                                .frame(width: fitted.width, height: fitted.height)
                            Text(cameraView.name)
                                .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.active)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(BTheme.header.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .position(x: size.width / 2,
                                          y: (size.height - fitted.height) / 2 - 10)
                        }
                        .frame(width: size.width, height: size.height)
                    }
                    .allowsHitTesting(false)
                }

                // Adjust Last Operation. It costs nothing until something has
                // run, and without it every operator is a guess you have to
                // undo to correct — which is most of what a modelling session
                // is.
                VStack {
                    Spacer()
                    HStack {
                        AdjustLastOperation(bridge: bridge)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 64)

                Button { camera.frameAll(scene.objects) } label: {
                    Image(systemName: "viewfinder").frame(width: 44, height: 44)
                        .background(BTheme.header.opacity(0.9)).clipShape(Circle())
                }.padding(14).accessibilityLabel("Frame All")
                VStack {
                    Spacer()
                    HStack {
                        Text(scene.active?.name ?? "Tap an object to select it")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let readout = scene.dragReadout { Text(readout).font(.system(size: 12, design: .monospaced)) }
                    }.padding(14).background(BTheme.header.opacity(0.9))
                }.allowsHitTesting(false)

                if let report = shownReport {
                    reportBanner(report)
                }
            }.foregroundStyle(BTheme.text)
            AnimationDock(scene: scene, session: session, bridge: bridge)
        }
        .sheet(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
            NavigationStack {
                Group {
                    switch panel {
                    case "Scene": OutlinerView(scene: scene, session: session, bridge: bridge)
                    case "Object Details":
                        // A camera or a light has no mesh to show, and until
                        // now had no settings either: the sheet went straight
                        // to the RNA browser, where `energy` is a row of JSON.
                        if let object = scene.active, object.overlayDisplay != nil {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    CameraLightPanel(scene: scene, session: session, bridge: bridge,
                                                     object: object, camera: $camera,
                                                     lookThrough: { lookThroughCamera(object) })
                                    if session.usesRealBlender {
                                        NavigationLink("Every Property") {
                                            BlenderDataBrowser(bridge: bridge, startPath: "bpy.context.object",
                                                               revision: session.backendRevision)
                                        }
                                        .font(BTheme.Font.ui(12))
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                    }
                                }
                            }
                        } else if scene.active != nil {
                            // A mesh got the RNA browser and nothing else, on
                            // exactly the backend where it matters: no
                            // Transform fields, no modifier stack, no material
                            // — so a part could not be placed at a number, only
                            // dragged. The Properties editor is what Blender
                            // shows here, and the browser stays one tap away,
                            // the way the camera and light panel already does.
                            VStack(spacing: 0) {
                                PropertiesView(scene: scene, session: session, bridge: bridge)
                                if session.usesRealBlender {
                                    BEditorDivider(.horizontal)
                                    NavigationLink("Every Property") {
                                        BlenderDataBrowser(bridge: bridge, startPath: "bpy.context.object",
                                                           revision: session.backendRevision)
                                    }
                                    .font(BTheme.Font.ui(12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                }
                            }
                        } else if session.usesRealBlender {
                            BlenderDataBrowser(bridge: bridge, startPath: "bpy.context.object", revision: session.backendRevision)
                        } else { PropertiesView(scene: scene, session: session, bridge: bridge) }
                    case "Transform Tools":
                        TransformToolsPanel(scene: scene, bridge: bridge,
                                            increment: $options.snapIncrement)
                    case "Animation": TimelineView(scene: scene, session: session)
                    case "Render": RenderingWorkspace(scene: scene, session: session, bridge: bridge, camera: $camera)
                    case "Image to 3D Model":
                        ImageToModelSheet(scene: scene, session: session, bridge: bridge) { panel = nil }
                    default: EmptyView()
                    }
                }
                .navigationTitle(panel ?? "Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
            }
            // A picture wants the room: half a sheet showed a 1920 × 1080
            // render as a thumbnail. The panels that are lists still open
            // half-height, where the viewport stays in view behind them.
            .presentationDetents(panel == "Render" || panel == "Image to 3D Model"
                                 ? [.large] : [.medium, .large])
        }
        // A model made from a picture is its texture: show it in Material
        // Preview, framed, rather than as a grey lump in Solid.
        .onReceive(NotificationCenter.default.publisher(for: ImageToModelImport.didCreate)) { _ in
            shading = .material
            _ = camera.frameSelected(in: scene)
        }
        // Whether Shade Auto Smooth can run here at all, asked of Blender
        // once; again after a script, if one was running when it was asked.
        .task(id: session.isRunning) { session.probeEssentialsLibrary() }
        #if DEBUG
        // `-panel <name>` opens one of the More menu's panels at launch, so a
        // panel can be photographed without tapping through a menu.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-panel"), i + 1 < args.count { panel = args[i + 1] }
        }
        // `-sculpt-enter` picks Sculpt from the Sculpt menu (`choose`) once a
        // `-eval64` script has finished: Blender's Sculpt Mode on the active
        // object, the way a tap does. `-sculpt-stroke` (MetalViewportView)
        // then strokes it.
        // Keyed on the bridge: a task keeps the view it started with, and the
        // bridge arrives after the first one.
        .task(id: bridge == nil) {
            guard ProcessInfo.processInfo.arguments.contains("-sculpt-enter"), bridge != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            choose(.sculptDraw)
            print("[bk] sculpt-enter: Blender in \(scene.mode.bpyMode) on \(scene.active?.name ?? "nothing"); "
                  + "banner: \(bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none")")
            fflush(stdout)
        }
        // `-xray` turns on X-Ray, as View Style ▸ X-Ray does.
        .task { if ProcessInfo.processInfo.arguments.contains("-xray") { options.xray = true } }
        // `-region-action intersect` picks the select tools' mode, as the
        // Select tool menu's Mode rows do.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-region-action"), i + 1 < args.count,
               let mode = SelectAction(rawValue: args[i + 1]) {
                regionAction = mode
            }
        }
        // `-select-menu a,b,…` presses Select menu rows (`SelectMenu.Command(token:)`)
        // through `select`, the call the rows make, once a `-eval64` script
        // (and any `-region-select`) has finished, and prints what Blender
        // holds after each, read back from Blender, beside what the viewport
        // shows.
        .task(id: bridge == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-select-menu"), i + 1 < args.count, bridge != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64((Double(args.firstIndex(of: "-select-menu-delay")
                .flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 3)) * 1e9))
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            for token in args[i + 1].split(separator: ",").map(String.init) {
                // `adjust:key=value` moves a field of the redo panel, through
                // `readjust`, the call the panel's own fields make.
                if token.hasPrefix("adjust:") {
                    let pair = token.dropFirst("adjust:".count).split(separator: "=").map(String.init)
                    let before = selectionSummary()
                    var result = "no adjustable operator"
                    if pair.count == 2, let v = Double(pair[1]), var op = bridge?.adjustable {
                        op[pair[0]] = v
                        result = bridge?.readjust(op).map { "re-ran \($0.python)" } ?? "REFUSED"
                    }
                    print("[bk] select-menu \(token): \(result); \(before.blender) -> \(selectionSummary().blender) "
                          + "in Blender; the viewport shows \(selectionSummary().shown)")
                    fflush(stdout)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                guard let command = SelectMenu.Command(token: token) else {
                    print("[bk] select-menu \(token): no such row"); continue
                }
                let before = selectionSummary()
                bridge?.dismissReport(bridge?.report?.id ?? -1)
                select(command)
                // The redo panel's fields as it displays them.
                let fields = bridge?.adjustable.map { op in
                    " [" + op.parameters.map { "\($0.label) \($0.display)" }.joined(separator: ", ") + "]"
                } ?? ""
                print("[bk] select-menu \(token): \(before.blender) -> \(selectionSummary().blender) in Blender; "
                      + "the viewport shows \(selectionSummary().shown); adjustable: \(bridge?.adjustable?.name ?? "no")"
                      + "\(fields); banner: \(bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none")")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            print("[bk] select-menu: done"); fflush(stdout)
        }
        // `-object-ops a,b,…` presses Object and Mesh menu rows through the
        // calls the rows make, once a `-eval64` script has finished, and
        // prints after each what Blender holds — every object's type, parent
        // and vertex count, read from Blender — beside what the app shows:
        // the mirror's objects and the Outliner's tree. Tokens: `select:A+B`
        // (the Outliner's tap, then a tap adding each further name — the last
        // is active), `edit` and `object` (Edit Mesh and Done), `all` (A),
        // `none` (Alt+A),
        // `dup` (Duplicate, Shift+D: elements in Edit Mode), `dup-linked`, `join`, `parent`, `parent-keep`, `clear`,
        // `clear-keep`, `clear-inverse`, `convert-mesh`, `convert-curve`,
        // `mesh:<LastOperator.Mesh>`, `shear`, `adjust:key=value` (the redo
        // panel), `undo`, `redo`, and `field:<location|rotation|scale>:<axis>=
        // <value>` (a Transform field of the active object).
        .task(id: bridge == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-object-ops"), i + 1 < args.count, bridge != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            for token in args[i + 1].split(separator: ",").map(String.init) {
                bridge?.dismissReport(bridge?.report?.id ?? -1)
                let started = Date()
                var said = ""
                switch token {
                case _ where token.hasPrefix("select:"):
                    let names = token.dropFirst("select:".count).split(separator: "+").map(String.init)
                    for (k, name) in names.enumerated() { bridge?.select(Bpy.select(name, only: k == 0)) }
                case "edit":   setEditing(true)
                case "object": setEditing(false)
                case "all":    bridge?.run(Bpy.selectAll(editing: editing), undo: "Select All")
                case "none":   bridge?.run(Bpy.deselectAll(editing: editing), undo: "Deselect")
                case "dup":           duplicateSelected()
                case "dup-linked":    performObjectRow(.duplicateLinked())
                case "join":          performObjectRow(.join())
                case "parent":        performObjectRow(.parent(keepTransform: false))
                case "parent-keep":   performObjectRow(.parent(keepTransform: true))
                case "clear":         performObjectRow(.clearParent(.clear))
                case "clear-keep":    performObjectRow(.clearParent(.keepTransform))
                case "clear-inverse": performObjectRow(.clearParent(.inverse))
                case "convert-mesh":  performObjectRow(.convert(to: .mesh))
                case "convert-curve": performObjectRow(.convert(to: .curve))
                case "shear":         bridge?.perform(editing ? LastOperator.shear() : LastOperator.shearObjects())
                case _ where token.hasPrefix("field:"):
                    // `field:<location|rotation|scale>:<axis>=<value>`: one
                    // Transform field of the active object, through the calls
                    // the field makes (`TransformFieldEdit`, then
                    // `commitTransformField`), the preview printed beside where
                    // Blender then put the object and its children.
                    let spec = token.dropFirst("field:".count).split(separator: "=").map(String.init)
                    let path = spec.first?.split(separator: ":").map(String.init) ?? []
                    guard spec.count == 2, path.count == 2, let value = Float(spec[1]), let axis = Int(path[1]),
                          let group = TransformChannels.Group.allCases.first(where: { $0.title.lowercased() == path[0] }),
                          let obj = scene.active, var edit = TransformFieldEdit(object: obj, scene: scene) else {
                        said = "no field edit: no active object, no channels for it, or a malformed token"
                        break
                    }
                    let shown = edit.start.values(group).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                    edit.change(group, axis: axis, to: value)
                    let moving = [obj] + scene.carried(by: [obj.id]).map(\.object)
                    let previewed = moving.map { ($0, $0.modelMatrix.columns.3) }
                    let outcome = bridge?.commitTransformField(edit, group: group)
                    let worst = previewed.map { simd_distance($0.0.modelMatrix.columns.3, $0.1) }.max() ?? 0
                    let after = obj.shownChannels?.values(group).map { String(format: "%.4f", $0) }
                        .joined(separator: ", ") ?? "unknown"
                    let held = bridge?.capture("""
                        _o = bpy.data.objects[\(Bpy.quote(obj.name))]
                        print(tuple(round(c, 4) for c in _o.location), tuple(round(c, 4) for c in _o.matrix_world.translation))
                        """) ?? "?"
                    said = "\(group.title) showed (\(shown)); sent \(edit.python ?? "nothing"); "
                        + "\(outcome.map { $0.succeeded ? "succeeded" : "FAILED: \($0.error ?? "")" } ?? "not run"); "
                        + "now shows (\(after)); Blender location, world: \(held); "
                        + "preview vs Blender, worst of \(previewed.count) object(s): \(String(format: "%.6f", worst)) m"
                case "undo":          session.performUndo()
                case "redo":          session.performRedo()
                case _ where token.hasPrefix("mesh:"):
                    guard let op = LastOperator.Mesh(rawValue: String(token.dropFirst("mesh:".count))) else {
                        print("[bk] object-ops \(token): no such Mesh row"); continue
                    }
                    bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location, symmetry: scene.active?.symmetry))
                case _ where token.hasPrefix("adjust:"):
                    let pair = token.dropFirst("adjust:".count).split(separator: "=").map(String.init)
                    said = "no adjustable operator"
                    if pair.count == 2, let v = Double(pair[1]), var op = bridge?.adjustable {
                        op[pair[0]] = v
                        said = bridge?.readjust(op).map { "re-ran \($0.python)" } ?? "REFUSED"
                    }
                default:
                    print("[bk] object-ops \(token): no such row"); continue
                }
                let took = Date().timeIntervalSince(started) * 1000
                let blender = bridge?.capture("""
                    import bmesh
                    _dg = bpy.context.evaluated_depsgraph_get()
                    def _bk_count(o):
                        if o.type != 'MESH':
                            return '-'
                        if o.mode == 'EDIT':
                            _bm = bmesh.from_edit_mesh(o.data)
                            return f"{len(_bm.verts)}v/{len(_bm.faces)}f sel {sum(v.select for v in _bm.verts)}"
                        _m = o.evaluated_get(_dg).data
                        return f"{len(_m.vertices)}v/{len(_m.polygons)}f"
                    print(' '.join(f"{o.name}:{o.type}:{o.parent.name if o.parent else '-'}:{_bk_count(o)}"
                                   + ('*' if o.select_get() else '')
                                   for o in bpy.context.view_layer.objects))
                    """) ?? "?"
                let shown = scene.objects.map {
                    "\($0.name):\($0.blenderType):\($0.parentName ?? "-"):\($0.mesh.vertices.count)v"
                        + (scene.selection.contains($0.id) ? "*" : "")
                }.joined(separator: " ")
                let tree = scene.outlinerRows().map { String(repeating: ">", count: $0.depth) + $0.object.name }
                    .joined(separator: " ")
                print("[bk] object-ops \(token) (\(Int(took)) ms)\(said.isEmpty ? "" : ": " + said); "
                      + "\(scene.mode.bpyMode) mode; active \(scene.active?.name ?? "none")")
                print("[bk]   Blender: \(blender)")
                print("[bk]   app:     \(shown)")
                print("[bk]   outliner: \(tree)")
                print("[bk]   redo panel: \(bridge?.adjustable.map { $0.name + " — " + $0.python.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? "none"); "
                      + "banner: \(bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none")")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            print("[bk] object-ops: done"); fflush(stdout)
        }
        // `-symmetry-ops a,b,…` drives mirror editing through the calls the
        // controls make, once a `-eval64` script has finished, and prints
        // after each what Blender holds beside what the app shows. Tokens:
        // `edit` and `object` (Edit Mesh and Done); `mode:vertexPaint|weightPaint|
        // texturePaint` (a paint mode, as `choose` enters it); `proportional:on|off
        // [:size[:falloff[:connected]]]`
        // (the Proportional menu's toggle, Size, Falloff and Connected Only); `toggle:x|y|z|topology`
        // (the header's button, `toggleSymmetry`); `drag:translate|rotate|scale
        // :0|1|2|screen:<amount>` — a gizmo drag with that handle, `amount`
        // the handle-lengths moved, the degrees turned or the scale ratio —
        // through make, beginSession, resolve, snapping, apply, then the
        // roll-back and `bridge.run` endGizmo does, printing the preview held
        // against Blender's result; `mesh:<LastOperator.Mesh>`; `undo`.
        .task(id: bridge == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-symmetry-ops"), i + 1 < args.count, bridge != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            func blenderSide() -> String {
                bridge?.capture("""
                    import bmesh
                    _o = bpy.context.view_layer.objects.active
                    if _o is None or _o.type != 'MESH':
                        print('no active mesh')
                    else:
                        _d = _o.data
                        _flags = ''.join(c for c, p in (('x', 'use_mirror_x'), ('y', 'use_mirror_y'),
                                         ('z', 'use_mirror_z'), ('t', 'use_mirror_topology')) if getattr(_d, p))
                        if _o.mode == 'EDIT':
                            _co = [v.co for v in bmesh.from_edit_mesh(_d).verts]
                        else:
                            _co = [v.co for v in _d.vertices]
                        print(f"{_o.name} {_o.mode} flags '{_flags}' " + ' '.join('%.6f %.6f %.6f' % tuple(c) for c in _co))
                    """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            }
            /// Blender's vertices, from what `blenderSide` printed.
            func blenderVertices(_ said: String) -> [SIMD3<Float>] {
                let numbers = said.split(separator: " ").dropFirst(4).compactMap { Float($0) }
                return stride(from: 0, to: numbers.count - 2, by: 3).map {
                    SIMD3(numbers[$0], numbers[$0 + 1], numbers[$0 + 2])
                }
            }
            for token in args[i + 1].split(separator: ",").map(String.init) {
                bridge?.dismissReport(bridge?.report?.id ?? -1)
                let parts = token.split(separator: ":").map(String.init)
                var said = ""
                switch parts[0] {
                case "edit":   setEditing(true)
                case "object": setEditing(false)
                case "undo":   session.performUndo()
                case "mode":
                    // A paint mode, entered as `choose` enters one: out of
                    // Blender's edit mode, then the interface's mode, with
                    // Blender left in object mode underneath.
                    guard parts.count == 2, let next = InteractionMode(rawValue: parts[1]), next.isBrushMode,
                          next != .sculpt else { said = "mode:vertexPaint|weightPaint|texturePaint"; break }
                    if editing { bridge?.run(Bpy.setMode(.object), undo: "Toggle Edit Mode") }
                    scene.setMode(next)
                case "proportional":
                    // The Proportional menu's toggle and its Size items.
                    bridge?.run(ToolsBpy.proportional(parts.count > 1 && parts[1] == "on", editing: editing))
                    if parts.count > 2, let v = Float(parts[2]) { bridge?.run(ToolsBpy.size(v)) }
                    // `proportional:on:<size>:<falloff>:connected` — the Falloff
                    // menu and Connected Only too.
                    if parts.count > 3, let f = MeshEditor.ProportionalFalloff(rawValue: parts[3]) {
                        bridge?.run(ToolsBpy.falloff(f))
                    }
                    if parts.count > 2 { bridge?.run(ToolsBpy.connected(parts.count > 4 && parts[4] == "connected")) }
                    said = "proportional \(scene.tools.isProportional(editing: editing)) size \(scene.tools.size) "
                        + "falloff \(scene.tools.falloff.rawValue) connected \(scene.tools.connected)"
                case "toggle":
                    guard parts.count == 2, let flag = SymmetryBpy.Flag.allCases
                        .first(where: { $0.property == "use_mirror_" + parts[1] }) else { said = "no such flag"; break }
                    toggleSymmetry(flag)
                case "mesh":
                    guard parts.count == 2, let op = LastOperator.Mesh(rawValue: parts[1]) else { said = "no such row"; break }
                    let before = scene.active?.mesh.vertices.map(\.position) ?? []
                    let made = LastOperator.mesh(op, spinningAround: scene.active?.location,
                                                 symmetry: scene.active?.symmetry)
                    bridge?.perform(made)
                    let after = scene.active?.mesh.vertices.map(\.position) ?? []
                    let moved = zip(before, after).filter { simd_distance($0, $1) > 1e-5 }
                    said = "sent \(made.python); \(moved.count) vertices moved, "
                        + "\(zip(before, after).filter { $0.x < -1e-4 && simd_distance($0, $1) > 1e-5 }.count) on -X"
                case "drag":
                    guard parts.count == 4, let amount = Double(parts[3]) else { said = "drag:mode:handle:amount"; break }
                    let mode: TransformGizmo.Mode = parts[1] == "rotate" ? .rotate : parts[1] == "scale" ? .scale : .translate
                    let handle: TransformGizmo.Handle = Int(parts[2]).map { .axis($0) } ?? .screen
                    let size = CGSize(width: 1000, height: 800)
                    guard let obj = scene.active,
                          let g = TransformGizmo.make(mode: mode, scene: scene, options: options,
                                                      camera: camera, size: size) else { said = "no gizmo"; break }
                    let p = TransformGizmo.Projection(camera: camera, size: size)
                    guard let c = p.project(g.origin) else { said = "gizmo off screen"; break }
                    var a = CGPoint(x: c.x + 60, y: c.y - 40), b = a
                    switch (mode, handle) {
                    case (.rotate, _):
                        let r: CGFloat = 110, t = CGFloat(amount) * .pi / 180
                        a = CGPoint(x: c.x + r, y: c.y)
                        b = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
                    case (_, .axis(let k)):
                        guard let tip = p.project(g.origin + g.axes[k] * g.radius) else { break }
                        a = tip
                        b = CGPoint(x: tip.x + (tip.x - c.x) * CGFloat(amount), y: tip.y + (tip.y - c.y) * CGFloat(amount))
                    default:
                        b = CGPoint(x: a.x + 60 * CGFloat(amount), y: a.y - 40 * CGFloat(amount))
                    }
                    let start = obj.mesh.vertices.map(\.position)
                    let session = TransformGizmo.beginSession(handle: handle, at: a, gizmo: g, scene: scene,
                                                              camera: camera, size: size, options: options)
                    guard let raw = TransformGizmo.resolve(session, at: b) else { said = "no result"; break }
                    let result = TransformGizmo.snapping(raw, session: session, at: b).result
                    TransformGizmo.apply(result, session: session)
                    let preview = obj.mesh.vertices.map(\.position)
                    let python = TransformGizmo.python(result, session: session)
                    TransformGizmo.rollBack(session)
                    // As endGizmo does: nothing sent when the mirror leaves
                    // Blender nothing to transform.
                    let blenderBefore = blenderVertices(blenderSide())
                    if let why = TransformGizmo.nothingToCommit(session) {
                        bridge?.showReport(session.gizmo.mode.undoName, why)
                    } else {
                        bridge?.run(python, undo: session.gizmo.mode.undoName)
                    }
                    let shown = obj.mesh.vertices.map(\.position)
                    let blender = blenderVertices(blenderSide())
                    func gap(_ x: [SIMD3<Float>], _ y: [SIMD3<Float>]) -> String {
                        x.count == y.count ? String(format: "%.1e", zip(x, y).map { simd_distance($0, $1) }.max() ?? 0)
                                           : "counts \(x.count) vs \(y.count)"
                    }
                    // Which vertices moved: the preview's among the drawn
                    // positions, Blender's among its own coordinates — under
                    // a modifier shown in edit mode the two differ, and only
                    // the second is what the mirror pairs on.
                    let previewMoved = start.indices.filter { simd_distance(start[$0], preview[$0]) > 1e-4 }
                    let blenderMoved = blender.count == blenderBefore.count
                        ? blender.indices.filter { simd_distance(blenderBefore[$0], blender[$0]) > 1e-4 } : []
                    let deformed = obj.editTopology?.blenderPositions.isEmpty == false
                    said = "sent \(TransformGizmo.nothingToCommit(session) == nil ? python : "nothing"); "
                        + "followers \(session.edit?.symmetry?.followers.count ?? 0)"
                        + (deformed ? " (paired on Blender's coordinates, a modifier moves what is drawn)" : "") + "; "
                        + "preview moved \(previewMoved.count) \(previewMoved), Blender moved \(blenderMoved.count) \(blenderMoved); "
                        + (deformed ? "" : "preview vs Blender \(gap(preview, blender)), ")
                        + "preview vs the mirror after \(gap(preview, shown))"
                default:
                    said = "no such token"
                }
                let symmetry = scene.active?.symmetry ?? MeshSymmetry()
                let blender = blenderSide()
                print("[bk] symmetry-ops \(token): \(said)")
                print("[bk]   \(scene.mode.bpyMode) mode; the header shows \(symmetry.label.isEmpty ? "none" : symmetry.label)"
                      + (symmetry.topology ? " + Topology" : "") + "; Blender: "
                      + blender.split(separator: " ").prefix(4).joined(separator: " ")
                      + "; banner: \(bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none")")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            print("[bk] symmetry-ops: done"); fflush(stdout)
        }
        // `-points-ops a,b,…` drives Edit Mode on curves and lattices through
        // the calls the controls make, once a `-eval64` script has finished,
        // and prints after each what Blender holds — the edited object's
        // selected points and their positions, read from Blender — beside
        // what the app shows. Tokens: `select:Name` (the Outliner's tap),
        // `edit`, `object` (Edit Curve / Edit Lattice and Done),
        // `tap:i[:extend]` (a tap 3 points right of and 2 above point i, through
        // `pointTap`), `box:x0:y0:x1:y1` (view fractions, through
        // `pointRegion`), `drag:translate|rotate|scale:0|1|2:amount:frames` (a
        // gizmo drag through make, beginSession, beginPointDrag, a preview per
        // frame and the commit, as the viewport's coordinator runs them; a
        // sixth part `what@k` does `what` after frame k, mid-gesture: `undo`,
        // `redo`, `tab`, `done` or `tap` the way the top bar, the keyboard and
        // the viewport send them, which the drag's hold refuses, or
        // `bypass-mode` / `bypass-points`, a mode change or a point moved
        // straight into Blender past the hold, which the next frame refuses),
        // `curve:<row>` and `lattice:<row>` (the menus' rows), `all`, `none`,
        // `delete`, `stale-mesh-tap` (marks a mesh selection pending, as a tap
        // on an emptied curve once did), `data:property=value` (a Data tab
        // field), `add-lattice`
        // (Add ▸ Lattice), `lattice-mod:Mesh:Lattice` (Add Modifier ▸ Lattice
        // on Mesh and its Object field), `cube-top:Name`, `undo`, `redo`.
        .task(id: bridge == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-points-ops"), i + 1 < args.count, let bridge else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            let size = CGSize(width: 1000, height: 800)
            func blenderPoints() -> String {
                bridge.capture("""
                    import _blenderkit_points as _bk_pts
                    _o = bpy.context.view_layer.objects.active
                    if _o is None or not _bk_pts.edits_points(_o) or _o.mode != 'EDIT':
                        print(f"{_o.name if _o else '-'} {_o.mode if _o else '-'}")
                    else:
                        _p, _f, _l = _bk_pts.cage(_o)
                        _sel = [i for i, f in enumerate(_f) if f & 1]
                        _cyc = [s.use_cyclic_u for s in _o.data.splines] if _o.type == 'CURVE' else []
                        print(f"{_o.name} EDIT {len(_f)} points, cyclic {_cyc}, selected {_sel}; "
                              + ' '.join('%d:(%.4f %.4f %.4f)' % (i, _p[3*i], _p[3*i+1], _p[3*i+2]) for i in _sel[:9]))
                    """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            }
            for token in args[i + 1].split(separator: ",").map(String.init) {
                bridge.dismissReport(bridge.report?.id ?? -1)
                let parts = token.split(separator: ":").map(String.init)
                let started = Date()
                var said = ""
                switch parts[0] {
                case "select":
                    guard parts.count == 2 else { said = "select:Name"; break }
                    bridge.select(Bpy.select(parts[1]))
                case "edit":   setEditing(true)
                case "object": setEditing(false)
                case "undo":   session.performUndo()
                case "redo":   session.performRedo()
                case "all":    bridge.run(selectAllCommand("SELECT"), undo: "Select All")
                case "none":   bridge.run(selectAllCommand("DESELECT"), undo: "Deselect")
                case "delete": deleteSelected()
                case "stale-mesh-tap":
                    scene.editSelection.vertices = [0]
                    scene.editSelectionPending = true
                case "add-lattice":
                    bridge.add(.lattice, at: scene.cursor, view: camera)
                case "tap":
                    guard parts.count >= 2, let k = Int(parts[1]), let (object, cage) = scene.editedPoints, k < cage.count,
                          let p = cage.screenPoints(model: object.modelMatrix,
                                                    viewProjection: camera.viewProjection(aspect: 1.25), size: size)[k]
                    else { said = "no such point on screen"; break }
                    let action: SelectAction = parts.count > 2 && parts[2] == "extend" ? .extend : .set
                    if let (target, next) = MetalViewportView.pointTap(at: CGPoint(x: p.x + 3, y: p.y - 2), scene: scene,
                                                                       camera: camera, size: size, action: action) {
                        bridge.select(PointsBpy.select(next, object: target.name))
                        said = "picked \(next.sorted())"
                    } else {
                        said = "the tap changed nothing"
                    }
                case "box":
                    let f = parts.dropFirst().compactMap(Double.init).map { CGFloat($0) }
                    guard f.count == 4 else { said = "box:x0:y0:x1:y1"; break }
                    let region = SelectionRegion.box(CGRect(x: f[0] * size.width, y: f[1] * size.height,
                                                            width: (f[2] - f[0]) * size.width,
                                                            height: (f[3] - f[1]) * size.height))
                    if let (target, next) = MetalViewportView.pointRegion(region, scene: scene, camera: camera,
                                                                          size: size, action: .set) {
                        bridge.run(PointsBpy.select(next, object: target.name), undo: region.undoName, quiet: true)
                        said = "boxed \(next.sorted())"
                    } else {
                        said = "the box changed nothing"
                    }
                case "drag":
                    guard parts.count == 5 || parts.count == 6, let amount = Double(parts[3]),
                          let frames = Int(parts[4]), frames > 0 else {
                        said = "drag:mode:handle:amount:frames[:what@k]"; break
                    }
                    let interruption = parts.count == 6 ? parts[5].split(separator: "@").map(String.init) : []
                    let interruptAt = interruption.count == 2 ? Int(interruption[1]) ?? 0 : 0
                    let mode: TransformGizmo.Mode = parts[1] == "rotate" ? .rotate : parts[1] == "scale" ? .scale : .translate
                    let handle: TransformGizmo.Handle = Int(parts[2]).map { .axis($0) } ?? .screen
                    guard let g = TransformGizmo.make(mode: mode, scene: scene, options: options,
                                                      camera: camera, size: size) else { said = "no gizmo"; break }
                    let p = TransformGizmo.Projection(camera: camera, size: size)
                    guard let c = p.project(g.origin) else { said = "gizmo off screen"; break }
                    var a = CGPoint(x: c.x + 60, y: c.y - 40)
                    var path: (CGFloat) -> CGPoint = { t in CGPoint(x: a.x + 60 * CGFloat(amount) * t, y: a.y - 40 * CGFloat(amount) * t) }
                    switch (mode, handle) {
                    case (.rotate, _):
                        let r: CGFloat = 110
                        let turn: CGFloat = CGFloat(amount) * .pi / 180
                        a = CGPoint(x: c.x + r, y: c.y)
                        path = { t in CGPoint(x: c.x + r * cos(turn * t), y: c.y + r * sin(turn * t)) }
                    case (_, .axis(let k)):
                        guard let tip = p.project(g.origin + g.axes[k] * g.radius) else { break }
                        a = tip
                        path = { t in CGPoint(x: tip.x + (tip.x - c.x) * CGFloat(amount) * t,
                                              y: tip.y + (tip.y - c.y) * CGFloat(amount) * t) }
                    default:
                        break
                    }
                    let session = TransformGizmo.beginSession(handle: handle, at: a, gizmo: g, scene: scene,
                                                              camera: camera, size: size, options: options)
                    guard let points = session.points else { said = "not a points drag"; break }
                    guard bridge.beginPointDrag(object: points.object.name, followers: points.followers,
                                                undo: session.gizmo.mode.undoName) else { said = "Blender refused the drag"; break }
                    var last: TransformGizmo.Result?
                    var costs: [Double] = []
                    var refused = false
                    let placeQuery = "_o = bpy.data.objects[\(Bpy.quote(points.object.name))]\n"
                        + "print('%.4f %.4f %.4f %s' % (*_o.matrix_world.translation, _o.mode))"
                    let placeBefore = bridge.capture(placeQuery) ?? "?"
                    for k in 1...frames {
                        guard let raw = TransformGizmo.resolve(session, at: path(CGFloat(k) / CGFloat(frames))) else { continue }
                        let result = TransformGizmo.snapping(raw, session: session, at: path(CGFloat(k) / CGFloat(frames))).result
                        guard result != last else { continue }
                        let t0 = Date()
                        if !bridge.previewPointDrag(TransformGizmo.python(result, session: session),
                                                    undo: session.gizmo.mode.undoName) {
                            said += "frame \(k) refused: \(bridge.report?.message ?? "?"); "
                            bridge.cancelPointDrag()
                            refused = true
                            break
                        }
                        costs.append(Date().timeIntervalSince(t0) * 1000)
                        last = result
                        guard k == interruptAt else { continue }
                        // Mid-gesture, through the same calls the controls make.
                        let stepsBefore = self.session.backendRevision
                        bridge.dismissReport(bridge.report?.id ?? -1)
                        switch interruption[0] {
                        case "undo": self.session.performUndo()
                        case "redo": self.session.performRedo()
                        case "tab": toggleEditing()
                        case "done": setEditing(false)
                        case "tap": bridge.select(PointsBpy.select([0], object: points.object.name))
                        case "bypass-mode": _ = bridge.capture("bpy.ops.object.mode_set(mode='OBJECT')")
                        case "bypass-points":
                            _ = bridge.capture("""
                                _s = bpy.data.objects[\(Bpy.quote(points.object.name))].data.splines[0]
                                _p = _s.bezier_points[0] if _s.type == 'BEZIER' else _s.points[0]
                                _p.co.x += 0.5
                                """)
                        default: said += "no such interruption; "
                        }
                        said += "\(interruption[0]) after frame \(k): hold \(bridge.pointDragOpen ? "on" : "off"), "
                            + "history revision \(stepsBefore) -> \(self.session.backendRevision), "
                            + "banner \(bridge.report.map { $0.message } ?? "none"), "
                            + "console \(self.session.console.last?.text ?? ""), Blender \(blenderPoints()); "
                    }
                    said += "object before \(placeBefore), after \(bridge.capture(placeQuery) ?? "?"); "
                    guard !refused else { said += "the drag was cancelled"; break }
                    let previewCage = points.object.controlCage
                    let previewMesh = points.object.mesh.vertices.map(\.position)
                    let followerMeshes = points.followers.compactMap { name in scene.objects.first { $0.name == name } }
                        .map { ($0.name, $0.mesh.vertices.map(\.position)) }
                    // Where the viewport drew each follower on the last frame.
                    let followerPlaces = points.followers.compactMap { name in scene.objects.first { $0.name == name } }
                        .map { ($0.name, $0.modelMatrix.columns.3) }
                    if let last {
                        let python = TransformGizmo.python(last, session: session)
                        let committed = bridge.commitPointDrag(python, undo: session.gizmo.mode.undoName)
                        said += "sent \(python)\(committed.succeeded ? "" : " — refused: \(committed.error ?? "?")"); "
                    } else {
                        bridge.cancelPointDrag()
                        said += "nothing moved; "
                    }
                    func gap(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> String {
                        a.count == b.count ? String(format: "%.1e", zip(a, b).map { simd_distance($0, $1) }.max() ?? 0)
                                           : "counts \(a.count) vs \(b.count)"
                    }
                    let after = points.object.controlCage
                    said += "\(costs.count) frames, each \(String(format: "%.1f", costs.min() ?? 0))–"
                        + "\(String(format: "%.1f", costs.max() ?? 0)) ms (median "
                        + "\(String(format: "%.1f", costs.sorted().dropFirst(costs.count / 2).first ?? 0))); "
                        + "the last frame's points vs the commit's \(gap(previewCage?.positions ?? [], after?.positions ?? [])), "
                        + "its wire vs the commit's \(gap(previewMesh, points.object.mesh.vertices.map(\.position)))"
                    for (name, mesh) in followerMeshes {
                        let now = scene.objects.first { $0.name == name }?.mesh.vertices.map(\.position) ?? []
                        said += "; follower \(name) frame vs commit \(gap(mesh, now))"
                    }
                    for (name, place) in followerPlaces {
                        let now = scene.objects.first { $0.name == name }?.modelMatrix.columns.3 ?? .zero
                        let blender = bridge.capture("print('%.4f %.4f %.4f' % tuple(bpy.data.objects["
                                                     + "\(Bpy.quote(name))].matrix_world.translation))") ?? "?"
                        said += String(format: "; follower %@ drawn on the last frame at (%.4f %.4f %.4f), after the "
                                       + "commit at (%.4f %.4f %.4f), Blender (%@)", name, place.x, place.y, place.z,
                                       now.x, now.y, now.z, blender)
                    }
                case "curve", "lattice":
                    guard parts.count >= 2 else { said = "curve:<row>"; break }
                    let command: PointsBpy.Command?
                    switch parts[1] {
                    case "subdivide": command = PointsBpy.subdivide(cuts: parts.count > 2 ? Int(parts[2]) ?? 1 : 1)
                    case "extrude":   command = PointsBpy.extrude
                    case "delete":    command = PointsBpy.delete(segments: false)
                    case "segments":  command = PointsBpy.delete(segments: true)
                    case "handle":    command = parts.count > 2 ? PointsBpy.handleType(parts[2]) : nil
                    case "cyclic":    command = PointsBpy.toggleCyclic
                    case "switch":    command = PointsBpy.switchDirection
                    case "regular":   command = PointsBpy.makeRegular
                    case "flip":      command = PointsBpy.flip(parts.count > 2 ? parts[2] : "U")
                    default:          command = nil
                    }
                    guard let command else { said = "no such row"; break }
                    runPoints(command)
                    said = "sent \(command.python)"
                case "data":
                    let pair = token.dropFirst("data:".count).split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2, let object = scene.active else { said = "data:property=value"; break }
                    bridge.run(PointsBpy.set(pair[0], to: pair[1], object: object.name), undo: pair[0])
                    said = "settings now \(String(describing: object.dataSettings))"
                case "lattice-mod":
                    // The Modifiers panel: Add Modifier ▸ Lattice, then its
                    // Object field, through the same two calls it makes.
                    guard parts.count == 3, let mesh = scene.objects.first(where: { $0.name == parts[1] }) else {
                        said = "lattice-mod:Mesh:Lattice"; break
                    }
                    bridge.select(Bpy.select(mesh.name))
                    bridge.run(Bpy.addModifier(.lattice, on: mesh.mesh), undo: "Add Modifier")
                    guard let modifier = mesh.modifiers.last(where: { $0.kind == .lattice }) else {
                        said = "no Lattice row came back"; break
                    }
                    var changed = modifier
                    changed.targetName = parts[2]
                    bridge.run(Bpy.modifierEdit(from: modifier, to: changed), undo: "Edit Modifier")
                    said = "the row reads object \(mesh.modifiers.last(where: { $0.kind == .lattice })?.targetName ?? "?")"
                case "cube-top":
                    let name = parts.count > 1 ? parts[1] : "Cube"
                    let shown = scene.objects.first { $0.name == name }.map { o in
                        o.mesh.vertices.map { (o.modelMatrix * SIMD4($0.position, 1)).z }.max() ?? .nan
                    } ?? .nan
                    let blender = bridge.capture("""
                        _o = bpy.data.objects[\(Bpy.quote(name))]
                        _dg = bpy.context.evaluated_depsgraph_get()
                        _m = _o.evaluated_get(_dg).to_mesh()
                        print('%.4f' % max((_o.matrix_world @ v.co).z for v in _m.vertices))
                        _o.evaluated_get(_dg).to_mesh_clear()
                        """) ?? "?"
                    said = "\(name)'s top: Blender \(blender), the viewport \(String(format: "%.4f", shown))"
                default:
                    said = "no such token"
                }
                let took = Date().timeIntervalSince(started) * 1000
                let shown = scene.editedPoints.map { "the viewport shows \($0.cage.count) points, selected \($0.cage.selected.sorted())" }
                    ?? "no points on screen"
                print("[bk] points-ops \(token) (\(Int(took)) ms): \(said)")
                print("[bk]   \(scene.mode.bpyMode) mode; Blender: \(blenderPoints()); \(shown); "
                      + "banner: \(bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            print("[bk] points-ops: done"); fflush(stdout)
        }
        // `-groups-ops a,b,…` drives the Data tab's Vertex Groups and Shape
        // Keys panels and the modifiers' Vertex Group field through the
        // commands their controls send (`GroupsBpy`, `Bpy.modifierEdit`), once
        // a `-eval64` script has finished, and prints after each what Blender
        // holds beside what the panels show. See `runGroupsOps`.
        .task(id: bridge == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-groups-ops"), i + 1 < args.count, bridge != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            await runGroupsOps(args[i + 1].split(separator: ",").map(String.init))
        }
        #endif
        .sheet(isPresented: $showOperations) {
            OperatorSearch(catalogue: catalogue, bridge: bridge, isPresented: $showOperations)
        }
        // Select ▸ Select Pattern…: Blender's `*` and `?` wildcards, added to
        // the selection, not case sensitive — its defaults.
        .alert("Select Pattern", isPresented: $askingPattern) {
            TextField("Pattern", text: $pattern)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Select") { select(.pattern(pattern)) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Objects whose names match, such as Wheel* or Cube.00?") }
        .focusedSceneValue(\.objectAddActions, keysLive ? ObjectAddActions(add: { bridge?.add($0, at: scene.cursor, view: camera) }) : nil)
        // The keyboard. Withdrawn while a sheet covers the view, while the
        // operator search is open, and while a text field has the keyboard —
        // so a letter typed into the Outliner or the search is a letter.
        .focusedSceneValue(\.viewportKeys, keysLive ? viewportKeys : nil)
        .background { keyAliases }
        .onChange(of: bridge?.report?.id) { _, _ in showReport() }
        // Blender's mode moved out from under a brush — Tab, Edit Mesh, a
        // script — and a brush in hand would now mean nothing.
        .onChange(of: scene.mode) { _, mode in
            if !mode.isBrushMode, tool.isBrush { tool = .select }
        }
        .onChange(of: scene.mode) { _, mode in if mode == .texturePaint, let obj = scene.active { TexturePaintSetup.prepare(obj, scene: scene, bridge: bridge) } }
        // Entered from a script, it waited for the script to end.
        .onChange(of: session.isRunning) { _, running in
            if !running, scene.mode == .texturePaint, let obj = scene.active {
                TexturePaintSetup.prepare(obj, scene: scene, bridge: bridge)
            }
        }
    }

    // MARK: selecting

    /// A Select menu row: Blender's operator through the bridge, as one undo
    /// step — with its redo panel, for the edit-mode rows Blender gives one.
    /// What is selected afterwards is what the mirror reads back.
    private func select(_ command: SelectMenu.Command) {
        guard let bridge, !session.isRunning else { return }
        switch command.action(editing: editing) {
        case .run(let python, let undo): bridge.run(python, undo: undo)
        case .perform(let op):          bridge.perform(op)
        }
    }

    #if DEBUG
    /// The `-groups-ops` hook. Tokens: `select:Name` (the Outliner's tap),
    /// `edit` and `object` (Edit Mesh and Done); `pick:x<0` (the vertices with
    /// x below 0 selected in Blender, everything else deselected first, as
    /// `Bpy.pushEditSelection` does for a tap); `group:add`,
    /// `group:remove`, `group:remove-all`, `group:rename:New`,
    /// `group:active:Name`, `group:lock:Name`, `group:assign`,
    /// `group:remove-from`, `group:select`, `group:deselect` (each on the
    /// active group, as the panel's buttons are), `weight:<w>` (the Weight
    /// field); `key:add`, `key:mix`, `key:remove`, `key:delete-all`,
    /// `key:apply-all`, `key:active:Name`, `key:value:Name:<v>` (the row's
    /// field, clamped as it clamps), `key:set:Name:<setting>:<python>`,
    /// `switch:relative|showonly|editmode:on|off`; `+kind` (Add Modifier),
    /// `mod:Name:group:Group` and `mod:Name:invert` (the row's Vertex Group
    /// field and its Invert); `drag:z:<handle lengths>` (a gizmo Move along Z
    /// through make, beginSession, resolve, apply, roll-back and `bridge.run`,
    /// as `endGizmo` does); `undo`, `redo`. Each sends exactly what the
    /// control sends; nothing here builds Python of its own but `pick`.
    private func runGroupsOps(_ tokens: [String]) async {
        guard let bridge else { return }
        func send(_ command: GroupsBpy.Command) {
            bridge.run(command.call, undo: command.undo, executing: command.executed)
        }
        func blenderSide() -> String {
            bridge.capture("""
                _o = bpy.context.view_layer.objects.active
                if _o is None or _o.type != 'MESH':
                    print('no active mesh')
                else:
                    if _o.mode == 'EDIT':
                        _o.update_from_editmode()
                    _n = [sum(1 for v in _o.data.vertices for g in v.groups if g.group == vg.index) for vg in _o.vertex_groups]
                    _sk = _o.data.shape_keys
                    _keys = [] if _sk is None else [f"{k.name}={k.value:.3f}" + ('/m' if k.mute else '') + (f"/rel:{k.relative_key.name}" if k.relative_key != _sk.reference_key else '') + (f"/vg:{k.vertex_group}" if k.vertex_group else '') for k in _sk.key_blocks]
                    _eval = _o.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh()
                    _top = max(v.co.z for v in _eval.vertices)
                    _o.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh_clear()
                    print(f"{_o.name} {_o.mode} groups {[g.name + ('*' if g.lock_weight else '') for g in _o.vertex_groups]} counts {_n} "
                          f"active {_o.vertex_groups.active_index} weight {bpy.context.scene.tool_settings.vertex_group_weight:.3f} "
                          f"keys {_keys} active key {_o.active_shape_key_index} sel {_o.data.total_vert_sel} "
                          f"top {_top:.3f} mods {[(m.name, m.vertex_group, m.invert_vertex_group) for m in _o.modifiers if hasattr(m, 'vertex_group')]}")
                """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        }
        func shown() -> String {
            guard let obj = scene.active else { return "no active object" }
            guard let g = obj.meshGroups else { return "\(obj.name): no groups record" }
            let groups = g.groups.map { $0.name + ($0.locked ? "*" : "") + ($0.count.map { ":\($0)" } ?? "") }
            let keys = g.keys.map { String(format: "%@=%.3f", $0.name, $0.value) + ($0.mute ? "/m" : "") }
            let mods = obj.modifiers.filter(\.kind.takesVertexGroup).map { "\($0.name):\($0.vertexGroup)\($0.invertVertexGroup ? "/inv" : "")" }
            return "groups \(groups) active \(g.activeGroupName ?? "-") weight \(String(format: "%.3f", g.weight)) "
                + "keys \(keys) active key \(g.activeKeyBlock?.name ?? "-") relative \(g.useRelative) "
                + "lock \(g.showOnlyShapeKey) editmode \(g.shapeKeyEditMode) mods \(mods) "
                + "top \(String(format: "%.3f", obj.mesh.vertices.map(\.position.z).max() ?? 0)) verts \(obj.mesh.vertices.count)"
        }
        for token in tokens {
            bridge.dismissReport(bridge.report?.id ?? -1)
            let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let obj = scene.active
            let name = obj?.name ?? ""
            let groups = obj?.meshGroups
            let active = groups?.activeGroupName ?? ""
            var said = ""
            switch parts[0] {
            case "select" where parts.count == 2: bridge.select(Bpy.select(parts[1], only: true))
            case "edit":   setEditing(true)
            case "object": setEditing(false)
            case "undo":   session.performUndo()
            case "redo":   session.performRedo()
            case "pick":
                bridge.run("""
                    import bmesh
                    _bm = bmesh.from_edit_mesh(bpy.context.object.data)
                    for _seq in (_bm.faces, _bm.edges, _bm.verts):
                        for _e in _seq:
                            _e.select = False
                    for _v in _bm.verts:
                        _v.select = _v.co.x < -1e-4
                    _bm.select_flush_mode()
                    bmesh.update_edit_mesh(bpy.context.object.data)
                    """, undo: "Select")
            case "weight" where parts.count == 2:
                bridge.run(GroupsBpy.setWeight(Float(parts[1]) ?? 1))
            case "group" where parts.count >= 2:
                switch parts[1] {
                case "add":         send(GroupsBpy.addGroup(object: name))
                case "remove":      send(GroupsBpy.removeGroup(active, object: name))
                case "remove-all":  send(GroupsBpy.removeAllGroups(object: name))
                case "rename" where parts.count == 3: send(GroupsBpy.renameGroup(active, to: parts[2], object: name))
                case "active" where parts.count == 3: send(GroupsBpy.setActiveGroup(parts[2], object: name))
                case "lock" where parts.count == 3:
                    let locked = groups?.groups.first { $0.name == parts[2] }?.locked ?? false
                    send(GroupsBpy.lockGroup(parts[2], !locked, object: name))
                case "assign":      send(GroupsBpy.assign(active, weight: groups?.weight ?? 1, object: name))
                case "remove-from": send(GroupsBpy.removeFromGroup(active, object: name))
                case "select":      send(GroupsBpy.selectGroup(active, select: true, object: name))
                case "deselect":    send(GroupsBpy.selectGroup(active, select: false, object: name))
                default:            said = "no such group token"
                }
            case "key" where parts.count >= 2:
                let editingHere = editing
                switch parts[1] {
                case "add":        send(GroupsBpy.addKey(fromMix: false, object: name))
                case "mix":        send(GroupsBpy.addKey(fromMix: true, object: name))
                case "remove":     send(GroupsBpy.removeKey(groups?.activeKeyBlock?.name ?? "", object: name))
                case "delete-all": send(GroupsBpy.removeAllKeys(apply: false, object: name))
                case "apply-all":  send(GroupsBpy.removeAllKeys(apply: true, object: name))
                case "active" where parts.count == 3: send(GroupsBpy.setActiveKey(parts[2], object: name))
                case "value" where parts.count == 4:
                    guard let key = groups?.keys.first(where: { $0.name == parts[2] }), let v = Float(parts[3]) else {
                        said = "no such key"; break
                    }
                    let sent = key.clamped(v)
                    said = "the field sends \(sent)"
                    send(GroupsBpy.setKeyValue(key.name, sent, editing: editingHere, object: name))
                case "set" where parts.count == 5:
                    guard let setting = GroupsBpy.KeySetting(rawValue: parts[3]) else { said = "no such setting"; break }
                    send(GroupsBpy.setKey(parts[2], setting, parts[4], editing: editingHere, object: name))
                default: said = "no such key token"
                }
            case "switch" where parts.count == 3:
                let toggle: GroupsBpy.Switch? = ["relative": .useRelative, "showonly": .showOnly,
                                                 "editmode": .editMode][parts[1]]
                if let toggle { send(GroupsBpy.set(toggle, parts[2] == "on", editing: editing, object: name)) }
                else { said = "no such switch" }
            case _ where token.hasPrefix("+"):
                guard let obj, let kind = ModifierKind(rawValue: String(token.dropFirst())) else { said = "no such kind"; break }
                bridge.run(Bpy.addModifier(kind, on: obj.mesh), undo: "Add Modifier")
            case "mod" where parts.count >= 3:
                guard let modifier = obj?.modifiers.first(where: { $0.name == parts[1] }), let obj else {
                    said = "no such modifier"; break
                }
                var changed = modifier
                if parts[2] == "group", parts.count == 4 { changed.vertexGroup = parts[3] }
                else if parts[2] == "invert" { changed.invertVertexGroup.toggle() }
                let lines = Bpy.modifierEdit(from: modifier, to: changed)
                said = "sent " + lines.joined(separator: " / ")
                if !lines.isEmpty { bridge.run(lines, undo: "Edit Modifier") }
                _ = obj
            case "drag" where parts.count == 3:
                let size = CGSize(width: 1000, height: 800)
                guard let amount = Double(parts[2]),
                      let g = TransformGizmo.make(mode: .translate, scene: scene, options: options,
                                                  camera: camera, size: size) else { said = "no gizmo"; break }
                let p = TransformGizmo.Projection(camera: camera, size: size)
                guard let c = p.project(g.origin), let tip = p.project(g.origin + g.axes[2] * g.radius) else {
                    said = "gizmo off screen"; break
                }
                let b = CGPoint(x: tip.x + (tip.x - c.x) * CGFloat(amount), y: tip.y + (tip.y - c.y) * CGFloat(amount))
                let drag = TransformGizmo.beginSession(handle: .axis(2), at: tip, gizmo: g, scene: scene,
                                                       camera: camera, size: size, options: options)
                guard let raw = TransformGizmo.resolve(drag, at: b) else { said = "no result"; break }
                let result = TransformGizmo.snapping(raw, session: drag, at: b).result
                TransformGizmo.apply(result, session: drag)
                let preview = scene.active?.mesh.vertices.map(\.position) ?? []
                let python = TransformGizmo.python(result, session: drag)
                TransformGizmo.rollBack(drag)
                bridge.run(python, undo: drag.gizmo.mode.undoName)
                let after = scene.active?.mesh.vertices.map(\.position) ?? []
                let gap = preview.count == after.count
                    ? zip(preview, after).map { simd_distance($0, $1) }.max() ?? 0 : -1
                said = "sent \(python); preview vs the mirror after: \(String(format: "%.1e", gap))"
            default:
                said = "no such token"
            }
            print("[bk] groups-ops \(token): \(said)")
            print("[bk]   \(scene.mode.bpyMode) mode; Blender: \(blenderSide())")
            print("[bk]   panels: \(shown()); banner: \(bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")")
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        print("[bk] groups-ops: done"); fflush(stdout)
    }

    /// What Blender holds selected and what the viewport shows, for the
    /// `-select-menu` hook's print.
    private func selectionSummary() -> (blender: String, shown: String) {
        if editing {
            let blender = bridge?.capture("""
                import bmesh
                _bm = bmesh.from_edit_mesh(bpy.context.object.data)
                print(f"{sum(v.select for v in _bm.verts)}v/{sum(e.select for e in _bm.edges)}e/{sum(f.select for f in _bm.faces)}f")
                """) ?? "?"
            let s = scene.editSelection
            let faces = Set(s.faces.map { scene.active?.editTopology?.trianglePolygons.indices.contains($0) == true
                ? Int(scene.active!.editTopology!.trianglePolygons[$0]) : $0 }).count
            return (blender, "\(s.vertices.count)v/\(s.edges.count)e/\(faces)f")
        }
        let blender = bridge?.capture(
            "print(','.join(sorted(o.name for o in bpy.context.view_layer.objects if o.select_get())))") ?? "?"
        return ("[\(blender)]", "[" + scene.objects.filter { scene.selection.contains($0.id) }
            .map(\.name).sorted().joined(separator: ",") + "]")
    }
    #endif

    /// Blender's Select menu, in the header where Blender has it: after the
    /// tool buttons, before Add and Object — or Mesh, while editing.
    private var selectMenu: some View {
        Menu {
            SelectMenuItems(editing: editing, selectMode: scene.selectMode, tool: tool,
                            hasActive: scene.active != nil,
                            vertexGroups: scene.active?.meshGroups?.groups.count,
                            choose: { choose($0) }, send: select,
                            askPattern: { askingPattern = true })
        } label: { menuLabel("Select", icon: "cursorarrow.rays") }
        .disabled(scene.objects.isEmpty)
    }

    // MARK: failures

    /// A failure, shown where the reader is looking — Blender's status-bar
    /// report. The traceback is still in the console; this is the one line
    /// that says what happened. It goes by itself after a few seconds.
    private func reportBanner(_ report: BpyBridge.Report) -> some View {
        Button {
            withAnimation(.easeIn(duration: 0.15)) { shownReport = nil }
            bridge?.dismissReport(report.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(BTheme.error)
                Text(report.operation)
                    .fontWeight(.semibold)
                Text(report.message)
                    .foregroundStyle(BTheme.text.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 560, alignment: .leading)
            .background(BTheme.menuBack.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(BTheme.error.opacity(0.6), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(report.operation) failed: \(report.message)")
        .padding(.top, 14)
        // Clear of the Frame All button in the corner.
        .padding(.horizontal, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
    }

    private func showReport() {
        guard let report = bridge?.report else { return }
        withAnimation(.easeOut(duration: 0.15)) { shownReport = report }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard shownReport?.id == report.id else { return }
            withAnimation(.easeIn(duration: 0.25)) { shownReport = nil }
        }
    }

    // MARK: sculpting

    /// A finished sculpt stroke goes into Blender's mesh, as one undo step.
    ///
    /// The brush paints the display cache, and the next mirroring pass puts
    /// Blender's mesh back over it — so until this, every stroke vanished at
    /// the next tap. On the simulator's shim the display cache *is* the scene,
    /// and only the undo step is needed.
    ///
    /// With the real Blender the stroke is Blender's own and is recorded by
    /// `BpyBridge.sculptEnd` as it ends, so this is the simulator's alone.
    private func keepStroke(_ object: BKObject) {
        guard !session.usesRealBlender else { return }
        undo.push("Sculpt Stroke", scene)
        session.autosave?.schedule(scene)
    }

    /// Blender is in its own Sculpt Mode, with its brushes on the mesh.
    private var sculptingInBlender: Bool { scene.mode == .sculpt && session.usesRealBlender }

    /// The object and mesh operations, refused in Blender's Sculpt Mode with
    /// a sentence on the banner: Blender offers none of them there (its sculpt
    /// header has Sculpt, Mask and Face Sets menus, no Object or Add menu),
    /// and some that the app sends would run in Sculpt Mode rather than in the
    /// mode they need — `primitive_cube_add` there crashes Blender (measured in
    /// 5.2.1). Returns whether it refused.
    private func refusedInSculptMode(_ what: String) -> Bool {
        guard sculptingInBlender else { return false }
        bridge?.showReport(what, "Blender's Sculpt Mode has no \(what). Leave Sculpt Mode first.")
        return true
    }

    // MARK: keyboard

    /// Everything the 3D View's keys can do, published while it is on screen.
    /// The keys themselves are in KeyboardCommands.swift.
    private var viewportKeys: ViewportKeyActions {
        ViewportKeyActions(
            isRunning: session.isRunning,
            hasActiveObject: scene.active != nil,
            editing: editing,
            selectMode: scene.selectMode,
            // Held while a sculpt stroke is down, or points are being
            // dragged (BpySession.gestureHold).
            canUndo: session.gestureHold == nil
                && (session.usesRealBlender ? session.backendCanUndo : undo.canUndo),
            canRedo: session.gestureHold == nil
                && (session.usesRealBlender ? session.backendCanRedo : undo.canRedo),
            setTool: { choose($0) },
            deleteSelected: deleteSelected,
            duplicate: { duplicateSelected() },
            selectAll: {
                bridge?.run(selectAllCommand("SELECT"), undo: "Select All")
            },
            deselectAll: {
                bridge?.run(selectAllCommand("DESELECT"), undo: "Deselect")
            },
            invertSelection: {
                bridge?.run(selectAllCommand("INVERT"), undo: "Invert Selection")
            },
            toggleEditing: toggleEditing,
            setSelectMode: setSelectMode,
            mesh: {
                if editingPoints {
                    // Bevel, Inset and the rest are the mesh's; the Curve or
                    // Lattice menu has what a curve or a lattice has.
                    bridge?.showReport($0.displayName, "\($0.displayName) works on meshes. The "
                                       + (activeIsLattice ? "Lattice" : "Curve") + " menu has the "
                                       + (activeIsLattice ? "lattice's" : "curve's") + " tools.")
                    return
                }
                if !refusedInSculptMode($0.displayName) { bridge?.perform(LastOperator.mesh($0, spinningAround: scene.active?.location, symmetry: scene.active?.symmetry)) }
            },
            // Blender adds at the 3D cursor and leaves the view where it is.
            // This used to re-frame the whole scene after every add.
            add: { kind in if !refusedInSculptMode("Add") { bridge?.perform(LastOperator.add(kind, at: scene.cursor)) } },
            objectTransform: objectTransform,
            setOrigin: setOrigin,
            applyTransform: applyTransform,
            objectRelations: objectRelations,
            showHide: showHide,
            separate: separate,
            shade: { setShading(smooth: $0) },
            perform: { op in if !refusedInSculptMode(op.name) { bridge?.perform(op) } },
            activeIsMesh: canEdit,
            essentialsLibrary: session.essentialsLibrary,
            frameAll: { camera.frameAll(scene.objects) },
            frameSelected: { camera.frameSelected(in: scene) },
            view: { camera.snap(to: $0) },
            lookThroughCamera: cameraToLookThrough == nil ? nil : { lookThroughCamera() },
            aimCameraAtView: cameraToLookThrough == nil ? nil : { aimCameraAtView() },
            togglePerspective: { camera.isOrthographic.toggle() },
            toggleWireframe: { shading = shading == .wireframe ? .solid : .wireframe },
            toggleXRay: { options.xray.toggle() },
            zoom: { camera.dolly(factor: $0) },
            undo: { session.performUndo() },
            redo: { session.performRedo() },
            showOutliner: { panel = "Scene" },
            showObjectDetails: { panel = "Object Details" },
            editTarget: canEditPoints ? (activeIsLattice ? "Lattice" : "Curve") : "Mesh")
    }

    /// Delete, Backspace or X — and More ▸ Delete Selected. Objects in object
    /// mode; while editing, the selected elements of the select mode in use.
    /// Whatever was tapped since Blender last reported its selection reaches
    /// Blender first, in the same evaluation.
    private func deleteSelected() {
        guard !refusedInSculptMode("Delete") else { return }
        guard let bridge, scene.active != nil else { return }
        if editingPoints {
            // Blender's lattice has no Delete: its points are its grid, and
            // the grid is its resolution.
            guard !activeIsLattice else {
                bridge.showReport("Delete", "A lattice's points cannot be deleted. Its resolution, "
                                  + "in the Data tab, sets how many there are.")
                return
            }
            runPoints(PointsBpy.delete(segments: false))
            return
        }
        bridge.run(Bpy.deleteSelection(editing: editing, mode: scene.selectMode), undo: "Delete")
    }

    /// Object ▸ Show/Hide, or Mesh ▸ Show/Hide while editing: H, Shift+H and
    /// Alt+H. What is hidden comes back through the mirror — hidden objects
    /// stay in the Outliner with their eye closed, hidden faces leave the
    /// viewport — and Show Hidden is where they return from.
    private func showHide(_ what: Bpy.ShowHide) {
        guard !refusedInSculptMode("Show/Hide") else { return }
        guard let bridge, !session.isRunning else { return }
        if editingPoints {
            guard !activeIsLattice else {
                bridge.showReport(what.label(editing: true), "A lattice's points cannot be hidden.")
                return
            }
            bridge.run(PointsBpy.showHide(what), undo: what.undoName(editing: true))
            return
        }
        bridge.run(Bpy.showHide(what, editing: editing), undo: what.undoName(editing: editing))
    }

    /// Mesh ▸ Separate. The new objects reach the Outliner and the viewport
    /// through the mirroring pass the command ends with, selected, as
    /// Blender leaves them.
    private func separate(_ type: Bpy.SeparateType) {
        guard let bridge, editing, !session.isRunning else { return }
        guard !editingPoints else {
            bridge.showReport("Separate", "Separate works on meshes here.")
            return
        }
        bridge.run(Bpy.separate(type), undo: "Separate")
    }

    /// Shade Smooth / Shade Flat, from the Object menu.
    private func setShading(smooth: Bool) {
        guard !refusedInSculptMode(smooth ? "Shade Smooth" : "Shade Flat") else { return }
        guard let bridge, scene.active != nil, !session.isRunning else { return }
        bridge.run(smooth ? Bpy.shadeSmooth : Bpy.shadeFlat,
                   undo: smooth ? "Shade Smooth" : "Shade Flat")
    }

    /// What Set Origin and Apply may do, and what they would do to.
    private var objectTransform: ObjectTransformState {
        ObjectTransformState(scene: scene, editing: editing, isRunning: session.isRunning)
    }

    /// What Duplicate Linked, Join, Parent and Convert may do. Sculpt Mode
    /// is left to `refusedInSculptMode`, which says why in words.
    private var objectRelations: ObjectRelationState {
        ObjectRelationState(scene: scene, editing: editing, isRunning: session.isRunning)
    }

    /// An Object menu row that runs an adjustable operator: Blender's own,
    /// through `perform`, refused in words in Sculpt Mode.
    private func performObjectRow(_ op: LastOperator) {
        guard !refusedInSculptMode(op.name) else { return }
        bridge?.perform(op)
    }

    /// Object ▸ Set Origin, through `BpyBridge.setOrigin` — the call the 3D
    /// View's Blender check makes, so what it runs is what this sends.
    private func setOrigin(_ choice: Bpy.OriginChoice) {
        guard !refusedInSculptMode("Set Origin") else { return }
        guard let bridge, !scene.selection.isEmpty, !session.isRunning else { return }
        bridge.setOrigin(choice)
    }

    /// Object ▸ Apply. Blender's Ctrl+A menu, which is where the fix for a
    /// modifier that came out lopsided lives.
    private func applyTransform(_ what: Bpy.AppliedTransform) {
        guard !refusedInSculptMode("Apply") else { return }
        guard let bridge, !scene.selection.isEmpty, !session.isRunning else { return }
        bridge.applyTransform(what)
    }

    /// Duplicate, which Blender has on Shift+D and this had nowhere at all.
    ///
    /// Modelling anything from parts means making the same part repeatedly —
    /// four wheels, two mirrors, a row of spikes. Without this each copy was a
    /// fresh primitive and nine numbers typed again, which is most of what
    /// building a car by hand cost. `duplicate_move` leaves the copy exactly
    /// on top of the original and selects it, so the next thing typed into
    /// Object Details moves the copy, not the original.
    ///
    /// In Edit Mode it is Blender's Edit Mode Shift+D: the selected elements,
    /// not the object. Elsewhere in Edit Mode (a curve's or a lattice's
    /// points) it is refused in words rather than copying the whole object.
    private func duplicateSelected() {
        guard !refusedInSculptMode("Duplicate") else { return }
        guard let bridge, let active = scene.active, !session.isRunning else { return }
        if editing {
            guard active.hasEditMode else {
                bridge.showReport("Duplicate", "Duplicate in Edit Mode copies mesh elements here, and "
                                  + "\(active.name) is not a mesh. Leave Edit Mode to duplicate the object.")
                return
            }
            bridge.run(Bpy.duplicateElements, undo: "Duplicate")
            return
        }
        bridge.run(Bpy.duplicate, undo: "Duplicate Objects")
    }

    /// Tab, from the viewport's own key command (see ViewportMTKView).
    private func toggleEditingFromKeyboard() {
        guard scene.active != nil, !session.isRunning else { return }
        toggleEditing()
    }

    /// Second names for Delete, as in Blender: X, and the forward-delete key.
    /// A menu item carries one shortcut, so these live here, invisible, and
    /// only while the keys are live.
    @ViewBuilder private var keyAliases: some View {
        if keysLive {
            ZStack {
                Button("Delete") { deleteSelected() }
                    .keyboardShortcut("x", modifiers: [])
                Button("Delete") { deleteSelected() }
                    .keyboardShortcut(.deleteForward, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .disabled(session.isRunning || scene.active == nil)
        }
    }

    // MARK: tool row

    /// One row: what the tools act on, the tool in hand, then what to do.
    ///
    /// The row is at least as wide as the screen, so Edit Mesh and More sit at
    /// its far end, and it scrolls when a narrow window cannot fit it.
    private var toolRow: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if editing { editingChip }
                    transformTools
                    Rectangle().fill(BTheme.outline).frame(width: 1, height: 24)
                    // Blender's header order between the tool buttons and the
                    // menus: the pivot point, the magnet, proportional editing.
                    pivotMenu
                    snapMenu
                    proportionalMenu
                    // Blender's mirror row: X, Y and Z, and Topology Mirror in
                    // its popover — in edit, sculpt and the paint modes, where
                    // its header draws them.
                    if showsSymmetry { symmetryControl }
                    Rectangle().fill(BTheme.outline).frame(width: 1, height: 24)
                    if editingPoints {
                        pointsMenus
                    } else if editing {
                        selectMenu
                        // The operations a mesh edit is mostly made of, one tap
                        // away; the rest are in the Mesh menu beside them.
                        ForEach([LastOperator.Mesh.extrude, .bevel, .inset, .subdivide], id: \.self) { op in
                            Button { bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location, symmetry: scene.active?.symmetry)) } label: {
                                Text(op.displayName)
                                    .padding(.horizontal, 10).frame(height: 40)
                                    .contentShape(Rectangle())
                            }
                        }
                        meshMenu
                    } else if sculptingInBlender {
                        // Blender's sculpt header: the mode, then the brush
                        // and its settings, then Dyntopo, Remesh, Multires,
                        // Mask and Face Sets. No Add or Mesh menu: Blender's
                        // Sculpt Mode has neither.
                        sculptMenu
                        SculptHeader(scene: scene, session: session, bridge: bridge)
                    } else {
                        if scene.mode == .object { selectMenu }
                        addMenu
                        meshMenu
                        sculptMenu
                        if scene.mode == .texturePaint { TexturePaintHeader(scene: scene, tool: tool) }
                        Button { panel = "Scene" } label: {
                            Label("Scene", systemImage: "square.3.layers.3d")
                                .padding(.horizontal, 10).frame(height: 40)
                                .contentShape(Rectangle())
                        }
                    }
                    Spacer(minLength: 8)
                    if !editing {
                        Button { setEditing(true) } label: {
                            Label(canEditPoints ? (activeIsLattice ? "Edit Lattice" : "Edit Curve") : "Edit Mesh",
                                  systemImage: "pencil")
                                .padding(.horizontal, 12).frame(height: 40)
                                .background(BTheme.widget)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(BTheme.outline, lineWidth: BTheme.Metric.hairline)
                                }
                                .opacity(canEdit || canEditPoints ? 1 : 0.4)
                        }
                        .disabled(!(canEdit || canEditPoints))
                    }
                    moreMenu
                }
                .padding(.horizontal, 12)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .frame(height: 56)
        .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
        .foregroundStyle(BTheme.text).background(BTheme.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BTheme.editorOutline).frame(height: BTheme.Metric.hairline)
        }
        .disabled(session.isRunning)
    }

    /// Edit Mode on a curve or a lattice: Blender's Select rows for its
    /// points, then its Curve menu (`VIEW3D_MT_edit_curve`, with the control
    /// point and segment rows) or its Lattice menu (`VIEW3D_MT_edit_lattice`).
    /// Each row is Blender's operator through the bridge, and a CANCELLED is
    /// said in words rather than read as done.
    @ViewBuilder private var pointsMenus: some View {
        Menu {
            Button("All") { bridge?.run(selectAllCommand("SELECT"), undo: "Select All") }
            Button("None") { bridge?.run(selectAllCommand("DESELECT"), undo: "Deselect") }
            Button("Invert") { bridge?.run(selectAllCommand("INVERT"), undo: "Invert Selection") }
            Divider()
            Text("Tap a point; a knot takes its handles. Shift adds.")
        } label: { menuLabel("Select", icon: "cursorarrow.rays") }
        if activeIsLattice {
            Menu {
                Button(PointsBpy.makeRegular.label) { runPoints(PointsBpy.makeRegular) }
                Menu("Flip") {
                    ForEach(["U", "V", "W"], id: \.self) { axis in
                        Button(axis) { runPoints(PointsBpy.flip(axis)) }
                    }
                }
                Divider()
                Text("Resolution U, V and W are in the Data tab")
            } label: { menuLabel("Lattice", icon: "grid") }
        } else {
            Menu {
                Button(PointsBpy.extrude.label) { runPoints(PointsBpy.extrude) }
                Menu("Subdivide") {
                    ForEach(1...4, id: \.self) { cuts in
                        Button(PointsBpy.subdivide(cuts: cuts).label) { runPoints(PointsBpy.subdivide(cuts: cuts)) }
                    }
                }
                Menu("Delete") {
                    Button(PointsBpy.delete(segments: false).label) { runPoints(PointsBpy.delete(segments: false)) }
                    Button(PointsBpy.delete(segments: true).label) { runPoints(PointsBpy.delete(segments: true)) }
                }
                Divider()
                Menu("Set Handle Type") {
                    ForEach(PointsBpy.handleTypes, id: \.identifier) { type in
                        Button(type.label) { runPoints(PointsBpy.handleType(type.identifier)) }
                    }
                }
                Button(PointsBpy.toggleCyclic.label) { runPoints(PointsBpy.toggleCyclic) }
                Button(PointsBpy.switchDirection.label) { runPoints(PointsBpy.switchDirection) }
                Divider()
                ForEach(Bpy.ShowHide.allCases, id: \.self) { what in
                    Button(what.label(editing: true)) { showHide(what) }
                }
            } label: { menuLabel("Curve", icon: ObjectAddition.CurveKind.bezier.icon) }
        }
    }

    /// "Editing Cylinder", what a tap picks in it, and the way out of it.
    private var editingChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(BTheme.active)
            Text("Editing \(scene.active?.name ?? "Mesh")").lineLimit(1)
            // Vertex, edge and face are a mesh's; a curve or a lattice has
            // points only.
            if !editingPoints { selectModeControl }
            Button { setEditing(false) } label: {
                Text("Done").font(BTheme.Font.ui(12))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 40)
        .background(BTheme.select.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(BTheme.select.opacity(0.55), lineWidth: 1)
        }
    }

    /// Vertex, edge or face — Blender's three header buttons in edit mode, and
    /// its 1, 2 and 3. A tap picks whichever of the three this says.
    private var selectModeControl: some View {
        HStack(spacing: 2) {
            ForEach(MeshSelectMode.allCases) { mode in
                Button { setSelectMode(mode) } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(scene.selectMode == mode ? Color.white : BTheme.text)
                        .frame(width: 30, height: 28)
                        .background(scene.selectMode == mode ? BTheme.select : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(mode.label) Select")
            }
        }
        .padding(2)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Select, Move, Rotate and Scale as one control, because only one of them
    /// is ever the tool: four separate buttons read as four things to do.
    private var transformTools: some View {
        HStack(spacing: 2) {
            // Select is a menu of Blender's four select tools: a tap, and the
            // three drags that select more than one thing at a time — a box, a
            // painted circle, a lasso. All, None and Invert moved to the
            // Select menu, where Blender has them.
            Menu {
                Button { choose(.select) } label: {
                    Label("Tap to Select", systemImage: tool == .select ? "checkmark" : ActiveTool.select.icon)
                }
                Button { choose(.boxSelect) } label: {
                    Label("Drag a Box", systemImage: tool == .boxSelect ? "checkmark" : ActiveTool.boxSelect.icon)
                }
                Button { choose(.circleSelect) } label: {
                    Label("Paint with a Circle",
                          systemImage: tool == .circleSelect ? "checkmark" : ActiveTool.circleSelect.icon)
                }
                Button { choose(.lassoSelect) } label: {
                    Label("Draw a Lasso", systemImage: tool == .lassoSelect ? "checkmark" : ActiveTool.lassoSelect.icon)
                }
                // The tool's mode, Blender's header buttons: Circle has three.
                if tool.isRegionSelect {
                    let circle = tool == .circleSelect
                    let current = regionAction.forRegion(circle: circle)
                    Menu("Mode: \(current.label)") {
                        ForEach(SelectAction.regionModes(circle: circle)) { mode in
                            Button { regionAction = mode } label: {
                                Label(mode.label, systemImage: current == mode ? "checkmark" : mode.icon)
                            }
                        }
                    }
                }
                // Blender's tool setting for Select Circle, shown with it.
                if tool == .circleSelect {
                    Menu("Circle Radius: \(Int(circleRadius)) pt") {
                        ForEach([10, 25, 50, 100] as [CGFloat], id: \.self) { r in
                            Button { circleRadius = r } label: {
                                Label("\(Int(r)) pt", systemImage: circleRadius == r ? "checkmark" : "")
                            }
                        }
                    }
                }
                Divider()
                Text("Shift adds, Ctrl or ⌘ takes away, both intersect (Box and Lasso). "
                     + "X-Ray (View Style) selects what the surface hides.")
            } label: {
                segment(tool.isRegionSelect ? tool.label : "Select",
                        icon: tool.isRegionSelect ? tool.icon : ActiveTool.select.icon,
                        active: tool == .select || tool.isRegionSelect)
            }
            ForEach([ActiveTool.move, .rotate, .scale], id: \.self) { item in
                Button { choose(item) } label: {
                    segment(item.label, icon: item.icon, active: tool == item)
                }
            }
        }
        .padding(2)
        .frame(height: 40)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(BTheme.outline, lineWidth: BTheme.Metric.hairline)
        }
    }

    private func segment(_ title: String, icon: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(active ? Color.white : BTheme.text)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(active ? BTheme.select : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }

    private func menuLabel(_ title: String, icon: String, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.55)
        }
        .foregroundStyle(active ? Color.white : BTheme.text)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(active ? BTheme.select : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Adds at the 3D cursor, and leaves the view alone, as Blender does.
    private var addMenu: some View {
        Menu {
            ForEach(PrimitiveKind.allCases) { kind in
                Button(kind.displayName, systemImage: kind.icon) {
                    bridge?.perform(LastOperator.add(kind, at: scene.cursor))
                }
            }
            ObjectAddItems { bridge?.add($0, at: scene.cursor, view: camera) }
            Divider()
            Button("Image to 3D Model…", systemImage: "photo.artframe") { panel = "Image to 3D Model" }
        } label: { menuLabel("Add", icon: "plus") }
    }

    /// Every mesh operator Blender can perform here, in one menu. They are
    /// actions rather than modes — you press Bevel, it bevels, and the panel
    /// that appears is where the width gets chosen. Nothing to switch into
    /// first.
    private var meshMenu: some View {
        Menu {
            // Grouped as Blender groups them. Forty-odd operators in one
            // flat column is a column nobody reads to the bottom of.
            ForEach(LastOperator.Mesh.Group.allCases, id: \.self) { group in
                Menu(group.rawValue) {
                    ForEach(LastOperator.Mesh.allCases.filter { $0.group == group }, id: \.self) { op in
                        Button(op.menuLabel) {
                            bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location, symmetry: scene.active?.symmetry))
                        }
                        // A selection or an edge flag is all these change,
                        // and only Edit Mode shows either (`editModeOnly`).
                        .disabled(op.editModeOnly && !editing)
                    }
                    if group == .cut { knifeProjectMenu }
                    if group == .deform { shearRow }
                }
            }
            if editing {
                // Where Blender's edit-mode Mesh menu has them: Separate
                // after Split, Show/Hide near the end.
                Divider()
                SeparateMenu(run: separate)
                ShowHideMenu(editing: true, run: showHide)
            }
        } label: { menuLabel("Mesh", icon: "cube.transparent") }
        // Every one of these needs edit mode, which a light does not have.
        .disabled(!canEdit)
    }

    /// Blender's Mesh ▸ Transform ▸ Shear, through the startup screen's 3D
    /// View its poll wants (`LastOperator.shear`), and in Object Mode its
    /// Object ▸ Transform ▸ Shear, which moves the selected objects
    /// (`LastOperator.shearObjects`; measured in 5.2.1, cubes at y = ±2 went
    /// ∓0.728 in x at 20°). It was greyed out in Object Mode on a check that
    /// could not move anything. The simulator's stand-in has no 3D View to
    /// borrow.
    @ViewBuilder private var shearRow: some View {
        if session.usesRealBlender {
            Button("Shear") { bridge?.perform(editing ? LastOperator.shear() : LastOperator.shearObjects()) }
        } else {
            Button("Shear") {}.disabled(true)
            Text("Shear needs Blender: the simulator's stand-in has no 3D View")
        }
    }

    /// Knife Project cuts with another object's outline, so it is a list of
    /// the objects it could cut with, picked by name as a Boolean's target
    /// is. Curves and text cut as well as meshes do (measured in 5.2.1: a
    /// Bezier circle and the default text both cut a plane); the cut goes
    /// along the one picked's normal, toward the mesh being edited.
    ///
    /// The list is the mirror's, which now carries objects with no faces: the
    /// default Add ▸ Circle is a wire of 32 edges, and until the mirror sent
    /// edges it never reached this list at all — the most common cutter there
    /// is. In the simulator the stand-in for Blender has no 3D View to cut
    /// through, so the menu says that rather than list cutters that all fail.
    private var knifeProjectMenu: some View {
        let cutters = scene.knifeProjectCutters
        return Menu("Knife Project") {
            if !session.usesRealBlender {
                Text("Needs Blender: the simulator's stand-in cannot cut")
            } else {
                if cutters.isEmpty {
                    // What the Add menu can make that has an outline.
                    Text("Add a curve, a circle, a plane or text to cut with")
                }
                ForEach(cutters, id: \.id) { cutter in
                    Button(cutter.name) {
                        bridge?.perform(LastOperator.knifeProject(cutter: cutter.name))
                    }
                }
            }
        }
    }

    /// Sculpting and painting need their own mode, so picking a brush puts
    /// the app there. That is the whole of the mode system as far as the
    /// reader is concerned — and the brush in hand shows on this button.
    ///
    /// With the real Blender, Sculpt Mode is one entry: Blender's own mode,
    /// whose brushes are Blender's Essentials, picked in the header it brings
    /// up. The six Swift brushes are the simulator's alone, and say they are
    /// an approximation there.
    private var sculptMenu: some View {
        Menu {
            if session.usesRealBlender {
                Section("Sculpt") {
                    if scene.mode == .sculpt {
                        Button("Leave Sculpt Mode", systemImage: "arrow.uturn.backward") { choose(.select) }
                    } else {
                        Button("Sculpt Mode", systemImage: InteractionMode.sculpt.icon) { choose(.sculptDraw) }
                    }
                }
            }
            ForEach(ActiveTool.combined, id: \.title) { section in
                if (section.title == "Sculpt" && !session.usesRealBlender) || section.title == "Paint" {
                    Section(section.title == "Sculpt" ? "Sculpt — an approximation of Blender's brushes" : section.title) {
                        ForEach(section.tools.filter(\.isImplemented), id: \.self) { t in
                            Button(t.label, systemImage: t.icon) { choose(t) }
                        }
                    }
                }
            }
        } label: {
            menuLabel(sculptingInBlender ? (scene.sculptBlender?.brush ?? "Sculpt")
                      : brushActive ? tool.label : "Sculpt",
                      icon: sculptingInBlender ? InteractionMode.sculpt.icon
                      : brushActive ? tool.icon : "paintbrush.pointed",
                      active: brushActive || sculptingInBlender)
        }
        // Sculpting and painting are mesh modes too.
        .disabled(!canEdit)
    }

    /// The camera these two act on: the scene's, or the only one there is, or
    /// the selected one.
    private var cameraToLookThrough: BKObject? {
        if let active = scene.active, case .camera = active.overlayDisplay { return active }
        return scene.sceneCamera ?? scene.cameras.first
    }

    private func lookThroughCamera(_ chosen: BKObject? = nil) {
        guard let object = chosen ?? cameraToLookThrough,
              case .camera(let display)? = object.overlayDisplay else { return }
        guard camera.look(through: object) else { return }
        let aspect = CGFloat(max(display.aspectX, 1) / max(display.aspectY, 1))
        cameraView = (aspect, camera, "\(object.name) · \(Int(display.aspectX)) × \(Int(display.aspectY))")
        session.note("Looking through \(object.name). Move the view to leave it.")
    }

    private func aimCameraAtView() {
        guard let object = cameraToLookThrough, let bridge else { return }
        _ = bridge.run(Bpy.alignCameraToView(object.name, camera.renderCamera),
                       undo: "Aim Camera at View")
    }

    // MARK: snapping, the pivot point and proportional editing
    //
    // All three are Blender's `scene.tool_settings`, mirrored onto
    // `scene.tools` after every command (TransformTools.swift). Every item
    // below is one `bridge.run` and reads its state back from the scene, so a
    // menu shows what Blender holds — including after a script changed it.
    // None carries an undo label: Blender pushes no undo step for a setting
    // either.

    private var pivotMenu: some View {
        Menu {
            ForEach(TransformPivot.allCases) { value in
                Button {
                    bridge?.run(ToolsBpy.pivot(value))
                } label: {
                    Label(value.label,
                          systemImage: scene.tools.pivot == value ? "checkmark" : value.icon)
                }
            }
        } label: {
            // Lit when the pivot is not Blender's default, which is the one
            // thing the closed control can usefully say.
            menuLabel("Pivot", icon: scene.tools.pivot.icon,
                      active: scene.tools.pivot != .medianPoint)
        }
    }

    private var snapMenu: some View {
        Menu {
            Toggle("Snap", isOn: Binding(get: { scene.tools.useSnap },
                                         set: { bridge?.run(ToolsBpy.useSnap($0)) }))
            Section("Snap To") {
                ForEach(SnapElement.allCases) { element in
                    let on = scene.tools.elements.contains(element)
                    Button {
                        var next = scene.tools.elements
                        if next.contains(element) { next.remove(element) } else { next.insert(element) }
                        bridge?.run(ToolsBpy.elements(next))
                    } label: {
                        Label(element.label, systemImage: on ? "checkmark" : "")
                    }
                    // Blender keeps at least one: assigning set() leaves the
                    // value as it was (measured in 5.2.1).
                    .disabled(on && scene.tools.elements.count == 1)
                }
                ForEach(SnapElementIndividual.allCases) { element in
                    Button {
                        var next = scene.tools.individual
                        if next.contains(element) { next.remove(element) } else { next.insert(element) }
                        bridge?.run(ToolsBpy.individual(next))
                    } label: {
                        Label(element.label,
                              systemImage: scene.tools.individual.contains(element) ? "checkmark" : "")
                    }
                }
            }
            Section("Snap With") {
                ForEach(SnapTarget.allCases) { value in
                    Button {
                        bridge?.run(ToolsBpy.target(value))
                    } label: {
                        Label(value.label,
                              systemImage: scene.tools.target == value ? "checkmark" : "")
                    }
                }
            }
        } label: {
            // Lit when a drag will snap: the magnet on and an element a drag
            // honours chosen (`snapsDrag`). Lit on the magnet alone, it said
            // snapping was on with only Volume chosen, which no drag uses.
            menuLabel("Snap", icon: "magnet", active: scene.tools.snapsDrag)
        }
    }

    // MARK: mesh symmetry
    //
    // The mesh's own `use_mirror_x/y/z` and `use_mirror_topology`, which
    // Blender's edit, sculpt and paint headers all write. Each button is one
    // `bridge.run` of `SymmetryBpy` and is lit from `scene.active.symmetry`,
    // which only the mirror writes — so it shows what Blender holds, after a
    // script or a file load too. What the flags do here: an edit-mode drag
    // mirrors its preview and sends `mirror=True` (SymmetricEdit,
    // TransformGizmo.python), the Mesh menu's transforms send it too
    // (`LastOperator.Mesh.honoursMeshSymmetry`), Blender's own sculpt brushes
    // and Smooth Vertices read the flags themselves, and the texture and
    // vertex paint strokes repeat across them.

    private var showsSymmetry: Bool {
        scene.mode != .object && scene.active?.blenderType == "MESH"
    }

    /// Flips one of the mesh's flags on the object the control shows, with an
    /// undo step where Blender's undo would restore it (`SymmetryBpy.undoLabel`).
    private func toggleSymmetry(_ flag: SymmetryBpy.Flag) {
        guard let obj = scene.active else { return }
        bridge?.run(SymmetryBpy.set(flag, !flag.isOn(in: obj.symmetry), objectNamed: obj.name),
                    undo: SymmetryBpy.undoLabel(flag, mode: scene.mode))
    }

    private var symmetryControl: some View {
        let symmetry = scene.active?.symmetry ?? MeshSymmetry()
        return HStack(spacing: 2) {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.system(size: 12))
                .foregroundStyle(symmetry.isOn ? BTheme.active : BTheme.textDim)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)
            ForEach([SymmetryBpy.Flag.x, .y, .z]) { flag in
                let on = flag.isOn(in: symmetry)
                Button { toggleSymmetry(flag) } label: {
                    Text(flag.label)
                        .foregroundStyle(on ? Color.white : BTheme.text)
                        .frame(width: 32, height: 36)
                        .background(on ? BTheme.select : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Mirror \(flag.label)")
                .accessibilityValue(on ? "On" : "Off")
            }
            if SymmetryBpy.offersTopology(in: scene.mode) {
                Menu {
                    Toggle(SymmetryBpy.Flag.topology.label,
                           isOn: Binding(get: { symmetry.topology }, set: { _ in toggleSymmetry(.topology) }))
                    Text("Pairs vertices by the mesh's edges rather than their places, "
                         + "for two halves with the same topology and no longer the same shape.")
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(symmetry.topology ? BTheme.active : BTheme.text)
                        .frame(width: 22, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Mirror Options")
            }
        }
        .padding(2)
        .frame(height: 40)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(BTheme.outline, lineWidth: BTheme.Metric.hairline)
        }
    }

    private var proportionalMenu: some View {
        let on = scene.tools.isProportional(editing: editing)
        return Menu {
            Toggle("Proportional Editing",
                   isOn: Binding(get: { on },
                                 set: { bridge?.run(ToolsBpy.proportional($0, editing: editing)) }))
            Menu("Falloff") {
                ForEach(MeshEditor.ProportionalFalloff.allCases) { value in
                    Button {
                        bridge?.run(ToolsBpy.falloff(value))
                    } label: {
                        Label(value.label,
                              systemImage: scene.tools.falloff == value ? "checkmark" : "")
                    }
                }
            }
            // A menu on iOS holds controls, not fields, so the header offers
            // the sizes a drag actually wants; Transform Tools has the field
            // for an exact one.
            Menu("Size") {
                ForEach(Self.proportionalSizes, id: \.self) { value in
                    Button {
                        bridge?.run(ToolsBpy.size(value))
                    } label: {
                        Label(String(format: "%g m", value),
                              systemImage: abs(scene.tools.size - value) < 1e-4 ? "checkmark" : "")
                    }
                }
            }
            Toggle("Connected Only",
                   isOn: Binding(get: { scene.tools.connected },
                                 set: { bridge?.run(ToolsBpy.connected($0)) }))
        } label: {
            menuLabel("Proportional", icon: "circle.dashed", active: on)
        }
    }

    /// The sizes Blender's own slider lands on most often. The field in
    /// Transform Tools takes anything in `TransformToolSettings.sizeRange`.
    private static let proportionalSizes: [Float] = [0.25, 0.5, 1, 2, 5, 10]

    /// Blender's Shift+S menu (VIEW3D_MT_snap), in 5.2.1's order — the four
    /// Selection actions, a separator, the four Cursor ones (SnapAction).
    /// These do move things, so each is an undo step.
    private var snapActionsMenu: some View {
        Menu("Snap") {
            ForEach(SnapAction.allCases) { action in
                if action == SnapAction.allCases.first(where: \.movesCursor) { Divider() }
                Button(action.title) {
                    bridge?.run(ToolsBpy.snap(action, increment: options.snapIncrement),
                                undo: action.undoName)
                }
                .disabled(!action.isOffered(in: scene))
            }
        }
    }

    /// What is left once the tools, Undo and Edit Mesh have their own places.
    private var moreMenu: some View {
        Menu {
            Button("Frame All", systemImage: "viewfinder") { camera.frameAll(scene.objects) }
            Button("Frame Selected", systemImage: "scope") { camera.frameSelected(in: scene) }
            // What a render will show, without rendering it: Blender's
            // numpad 0 and its Align Active Camera to View.
            Button("Look Through Camera", systemImage: "video") { lookThroughCamera() }
                .disabled(cameraToLookThrough == nil)
            Button("Aim Camera at This View", systemImage: "camera.metering.center.weighted") {
                aimCameraAtView()
            }.disabled(cameraToLookThrough == nil)
            Menu("View Style") {
                ForEach(ViewportShading.allCases) { value in
                    Button(value.rawValue) { shading = value }.disabled(!value.isImplemented)
                }
                Divider()
                // Blender's X-Ray: the surface drawn see-through, and the
                // select tools taking what it hides, as Blender's do.
                Toggle("X-Ray", isOn: $options.xray)
            }
            Divider()
            Button("Object Details") { panel = "Object Details" }
            Toggle("Timeline", isOn: Bindable(scene).animation.showsTimeline)
            Button("Render") { panel = "Render" }
            Button("All Blender Tools") { showOperations = true }
            Divider()
            // Blender has these on the Object menu and on the right-click
            // menu. They were reachable only from a script, and they are the
            // difference between a subdivided surface that reads as a shape
            // and one that reads as facets — which is most of what makes a
            // model built from primitives look unfinished.
            snapActionsMenu
            Button("Transform Tools") { panel = "Transform Tools" }
            Divider()
            ShadingItems(meshInObjectMode: canEdit && !editing && !session.isRunning,
                         hasObject: scene.active != nil && !session.isRunning,
                         essentialsLibrary: session.essentialsLibrary,
                         shade: { setShading(smooth: $0) },
                         perform: { op in if !refusedInSculptMode(op.name) { bridge?.perform(op) } })
            // Blender keeps it under Object Data ▸ Remesh; it is an operator
            // on the whole object, so it sits with the other ones here.
            Button("QuadriFlow Remesh") { bridge?.perform(LastOperator.quadriflowRemesh()) }
                .disabled(!canEdit || editing || session.isRunning)
            // The other two object-level operations Blender keeps on this
            // menu, above the destructive ones.
            ObjectTransformItems(state: objectTransform,
                                 setOrigin: setOrigin, apply: applyTransform)
            Divider()
            // Blender's Object menu order: Duplicate Objects, Duplicate
            // Linked and Join, then Parent and Convert further down.
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicateSelected() }
                .keyboardShortcut("d", modifiers: .shift)   // Blender's Shift+D
                .disabled(scene.active == nil || session.isRunning)
            ObjectRelationItems(state: objectRelations, perform: performObjectRow)
            Divider()
            // Blender's Object ▸ Show/Hide, or the Mesh menu's while editing.
            ShowHideMenu(editing: editing, run: showHide)
                .disabled(scene.objects.isEmpty || session.isRunning)
            Button("Delete Selected", role: .destructive) {
                deleteSelected()
            }.disabled(scene.active == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

enum BottomPanel: String, CaseIterable, Identifiable {
    case timeline, shading, render
    var id: String { rawValue }
    var title: String {
        switch self {
        case .timeline: return "Timeline"
        case .shading:  return "Shading"
        case .render:   return "Render"
        }
    }
    var icon: String {
        switch self {
        case .timeline: return "timeline.selection"
        case .shading:  return "circle.righthalf.filled"
        case .render:   return "photo"
        }
    }
}
