import Foundation

/// The Python Texture Paint sends. The bpy side lives in
/// `Resources/python/site/_blenderkit_texpaint.py`; these are the calls into
/// it, kept here so tests/texpaint/blender runs exactly what the app sends.
public enum TexturePaintBpy {

    /// Blender's name for a kept stroke's undo step.
    public static let undoName = "Texture Paint"

    /// Entering Texture Paint on `name`: what Blender's texture paint offers
    /// when it finds something missing, done rather than offered — Add Simple
    /// UVs for a mesh with no UV map, Add Paint Slot for a material with no
    /// image to paint. The names of the operators that ran are left in
    /// `_bk_tp_made` for `madeQuery`.
    public static func enter(object name: String, width: Int = 1024, height: Int = 1024) -> String {
        """
        import _blenderkit_texpaint as _bk_tp
        _bk_tp_made = _bk_tp.enter(\(Bpy.quote(name)), \(width), \(height))
        """
    }

    /// What the last `enter` made, one name per line.
    public static let madeQuery = "print('\\n'.join(_bk_tp_made))"

    /// Keeping a stroke: the painted pixels into Blender's images, which are
    /// then packed so the .blend — and so every undo checkpoint and the
    /// autosave — carries them.
    public static func write(images names: [String]) -> String {
        let list = names.map { Bpy.quote($0) }.joined(separator: ", ")
        return "import _blenderkit_texpaint as _bk_tp\n_bk_tp.write([\(list)])"
    }

    /// The undo step entering makes: Add Paint Slot when it made an image, Add
    /// Simple UVs when it made only a UV map, and none when it made nothing.
    public static func undoName(for made: [String]) -> String? {
        made.contains("Add Paint Slot") ? "Add Paint Slot" : made.first
    }
}
