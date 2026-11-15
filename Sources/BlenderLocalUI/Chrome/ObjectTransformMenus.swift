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
    /// Blender's rows after Rotation & Scale (the deltas, Visual Transform,
    /// Visual Geometry, Make Instances Real, Parent Inverse), each its
    /// operator through `perform`. Nil leaves them out.
    var perform: ((LastOperator) -> Void)? = nil

    var body: some View {
        Menu("Apply") {
            ApplyTransformRows(state: state, apply: apply)
            if let perform {
                ApplyMoreRows(perform: perform)
            }
        }
        .disabled(!state.enabled || (perform == nil && !state.canApply))
    }
}

/// `object.transform_apply`'s five rows.
private struct ApplyTransformRows: View {
    var state: ObjectTransformState
    var apply: (Bpy.AppliedTransform) -> Void

    var body: some View {
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
}

/// VIEW3D_MT_object_apply after its transform rows (5.2.1), in its order and
/// with its separators.
struct ApplyMoreRows: View {
    var perform: (LastOperator) -> Void

    var body: some View {
        Divider()
        ForEach(LastOperator.deltaRows, id: \.mode) { row in
            Button(row.label) { perform(.transformsToDeltas(mode: row.mode)) }
        }
        Button("Animated Transforms to Deltas") { perform(.animatedTransformsToDeltas()) }
        Divider()
        Button("Visual Transform") { perform(.visualTransformApply()) }
        Button("Visual Geometry to Mesh") { perform(.convert(to: .mesh)) }
        Button("Visual Geometry to Objects") { perform(.visualGeometryToObjects()) }
        Button("Make Instances Real") { perform(.makeInstancesReal()) }
        Divider()
        Button("Parent Inverse") { perform(.parentInverseApply()) }
    }
}

/// Both menus, with the divider Blender has around them, for a caller that
/// wants the pair.
struct ObjectTransformItems: View {
    var state: ObjectTransformState
    var setOrigin: (Bpy.OriginChoice) -> Void
    var apply: (Bpy.AppliedTransform) -> Void
    var perform: ((LastOperator) -> Void)? = nil

    var body: some View {
        SetOriginMenu(state: state, setOrigin: setOrigin)
        ApplyTransformMenu(state: state, apply: apply, perform: perform)
    }
}
