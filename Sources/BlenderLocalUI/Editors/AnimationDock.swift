import SwiftUI
import QuartzCore

/// Animation in the 3D View: the docked Timeline, playback's clock, the
/// Animation menu's keys, and the confirmation Blender asks for before it
/// deletes keyframes.
///
/// Always under the viewport, and taking no room until the Timeline is shown.
/// I, Alt I and Space work with the Timeline hidden, as they do in Blender,
/// where they belong to the 3D View and to every editor rather than to the
/// Timeline.
struct AnimationDock: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    @State private var driver = TimelineDriver()
    @State private var ticker = PlaybackTicker()
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            // Something always, so the dock is on screen to publish its keys
            // and keep its lifecycle while the Timeline is hidden.
            Color.clear.frame(height: 0)
            if scene.animation.showsTimeline {
                TimelineView(scene: scene, session: session, driver: driver,
                             confirmDelete: { confirmingDelete = true },
                             close: { scene.animation.showsTimeline = false })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: scene.animation.showsTimeline)
        .onAppear {
            bind()
            #if DEBUG
            framesLaunchIfRequested()
            #endif
        }
        // The bridge arrives after the first layout, when the root view has
        // made it.
        .onChange(of: bridge.map { ObjectIdentifier($0) }) { _, _ in bind() }
        .onChange(of: driver.isPlaying) { _, playing in
            if playing { ticker.start(driver) } else { ticker.stop() }
        }
        // A report Blender would put in its status bar — auto keying that
        // could not key — shown where a failed command's report is shown.
        .onChange(of: scene.animation.notice) { _, notice in
            guard let notice else { return }
            bridge?.showReport("Auto Keying", notice.text)
            driver.dismissNotice(notice.id)
        }
        .onDisappear {
            driver.pause()
            ticker.stop()
        }
        // Blender's Alt I asks first: delete_key_v3d_invoke in keyframing.cc.
        .alert(BpyAnimation.deleteConfirmation, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { driver.deleteKeyframe() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .focusedSceneValue(\.animationKeys, keys)
    }

    private func bind() {
        driver.bind(scene: scene, session: session, bridge: bridge)
    }

    #if DEBUG
    /// `-frames 2,3,5 -frames-wait <text>`: once the console shows the text (a
    /// `-eval64` script printed it) and no script is running, each frame through
    /// `TimelineDriver.setFrame` — what a scrub and playback call — printing
    /// what the timeline, the viewport and Blender hold after each.
    private func framesLaunchIfRequested(tries: Int = 240) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-frames"), i + 1 < args.count else { return }
        let frames = args[i + 1].split(separator: ",").compactMap { Int($0) }
        let wait = args.firstIndex(of: "-frames-wait").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        guard tries > 0 else {
            print("[bk] frames: never ready")
            fflush(stdout)
            return
        }
        // `scene`, `session` and `driver` are references, so this copy of the
        // view, captured as it appeared, still sees them change; its `bridge`
        // would stay the nil it appeared with.
        guard driver.isAvailable, session.usesRealBlender,
              wait.map({ text in session.console.contains { $0.text.contains(text) } }) ?? true else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { framesLaunchIfRequested(tries: tries - 1) }
            return
        }
        let probe = "import bpy\n_s = bpy.context.scene\nprint('BLENDER', _s.frame_current, len(_s.objects), "
            + "' '.join('%s:%.4f' % (o.name, o.matrix_world[2][3]) for o in _s.objects if o.name.startswith('Keyed')), "
            + "'handlers', len(bpy.app.handlers.frame_change_post), bpy.app.driver_namespace.get('bk_test_log', [])[-2:])"
        for frame in frames {
            let sent = driver.setFrame(frame)
            let drawn = scene.objects.filter { $0.name.hasPrefix("Keyed") }
            let heights = drawn.map { String(format: "%@:%.4f", $0.name, $0.modelMatrix.columns.3.z) }
            let blender = session.capture(probe)?.split(separator: "\n").last { $0.hasPrefix("BLENDER") } ?? "?"
            print("[bk] frames: set \(frame) -> \(sent ? "sent" : "NOT SENT"); timeline at \(scene.frameCurrent), "
                  + "\(scene.objects.count) objects drawn; drawn \(heights.joined(separator: " "))")
            print("[bk] frames: \(blender)")
            fflush(stdout)
        }
        print("[bk] frames done")
        fflush(stdout)
    }
    #endif

    private var keys: AnimationKeyActions {
        AnimationKeyActions(
            isRunning: session.isRunning,
            isPlaying: driver.isPlaying,
            editing: scene.mode == .edit,
            autoKey: scene.animation.autoKey,
            timelineShown: scene.animation.showsTimeline,
            insertKeyframe: { driver.insertKeyframe() },
            deleteKeyframe: { confirmingDelete = true },
            togglePlay: { driver.togglePlay(reverse: $0) },
            cancel: { driver.cancel() },
            jumpToKeyframe: { next in
                if !driver.jumpToKeyframe(next: next) {
                    // screen.keyframe_jump's own report.
                    session.note("No more keyframes to jump to in this direction")
                }
            },
            offset: { driver.offset($0) },
            jumpToEndpoint: { driver.jumpToEndpoint(end: $0) },
            setAutoKey: { driver.setAutoKeying($0) },
            setTimelineShown: { scene.animation.showsTimeline = $0 })
    }
}

/// Playback's clock: the driver is asked for a frame at every display refresh
/// while playing, and answers with whichever frame the time says.
final class PlaybackTicker: NSObject {
    private var link: CADisplayLink?
    private weak var driver: TimelineDriver?

    func start(_ driver: TimelineDriver) {
        self.driver = driver
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        // As often as the display refreshes. The driver evaluates a frame only
        // when the frame number changes, so the extra refreshes cost nothing,
        // and a 24 fps scene is not held to the phase of a 24 Hz refresh.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        driver?.tick()
    }
}
