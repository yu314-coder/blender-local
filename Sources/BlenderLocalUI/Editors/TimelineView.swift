import SwiftUI

/// Blender's Timeline, docked under the 3D View as Blender's Layout workspace
/// docks it. Shown from More ▸ Timeline or Animation ▸ Timeline; the dock
/// around it (AnimationDock.swift) owns playback and the keyboard.
///
/// The header follows `playback_controls` in Blender 5.2.1's
/// scripts/startup/bl_ui/space_time.py, left to right: the View and Marker
/// menus, the Playback popover, the record button and its popover, the
/// transport, then the current frame, the preview-range toggle and the range.
/// Two buttons are added for a screen with no I key: Insert and Delete
/// Keyframe, which Blender keeps in the Dope Sheet's Keying popover. The body
/// is the scrubbing strip with its numbers and playhead box
/// (time_scrub_ui.cc) over the summary of keys, with the frames outside the
/// range darkened (anim_draw.cc).
///
/// Nothing here holds animation state. Blender owns the frame, the range and
/// the keys; the mirror puts them in the scene, this draws them, and every
/// control goes through `TimelineDriver`.
struct TimelineView: View {
    var scene: BKScene
    var session: BpySession
    /// Asks before deleting keyframes, as Blender's Alt I does.
    var confirmDelete: () -> Void
    var close: () -> Void

    private let docked: TimelineDriver?
    @State private var standalone = TimelineDriver()
    private var driver: TimelineDriver { docked ?? standalone }

    static let scrubHeight: CGFloat = 22
    static let keysHeight: CGFloat = 46

    init(scene: BKScene, session: BpySession, driver: TimelineDriver,
         confirmDelete: @escaping () -> Void, close: @escaping () -> Void) {
        self.scene = scene
        self.session = session
        self.docked = driver
        self.confirmDelete = confirmDelete
        self.close = close
    }

