import Foundation

// The operators behind Blender's right-click menus and menu keys that no menu
// here reached before: Object ▸ Snap (Shift+S), Object ▸ Clear (Alt+G, Alt+R,
// Alt+S), Copy and Paste Objects (Ctrl+C, Ctrl+V), Subdivision Set (Ctrl+0…5)
// and Set Active Camera. Each measured in desktop Blender 5.2.1 under
// `-b --factory-startup` with the app's context (an undo stack from
// `ed.undo_push`, the startup screen's 3D View borrowed through
// `_blenderkit_context.temp_override_view3d` where the poll wants one):
//
// - the seven Snap operators fail their poll without a 3D View ("context is
//   incorrect", "Expected a view3d region") and act as on a desktop with the
//   borrowed one: Cursor to Selected put the cursor at a cube's (1, 2, 3),
//   Selection to Grid moved (1.3, 2.6, 0.2) to (1, 3, 0), Selection to Cursor
//   moved it to the cursor's (0, 0, 5); in Edit Mode both of the cursor's
//   rows act on the selected vertices.
// - Clear Location, Rotation and Scale need no view: (1, 2, 3) → 0, a
//   rotation → 0, a scale of 2 → 1.
// - Copy Objects and Paste Objects need none either; three objects copied and
//   pasted made a fourth (`Cube.001`).
// - Subdivision Set returns FINISHED without the view and adds nothing; with
//   it, a Subdivision modifier.
// - Set Active Object as Camera needs the view.

/// Blender's Snap menu (`VIEW3D_MT_snap`), its rows in its order: the
/// selection to the grid, the cursor or the active object, then the cursor to
/// the selection, the world origin, the grid or the active object. Shift+S's
/// pie has the same eight.
public enum SnapBpy: CaseIterable, Sendable {
    case selectionToGrid, selectionToCursor, selectionToCursorKeepOffset, selectionToActive
    case cursorToSelected, cursorToWorldOrigin, cursorToGrid, cursorToActive

    /// The row's words, which Blender's menu sets (`text=`).
    public var label: String {
        switch self {
        case .selectionToGrid:             return "Selection to Grid"
        case .selectionToCursor:           return "Selection to Cursor"
        case .selectionToCursorKeepOffset: return "Selection to Cursor (Keep Offset)"
        case .selectionToActive:           return "Selection to Active"
        case .cursorToSelected:            return "Cursor to Selected"
        case .cursorToWorldOrigin:         return "Cursor to World Origin"
        case .cursorToGrid:                return "Cursor to Grid"
        case .cursorToActive:              return "Cursor to Active"
        }
    }

    /// The operator's name (`get_rna_type().name`, 5.2.1), which Blender's
    /// undo history calls the step.
    public var operatorName: String {
        switch self {
        case .selectionToGrid:                                return "Snap Selection to Grid"
        case .selectionToCursor, .selectionToCursorKeepOffset: return "Snap Selection to Cursor"
        case .selectionToActive:                              return "Snap Selection to Active"
        case .cursorToSelected:                               return "Snap Cursor to Selected"
        case .cursorToWorldOrigin:                            return "Snap Cursor to World Origin"
        case .cursorToGrid:                                   return "Snap Cursor to Grid"
        case .cursorToActive:                                 return "Snap Cursor to Active"
        }
    }

    /// Whether it moves the selection, rather than the 3D cursor.
    public var movesSelection: Bool {
        switch self {
        case .selectionToGrid, .selectionToCursor, .selectionToCursorKeepOffset, .selectionToActive: return true
        default: return false
        }
    }

    /// Whether it needs an active object to snap to or from.
    public var needsActive: Bool { self == .selectionToActive || self == .cursorToActive }

    var call: String {
        switch self {
        case .selectionToGrid:             return "bpy.ops.view3d.snap_selected_to_grid()"
        case .selectionToCursor:           return "bpy.ops.view3d.snap_selected_to_cursor(use_offset=False)"
        case .selectionToCursorKeepOffset: return "bpy.ops.view3d.snap_selected_to_cursor(use_offset=True)"
        case .selectionToActive:           return "bpy.ops.view3d.snap_selected_to_active()"
        case .cursorToSelected:            return "bpy.ops.view3d.snap_cursor_to_selected()"
        case .cursorToWorldOrigin:         return "bpy.ops.view3d.snap_cursor_to_center()"
        case .cursorToGrid:                return "bpy.ops.view3d.snap_cursor_to_grid()"
        case .cursorToActive:              return "bpy.ops.view3d.snap_cursor_to_active()"
        }
    }

