import SwiftUI

/// Blender's Shading workspace: the 3D viewport in Material Preview above, the
/// shader node editor below.
///
/// Blender's version also carries an image editor and a file browser for
/// textures; without a texture system those would be empty, so they are left
/// out rather than shown hollow.
struct ShadingWorkspace: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera
    @State private var options = ViewportOptions()

    var body: some View {
        VStack(spacing: 0) {
            // Blender switches this workspace straight into Material Preview,
            // which is the whole point of it.
            MetalViewportView(scene: scene, camera: $camera,
                              shading: .material, options: options,
                              onSelectionChange: { _ in })
                .frame(maxHeight: .infinity)

            BEditorDivider(.horizontal)

            ShaderNodeEditor(scene: scene, session: session)
                .frame(height: 300)
        }
    }
}

/// Blender's UV Editing workspace: the UV editor on the left, the 3D viewport
/// on the right, with the object in edit mode.
struct UVEditingWorkspace: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera
    @State private var options = ViewportOptions()

    var body: some View {
        HStack(spacing: 0) {
            UVEditor(scene: scene, session: session, bridge: bridge)
                .frame(maxWidth: .infinity)

            BEditorDivider(.vertical)

            MetalViewportView(scene: scene, camera: $camera,
                              shading: .solid, options: options,
                              onSelectionChange: { _ in })
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Blender's UV Editing workspace opens in edit mode.
            if scene.active != nil { scene.setMode(.edit) }
        }
    }
}
