import Foundation

/// The undo steps the 3D View's own buttons, keys and gizmo record: Tab, the
/// bar's Edit Mode and Object Mode, Shift+D, X, Shade Smooth and Shade Flat,
/// Mesh ▸ Separate, Add Modifier's rows, and a Move, Rotate or Scale drag.
///
/// Each is the step Blender's own undo history records for the operator the
/// button calls, measured in desktop 5.2.1: the operator run with its undo on
/// in the app's context and the step read back with `print_undo_steps`
/// (tests/names/blender/verify.py, which measures it again on every run).
///
/// They live here, not beside the buttons in BlenderLocalUI, so that the check
/// reads them from the app. Round 4's review found that check typing these
/// sixteen names in itself: a scratch copy with LayoutWorkspace's Edit Mode
/// step changed to "Enter Edit" and Shift+D's to "Duplicate Mesh" failed
/// nothing. Now tests/names/main.swift prints these with the call each stands
/// for, the Blender check holds them to what Blender records, and
/// tests/names/scan.py holds every call site in BlenderLocalUI and
/// BlenderLocalApp to these constants (no literal, and no name of the UI's
/// own, where one of these builders is run).
public enum UndoStep {
    /// Into or out of Edit Mode. Measured: `object.editmode_toggle` both
    /// ways, and `object.mode_set` into Edit Mode and back to Object Mode,
    /// each push a step of this name — `editmode_toggle`'s own name in 5.2.1.
    public static let editMode = "Edit Mode"
    /// Shift+D in a mesh's Edit Mode, `mesh.duplicate_move`.
    public static let duplicateElements = "Add Duplicate"
    /// Shift+D in Object Mode, `object.duplicate_move`.
    public static let duplicateObjects = "Duplicate Objects"
    /// X: `object.delete`, and `mesh.delete` while editing.
    public static let delete = "Delete"
    /// Object ▸ Shade Smooth, `object.shade_smooth`.
    public static let shadeSmooth = "Shade Smooth"
    /// Object ▸ Shade Flat, `object.shade_flat`.
    public static let shadeFlat = "Shade Flat"
    /// Mesh ▸ Separate's rows, `mesh.separate`.
    public static let separate = "Separate"
    /// Add Modifier's rows, `object.modifier_add`.
    public static let addModifier = "Add Modifier"
    /// A Move drag (the gizmo, the Cursor tool), `transform.translate`.
    public static let move = "Move"
    /// A Rotate drag, `transform.rotate`.
    public static let rotate = "Rotate"
    /// A Scale drag, `transform.resize`: Blender's Scale tool runs Resize,
    /// and its step is Resize.
    public static let resize = "Resize"
}
