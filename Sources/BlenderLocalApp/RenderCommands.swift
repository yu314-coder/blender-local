import SwiftUI

// Blender's Render menu on the Mac menu bar (`TOPBAR_MT_render`, 5.2.1): the
// rows open the Render panel for their action (`RenderPanelAction`), as the
// top bar's Render menu does. The keys are the 3D View's own (F12, Ctrl+F12,
// F11, Ctrl+F11, ViewportKeymap.swift): a SwiftUI menu row cannot carry an
// F key, so the rows have Blender's names and no key.

struct RenderCommands: Commands {
    @FocusedValue(\.appKeys) private var app

    var body: some Commands {
        CommandMenu("Render") {
            Button("Render Image") { RenderPanelAction.renderImage.post() }
                .disabled(app == nil)
            Button("Render Animation") { RenderPanelAction.renderAnimation.post() }
                .disabled(app == nil)
            Divider()
            Button("View Render") { RenderPanelAction.viewRender.post() }
                .disabled(app == nil)
            Button("View Animation") { RenderPanelAction.viewAnimation.post() }
                .disabled(app == nil)
        }
    }
}