    /// Without a dock: a driver of its own, which moves the frame and changes
    /// settings but has no bridge to key with.
    init(scene: BKScene, session: BpySession) {
        self.scene = scene
        self.session = session
        self.docked = nil
        self.confirmDelete = {}
        self.close = {}
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TimelineBody(scene: scene, driver: driver)
                .frame(height: Self.scrubHeight + Self.keysHeight)
        }
        .background(TimelineColours.back)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1)
        }
        .disabled(session.isRunning)
        .onAppear {
            if docked == nil { standalone.bind(scene: scene, session: session, bridge: nil) }
        }
    }

    // MARK: header

    private var header: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(BTheme.textDim)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                    viewMenu
                    markerMenu
                    playbackMenu
                    Spacer(minLength: 16)
                    TimelineAutoKeying(scene: scene, driver: driver)
                    keyingButtons
                    TimelineTransport(scene: scene, driver: driver)
                    Spacer(minLength: 16)
                    TimelineCurrentFrame(scene: scene, driver: driver)
                    TimelineRange(scene: scene, driver: driver)
                    closeButton
                }
                .padding(.horizontal, 6)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
        .frame(height: BTheme.Metric.headerHeight)
    }

    /// TIME_MT_view's toggle that matters here: whose keys the summary shows
    /// and the jumps step through.
    private var viewMenu: some View {
        Menu("View") {
            Toggle("Only Show Selected", isOn: Binding(get: { scene.animation.onlySelectedKeys },
                                                       set: { driver.setOnlySelectedKeys($0) }))
            Divider()
            BUnavailable("Show Seconds")
            BUnavailable("Show Markers")
        }
        .menuStyle(BlenderMenuStyle())
    }

    private var markerMenu: some View {
        Menu("Marker") {
            BUnavailable("Add Marker")
            BUnavailable("Rename Marker")
            BUnavailable("Delete Marker")
        }
        .menuStyle(BlenderMenuStyle())
    }

    /// TIME_PT_playback, as much of it as applies: the loop mode. Playback
    /// always drops frames rather than slow down, whatever the scene's Sync
    /// says, and the menu says so.
    private var playbackMenu: some View {
        Menu("Playback") {
            Picker("Loop", selection: Binding(get: { scene.animation.loopMode },
                                              set: { driver.setLoopMode($0) })) {
                ForEach(PlaybackLoopMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Divider()
            Text("Sync: Frame Dropping").disabled(true)
            Text("Frame Rate: \(Self.rate(scene.animation.fps)) fps").disabled(true)
        }
        .menuStyle(BlenderMenuStyle())
    }

    static func rate(_ fps: Double) -> String {
        fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
    }

    private var keyingButtons: some View {
        HStack(spacing: 1) {
            TimelineButton(label: "Insert Keyframe", action: { driver.insertKeyframe() }) {
                Image(systemName: "key.fill").font(.system(size: 11))
            }
            TimelineButton(label: "Delete Keyframe", action: confirmDelete) {
                Image(systemName: "key.slash").font(.system(size: 11))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BTheme.textDim)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Hide Timeline")
    }
}

// MARK: - Colours

/// The default theme's Timeline colours, as Blender 5.2.1 reports them from
/// `bpy.context.preferences.themes[0]`, and the shading its drawing code
/// applies to them.
enum TimelineColours {
    /// `dopesheet_editor.space.back`
    static let back = Color(hex: 0x303030)
    /// `regions.scrubbing.back` — TH_TIME_SCRUB_BACKGROUND
    static let scrubBack = Color(hex: 0x1D1D1D)
    /// `regions.scrubbing.text` — TH_TIME_SCRUB_TEXT
    static let scrubText = Color(hex: 0x808080)
    /// `common.anim.playhead` — TH_CFRAME
    static let playhead = Color(hex: 0x4772B3)
    /// `dopesheet_editor.space.header_text_hi` — TH_HEADER_TEXT_HI
    static let playheadText = Color(hex: 0xFFFFFF)
    /// `dopesheet_editor.grid`
    static let grid = Color(hex: 0x161616)
    /// ANIM_draw_framerange: TH_BACK shaded -25, its alpha lowered by 100.
    static let outsideRange = Color(hex: 0x171717).opacity(155.0 / 255.0)
    /// …and a line at each end in TH_BACK shaded -60, which clamps to black.
    static let rangeLine = Color(hex: 0x000000)
    /// ANIM_draw_previewrange: TH_ANIM_PREVIEW_RANGE (#A14D0066) shaded -25,
    /// its alpha lowered by 30.
    static let previewCurtain = Color(hex: 0x883400).opacity(72.0 / 255.0)
    /// `common.anim.keyframe` and `keyframe_selected`, drawn with
    /// `dopesheet_editor.keyframe_border`.
    static let key = Color(hex: 0xBFBFBF)
    static let keySelected = Color(hex: 0xFFBE33)
    static let keyBorder = Color(hex: 0x000000)
    /// `user_interface.wcol_toggle.inner_sel`: a toggle that is on.
    static let toggleOn = Color(hex: 0x4772B3)
    /// `user_interface.wcol_num.inner_sel`: a number field being edited.
    static let fieldActive = Color(hex: 0x222222)
    /// `user_interface.icon_autokey`, "Auto Keying Indicator": the colour
    /// RECORD_ON's themed dot is drawn in.
    static let autoKey = Color(hex: 0xAB3C48)
}

// MARK: - Controls

/// One of the header's buttons: `wcol_regular`, or `wcol_toggle` when on.
/// Grouped buttons sit 1 point apart and share rounded ends, the way Blender
/// draws an aligned row.
private struct TimelineButton<Content: View>: View {
    var label: String
    var enabled = true
    var on = false
    var width: CGFloat = 30
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(on ? Color.white : BTheme.text.opacity(enabled ? 1 : 0.3))
                .frame(width: width, height: 26)
                .background(on ? TimelineColours.toggleOn : BTheme.widget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// PREV_KEYFRAME and NEXT_KEYFRAME: a key with an arrow pointing the way.
private struct KeyframeJumpIcon: View {
    var next: Bool

    var body: some View {
        HStack(spacing: 1) {
            if !next { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 6)) }
            Image(systemName: "diamond.fill").font(.system(size: 9))
            if next { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 6)) }
        }
    }
}

