import SwiftUI

/// Runs `refresh` when it appears and whenever `key()` changes — what
/// `.task(id:)` does — but reads the key in a body of its own.
///
/// An editor that builds its key in its own body redraws whenever anything
/// the key reads changes. With the frame in the key, that was the whole 3D
/// View screen (`LayoutWorkspace`) and the whole Properties editor at every
/// frame of playback or a scrub, each frame costing a millisecond in Blender
/// and many more in SwiftUI. Put behind the editor (`.background`), only this
/// empty view redraws, and `refresh` still runs on every change of the key.
struct KeyedRefresh<Key: Equatable>: View {
    let key: () -> Key
    let refresh: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key()) { refresh() }
    }
}
