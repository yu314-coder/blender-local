import SwiftUI
import UIKit

/// Blender's 3D View keys that open its menus or run a command that had no key
/// here (blender_default.py's "3D View", "Object Mode" and "Mesh" keymaps,
/// 5.2.1), as one table: the Mac menu bar's rows are drawn from it, the 3D
/// View's hidden key commands carry the keys a menu row cannot (F2, F3, F9,
/// Blender's ⌘ twins), and the `-menu-ops` launch hook presses its chords.
///
/// On a Mac Blender gives every Ctrl key a ⌘ twin
/// (`keyconfig_data_oskey_from_ctrl_for_macos`) but Ctrl+H, M, Space, W, `,
/// Period and Tab; so does this, with the twin unlisted. The number row is
/// Blender's "Emulate Numpad", as the views already were: 2, 4, 6, 8 and 9
/// orbit, Ctrl with them pans.
struct ViewportKey {
    enum Menu { case view, select, object, mesh }

    /// "shift+ctrl+a", "f3": the modifiers in Blender's order, then the key.
    let chord: String
    let title: String
    let menu: Menu
    /// A key a menu row cannot carry: an F key, Blender's Ctrl+Z beside the
    /// menu bar's ⌘Z. (X and Delete are the 3D View's own key aliases.)
    var hidden = false
    let when: (ViewportKeyActions) -> Bool
    let run: (ViewportKeyActions) -> Void

    // MARK: the table

    static let all: [ViewportKey] = view + select + object + mesh

    private static func objectMode(_ v: ViewportKeyActions) -> Bool { !v.editing && v.mode == .object }
    private static func meshEdit(_ v: ViewportKeyActions) -> Bool { v.editing && v.editingMesh }
    private static func navigable(_ v: ViewportKeyActions) -> Bool { true }

    private static let view: [ViewportKey] = [
        ViewportKey(chord: "accent_grave", title: "View", menu: .view, when: navigable) { $0.openMenu(.view) },
        ViewportKey(chord: "z", title: "Shading", menu: .view, when: navigable) { $0.openMenu(.shading) },
        ViewportKey(chord: "t", title: "Toolbar", menu: .view, when: navigable) { $0.toggleToolbar() },
        ViewportKey(chord: "ctrl+space", title: "Toggle Maximize Area", menu: .view, when: navigable) { $0.maximize() },
        ViewportKey(chord: "shift+c", title: "Frame All and Center Cursor", menu: .view, when: navigable) { v in
            v.snap(.cursorToWorldOrigin)
            v.frameAll()
        },
        // `view3d.view_orbit` by Blender's 15° step (Preferences ▸ Navigation
        // ▸ Orbit Angle): Orbit Left moves the eye to the left (measured, 5.2.1:
        // from Front the eye went to (−0.259, −0.966, 0)), Orbit Up up.
        ViewportKey(chord: "4", title: "Orbit Left", menu: .view, when: navigable) { $0.orbit(-step, 0) },
        ViewportKey(chord: "6", title: "Orbit Right", menu: .view, when: navigable) { $0.orbit(step, 0) },
        ViewportKey(chord: "8", title: "Orbit Up", menu: .view, when: navigable) { $0.orbit(0, step) },
        // 2 chooses edges while editing, as it does in Blender without a numpad.
        ViewportKey(chord: "2", title: "Orbit Down", menu: .view, when: { !$0.editing }) { $0.orbit(0, -step) },
        ViewportKey(chord: "9", title: "Orbit Opposite", menu: .view, when: navigable) { $0.orbit(.pi, 0) },
        ViewportKey(chord: "ctrl+4", title: "Pan Left", menu: .view, when: navigable) { $0.pan(-panStep, 0) },
        ViewportKey(chord: "ctrl+6", title: "Pan Right", menu: .view, when: navigable) { $0.pan(panStep, 0) },
        ViewportKey(chord: "ctrl+8", title: "Pan Up", menu: .view, when: navigable) { $0.pan(0, panStep) },
        ViewportKey(chord: "ctrl+2", title: "Pan Down", menu: .view, when: { !$0.editing }) { $0.pan(0, -panStep) },
        ViewportKey(chord: "f3", title: "Search", menu: .view, hidden: true, when: navigable) { $0.searchOperators() },
        ViewportKey(chord: "f9", title: "Adjust Last Operation", menu: .view, hidden: true, when: navigable) {
            $0.adjustLastOperation()
        },
        // Blender's F12 (the Screen keymap's `render.render`): the Render
        // panel, rendering at once.
        ViewportKey(chord: "f12", title: "Render Image", menu: .view, hidden: true,
                    when: { $0.render != nil && !$0.isRunning }) { $0.render?() },
        ViewportKey(chord: "ctrl+z", title: "Undo", menu: .view, hidden: true, when: { $0.canUndo && !$0.isRunning }) {
            $0.undo()
        },
        ViewportKey(chord: "shift+ctrl+z", title: "Redo", menu: .view, hidden: true,
                    when: { $0.canRedo && !$0.isRunning }) { $0.redo() },
    ]

