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
    /// Viewport Overlays ▸ Statistics and Mesh Edit Mode ▸ Measurement (Edge
    /// Length, Edge Angle, Face Area, Face Angle): the 3D View's own switches,
    /// kept on its SpaceView3D in Blender as X-Ray is; what they draw is read
    /// from Blender (EditMeasure.swift). Off, as Blender's start.
    var measure = MeasureOverlays()
    /// Viewport Overlays ▸ Grease Pencil ▸ Onion Skins
    /// (`View3DOverlay.use_gpencil_onion_skin`). On here, as Blender's 2D
    /// Animation workspace starts it; its General startup file starts it off.
    var showOnionSkins = true

    // Snapping, the pivot point and proportional editing used to live here as
    // well, as five separate @State copies that never reached Blender and
    // disagreed between workspaces, and so did Auto Merge, whose toggle only
    // logged and whose preview welded at 0.02 where Blender welds at
    // `double_threshold` (0.001). They are Blender's — `scene.tools`,
    // mirrored from `bpy.context.scene.tool_settings` (TransformTools.swift).

    // The transform orientation used to be here too, as a copy that never
    // reached Blender, with Normal, Gimbal, View, Cursor and Parent greyed on
    // the grounds that the app had no Edit Mode and no 3D cursor — both of
    // which it has had since round 1. It is Blender's now:
    // `scene.transform_orientation_slots[0].type`, picked from the header's
    // Orientation menu (LayoutWorkspace) and read back with its matrix into
    // `scene.orientation` (TransformOrientation.swift, `_blenderkit_orient`).
}
