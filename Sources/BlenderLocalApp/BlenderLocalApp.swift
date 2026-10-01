import SwiftUI

@main
struct BlenderLocalApp: App {

    init() {
        Self.seedLaunchScriptIfRequested()
    }

    /// Writes `-eval64`'s script into the draft before any view exists.
    ///
    /// The Scripting tab reads the draft in `@State private var document =
    /// ScriptDocument.restored()`, which SwiftUI evaluates when the view is
    /// first constructed. Doing this from `onAppear` — where it used to live —
    /// was too late: the editor had already captured whatever was in the draft
    /// from the *previous* run, so every screenshot showed the last script
    /// rather than the one being tested. The harness was lying, not the editor.
    private static func seedLaunchScriptIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-eval64"), i + 1 < args.count,
              let data = Data(base64Encoded: args[i + 1]),
              let source = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.removeObject(forKey: "bl_script_last_opened")
        try? source.write(to: ScriptDocument.draftURL, atomically: true, encoding: .utf8)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Blender has no light theme in this app; the whole interface is
                // themed from Blender's own dark values.
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
        // The Magic Keyboard's way in: every command and its key, per tab.
        // See KeyboardCommands.swift.
        .commands {
            BlenderCommands()
            // Blender's frame and keyframe keys. See AnimationCommands.swift.
            AnimationCommands()
        }
    }
}