    /// Run in the borrowed 3D View. Blender pushes an undo step for every
    /// one of them, the cursor's included (`OPTYPE_UNDO` on all eight), so
    /// each carries its operator's name.
    public var command: BlenderCommand {
        BlenderCommand(call: call,
                       body: "import _blenderkit_context\n"
                           + "with _blenderkit_context.temp_override_view3d(\(Bpy.quote(operatorName))):\n"
                           + "    " + call,
                       undo: operatorName)
    }
}

/// Object ▸ Clear's first three rows, Blender's Alt+G, Alt+R and Alt+S.
public enum ClearTransform: CaseIterable, Sendable {
    case location, rotation, scale

    public var label: String {
        switch self {
        case .location: return "Location"
        case .rotation: return "Rotation"
        case .scale:    return "Scale"
        }
    }

    public var key: String {
        switch self {
        case .location: return "Alt G"
        case .rotation: return "Alt R"
        case .scale:    return "Alt S"
        }
    }
}

public extension LastOperator {

    /// `object.location_clear`, `rotation_clear` or `scale_clear`, with
    /// Blender's redo panel's one field, Clear Delta.
    static func clear(_ what: ClearTransform) -> LastOperator {
        let name = "Clear " + what.label
        let id: String = {
            switch what {
            case .location: return "location_clear"
            case .rotation: return "rotation_clear"
            case .scale:    return "scale_clear"
            }
        }()
        var op = LastOperator(
            name: name, call: "bpy.ops.object." + id,
            parameters: [Parameter(key: "clear_delta", label: "Clear Delta",
                                   kind: .literal([Parameter.Option("False", "Off"),
                                                   Parameter.Option("True", "On")]),
                                   value: 0, softMin: 0, softMax: 1, step: 0.02)],
            restoration: .throughBlenderUndo)
        op.refusal = name + " acts on the selected objects, and none is selected. Select one first."
        return op
    }

    /// `object.subdivision_set`, Blender's Ctrl+0 to Ctrl+5 in Object Mode:
    /// a Subdivision Surface modifier at that level on each selected object,
    /// added where there is none. Through the borrowed 3D View, without which
    /// it returns FINISHED having added nothing (measured).
    static func subdivisionSet(level: Int) -> LastOperator {
        var op = LastOperator(
            name: "Subdivision Set", call: "bpy.ops.object.subdivision_set",
            parameters: [Parameter(key: "level", label: "Level", kind: .integer,
                                   value: Double(level), softMin: 0, softMax: 6, step: 0.05)],
            restoration: .throughBlenderUndo)
        op.fixedArguments = ["relative=False"]
        op.lead = "import _blenderkit_context"
        op.within = "_blenderkit_context.temp_override_view3d('Subdivision Set')"
        op.refusal = "Subdivision Set acts on the selected objects, and none is selected. Select one first."
        return op
    }
}

/// Copy Objects and Paste Objects, Blender's Ctrl+C and Ctrl+V in the 3D
/// View, and its context menu's two rows: the selected objects written to
/// Blender's copy buffer (a .blend in its temporary folder) and read back in,
/// selected.
public enum ObjectBufferBpy {
    /// Changes nothing in the scene, so no undo step, as in Blender.
    public static let copy = BlenderCommand(call: "bpy.ops.view3d.copybuffer()",
                                            body: "bpy.ops.view3d.copybuffer()", undo: nil)
    public static let paste = BlenderCommand(call: "bpy.ops.view3d.pastebuffer()",
                                             body: "bpy.ops.view3d.pastebuffer()", undo: "Paste Objects")
}

/// The context menu's Set Active Camera, for a camera
/// (`view3d.object_as_camera`, "Set Active Object as Camera"): the scene's
/// camera becomes the active object.
public enum ActiveCameraBpy {
    public static let set = BlenderCommand(
        call: "bpy.ops.view3d.object_as_camera()",
        body: "import _blenderkit_context\n"
            + "with _blenderkit_context.temp_override_view3d('Set Active Camera'):\n"
            + "    bpy.ops.view3d.object_as_camera()",
        undo: "Set Active Object as Camera")
}
