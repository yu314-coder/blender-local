import Foundation

/// Which thread a script or console line runs on.
///
/// Scripts run off the main thread when the setting says so, which keeps the
/// interface drawing while they work. Two things work on the main thread
/// only. One is `Context.temp_override` with a window, screen, area or region.
/// Blender gives those members out on the main thread and reads None for them
/// anywhere else, so off it the override cannot reach the operators inside the
/// block, and before `_blenderkit_context.py` it also wiped the main thread's
/// window and screen as it ended. The other is loading a file (`fileReads`).
public enum ScriptThread {
    /// Whether `source` runs on the main thread even when scripts normally run
    /// off it: whenever it mentions `temp_override` or one of `fileReads` at
    /// all.
    ///
    /// Deliberately blunt. The members arrive in every shape — keywords,
    /// `**override`, a dict built from `context.copy()` — and a mention in a
    /// comment only costs one run on the main thread, which is how every
    /// script ran before build 20.
    public static func needsMainThread(_ source: String) -> Bool {
        source.contains("temp_override") || readsFile(source)
    }

    /// The `bpy.ops.wm` operators that load a .blend over the scene.
    ///
    /// Each takes down Blender's screen on the way: `wm_file_read_setup_wm_init`
    /// calls `ED_screen_exit` for every window, whatever `load_ui` says, and
    /// that asks the context for the window, which Blender gives out on the
    /// main thread only. On the script thread it read NULL, and a script's
    /// `bpy.ops.wm.read_homefile()` crashed the app in
    /// `WM_event_modal_handler_region_replace` (EXC_BAD_ACCESS at 0xf0,
    /// reports BlenderLocal-2026-09-22-100656 and -100743). On the main thread
    /// all six load, measured in desktop Blender 5.2.1 with the app's context.
    ///
    /// The same names as `FILE_READS` in `_blenderkit_context.py`, which
    /// refuses them off the main thread for the calls this check cannot see;
    /// run-scriptthread-tests.sh compares the two lists.
    public static let fileReads = [
        "read_homefile", "read_factory_settings", "open_mainfile",
        "revert_mainfile", "recover_last_session", "recover_auto_save",
    ]

    /// Whether `source` mentions one of `fileReads`.
    public static func readsFile(_ source: String) -> Bool {
        fileReads.contains { source.contains($0) }
    }

    /// Whether `source` may start Blender's GPU module, which has to be
    /// started on the main thread first (`BpySession.startGPUOnMainThread`):
    /// an Eevee or Solid render, a viewport render, or the `gpu` module
    /// itself. As blunt as `needsMainThread`, for the same reason — a false
    /// match costs one call that returns at once.
    public static func mayStartGPU(_ source: String) -> Bool {
        source.contains("render.render") || source.contains("render.opengl")
            || source.contains("gpu")
    }

    /// What starts it. A build without the module, or one that cannot start
    /// it, is left to fail in the script that wanted it, in that script's
    /// own words.
    public static let gpuStart = """
    try:
        import gpu as _bk_gpu
        _bk_gpu.init()
    except Exception:
        pass
    """

    /// Said in the console when that is why a run is on the main thread.
    public static let mainThreadNote =
        "Running on the main thread: temp_override needs the window, area and region Blender gives out there only."

    /// Said instead when the run is there because it loads a file.
    public static let fileReadNote =
        "Running on the main thread: loading a file takes down Blender's screen, which exists there only."

    /// The note for a run of `source` that `needsMainThread` put on the main thread.
    public static func note(for source: String) -> String {
        readsFile(source) ? fileReadNote : mainThreadNote
    }
}