    /// Blender's 15° orbit step, and a pan of a tenth of the view's width.
    static let step: Float = 15 * .pi / 180
    static let panStep: Float = 60

    private static let select: [ViewportKey] = [
        ViewportKey(chord: "shift+g", title: "Select Grouped", menu: .select, when: { objectMode($0) && $0.hasActiveObject }) {
            $0.openMenu(.selectGrouped)
        },
        ViewportKey(chord: "shift+l", title: "Select Linked", menu: .select, when: { objectMode($0) && $0.hasActiveObject }) {
            $0.openMenu(.selectLinked)
        },
        ViewportKey(chord: "shift+g", title: "Select Similar", menu: .select, when: meshEdit) { $0.openMenu(.selectSimilar) },
    ]

    private static let object: [ViewportKey] = [
        ViewportKey(chord: "shift+a", title: "Add", menu: .object, when: { objectMode($0) && !$0.isRunning }) {
            $0.openMenu(.add)
        },
        ViewportKey(chord: "ctrl+a", title: "Apply", menu: .object, when: objectMode) { $0.openMenu(.apply) },
        ViewportKey(chord: "ctrl+c", title: "Copy Objects", menu: .object,
                    when: { objectMode($0) && $0.hasActiveObject && !$0.isRunning }) { $0.copyObjects() },
        ViewportKey(chord: "ctrl+v", title: "Paste Objects", menu: .object, when: { objectMode($0) && !$0.isRunning }) {
            $0.pasteObjects()
        },
        ViewportKey(chord: "ctrl+p", title: "Set Parent To", menu: .object, when: objectMode) { $0.openMenu(.parent) },
        ViewportKey(chord: "alt+p", title: "Clear Parent", menu: .object, when: objectMode) { $0.openMenu(.clearParent) },
        ViewportKey(chord: "ctrl+l", title: "Link/Transfer Data", menu: .object, when: objectMode) { $0.openMenu(.makeLinks) },
        ViewportKey(chord: "m", title: "Move to Collection", menu: .object, when: objectMode) {
            $0.openMenu(.moveToCollection)
        },
        ViewportKey(chord: "shift+m", title: "Link to Collection", menu: .object, when: objectMode) {
            $0.openMenu(.linkToCollection)
        },
        ViewportKey(chord: "alt+g", title: "Clear Location", menu: .object, when: { objectMode($0) && !$0.isRunning }) {
            $0.perform(.clear(.location))
        },
        ViewportKey(chord: "alt+r", title: "Clear Rotation", menu: .object, when: { objectMode($0) && !$0.isRunning }) {
            $0.perform(.clear(.rotation))
        },
        ViewportKey(chord: "alt+s", title: "Clear Scale", menu: .object, when: { objectMode($0) && !$0.isRunning }) {
            $0.perform(.clear(.scale))
        },
        ViewportKey(chord: "shift+s", title: "Snap", menu: .object, when: { $0.mode == .object || $0.editing }) {
            $0.openMenu(.snap)
        },
        ViewportKey(chord: "ctrl+tab", title: "Mode", menu: .object, when: { !$0.modes.isEmpty }) { $0.openMenu(.mode) },
        ViewportKey(chord: "comma", title: "Orientation", menu: .object, when: { $0.mode == .object || $0.editing }) {
            $0.openMenu(.orientation)
        },
        ViewportKey(chord: "shift+tab", title: "Snapping", menu: .object, when: { $0.mode == .object || $0.editing }) {
            $0.toggleSnap()
        },
        ViewportKey(chord: "o", title: "Proportional Editing", menu: .object, when: { $0.mode == .object || $0.editing }) {
            $0.toggleProportional()
        },
        ViewportKey(chord: "shift+r", title: "Repeat Last", menu: .object, when: { $0.canRepeatLast() && !$0.isRunning }) {
            $0.repeatLast()
        },
        ViewportKey(chord: "f2", title: "Rename Active Object…", menu: .object, hidden: true,
                    when: { objectMode($0) && $0.rename != nil }) { $0.rename?() },
    ]

