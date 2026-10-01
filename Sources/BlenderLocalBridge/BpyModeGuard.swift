import Foundation

/// Runs a bare operator in the Blender mode it needs, and puts the mode back.
///
/// Blender's mode is global and outlives whatever set it, and its operators
/// refuse to run in the wrong one: `object.select_all` fails its poll in edit
/// mode, `mesh.extrude_region_move` fails it in object mode, and
/// `primitive_cube_add` crashes the process in sculpt mode. The interface sends
/// two dozen of these straight from menus. Before this, each one assumed a mode
/// and failed — with "context is incorrect", in whichever tab happened to be
/// open — whenever the assumption was wrong.
///
/// The required mode is read from Blender's own operator namespace, which is
/// what Blender's poll functions check: `bpy.ops.mesh.*` and `bpy.ops.uv.*` run
/// on the edited mesh, `bpy.ops.object.*` on objects. Adds are the exception —
/// they live under `mesh` but must not run in edit mode, where they add the
/// primitive into the mesh being edited instead of into the scene.
///
/// Anything that is not a bare operator call is left alone. A script manages
/// its own modes, and so does anything that already calls `mode_set`.
public enum BpyModeGuard {

    /// The mode a bare operator call needs, or nil to leave it untouched.
    public static func requiredMode(for python: String) -> String? {
        let lines = python.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let first = lines.first, first.hasPrefix("bpy.ops.") else { return nil }
        // Explicit mode management is the caller's business, not ours.
        guard !lines.contains(where: { $0.contains("mode_set") }) else { return nil }

        if first.hasPrefix("bpy.ops.mesh.primitive_") { return "OBJECT" }
        if first.hasPrefix("bpy.ops.mesh.") || first.hasPrefix("bpy.ops.uv.") { return "EDIT" }
        if first.hasPrefix("bpy.ops.object.") { return "OBJECT" }
        // transform.*, view3d.* and the rest work in whichever mode they are
        // given, and mean something different in each — Move on an object
        // versus Move on a vertex. Forcing a mode there would be wrong.
        return nil
    }

    /// `python`, bracketed so it runs in its required mode and restores the
    /// previous one afterwards — including when the operator raises, which
    /// still propagates so the failure reaches the console.
    ///
    /// When Blender will not switch, the operator does not run: it is refused
    /// in words. The failed `mode_set` used to be swallowed and the operator
    /// run in whatever mode Blender was left in. Measured in desktop 5.2.1 on
    /// an object in Sculpt Mode with Disable in Viewports on ("Cannot edit
    /// hidden object"): `primitive_cube_add` then ran in Sculpt Mode and, with
    /// no undo stack (after a file load, or under the checkpoint history),
    /// segfaulted in `sculpt_paint::undo::geometry_begin_ex`; with one it ran
    /// and added nothing. Round 3's review found the Multires buttons reaching
    /// Sculpt Mode the same way.
    public static func wrap(_ python: String) -> String {
        guard let mode = requiredMode(for: python) else { return python }
        let body = python.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
        let label = mode == "EDIT" ? "Edit Mode" : "Object Mode"
        return """
        _bk_g_prev = 'OBJECT'
        _bk_g_active = bpy.context.view_layer.objects.active
        if _bk_g_active is not None:
            _bk_g_prev = getattr(_bk_g_active, 'mode', 'OBJECT')
        if _bk_g_prev != '\(mode)':
            try:
                bpy.ops.object.mode_set(mode='\(mode)')
            except Exception as _bk_g_error:
                raise RuntimeError('This runs in \(label), and Blender would not switch to it: '
                                   + str(_bk_g_error).split('.poll() ', 1)[-1]) from None
            if _bk_g_active is not None and getattr(_bk_g_active, 'mode', '\(mode)') != '\(mode)':
                raise RuntimeError('This runs in \(label), and Blender left ' + _bk_g_active.name
                                   + ' in ' + _bk_g_active.mode.replace('_', ' ').title() + ' Mode')
        try:
        \(body)
        finally:
            if _bk_g_prev != '\(mode)':
                try:
                    bpy.ops.object.mode_set(mode=_bk_g_prev)
                except Exception:
                    pass
        """
    }
}