/// RECORD_OFF is a ring in white at 60%; RECORD_ON a filled dot inside a
/// ring at 80% (release/datafiles/icons_svg).
private struct RecordIcon: View {
    var on: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(on ? 0.8 : 0.6), lineWidth: 1.2)
            if on {
                Circle().fill(TimelineColours.autoKey).padding(2.6)
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// The record button — `tool_settings.use_keyframe_insert_auto` — and
/// TIME_PT_auto_keyframing beside it, dimmed while auto keying is off.
private struct TimelineAutoKeying: View {
    var scene: BKScene
    var driver: TimelineDriver

    var body: some View {
        let on = scene.animation.autoKey
        HStack(spacing: 1) {
            TimelineButton(label: "Auto Keying", on: on, action: { driver.setAutoKeying(!on) }) {
                RecordIcon(on: on)
            }
            Menu {
                Picker("Auto-Keying Mode", selection: Binding(get: { scene.animation.autoKeyReplace },
                                                              set: { driver.setAutoKeyingReplace($0) })) {
                    Text("Add & Replace").tag(false)
                    Text("Replace").tag(true)
                }
                .pickerStyle(.inline)
                // A preference in Blender, and the one that decides whether
                // auto keying keys anything not already animated; there is no
                // Preferences editor here to find it in.
                Toggle("Only Insert Available", isOn: Binding(get: { scene.animation.onlyInsertAvailable },
                                                              set: { driver.setOnlyInsertAvailable($0) }))
                BUnavailable("Only Active Keying Set")
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(BTheme.text.opacity(on ? 1 : 0.5))
                    .frame(width: 18, height: 26)
                    .background(BTheme.widget)
            }
            .accessibilityLabel("Auto Keying Settings")
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }
}

/// Jump to Endpoint, Jump to Keyframe, Play backwards, Play — or Pause, which
/// Blender draws twice as wide in place of both play buttons while playing.
private struct TimelineTransport: View {
    var scene: BKScene
    var driver: TimelineDriver

    var body: some View {
        let previous = scene.keyframeJumpTarget(next: false) != nil
        let next = scene.keyframeJumpTarget(next: true) != nil
        HStack(spacing: 1) {
            TimelineButton(label: "Jump to Start", action: { driver.jumpToEndpoint(end: false) }) {
                Image(systemName: "backward.end.fill").font(.system(size: 10))
            }
            TimelineButton(label: "Jump to Previous Keyframe", enabled: previous,
                           action: { driver.jumpToKeyframe(next: false) }) {
                KeyframeJumpIcon(next: false)
            }
            if driver.isPlaying {
                TimelineButton(label: "Pause Animation", width: 61, action: { driver.pause() }) {
                    Image(systemName: "pause.fill").font(.system(size: 10))
                }
            } else {
                TimelineButton(label: "Play Animation in Reverse", action: { driver.play(reverse: true) }) {
                    Image(systemName: "play.fill").font(.system(size: 10)).scaleEffect(x: -1, y: 1)
                }
                TimelineButton(label: "Play Animation", action: { driver.play() }) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                }
            }
            TimelineButton(label: "Jump to Next Keyframe", enabled: next,
                           action: { driver.jumpToKeyframe(next: true) }) {
                KeyframeJumpIcon(next: true)
            }
            TimelineButton(label: "Jump to End", action: { driver.jumpToEndpoint(end: true) }) {
                Image(systemName: "forward.end.fill").font(.system(size: 10))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }
}

/// `scene.frame_current`, in its own view so a frame change redraws only this.
private struct TimelineCurrentFrame: View {
    var scene: BKScene
    var driver: TimelineDriver

    var body: some View {
        TimelineNumberField(label: "", value: scene.frameCurrent, width: 62,
                            onDrag: { driver.scrub(to: $0) },
                            onCommit: { frame in
                                driver.scrub(to: frame)
                                driver.flushPendingFrame()
                            })
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            .accessibilityLabel("Current Frame")
    }
}

/// The preview-range toggle, then Start and End — the preview range's while
/// it is on, as Blender's header swaps them.
private struct TimelineRange: View {
    var scene: BKScene
    var driver: TimelineDriver

    var body: some View {
        let a = scene.animation
        HStack(spacing: 6) {
            TimelineButton(label: "Use Preview Range", on: a.usePreviewRange,
                           action: { driver.setUsePreviewRange(!a.usePreviewRange) }) {
                Image(systemName: "stopwatch").font(.system(size: 11))
            }
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            HStack(spacing: 1) {
                if a.usePreviewRange {
                    TimelineNumberField(label: "Start", value: a.previewStart, width: 86,
                                        onCommit: { driver.setPreviewStart($0) })
                        .accessibilityLabel("Preview Range Start Frame")
                    TimelineNumberField(label: "End", value: a.previewEnd, width: 86,
                                        onCommit: { driver.setPreviewEnd($0) })
                        .accessibilityLabel("Preview Range End Frame")
                } else {
                    TimelineNumberField(label: "Start", value: scene.frameStart, width: 86,
                                        onCommit: { driver.setFrameStart($0) })
                        .accessibilityLabel("Start Frame")
                    TimelineNumberField(label: "End", value: scene.frameEnd, width: 86,
                                        onCommit: { driver.setFrameEnd($0) })
                        .accessibilityLabel("End Frame")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
    }
}

/// Blender's integer field (`wcol_num`): drag across it to change the value,
/// tap it to type one. A drag shows its value as it goes and is kept when the
/// finger lifts, so it is one undo step rather than one per frame of the drag.
private struct TimelineNumberField: View {
    var label: String
    var value: Int
    var width: CGFloat
    /// Called as a drag changes the value, for a field the scene follows live.
    var onDrag: ((Int) -> Void)? = nil
    /// The value to keep, once a drag or an edit ends.
    var onCommit: (Int) -> Void

    @State private var dragStart: Int?
    @State private var dragValue: Int?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if editing {
                TextField("", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .font(BTheme.Font.mono(11))
                    .foregroundStyle(Color.white)
                    .focused($focused)
                    .onSubmit(finishTyping)
                    .padding(.horizontal, 4)
                    .onAppear { DispatchQueue.main.async { focused = true } }
            } else {
                HStack(spacing: 4) {
                    if !label.isEmpty {
                        Text(label).foregroundStyle(BTheme.textDim)
                    }
                    Text(verbatim: "\(dragValue ?? value)")
                        .monospacedDigit()
                        .foregroundStyle(dragStart == nil ? BTheme.text : Color.white)
                }
                .font(BTheme.Font.ui(11))
                .lineLimit(1)
            }
        }
        .frame(width: width, height: 26)
        .background(editing || dragStart != nil ? TimelineColours.fieldActive : BTheme.widget)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !editing else { return }
            text = String(value)
            editing = true
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { g in
                    guard !editing else { return }
                    let base = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    let next = base + Int((g.translation.width / 4).rounded(.towardZero))
                    if next != dragValue {
                        dragValue = next
                        onDrag?(next)
                    }
                }
                .onEnded { _ in
                    let final = dragValue
                    dragStart = nil
                    dragValue = nil
                    if let final { onCommit(final) }
                }
        )
        .onChange(of: focused) { _, isFocused in
            if !isFocused, editing { finishTyping() }
        }
        .accessibilityValue(Text(verbatim: "\(value)"))
    }

    private func finishTyping() {
        guard editing else { return }
        editing = false
        if let typed = Int(text.trimmingCharacters(in: .whitespaces)) { onCommit(typed) }
    }
}

// MARK: - Body

/// Which frames the body shows across its width: the scene range, with a
/// margin either side so the darkened frames beyond each end are visible, as
/// Blender's Frame Scene Range leaves them.
struct TimelineWindow: Equatable {
    var first: Double
    var last: Double
    var width: CGFloat

    init(range: ClosedRange<Int>, width: CGFloat) {
        let span = Double(max(range.upperBound - range.lowerBound, 1))
        let margin = max(span * 0.04, 1)
        first = Double(range.lowerBound) - margin
        last = Double(range.upperBound) + margin
        self.width = max(width, 1)
    }

    func x(_ frame: Double) -> CGFloat {
        CGFloat((frame - first) / (last - first)) * width
    }

    /// The whole frame nearest a point — a scrub snaps to frames.
    func frame(at x: CGFloat) -> Int {
        Int((first + Double(x / width) * (last - first)).rounded())
    }

    /// Frames between numbers: the smallest of the usual steps that keeps the
    /// numbers a readable distance apart.
    func step(minimumSpacing: CGFloat = 56) -> Int {
        let perFrame = width / CGFloat(last - first)
        let steps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000,
                     10_000, 25_000, 50_000, 100_000, 250_000, 500_000]
        return steps.first { CGFloat($0) * perFrame >= minimumSpacing } ?? 1_000_000
    }

    /// The numbered frames across the window.
    var numbered: [Int] {
        let step = step()
        var frames: [Int] = []
        var f = Int((first / Double(step)).rounded(.up)) * step
        while Double(f) <= last {
            frames.append(f)
            f += step
        }
        return frames
    }
}

/// A drag or a tap anywhere on the body moves the playhead there.
private struct TimelineBody: View {
    var scene: BKScene
    var driver: TimelineDriver

    var body: some View {
        GeometryReader { geo in
            let window = TimelineWindow(range: scene.frameStart...max(scene.frameEnd, scene.frameStart),
                                        width: geo.size.width)
            ZStack(alignment: .topLeading) {
                TimelineKeyLayer(scene: scene, window: window, scrubHeight: TimelineView.scrubHeight)
                TimelineScrubNumbers(window: window, height: TimelineView.scrubHeight)
                TimelinePlayhead(scene: scene, window: window, scrubHeight: TimelineView.scrubHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in driver.scrub(to: window.frame(at: g.location.x)) }
                    .onEnded { g in
                        driver.scrub(to: window.frame(at: g.location.x))
                        driver.flushPendingFrame()
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(Text(verbatim: "Frame \(scene.frameCurrent)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: driver.offset(1)
            case .decrement: driver.offset(-1)
            @unknown default: break
            }
        }
    }
}

/// The grid, the range, and a diamond per column of keys. Redrawn when the
/// keys or the range change, not when the frame does.
private struct TimelineKeyLayer: View {
    var scene: BKScene
    var window: TimelineWindow
    var scrubHeight: CGFloat

    var body: some View {
        let keys = scene.timelineKeys
        let start = scene.frameStart
        let end = scene.frameEnd
        let a = scene.animation
        let preview: (Int, Int)? = a.usePreviewRange ? (a.previewStart, a.previewEnd) : nil
        Canvas { context, size in
            let full = CGRect(origin: .zero, size: size)
            context.fill(Path(full), with: .color(TimelineColours.back))

            for f in window.numbered {
                let x = window.x(Double(f)).rounded()
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                             with: .color(TimelineColours.grid))
            }

            // ANIM_draw_framerange.
            let xs = window.x(Double(start))
            let xe = window.x(Double(end))
            if start < end {
                context.fill(Path(CGRect(x: 0, y: 0, width: max(xs, 0), height: size.height)),
                             with: .color(TimelineColours.outsideRange))
                context.fill(Path(CGRect(x: xe, y: 0, width: max(size.width - xe, 0), height: size.height)),
                             with: .color(TimelineColours.outsideRange))
            } else {
                context.fill(Path(full), with: .color(TimelineColours.outsideRange))
            }
            for x in [xs, xe] {
                context.fill(Path(CGRect(x: x.rounded() - 0.5, y: 0, width: 1, height: size.height)),
                             with: .color(TimelineColours.rangeLine))
            }

            // ANIM_draw_previewrange.
            if let preview {
                let ps = window.x(Double(preview.0))
                let pe = window.x(Double(preview.1))
                if preview.0 < preview.1 {
                    context.fill(Path(CGRect(x: 0, y: 0, width: max(ps, 0), height: size.height)),
                                 with: .color(TimelineColours.previewCurtain))
                    context.fill(Path(CGRect(x: pe, y: 0, width: max(size.width - pe, 0), height: size.height)),
                                 with: .color(TimelineColours.previewCurtain))
                } else {
                    context.fill(Path(full), with: .color(TimelineColours.previewCurtain))
                }
            }

            // The summary: a diamond per column, in the middle of the key area.
            let y = scrubHeight + (size.height - scrubHeight) / 2
            let r: CGFloat = 5.5
            for key in keys {
                let x = window.x(Double(key.frame))
                guard x > -r, x < size.width + r else { continue }
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: y - r))
                diamond.addLine(to: CGPoint(x: x + r, y: y))
                diamond.addLine(to: CGPoint(x: x, y: y + r))
                diamond.addLine(to: CGPoint(x: x - r, y: y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(key.selected ? TimelineColours.keySelected : TimelineColours.key))
                context.stroke(diamond, with: .color(TimelineColours.keyBorder), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The scrubbing strip along the top, with its frame numbers.
private struct TimelineScrubNumbers: View {
    var window: TimelineWindow
    var height: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: height)),
                         with: .color(TimelineColours.scrubBack))
            for f in window.numbered {
                context.draw(Text(verbatim: "\(f)")
                                .font(BTheme.Font.ui(10))
                                .foregroundStyle(TimelineColours.scrubText),
                             at: CGPoint(x: window.x(Double(f)), y: height / 2))
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// ANIM_draw_cfra's line, and the playhead box with the frame in it.
private struct TimelinePlayhead: View {
    var scene: BKScene
    var window: TimelineWindow
    var scrubHeight: CGFloat

    var body: some View {
        let subframe = scene.animation.subframe
        let frame = Double(scene.frameCurrent) + Double(subframe)
        let x = window.x(frame)
        let label = subframe == 0 ? "\(scene.frameCurrent)" : String(format: "%.1f", frame)
        GeometryReader { geo in
            if x >= -12, x <= geo.size.width + 12 {
                Rectangle()
                    .fill(TimelineColours.playhead)
                    .frame(width: 2, height: geo.size.height)
                    .position(x: x, y: geo.size.height / 2)
                Text(verbatim: label)
                    .font(BTheme.Font.ui(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(TimelineColours.playheadText)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 24, minHeight: scrubHeight - 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(TimelineColours.playhead))
                    .position(x: min(max(x, 14), geo.size.width - 14), y: scrubHeight / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
