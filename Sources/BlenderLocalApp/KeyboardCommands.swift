import SwiftUI

// Magic Keyboard support: every command a tab offers, in the menu bar on
// iPadOS 26 and in the hold-⌘ overlay before it, with Blender's key where
// Blender has one and the Mac's where it does not.
//
// Each workspace publishes what it can do as a focused scene value while it is
// on screen, and the menus are built from those values. A command therefore
// exists only in the tab it belongs to. That matters most for the 3D View's
// single-letter keys: they are built only while the 3D View is showing, so G,
// R, S and the digits can never reach the script editor as anything but typing.

/// What every tab offers.
struct AppKeyActions {
    var workspace: Workspace
    /// The operator search is open over the tab, and its field is where the
    /// keyboard's letters are meant to go.
    var searchVisible: Bool
    var showWorkspace: (Workspace) -> Void
    var searchOperators: () -> Void
}

/// What the Scripting tab offers while it is on screen.
struct ScriptingKeyActions {
    var isRunning: Bool
    var run: () -> Void
    var stop: () -> Void
    var newScript: () -> Void
    var save: () -> Void
    var clearConsole: () -> Void
    /// Moves the keyboard between the editor and the console prompt.
    var switchEditorAndConsole: () -> Void
    /// Runs one of Monaco's own editor actions, by its id.
    var editor: (String) -> Void
    /// +1 or -1 steps the text size of whichever pane has the keyboard — the
    /// console when it does, the editor otherwise; 0 puts it back.
    var textSize: (Int) -> Void
}

/// What the 3D View offers while it is on screen and nothing is taking the
/// keyboard's letters — no sheet, no operator search, no text field.
struct ViewportKeyActions {
    var isRunning: Bool
    var hasActiveObject: Bool
    var editing: Bool
    /// Editing a mesh, not a curve's or a lattice's points: what Ctrl+L's
    /// Select Linked ▸ Linked (`mesh.select_linked`) acts on.
    var editingMesh = false
    /// Vertex, edge or face, while editing.
    var selectMode: MeshSelectMode
    var canUndo: Bool
    var canRedo: Bool
    var setTool: (ActiveTool) -> Void
    /// The Knife's Confirm (Return) and Cancel (Escape), Blender's keys for
    /// them; nil while there is no path to confirm or cancel.
    var knifeConfirm: (() -> Void)? = nil
    var knifeCancel: (() -> Void)? = nil
    /// The Measure tool's Ruler Remove (X), while a ruler is active; nil
    /// otherwise. Delete reaches it through `deleteSelected`.
    var rulerRemove: (() -> Void)? = nil
    var deleteSelected: () -> Void
    var duplicate: () -> Void
    var selectAll: () -> Void
    var deselectAll: () -> Void
    var invertSelection: () -> Void
    /// Blender's L (false) and Shift+L (true): Select Linked under the
    /// pointer, while a mesh is being edited; nil otherwise.
    var selectLinkedPick: ((Bool) -> Void)? = nil
    /// A row of the Select menu, as the menu sends it.
    var selectRow: (SelectMenu.Command) -> Void = { _ in }
    var toggleEditing: () -> Void
    var setSelectMode: (MeshSelectMode) -> Void
    var mesh: (LastOperator.Mesh) -> Void
    var add: (PrimitiveKind) -> Void
    /// What the selection offers Set Origin and Apply — read back from
    /// Blender, so a greyed-out row means Blender has nothing to do.
    var objectTransform: ObjectTransformState
    var setOrigin: (Bpy.OriginChoice) -> Void
    var applyTransform: (Bpy.AppliedTransform) -> Void
    /// What Duplicate Linked, Join, Parent and Convert may do; they run
    /// through `perform`.
    var objectRelations: ObjectRelationState
    /// Object ▸ Show/Hide, or Mesh ▸ Show/Hide while editing.
    var showHide: (Bpy.ShowHide) -> Void
    /// Mesh ▸ Separate, while editing.
    var separate: (Bpy.SeparateType) -> Void
    /// Shade Smooth (true) and Shade Flat (false).
    var shade: (Bool) -> Void
    /// An adjustable operator: Shade Auto Smooth, QuadriFlow Remesh.
    var perform: (LastOperator) -> Void
    /// The active object is a mesh, which those need.
    var activeIsMesh: Bool
    /// Whether Blender has the Essentials library Auto Smooth loads from;
    /// nil until it has been asked (`BpySession.essentialsLibrary`).
    var essentialsLibrary: Bool?
    var frameAll: () -> Void
    var frameSelected: () -> Void
    var view: (ViewportCamera.Viewpoint) -> Void
    /// Blender's numpad 0: look through the scene's camera. Nil when the scene
    /// has none, which is what greys the item out.
    var lookThroughCamera: (() -> Void)?
    var aimCameraAtView: (() -> Void)?
    var togglePerspective: () -> Void
    var toggleWireframe: () -> Void
    /// Blender's Alt+Z: X-Ray, which the select tools also honour — with it
    /// on they take what the surface hides.
    var toggleXRay: () -> Void
    /// Below 1 moves the camera in, above 1 out.
    var zoom: (Float) -> Void
    var undo: () -> Void
    var redo: () -> Void
    var showOutliner: () -> Void
    /// The Properties editor (More ▸ Properties). N used to open it, in place
    /// of the Sidebar nothing showed; N is the Sidebar's again.
    var showProperties: () -> Void
    /// View ▸ Sidebar, on Blender's N: whether it is out, and the toggle.
    var sidebarShown: Bool = false
    var toggleSidebar: () -> Void = {}
    /// Blender's collection tree, for Object ▸ Collection's Move to and Link
    /// to Collection menus; nil where Blender sent none.
    var collections: CollectionTree? = nil
    /// One command of the Object menu's that has no redo panel (Move and Link
    /// to Collection, Local View).
    var run: (BlenderCommand) -> Void = { _ in }
    /// Move / Link to New Collection's name prompt, inside a collection.
    var askNewCollection: (Int, Bool) -> Void = { _, _ in }
    /// Blender's Local View: whether the 3D View is in it, and whether Toggle
    /// Local View has something to do.
    var inLocalView: Bool = false
    var canToggleLocalView: Bool = false

