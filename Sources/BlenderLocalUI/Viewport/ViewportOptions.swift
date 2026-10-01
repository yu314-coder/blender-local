import Foundation

/// The viewport toggles Blender keeps on the right of its 3D view header.
///
/// Only options with real behaviour behind them are switchable; the rest are
/// shown disabled, the way Blender greys out what does not apply, rather than
/// appearing to work.
struct ViewportOptions {
    /// Blender's overlay toggle: grid, axes and object outlines.
    var showOverlays = true
    /// Blender's X-Ray: surfaces become translucent so what is behind shows.
    var xray = false
    /// Blender's gizmo toggle. Here it draws the active object's local axes.
    var showGizmos = true
    /// How far apart the increments the magnet rounds a drag to are.
    ///
    /// The one setting of the trio that stays here: Blender takes its
    /// increment from the 3D View's own grid, which is a per-view property
    /// there and has no equivalent on `scene.tool_settings`. Whether it is
    /// used at all is Blender's — `scene.tools.snapsDrag`.
    var snapIncrement: Float = 0.25
    var orientation: TransformOrientation = .global

    // Snapping, the pivot point and proportional editing used to live here as
    // well, as five separate @State copies that never reached Blender and
    // disagreed between workspaces, and so did Auto Merge, whose toggle only
    // logged and whose preview welded at 0.02 where Blender welds at
    // `double_threshold` (0.001). They are Blender's — `scene.tools`,
    // mirrored from `bpy.context.scene.tool_settings` (TransformTools.swift).

    /// Blender's transform orientation dropdown. Normal, Gimbal, View, Cursor
    /// and Parent need an edit mode or a 3D cursor, neither of which exists
    /// here, so they are listed but disabled.
    enum TransformOrientation: String, CaseIterable, Identifiable {
        case global, local, normal, gimbal, view, cursor, parent
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var isImplemented: Bool { self == .global || self == .local }
    }
}