    private static func mesh(_ chord: String, _ op: LastOperator.Mesh, _ title: String? = nil) -> ViewportKey {
        ViewportKey(chord: chord, title: title ?? op.menuLabel, menu: .mesh, when: { meshEdit($0) && !$0.isRunning }) {
            $0.mesh(op)
        }
    }

    private static func meshMenu(_ chord: String, _ title: String, _ menu: ViewportMenu) -> ViewportKey {
        ViewportKey(chord: chord, title: title, menu: .mesh, when: meshEdit) { $0.openMenu(menu) }
    }

    private static let mesh: [ViewportKey] = [
        // `view3d.edit_mesh_extrude_move_normal`: here the Extrude row the
        // toolbar has, along the normals.
        mesh("e", .extrude),
        meshMenu("alt+e", "Extrude", .extrude),
        mesh("f", .fillFace),
        meshMenu("m", "Merge", .merge),
        meshMenu("alt+m", "Split", .split),
        meshMenu("p", "Separate", .separate),
        mesh("y", .splitSelection, "Split"),
        mesh("j", .connectVertexPath),
        meshMenu("ctrl+v", "Vertex", .vertex),
        meshMenu("ctrl+e", "Edge", .edge),
        meshMenu("ctrl+f", "Face", .face),
        meshMenu("alt+n", "Normals", .normals),
        mesh("shift+ctrl+b", .bevelVertices),
        mesh("ctrl+t", .triangulate),
        mesh("alt+j", .quadify),
        mesh("shift+n", .recalculateNormals),
        mesh("shift+ctrl+n", .recalculateInside),
        mesh("alt+s", .shrinkFatten),
        mesh("shift+alt+s", .toSphere),
        ViewportKey(chord: "shift+ctrl+alt+s", title: "Shear", menu: .mesh, when: { meshEdit($0) && !$0.isRunning }) {
            $0.shear()
        },
        mesh("shift+v", .slideVertices),
        mesh("shift+e", .edgeCrease),
        mesh("shift+ctrl+r", .offsetEdgeSlide),
        ViewportKey(chord: "ctrl+x", title: "Dissolve Selection", menu: .mesh, when: { meshEdit($0) && !$0.isRunning }) { v in
            switch v.selectMode {
            case .vertex: v.mesh(.dissolveVerts)
            case .edge:   v.mesh(.dissolveEdges)
            case .face:   v.mesh(.dissolveFaces)
            }
        },
    ]

    // MARK: chords

    /// The entry a chord runs right now, if any.
    static func entry(_ chord: String, _ v: ViewportKeyActions) -> ViewportKey? {
        all.first { $0.chord == chord && $0.when(v) }
    }

    /// Runs the chord, as a key press would; false when it means nothing now.
    @discardableResult
    static func press(_ chord: String, _ v: ViewportKeyActions) -> Bool {
        guard let entry = entry(chord.lowercased(), v) else { return false }
        entry.run(v)
        return true
    }

    /// Blender's macOS ⌘ twin of a Ctrl chord, when it has one.
    static func commandTwin(of chord: String) -> String? {
        let parts = chord.split(separator: "+").map(String.init)
        guard parts.contains("ctrl"), let key = parts.last else { return nil }
        let excluded: Set<String> = ["h", "m", "space", "w", "accent_grave", "period", "tab"]
        if excluded.contains(key), !parts.contains("alt"), !parts.contains("shift") { return nil }
        // The number row is the workspaces' (⌘1 Scripting, ⌘2 Layout).
        if key.count == 1, key.first!.isNumber { return nil }
        let twin = parts.map { $0 == "ctrl" ? "cmd" : $0 }.joined(separator: "+")
        // Already the menu bar's: Undo and Redo.
        return ["cmd+z", "shift+cmd+z"].contains(twin) ? nil : twin
    }

