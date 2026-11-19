import SwiftUI

@main
struct BlenderLocalApp: App {
    init() {
        // The interface language's table, before the first view asks for text.
        LaunchTrace.waitForProfiler()
        LaunchTrace.mark("app init")
        BpyPrewarm.start()
        Translation.load()
        LaunchTrace.mark("translations loaded")
    }

    var body: some Scene {
        let _ = LaunchTrace.once("scene body")
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
            // Blender's Render menu. See RenderCommands.swift.
            RenderCommands()
        }
    }
}