    // MARK: Blender's pop-up menus (ViewportMenus.swift) and the rest of its keys

    /// Opens one of Blender's menus at the pointer.
    var openMenu: (ViewportMenu) -> Void = { _ in }
    /// The Add menu's rows past Mesh: curves, text, lattice, empties, images,
    /// lights and the camera (ObjectAddMenus.swift).
    var addObject: (ObjectAddition) -> Void = { _ in }
    var addImage: ((ReferenceImages.Kind) -> Void)? = nil
    var mode: InteractionMode = .object
    /// Editing a curve's or a lattice's points rather than a mesh.
    var editingCurve = false
    var editingLattice = false
    /// How many objects are selected, for Join's row (Blender draws it only
    /// for more than one).
    var selectedCount = 0
    /// Blender's type of the active object (`MESH`, `CAMERA`, `LIGHT`…).
    var activeType: String? = nil
    var activeName: String? = nil
    /// While a mesh is edited, how many vertices, edges and faces are
    /// selected, when the mirror has counted them: the Edit Mode context
    /// menu draws some rows only past a count, as Blender's does. Asked when
    /// a menu opens — read here, it would redraw the 3D View's screen on
    /// every change of the counts (KeyedRefresh.swift).
    var selectedElements: () -> (vertices: Int, edges: Int, faces: Int)? = { nil }
    var shading: ViewportShading = .solid
    var setShading: (ViewportShading) -> Void = { _ in }
    /// Asked when a menu opens, for the same reason: with Local on an
    /// animated object it changes at every frame.
    var orientation: () -> TransformOrientation? = { nil }
    var setOrientation: (TransformOrientation) -> Void = { _ in }
    /// The modes the active object can go to, and going there.
    var modes: [InteractionMode] = []
    var enterMode: (InteractionMode) -> Void = { _ in }
    /// Mesh ▸ Vertex ▸ Extrude to Cursor or Add (Ctrl+right click).
    var extrudeToCursor: () -> Void = {}
    /// Transform ▸ Shear, in Object or Edit Mode.
    var shear: () -> Void = {}
    var snap: (SnapBpy) -> Void = { _ in }
    var setActiveCamera: (() -> Void)? = nil
    var copyObjects: () -> Void = {}
    var pasteObjects: () -> Void = {}
    /// F2: Rename Active Object…
    var rename: (() -> Void)? = nil
    var insertKeyframe: () -> Void = {}
    var deleteKeyframes: () -> Void = {}
    /// Numpad 4/6/8/2 (`view3d.view_orbit`), Numpad 9, Ctrl+Numpad 4/6/8/2.
    var orbit: (_ azimuth: Float, _ elevation: Float) -> Void = { _, _ in }
    var pan: (_ dx: Float, _ dy: Float) -> Void = { _, _ in }
    /// Snapping (Shift+Tab) and Proportional Editing (O): Blender's tool
    /// settings, as the header's popovers set them.
    var toggleSnap: () -> Void = {}
    var toggleProportional: () -> Void = {}
    /// Toolbar (T), Maximize Area (Ctrl+Space), Adjust Last Operation (F9),
    /// Repeat Last (Shift+R).
    var toggleToolbar: () -> Void = {}
    var maximize: () -> Void = {}
    var adjustLastOperation: () -> Void = {}
    var canRepeatLast: () -> Bool = { false }
    var repeatLast: () -> Void = {}
    /// F3, Blender's Search: the Operator Search.
    var searchOperators: () -> Void = {}
    /// F12, Blender's Render Image: the Render panel, rendering at once; nil
    /// where the 3D View has no Render panel.
    var render: (() -> Void)? = nil
    /// The brush panel a right-click opens in Sculpt Mode, Vertex Paint and
    /// Weight Paint (BrushContextPanel.swift); nil in the other modes.
    var brushPanel: (() -> AnyView)? = nil

