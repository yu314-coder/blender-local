import SwiftUI
import simd

/// Blender's Object ▸ Set Origin and Object ▸ Apply, defined once and shown in
/// both places this app surfaces the Object menu: the Mac menu bar
/// (KeyboardCommands.swift) and the 3D View's More pop-up
/// (LayoutWorkspace.swift). Two copies of these rows would drift, and a
/// greyed-out row that disagrees between the two would be worse than no row.

// What greys a row out is `ObjectTransformState` (BlenderLocalBridge), which
// the 3D View's Blender check compiles and holds against Blender's operators.

/// `VIEW3D_MT_object_set_origin`.
struct SetOriginMenu: View {
    var state: ObjectTransformState
    var setOrigin: (Bpy.OriginChoice) -> Void

    var body: some View {
        Menu("Set Origin") {
            ForEach(Bpy.originMenu) { choice in
                Button(choice.title) { setOrigin(choice) }
            }
        }
        .disabled(!state.enabled || !state.canSetOrigin)
    }
}

/// `VIEW3D_MT_object_apply`, the part of it these two operators cover.
struct ApplyTransformMenu: View {
    var state: ObjectTransformState
    var apply: (Bpy.AppliedTransform) -> Void

    var body: some View {
        Menu("Apply") {
            ForEach(Bpy.AppliedTransform.allCases) { what in
                Button {
                    apply(what)
                } label: {
                    if what == .scale, let scale = state.activeScaleText {
                        Text(what.title)
                        Text(scale)
                    } else {
                        Text(what.title)
                    }
                }
                .disabled(!state.offers(what))
            }
        }
        .disabled(!state.enabled || !state.canApply)
    }
}

/// Both menus, with the divider Blender has around them, for a caller that
/// wants the pair.
struct ObjectTransformItems: View {
    var state: ObjectTransformState
    var setOrigin: (Bpy.OriginChoice) -> Void
    var apply: (Bpy.AppliedTransform) -> Void

    var body: some View {
        SetOriginMenu(state: state, setOrigin: setOrigin)
        ApplyTransformMenu(state: state, apply: apply)
    }
}
