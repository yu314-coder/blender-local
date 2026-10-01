import SwiftUI

// Blender's animation keys, on a Magic Keyboard.
//
// Blender 5.2.1 binds them in two keymaps
// (scripts/presets/keyconfig/keymap_data/blender_default.py). `km_frames`
// works over every editor: Space plays, Shift Ctrl Space plays backwards, Esc
// cancels, Left and Right step a frame, Shift Left and Right jump to the ends,
// and Up and Down jump between keyframes — Up to the previous one, in 5.2.1.
// `km_object_mode` has I for Insert Keyframe and Alt I for Delete Keyframe.
//
// Like the Object menu's commands these exist only while the 3D View's keys
// are live — nothing covering the view, nothing being typed into — so a space
// or an arrow typed into a field stays typing.

/// What the 3D View's animation offers while it is on screen. Published by
/// AnimationDock.
struct AnimationKeyActions {
    var isRunning: Bool
    var isPlaying: Bool
    /// I and Alt I are Object Mode keys. While editing, I is Inset Faces.
    var editing: Bool
    var autoKey: Bool
    var timelineShown: Bool
    var insertKeyframe: () -> Void
    /// Asks first, as Blender's Alt I does.
    var deleteKeyframe: () -> Void
    var togglePlay: (_ reverse: Bool) -> Void
    var cancel: () -> Void
    var jumpToKeyframe: (_ next: Bool) -> Void
    var offset: (_ frames: Int) -> Void
    var jumpToEndpoint: (_ end: Bool) -> Void
    var setAutoKey: (Bool) -> Void
    var setTimelineShown: (Bool) -> Void
}

private struct AnimationKeyActionsKey: FocusedValueKey { typealias Value = AnimationKeyActions }

extension FocusedValues {
    var animationKeys: AnimationKeyActions? {
        get { self[AnimationKeyActionsKey.self] }
        set { self[AnimationKeyActionsKey.self] = newValue }
    }
}

struct AnimationCommands: Commands {
    @FocusedValue(\.appKeys) private var app
    @FocusedValue(\.viewportKeys) private var viewport
    @FocusedValue(\.animationKeys) private var animation

    /// The keys, while the 3D View's are live. The 3D View withdraws its own
    /// whenever a sheet, the operator search or a text field has the keyboard.
    private var live: AnimationKeyActions? {
        guard viewport != nil, app?.searchVisible != true else { return nil }
        return animation
    }

    var body: some Commands {
        CommandMenu("Animation") { items }
    }

    @ViewBuilder private var items: some View {
        if let a = live {
            if a.editing {
                // Present, so the menu keeps its shape, but without I: in
                // edit mode I belongs to Inset Faces.
                Button("Insert Keyframe") {}.disabled(true)
                Button("Delete Keyframe…") {}.disabled(true)
            } else {
                Button("Insert Keyframe") { a.insertKeyframe() }
                    .keyboardShortcut("i", modifiers: [])
                    .disabled(a.isRunning)
                Button("Delete Keyframe…") { a.deleteKeyframe() }
                    .keyboardShortcut("i", modifiers: .option)
                    .disabled(a.isRunning)
            }
            Toggle("Auto Keying", isOn: Binding(get: { a.autoKey }, set: { a.setAutoKey($0) }))
                .disabled(a.isRunning)
            Divider()
            Button(a.isPlaying ? "Pause Animation" : "Play Animation") { a.togglePlay(false) }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(a.isRunning)
            Button("Play Animation in Reverse") { a.togglePlay(true) }
                .keyboardShortcut(.space, modifiers: [.shift, .control])
                .disabled(a.isRunning)
            if a.isPlaying {
                Button("Cancel Animation") { a.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Divider()
            Button("Jump to Previous Keyframe") { a.jumpToKeyframe(false) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(a.isRunning)
            Button("Jump to Next Keyframe") { a.jumpToKeyframe(true) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(a.isRunning)
            Button("Previous Frame") { a.offset(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(a.isRunning)
            Button("Next Frame") { a.offset(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(a.isRunning)
            Button("Jump to Start") { a.jumpToEndpoint(false) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(a.isRunning)
            Button("Jump to End") { a.jumpToEndpoint(true) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(a.isRunning)
            Divider()
            Toggle("Timeline", isOn: Binding(get: { a.timelineShown }, set: { a.setTimelineShown($0) }))
        } else if viewport == nil {
            Button("Open the 3D View") { app?.showWorkspace(.layout) }
                .disabled(app == nil)
        }
    }
}
