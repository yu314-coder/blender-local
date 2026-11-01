import SwiftUI

@main
struct BlenderLocalApp: App {
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