    // MARK: November 7, later: Blender's pies and the rest of its keys

    /// Period's Pivot Point pie and Shift+O's Proportional Editing Falloff
    /// pie: the settings, asked when the pie opens, and setting them.
    var pivot: () -> TransformPivot = { .medianPoint }
    var setPivot: (TransformPivot) -> Void = { _ in }
    var falloff: () -> MeshEditor.ProportionalFalloff = { .smooth }
    var setFalloff: (MeshEditor.ProportionalFalloff) -> Void = { _ in }
    /// Alt+O, Connected Only (`use_proportional_connected`), while editing;
    /// Ctrl+Period, Transform Origins (`use_transform_data_origin`).
    var toggleConnected: () -> Void = {}
    var toggleTransformOrigins: () -> Void = {}
    /// Shift+Alt+Z: Show Overlays.
    var toggleOverlays: () -> Void = {}
    /// Ctrl+Numpad 0 (Ctrl+0 on the number row): Set Active Object as Camera —
    /// the active object becomes the scene's camera and the view looks
    /// through it. Nil without an active object.
    var objectAsCamera: (() -> Void)? = nil
    /// The toolbar's tool in hand, which Shift+Space's toolbar ticks.
    var tool: ActiveTool = .select
    /// U's UV Mapping rows.
    var uv: (UVOperator) -> Void = { _ in }
}

private struct AppKeyActionsKey: FocusedValueKey { typealias Value = AppKeyActions }
private struct ScriptingKeyActionsKey: FocusedValueKey { typealias Value = ScriptingKeyActions }
private struct ViewportKeyActionsKey: FocusedValueKey { typealias Value = ViewportKeyActions }

extension FocusedValues {
    var appKeys: AppKeyActions? {
        get { self[AppKeyActionsKey.self] }
        set { self[AppKeyActionsKey.self] = newValue }
    }
    var scriptingKeys: ScriptingKeyActions? {
        get { self[ScriptingKeyActionsKey.self] }
        set { self[ScriptingKeyActionsKey.self] = newValue }
    }
    var viewportKeys: ViewportKeyActions? {
        get { self[ViewportKeyActionsKey.self] }
        set { self[ViewportKeyActionsKey.self] = newValue }
    }
}

