import SwiftUI
import simd

/// The part of Blender's Add menu that is not meshes (`VIEW3D_MT_add`):
/// Curve ▸ Bézier and Circle, Text, Lattice, Empty ▸ each display type,
/// Light ▸ each type, and Camera, in Blender's order, with Blender's
/// separators.
struct ObjectAddItems: View {
    var add: (ObjectAddition) -> Void

    var body: some View {
        Divider()
        CurveAddMenu(add: add)
        Button { add(.text) } label: {
            Label(ObjectAddition.text.label, systemImage: ObjectAddition.text.icon)
        }
        // After Text, as in Blender's menu (its Armature row is not offered).
        Button { add(.lattice) } label: {
            Label(ObjectAddition.lattice.label, systemImage: ObjectAddition.lattice.icon)
        }
        Divider()
        EmptyAddMenu(add: add)
        Divider()
        LightAddMenu(add: add)
        Divider()
        Button { add(.camera) } label: {
            Label(ObjectAddition.camera.label, systemImage: ObjectAddition.camera.icon)
        }
    }
}

/// `VIEW3D_MT_curve_add`'s Bézier rows. Each arrives as a wire — neither is
/// filled — drawn by its edges, in object mode; Edit Curve edits its knots
/// and handles (ControlPoints.swift).
struct CurveAddMenu: View {
    var add: (ObjectAddition) -> Void

    var body: some View {
        Menu {
            ForEach(ObjectAddition.CurveKind.allCases, id: \.self) { kind in
                Button { add(.curve(kind)) } label: { Label(kind.label, systemImage: kind.icon) }
            }
        } label: {
            Label("Curve", systemImage: ObjectAddition.CurveKind.bezier.icon)
        }
    }
}

/// `VIEW3D_MT_empty_add`.
struct EmptyAddMenu: View {
    var add: (ObjectAddition) -> Void

    var body: some View {
        Menu {
            ForEach(EmptyDisplay.Kind.addMenu, id: \.self) { kind in
                Button { add(.empty(kind)) } label: { Label(kind.label, systemImage: kind.icon) }
            }
        } label: {
            Label("Empty", systemImage: EmptyDisplay.Kind.arrows.icon)
        }
    }
}

/// `VIEW3D_MT_light_add`.
struct LightAddMenu: View {
    var add: (ObjectAddition) -> Void

    var body: some View {
        Menu {
            ForEach(LightDisplay.Kind.allCases, id: \.self) { kind in
                Button { add(.light(kind)) } label: { Label(kind.label, systemImage: kind.icon) }
            }
        } label: {
            Label("Light", systemImage: "lightbulb")
        }
    }
}

extension BpyBridge {
    /// Adds a curve, text, camera, light or empty the way the Add menu adds a
    /// primitive: at the 3D cursor, as one undo step that Adjust Last
    /// Operation can change, and without moving the view. A camera faces the way `view`
    /// faces, as Blender aligns one added from its 3D View.
    @discardableResult
    func add(_ addition: ObjectAddition, at cursor: SIMD3<Float>, view: ViewportCamera?) -> Outcome {
        perform(LastOperator.add(addition, at: cursor, viewRotation: view?.objectRotation))
    }
}

/// What the keyboard's Object ▸ Add menu can add besides primitives. The 3D
/// View publishes it while its keys are live, as it does `ViewportKeyActions`.
struct ObjectAddActions {
    var add: (ObjectAddition) -> Void
}

private struct ObjectAddActionsKey: FocusedValueKey { typealias Value = ObjectAddActions }

extension FocusedValues {
    var objectAddActions: ObjectAddActions? {
        get { self[ObjectAddActionsKey.self] }
        set { self[ObjectAddActionsKey.self] = newValue }
    }
}
