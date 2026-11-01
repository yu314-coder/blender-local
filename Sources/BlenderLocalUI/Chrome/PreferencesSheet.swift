import SwiftUI

/// Blender's Preferences, as far as this app has any: the version and build it
/// is, and the two tests of the build on this device. The top bar's gear and
/// File ▸ Preferences… open it (Blender keeps Preferences… in its Edit menu,
/// which this top bar does not have).
///
/// Testing holds the two app-only features, under their own names: Test All
/// Features (`FeatureTestSheet`), which runs every feature and rates how
/// smooth each is, and the Self-Test (`SelfTestSheet`), the crash fixes'
/// checks. Both ship in Release, since the TestFlight build is the one they
/// have to check. The Self-Test used to open only after seven taps on the
/// Version row; it is a button beside the other now.
struct PreferencesSheet: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var showSelfTest = false
    @State private var showFeatureTest = false

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(StatusBar.versionString)
                            .foregroundStyle(BTheme.textDim)
                    }
                }
                Section("Testing") {
                    testRow("Test All Features",
                            "Runs every feature on this device and rates each Smooth, OK, Slow, Freeze or Failed, "
                            + "with a report. About three minutes.") { showFeatureTest = true }
                    testRow("Self-Test",
                            "Runs the app's crash-fix checks and vertex-budget refusals, with a report. "
                            + "About a minute.") { showSelfTest = true }
                }
            }
            .sheet(isPresented: $showFeatureTest) {
                FeatureTestSheet(scene: scene, session: session, bridge: bridge, workspace: $workspace)
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $showSelfTest) {
            SelfTestSheet(session: session)
        }
        #if DEBUG
        // `-self-test` and `-feature-test`: the button pressed, through its
        // own action.
        .onAppear {
            if SelfTestLaunch.requested, !SelfTestLaunch.tapped {
                SelfTestLaunch.tapped = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showSelfTest = true }
            }
            if FeatureTestLaunch.requested, !FeatureTestLaunch.opened {
                FeatureTestLaunch.opened = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showFeatureTest = true }
            }
        }
        #endif
    }

    /// A test's button, with one line of what it does.
    private func testRow(_ title: String, _ explanation: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(title, action: action)
                .disabled(session.isRunning || session.gestureHold != nil)
            Text(explanation)
                .font(BTheme.Font.ui(12))
                .foregroundStyle(BTheme.textDim)
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
/// DEBUG `-self-test`: Preferences opened at launch, its Self-Test button
/// pressed through its own action, and the Self-Test's Run pressed; the
/// report's path is printed when it ends. The whole way in, for a Mac whose
/// screen cannot be clicked (a locked screen refuses synthetic clicks). Once
/// per launch.
enum SelfTestLaunch {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-self-test") }
    static var tapped = false
    static var ran = false
}
#endif