struct BlenderCommands: Commands {
    @AppStorage(BpySession.offMainThreadKey) private var scriptsOffMainThread = true
    @FocusedValue(\.appKeys) private var app
    @FocusedValue(\.scriptingKeys) private var script
    @FocusedValue(\.viewportKeys) private var viewport
    @FocusedValue(\.objectAddActions) private var objectAdd

    /// The 3D View's commands — but not while the operator search is open over
    /// it, when G is a letter to search for rather than the Move tool.
    private var view3D: ViewportKeyActions? {
        guard let viewport, app?.searchVisible != true else { return nil }
        return viewport
    }

    var body: some Commands {
        #if DEBUG
        let _ = FocusLog.count("menu")
        #endif
        CommandGroup(replacing: .newItem) {
            Button("New Script") { script?.newScript() }
                .keyboardShortcut("n")
                .disabled(script == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Script") { script?.save() }
                .keyboardShortcut("s")
                .disabled(script == nil)
        }
        // Undo in the 3D View is the scene's. Everywhere else the system's own
        // Undo stays in place, so the editor and the console prompt keep
        // undoing their own text.
        if let v = view3D {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { v.undo() }
                    .keyboardShortcut("z")
                    .disabled(!v.canUndo || v.isRunning)
                Button("Redo") { v.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!v.canRedo || v.isRunning)
            }
        }
        CommandGroup(after: .sidebar) { viewCommands }
        CommandMenu("Script") { scriptCommands }
        // Blender's 3D View header reads View, Select, Add, Object: Select is
        // a menu of its own here too, before Object.
        CommandMenu("Select") { selectCommands }
        CommandMenu("Object") { objectCommands }
    }

    private func cycleWorkspace(_ step: Int) {
        guard let app else { return }
        let tabs = Workspace.visible
        let at = tabs.firstIndex(of: app.workspace) ?? 0
        app.showWorkspace(tabs[(at + step + tabs.count) % tabs.count])
    }