    /// The SwiftUI shortcut of a chord a menu row can carry.
    static func shortcut(_ chord: String) -> KeyboardShortcut? {
        let parts = chord.split(separator: "+").map(String.init)
        guard let key = parts.last, let equivalent = keyEquivalent(key) else { return nil }
        var modifiers: EventModifiers = []
        if parts.contains("shift") { modifiers.insert(.shift) }
        if parts.contains("ctrl") { modifiers.insert(.control) }
        if parts.contains("alt") { modifiers.insert(.option) }
        if parts.contains("cmd") { modifiers.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    private static func keyEquivalent(_ key: String) -> KeyEquivalent? {
        switch key {
        case "space": return .space
        case "tab": return .tab
        case "comma": return ","
        case "period": return "."
        case "accent_grave": return "`"
        default:
            guard key.count == 1, let c = key.first else { return nil }
            return KeyEquivalent(c)
        }
    }

    /// A UIKit key command's input and modifiers for a chord, for the keys
    /// the 3D View carries itself.
    static func uiKey(_ chord: String) -> (input: String, modifiers: UIKeyModifierFlags)? {
        let parts = chord.split(separator: "+").map(String.init)
        guard let key = parts.last else { return nil }
        var flags: UIKeyModifierFlags = []
        if parts.contains("shift") { flags.insert(.shift) }
        if parts.contains("ctrl") { flags.insert(.control) }
        if parts.contains("alt") { flags.insert(.alternate) }
        if parts.contains("cmd") { flags.insert(.command) }
        let input: String
        switch key {
        case "f2": input = UIKeyCommand.f2
        case "f3": input = UIKeyCommand.f3
        case "f9": input = UIKeyCommand.f9
        case "f12": input = UIKeyCommand.f12
        case "space": input = " "
        case "tab": input = "\t"
        case "comma": input = ","
        case "period": input = "."
        case "accent_grave": input = "`"
        default: input = key
        }
        return (input, flags)
    }

    /// The chords the 3D View answers itself: the hidden entries and every ⌘
    /// twin, each once.
    static let viewKeys: [String] = {
        var out: [String] = []
        for entry in all {
            if entry.hidden, !out.contains(entry.chord) { out.append(entry.chord) }
            if let twin = commandTwin(of: entry.chord), !out.contains(twin) { out.append(twin) }
        }
        // The menu bar's ⌘ rows' Ctrl twins (Blender's keys) and the ⌘ twins
        // of the Ctrl rows that were there before this table.
        for chord in ["ctrl+i", "ctrl+b", "ctrl+j", "cmd+r", "cmd+l"] where !out.contains(chord) {
            out.append(chord)
        }
        return out
    }()

    /// What a chord the 3D View carries runs: its table entry, the entry its
    /// ⌘ twin stands for, or one of the menu bar's own rows under Blender's
    /// other key.
    @MainActor static func pressViewKey(_ chord: String, _ v: ViewportKeyActions) -> Bool {
        if press(chord, v) { return true }
        if chord.contains("cmd") {
            let ctrl = chord.replacingOccurrences(of: "cmd", with: "ctrl")
            if press(ctrl, v) { return true }
        }
        guard !v.isRunning else { return false }
        switch chord {
        case "ctrl+i":
            v.invertSelection()
        case "ctrl+b":
            guard v.editing && v.editingMesh else { return false }
            v.mesh(.bevel)
        case "ctrl+j":
            guard !v.editing, v.objectRelations.canJoin else { return false }
            v.perform(.join())
        case "cmd+r":
            guard v.editing && v.editingMesh else { return false }
            v.setTool(.loopCut)
        case "cmd+l":
            guard v.editing && v.editingMesh else { return false }
            v.selectRow(.mesh(.linked))
        default:
            return false
        }
        return true
    }

    /// Whether the 3D View's key command for a chord has anything to do now.
    /// When it has not, UIKit passes the key on — to the menu bar's own row
    /// on the same key (X is Ruler Remove's with a ruler out).
    @MainActor static func canPressViewKey(_ chord: String, _ v: ViewportKeyActions) -> Bool {
        if entry(chord, v) != nil { return true }
        if chord.contains("cmd"), entry(chord.replacingOccurrences(of: "cmd", with: "ctrl"), v) != nil { return true }
        guard !v.isRunning else { return false }
        switch chord {
        case "ctrl+i": return true
        case "ctrl+b", "cmd+r", "cmd+l": return v.editing && v.editingMesh
        case "ctrl+j": return !v.editing && v.objectRelations.canJoin
        default: return false
        }
    }
}

/// The table's rows for one of the menu bar's menus, each with its key,
/// greyed when it means nothing now.
struct ViewportKeyRows: View {
    let menu: ViewportKey.Menu
    let actions: ViewportKeyActions

    var body: some View {
        let rows = ViewportKey.all.filter { $0.menu == menu && !$0.hidden }
        // Only the rows that apply now, as the menu bar's other mode rows are
        // drawn: a chord can mean one thing in Object Mode and another while
        // editing (Alt+S is Clear Scale, then Shrink/Fatten; 2 orbits, then
        // chooses edges), and a greyed row would put the key on two rows.
        ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
            if entry.when(actions) {
                Button(entry.title) { entry.run(actions) }
                    .keyboardShortcut(ViewportKey.shortcut(entry.chord))
            }
        }
    }
}
