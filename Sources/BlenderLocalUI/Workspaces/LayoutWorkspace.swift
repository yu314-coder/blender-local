import SwiftUI
import ImageIO
import Metal
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
    /// What a finger's tap does while editing a mesh: one of Blender's pick
    /// selections (Loop Select, Edge Ring Select, Pick Shortest Path, Select
    /// Linked), set from the Select menu or the pick bar, or nil for an
    /// ordinary select. A pointer's Alt, Ctrl+Alt and Ctrl make them anyway.
    @State private var pick: SelectPick?
    /// Blender's Shift variant of `pick`, for a finger.
    @State private var pickShift = false
    /// Select ▸ Select Pattern…, asking for the pattern.
    @State private var askingPattern = false
    @State private var pattern = "*"
    @State private var panel: String?
    /// Blender's Sidebar (View ▸ Sidebar, N): Item, Tool and View down the
    /// right edge of the 3D View. It existed (SidebarN) and nothing showed it,
    /// so Edit Mode had nowhere to type a vertex's position (round 3's
    /// review, toolkit item 3).
    @State private var showsSidebar = false
    /// More's panel (`morePanel`) is open.
    @State private var showsMore = false
    /// The Transform panel (`transformPanel`) is open.
    @State private var showsTransform = false
    /// The Outliner and the Properties editor beside the 3D View
    /// (`editorsDock`), open as Blender opens them; kept across launches.
    @AppStorage("bl_editors_shown") private var showsEditors = true
    /// The header's width, its content's, and whether it is scrolled to its
    /// end (`headerRow`).
    @State private var headerWidth: CGFloat = 1_000
    @State private var headerContentWidth: CGFloat = 0
    @State private var headerScrolledToEnd = false
    /// Set by Look Through Camera: the frame the render will take, and the
    /// view it was set from. The guide is drawn while the view has not moved.
    @State private var cameraView: (aspect: CGFloat, camera: ViewportCamera, name: String)?
    @State private var showOperations = false
    /// Blender's pop-up menu open at the pointer — a right-click's context
    /// menu, Shift+A's Add, M's Move to Collection (ViewportMenus.swift).
    @State private var popupMenu: PopupMenuModel?
    /// Where the 3D View sits in the workspace, which the menu is placed in.
    @State private var viewportOrigin: CGPoint = .zero
    /// F2's Rename Active Object… prompt.
    @State private var renaming = false
    @State private var renameText = ""
    /// View ▸ Toolbar, Blender's T.
    @AppStorage("bl_toolbar_shown") private var showsToolbar = true
    /// What Ctrl+Space's Toggle Maximize Area put away, to bring back.
    @State private var maximizedFrom: (editors: Bool, sidebar: Bool, toolbar: Bool)?
    /// The redo panel's own setting, which F9 opens.
    @AppStorage("bl_redo_expanded") private var redoExpanded = false
    /// How much of the editors' dock the Outliner takes, set by dragging the
    /// line between it and the Properties editor, as Blender resizes areas.
    @AppStorage("bl_outliner_share") private var outlinerShare = 0.4
    /// The share as the drag started.
    @State private var outlinerShareAtDrag: Double?
    @State private var catalogue = OperatorCatalogue()
    /// The failure on screen, until it times out or is tapped away.
    @State private var shownReport: BpyBridge.Report?
    /// Move or Link to New Collection's name prompt: the collection the new
    /// one goes inside, and whether the selection is linked rather than moved.
    @State private var newCollection: (parent: Int, link: Bool)?
    /// The 3D View's size, for Local View's framing, which fits the
    /// narrower side as Blender's does.
    @State private var viewportSize = CGSize(width: 4, height: 3)
    /// What Edit Mode's overlays were last read for (`measureChanged`).
    @State private var measuredFor: MeasureKey?
    @State private var newCollectionName = ""
    /// Add ▸ Image's Reference... or Background..., asking for its picture.
    @State private var imageRequest: ReferenceImages.Kind?
    /// The text object whose Body Text Tab opened (round 4, group 8).
    @State private var bodyTextObject: BKObject?
    /// The view and the camera view Local View was entered from, put back on
    /// the way out as Blender puts back the view it kept (`localvd`).
    /// The Sidebar's Global / Local (SidebarN's `bl_sidebar_item_local`):
    /// Blender's V3D_GLOBAL_STATS, which its Edge Length, Face Area and the
    /// angles read too.
    @AppStorage("bl_sidebar_item_local") private var measureLocal = true
    @State private var beforeLocalView: (camera: ViewportCamera,
                                         cameraView: (aspect: CGFloat, camera: ViewportCamera, name: String)?)?

    /// Picks a tool, and takes the view to the mode it needs.
    ///
    /// The reader never picks a mode. A sculpt brush can only mean sculpting,
    /// so choosing one says so; and choosing Select, Box or a transform after a
    /// brush can only mean leaving it, which is Blender's Object Mode. Before
    /// that second half, Move lit up after a brush while every drag still
    /// pushed the mesh around.
    ///
    /// Texture Paint is the app's own mode, on top of Blender's Object Mode:
    /// its brush works on the viewport's images and each finished stroke is
    /// written into Blender's. Weight Paint and Vertex Paint are Blender's own
    /// with the real Blender (`enterPaintMode`, `_blenderkit_vwpaint`): they
    /// were the app's too, and their strokes never reached Blender (round 3's
    /// review).
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
        // Object Mode and Edit Mode only (`InteractionMode.isOffered`): a
        // brush needs a mode the app does not offer.
        if let needed = t.requiredMode, !needed.isOffered { return }
        if let next = t.mode(whenChosenFrom: scene.mode) {
            if next == .sculpt, session.usesRealBlender {
                bridge?.run(SculptBpy.enter, undo: SculptBpy.modeUndo)
            } else if PaintModeBpy.modes.contains(next), session.usesRealBlender {
                enterPaintMode(next)
            } else if next.isBrushMode {
                // Out of Blender's edit mode first, as its own Sculpt Mode
                // leaves it. Out of its Sculpt Mode, Weight Paint or Vertex
                // Paint too, for Texture Paint, which is the app's own.
                if editing { bridge?.run(Bpy.setMode(.object), undo: UndoStep.editMode) }
                if scene.mode == .sculpt, session.usesRealBlender {
                    bridge?.run(SculptBpy.leave, undo: SculptBpy.modeUndo)
                }
                if paintingInBlender {
                    bridge?.run(PaintModeBpy.leave, undo: PaintModeBpy.modeUndo(scene.mode))
                }
                scene.setMode(next)
            } else if scene.mode == .sculpt, session.usesRealBlender {
                bridge?.run(SculptBpy.leave, undo: SculptBpy.modeUndo)
            } else if paintingInBlender {
                bridge?.run(PaintModeBpy.leave, undo: PaintModeBpy.modeUndo(scene.mode))
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
        // In Blender's Weight Paint and Vertex Paint the toolbar's Brush,
        // Blur, Average and Smear are Blender's tools, each with its brush
        // (`_blenderkit_vwpaint.set_tool`).
        if let paintTool = PaintTool(t), paintingInBlender {
            bridge?.run(PaintModeBpy.setTool(paintTool))
            scene.paintBlender = bridge?.paintState()
        }
        tool = t
    }

    /// Blender's Weight Paint or Vertex Paint, as its mode menu's row enters
    /// it: one undo step named as Blender names it ("Weight Paint Mode"),
    /// refused in words for what Blender would enter and not paint. The
    /// mirror then reports Blender's mode, and the tool follows Blender's
    /// brush. Strokes there are Blender's (`_blenderkit_vwpaint`); the app's
    /// own paint modes used to paint its display cache and nothing reached
    /// Blender (round 3's review).
    private func enterPaintMode(_ mode: InteractionMode) {
        guard mode.isOffered else { return }
        if let held = session.gestureHold {
            bridge?.showReport(mode.label, held)
            return
        }
        // Texture Paint is the app's own, on top of Blender's Object Mode.
        if scene.mode == .texturePaint { scene.setMode(.object) }
        bridge?.run(PaintModeBpy.enter(mode), undo: PaintModeBpy.modeUndo(mode))
        guard scene.mode == mode else { return }
        scene.paintBlender = bridge?.paintState()
        tool = scene.paintBlender?.paintTool?.tool ?? .paintDraw
    }

    /// Blender's own Weight Paint or Vertex Paint, with the real Blender.
    private var paintingInBlender: Bool {
        (scene.mode == .weightPaint || scene.mode == .vertexPaint) && session.usesRealBlender
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

    /// The bar's Edit Mode and Object Mode: into and out of Blender's edit
    /// mode, as its mode menu's two rows do.
    private func setEditing(_ on: Bool) {
        if on, openBodyText() { return }
        bridge?.run(Bpy.setMode(on ? .edit : .object), undo: UndoStep.editMode)
    }

    /// Tab: toggles by Blender's own mode, read when the key is pressed.
    private func toggleEditing() {
        if !editing, openBodyText() { return }
        bridge?.run(Bpy.toggleEditMode, undo: UndoStep.editMode)
    }

    /// Edit Mode on a text object is typing its body. Blender's own Edit Mode
    /// keeps the typing in a buffer no Python can read back
    /// (_blenderkit_text.py), so Blender stays in Object Mode and the body is
    /// typed into its Body Text field, written to `data.body` when the edit
    /// ends. True when it opened.
    private func openBodyText() -> Bool {
        guard session.usesRealBlender, let active = scene.active, active.blenderType == "FONT",
              scene.mode == .object else { return false }
        bodyTextObject = active
        return true
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
            && popupMenu == nil && !renaming
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            // Blender's layout: the toolbar down the left edge, and the
            // Outliner over the Properties editor beside the 3D View — on the
            // right when the window is wider than tall, underneath when it is
            // taller, where a column would leave the view too narrow to model
            // in. Both stay open while the view is worked in; as sheets they
            // dimmed it and covered the object being edited. The toolbar runs
            // the full height, beside the editors too when they are
            // underneath: an upright iPad's view alone is too short for Edit
            // Mode's twelve buttons.
            HStack(spacing: 0) {
                if showsToolbar { toolShelf }
                GeometryReader { geo in
                    let wide = geo.size.width >= geo.size.height
                    let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        ZStack(alignment: .topTrailing) {
                            MetalViewportView(scene: scene, camera: $camera, tool: tool,
                                              shading: shading, options: options,
                                              circleRadius: circleRadius,
                                              regionAction: regionAction,
                                              pick: editing && !editingPoints ? pick : nil, pickShift: pickShift,
                                              bridge: bridge,
                                              onSelectionChange: { _ in },
                                              onTransform: { session.log($0) },
                                              onCommit: { name in if !session.usesRealBlender { undo.push(name, scene) } },
                                              onCycleTool: { choose(tool.next) },
                                              onToggleEditing: keysLive ? toggleEditingFromKeyboard : nil,
                                              onStrokeEnd: keepStroke,
                                              onSecondaryClick: keysLive ? { openMenu(.context, at: $0) } : nil,
                                              viewKeys: keysLive ? viewKeyCommands : nil)
                                .background(GeometryReader { geo in
                                    Color.clear
                                        .onAppear {
                                            viewportSize = geo.size
                                            viewportOrigin = geo.frame(in: .named(Self.space)).origin
                                        }
                                        .onChange(of: geo.size) { _, size in viewportSize = size }
                                        .onChange(of: geo.frame(in: .named(Self.space)).origin) { _, origin in
                                            viewportOrigin = origin
                                        }
                                })
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
                            // The Measure tool's rulers and Edit Mode's measurements
                            // (MeasureOverlay.swift).
                            MeasureOverlay(scene: scene, camera: camera, showsRulers: tool == .measure,
                                           overlays: options.measure, editingMesh: editingMesh)
                            // Loop Cut's and the Knife's bar; with any other tool while
                            // editing a mesh, the pick bar; the Cursor's and the Measure
                            // tool's settings; then the Statistics overlay's rows.
                            VStack(alignment: .leading, spacing: 0) {
                                HStack { cutToolBar; pickBar; cursorToolBar; measureToolBar; Spacer(minLength: 0) }
                                if options.measure.statistics, editingMesh, let stats = scene.editMeasurements?.statistics {
                                    StatisticsOverlay(statistics: stats)
                                        .padding(.leading, 14).padding(.top, 6)
                                }
                                // Fewer labels than Blender would draw, said in words.
                                if options.measure.measures, editingMesh, scene.transformReadout == nil,
                                   let note = scene.editMeasurements?.thinningNote {
                                    Text(note)
                                        .font(BTheme.Font.ui(11))
                                        .foregroundStyle(BTheme.text.opacity(0.9))
                                        .shadow(color: .black.opacity(0.6), radius: 1, y: 0.5)
                                        .frame(maxWidth: 420, alignment: .leading)
                                        .padding(.leading, 14).padding(.top, 6)
                                        .allowsHitTesting(false)
                                }
                                Spacer(minLength: 0)
                            }

                            // Blender's Sidebar, over the 3D View's right edge as
                            // Blender draws it, below Frame All and above the info row.
                            if showsSidebar {
                                SidebarN(scene: scene, session: session, bridge: bridge,
                                         camera: $camera, tool: tool,
                                         onClose: { showsSidebar = false })
                                    .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                                    .padding(.top, 70)
                                    .padding(.trailing, 8)
                                    .padding(.bottom, 54)
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
                            ViewportInfoRow(scene: scene)

                            if let report = shownReport {
                                reportBanner(report)
                            }
                        }.foregroundStyle(BTheme.text)
                        if showsEditors {
                            editorsDock(wide: wide, height: geo.size.height)
                                .frame(width: wide ? min(360, geo.size.width * 0.36) : nil,
                                       height: wide ? nil : geo.size.height * 0.42)
                        }
                    }
                }
            }
            AnimationDock(scene: scene, session: session, bridge: bridge)
        }
        .sheet(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
            NavigationStack {
                Group {
                    switch panel {
                    case "Tool Settings":
                        TransformToolsPanel(scene: scene, bridge: bridge,
                                            increment: $options.snapIncrement)
                    case "Animation": TimelineView(scene: scene, session: session)
                    case "Render": RenderingWorkspace(scene: scene, session: session, bridge: bridge, camera: $camera)
                    case "Image to 3D Model":
                        ImageToModelSheet(scene: scene, session: session, bridge: bridge) { panel = nil }
                    default: EmptyView()
                    }
                }
                .navigationTitle(panel ?? "")
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
        // panel can be photographed without tapping through a menu:
        // "Outliner", "Properties", "Tool Settings", "Render", "Image to 3D
        // Model".
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-panel"), i + 1 < args.count { show(args[i + 1]) }
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
        #if DEBUG
        // `-measure-overlays stats,length,eangle,area,fangle`: Viewport
        // Overlays' Statistics and Measurement switches, as the More menu
        // sets them, for `-measure-ops`.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-measure-overlays"), i + 1 < args.count {
                let on = Set(args[i + 1].split(separator: ",").map(String.init))
                options.measure = MeasureOverlays(statistics: on.contains("stats"), edgeLength: on.contains("length"),
                                                  edgeAngle: on.contains("eangle"), faceArea: on.contains("area"),
                                                  faceAngle: on.contains("fangle"))
            }
        }
        #endif
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
        // `mesh:<LastOperator.Mesh>` (with the menu's `meshPointer`),
        // `extrude-cursor` (Mesh ▸ Vertex ▸ Extrude to Cursor or Add),
        // `separate:<SELECTED|MATERIAL|LOOSE>` (Mesh ▸ Separate's rows),
        // `cursor:x;y;z` (the 3D cursor, as the Sidebar writes it), `py:<base64>` (a script line, as the
        // console runs it), `cap:<base64>` (what a script prints), `shear`, `adjust:key=value` (the redo
        // panel), `undo`, `redo`, `field:<location|rotation|scale>:<axis>=
        // <value>` (a Transform field of the active object), and, to read what
        // the screen says: `ax` (every accessibility label in the windows),
        // `steps` (Blender's undo history by name), `panel:<name>` and
        // `close` (a More-menu sheet: Outliner, Properties, Tool Settings,
        // Render), `search` (the Operator Search), `tool:<ActiveTool>`,
        // `paintmode:<weightPaint|vertexPaint>` (the mode menu's row),
        // `aim-camera` (Cameras ▸ Align Active Camera to View),
        // `normals` (the active mesh's shading normals against Blender's
        // corner normals), `view-stats` (the 3D View's own frame, measured)
        // and `render-stats` (the viewport drawn offscreen, measured), with
        // `winding:old` / `winding:blender` (the renderer's front face for a
        // mirrored object as it was, or as Blender flips it) and
        // `culling:old` / `culling:blender` (back faces culled as they were,
        // or both sides drawn as Blender's 3D View draws them) and
        // `shading:old` / `shading:blender` (every surface by its vertex
        // normals as before, or by Blender's face and corner normals).
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
                case "all":    bridge?.run(Bpy.selectAll(editing: editing), undo: SelectMenu.selectAllUndo)
                case "none":   bridge?.run(Bpy.deselectAll(editing: editing), undo: SelectMenu.selectAllUndo)
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
                    // Transform field of the active object, through the type
                    // the fields themselves run (`TransformFieldDrag`: its
                    // `change`, with Blender's preview of a field a constraint
                    // decides, then its `commit`), the preview printed beside
                    // where Blender then put the object and its children.
                    let spec = token.dropFirst("field:".count).split(separator: "=").map(String.init)
                    let path = spec.first?.split(separator: ":").map(String.init) ?? []
                    guard spec.count == 2, path.count == 2, let value = Float(spec[1]), let axis = Int(path[1]),
                          let group = TransformChannels.Group.allCases.first(where: { $0.title.lowercased() == path[0] }),
                          let obj = scene.active, let start = obj.shownChannels else {
                        said = "no field edit: no active object, no channels for it, or a malformed token"
                        break
                    }
                    let shown = start.values(group).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                    let drag = TransformFieldDrag()
                    drag.change(group, axis: axis, to: value, of: obj, in: scene, bridge: bridge)
                    let constrained = drag.constrainedPreview
                    let sent = drag.edit?.python
                    let moving = [obj] + scene.carried(by: [obj.id]).map(\.object)
                        + scene.objects.filter { !$0.constraints.isEmpty && $0.id != obj.id }
                    let previewed = moving.map { ($0, $0.modelMatrix.columns.3) }
                    // Mid-edit, as the bar's Undo would be: refused while
                    // Blender previews it (BpySession.constrainedDragOpen).
                    let hold = session.gestureHold ?? "no hold"
                    let outcome = drag.commit(group, bridge: bridge)
                    let worst = previewed.map { simd_distance($0.0.modelMatrix.columns.3, $0.1) }.max() ?? 0
                    let after = obj.shownChannels?.values(group).map { String(format: "%.4f", $0) }
                        .joined(separator: ", ") ?? "unknown"
                    let held = bridge?.capture("""
                        _o = bpy.data.objects[\(Bpy.quote(obj.name))]
                        print(tuple(round(c, 4) for c in _o.location), tuple(round(c, 4) for c in _o.matrix_world.translation))
                        """) ?? "?"
                    said = "\(group.title) showed (\(shown)); sent \(sent ?? "nothing"); "
                        + "\(outcome.map { $0.succeeded ? "succeeded" : "FAILED: \($0.error ?? "")" } ?? "not run"); "
                        + "now shows (\(after)); Blender location, world: \(held); "
                        + "preview vs Blender, worst of \(previewed.count) object(s): \(String(format: "%.6f", worst)) m"
                        + (constrained ? " (Blender previewed it: constrained; mid-edit hold: \(hold))" : "")
                        + "; hold after: \(session.gestureHold ?? "none")"
                case "undo":          session.performUndo()
                case "redo":          session.performRedo()
                // What the screen says: every accessibility label in the
                // windows, the bar's, the redo panel's and an open sheet's.
                case "ax":            AccessibilityDump.print("object-ops")
                // Blender's own undo history, by the names it shows.
                case "steps":
                    said = "Blender's undo steps: " + (bridge?.capture("""
                        import _blenderkit_undo as _bk_u
                        print([_r[2] + ('*' if _r[3] else '') for _r in (_bk_u.blender_steps() or [])][-14:])
                        """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
                // A More-menu sheet, as its row opens it, or none.
                case _ where token.hasPrefix("panel:"):
                    panel = String(token.dropFirst("panel:".count))
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                case "close":         panel = nil; showOperations = false
                // The Operator Search sheet, as More ▸ Operator Search opens it.
                case "search":        showOperations = true
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                // Blender's Weight Paint or Vertex Paint, as the mode menu's
                // row enters it (`enterPaintMode`).
                case _ where token.hasPrefix("paintmode:"):
                    guard let mode = InteractionMode(rawValue: String(token.dropFirst("paintmode:".count))),
                          PaintModeBpy.modes.contains(mode) else { said = "paintmode:weightPaint|vertexPaint"; break }
                    enterPaintMode(mode)
                    said = "Blender: \(bridge?.paintState().map { "\($0.mode ?? "OBJECT") \($0.brush ?? "no brush") tool \($0.tool ?? "?") size \($0.size ?? -1)" } ?? "?")"
                // Cameras ▸ Align Active Camera to View, as its row runs it,
                // then where the camera ended up in the world beside the view.
                case "aim-camera":
                    aimCameraAtView()
                    let view = camera.renderCamera
                    said = "the view: location \(view.location), rotation \(view.rotation); Blender: " + (bridge?.capture("""
                        _bk_c = bpy.context.scene.camera
                        if _bk_c is None:
                            print('no scene camera')
                        else:
                            bpy.context.view_layer.update()
                            _bk_m = _bk_c.matrix_world
                            print(_bk_c.name, _bk_c.rotation_mode, 'parent', _bk_c.parent.name if _bk_c.parent else '-',
                                  'world', tuple(round(v, 4) for v in _bk_m.translation),
                                  tuple(round(v, 4) for v in _bk_m.to_euler('XYZ')))
                        """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
                // The viewport's own drawing of the scene, offscreen at 400 x
                // 300 (the renderer's culling with each object's winding):
                // how much of the frame the scene covers and how bright, by a
                // 4 x 3 grid of cells, to compare two states by.
                // `view-stats`: the same for the 3D View's own frame (its
                // Solid pass, `captureFrame`), the overlays off so only the
                // surfaces count.
                case "render-stats", "view-stats":
                    let w = 400, h = 300
                    var frame: [UInt8]?
                    if token == "view-stats" {
                        if let device = MTLCreateSystemDefaultDevice(),
                           let renderer = ViewportRenderer(device: device, scene: scene, camera: camera) {
                            renderer.shading = shading
                            renderer.options.showOverlays = false
                            frame = renderer.captureFrame(points: CGSize(width: w, height: h), scale: 1,
                                                          clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))?.rgba
                        }
                    } else {
                        frame = OfflineRenderer.render(scene: scene, camera: camera, width: w, height: h)
                    }
                    if let bytes = frame {
                        var covered = 0
                        var cells = [Double](repeating: 0, count: 12), counts = [Int](repeating: 0, count: 12)
                        for y in 0..<h {
                            for x in 0..<w {
                                let i = (y * w + x) * 4
                                let lum = (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
                                guard lum > 20 else { continue }
                                covered += 1
                                let c = (y * 3 / h) * 4 + x * 4 / w
                                cells[c] += lum
                                counts[c] += 1
                            }
                        }
                        said = "covered \(covered) px; mean brightness by cell: " + (0..<12).map {
                            counts[$0] == 0 ? "-" : String(format: "%.1f", cells[$0] / Double(counts[$0]))
                        }.joined(separator: " ")
                        // Pixel by pixel against the last frame of this kind:
                        // a cell's mean hides a flat face drawn smooth.
                        let key = token
                        if let last = Self.lastStatsFrame[key], last.count == bytes.count {
                            var differ = 0, most = 0
                            for k in stride(from: 0, to: bytes.count, by: 4) {
                                let d = max(abs(Int(bytes[k]) - Int(last[k])), abs(Int(bytes[k + 1]) - Int(last[k + 1])),
                                            abs(Int(bytes[k + 2]) - Int(last[k + 2])))
                                if d > 8 { differ += 1 }
                                most = max(most, d)
                            }
                            said += "; against the last \(key): \(differ) px differ by more than 8 of 255, at most \(most)"
                        }
                        Self.lastStatsFrame[key] = bytes
                    } else {
                        said = "no render"
                    }
                // `winding:old` / `winding:blender`: the renderer's front face
                // for a mirrored object as it was (anticlockwise always), or
                // flipped as Blender flips it — the in-app negative control
                // for `render-stats` (`ViewportRenderer.frontFacing`).
                // Read by `BpyBridge.beginConstrainedDrag`: the path the
                // fields and the gizmo run.
                case "constrained-preview:off": BpyBridge.debugSkipConstrainedPreview = true
                case "constrained-preview:on":  BpyBridge.debugSkipConstrainedPreview = false
                case "winding:old":     ViewportRenderer.debugOldWinding = true
                case "winding:blender": ViewportRenderer.debugOldWinding = false
                // `culling:old` / `culling:blender`: the surface passes culling
                // back faces as they did, or drawing both sides as Blender's
                // 3D View does (`ViewportRenderer.surfaceCull`).
                // `shading:old` / `shading:blender`: every surface drawn by
                // its vertex normals, as before, or by Blender's face and
                // corner normals (`ViewportRenderer.drawSurface`).
                case "shading:old":     ViewportRenderer.debugVertexNormalsOnly = true
                case "shading:blender": ViewportRenderer.debugVertexNormalsOnly = false
                case "culling:old":     ViewportRenderer.debugCullBackFaces = true
                case "culling:blender": ViewportRenderer.debugCullBackFaces = false
                // A tool, as its button or menu row picks it (`choose`).
                case _ where token.hasPrefix("tool:"):
                    guard let t = ActiveTool(rawValue: String(token.dropFirst("tool:".count))) else {
                        said = "no such tool"; break
                    }
                    choose(t)
                case _ where token.hasPrefix("mesh:"):
                    guard let op = LastOperator.Mesh(rawValue: String(token.dropFirst("mesh:".count))) else {
                        print("[bk] object-ops \(token): no such Mesh row"); continue
                    }
                    bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location,
                                                      symmetry: scene.active?.symmetry, pointer: meshPointer))
                // Mesh ▸ Vertex ▸ Extrude to Cursor or Add, as its row runs it.
                case "extrude-cursor": extrudeToCursor()
                // Mesh ▸ Separate ▸ <SELECTED|MATERIAL|LOOSE>, as its row runs it.
                case _ where token.hasPrefix("separate:"):
                    guard let type = Bpy.SeparateType(rawValue: String(token.dropFirst("separate:".count))) else {
                        said = "separate:SELECTED|MATERIAL|LOOSE"; break
                    }
                    separate(type)
                // `py:<base64>`: a script line between rows (a selection to
                // set up, a file to save), as the console runs one, with an
                // undo step of its own so an Undo after the next row stops
                // there.
                case _ where token.hasPrefix("py:"):
                    guard let data = Data(base64Encoded: String(token.dropFirst("py:".count))),
                          let script = String(data: data, encoding: .utf8) else { said = "py:<base64>"; break }
                    let outcome = bridge?.run(script, undo: "Run Script")
                    said = outcome.map { $0.succeeded ? "ran" : "FAILED: \($0.error ?? "")" } ?? "no bridge"
                // `cap:<base64>`: what a script prints, read without a step —
                // Blender's own numbers to hold the app's against.
                case _ where token.hasPrefix("cap:"):
                    guard let data = Data(base64Encoded: String(token.dropFirst("cap:".count))),
                          let script = String(data: data, encoding: .utf8) else { said = "cap:<base64>"; break }
                    said = bridge?.capture(script)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                // `normals`: the normals the 3D View shades the active mesh
                // with (`MeshData.shadingNormal`), corner by corner, against
                // the corner normals Blender's Solid view draws, read from
                // Blender's evaluated mesh; and, as the control, the vertex
                // normals the 3D View drew before against the same.
                case "normals":
                    guard let obj = scene.active, let bridge else { said = "no active object"; break }
                    said = obj.shadingReport(bridge)
                // The 3D cursor, as the Sidebar's View tab writes it.
                case _ where token.hasPrefix("cursor:"):
                    let c = token.dropFirst("cursor:".count).split(separator: ";").compactMap { Float($0) }
                    guard c.count == 3 else { said = "cursor:x;y;z"; break }
                    bridge?.run(ToolsBpy.setCursor(SIMD3(c[0], c[1], c[2])))
                    said = "the cursor shows \(scene.cursor); the pointer: \(meshPointer.pythonArguments())"
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
                    if editing { bridge?.run(Bpy.setMode(.object), undo: UndoStep.editMode) }
                    // Weight Paint and Vertex Paint are Blender's own here, as
                    // the mode menu enters them; Texture Paint the app's.
                    if PaintModeBpy.modes.contains(next), session.usesRealBlender {
                        enterPaintMode(next)
                    } else {
                        scene.setMode(next)
                    }
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
                    // As endGizmo does, through the same call: rolled back,
                    // then performed — or nothing sent when the mirror leaves
                    // Blender nothing to transform.
                    TransformGizmo.rollBack(session)
                    let blenderBefore = blenderVertices(blenderSide())
                    if let bridge { TransformGizmo.commit(result, session: session, bridge: bridge) }
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
                case "all":    bridge.run(selectAllCommand("SELECT"), undo: SelectMenu.selectAllUndo)
                case "none":   bridge.run(selectAllCommand("DESELECT"), undo: SelectMenu.selectAllUndo)
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
                    let outcome = bridge.run(PointsBpy.set(pair[0], to: pair[1], object: object.name), undo: pair[0])
                    said = (outcome.succeeded ? "" : "FAILED \(outcome.error ?? ""); ")
                        + "settings now \(String(describing: object.dataSettings)); \(BudgetProbe.report(bridge))"
                case "lattice-mod":
                    // The Modifiers panel: Add Modifier ▸ Lattice, then its
                    // Object field, through the same two calls it makes.
                    guard parts.count == 3, let mesh = scene.objects.first(where: { $0.name == parts[1] }) else {
                        said = "lattice-mod:Mesh:Lattice"; break
                    }
                    bridge.select(Bpy.select(mesh.name))
                    bridge.run(Bpy.addModifier(.lattice, on: mesh.mesh), undo: UndoStep.addModifier)
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
        #if DEBUG
        // `-menu-ops a;b;…` drives Blender's menus and keys as the pointer
        // and the keyboard reach them (ViewportMenus.swift, ViewportKeymap.swift),
        // once the bridge is up and no script is running: `menu:<name>[@x,y]`
        // opens one at a point in the 3D View, `key:<chord>` presses a key as
        // the 3D View's own key command or a menu bar row would, `row:<a>/<b>`
        // runs the open menu's row (through its submenus), `close`, `wait:<s>`,
        // `py:<expression>` prints what Blender holds. Each step prints the
        // menu it left open.
        .task(id: bridge == nil) {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-menu-ops"), i + 1 < args.count, bridge != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            for token in args[i + 1].split(separator: ";").map(String.init) {
                await runMenuOp(token)
            }
            print("[bk] menu-ops: done"); fflush(stdout)
        }
        #endif
        .overlay {
            if let popupMenu {
                PopupMenuOverlay(model: popupMenu) { self.popupMenu = nil }
            }
        }
        .coordinateSpace(name: Self.space)
        .sheet(isPresented: $showOperations) {
            OperatorSearch(catalogue: catalogue, bridge: bridge, isPresented: $showOperations)
        }
        // F2, and the context menu's Rename Active Object…: Blender's name
        // panel (TOPBAR_PT_name), one field.
        .alert("Rename Active Object", isPresented: $renaming) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                if let name = scene.active?.name, !renameText.isEmpty, renameText != name {
                    bridge?.run(Bpy.rename(name, to: renameText), undo: "Rename")
                }
            }
            Button("Cancel", role: .cancel) {}
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
        // Blender's invoke for Move / Link to New Collection: a Name field
        // holding the name Blender would give it, and Create.
        .alert(newCollection?.link == true ? "Link to New Collection" : "Move to New Collection",
               isPresented: Binding(get: { newCollection != nil }, set: { if !$0 { newCollection = nil } })) {
            TextField("Name", text: $newCollectionName)
                .autocorrectionDisabled()
            Button("Create") {
                if let pending = newCollection {
                    bridge?.run(CollectionsBpy.move(to: pending.parent, link: pending.link,
                                                    newCollection: newCollectionName))
                }
                newCollection = nil
            }
            Button("Cancel", role: .cancel) { newCollection = nil }
        }
        .onChange(of: scene.localView) { before, after in localViewChanged(from: before, to: after) }
        .modifier(ReferenceImagePicker(request: $imageRequest) { kind, data, name in
            bridge?.addReferenceImage(kind, data: data, name: name, at: scene.cursor, view: camera)
        })
        .sheet(item: $bodyTextObject) { text in
            BodyTextSheet(scene: scene, bridge: bridge, object: text) { bodyTextObject = nil }
                .presentationDetents([.medium])
        }
        .focusedSceneValue(\.objectAddActions, keysLive ? ObjectAddActions(add: { bridge?.add($0, at: scene.cursor, view: camera) },
                                                                          addImage: session.usesRealBlender ? { imageRequest = $0 } : nil) : nil)
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
            leaveHiddenMode()
        }
        // A script that left Blender in a mode the app does not offer, once
        // it has finished.
        .onChange(of: session.isRunning) { _, running in if !running { leaveHiddenMode() } }
        // Loop Cut's ring and the Knife's path belong to the tool, the mode
        // and the object they were made with.
        .onChange(of: tool) { _, next in CutToolActions.keep(for: next, scene: scene) }
        .task(id: measureKey) { await measureChanged() }
        .onChange(of: scene.mode) { _, _ in CutToolActions.keep(for: tool, scene: scene) }
        .onChange(of: scene.activeID) { _, _ in CutToolActions.keep(for: tool, scene: scene) }
        .onChange(of: scene.mode) { _, mode in if mode == .texturePaint, let obj = scene.active { TexturePaintSetup.prepare(obj, scene: scene, bridge: bridge) } }
        // Entered from a script, it waited for the script to end.
        .onChange(of: session.isRunning) { _, running in
            if !running, scene.mode == .texturePaint, let obj = scene.active {
                TexturePaintSetup.prepare(obj, scene: scene, bridge: bridge)
            }
        }
        // Blender's orientation and its matrix, read back whenever what they
        // depend on may have moved: any command or undo (the revision), the
        // object selection a tap changes without one, the mode — and, for
        // Normal in Edit Mode, the viewport's edit selection, which the
        // bridge hands Blender first (`captureWithSelection`).
        // Keyed in a view of its own, so the frame in the key redraws that
        // view and not this screen at every frame of playback (KeyedRefresh).
        .background(KeyedRefresh(key: { orientationKey }, refresh: { refreshOrientation() }))
        // Test All Features' way to this view's own functions (`featureTestDoor`).
        .task(id: bridge == nil) { await FeatureTestDoor.hold(featureTestDoor) }
        #if DEBUG
        .task(id: bridge == nil) { await runTransformOps() }
        .task(id: bridge == nil) { await runRelationsOps() }
        #if DEBUG
        .task(id: bridge == nil) { await runTextImageOps() }
        #endif
        #endif
    }

    /// What Blender's orientation matrix may change with. The frame too: a
    /// frame change is a `capture` (TimelineDriver.setFrame), which moves no
    /// revision, and an animated rotation — the object's or its parent's —
    /// turns Local, Gimbal, Parent and Normal. Without it the gizmo kept the
    /// last frame's axes and committed them as `orient_matrix`, axes Blender
    /// no longer held (round 4's review of group 5).
    private struct OrientationKey: Equatable {
        var revision: Int
        var running: Bool
        var mode: InteractionMode
        var active: UUID?
        var selection: Set<UUID>
        var edit: [Set<Int>]
        var history: [EditElement]
        var activeFace: Int?
        var frame: Int
        var subframe: Float
    }

    private var orientationKey: OrientationKey {
        // Only Normal follows the edit selection; anything else would read
        // Blender again for every tap.
        let followsSelection = scene.orientation.type == .normal && scene.mode == .edit
        let followsFrame = scene.orientation.type?.followsObject ?? true
        let edit = scene.editSelection
        return OrientationKey(revision: session.backendRevision, running: session.isRunning,
                              mode: scene.mode, active: scene.activeID, selection: scene.selection,
                              edit: followsSelection ? [edit.vertices, edit.edges, edit.faces] : [],
                              history: followsSelection ? edit.history : [],
                              activeFace: followsSelection ? edit.activeFace : nil,
                              // Global, View and Cursor are the same at every
                              // frame: playing in them asks Blender nothing.
                              frame: followsFrame ? scene.frameCurrent : 0,
                              subframe: followsFrame ? scene.animation.subframe : 0)
    }

    private func refreshOrientation() {
        guard let bridge, session.usesRealBlender, !session.isRunning,
              let state = bridge.orientationState() else { return }
        if scene.orientation != state { scene.orientation = state }
    }

    /// The header's Orientation menu: Blender's slot, written through the
    /// bridge — a setting, so no undo step, as the pivot's and the snap's —
    /// and shown as Blender then holds it.
    private func setOrientation(_ value: TransformOrientation) {
        guard let bridge else { return }
        bridge.run(OrientationBpy.set(value))
        refreshOrientation()
    }

    // MARK: selecting

    /// A Select menu row: Blender's operator through the bridge, as one undo
    /// step — with its redo panel, for the edit-mode rows Blender gives one.
    /// What is selected afterwards is what the mirror reads back.
    private func select(_ command: SelectMenu.Command) {
        guard let bridge, !session.isRunning else { return }
        // In Local View every row takes only what Local View holds, as
        // Blender's do under its view: the bridge runs them there
        // (`LocalViewBpy.scoped`).
        // Where the 3D View looks, for Side of Active's View axis.
        let view = SelectMenu.ViewDirection(forward: simd_normalize(camera.target - camera.eye), up: camera.trueUp)
        // Blender's select mode, as the mirror read it back: Select Linked ▸
        // Linked (and Ctrl+L) start their Delimit from it, as Blender's do.
        switch command.action(editing: editing, view: view, selectMode: scene.selectMode) {
        case .run(let python, let undo): bridge.run(python, undo: undo)
        case .perform(let op):          bridge.perform(op)
        }
    }

    /// Blender's pick selections for a finger, over the view's top left
    /// while a mesh is being edited with anything but Loop Cut or the Knife:
    /// Select (an ordinary tap), then Loop Select, Edge Ring Select, Pick
    /// Shortest Path and Select Linked, each named as Blender names the
    /// operator, and the toggle for what Shift adds in Blender's keymap —
    /// to an ordinary click its Toggle Selection. The Select menu has the
    /// same rows.
    @ViewBuilder private var pickBar: some View {
        if editing, !editingPoints, tool != .loopCut, tool != .knife {
            HStack(spacing: 2) {
                pickSegment(nil, label: "Select", icon: "cursorarrow.click")
                ForEach(SelectPick.allCases, id: \.self) { item in
                    pickSegment(item, label: item.operatorName, icon: item.icon)
                }
                shiftToggle(pick?.shiftLabel ?? SelectPick.toggleLabel)
            }
            .padding(2)
            .background(BTheme.header.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BTheme.outline, lineWidth: BTheme.Metric.hairline))
            .padding(10)
        }
    }

    /// What Shift adds, for a finger: Blender's name for it.
    private func shiftToggle(_ label: String) -> some View {
        Button { pickShift.toggle() } label: {
            Text(label).font(BTheme.Font.ui(11))
                .foregroundStyle(pickShift ? Color.white : BTheme.text)
                .padding(.horizontal, 8).frame(height: 28)
                .background(pickShift ? BTheme.select : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(pickShift ? "On" : "Off")
    }

    private func pickSegment(_ item: SelectPick?, label: String, icon: String) -> some View {
        Button {
            // What Shift adds differs from pick to pick; a new pick starts
            // without it.
            if pick != item { pickShift = false }
            pick = item
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(pick == item ? Color.white : BTheme.text)
                .frame(width: 32, height: 28)
                .background(pick == item ? BTheme.select : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(pick == item ? "On" : "Off")
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
                bridge.run(Bpy.addModifier(kind, on: obj.mesh), undo: UndoStep.addModifier)
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
                            askPattern: { askingPattern = true },
                            pick: pick, pickShift: pickShift,
                            setPick: { if pick != $0 { pickShift = false }; pick = $0 },
                            setPickShift: { pickShift = $0 },
                            // As the 3D View is handed `pick` (`body`).
                            picks: editing && !editingPoints)
        } label: { menuLabel("Select", icon: "selection.pin.in.out") }
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
        undo.push(scene.sculpt.brush.label + " Brush", scene)
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
        if sculptingInBlender {
            bridge?.showReport(what, "Blender's Sculpt Mode has no \(what). Switch to Object Mode first.")
            return true
        }
        // Blender's Weight Paint and Vertex Paint headers have View and
        // Weights / Paint menus, and none of the object and mesh operations.
        if paintingInBlender {
            bridge?.showReport(what, "Blender's \(scene.mode.label) has no \(what). Switch to Object Mode first.")
            return true
        }
        return false
    }

    // MARK: keyboard

    /// Everything the 3D View's keys can do, published while it is on screen.
    /// The keys themselves are in KeyboardCommands.swift.
    private var viewportKeys: ViewportKeyActions {
        ViewportKeyActions(
            isRunning: session.isRunning,
            hasActiveObject: scene.active != nil,
            editing: editing,
            editingMesh: editing && !editingPoints,
            selectMode: scene.selectMode,
            // Held while a sculpt stroke is down, or points are being
            // dragged (BpySession.gestureHold).
            canUndo: session.gestureHold == nil
                && (session.usesRealBlender ? session.backendCanUndo : undo.canUndo),
            canRedo: session.gestureHold == nil
                && (session.usesRealBlender ? session.backendCanRedo : undo.canRedo),
            setTool: { choose($0) },
            knifeConfirm: tool == .knife && editing && scene.knifePath != nil
                ? { CutToolActions.knifeDone(scene: scene, camera: camera, bridge: bridge) } : nil,
            knifeCancel: tool == .knife && editing && scene.knifePath != nil
                ? { CutToolActions.knifeCancel(scene) } : nil,
            rulerRemove: tool == .measure && scene.activeRuler != nil ? { MeasureActions.remove(scene) } : nil,
            deleteSelected: deleteSelected,
            duplicate: { duplicateSelected() },
            selectAll: {
                bridge?.run(selectAllCommand("SELECT"), undo: SelectMenu.selectAllUndo)
            },
            deselectAll: {
                bridge?.run(selectAllCommand("DESELECT"), undo: SelectMenu.selectAllUndo)
            },
            invertSelection: {
                bridge?.run(selectAllCommand("INVERT"), undo: SelectMenu.selectAllUndo)
            },
            // Blender's L and Shift+L, under the pointer: the 3D View that
            // has the pointer answers (SelectPickInput.swift).
            selectLinkedPick: editing && !editingPoints ? { deselect in
                NotificationCenter.default.post(name: SelectPickKeys.linked, object: nil,
                                                userInfo: ["deselect": deselect])
            } : nil,
            selectRow: { select($0) },
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
                if !refusedInSculptMode($0.displayName) {
                    bridge?.perform(LastOperator.mesh($0, spinningAround: scene.active?.location,
                                                      symmetry: scene.active?.symmetry, pointer: meshPointer))
                }
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
            aimCameraAtView: cameraToAlign == nil ? nil : { aimCameraAtView() },
            togglePerspective: { camera.isOrthographic.toggle() },
            toggleWireframe: { shading = shading == .wireframe ? .solid : .wireframe },
            toggleXRay: { options.xray.toggle() },
            zoom: { camera.dolly(factor: $0) },
            undo: { session.performUndo() },
            redo: { session.performRedo() },
            showOutliner: { show("Outliner") },
            showProperties: { show("Properties") },
            sidebarShown: showsSidebar,
            toggleSidebar: { showsSidebar.toggle() },
            collections: scene.collections,
            run: { bridge?.run($0) },
            askNewCollection: askNewCollection,
            inLocalView: scene.localView != nil,
            canToggleLocalView: session.usesRealBlender && !session.isRunning
                && (scene.localView != nil || !scene.selection.isEmpty || editing),
            openMenu: { openMenu($0) },
            addObject: { bridge?.add($0, at: scene.cursor, view: camera) },
            addImage: session.usesRealBlender ? { imageRequest = $0 } : nil,
            mode: scene.mode,
            editingCurve: editingPoints && !activeIsLattice,
            editingLattice: editingPoints && activeIsLattice,
            selectedCount: scene.selection.count,
            activeType: scene.active?.blenderType,
            activeName: scene.active?.name,
            selectedElements: {
                guard let stats = scene.editMeasurements?.statistics else { return nil }
                return (vertices: stats.verticesSelected, edges: stats.edgesSelected, faces: stats.facesSelected)
            },
            shading: shading,
            setShading: { shading = $0 },
            orientation: { scene.orientation.type },
            setOrientation: { setOrientation($0) },
            modes: availableModes,
            enterMode: { enterMode($0) },
            extrudeToCursor: extrudeToCursor,
            shear: {
                guard session.usesRealBlender else { return }
                bridge?.perform(editing ? LastOperator.shear() : LastOperator.shearObjects())
            },
            snap: { bridge?.run($0.command) },
            setActiveCamera: scene.active?.blenderType == "CAMERA" && session.usesRealBlender
                ? { bridge?.run(ActiveCameraBpy.set) } : nil,
            copyObjects: { bridge?.run(ObjectBufferBpy.copy) },
            pasteObjects: { bridge?.run(ObjectBufferBpy.paste) },
            rename: scene.active == nil ? nil : {
                renameText = scene.active?.name ?? ""
                renaming = true
            },
            insertKeyframe: { keyframe(insert: true) },
            deleteKeyframes: { keyframe(insert: false) },
            orbit: { azimuth, elevation in camera.orbit(dx: azimuth, dy: elevation) },
            pan: { dx, dy in camera.pan(dx: dx, dy: dy) },
            toggleSnap: { bridge?.run(ToolsBpy.useSnap(!scene.tools.useSnap)) },
            toggleProportional: {
                bridge?.run(ToolsBpy.proportional(!scene.tools.isProportional(editing: editing), editing: editing))
            },
            toggleToolbar: { showsToolbar.toggle() },
            maximize: toggleMaximize,
            adjustLastOperation: { redoExpanded = true },
            canRepeatLast: { bridge?.repeatable != nil },
            repeatLast: { if let op = bridge?.repeatable { bridge?.perform(op) } },
            searchOperators: { showOperations = true },
            brushPanel: session.usesRealBlender && [.sculpt, .vertexPaint, .weightPaint].contains(scene.mode)
                ? { AnyView(BrushContextPanel(scene: scene, session: session, bridge: bridge)) } : nil)
    }

    #if DEBUG
    /// One step of `-menu-ops`.
    func runMenuOp(_ token: String) async {
        let (verb, rest) = token.firstIndex(of: ":").map { (String(token[..<$0]), String(token[token.index(after: $0)...])) }
            ?? (token, "")
        var said = ""
        switch verb {
        case "menu":
            let parts = rest.split(separator: "@")
            guard let menu = ViewportMenu(rawValue: String(parts[0])) else { said = "no such menu"; break }
            var point: CGPoint?
            if parts.count > 1 {
                let xy = parts[1].split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { point = CGPoint(x: xy[0], y: xy[1]) }
            }
            openMenu(menu, at: point)
            said = popupMenu == nil ? "nothing opened" : "opened"
        case "key":
            let known = ViewportKey.canPressViewKey(rest, viewportKeys) || ViewportKey.entry(rest, viewportKeys) != nil
            let pressed = known && ViewportKey.pressViewKey(rest, viewportKeys)
            said = pressed ? "pressed" : "means nothing here"
        case "row":
            guard let model = popupMenu else { said = "no menu open"; break }
            var items = model.items
            var found: PopupItem?
            for (n, name) in rest.split(separator: "/").map(String.init).enumerated() {
                func flat(_ rows: [PopupItem]) -> [PopupItem] {
                    rows.flatMap { item -> [PopupItem] in
                        if case .columns(let columns) = item.kind { return columns.flatMap(flat) }
                        return [item]
                    }
                }
                guard let item = flat(items).first(where: { $0.title == name }) else { found = nil; break }
                found = item
                if case .submenu(let build) = item.kind, n < rest.split(separator: "/").count - 1 { items = build() }
            }
            guard let item = found, case .action(let run) = item.kind else { said = "no such row"; break }
            guard item.enabled else { said = "row is greyed out"; break }
            popupMenu = nil
            run()
            said = "ran \(item.title)"
        case "close":
            popupMenu = nil
        case "do":
            // The setup a test needs that is not a Blender key here: A, and
            // the select mode.
            switch rest {
            case "all": viewportKeys.selectAll()
            case "vertex": setSelectMode(.vertex)
            case "edge": setSelectMode(.edge)
            case "face": setSelectMode(.face)
            case "sidebar": showsSidebar.toggle()
            default: said = "no such action"
            }
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(rest) ?? 1) * 1_000_000_000))
        case "py":
            said = bridge?.capture("print(" + rest + ")")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        default:
            said = "no such step"
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        print("[bk] menu-ops \(token): \(said); \(scene.mode.label), \(scene.objects.count) objects, "
              + "active \(scene.active?.name ?? "none"), selected \(scene.selection.count), "
              + "cursor \(scene.cursor), banner \(bridge?.report.map { "\($0.operation): \($0.message)" } ?? "none")")
        if let popupMenu {
            print("[bk] menu " + popupMenu.dump().replacingOccurrences(of: "\n", with: "\n[bk] menu "))
        }
        fflush(stdout)
    }
    #endif

    // MARK: Blender's menus at the pointer, and its other keys

    /// The workspace's coordinate space, which the pop-up menu is drawn in.
    private static let space = "bk-layout"

    /// Opens one of Blender's menus where the pointer is over the 3D View —
    /// where a right-click was, or for a key, where the mouse or trackpad
    /// last hovered — or in the middle of the view without a pointer.
    private func openMenu(_ menu: ViewportMenu, at point: CGPoint? = nil) {
        let local = point ?? ViewportPointer.location
            ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let anchor = CGPoint(x: viewportOrigin.x + local.x, y: viewportOrigin.y + local.y)
        guard let model = ViewportMenu.model(menu, viewportKeys, at: anchor) else { return }
        popupMenu = model
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-menu-dump") {
            print("[bk] menu " + model.dump().replacingOccurrences(of: "\n", with: "\n[bk] menu "))
            fflush(stdout)
        }
        #endif
    }

    /// X, Delete and the forward-delete key delete, at once: in Object Mode
    /// the selected objects, in a mesh's Edit Mode what the select mode
    /// selects — vertices, edges or faces — and with the Measure tool its
    /// ruler (`deleteSelected`). Blender asks first: X a confirmation in
    /// Object Mode, and in Edit Mode both its Delete menu. On an iPad that
    /// was a menu to answer for every delete (the user, November 4: "the del
    /// button should be just del"); Blender's choices — Dissolve, Only Faces,
    /// Edge Loops — are on the right-click menu and in Mesh ▸ Delete.
    private func deleteKey() {
        deleteSelected()
    }

    /// The modes the mode menu offers the active object, in its order.
    private var availableModes: [InteractionMode] {
        guard scene.active != nil else { return [] }
        var modes: [InteractionMode] = [.object]
        if canEdit || canEditPoints { modes.append(.edit) }
        if canEdit {
            modes.append(.sculpt)
            if session.usesRealBlender { modes += PaintModeBpy.modes }
            modes.append(.texturePaint)
        }
        return modes.filter(\.isOffered)
    }

    /// Ctrl+Tab's Mode menu: each mode entered as the mode menu enters it.
    private func enterMode(_ mode: InteractionMode) {
        guard mode != scene.mode else { return }
        switch mode {
        case .object:       toObjectMode()
        case .edit:         setEditing(true)
        case .sculpt:       choose(.sculptDraw)
        case .texturePaint: choose(.paintDraw)
        case .vertexPaint, .weightPaint: enterPaintMode(mode)
        }
    }

    /// I and Alt+I from the context menu, as the timeline's keys run them
    /// (`TimelineDriver.insertKeyframe`).
    private func keyframe(insert: Bool) {
        guard !session.isRunning else { return }
        if session.usesRealBlender {
            bridge?.run(insert ? BpyAnimation.insertKeyframe : BpyAnimation.deleteKeyframe,
                        undo: insert ? BpyAnimation.insertUndoName : BpyAnimation.deleteUndoName)
        } else if insert ? scene.insertKeyframe() > 0 : scene.deleteKeyframe() > 0 {
            session.log(insert ? "bpy.ops.anim.keyframe_insert()" : "bpy.ops.anim.keyframe_delete_v3d()")
        }
    }

    /// Ctrl+Space, Blender's Toggle Maximize Area: the 3D View alone — the
    /// toolbar, the editors and the Sidebar put away — and back as it was.
    private func toggleMaximize() {
        if let was = maximizedFrom {
            showsEditors = was.editors
            showsSidebar = was.sidebar
            showsToolbar = was.toolbar
            maximizedFrom = nil
        } else {
            maximizedFrom = (showsEditors, showsSidebar, showsToolbar)
            showsEditors = false
            showsSidebar = false
            showsToolbar = false
        }
    }

    /// The keys the 3D View carries itself (ViewportKeymap.swift): Blender's
    /// ⌘ twins and the F keys.
    private var viewKeyCommands: ViewKeyCommands {
        ViewKeyCommands(chords: ViewportKey.viewKeys,
                        canPress: { ViewportKey.canPressViewKey($0, viewportKeys) },
                        press: { _ = ViewportKey.pressViewKey($0, viewportKeys) })
    }

    /// Delete, Backspace or X — and More ▸ Delete Selected. Objects in object
    /// mode; while editing, the selected elements of the select mode in use.
    /// Whatever was tapped since Blender last reported its selection reaches
    /// Blender first, in the same evaluation.
    private func deleteSelected() {
        // With the Measure tool, Blender's Delete (and X) removes the active
        // ruler (`view3d.ruler_remove` in its tool keymap).
        if tool == .measure, scene.activeRuler != nil {
            MeasureActions.remove(scene)
            return
        }
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
        bridge.run(Bpy.deleteSelection(editing: editing, mode: scene.selectMode), undo: UndoStep.delete)
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
        bridge.run(Bpy.separate(type), undo: UndoStep.separate)
    }

    /// Shade Smooth / Shade Flat, from the Object menu.
    private func setShading(smooth: Bool) {
        guard !refusedInSculptMode(smooth ? "Shade Smooth" : "Shade Flat") else { return }
        guard let bridge, scene.active != nil, !session.isRunning else { return }
        bridge.run(smooth ? Bpy.shadeSmooth : Bpy.shadeFlat,
                   undo: smooth ? UndoStep.shadeSmooth : UndoStep.shadeFlat)
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

    /// Opens Move / Link to New Collection's prompt with the name Blender's
    /// invoke proposes (`BKE_collection_new_name_get`).
    private func askNewCollection(_ parent: Int, _ link: Bool) {
        newCollectionName = scene.collections?.newName(inside: parent) ?? "Collection"
        newCollection = (parent, link)
    }

    /// Local View came or went in Blender — the toggle, Remove from Local
    /// View emptying it, an Undo past the step that entered it. Entering
    /// frames what it holds as Blender's Frame Selected does
    /// (`LocalViewFraming`), from the view as it is, leaving camera view as
    /// Blender does; leaving puts back the view it was entered from.
    private func localViewChanged(from before: LocalViewState?, to after: LocalViewState?) {
        if before == nil, let after {
            beforeLocalView = (camera, cameraView)
            cameraView = nil
            // Each object's box as Blender's `BKE_object_minmax` makes it: an
            // empty, a light or a camera is its location ± its scale.
            let held = scene.objects.filter { after.objects.contains($0.name) }
            let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
            if let box = LocalViewFraming.box(of: held),
               let framed = LocalViewFraming.frame(lo: box.lo, hi: box.hi, fovY: camera.fovY,
                                                   aspect: aspect > 0 ? aspect : 1, clipStart: camera.near) {
                camera.target = framed.centre
                camera.distance = framed.distance
            }
        } else if before != nil, after == nil, let kept = beforeLocalView {
            camera = kept.camera
            cameraView = kept.cameraView
            beforeLocalView = nil
        }
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
        guard !refusedInSculptMode("Duplicate Objects") else { return }
        guard let bridge, let active = scene.active, !session.isRunning else { return }
        if editing {
            guard active.hasEditMode else {
                bridge.showReport("Duplicate", "Duplicate in Edit Mode copies mesh elements here, and "
                                  + "\(active.name) is not a mesh. Leave Edit Mode to duplicate the object.")
                return
            }
            // Mesh ▸ Duplicate is `mesh.duplicate_move`, whose step Blender's
            // undo history names after it (measured in 5.2.1).
            bridge.run(Bpy.duplicateElements, undo: UndoStep.duplicateElements)
            return
        }
        bridge.run(Bpy.duplicate, undo: UndoStep.duplicateObjects)
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
                // X and forward-delete delete at once (`deleteKey`).
                Button("Delete") { deleteKey() }
                    .keyboardShortcut("x", modifiers: [])
                Button("Delete") { deleteKey() }
                    .keyboardShortcut(.deleteForward, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .disabled(session.isRunning || scene.active == nil)
        }
    }

    /// The Properties editor for the active object, in the editors' dock
    /// (`editorsDock`): a camera's or a light's own settings, else the tabs
    /// of `PropertiesView`, with the Data API one tap below either.
    @ViewBuilder private var propertiesEditor: some View {
        // A camera or a light has no mesh to show, and until now had no
        // settings either: the sheet went straight to the RNA browser, where
        // `energy` is a row of JSON.
        if let object = scene.active, object.overlayDisplay != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CameraLightPanel(scene: scene, session: session, bridge: bridge,
                                     object: object, camera: $camera,
                                     lookThrough: { lookThroughCamera(object) })
                    if session.usesRealBlender {
                        BEditorDivider(.horizontal)
                        dataAPILink
                    }
                }
            }
        } else {
            // A mesh got the RNA browser and nothing else, on exactly the
            // backend where it matters: no Transform fields, no modifier
            // stack, no material — so a part could not be placed at a number,
            // only dragged. The Properties editor is what Blender shows here,
            // and the browser stays one tap away, the way the camera and light
            // panel already does. With nothing selected Blender still shows
            // the Properties editor (its Scene tab), not the raw RNA tree.
            VStack(spacing: 0) {
                PropertiesView(scene: scene, session: session, bridge: bridge)
                if session.usesRealBlender {
                    BEditorDivider(.horizontal)
                    dataAPILink
                }
            }
        }
    }

    /// The way into the Data API browser (Blender's Outliner shows the RNA
    /// tree as its Data API display mode): on the active object, or on the
    /// scene when nothing is active.
    private var dataAPILink: some View {
        let onObject = scene.active != nil
        return NavigationLink {
            BlenderDataBrowser(bridge: bridge,
                               startPath: onObject ? "bpy.context.object" : "bpy.context.scene",
                               revision: session.backendRevision)
                .toolbar(.visible, for: .navigationBar)
        } label: {
            BLinkRow(icon: "list.bullet.indent", title: "Data API",
                     caption: onObject ? "Every setting of this object, under Blender's names"
                                       : "Every setting of the scene, under Blender's names")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("properties.dataAPI")
    }

    // MARK: the header, the toolbar and the editors' dock

    /// Blender's 3D View header: the mode menu, then the menus for what is
    /// being worked on, then — at the far end — the transform settings, the
    /// editors' dock and More.
    ///
    /// The tools moved out of it to the toolbar (`toolShelf`), where Blender
    /// keeps them. With them in it the row was 1,774 points wide in Object
    /// Mode and 2,507 in Edit Mode: on an iPad Air 11-inch held upright (820
    /// points) Select, Add, Mesh, the mode menu, the Outliner, Edit Mode and
    /// More lay past the screen's edge with nothing to say they were there,
    /// and Edit Mode and More did on every iPad, in either orientation
    /// (measured with `-ui-audit`, November 1). The transform settings are
    /// icons, as Blender's header draws them, and on a narrow window the
    /// menus' titles lose their icons and the mirror row folds into one menu.
    /// The mode menu, the editors' button and More are pinned at the two
    /// ends; between them, a mode whose header still does not fit (Blender's
    /// Sculpt Mode header, 1,300 points with its brush settings) scrolls, and
    /// a fade and a chevron at the edge say so. In the sculpt and paint modes
    /// the transform settings go, as they go from Blender's header there.
    private var headerRow: some View {
        HStack(spacing: 4) {
            modeMenu
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if editing, !editingPoints { selectModeControl }
                        if editingPoints {
                            pointsMenus
                        } else if editing {
                            selectMenu
                            meshMenu
                        } else if sculptingInBlender {
                            // Blender's sculpt header: the brush and its
                            // settings, then Dyntopo, Remesh, Multires, Mask
                            // and Face Sets. No Add or Mesh menu: Blender's
                            // Sculpt Mode has neither.
                            sculptMenu
                            SculptHeader(scene: scene, session: session, bridge: bridge)
                        } else if paintingInBlender {
                            // Blender's Weight Paint and Vertex Paint headers:
                            // the brush and its settings. No Add or Mesh menu:
                            // neither mode has them.
                            sculptMenu
                            PaintModeHeader(scene: scene, session: session, bridge: bridge)
                        } else {
                            if scene.mode == .object { selectMenu }
                            addMenu
                            // Blender's Object Mode header: View, Select,
                            // Add, Object. The Mesh menu after it is the
                            // app's: its rows run without entering Edit Mode.
                            if scene.mode == .object { objectMenu }
                            meshMenu
                            // The brushes, in the modes that have them.
                            if scene.mode != .object { sculptMenu }
                            if scene.mode == .texturePaint { TexturePaintHeader(scene: scene, tool: tool) }
                        }
                        Spacer(minLength: 4)
                        // Blender's header order at its right end: the
                        // orientation, the pivot point, the magnet,
                        // proportional editing — in Object and Edit Mode —
                        // then the mirror row in the modes that draw it.
                        if scene.mode == .object || editing {
                            transformButton
                        }
                        if showsSymmetry { symmetryControl }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerContentWidth = $0 }
                }
                .modifier(ScrolledToEnd(atEnd: $headerScrolledToEnd))
                .overlay(alignment: .trailing) {
                    if headerContentWidth > geo.size.width + 1, !headerScrolledToEnd {
                        ZStack(alignment: .trailing) {
                            LinearGradient(colors: [BTheme.header.opacity(0), BTheme.header],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 44)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(BTheme.textDim)
                                .padding(.trailing, 4)
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
            Rectangle().fill(BTheme.outline).frame(width: 1, height: 24).padding(.horizontal, 2)
            editorsToggle
            moreMenu
        }
        .padding(.horizontal, compactHeader ? 4 : 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
        .frame(height: 52)
        .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
        .foregroundStyle(BTheme.text).background(BTheme.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BTheme.editorOutline).frame(height: BTheme.Metric.hairline)
        }
        .disabled(session.isRunning)
    }

    /// A narrow window: an upright iPad (820 points for an 11-inch, 1032 for
    /// a 13-inch, 744 for the mini) or a window beside another app. Edit
    /// Mode's full header needs about 1,050 points.
    private var compactHeader: Bool { headerWidth < 1_100 }

    /// Blender's mode menu, the header's first control: the mode the active
    /// object is in, and every mode it can go to. Edit Mode was a button at
    /// the row's far end, Sculpt Mode, Vertex Paint and Weight Paint were rows
    /// of a menu titled Sculpt, and leaving Edit Mode was a button inside a
    /// chip; Blender has one menu for all of them, and so does this.
    private var modeMenu: some View {
        let current: InteractionMode = scene.mode
        return Menu {
            Button { toObjectMode() } label: {
                Label(InteractionMode.object.label,
                      systemImage: current == .object ? "checkmark" : InteractionMode.object.icon)
            }
            if canEdit || canEditPoints {
                Button { if !editing { setEditing(true) } } label: {
                    Label(InteractionMode.edit.label,
                          systemImage: current == .edit ? "checkmark" : InteractionMode.edit.icon)
                }
            }
            // Object Mode and Edit Mode only (`InteractionMode.isOffered`).
            if canEdit, InteractionMode.sculpt.isOffered {
                Button { if current != .sculpt { choose(.sculptDraw) } } label: {
                    Label(InteractionMode.sculpt.label,
                          systemImage: current == .sculpt ? "checkmark" : InteractionMode.sculpt.icon)
                }
            }
            if canEdit {
                // Blender's own Vertex Paint and Weight Paint, with its module.
                if session.usesRealBlender {
                    ForEach(PaintModeBpy.modes.filter(\.isOffered), id: \.self) { mode in
                        Button { if current != mode { enterPaintMode(mode) } } label: {
                            Label(mode.label, systemImage: current == mode ? "checkmark" : mode.icon)
                        }
                    }
                }
                // Texture Paint is the app's own: its brushes paint the image
                // in Swift and keep the stroke in Blender.
                if InteractionMode.texturePaint.isOffered {
                    Button { if current != .texturePaint { choose(.paintDraw) } } label: {
                        Label(InteractionMode.texturePaint.label,
                              systemImage: current == .texturePaint ? "checkmark" : InteractionMode.texturePaint.icon)
                    }
                }
            }
        } label: { menuLabel(current.label, icon: current.icon, active: current != .object) }
        .disabled(scene.active == nil)
    }

    /// The mode menu's Object Mode: out of Edit Mode as its Tab does, out of
    /// a sculpt or paint mode as picking a tool that needs none does
    /// (`ActiveTool.mode(whenChosenFrom:)`).
    private func toObjectMode() {
        if editing { setEditing(false) } else if scene.mode != .object { choose(.select) }
    }

    /// A scene saved in a mode the app does not offer (`InteractionMode.isOffered`)
    /// — a file left in Sculpt Mode — or a script that went into one: back
    /// to Object Mode, as the mode menu's Object Mode does, once nothing is
    /// running and no stroke is down.
    private func leaveHiddenMode() {
        guard !scene.mode.isOffered, !session.isRunning, session.gestureHold == nil,
              scene.active != nil else { return }
        toObjectMode()
    }

    /// Blender's toolbar, down the 3D View's left edge: the select tools,
    /// Cursor, Move, Rotate, Scale and Measure, and in a mesh's Edit Mode the
    /// tools and actions a mesh edit is mostly made of — Extrude, Inset,
    /// Bevel, Subdivide, Loop Cut and Knife (the rest are in the Mesh menu).
    /// Each is an icon with its name under it, 56 points square: a finger's
    /// size, where the header's buttons were 36 points tall. It scrolls when a
    /// short window cannot fit it.
    private var toolShelf: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                selectToolMenu
                // Blender's toolbar order: the select tools, Cursor, the
                // transforms, then Measure (after Annotate, which is not built).
                ForEach([ActiveTool.cursor, .move, .rotate, .scale, .measure], id: \.self) { item in
                    Button { choose(item) } label: {
                        shelfItem(item.label, icon: item.icon, active: tool == item)
                    }
                    .accessibilityLabel(item.label)
                }
                // Image to 3D Model, the app's own, where it can be seen
                // without opening a menu.
                if scene.mode == .object {
                    Rectangle().fill(BTheme.outline).frame(width: 36, height: 1).padding(.vertical, 4)
                    Button { panel = "Image to 3D Model" } label: {
                        shelfItem("Image to 3D", icon: "photo.artframe", active: panel == "Image to 3D Model")
                    }
                    .accessibilityLabel("Image to 3D Model")
                }
                if editing, !editingPoints {
                    Rectangle().fill(BTheme.outline).frame(width: 36, height: 1).padding(.vertical, 4)
                    ForEach([LastOperator.Mesh.extrude, .inset, .bevel, .subdivide], id: \.self) { op in
                        Button {
                            bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location,
                                                              symmetry: scene.active?.symmetry))
                        } label: {
                            shelfItem(op.toolLabel, icon: shelfIcon(op), active: false)
                        }
                        .accessibilityLabel(op.toolLabel)
                    }
                    // Tools, not actions: with one in hand a tap shows the
                    // ring a loop cut will cross, or adds a point to the
                    // knife's path (CutToolInput.swift).
                    ForEach([ActiveTool.loopCut, .knife], id: \.self) { item in
                        Button { choose(item) } label: {
                            shelfItem(item.label, icon: item.icon, active: tool == item)
                        }
                        .accessibilityLabel(item.label)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 64)
        .buttonStyle(.plain)
        .foregroundStyle(BTheme.text)
        .background(BTheme.header)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BTheme.editorOutline).frame(width: BTheme.Metric.hairline)
        }
        .disabled(session.isRunning)
    }

    /// The toolbar's icons for the Edit Mode actions: the tools' own where
    /// Blender's toolbar has the tool.
    private func shelfIcon(_ op: LastOperator.Mesh) -> String {
        switch op {
        case .extrude: return ActiveTool.extrudeRegion.icon
        case .inset:   return ActiveTool.insetFaces.icon
        case .bevel:   return ActiveTool.bevel.icon
        default:       return "square.grid.2x2"
        }
    }

    private func shelfItem(_ title: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(active ? Color.white : BTheme.text)
        .frame(width: 56, height: 56)
        .background(active ? BTheme.select : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// The Outliner over the Properties editor, as Blender's default layout
    /// has them beside the 3D View; side by side under it when the window is
    /// taller than wide. The header's button (`editorsToggle`) shows and hides
    /// them, and More ▸ Properties shows them.
    private func editorsDock(wide: Bool, height: CGFloat) -> some View {
        let layout = wide ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            NavigationStack {
                OutlinerView(scene: scene, session: session, bridge: bridge)
                    .toolbar(.hidden, for: .navigationBar)
            }
            // The Outliner's share of the column, which the line under it
            // drags (`outlinerShare`); beside the Properties editor when the
            // dock is under the view, 320 points wide.
            .frame(width: wide ? nil : 320,
                   height: wide ? min(max(height * outlinerShare, 120), max(height - 220, 120)) : nil)
            BEditorDivider(wide ? .horizontal : .vertical)
                .overlay {
                    // A finger's strip on the hairline, wider than it looks.
                    if wide {
                        Color.clear
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { drag in
                                    let start = outlinerShareAtDrag ?? outlinerShare
                                    if outlinerShareAtDrag == nil { outlinerShareAtDrag = outlinerShare }
                                    outlinerShare = min(max(start + drag.translation.height / max(height, 1), 0.15), 0.8)
                                }
                                .onEnded { _ in outlinerShareAtDrag = nil })
                            .hoverEffect(.highlight)
                            .accessibilityLabel("Resize the Outliner")
                    }
                }
            NavigationStack {
                propertiesEditor
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .background(BTheme.properties)
        .overlay(alignment: wide ? .leading : .top) {
            BEditorDivider(wide ? .vertical : .horizontal)
        }
    }

    /// Shows or hides the Outliner and the Properties editor.
    private var editorsToggle: some View {
        Button { showsEditors.toggle() } label: {
            settingLabel(icon: "sidebar.right", active: showsEditors, chevron: false)
        }
        .accessibilityLabel("Outliner and Properties")
        .accessibilityValue(showsEditors ? "Shown" : "Hidden")
    }

    /// Shows `name`'s panel: the Outliner and Properties in the dock, any
    /// other (Render, Tool Settings, …) as a sheet.
    private func show(_ name: String) {
        if name == "Outliner" || name == "Properties" { showsEditors = true } else { panel = name }
    }

    /// A header setting drawn as Blender draws it, an icon: 44 points.
    private func settingLabel(icon: String, active: Bool = false, chevron: Bool = true) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(active ? Color.white : BTheme.text)
        .frame(minWidth: 44, minHeight: 44)
        .background(active ? BTheme.select : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Edit Mode on a curve or a lattice: Blender's Select rows for its
    /// points, then its Curve menu (`VIEW3D_MT_edit_curve`, with the control
    /// point and segment rows) or its Lattice menu (`VIEW3D_MT_edit_lattice`).
    /// Each row is Blender's operator through the bridge, and a CANCELLED is
    /// said in words rather than read as done.
    @ViewBuilder private var pointsMenus: some View {
        Menu {
            Button("All") { bridge?.run(selectAllCommand("SELECT"), undo: SelectMenu.selectAllUndo) }
            Button("None") { bridge?.run(selectAllCommand("DESELECT"), undo: SelectMenu.selectAllUndo) }
            Button("Invert") { bridge?.run(selectAllCommand("INVERT"), undo: SelectMenu.selectAllUndo) }
            Divider()
            Text("Tap a point; a knot takes its handles. Shift adds.")
        } label: { menuLabel("Select", icon: "selection.pin.in.out") }
        if activeIsLattice {
            Menu {
                Button(PointsBpy.makeRegular.label) { runPoints(PointsBpy.makeRegular) }
                Menu("Flip (Distortion Free)") {
                    ForEach(["U", "V", "W"], id: \.self) { axis in
                        Button(PointsBpy.flip(axis).label) { runPoints(PointsBpy.flip(axis)) }
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

    /// Vertex, edge or face — Blender's three header buttons in edit mode, and
    /// its 1, 2 and 3. A tap picks whichever of the three this says.
    private var selectModeControl: some View {
        HStack(spacing: 2) {
            ForEach(MeshSelectMode.allCases) { mode in
                Button { setSelectMode(mode) } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(scene.selectMode == mode ? Color.white : BTheme.text)
                        .frame(width: 44, height: 40)
                        .background(scene.selectMode == mode ? BTheme.select : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                // Blender's Mesh Select Mode rows.
                .accessibilityLabel(mode.label)
            }
        }
        .padding(2)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The toolbar's first button: Blender's four select tools under one,
    /// as its toolbar keeps them under one button — a tap, and the three
    /// drags that select more than one thing at a time (a box, a painted
    /// circle, a lasso). All, None and Invert are in the Select menu, where
    /// Blender has them.
    private var selectToolMenu: some View {
        Menu {
            // Blender's toolbar names: Tweak, Select Box, Select Circle,
            // Select Lasso (5.2.1, tests/names/reference).
            ForEach([ActiveTool.select, .boxSelect, .circleSelect, .lassoSelect], id: \.self) { t in
                Button { choose(t) } label: {
                    Label(t.label, systemImage: tool == t ? "checkmark" : t.icon)
                }
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
                Menu("Radius: \(Int(circleRadius)) pt") {
                    ForEach([10, 25, 50, 100] as [CGFloat], id: \.self) { r in
                        Button { circleRadius = r } label: {
                            Label("\(Int(r)) pt", systemImage: circleRadius == r ? "checkmark" : "")
                        }
                    }
                }
            }
            Divider()
            Text("Shift adds, Ctrl or ⌘ takes away, both intersect (Box and Lasso). "
                 + "X-Ray (Viewport Shading) selects what the surface hides.")
        } label: {
            shelfItem(tool.isRegionSelect ? tool.label : ActiveTool.select.label,
                      icon: tool.isRegionSelect ? tool.icon : ActiveTool.select.icon,
                      active: tool == .select || tool.isRegionSelect)
        }
    }

    /// Blender's toolbar's Loop Cut and Knife: tools, not actions — with one
    /// in hand a tap (or a pointer over an edge) shows the ring a loop cut
    /// will cross, or adds a point to the knife's path (CutToolInput.swift).
    /// Whether a mesh is in Blender's Edit Mode, which Edit Mode's overlays
    /// measure.
    private var editingMesh: Bool {
        editing && !editingPoints && session.usesRealBlender && scene.active?.hasEditMode == true
    }

    /// The Cursor tool's settings, as Blender's tool header draws them
    /// (`_defs_view3d_generic.cursor`: Surface Project, Orientation), each
    /// written where Blender's toolbar keeps it and shown as Blender holds it
    /// (`scene.cursorState`, read back every pass).
    @ViewBuilder private var cursorToolBar: some View {
        if tool == .cursor, scene.mode == .object || scene.mode == .edit {
            let state = scene.cursorState
            HStack(spacing: 10) {
                Label(ActiveTool.cursor.label, systemImage: ActiveTool.cursor.icon)
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.active)
                Toggle(CursorTool.surfaceProjectLabel, isOn: Binding(
                    get: { scene.cursorState.surfaceProject },
                    set: { bridge?.run(CursorTool.settingsPython(surfaceProject: $0)) }))
                    .toggleStyle(.button).font(BTheme.Font.ui(11))
                Menu {
                    ForEach(CursorTool.Orientation.allCases) { o in
                        Button { bridge?.run(CursorTool.settingsPython(orientation: o)) } label: {
                            Label(o.label, systemImage: state.orientation == o ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text("\(CursorTool.orientationLabel): \(state.orientation.label)").font(BTheme.Font.ui(11))
                }
                Text("Tap to place the 3D cursor; drag from it to move it.")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(BTheme.header.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)
            .disabled(session.isRunning || !session.usesRealBlender)
        }
    }

    /// The Measure tool's bar: what it does, and Ruler Remove (Blender's X and
    /// Delete with the tool, `view3d.ruler_remove`).
    @ViewBuilder private var measureToolBar: some View {
        if tool == .measure {
            HStack(spacing: 10) {
                Label(RulerTool.label, systemImage: ActiveTool.measure.icon)
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.active)
                Text(measureHint).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                Button(RulerTool.removeLabel) { MeasureActions.remove(scene) }
                    .font(BTheme.Font.ui(11))
                    .disabled(scene.activeRuler == nil)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(BTheme.header.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }

    /// The Measure tool's hint: Blender's tooltip's, for a finger and a
    /// keyboard, and why the object being edited is not snapped to.
    private var measureHint: String {
        var text = "Drag for a ruler; drag a ruler's line for an angle. "
            + (scene.tools.useSnap ? "Snap is on: the ends snap (Ctrl turns it off)."
                                   : "Snap (the header's magnet) or Ctrl snaps the ends.")
        if editing, let why = RulerTool.excluded(scene.objects, edited: scene.active).refusal {
            text += " " + why
        }
        return text
    }

    /// What Edit Mode's overlays are worked out from: any command or undo,
    /// the mode, the object, the viewport's selection, the switches, and
    /// Global or Local (the Sidebar's, the same 3D View flag in Blender) —
    /// and the view, which matters only once a read was culled to it.
    private struct MeasureKey: Equatable {
        var revision: Int
        var running: Bool
        var editing: Bool
        var active: UUID?
        var edit: [Set<Int>]
        var overlays: MeasureOverlays
        var global: Bool
        var view: [Float]

        /// The same read but for the view.
        func sameRead(as other: MeasureKey) -> Bool {
            var a = self, b = other
            a.view = []; b.view = []
            return a == b
        }
    }

    private var measureKey: MeasureKey {
        let edit = scene.editSelection
        return MeasureKey(revision: session.backendRevision, running: session.isRunning, editing: editingMesh,
                          active: scene.activeID, edit: [edit.vertices, edit.edges, edit.faces],
                          overlays: options.measure, global: !measureLocal,
                          view: [camera.target.x, camera.target.y, camera.target.z, camera.distance,
                                 camera.azimuth, camera.elevation, camera.fovY, camera.isOrthographic ? 1 : 0,
                                 Float(viewportSize.width), Float(viewportSize.height)])
    }

    /// The view the overlays are drawn in, as the read culls to it: the
    /// Canvas's own (`MeasureOverlay`, `snapView`).
    private var measureView: simd_float4x4 { camera.snapView(viewportSize).viewProjection }

    /// Runs on every change of `measureKey`. A change of the view alone
    /// reads again only when the last read was culled to its view, and only
    /// once the view has rested for a quarter of a second: an orbit is a new
    /// view every frame, and each read of a mesh of 490,000 faces costs about
    /// half a second (measured in desktop 5.2.1, `_blenderkit_measure`).
    private func measureChanged() async {
        let key = measureKey
        if let last = measuredFor, last.sameRead(as: key) {
            guard last.view != key.view, scene.editMeasurements?.thinning?.culled == true else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
        refreshMeasurements()
        measuredFor = key
    }

    /// Reads Edit Mode's statistics and measurements from Blender, after
    /// handing it the viewport's selection (`captureWithSelection`).
    private func refreshMeasurements() {
        guard editingMesh, options.measure.any, let bridge, !session.isRunning else {
            if scene.editMeasurements != nil { scene.editMeasurements = nil }
            return
        }
        #if DEBUG
        let started = Date()
        #endif
        let text = bridge.captureWithSelection(options.measure.python(global: !measureLocal, view: measureView))
        let read = text.flatMap(EditMeasurements.init(json:))
        #if DEBUG
        // `-measure-ops` times the read on the main thread, as the app makes it.
        if ProcessInfo.processInfo.arguments.contains("-measure-ops") {
            print(String(format: "[bk] measure read: %.1f ms, %d bytes, %d labels%@", Date().timeIntervalSince(started) * 1000,
                         text?.utf8.count ?? 0, read?.count ?? 0,
                         read?.thinning.map { " (\($0.inView) in view, every \($0.every), culled \($0.culled))" } ?? ""))
            fflush(stdout)
        }
        #endif
        if scene.editMeasurements != read { scene.editMeasurements = read }
    }

    /// What the cutting tool in hand says and offers, over the view's top
    /// left: Blender's status bar for it. The Knife's Cut Through, Undo,
    /// Cancel and Confirm are its modal keys' names in Blender
    /// (`knifetool_modal_keymap`, editmesh_knife.cc).
    @ViewBuilder private var cutToolBar: some View {
        if editing, !editingPoints, tool == .loopCut || tool == .knife {
            HStack(spacing: 10) {
                Label(tool.label, systemImage: tool.icon).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.active)
                if tool == .loopCut {
                    Text(session.usesRealBlender
                         ? "Point at an edge to see the loop it cuts, then tap or click that edge to cut. "
                           + "Number of Cuts, Smoothness and the slide are in the panel after."
                         : "Loop Cut needs Blender: the simulator's stand-in has no 3D View.")
                        .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                } else {
                    let count = scene.knifePath?.points.count ?? 0
                    Text(count == 0 ? "Tap points on the mesh." : "\(count) point\(count == 1 ? "" : "s")")
                        .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Toggle("Cut Through", isOn: Binding(get: { scene.knifeCutThrough },
                                                        set: { scene.knifeCutThrough = $0 }))
                        .toggleStyle(.button).font(BTheme.Font.ui(11))
                    Button("Undo") { CutToolActions.knifeUndoPoint(scene) }
                    .disabled(count == 0)
                    Button("Cancel") { CutToolActions.knifeCancel(scene) }
                        .disabled(count == 0)
                    Button("Confirm") { CutToolActions.knifeDone(scene: scene, camera: camera, bridge: bridge) }
                        .disabled(count < 2 || session.isRunning)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(BTheme.header.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
    }

    /// A header menu's title. On a narrow window (`compactHeader`) the icon
    /// goes, as Blender's header shows its menus: the words.
    private func menuLabel(_ title: String, icon: String, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            if !compactHeader { Image(systemName: icon) }
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.55)
        }
        .foregroundStyle(active ? Color.white : BTheme.text)
        .padding(.horizontal, compactHeader ? 8 : 10)
        .frame(minHeight: 44)
        .background(active ? BTheme.select : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Adds at the 3D cursor, and leaves the view alone, as Blender does.
    private var addMenu: some View {
        Menu {
            // First, where it is seen: at the bottom, under every primitive,
            // curve, light and camera, nobody found it (the user, November 4).
            Button("Image to 3D Model…", systemImage: "photo.artframe") { panel = "Image to 3D Model" }
            Divider()
            ForEach(PrimitiveKind.allCases) { kind in
                Button(kind.displayName, systemImage: kind.icon) {
                    bridge?.perform(LastOperator.add(kind, at: scene.cursor))
                }
            }
            ObjectAddItems(add: { bridge?.add($0, at: scene.cursor, view: camera) },
                           addImage: session.usesRealBlender ? { imageRequest = $0 } : nil)
        } label: { menuLabel("Add", icon: "plus") }
    }

    /// Blender's Object menu (VIEW3D_MT_object, 5.2.1), in its order: the
    /// transforms, Set Origin, Mirror, Clear, Apply and Snap; Duplicate
    /// Objects, Duplicate Linked and Join; Copy and Paste Objects; Collection;
    /// Relations, Parent, Modifiers, Constraints and Link/Transfer Data; the
    /// shading rows; Convert; Show/Hide; then Delete and Delete Global, where
    /// Blender keeps them. These rows were in More, mixed with the view's,
    /// and Delete was its last row (the user, November 3: "hard to del
    /// things"). Each row is one the app already ran from More, the Mac menu
    /// bar or a key; a row Blender has and the app cannot run (Bend, Track,
    /// Quick Effects) is left out, as the key menus leave theirs.
    private var objectMenu: some View {
        Menu {
            Menu("Transform") {
                Button(ActiveTool.move.label) { choose(.move) }
                Button(ActiveTool.rotate.label) { choose(.rotate) }
                Button(ActiveTool.scale.label) { choose(.scale) }
                if session.usesRealBlender {
                    Divider()
                    Button("Shear") { performObjectRow(LastOperator.shearObjects()) }
                        .disabled(!objectRelations.canDuplicate)
                }
                Divider()
                RandomizeAlignItems(state: objectRelations, perform: performObjectRow)
            }
            SetOriginMenu(state: objectTransform, setOrigin: setOrigin)
            ObjectMirrorMenu(state: objectRelations, perform: performObjectRow)
            Menu("Clear") {
                ForEach(ClearTransform.allCases, id: \.self) { what in
                    Button(what.label) { performObjectRow(LastOperator.clear(what)) }
                }
            }
            .disabled(scene.selection.isEmpty || session.isRunning)
            ApplyTransformMenu(state: objectTransform, apply: applyTransform)
            snapActionsMenu
            Divider()
            Button("Duplicate Objects", systemImage: "plus.square.on.square") { duplicateSelected() }
                .disabled(scene.active == nil || session.isRunning)
            DuplicateLinkedJoinItems(state: objectRelations, perform: performObjectRow)
            Divider()
            Button("Copy Objects", systemImage: "doc.on.doc") { bridge?.run(ObjectBufferBpy.copy) }
                .disabled(scene.selection.isEmpty || session.isRunning)
            Button("Paste Objects", systemImage: "doc.on.clipboard") { bridge?.run(ObjectBufferBpy.paste) }
                .disabled(session.isRunning)
            Divider()
            ObjectCollectionMenu(state: objectRelations, collections: scene.collections,
                                 run: { bridge?.run($0) }, askNewCollection: askNewCollection)
            Divider()
            ObjectRelationsMenu(state: objectRelations, perform: performObjectRow)
            ObjectParentMenu(state: objectRelations, perform: performObjectRow)
            ObjectModifiersMenu(state: objectRelations, perform: performObjectRow)
            ObjectConstraintsMenu(state: objectRelations, perform: performObjectRow)
            LinkTransferDataMenu(state: objectRelations, perform: performObjectRow)
            Divider()
            ShadingItems(meshInObjectMode: canEdit && !session.isRunning,
                         hasObject: scene.active != nil && !session.isRunning,
                         essentialsLibrary: session.essentialsLibrary,
                         shade: { setShading(smooth: $0) },
                         perform: { op in if !refusedInSculptMode(op.name) { bridge?.perform(op) } })
            Divider()
            ObjectConvertMenu(state: objectRelations, perform: performObjectRow)
            Divider()
            ShowHideMenu(editing: false, run: showHide)
                .disabled(scene.objects.isEmpty || session.isRunning)
            Divider()
            // Objects, always: the Delete key and More's row remove the active
            // ruler instead while the Measure tool has one, as Blender's X does.
            Button("Delete", systemImage: "trash", role: .destructive) {
                bridge?.run(Bpy.deleteSelected, undo: UndoStep.delete)
            }
            .disabled(scene.selection.isEmpty || session.isRunning)
            Button("Delete Global", role: .destructive) {
                bridge?.run(Bpy.deleteSelectedGlobally, undo: UndoStep.delete)
            }
            .disabled(scene.selection.isEmpty || session.isRunning)
        } label: { menuLabel("Object", icon: "cube.fill") }
        .accessibilityIdentifier("header.object")
    }

    /// Every mesh operator Blender can perform here, in one menu. They are
    /// actions rather than modes — you press Bevel, it bevels, and the panel
    /// that appears is where the width gets chosen. Nothing to switch into
    /// first.
    ///
    /// Made of Blender's own menus (`LastOperator.Mesh.Group`): Select ▸
    /// Select Loops, its Mesh menu's submenus and rows in that menu's order,
    /// then the Vertex, Edge and Face menus its header has beside Mesh.
    private var meshMenu: some View {
        Menu {
            // Normals ▸ Average is drawn inside Normals (`Group.parent`).
            ForEach(LastOperator.Mesh.Group.allCases.filter { $0.parent == nil }, id: \.self) { group in
                if group.isInline {
                    // Separate (while editing), Bisect, Knife Project and
                    // Symmetrize: rows of Blender's Mesh menu itself, in its
                    // order after Split.
                    if editing { SeparateMenu(run: separate) }
                    meshRows(group)
                } else {
                    if group == .vertex { Divider() }
                    Menu(group.rawValue) { meshRows(group) }
                }
                // Blender's Mesh menu: Transform, Mirror and Snap, then
                // Duplicate before Extrude. Both were in More only, and More
                // kept a second copy of the Object menu for them.
                if group == .transform, editing {
                    snapActionsMenu
                    Divider()
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicateSelected() }
                        .disabled(session.isRunning)
                }
                if group == .shading, editing { ShowHideMenu(editing: true, run: showHide) }
            }
        } label: { menuLabel("Mesh", icon: "cube.transparent") }
        // Every one of these needs edit mode, which a light does not have.
        .disabled(!canEdit)
    }

    /// One of the Mesh menu's groups, its rows in Blender's order.
    @ViewBuilder private func meshRows(_ group: LastOperator.Mesh.Group) -> AnyView {
        // Type-erased: Normals draws Average inside it, a recursion an opaque
        // `some View` cannot name.
        AnyView(ForEach(group.rows, id: \.self) { op in
            // Blender's Vertex menu: Extrude to Cursor or Add before Bevel
            // Vertices, and Rip Vertices, Rip Vertices and Fill before Rip
            // Vertices and Extend (MeshMenuTools).
            if op == .bevelVertices { extrudeToCursorRow }
            if op == .ripVerticesExtend {
                ForEach(MeshMenuTools.ripRows, id: \.self) { row in
                    Button {} label: {
                        Text(row)
                        Text(MeshMenuTools.ripRefusal)
                    }
                    .disabled(true)
                }
            }
            Button(op.menuLabel) {
                bridge?.perform(LastOperator.mesh(op, spinningAround: scene.active?.location,
                                                  symmetry: scene.active?.symmetry, pointer: meshPointer))
            }
            // A selection or an edge flag is all these change,
            // and only Edit Mode shows either (`editModeOnly`).
            .disabled(op.editModeOnly && !editing)
            if let nested = LastOperator.Mesh.Group.allCases.first(where: { $0.parent == group && $0.after == op }) {
                Menu(nested.rawValue) { meshRows(nested) }
            }
            // Blender's order: Knife Project and the Knife Topology Tool after
            // Bisect, Shear after To Sphere, Loop Cut and Slide after Edge
            // Slide. The two tool rows pick the toolbar's Knife and Loop Cut,
            // as Blender's rows start the same modal tools.
            if op == .bisect {
                knifeProjectMenu
                Button(CutTool.knife.menuRow.label) { choose(.knife) }.disabled(!editing)
            }
            if op == .toSphere { shearRow }
            if op == .edgeSlide {
                Button(CutTool.loopCut.menuRow.label) { choose(.loopCut) }.disabled(!editing)
            }
        })
    }

    /// The pointer for the rows Blender runs at the mouse: over the 3D
    /// cursor, as this 3D View looks at it (`MeshPointer`).
    private var meshPointer: MeshPointer {
        MeshPointer(eye: camera.eye, forward: simd_normalize(camera.target - camera.eye), up: camera.trueUp,
                    orthographic: camera.isOrthographic, cursor: scene.cursor)
    }

    /// Mesh ▸ Vertex ▸ Extrude to Cursor or Add: Blender's Ctrl+right click
    /// with the pointer over the 3D cursor. Blender has no redo panel for it
    /// (no exec), so it runs once, as `bridge.run` with its own undo step.
    private var extrudeToCursorRow: some View {
        Button(MeshMenuTools.extrudeToCursor) { extrudeToCursor() }
            .disabled(!editing)
    }

    private func extrudeToCursor() {
        guard let bridge, editing else { return }
        bridge.run(MeshMenuTools.extrudeToCursorPython(meshPointer), undo: MeshMenuTools.extrudeToCursor)
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
                Section("Mode") {
                    // Blender's mode menu rows, in and out: Sculpt Mode,
                    // Vertex Paint and Weight Paint are Blender's own here.
                    if scene.mode == .sculpt || paintingInBlender {
                        Button(InteractionMode.object.label, systemImage: InteractionMode.object.icon) { choose(.select) }
                    }
                    if scene.mode != .sculpt {
                        Button(InteractionMode.sculpt.label, systemImage: InteractionMode.sculpt.icon) { choose(.sculptDraw) }
                    }
                    ForEach(PaintModeBpy.modes, id: \.self) { mode in
                        if scene.mode != mode {
                            Button(mode.label, systemImage: mode.icon) { enterPaintMode(mode) }
                        }
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
                      : paintingInBlender ? scene.mode.label
                      : brushActive ? tool.label : "Sculpt",
                      icon: sculptingInBlender ? InteractionMode.sculpt.icon
                      : paintingInBlender ? scene.mode.icon
                      : brushActive ? tool.icon : "paintbrush.pointed",
                      active: brushActive || sculptingInBlender || paintingInBlender)
        }
        // Sculpting and painting are mesh modes too.
        .disabled(!canEdit)
    }

    /// The camera Active Camera looks through: the selected one when the
    /// active object is a camera, else the scene's, else the first there is.
    private var cameraToLookThrough: BKObject? {
        if let active = scene.active, case .camera = active.overlayDisplay { return active }
        return scene.sceneCamera ?? scene.cameras.first
    }

    /// The camera Align Active Camera to View aims: the scene's, as Blender's
    /// `view3d.camera_to_view` aims `scene.camera` (its poll fails without
    /// one). It aimed the selected camera ahead of it (round 4's review).
    private var cameraToAlign: BKObject? { scene.sceneCamera }

    private func lookThroughCamera(_ chosen: BKObject? = nil) {
        guard let object = chosen ?? cameraToLookThrough,
              case .camera(let display)? = object.overlayDisplay else { return }
        guard camera.look(through: object) else { return }
        let aspect = CGFloat(max(display.aspectX, 1) / max(display.aspectY, 1))
        cameraView = (aspect, camera, "\(object.name) · \(Int(display.aspectX)) × \(Int(display.aspectY))")
        session.note("Looking through \(object.name). Move the view to leave it.")
    }

    private func aimCameraAtView() {
        guard let object = cameraToAlign, let bridge else { return }
        _ = bridge.run(Bpy.alignCameraToView(object.name, camera.renderCamera),
                       undo: "Align Camera to View")
    }

    // MARK: snapping, the pivot point and proportional editing
    //
    // In the Transform panel (`transformPanel`). All three are Blender's
    // `scene.tool_settings`, mirrored onto `scene.tools` after every command
    // (TransformTools.swift). Every choice there is one `bridge.run` and reads
    // its state back from the scene, so the panel shows what Blender holds —
    // including after a script changed it.
    // None carries an undo label: Blender pushes no undo step for a setting
    // either.

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

    /// The mirror row; on a narrow window, one menu holding it, so the header
    /// still fits an upright iPad in Edit Mode.
    @ViewBuilder private var symmetryControl: some View {
        if compactHeader {
            let symmetry = scene.active?.symmetry ?? MeshSymmetry()
            Menu {
                Section("Mirror") {
                    ForEach([SymmetryBpy.Flag.x, .y, .z]) { flag in
                        Button { toggleSymmetry(flag) } label: {
                            Label(flag.label, systemImage: flag.isOn(in: symmetry) ? "checkmark" : "")
                        }
                    }
                }
                if SymmetryBpy.offersTopology(in: scene.mode) {
                    Button { toggleSymmetry(.topology) } label: {
                        Label(SymmetryBpy.Flag.topology.label, systemImage: symmetry.topology ? "checkmark" : "")
                    }
                }
            } label: {
                settingLabel(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                             active: symmetry.isOn)
            }
            .accessibilityLabel("Mirror")
        } else {
            symmetryRow
        }
    }

    private var symmetryRow: some View {
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
                // Where Blender keeps Topology Mirror: Edit Mode's Options
                // popover, Weight Paint's Symmetry.
                .accessibilityLabel(scene.mode == .edit ? "Options" : "Symmetry")
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

    /// What is left once the tools, Undo and Edit Mode have their own places.
    /// "More" is the app's own: Blender has no such menu, and every row in it
    /// is named as Blender names it.
    private var moreMenu: some View {
        Button { showsMore = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(BTheme.text)
        .accessibilityLabel("More")
        .popover(isPresented: $showsMore, arrowEdge: .top) {
            morePanel
                .presentationDetents([.medium, .large])
        }
    }

    /// More, as a panel rather than a menu: it was a list of rows and
    /// submenus — Cameras, Viewport Shading, Viewport Overlays — with the
    /// toggles hidden two levels down and most rows without an icon (the
    /// user, November 4: "the three dots one open is bad and hard to use").
    /// The view's actions are tiles a finger can hit, the four shadings sit
    /// side by side with the current one lit, and every setting that is on
    /// or off is a switch that shows which. Every row is named as Blender
    /// names it.
    private var morePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                moreSection("View") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        moreTile("Frame All", icon: "arrow.up.left.and.down.right.magnifyingglass") {
                            camera.frameAll(scene.objects)
                        }
                        moreTile("Frame Selected", icon: "dot.viewfinder",
                                 enabled: !scene.selection.isEmpty || editing) {
                            camera.frameSelected(in: scene)
                        }
                        // View ▸ Local View: the selection by itself, through
                        // the borrowed 3D View's own (`_blenderkit_localview`).
                        moreTile("Toggle Local View", icon: "circle.dashed.inset.filled",
                                 active: scene.localView != nil,
                                 enabled: session.usesRealBlender && !session.isRunning
                                     && (scene.localView != nil || !scene.selection.isEmpty || editing)) {
                            bridge?.run(LocalViewBpy.toggle)
                        }
                        // View ▸ Cameras ▸ Active Camera (numpad 0) and View ▸
                        // Align View ▸ Align Active Camera to View.
                        moreTile("Active Camera", icon: "video", enabled: cameraToLookThrough != nil) {
                            lookThroughCamera()
                        }
                        moreTile("Align Active Camera to View", icon: "camera.viewfinder",
                                 enabled: cameraToAlign != nil) {
                            aimCameraAtView()
                        }
                        moreTile("Remove from Local View", icon: "minus.circle",
                                 enabled: scene.localView != nil && !session.isRunning) {
                            bridge?.run(LocalViewBpy.removeFrom)
                        }
                    }
                }
                // Blender's header popover of the same name: its four types,
                // then X-Ray.
                moreSection("Viewport Shading") {
                    HStack(spacing: 8) {
                        ForEach(ViewportShading.allCases) { value in
                            moreTile(value.label, icon: value.icon, active: shading == value,
                                     enabled: value.isImplemented, closes: false) { shading = value }
                        }
                    }
                    moreSwitch("X-Ray", icon: "circle.lefthalf.striped.horizontal", isOn: $options.xray)
                }
                // Blender's Viewport Overlays popover's Statistics, and in a
                // mesh's Edit Mode its Measurement (VIEW3D_PT_overlay,
                // VIEW3D_PT_overlay_edit_mesh_measurement), each read from
                // Blender (EditMeasure.swift).
                moreSection("Viewport Overlays") {
                    moreSwitch(MeasureOverlays.statisticsLabel, icon: "chart.bar.xaxis",
                               isOn: $options.measure.statistics,
                               note: !session.usesRealBlender
                                   ? "Statistics reads Blender's edit mesh, which the simulator's stand-in does not have."
                                   : (!editingMesh ? "Statistics is drawn for a mesh in Edit Mode." : nil))
                    if editingMesh {
                        moreSwitch(MeasureOverlays.edgeLengthLabel, icon: "arrow.left.and.right",
                                   isOn: $options.measure.edgeLength)
                        moreSwitch(MeasureOverlays.edgeAngleLabel, icon: "angle",
                                   isOn: $options.measure.edgeAngle)
                        moreSwitch(MeasureOverlays.faceAreaLabel, icon: "square.dashed",
                                   isOn: $options.measure.faceArea)
                        moreSwitch(MeasureOverlays.faceAngleLabel, icon: "triangle",
                                   isOn: $options.measure.faceAngle)
                    }
                }
                // The editors Blender has for these, by their names: the
                // Properties editor, View ▸ Sidebar (N), the Timeline, the
                // Render menu's window, the Tool Settings bar's settings, and
                // Edit ▸ Operator Search.
                moreSection("Editors") {
                    moreRow("Properties", icon: "slider.horizontal.3") { show("Properties") }
                    moreSwitch("Sidebar", icon: "sidebar.right", isOn: $showsSidebar)
                    moreSwitch("Timeline", icon: "timeline.selection",
                               isOn: Bindable(scene).animation.showsTimeline)
                    moreRow("Render", icon: "camera.aperture") { panel = "Render" }
                    moreRow("Tool Settings", icon: "wrench.and.screwdriver") { panel = "Tool Settings" }
                    moreRow("Operator Search", icon: "magnifyingglass") { showOperations = true }
                }
                // Blender keeps it under Object Data ▸ Remesh.
                moreSection("Remesh") {
                    moreRow("QuadriFlow Remesh", icon: "square.grid.3x3.topleft.filled",
                            enabled: canEdit && !editing && !session.isRunning) {
                        bridge?.perform(LastOperator.quadriflowRemesh())
                    }
                }
                // A curve's or a lattice's points have no Object or Mesh menu
                // here, so their rows stay in More.
                if editingPoints {
                    moreSection("Object") {
                        Menu { moreObjectRows } label: {
                            moreRowLabel("Snap, Shading, Set Origin, Delete…", icon: "ellipsis.circle", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 340, idealWidth: 360)
        .background(BTheme.menuBack)
        .preferredColorScheme(.dark)
    }

    /// Blender's header settings at its right end — Transform Orientations,
    /// Pivot Point, Snapping, Proportional Editing — as one button that opens
    /// them in a panel (`transformPanel`). They were four buttons of their
    /// own, each a menu of small rows (the user, November 4: too many
    /// buttons). It shows the orientation by name, as Blender's does, and
    /// beside it the pivot, the magnet and proportional editing when they are
    /// not at their defaults, lit.
    private var transformButton: some View {
        let state = scene.orientation
        let snapping = scene.tools.snapsDrag
        let proportional = scene.tools.isProportional(editing: editing)
        let pivoted = scene.tools.pivot != .medianPoint
        return Button { showsTransform = true } label: {
            HStack(spacing: 6) {
                Image(systemName: (state.type ?? .global).icon)
                if !compactHeader { Text(state.label) }
                if pivoted { Image(systemName: scene.tools.pivot.icon).foregroundStyle(BTheme.active) }
                if snapping { Image(systemName: "dot.squareshape.split.2x2").foregroundStyle(BTheme.active) }
                if proportional { Image(systemName: "smallcircle.filled.circle").foregroundStyle(BTheme.active) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.55)
            }
            .foregroundStyle(BTheme.text)
            .padding(.horizontal, compactHeader ? 8 : 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transform Orientations, Pivot Point, Snapping, Proportional Editing")
        .accessibilityValue(state.label)
        .popover(isPresented: $showsTransform, arrowEdge: .top) {
            transformPanel
                .presentationDetents([.medium, .large])
        }
    }

    /// The four settings Blender's header holds at its right end, each as
    /// Blender's popover has it, in the More panel's tiles and switches: a
    /// choice is a tile lit when it is the current one, and the panel stays
    /// open, since what changes is in the view behind it.
    private var transformPanel: some View {
        let state = scene.orientation
        let tools = scene.tools
        let real = session.usesRealBlender
        let threeColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                moreSection("Transform Orientations") {
                    LazyVGrid(columns: threeColumns, spacing: 8) {
                        ForEach(TransformOrientation.allCases) { value in
                            moreTile(value.label, icon: value.icon, active: state.type == value,
                                     enabled: real, closes: false) { setOrientation(value) }
                        }
                    }
                    if state.type == nil, let name = state.customName {
                        transformNote("Now: \(name)")
                    }
                    if let why = state.unavailable { transformNote(why) }
                }
                moreSection("Pivot Point") {
                    LazyVGrid(columns: threeColumns, spacing: 8) {
                        ForEach(TransformPivot.allCases) { value in
                            moreTile(value.label, icon: value.icon, active: tools.pivot == value,
                                     closes: false) { bridge?.run(ToolsBpy.pivot(value)) }
                        }
                    }
                }
                moreSection("Snapping") {
                    moreSwitch("Snap", icon: "dot.squareshape.split.2x2",
                               isOn: Binding(get: { scene.tools.useSnap },
                                             set: { bridge?.run(ToolsBpy.useSnap($0)) }))
                    transformNote("Snap Target")
                    LazyVGrid(columns: threeColumns, spacing: 8) {
                        ForEach(SnapElement.allCases) { element in
                            let on = tools.elements.contains(element)
                            moreChip(element.label, active: on, enabled: !(on && tools.elements.count == 1)) {
                                var next = scene.tools.elements
                                if next.contains(element) { next.remove(element) } else { next.insert(element) }
                                bridge?.run(ToolsBpy.elements(next))
                            }
                        }
                    }
                    transformNote("Snap Target for Individual Elements")
                    HStack(spacing: 8) {
                        ForEach(SnapElementIndividual.allCases) { element in
                            moreChip(element.label, active: tools.individual.contains(element)) {
                                var next = scene.tools.individual
                                if next.contains(element) { next.remove(element) } else { next.insert(element) }
                                bridge?.run(ToolsBpy.individual(next))
                            }
                        }
                    }
                    transformNote("Snap Base")
                    HStack(spacing: 8) {
                        ForEach(SnapTarget.allCases) { value in
                            moreChip(value.label, active: tools.target == value) {
                                bridge?.run(ToolsBpy.target(value))
                            }
                        }
                    }
                }
                moreSection("Proportional Editing") {
                    moreSwitch(editing ? "Proportional Editing" : "Proportional Editing Objects",
                               icon: "smallcircle.filled.circle",
                               isOn: Binding(get: { scene.tools.isProportional(editing: editing) },
                                             set: { bridge?.run(ToolsBpy.proportional($0, editing: editing)) }))
                    transformNote("Proportional Editing Falloff")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(MeshEditor.ProportionalFalloff.allCases) { value in
                            moreChip(value.label, active: tools.falloff == value) {
                                bridge?.run(ToolsBpy.falloff(value))
                            }
                        }
                    }
                    transformNote("Proportional Size")
                    LazyVGrid(columns: threeColumns, spacing: 8) {
                        ForEach(Self.proportionalSizes, id: \.self) { value in
                            moreChip(String(format: "%g m", value), active: abs(tools.size - value) < 1e-4) {
                                bridge?.run(ToolsBpy.size(value))
                            }
                        }
                    }
                    moreSwitch("Connected Only", icon: "point.3.connected.trianglepath.dotted",
                               isOn: Binding(get: { scene.tools.connected },
                                             set: { bridge?.run(ToolsBpy.connected($0)) }))
                }
            }
            .padding(16)
        }
        .frame(minWidth: 340, idealWidth: 380)
        .background(BTheme.menuBack)
        .preferredColorScheme(.dark)
    }

    private func transformNote(_ text: String) -> some View {
        Text(text)
            .font(BTheme.Font.ui(12))
            .foregroundStyle(BTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A choice without an icon, a finger's height: one of several the
    /// Transform panel lists, lit when it is chosen.
    private func moreChip(_ title: String, active: Bool, enabled: Bool = true,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BTheme.Font.ui(13))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(active ? Color.white : BTheme.text)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(active ? BTheme.select : BTheme.widget.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// One of More's sections: a dim heading over its rows.
    private func moreSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BTheme.textDim)
            content()
        }
    }

    /// A tile: an action with its icon over its name, lit while it is on.
    /// Most close More, since what they do is in the view behind it.
    private func moreTile(_ title: String, icon: String, active: Bool = false, enabled: Bool = true,
                          closes: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if closes { showsMore = false }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(BTheme.Font.ui(12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Color.white : BTheme.text)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(active ? BTheme.select : BTheme.widget.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    /// A row that opens an editor or runs an operator, and closes More.
    private func moreRow(_ title: String, icon: String, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button {
            showsMore = false
            action()
        } label: {
            moreRowLabel(title, icon: icon, chevron: true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func moreRowLabel(_ title: String, icon: String, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
            Text(title).font(BTheme.Font.ui(14))
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BTheme.textDim)
            }
        }
        .foregroundStyle(BTheme.text)
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(BTheme.widget.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// A setting that is on or off, as a switch that shows which. More stays
    /// open: the change shows in the view behind it.
    private func moreSwitch(_ title: String, icon: String, isOn: Binding<Bool>, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 24)
                    Text(title).font(BTheme.Font.ui(14))
                }
                .foregroundStyle(BTheme.text)
            }
            .tint(BTheme.select)
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(BTheme.widget.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let note {
                Text(note)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }

    /// More's object rows, while there is no Object menu in the header.
    @ViewBuilder private var moreObjectRows: some View {
        Divider()
        // Blender has these on the Object menu and on the right-click
        // menu. They were reachable only from a script, and they are the
        // difference between a subdivided surface that reads as a shape
        // and one that reads as facets — which is most of what makes a
        // model built from primitives look unfinished.
        snapActionsMenu
        ShadingItems(meshInObjectMode: canEdit && !editing && !session.isRunning,
                     hasObject: scene.active != nil && !session.isRunning,
                     essentialsLibrary: session.essentialsLibrary,
                     shade: { setShading(smooth: $0) },
                     perform: { op in if !refusedInSculptMode(op.name) { bridge?.perform(op) } })
        // The other two object-level operations Blender keeps on this
        // menu, above the destructive ones.
        ObjectTransformItems(state: objectTransform,
                             setOrigin: setOrigin, apply: applyTransform)
        Divider()
        // Blender's Object menu order: Duplicate Objects, Duplicate
        // Linked and Join, then Parent and Convert further down.
        // Blender's Object ▸ Duplicate Objects, or its Mesh ▸ Duplicate
        // while editing.
        Button(editing ? "Duplicate" : "Duplicate Objects", systemImage: "plus.square.on.square") {
            duplicateSelected()
        }
            .keyboardShortcut("d", modifiers: .shift)   // Blender's Shift+D
            .disabled(scene.active == nil || session.isRunning)
        ObjectRelationItems(state: objectRelations, perform: performObjectRow)
        ObjectMenuMoreItems(state: objectRelations, collections: scene.collections,
                            perform: performObjectRow, run: { bridge?.run($0) },
                            askNewCollection: askNewCollection)
        Divider()
        // Blender's Object ▸ Show/Hide, or the Mesh menu's while editing.
        ShowHideMenu(editing: editing, run: showHide)
            .disabled(scene.objects.isEmpty || session.isRunning)
        Button("Delete", role: .destructive) {
            deleteSelected()
        }.disabled(scene.active == nil)
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

#if DEBUG
// MARK: - `-transform-ops`

extension LayoutWorkspace {
    /// `-transform-ops a,b,…`: the Orientation menu, gizmo drags and their redo
    /// panel, and the Sidebar's Item tab, through the calls the controls make,
    /// once a `-eval64` script has finished. Tokens:
    /// `orient:<GLOBAL|LOCAL|NORMAL|GIMBAL|VIEW|CURSOR|PARENT>` (the menu's
    /// `setOrientation`), `select:A+B`, `edit`, `object`, `view:<persp:d|top>`,
    /// `gizmo:<translate|rotate|scale>:<0|1|2|p0|p1|p2|s>:<amount>` (a drag
    /// through `beginSession`, `resolve`, `snapping`, `apply` and `commit`, as
    /// the viewport's own; a move's amount in the orientation's units, a
    /// turn's in degrees, a scale's a factor), `adjust:<key>=<value>` (a redo
    /// panel row, through `readjust`), `redo-panel` (its title and rows as it
    /// shows them), `sidebar:on|off`, `local` / `global` (the Item tab's
    /// pair), `item:<0|1|2>=<v>` (a Median field, `ItemActions.median`),
    /// `data:<bevel_weight_vert|crease_vert|bevel_weight_edge|crease_edge>=<v>`,
    /// `dims:<0|1|2>=<v>` (a Dimensions field), `item-state` (what the Item
    /// tab and the Data tab read), `undo`, `redo`, `ax`, `steps`. After each it
    /// prints what Blender holds beside what the app shows.
    func runTransformOps() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-transform-ops"), i + 1 < args.count, let bridge else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        var itemIsGlobal = true
        for token in args[i + 1].split(separator: ",").map(String.init) {
            bridge.dismissReport(bridge.report?.id ?? -1)
            refreshOrientation()
            let parts = token.split(separator: ":", maxSplits: 3).map(String.init)
            var said = ""
            switch parts[0] {
            case "orient":
                guard parts.count == 2, let o = TransformOrientation(identifier: parts[1]) else {
                    said = "orient:<TYPE>"; break
                }
                setOrientation(o)
                said = "Blender's slot " + (bridge.capture("print(bpy.context.scene.transform_orientation_slots[0].type)")?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
                    + "; the app holds \(scene.orientation.label) axes \(Self.axesText(scene.orientation.axes))"
                    + (scene.orientation.unavailable.map { " unavailable: \($0)" } ?? "")
            case "select":
                let names = token.dropFirst("select:".count).split(separator: "+").map(String.init)
                for (k, name) in names.enumerated() { bridge.select(Bpy.select(name, only: k == 0)) }
            case "edit":   setEditing(true)
            case "object": setEditing(false)
            case "view":
                if parts.count >= 2, parts[1] == "top" { camera.snap(to: .top) }
                if parts.count >= 3, parts[1] == "persp", let d = Float(parts[2]) {
                    camera.isOrthographic = false; camera.distance = d
                }
                said = "eye \(camera.eye)"
            case "gizmo":
                said = gizmoToken(parts, bridge: bridge)
            case "adjust":
                let pair = token.dropFirst("adjust:".count).split(separator: "=").map(String.init)
                let before = Self.blenderPlaces(bridge, scene: scene)
                said = "no adjustable operator"
                if pair.count == 2, let v = Double(pair[1]), var op = bridge.adjustable {
                    op[pair[0]] = v
                    said = bridge.readjust(op).map { "re-ran \($0.python)" } ?? "REFUSED"
                }
                said += "; Blender \(before) -> \(Self.blenderPlaces(bridge, scene: scene))"
            case "redo-panel":
                if let op = bridge.adjustable {
                    said = "\(op.name): " + op.parameters.filter { op.isShown($0) }
                        .map { "\($0.label) \($0.display)" }.joined(separator: ", ")
                } else {
                    said = "no redo panel"
                }
            case "sidebar":
                showsSidebar = parts.count < 2 || parts[1] != "off"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                said = "sidebar \(showsSidebar ? "out" : "in")"
            case "local":  itemIsGlobal = false
            case "global": itemIsGlobal = true
            case "item", "data", "dims":
                let pair = token.dropFirst(parts[0].count + 1).split(separator: "=").map(String.init)
                guard pair.count == 2, let v = Float(pair[1]) else { said = "\(parts[0]):<what>=<value>"; break }
                let outcome: BpyBridge.Outcome?
                switch parts[0] {
                case "item":
                    outcome = Int(pair[0]).map { ItemActions.median(bridge, axis: $0, to: v, global: itemIsGlobal) }
                case "data":
                    let row = ItemDataRow(rawValue: pair[0])
                    let label = ItemActions.state(bridge, global: itemIsGlobal)?.dataRows
                        .first { $0.row == row }?.label ?? pair[0]
                    outcome = row.map { ItemActions.data(bridge, $0, label: label, to: v) }
                default:
                    outcome = (scene.active?.name).flatMap { name in
                        Int(pair[0]).map { ItemActions.dimension(bridge, of: name, axis: $0, to: v) }
                    }
                }
                said = outcome.map { $0.succeeded ? "sent \($0.python)" : "FAILED \($0.error ?? "")" } ?? "nothing sent"
                said += "; " + itemState(bridge, global: itemIsGlobal)
            case "item-state":
                said = itemState(bridge, global: itemIsGlobal)
            case "tap":
                // What a tap on one vertex leaves in Vertex select mode (the
                // viewport's `editTapSelection` with Set): the viewport's
                // selection changed and pending, the redo panel closed —
                // then time for the views' reads (Normal's refresh, the
                // Sidebar's), which hand it to Blender early.
                guard parts.count == 2, let k = Int(parts[1]), scene.mode == .edit else {
                    said = "tap:<vertex>, in Edit Mode"; break
                }
                var selection = EditSelection()
                selection.vertices = [k]
                selection.history = [.vertex(k)]
                scene.editSelection = selection
                scene.editSelectionPending = true
                bridge.noteSelectionChanged()
                try? await Task.sleep(nanoseconds: 800_000_000)
                said = "the viewport holds vertex \(k) (pending: \(scene.editSelectionPending)); Blender's selection "
                    + (bridge.capture("""
                        import bmesh
                        _o = bpy.context.view_layer.objects.active
                        print([v.index for v in bmesh.from_edit_mesh(_o.data).verts if v.select])
                        """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
            case "frame":
                // The timeline's own frame change (`TimelineDriver.setFrame`,
                // a capture that moves no revision), then nothing but time:
                // what the gizmo's axes are once the views' keys have had
                // their turn, beside Blender's own for the new frame. Not
                // followed by this loop's refresh, which would hide a key
                // that missed the frame.
                guard parts.count == 2, let frame = Int(parts[1]) else { said = "frame:<n>"; break }
                let driver = TimelineDriver()
                driver.bind(scene: scene, session: session, bridge: bridge)
                let before = Self.axesText(scene.orientation.axes)
                let moved = driver.setFrame(frame)
                try? await Task.sleep(nanoseconds: 800_000_000)
                let blender = bridge.capture(OrientationBpy.report)?.split(separator: "\n").last
                    .flatMap { OrientationState.parse(String($0)) }
                print("[bk] transform-ops \(token): frame set \(moved ? "" : "REFUSED ")to \(scene.frameCurrent); "
                      + "the app's \(scene.orientation.label) axes \(before) -> \(Self.axesText(scene.orientation.axes)); "
                      + "Blender's \(Self.axesText(blender?.axes))")
                fflush(stdout)
                continue
            case "undo": session.performUndo()
            case "redo": session.performRedo()
            case "ax":   AccessibilityDump.print("transform-ops")
            case "steps":
                said = "Blender's undo steps: " + (bridge.capture("""
                    import _blenderkit_undo as _bk_u
                    print([_r[2] + ('*' if _r[3] else '') for _r in (_bk_u.blender_steps() or [])][-10:])
                    """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
            default:
                said = "no such token"
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshOrientation()
            print("[bk] transform-ops \(token): \(said); redo panel: \(bridge.adjustable?.name ?? "none"); "
                  + "banner: \(bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")")
            fflush(stdout)
        }
        print("[bk] transform-ops: done"); fflush(stdout)
    }

    /// One gizmo drag through the 3D View's own gesture code
    /// (`MetalViewportView.Coordinator.debugDrag`: `beginGizmo`, `updateGizmo`,
    /// `endGizmo`, in the view on screen), then what Blender holds beside what
    /// the preview showed.
    private func gizmoToken(_ parts: [String], bridge: BpyBridge) -> String {
        guard parts.count == 4, let amount = Float(parts[3]) else { return "gizmo:mode:handle:amount" }
        let mode: TransformGizmo.Mode = parts[1] == "rotate" ? .rotate : parts[1] == "scale" ? .scale : .translate
        let handle: TransformGizmo.Handle
        if let k = Int(parts[2]) { handle = .axis(k) }
        else if parts[2].hasPrefix("p"), let k = Int(parts[2].dropFirst()) { handle = .plane(k) }
        else { handle = .screen }
        var preview: [Float] = [], followers: [Float] = []
        var readout = "", axes = "none", constrained = false, points = false, held = ""
        var moved: [String] = []
        // The commit is a `perform`, which makes a new adjustable operator.
        let generation = bridge.adjustableGeneration
        let began = MetalViewportView.Coordinator.debugDrag(mode: mode, handle: handle, amount: amount) { session, result, blender in
            preview = Self.shownPlaces(scene, session: session)
            followers = Self.watchedPlaces(scene)
            readout = TransformGizmo.readout(result, session: session)
            axes = Self.axesText(simd_float3x3(session.gizmo.axes[0], session.gizmo.axes[1], session.gizmo.axes[2]))
            constrained = blender
            points = session.points != nil
            // An object drag's objects; an edit drag reads the edit mesh.
            moved = session.edit == nil ? session.snapshot.map(\.object.name) : []
            // Mid-drag, the bar's Undo as it presses it: refused while Blender
            // previews the drag (BpySession.constrainedDragOpen), so Blender's
            // active step stays where it was.
            if session.edit == nil && blender {
                let step = { bridge.capture("import _blenderkit_undo as _bk_u\nprint([_r[2] for _r in (_bk_u.blender_steps() or []) if _r[3]][-1:])") ?? "?" }
                let before = step()
                self.session.performUndo()
                held = "\(self.session.gestureHold ?? "no hold"); Undo pressed: step \(before) -> \(step())"
            }
        }
        guard began.hasPrefix("began") else { return began }
        let outcome = bridge.adjustableGeneration == generation ? nil : bridge.lastOutcome
        let followersAfter = Self.watchedPlaces(scene)
        // Blender's places for the objects the drag moved, in the session's
        // order: in Local View Blender's `selected_objects` read here, with no
        // view, also lists selected objects the 3D View does not draw.
        let blender = moved.isEmpty ? Self.blenderPlaces(bridge, scene: scene) : (bridge.capture("""
            _out = []
            for _n in [\(moved.map { Bpy.quote($0) }.joined(separator: ", "))]:
                _m = bpy.data.objects[_n].matrix_world
                _out.append('%.5f %.5f %.5f' % tuple(_m.translation))
                _out.append('%.5f %.5f %.5f %.5f %.5f %.5f' % (*_m.col[0].xyz, *_m.col[1].xyz))
            print(' '.join(_out))
            """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
        let gap = points ? "(points: -points-ops measures them)" : Self.gap(preview, Self.numbers(blender))
        return "\(began); axes \(axes); readout \(readout); "
            + "sent \(outcome.map { $0.succeeded ? $0.python : "FAILED \($0.python): \($0.error ?? "")" } ?? "nothing"); "
            + "preview vs Blender, worst: \(gap)"
            + (constrained ? "; Blender previewed it (constrained), mid-drag hold: \(held); every drawn object's place, "
                + "preview vs after: " + Self.gap(followers, followersAfter) : "")
    }

    private func itemState(_ bridge: BpyBridge, global: Bool) -> String {
        var out = ""
        if scene.mode == .edit, let state = ItemActions.state(bridge, global: global) {
            out += "\(state.medianTitle) \(state.median.map { String(format: "(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) } ?? "-") "
                + (global ? "Global" : "Local") + "; "
                + state.dataRows.map { "\($0.label) \(String(format: "%.3f", $0.value))" }.joined(separator: ", ")
        }
        if let obj = scene.active, let d = ItemActions.dimensions(bridge, of: obj.name) {
            out += String(format: " Dimensions (%.4f, %.4f, %.4f)", d.x, d.y, d.z)
                + String(format: " scale (%.4f, %.4f, %.4f)", obj.scale.x, obj.scale.y, obj.scale.z)
        }
        return out
    }

    private static func axesText(_ m: simd_float3x3?) -> String {
        guard let m else { return "none" }
        func v(_ c: SIMD3<Float>) -> String { String(format: "(%.4f, %.4f, %.4f)", c.x, c.y, c.z) }
        return "X \(v(m.columns.0)) Y \(v(m.columns.1)) Z \(v(m.columns.2))"
    }

    /// What the preview showed: the edited mesh's vertices in the world, or
    /// the moving objects' origins, as one list of numbers.
    private static func shownPlaces(_ scene: BKScene, session: TransformGizmo.Session) -> [Float] {
        if let edit = session.edit {
            let m = edit.object.modelMatrix
            return edit.object.mesh.vertices.flatMap { v -> [Float] in
                let w = (m * SIMD4(v.position, 1)).xyz
                return [w.x, w.y, w.z]
            }
        }
        return session.snapshot.flatMap { entry -> [Float] in
            let m = entry.object.modelMatrix
            return [m.columns.3.x, m.columns.3.y, m.columns.3.z,
                    m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.1.x, m.columns.1.y, m.columns.1.z]
        }
    }

    /// The same list from Blender: the edit mesh in the world, or the selected
    /// objects' world origins and X and Y axes.
    private static func blenderPlaces(_ bridge: BpyBridge, scene: BKScene) -> String {
        bridge.capture("""
            import bmesh
            _o = bpy.context.view_layer.objects.active
            if _o is not None and _o.mode == 'EDIT' and _o.type == 'MESH':
                _m = _o.matrix_world
                _bm = bmesh.from_edit_mesh(_o.data)
                print(' '.join('%.5f %.5f %.5f' % tuple(_m @ v.co) for v in _bm.verts))
            else:
                _out = []
                for _s in bpy.context.selected_objects:
                    _m = _s.matrix_world
                    _out.append('%.5f %.5f %.5f' % tuple(_m.translation))
                    _out.append('%.5f %.5f %.5f %.5f %.5f %.5f' % (*_m.col[0].xyz, *_m.col[1].xyz))
                print(' '.join(_out))
            """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    /// `-object-ops view-stats` / `render-stats`: the last frame each took,
    /// to tell the next one pixel by pixel what changed.
    nonisolated(unsafe) static var lastStatsFrame: [String: [UInt8]] = [:]

    /// Every object's drawn world place, in the scene's order.
    private static func watchedPlaces(_ scene: BKScene) -> [Float] {
        scene.objects.flatMap { o -> [Float] in
            let t = o.modelMatrix.columns.3
            return [t.x, t.y, t.z]
        }
    }

    private static func numbers(_ text: String) -> [Float] {
        text.split(separator: " ").compactMap { Float($0) }
    }

    private static func gap(_ a: [Float], _ b: [Float]) -> String {
        guard a.count == b.count, !a.isEmpty else { return "counts \(a.count) vs \(b.count)" }
        return String(format: "%.2e", zip(a, b).map { abs($0 - $1) }.max() ?? 0)
    }
}
#endif

#if DEBUG
// MARK: - `-relations-ops`

extension LayoutWorkspace {
    /// `-relations-ops a,b,…`: the Outliner's collections, Object ▸
    /// Collection, the Object Constraints tab, the Object menu's Mirror,
    /// Link/Transfer Data, Make Single User, Copy Modifiers, Randomize and
    /// Align rows, and Local View — through the commands their controls send
    /// (`CollectionsBpy`, `ConstraintsBpy`, the `LastOperator` rows,
    /// `LocalViewBpy`, `select(_:)`), once a `-eval64` script has finished.
    /// Collections are named, and looked up in the tree the mirror read, as a
    /// tap finds the row. Tokens:
    /// `select:A+B` (B active), `new:<parent>`, `rename:<name>=<new>`,
    /// `delete:<name>`, `delete-h:<name>`, `toggle:<name>:<exclude|hide|selectable|render>`,
    /// `active:<name>`, `move:<name>`, `link:<name>`, `move-new:<parent>=<name>`,
    /// `link-new:<parent>=<name>`, `con-add:<TYPE>`, `con-del:<name>`, `con-up:<name>`,
    /// `con-down:<name>`, `con-first:<name>`, `con-last:<name>`, `con-set:<name>:<prop>=<python>`,
    /// `con-target:<name>=<object>`, `con-op:<name>:<apply|copy|copy_to_selected|childof_set_inverse|childof_clear_inverse|followpath_path_animate>`,
    /// `mirror:<0|1|2>:<g|l>`, `links:<TYPE>`, `uvs`, `single:<row>`, `modcopy`,
    /// `apply:<all|location|rotation|scale>` (Object ▸ Apply's rows), `randomize`,
    /// `align`, `con-targets:<TYPE>`, `con-copy`, `con-clear`, `adjust:<key>=<value>`,
    /// `redo-panel`, `add:<primitive>`, `local`, `local-remove`, `all`, `invert`, `sel:<Select menu row>`,
    /// `delete-selected` (X), `search:<path>[:<key>=<string>]` (the Operator Search's Run), `frame`, `outliner`,
    /// `gizmo:<mode>:<handle>:<amount>` (as `-transform-ops` has it), `panel:<sheet>`,
    /// `undo`, `redo`, `steps`, `ax`.
    /// After each it prints what Blender holds beside what the app shows.
    func runRelationsOps() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-relations-ops"), i + 1 < args.count, let bridge else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        // A name, or `B/C`: the instance of C under B, for a collection
        // linked into two parents.
        func entry(_ name: String) -> CollectionTree.Entry? {
            guard let tree = scene.collections else { return nil }
            let chain = name.split(separator: "/").map(String.init)
            guard chain.count > 1 else { return tree.entries.first { $0.name == name } }
            return tree.entries.first { e in e.path.map { tree.entry($0)?.name ?? "" } == chain }
        }
        for token in args[i + 1].split(separator: ",").map(String.init) {
            bridge.dismissReport(bridge.report?.id ?? -1)
            let parts = token.split(separator: ":", maxSplits: 2).map(String.init)
            let rest = parts.count > 1 ? String(token.dropFirst(parts[0].count + 1)) : ""
            var said = ""
            var outcome: BpyBridge.Outcome?
            switch parts[0] {
            case "select":
                let names = rest.split(separator: "+").map(String.init)
                outcome = bridge.run(Bpy.objectSelection(names, active: names.last), undo: nil)
            case "new":
                if let e = entry(rest) { outcome = bridge.run(CollectionsBpy.new(inside: e.uid)) } else { said = "no collection \(rest)" }
            case "rename":
                let pair = rest.split(separator: "=").map(String.init)
                if pair.count == 2, let e = entry(pair[0]) { outcome = bridge.run(CollectionsBpy.rename(e.uid, from: e.name, to: pair[1])) }
                else { said = "rename:<name>=<new>" }
            case "delete", "delete-h":
                if let e = entry(rest) { outcome = bridge.run(CollectionsBpy.delete(e.uid, hierarchy: parts[0] == "delete-h")) }
                else { said = "no collection \(rest)" }
            case "toggle":
                let bits = rest.split(separator: ":").map(String.init)
                if bits.count == 2, let e = entry(bits[0]), let tree = scene.collections,
                   let toggle = CollectionsBpy.Toggle(rawValue: bits[1]) {
                    // What the row's button sends: the state it draws, flipped.
                    let drawnOn: Bool
                    switch toggle {
                    case .exclude: drawnOn = !e.excluded
                    case .hide: drawnOn = !e.hidden
                    case .selectable: drawnOn = e.selectable
                    case .render: drawnOn = e.renders
                    }
                    outcome = bridge.run(CollectionsBpy.set(toggle, of: e, in: tree, on: !drawnOn))
                } else { said = "toggle:<name>:<exclude|hide|selectable|render>" }
            case "active":
                if let e = entry(rest), let tree = scene.collections { outcome = bridge.run(CollectionsBpy.setActive(e, in: tree)) }
                else { said = "no collection \(rest)" }
            case "move", "link":
                if let e = entry(rest) { outcome = bridge.run(CollectionsBpy.move(to: e.uid, link: parts[0] == "link")) }
                else { said = "no collection \(rest)" }
            case "move-new", "link-new":
                let pair = rest.split(separator: "=").map(String.init)
                if pair.count == 2, let e = entry(pair[0]) {
                    // The prompt's own path: the name it proposes, then Create.
                    askNewCollection(e.uid, parts[0] == "link-new")
                    said = "prompt proposed \(newCollectionName)"
                    newCollectionName = pair[1]
                    outcome = bridge.run(CollectionsBpy.move(to: e.uid, link: parts[0] == "link-new",
                                                             newCollection: newCollectionName))
                    newCollection = nil
                } else { said = "move-new:<parent>=<name>" }
            case "con-add":
                if let obj = scene.active { outcome = bridge.run(ConstraintsBpy.add(rest, to: obj.name)) }
            case "con-del", "con-up", "con-down", "con-first", "con-last":
                guard let obj = scene.active else { said = "no active object"; break }
                let count = obj.constraints.count
                switch parts[0] {
                case "con-del": outcome = bridge.run(ConstraintsBpy.remove(rest, of: obj.name))
                case "con-up": outcome = bridge.run(ConstraintsBpy.move(rest, of: obj.name, by: -1))
                case "con-down": outcome = bridge.run(ConstraintsBpy.move(rest, of: obj.name, by: 1))
                case "con-first": outcome = bridge.run(ConstraintsBpy.move(rest, of: obj.name, to: 0))
                default: outcome = bridge.run(ConstraintsBpy.move(rest, of: obj.name, to: count - 1))
                }
            case "con-set":
                let bits = rest.split(separator: ":", maxSplits: 1).map(String.init)
                let pair = bits.count == 2 ? bits[1].split(separator: "=", maxSplits: 1).map(String.init) : []
                if let obj = scene.active, pair.count == 2 {
                    outcome = bridge.run(ConstraintsBpy.set(pair[0], of: bits[0], on: obj.name, to: pair[1], undo: pair[0]))
                } else { said = "con-set:<name>:<prop>=<python>" }
            case "con-target":
                let pair = rest.split(separator: "=").map(String.init)
                if let obj = scene.active, !pair.isEmpty {
                    outcome = bridge.run(ConstraintsBpy.setTarget(pair.count > 1 ? pair[1] : nil, of: pair[0], on: obj.name))
                }
            case "con-op":
                let bits = rest.split(separator: ":").map(String.init)
                if let obj = scene.active, bits.count == 2, let op = ConstraintsBpy.Operation(rawValue: bits[1]) {
                    outcome = bridge.run(ConstraintsBpy.operate(op, on: bits[0], of: obj.name))
                } else { said = "con-op:<name>:<operation>" }
            case "mirror":
                let bits = rest.split(separator: ":").map(String.init)
                performObjectRow(.mirror(axis: Int(bits.first ?? "0") ?? 0, local: bits.count > 1 && bits[1] == "l"))
            case "links": performObjectRow(.makeLinksData(rest))
            case "uvs": performObjectRow(.copyUVMaps())
            case "single":
                if let row = LastOperator.SingleUser(rawValue: rest) { performObjectRow(.makeSingleUser(row)) }
                else { said = "single:<object|objectData|objectDataMaterials|materials|objectAnimation|objectDataAnimation>" }
            case "modcopy": performObjectRow(.copyModifiersToSelected())
            // Object ▸ Apply ▸ <all|location|rotation|scale>, as its row runs it.
            case "apply":
                if let what = Bpy.AppliedTransform(rawValue: rest) { applyTransform(what) }
                else { said = "apply:<all|location|rotation|scale>" }
            case "randomize": performObjectRow(.randomizeTransform())
            case "align": performObjectRow(.alignObjects())
            case "con-targets": performObjectRow(.addConstraintWithTargets(rest))
            case "con-copy": performObjectRow(.copyConstraintsToSelected())
            case "con-clear": performObjectRow(.clearObjectConstraints())
            case "adjust":
                let pair = rest.split(separator: "=").map(String.init)
                said = "no adjustable operator"
                if pair.count == 2, let v = Double(pair[1]), var op = bridge.adjustable {
                    op[pair[0]] = v
                    said = bridge.readjust(op).map { "re-ran \($0.python)" } ?? "REFUSED"
                }
            case "redo-panel":
                if let op = bridge.adjustable {
                    said = "\(op.name): " + op.parameters.filter { op.isShown($0) }
                        .map { "\($0.label) \($0.display)" }.joined(separator: ", ")
                } else { said = "no redo panel" }
            case "add":
                // Add ▸ Mesh's row: `perform(LastOperator.add(kind, at: cursor))`.
                if let kind = PrimitiveKind(rawValue: rest) {
                    outcome = bridge.perform(LastOperator.add(kind, at: scene.cursor))
                } else { said = "add:<\(PrimitiveKind.allCases.map(\.rawValue).joined(separator: "|"))>" }
            case "local": outcome = bridge.run(LocalViewBpy.toggle)
            case "local-remove": outcome = bridge.run(LocalViewBpy.removeFrom)
            case "all": select(.all)
            case "invert": select(.invert)
            // Any Select menu row (`SelectMenu.Command(token:)`), through the
            // menu's own `select`, and Delete as X sends it.
            case "sel":
                if let command = SelectMenu.Command(token: rest) { select(command) } else { said = "no such row" }
            case "delete-selected": deleteSelected()
            // More ▸ Operator Search's Run, as its form sends it
            // (`OperatorCatalogue.runCommand` through `bridge.run`):
            // `search:<path>` or `search:<path>:<key>=<string>`.
            case "search":
                let bits = rest.split(separator: ":", maxSplits: 1).map(String.init)
                var arguments: [String: String] = [:]
                if bits.count == 2, let eq = bits[1].firstIndex(of: "=") {
                    arguments[String(bits[1][..<eq])] = String(bits[1][bits[1].index(after: eq)...])
                }
                let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                outcome = bridge.run(OperatorCatalogue.runCommand(path: bits.first ?? "", json: json),
                                     undo: bits.first ?? "")
            case "frame":
                said = String(format: "camera target (%.4f, %.4f, %.4f) distance %.4f, viewport %.0f x %.0f",
                              camera.target.x, camera.target.y, camera.target.z, camera.distance,
                              viewportSize.width, viewportSize.height)
            case "outliner":
                said = scene.outlinerTree().map { row -> String in
                    let pad = String(repeating: ".", count: row.depth)
                    switch row.item {
                    case .collection(let e):
                        return pad + "[\(e.name)\(e.active ? "*" : "")\(e.excluded ? " excl" : "")\(e.hidden ? " hid" : "")\(e.selectable ? "" : " unsel")\(e.renders ? "" : " norender")]"
                    case .object(let o):
                        return pad + o.name + (row.excluded ? "(x)" : "") + (o.visible ? "" : "(not drawn)")
                    }
                }.joined(separator: " ")
            case "gizmo":
                // A gizmo drag, as `-transform-ops gizmo:` makes one: through
                // the viewport's own session, preview and commit — with
                // Blender previewing a drag a constraint decides.
                said = gizmoToken(token.split(separator: ":", maxSplits: 3).map(String.init), bridge: bridge)
            case "constrained-preview":
                // The negative control, read by `BpyBridge.beginConstrainedDrag`
                // itself, so it switches the gizmo's and the fields' path.
                BpyBridge.debugSkipConstrainedPreview = rest == "off"
                said = "Blender previews constrained drags: \(!BpyBridge.debugSkipConstrainedPreview)"
            case "panel":
                panel = rest.isEmpty ? nil : rest
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                said = "panel \(panel ?? "none")"
            case "undo": session.performUndo()
            case "redo": session.performRedo()
            case "ax": AccessibilityDump.print("relations-ops")
            case "steps":
                said = "Blender's undo steps: " + (bridge.capture("""
                    import _blenderkit_undo as _bk_u
                    print([_r[2] + ('*' if _r[3] else '') for _r in (_bk_u.blender_steps() or [])][-12:])
                    """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
            default:
                said = "no such token"
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let outcome, !outcome.succeeded { said += " FAILED: \(outcome.error ?? "?")" }
            if let report = bridge.report { said += " banner: \(report.operation): \(report.message)" }
            print("[bk] relations-ops \(token): \(said); app \(Self.relationsShown(scene)); Blender \(Self.relationsHeld(bridge))")
            fflush(stdout)
        }
        print("[bk] relations-ops: done"); fflush(stdout)
    }

    /// What the app shows: selection, active, Local View, every object's
    /// drawn state, collections and constraints, the active collection.
    static func relationsShown(_ scene: BKScene) -> String {
        let tree = scene.collections
        let objects = scene.objects.map { o -> String in
            let colls = tree?.collections(holding: o.name).map(\.name).joined(separator: "+") ?? "-"
            let cons = o.constraints.map { "\($0.name)\($0.enabled ? "" : "(off)")@\(LastOperator.number(Double($0.influence)))" }
                .joined(separator: "+")
            let m = o.modelMatrix.columns.3
            let sx = simd_length(SIMD3(o.modelMatrix.columns.0.x, o.modelMatrix.columns.0.y, o.modelMatrix.columns.0.z))
            let det = simd_determinant(o.modelMatrix)
            return "\(o.name){\(scene.selection.contains(o.id) ? "sel," : "")\(o.visible ? "drawn" : "hidden")\(o.outsideLocalView ? ",notlocal" : "")"
                + String(format: ",at %.3f %.3f %.3f,sx %.3f,det %.2f", m.x, m.y, m.z, sx, det)
                + ",in \(colls)" + (cons.isEmpty ? "" : ",cons \(cons)") + "}"
        }.joined(separator: " ")
        let local = scene.localView.map { "local[\($0.objects.sorted().joined(separator: "+"))]" } ?? "no local view"
        return "active \(scene.active?.name ?? "none"); \(local); active collection \(tree?.active?.name ?? "?"); \(objects)"
    }

    /// The same, from Blender.
    static func relationsHeld(_ bridge: BpyBridge) -> String {
        bridge.capture("""
            import _blenderkit_localview as _bk_lv
            _vl = bpy.context.view_layer
            _m = _bk_lv.members()
            _out = ['active ' + (_vl.objects.active.name if _vl.objects.active else 'none'),
                    ('local[' + '+'.join(sorted(_m)) + ']') if _m is not None else 'no local view',
                    'active collection ' + _vl.active_layer_collection.name]
            for _o in bpy.context.scene.objects:
                _t = _o.matrix_world.translation
                _c = '+'.join(c.name for c in _o.users_collection)
                _k = '+'.join(c.name + ('' if c.enabled else '(off)') + '@%g' % round(c.influence, 4) for c in _o.constraints)
                _out.append('%s{%s%s,at %.3f %.3f %.3f,sx %.3f,det %.2f,in %s%s}' % (_o.name, 'sel,' if _o.select_get() else '',
                    'visible' if _o.visible_get() else 'hidden', _t.x, _t.y, _t.z, _o.matrix_world.col[0].xyz.length,
                    _o.matrix_world.determinant(), _c, (',cons ' + _k) if _k else ''))
            _cl = []
            def _walk(_l, _d):
                _c = _l.collection
                _cl.append('.' * _d + '[' + _l.name + (' excl' if _l.exclude else '') + (' hid' if _l.hide_viewport else '')
                           + (' unsel' if _c.hide_select else '') + (' norender' if _c.hide_render else '') + ']'
                           + ','.join(o.name for o in _c.objects))
                for _ch in _l.children:
                    _walk(_ch, _d + 1)
            _walk(_vl.layer_collection, 0)
            print('; '.join(_out) + '; tree ' + ' '.join(_cl))
            """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }
}
#endif

// MARK: - `-textimage-ops`

#if DEBUG
extension LayoutWorkspace {
    /// `-textimage-ops a,b,…` (round 4, group 8): a text object's Body Text
    /// and Data tab rows, Tab on a text, Add ▸ Image ▸ Reference... and
    /// Background..., the Empty panel's image rows, and what the 3D View
    /// draws for the pictures — through the calls the controls make, once a
    /// `-eval64` script has finished. Tokens:
    /// `select:<name>`, `add-text`, `body:<text>` (`\n` for a new line; the
    /// field's own end-of-edit: `NameDraft` then `TextBpy.setBody`),
    /// `text:<key>=<number or ID>` (a Data tab row), `tab` (whether Tab opened
    /// the Body Text sheet, then closes it), `image-ref:<file>`,
    /// `image-bg:<file>`, `image-plane:<file>` (`BpyBridge.addReferenceImage`,
    /// the pickers' call, which converts the file as it converts theirs),
    /// `empty:<key>=<python>` (an Empty panel row on the active object),
    /// `view:<top|front|back|right|left|persp|ortho>`, `orbit:<azimuth°>:<elevation°>`,
    /// `images` (what `ImageEmptyDraw` draws for this view), `capture:<file.png>`
    /// (the 3D View's frame, read back, `ViewportRenderer.captureFrame`, with
    /// how many pixels differ from the background), `culling:old|blender`
    /// (`ViewportRenderer.surfaceCull`'s negative control),
    /// `undo`, `redo`, `steps`. After each it prints what the app shows beside
    /// what Blender holds for the active object.
    func runTextImageOps() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-textimage-ops"), i + 1 < args.count, let bridge else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        for token in args[i + 1].split(separator: ",").map(String.init) {
            bridge.dismissReport(bridge.report?.id ?? -1)
            let head = token.split(separator: ":", maxSplits: 1).map(String.init)
            let rest = head.count > 1 ? head[1] : ""
            var said = ""
            var outcome: BpyBridge.Outcome?
            switch head[0] {
            case "select":
                outcome = bridge.run(Bpy.objectSelection([rest], active: rest), undo: nil)
            case "add-text":
                outcome = bridge.add(.text, at: scene.cursor, view: camera)
            case "body":
                guard let obj = scene.active, case .text(let settings)? = obj.dataSettings else {
                    said = "the active object shows no text"
                    break
                }
                let typed = rest.replacingOccurrences(of: "\\n", with: "\n")
                if let text = NameDraft(text: typed).ending(over: settings.body) {
                    outcome = bridge.run(TextBpy.setBody(text, object: obj.name), undo: TextBpy.bodyUndo)
                } else {
                    said = "unchanged, nothing sent"
                }
            case "text":
                let pair = rest.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, let obj = scene.active,
                      let label = TextSettings.rows.first(where: { $0.key == pair[0] })?.label else {
                    said = "text:<key>=<value> on a text object"
                    break
                }
                let python = Float(pair[1]).map { TextBpy.python(pair[0], $0) } ?? "'\(pair[1])'"
                outcome = bridge.run(TextBpy.set(pair[0], to: python, object: obj.name), undo: label)
            case "tab":
                toggleEditing()
                try? await Task.sleep(nanoseconds: 800_000_000)
                said = "Body Text sheet " + (bodyTextObject.map { "opened on \($0.name)" } ?? "not opened")
                    + "; mode \(scene.mode.bpyMode)"
                bodyTextObject = nil
            case "image-ref", "image-bg", "image-plane":
                let url = URL(fileURLWithPath: rest)
                guard let data = try? Data(contentsOf: url) else { said = "cannot read \(rest)"; break }
                let kind: ReferenceImages.Kind = head[0] == "image-ref" ? .reference
                    : head[0] == "image-bg" ? .background : .plane
                outcome = bridge.addReferenceImage(kind, data: data, name: url.lastPathComponent,
                                                   at: scene.cursor, view: camera)
            case "empty":
                let pair = rest.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, let obj = scene.active else { said = "empty:<key>=<python>"; break }
                outcome = bridge.run(ReferenceImages.set(pair[0], to: pair[1], object: obj.name), undo: pair[0])
            case "view":
                if let viewpoint = ViewportCamera.Viewpoint(rawValue: rest) {
                    camera.snap(to: viewpoint)
                } else {
                    camera.isOrthographic = rest == "ortho"
                }
                said = "camera \(camera.isOrthographic ? "orthographic" : "perspective") eye \(camera.eye)"
            case "orbit":
                let degrees = rest.split(separator: ":").compactMap { Float($0) }
                if degrees.count == 2 {
                    camera.azimuth = degrees[0] * .pi / 180
                    camera.elevation = degrees[1] * .pi / 180
                }
                said = "camera eye \(camera.eye)"
            case "images":
                let view = OverlayView(camera: camera, size: CGSize(width: 800, height: 600))
                let quads = ImageEmptyDraw.quads(in: scene, view: view)
                said = "\(quads.count) pictures drawn: " + quads.map {
                    "\($0.object) pass \($0.pass) blend \($0.alphaBlend) tint \($0.tint) file \(($0.file as NSString).lastPathComponent)"
                }.joined(separator: " | ")
                for obj in scene.objects {
                    guard case .empty(let e)? = obj.overlayDisplay, e.kind == .image else { continue }
                    said += "; \(obj.name): frame \(e.frameVisible(perspective: view.isPerspective)) "
                        + "picture \(e.pictureVisible(world: obj.modelMatrix, view: view)) depth \(e.depth.rawValue) "
                        + "side \(e.side.rawValue) alpha \(e.useAlpha) \(e.color.w) data \(e.imageHasData)"
                }
            case "capture":
                guard let device = MTLCreateSystemDefaultDevice(),
                      let renderer = ViewportRenderer(device: device, scene: scene, camera: camera),
                      let frame = renderer.captureFrame(points: CGSize(width: 800, height: 600), scale: 1,
                                                        clear: MTLClearColor(red: 0.188, green: 0.188,
                                                                             blue: 0.188, alpha: 1))
                else { said = "capture failed"; break }
                said = Self.writePNG(frame, to: rest)
                // How much of the frame is not the background (0.188 grey,
                // 48 in a byte): what the surfaces and overlays cover.
                var covered = 0, left = 0
                for k in stride(from: 0, to: frame.rgba.count, by: 4)
                where abs(Int(frame.rgba[k]) - 48) + abs(Int(frame.rgba[k + 1]) - 48) + abs(Int(frame.rgba[k + 2]) - 48) > 6 {
                    covered += 1
                    if (k / 4) % frame.width < frame.width / 2 { left += 1 }
                }
                said += "; \(covered) of \(frame.width * frame.height) px differ from the background "
                    + "(left half \(left), right half \(covered - left))"
                let view = OverlayView(camera: camera, size: CGSize(width: 800, height: 600))
                // The centres of the picture's four quarters, bottom left,
                // bottom right, top left, top right (uv from the frame's
                // bottom-left corner), where the view shows them: a picture
                // with four colours tells a turn or a flip from the right way
                // up, which one with two halves could not (round 4's review).
                for quad in ImageEmptyDraw.quads(in: scene, view: view) {
                    for (u, v) in [(Float(0.25), Float(0.25)), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                        let c = quad.corners
                        let bottom = c[0] + (c[1] - c[0]) * u, top = c[3] + (c[2] - c[3]) * u
                        guard let p = view.project(bottom + (top - bottom) * v) else { continue }
                        let x = min(max(Int(p.x), 0), frame.width - 1), y = min(max(Int(p.y), 0), frame.height - 1)
                        let k = (y * frame.width + x) * 4
                        said += "; \(quad.object) uv (\(u), \(v)) at (\(x), \(y)) is RGB \(frame.rgba[k]) \(frame.rgba[k + 1]) \(frame.rgba[k + 2])"
                    }
                }
                // Control: the same pixel with the overlays off (no pictures).
                if let first = ImageEmptyDraw.quads(in: scene, view: view).first,
                   let p = view.project(first.corners[0] + (first.corners[1] - first.corners[0]) * 0.25
                                        + (first.corners[3] - first.corners[0]) * 0.5) {
                    var off = ViewportOptions()
                    off.showOverlays = false
                    if let device = MTLCreateSystemDefaultDevice(),
                       let bare = ViewportRenderer(device: device, scene: scene, camera: camera) {
                        bare.options = off
                        if let plain = bare.captureFrame(points: CGSize(width: 800, height: 600), scale: 1,
                                                         clear: MTLClearColor(red: 0.188, green: 0.188, blue: 0.188, alpha: 1)) {
                            let x = min(max(Int(p.x), 0), plain.width - 1), y = min(max(Int(p.y), 0), plain.height - 1)
                            let k = (y * plain.width + x) * 4
                            said += "; control, overlays off: (\(x), \(y)) is RGB \(plain.rgba[k]) \(plain.rgba[k + 1]) \(plain.rgba[k + 2])"
                        }
                    }
                }
            // `culling:old` / `culling:blender`, as `-object-ops` has them,
            // so a capture before and after is one run.
            case "culling":
                ViewportRenderer.debugCullBackFaces = rest == "old"
                said = "surface passes cull \(ViewportRenderer.surfaceCull == .back ? "back faces" : "nothing")"
            case "undo": session.performUndo()
            case "redo": session.performRedo()
            case "steps":
                said = "Blender's undo steps: " + (bridge.capture("""
                    import _blenderkit_undo as _bk_u
                    print([_r[2] + ('*' if _r[3] else '') for _r in (_bk_u.blender_steps() or [])][-10:])
                    """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?")
            default:
                said = "no such token"
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let outcome, !outcome.succeeded { said += " FAILED: \(outcome.error ?? "?")" }
            if let report = bridge.report { said += " banner: \(report.operation): \(report.message)" }
            if head[0] == "text" || head[0] == "body" { said += "; " + BudgetProbe.report(bridge) }
            print("[bk] textimage-ops \(token): \(said); app \(Self.textImageShown(scene)); Blender \(Self.textImageHeld(bridge))")
            fflush(stdout)
        }
        print("[bk] textimage-ops: done"); fflush(stdout)
    }

    /// The active object as the app shows it: a text's body and settings, an
    /// image empty's picture settings, the drawn vertex count.
    static func textImageShown(_ scene: BKScene) -> String {
        guard let obj = scene.active else { return "no active object" }
        var out = "\(obj.name) \(obj.blenderType) \(obj.mesh.vertices.count) verts"
        if case .text(let t)? = obj.dataSettings {
            out += " body=\(t.body.debugDescription) " + TextSettings.rows.map { "\($0.key)=\(t.values[$0.key] ?? "-")" }
                .joined(separator: " ")
        }
        if case .empty(let e)? = obj.overlayDisplay {
            out += " \(e.kind.rawValue) image=\(e.imageName) data=\(e.imageHasData) depth=\(e.depth.rawValue) "
                + "side=\(e.side.rawValue) ortho=\(e.showOrthographic) persp=\(e.showPerspective) "
                + "axis=\(e.onlyAxisAligned) alpha=\(e.useAlpha) opacity=\(e.color.w) size=\(e.size) "
                + "offset=\(e.imageOffset) file=\((e.imageFile as NSString).lastPathComponent)"
        }
        return out
    }

    /// The same, read from Blender.
    static func textImageHeld(_ bridge: BpyBridge) -> String {
        bridge.capture("""
            import bpy
            _o = bpy.context.view_layer.objects.active
            if _o is None:
                print('no active object')
            elif _o.type == 'FONT':
                _d = _o.data
                _e = _o.evaluated_get(bpy.context.evaluated_depsgraph_get())
                _m = _e.to_mesh()
                print(_o.name, _o.mode, len(_m.vertices), 'verts body=%r' % _d.body, ' '.join('%s=%s' % (_k, getattr(_d, _k)) for _k in ('resolution_u', 'fill_mode', 'offset', 'extrude', 'bevel_depth', 'bevel_resolution', 'size', 'shear', 'align_x', 'align_y', 'space_character', 'space_word', 'space_line', 'offset_x', 'offset_y')))
                _e.to_mesh_clear()
            elif _o.type == 'EMPTY':
                _i = _o.data
                print(_o.name, _o.empty_display_type, 'image=%s' % (_i.name if _i else None), 'packed=%s' % (bool(_i.packed_file) if _i else None), 'size=%s' % ((tuple(_i.size) if _i else None),), 'depth=%s side=%s ortho=%s persp=%s axis=%s alpha=%s opacity=%.3f dsize=%.3f offset=%s rot=%s' % (_o.empty_image_depth, _o.empty_image_side, _o.show_empty_image_orthographic, _o.show_empty_image_perspective, _o.show_empty_image_only_axis_aligned, _o.use_empty_image_alpha, _o.color[3], _o.empty_display_size, tuple(round(_c, 3) for _c in _o.empty_image_offset), tuple(round(_c, 3) for _c in _o.rotation_euler)))
            else:
                print(_o.name, _o.type)
            """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    static func writePNG(_ frame: (width: Int, height: Int, rgba: [UInt8]), to path: String) -> String {
        var pixels = frame.rgba
        let written: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: frame.width, height: frame.height,
                                          bitsPerComponent: 8, bytesPerRow: frame.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                    "public.png" as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination)
        }
        return written ? "captured \(frame.width) x \(frame.height) to \(path)" : "could not write \(path)"
    }
}
#endif

#if DEBUG
extension BKObject {
    /// DEBUG launch hooks (`-object-ops normals`, `-sculpt-stroke`): the
    /// normals the 3D View shades this mesh with (`MeshData.shadingNormal`),
    /// corner by corner, against the corner normals Blender's Solid view
    /// draws, read from Blender's evaluated mesh; and, as the control, the
    /// vertex normals the 3D View drew before against the same. Only for the
    /// active object, which is the one the capture reads.
    func shadingReport(_ bridge: BpyBridge) -> String {
        let held = bridge.capture("""
            import json
            _o = bpy.context.view_layer.objects.active
            if _o.mode == 'EDIT':
                _o.update_from_editmode()
            _e = _o.evaluated_get(bpy.context.evaluated_depsgraph_get())
            _m = _e.to_mesh()
            _m.calc_loop_triangles()
            _hidden = _o.mode == 'EDIT'
            _n = [round(_c, 6) for _t in _m.loop_triangles
                  if not (_hidden and _m.polygons[_t.polygon_index].hide)
                  for _l in _t.loops for _c in _m.corner_normals[_l].vector]
            print(json.dumps({'domain': _m.normals_domain, 'n': _n}))
            _e.to_mesh_clear()
            """) ?? ""
        guard let data = held.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domain = json["domain"] as? String,
              let flat = (json["n"] as? [NSNumber])?.map(\.floatValue) else {
            return "Blender's corner normals unread: \(held)"
        }
        guard flat.count == 3 * mesh.indices.count else {
            return "Blender has \(flat.count / 3) triangle corners, the app \(mesh.indices.count)"
        }
        // atan2 in doubles: acos of a Float dot cannot tell 0° from 0.028°.
        func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let x = SIMD3<Double>(a), y = SIMD3<Double>(b)
            return Float(atan2(simd_length(simd_cross(x, y)), simd_dot(x, y)) * 180 / .pi)
        }
        var shaded: Float = 0, byVertex: Float = 0
        for c in mesh.indices.indices {
            let blender = SIMD3(flat[3 * c], flat[3 * c + 1], flat[3 * c + 2])
            shaded = max(shaded, degrees(mesh.shadingNormal(corner: c), blender))
            byVertex = max(byVertex, degrees(mesh.vertices[Int(mesh.indices[c])].normal, blender))
        }
        return "Blender's \(domain) normals; the 3D View shades \(name) by its "
            + "\(mesh.shadingFits ? "\(mesh.shadingDomain)" : "vertex") normals, \(mesh.indices.count) corners, "
            + "worst \(String(format: "%.4f", shaded))° from Blender's; "
            + "control, the vertex normals: worst \(String(format: "%.4f", byVertex))°"
    }
}
#endif

/// Whether a horizontal scroll view shows its content's end, for the fade
/// that says a header runs on past the screen (`LayoutWorkspace.headerRow`).
/// iOS 17 cannot tell, and keeps the fade while the content is wider than the
/// view.
private struct ScrolledToEnd: ViewModifier {
    @Binding var atEnd: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.x + g.containerSize.width >= g.contentSize.width - 2
            } action: { _, end in atEnd = end }
        } else {
            content
        }
    }
}

// MARK: - Test All Features

extension LayoutWorkspace {
    /// The functions of this view Test All Features calls as its controls
    /// do, which live in its private state: the toolbar's tool (`choose`),
    /// the mode menu's Weight Paint and Vertex Paint (`enterPaintMode`), and
    /// Viewport Shading and X-Ray, set as their menu rows set them, and the
    /// view's camera, which its gestures move. Thin wrappers, nothing more
    /// (`FeatureTestRunner`).
    var featureTestDoor: FeatureTestLayoutDoor {
        FeatureTestLayoutDoor(camera: { camera },
                              setCamera: { camera = $0 },
                              choose: { choose($0) },
                              enterPaintMode: { enterPaintMode($0) },
                              setShading: { shading = $0 },
                              shading: { shading },
                              setXRay: { options.xray = $0 },
                              tool: { tool })
    }
}

/// The 3D View's bottom row: the active object's name, and what the drag under
/// way is doing ("Orbit  40°, 25°"). A view of its own so that a drag, which
/// changes the readout every step, redraws this row and not the whole 3D View
/// (`MetalViewportView.Coordinator.moveCamera`).
private struct ViewportInfoRow: View {
    var scene: BKScene

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text(scene.active?.name ?? "Tap an object to select it")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let readout = scene.dragReadout { Text(readout).font(.system(size: 12, design: .monospaced)) }
            }.padding(14).background(BTheme.header.opacity(0.9))
        }.allowsHitTesting(false)
    }
}