    @ViewBuilder private var viewCommands: some View {
        Button("Scripting") { app?.showWorkspace(.scripting) }
            .keyboardShortcut("1")
            .disabled(app == nil)
        Button(Workspace.layout.rawValue) { app?.showWorkspace(.layout) }
            .keyboardShortcut("2")
            .disabled(app == nil)
        // Blender's Window ▸ Next Workspace and Previous Workspace
        // (`screen.workspace_cycle`, Ctrl+Page Down and Page Up), over the
        // tabs the top bar shows.
        Button("Next Workspace") { cycleWorkspace(1) }
            .keyboardShortcut(.pageDown, modifiers: .control)
            .disabled(app == nil)
        Button("Previous Workspace") { cycleWorkspace(-1) }
            .keyboardShortcut(.pageUp, modifiers: .control)
            .disabled(app == nil)
        // Blender's Edit ▸ Preferences, on its Ctrl+Comma. Not on Blender's ⌘
        // twin: on a Mac, ⌘, is the system's own Settings for an iPad app
        // (Window Size, Touch Alternatives), and it takes the key first.
        Button("Preferences…") { NotificationCenter.default.post(name: .openPreferences, object: nil) }
            .keyboardShortcut(",", modifiers: .control)
        // Blender's Edit ▸ Operator Search: every operator, by name.
        Button("Operator Search…") { app?.searchOperators() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(app == nil)
        Divider()
        // One Zoom for both tabs — the editor's text in Scripting, the camera
        // in the 3D View — because two items on one key would fight over it.
        Button("Zoom In") {
            if let v = view3D { v.zoom(0.8) } else { script?.textSize(1) }
        }
        .keyboardShortcut("+")
        .disabled(view3D == nil && script == nil)
        Button("Zoom Out") {
            if let v = view3D { v.zoom(1.25) } else { script?.textSize(-1) }
        }
        .keyboardShortcut("-")
        .disabled(view3D == nil && script == nil)
        Button("Actual Text Size") { script?.textSize(0) }
            .keyboardShortcut("0")
            .disabled(script == nil)
        if let v = view3D {
            Divider()
            // Blender's keys: Home frames everything, numpad period frames the
            // selection. Period used to frame everything, which on a
            // keyboard-trained hand zoomed out when it meant to zoom in.
            Button("Frame All") { v.frameAll() }
                .keyboardShortcut(.home, modifiers: [])
            // Blender's numpad period, which the 3D View answers itself
            // (ViewportKeymap's numpad); the number row's period is the Pivot
            // Point pie, as in Blender.
            Button("Frame Selected") { v.frameSelected() }
            // View ▸ Local View ▸ Toggle Local View, Blender's numpad /, and
            // Remove from Local View (VIEW3D_MT_view_local), as rows of their
            // own: a submenu cannot carry a key.
            Button("Toggle Local View") { v.run(LocalViewBpy.toggle) }
                .keyboardShortcut("/", modifiers: [])
                .disabled(!v.canToggleLocalView)
            Button("Remove from Local View") { v.run(LocalViewBpy.removeFrom) }
                .keyboardShortcut("/", modifiers: .option)
                .disabled(!v.inLocalView || v.isRunning)
            // Blender's numpad views, on the number row: Blender's own
            // "emulate numpad" setting maps them the same way. While editing,
            // 1, 2 and 3 choose vertices, edges or faces instead — as they do
            // in Blender on a keyboard without a numpad — so Front and Right
            // stay here without their keys.
            if v.editing {
                Button("Front") { v.view(.front) }
                Button("Right") { v.view(.right) }
            } else {
                Button("Front") { v.view(.front) }.keyboardShortcut("1", modifiers: [])
                Button("Right") { v.view(.right) }.keyboardShortcut("3", modifiers: [])
            }
            Button("Top") { v.view(.top) }.keyboardShortcut("7", modifiers: [])
            Button("Back") { v.view(.back) }.keyboardShortcut("1", modifiers: .control)
            Button("Left") { v.view(.left) }.keyboardShortcut("3", modifiers: .control)
            Button("Bottom") { v.view(.bottom) }.keyboardShortcut("7", modifiers: .control)
            // Blender's numpad 0 — View ▸ Viewpoint ▸ Camera, beside the
            // other viewpoints above — and the Align Active Camera to View
            // that usually follows it.
            Button("Camera") { v.lookThroughCamera?() }
                .keyboardShortcut("0", modifiers: [])
                .disabled(v.lookThroughCamera == nil)
            Button("Align Active Camera to View") { v.aimCameraAtView?() }
                .keyboardShortcut("0", modifiers: [.control, .option])
                .disabled(v.aimCameraAtView == nil)
            // View ▸ Perspective/Orthographic, and Shift+Z's operator.
            Button("Perspective/Orthographic") { v.togglePerspective() }
                .keyboardShortcut("5", modifiers: [])
            Button("Toggle Shading Type") { v.toggleWireframe() }
                .keyboardShortcut("z", modifiers: .shift)
            Button("Toggle X-Ray") { v.toggleXRay() }
                .keyboardShortcut("z", modifiers: .option)
            Divider()
            // Blender's pies and the rest of its 3D View keys (ViewportKeymap.swift).
            ViewportKeyRows(menu: .view, actions: v)
        }
    }

    @ViewBuilder private var scriptCommands: some View {
        let s = script
        // Blender's Text editor's names where it has the command: Run Script,
        // Find & Replace, Jump To, Toggle Comments, Indent and Unindent. Stop,
        // Next Error, folding, the text size and the console's are the
        // Scripting tab's own (docs/blender-names.md).
        Button("Run Script") { s?.run() }
            .keyboardShortcut("r")
            .disabled(s == nil || s?.isRunning == true)
        Button("Stop") { s?.stop() }
            .keyboardShortcut(".")
            .disabled(s?.isRunning != true)
        Divider()
        Button("Find…") { s?.editor("actions.find") }
            .keyboardShortcut("f")
            .disabled(s == nil)
        Button("Find & Replace…") { s?.editor("editor.action.startFindReplaceAction") }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(s == nil)
        Button("Jump To…") { s?.editor("editor.action.gotoLine") }
            .keyboardShortcut("l")
            .disabled(s == nil)
        Button("Next Error") { s?.editor("editor.action.marker.next") }
            .keyboardShortcut("'")
            .disabled(s == nil)
        Divider()
        Button("Toggle Comments") { s?.editor("editor.action.commentLine") }
            .keyboardShortcut("/")
            .disabled(s == nil)
        Button("Indent") { s?.editor("editor.action.indentLines") }
            .keyboardShortcut("]")
            .disabled(s == nil)
        Button("Unindent") { s?.editor("editor.action.outdentLines") }
            .keyboardShortcut("[")
            .disabled(s == nil)
        Button("Fold") { s?.editor("editor.fold") }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(s == nil)
        Button("Unfold") { s?.editor("editor.unfold") }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(s == nil)
        Divider()
        Button("Clear Console") { s?.clearConsole() }
            .keyboardShortcut("k")
            .disabled(s == nil || s?.isRunning == true)
        Button("Switch Editor and Console") { s?.switchEditorAndConsole() }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(s == nil)
        Divider()
        // The same setting as the Scripting tab's Options menu, here too so a
        // keyboard or the Mac's menu bar reaches it from either tab.
        Toggle("Run Scripts Off the Main Thread", isOn: $scriptsOffMainThread)
    }

    /// Blender's Select menu's first three rows, A, Alt+A and Ctrl+I.
    @ViewBuilder private var selectCommands: some View {
        if let v = view3D {
            Button("All") { v.selectAll() }
                .keyboardShortcut("a", modifiers: [])
            Button("None") { v.deselectAll() }
                .keyboardShortcut("a", modifiers: .option)
            Button("Invert") { v.invertSelection() }
                .keyboardShortcut("i", modifiers: .command)
            if v.editing {
                // Blender's L and Shift+L pick what is linked to the element
                // under the pointer (`mesh.select_linked_pick`, Deselect on
                // with Shift); its Ctrl+L is Select ▸ Select Linked ▸ Linked.
                Divider()
                Button("Select Linked") { v.selectLinkedPick?(false) }
                    .keyboardShortcut("l", modifiers: [])
                    .disabled(v.selectLinkedPick == nil || v.isRunning)
                Button("Select Linked (Deselect)") { v.selectLinkedPick?(true) }
                    .keyboardShortcut("l", modifiers: .shift)
                    .disabled(v.selectLinkedPick == nil || v.isRunning)
                // A mesh's: while a curve or a lattice is edited it was
                // offered and then refused in words (round 4's review).
                Button("Linked") { v.selectRow(.mesh(.linked)) }
                    .keyboardShortcut("l", modifiers: .control)
                    .disabled(!v.editingMesh || v.isRunning)
            }
            Divider()
            ViewportKeyRows(menu: .select, actions: v)
        } else {
            Button(Workspace.layout.rawValue) { app?.showWorkspace(.layout) }
                .disabled(app == nil)
        }
    }

    @ViewBuilder private var objectCommands: some View {
        if let v = view3D {
            // Blender's G, R and S (Object ▸ Transform, Mesh ▸ Transform):
            // the transform itself, following the pointer, with X, Y, Z and
            // typed numbers (ModalTransform.swift). They used to pick the
            // toolbar's tools, which have no keys of their own in Blender.
            Section("Transform") {
                Button("Move") { ModalTransformState.begin(.translate) }
                    .keyboardShortcut("g", modifiers: [])
                Button("Rotate") { ModalTransformState.begin(.rotate) }
                    .keyboardShortcut("r", modifiers: [])
                Button("Scale") { ModalTransformState.begin(.scale) }
                    .keyboardShortcut("s", modifiers: [])
            }
            .disabled(v.isRunning || !(v.mode == .object || v.editing))
            // The toolbar's tools, by Blender's toolbar names (5.2.1,
            // tests/names/reference). W cycles the select tools in Blender;
            // here it is Tweak.
            Section("Toolbar") {
                Button(ActiveTool.select.label) { v.setTool(.select) }
                    .keyboardShortcut("w", modifiers: [])
                Button(ActiveTool.boxSelect.label) { v.setTool(.boxSelect) }
                    .keyboardShortcut("b", modifiers: [])
                // Blender's C is Circle Select; the lasso has no key of its
                // own there either (it is a Ctrl-drag), so it is in the menu
                // only.
                Button(ActiveTool.circleSelect.label) { v.setTool(.circleSelect) }
                    .keyboardShortcut("c", modifiers: [])
                Button(ActiveTool.lassoSelect.label) { v.setTool(.lassoSelect) }
                Button(ActiveTool.move.label) { v.setTool(.move) }
                Button(ActiveTool.rotate.label) { v.setTool(.rotate) }
                Button(ActiveTool.scale.label) { v.setTool(.scale) }
                // Blender's Cursor and Measure, which have no key of their own.
                Button(ActiveTool.cursor.label) { v.setTool(.cursor) }
                Button(ActiveTool.measure.label) { v.setTool(.measure) }
                // Blender's Ctrl+R and K, in a mesh's Edit Mode.
                if v.editing {
                    Button(ActiveTool.loopCut.label) { v.setTool(.loopCut) }
                        .keyboardShortcut("r", modifiers: .control)
                    Button(ActiveTool.knife.label) { v.setTool(.knife) }
                        .keyboardShortcut("k", modifiers: [])
                }
            }
            if let remove = v.rulerRemove {
                Section(RulerTool.label) {
                    Button(RulerTool.removeLabel) { remove() }
                        .keyboardShortcut("x", modifiers: [])
                }
            }
            if let confirm = v.knifeConfirm, let cancel = v.knifeCancel {
                Section(ActiveTool.knife.label) {
                    Button("Confirm") { confirm() }
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Cancel") { cancel() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            Divider()
            Menu("Add") {
                ForEach(PrimitiveKind.allCases) { kind in
                    Button(kind.displayName) { v.add(kind) }
                }
                if let objectAdd { ObjectAddItems(add: objectAdd.add, addImage: objectAdd.addImage) }
            }
            .disabled(v.editing || v.isRunning)
            // In Edit Mode, the selected elements (`duplicateSelected`):
            // Blender's Mesh ▸ Duplicate; its Object ▸ Duplicate Objects
            // otherwise.
            Button(v.editing ? "Duplicate" : "Duplicate Objects") { v.duplicate() }
                .keyboardShortcut("d", modifiers: .shift)
                .disabled(!v.hasActiveObject || v.isRunning)
            // Blender's Duplicate Linked (Alt+D) and Join (Ctrl+J) follow
            // Duplicate Objects; Parent and Convert, further down its menu,
            // come with them here.
            ObjectRelationItems(state: v.objectRelations, withKeys: true, perform: v.perform)
            // Transform's Randomize and Align, Mirror, Collection, Relations,
            // Modifiers, Constraints and Link/Transfer Data, where Blender's
            // Object menu has them.
            ObjectMenuMoreItems(state: v.objectRelations, collections: v.collections,
                                perform: v.perform, run: v.run, askNewCollection: v.askNewCollection)
            // Deletes at once, as X does: the selected objects, a mesh's
            // selected vertices, edges or faces by the select mode, or with
            // the Measure tool and an active ruler, the ruler (Ruler Remove,
            // which needs no active object). Blender's Delete menu
            // (VIEW3D_MT_edit_mesh_delete) is on the right-click menu and in
            // Mesh ▸ Delete.
            Button("Delete") { v.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!(v.hasActiveObject || v.rulerRemove != nil) || v.isRunning)
            Divider()
            // Where Blender's Object menu has them, below the add/duplicate/
            // delete group. Neither takes a key: Blender's Ctrl+A opens a
            // *menu* rather than running an operator, Set Origin has no
            // default key at all, a SwiftUI submenu cannot carry a shortcut,
            // and ⌘A here would shadow the Mac's Select All in an app where
            // plain A is already Select All.
            ObjectTransformItems(state: v.objectTransform,
                                 setOrigin: v.setOrigin, apply: v.applyTransform)
            Divider()
            // Blender's shading group, then QuadriFlow, which Blender keeps
            // under Object Data ▸ Remesh.
            ShadingItems(meshInObjectMode: v.activeIsMesh && !v.editing && !v.isRunning,
                         hasObject: v.hasActiveObject && !v.isRunning,
                         essentialsLibrary: v.essentialsLibrary,
                         shade: v.shade, perform: v.perform)
            Button("QuadriFlow Remesh") { v.perform(LastOperator.quadriflowRemesh()) }
                .disabled(!v.activeIsMesh || v.editing || v.isRunning)
            Divider()
            // Blender's Show/Hide keys, in both modes: H hides the selection,
            // Shift+H everything else, Alt+H brings back what was hidden. A
            // submenu cannot carry a key, so these are rows of their own.
            ForEach(Bpy.ShowHide.allCases, id: \.self) { what in
                Button(what.label(editing: v.editing)) { v.showHide(what) }
                    .keyboardShortcut("h", modifiers: what == .reveal ? .option
                                      : what == .hideUnselected ? .shift : [])
                    .disabled(v.isRunning)
            }
            if v.editing {
                SeparateMenu(run: v.separate)
                    .disabled(v.isRunning)
            }
            Divider()
            // Tab: `object.editmode_toggle`, which 5.2.1 names "Edit Mode",
            // ticked while Blender is in it.
            Toggle(InteractionMode.edit.label, isOn: Binding(get: { v.editing }, set: { _ in v.toggleEditing() }))
                .keyboardShortcut(.tab, modifiers: [])
                .disabled(!v.hasActiveObject || v.isRunning)
            if v.editing {
                // Blender's 1, 2 and 3 in edit mode, its Mesh Select Mode
                // menu's rows.
                Section("Mesh Select Mode") {
                    ForEach(MeshSelectMode.allCases) { mode in
                        Toggle(mode.label, isOn: Binding(get: { v.selectMode == mode },
                                                        set: { _ in
                                                            #if DEBUG
                                                            if ProcessInfo.processInfo.arguments.contains("-key-log") {
                                                                print("[bk] key command select mode \(mode)"); fflush(stdout)
                                                            }
                                                            #endif
                                                            v.setSelectMode(mode) }))
                            .keyboardShortcut(KeyEquivalent(Character(mode.shortcut)), modifiers: [])
                            .disabled(v.isRunning)
                    }
                }
            }
            Button("Bevel") { v.mesh(.bevel) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!v.editing || v.isRunning)
            Button("Inset Faces") { v.mesh(.inset) }
                .keyboardShortcut(v.editing ? KeyboardShortcut("i", modifiers: []) : nil)
                .disabled(!v.editing || v.isRunning)
            Button("Subdivide") { v.mesh(.subdivide) }
                .disabled(!v.editing || v.isRunning)
            Divider()
            // Blender's Object Mode and Edit Mode keys and the menus they
            // open at the pointer (ViewportKeymap.swift).
            ViewportKeyRows(menu: .object, actions: v)
            if v.editing {
                Section("Mesh") { ViewportKeyRows(menu: .mesh, actions: v) }
            }
            Divider()
            // View ▸ Sidebar, ticked while it is out, on Blender's N.
            Toggle("Sidebar", isOn: Binding(get: { v.sidebarShown }, set: { _ in v.toggleSidebar() }))
                .keyboardShortcut("n", modifiers: [])
            Button("Properties") { v.showProperties() }
            Button("Outliner") { v.showOutliner() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        } else {
            Button(Workspace.layout.rawValue) { app?.showWorkspace(.layout) }
                .disabled(app == nil)
        }
    }
}
