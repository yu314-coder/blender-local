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
    /// Vertex, edge or face, while editing.
    var selectMode: MeshSelectMode
    var canUndo: Bool
    var canRedo: Bool
    var setTool: (ActiveTool) -> Void
    var deleteSelected: () -> Void
    var duplicate: () -> Void
    var selectAll: () -> Void
    var deselectAll: () -> Void
    var invertSelection: () -> Void
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
    /// Blender's N: the panel that shows the active object's numbers.
    var showObjectDetails: () -> Void
    /// What Tab edits — "Mesh", "Curve" or "Lattice" — for the menu's words,
    /// which said Edit Mesh over a curve.
    var editTarget = "Mesh"
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
        CommandMenu("Object") { objectCommands }
    }

    @ViewBuilder private var viewCommands: some View {
        Button("Scripting") { app?.showWorkspace(.scripting) }
            .keyboardShortcut("1")
            .disabled(app == nil)
        Button("3D View") { app?.showWorkspace(.layout) }
            .keyboardShortcut("2")
            .disabled(app == nil)
        Button("Search Operators…") { app?.searchOperators() }
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
            Button("View Selected") { v.frameSelected() }
                .keyboardShortcut(".", modifiers: [])
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
            // Blender's numpad 0, and the Align Active Camera to View that
            // usually follows it.
            Button("Look Through Camera") { v.lookThroughCamera?() }
                .keyboardShortcut("0", modifiers: [])
                .disabled(v.lookThroughCamera == nil)
            Button("Aim Camera at This View") { v.aimCameraAtView?() }
                .keyboardShortcut("0", modifiers: [.control, .option])
                .disabled(v.aimCameraAtView == nil)
            Button("Perspective / Orthographic") { v.togglePerspective() }
                .keyboardShortcut("5", modifiers: [])
            Button("Wireframe / Solid") { v.toggleWireframe() }
                .keyboardShortcut("z", modifiers: .shift)
            Button("Toggle X-Ray") { v.toggleXRay() }
                .keyboardShortcut("z", modifiers: .option)
        }
    }

    @ViewBuilder private var scriptCommands: some View {
        let s = script
        Button("Run") { s?.run() }
            .keyboardShortcut("r")
            .disabled(s == nil || s?.isRunning == true)
        Button("Stop") { s?.stop() }
            .keyboardShortcut(".")
            .disabled(s?.isRunning != true)
        Divider()
        Button("Find…") { s?.editor("actions.find") }
            .keyboardShortcut("f")
            .disabled(s == nil)
        Button("Find and Replace…") { s?.editor("editor.action.startFindReplaceAction") }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(s == nil)
        Button("Go to Line…") { s?.editor("editor.action.gotoLine") }
            .keyboardShortcut("l")
            .disabled(s == nil)
        Button("Next Error") { s?.editor("editor.action.marker.next") }
            .keyboardShortcut("'")
            .disabled(s == nil)
        Divider()
        Button("Toggle Comment") { s?.editor("editor.action.commentLine") }
            .keyboardShortcut("/")
            .disabled(s == nil)
        Button("Indent") { s?.editor("editor.action.indentLines") }
            .keyboardShortcut("]")
            .disabled(s == nil)
        Button("Outdent") { s?.editor("editor.action.outdentLines") }
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

    @ViewBuilder private var objectCommands: some View {
        if let v = view3D {
            Button("Select All") { v.selectAll() }
                .keyboardShortcut("a", modifiers: [])
            Button("Deselect All") { v.deselectAll() }
                .keyboardShortcut("a", modifiers: .option)
            Button("Invert Selection") { v.invertSelection() }
                .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("Select Tool") { v.setTool(.select) }
                .keyboardShortcut("w", modifiers: [])
            Button("Box Select Tool") { v.setTool(.boxSelect) }
                .keyboardShortcut("b", modifiers: [])
            // Blender's C is Circle Select; the lasso has no key of its own
            // there either (it is a Ctrl-drag), so it is in the menu only.
            Button("Circle Select Tool") { v.setTool(.circleSelect) }
                .keyboardShortcut("c", modifiers: [])
            Button("Lasso Select Tool") { v.setTool(.lassoSelect) }
            Button("Move Tool") { v.setTool(.move) }
                .keyboardShortcut("g", modifiers: [])
            Button("Rotate Tool") { v.setTool(.rotate) }
                .keyboardShortcut("r", modifiers: [])
            Button("Scale Tool") { v.setTool(.scale) }
                .keyboardShortcut("s", modifiers: [])
            Divider()
            Menu("Add") {
                ForEach(PrimitiveKind.allCases) { kind in
                    Button(kind.displayName) { v.add(kind) }
                }
                if let objectAdd { ObjectAddItems(add: objectAdd.add) }
            }
            .disabled(v.editing || v.isRunning)
            // In Edit Mode, the selected elements (`duplicateSelected`).
            Button("Duplicate") { v.duplicate() }
                .keyboardShortcut("d", modifiers: .shift)
                .disabled(!v.hasActiveObject || v.isRunning)
            // Blender's Duplicate Linked (Alt+D) and Join (Ctrl+J) follow
            // Duplicate Objects; Parent and Convert, further down its menu,
            // come with them here.
            ObjectRelationItems(state: v.objectRelations, withKeys: true, perform: v.perform)
            Button("Delete") { v.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!v.hasActiveObject || v.isRunning)
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
            Button(v.editing ? "Finish Editing \(v.editTarget)" : "Edit \(v.editTarget)") { v.toggleEditing() }
                .keyboardShortcut(.tab, modifiers: [])
                .disabled(!v.hasActiveObject || v.isRunning)
            if v.editing {
                // Blender's 1, 2 and 3 in edit mode.
                ForEach(MeshSelectMode.allCases) { mode in
                    Button((v.selectMode == mode ? "✓ " : "") + "\(mode.label) Select") {
                        v.setSelectMode(mode)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(mode.shortcut)), modifiers: [])
                    .disabled(v.isRunning)
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
            Button("Object Details") { v.showObjectDetails() }
                .keyboardShortcut("n", modifiers: [])   // Blender's sidebar key
            Button("Outliner") { v.showOutliner() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        } else {
            Button("Open the 3D View") { app?.showWorkspace(.layout) }
                .disabled(app == nil)
        }
    }
}
