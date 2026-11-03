import Foundation

/// Blender's Outliner menu for an object (`OUTLINER_MT_object`), the rows a
/// long press or a right-click on an object's row offers: Delete and Delete
/// Hierarchy, Select, Select Hierarchy and Deselect. Blender's own operators
/// (`outliner.delete`, `outliner.object_operation`) act on the Outliner's
/// selected elements and fail their poll without an Outliner area, so each
/// row here says the same thing in object terms: the row's object (and for
/// a hierarchy its children, all the way down) selected alone, then
/// `object.delete` — what the 3D View's Delete key sends — as one undo step
/// named as Blender names it.
public enum OutlinerBpy {

    /// The row's object, and with `hierarchy` every child under it, selected
    /// alone and made active.
    static func selecting(_ name: String, hierarchy: Bool) -> String {
        """
        _bk_o = bpy.data.objects[\(Bpy.quote(name))]
        _bk_layer = bpy.context.view_layer.objects
        bpy.ops.object.select_all(action='DESELECT')
        for _bk_x in [_bk_o] + (list(_bk_o.children_recursive) if \(hierarchy ? "True" : "False") else []):
            if _bk_x.name in _bk_layer:
                _bk_x.select_set(True)
        _bk_layer.active = _bk_o
        """
    }

    /// Delete, or Delete Hierarchy: the row's object (and its children).
    public static func delete(_ name: String, hierarchy: Bool) -> BlenderCommand {
        BlenderCommand(call: "bpy.ops.outliner.delete(" + (hierarchy ? "hierarchy=True" : "") + ")",
                       body: selecting(name, hierarchy: hierarchy) + "\n" + Bpy.deleteSelected,
                       undo: UndoStep.delete)
    }

    /// Select and Select Hierarchy: the selection alone, as a tap on the row
    /// makes it (no undo step, as a tap's).
    public static func select(_ name: String, hierarchy: Bool) -> String {
        selecting(name, hierarchy: hierarchy)
    }

    /// Deselect: the row's object out of the selection.
    public static func deselect(_ name: String) -> String {
        "bpy.data.objects[\(Bpy.quote(name))].select_set(False)"
    }
}
