import SwiftUI

/// Rows of Blender's Object menu (VIEW3D_MT_object) and edit mode's Mesh menu
/// that this app shows in two places — the Mac menu bar (KeyboardCommands.swift)
/// and the 3D View's More and Mesh pop-ups (LayoutWorkspace.swift). Defined
/// once, as ObjectTransformMenus.swift does for Set Origin and Apply, so the
/// two places cannot drift apart.
///
/// Every row runs Blender's operator through the bridge and shows nothing of
/// its own: what it did comes back through the mirror.

/// Object ▸ Show/Hide in object mode (VIEW3D_MT_object_showhide), Mesh ▸
/// Show/Hide while editing (VIEW3D_MT_edit_mesh_showhide), in Blender's order:
/// the reveal first, then Hide Selected and Hide Unselected.
struct ShowHideMenu: View {
    var editing: Bool
    var run: (Bpy.ShowHide) -> Void

    var body: some View {
        Menu("Show/Hide") {
            ForEach(Bpy.ShowHide.allCases, id: \.self) { what in
                if what == .hideSelected { Divider() }
                Button(what.label(editing: editing)) { run(what) }
            }
        }
    }
}

/// Mesh ▸ Separate, while editing: `mesh.separate`'s three types.
struct SeparateMenu: View {
    var run: (Bpy.SeparateType) -> Void

    var body: some View {
        Menu("Separate") {
            ForEach(Bpy.SeparateType.allCases, id: \.self) { type in
                Button(type.label) { run(type) }
            }
        }
    }
}

/// The Object menu's shading group — Shade Smooth, Shade Auto Smooth, Shade
/// Flat, in Blender's order — with Shade Smooth by Angle after it. Blender
/// keeps that one in its operator search; it is here because Auto Smooth
/// needs the Essentials asset library the app's bpy does not ship, and Smooth
/// by Angle does the same once without it.
///
/// Auto Smooth and Smooth by Angle are object-mode operators on meshes, as
/// in Blender's menu (which offers Auto Smooth for curves and text too; here
/// it is held to meshes, whose mesh the redo panel can put back).
struct ShadingItems: View {
    /// A mesh is active and the view is in object mode.
    var meshInObjectMode: Bool
    /// Anything is active.
    var hasObject: Bool
    /// Whether Blender has the Essentials asset library Auto Smooth loads
    /// from (`BpySession.essentialsLibrary`); nil until Blender is asked,
    /// and then the row is offered and a failure says why in words.
    var essentialsLibrary: Bool?
    var shade: (_ smooth: Bool) -> Void
    var perform: (LastOperator) -> Void

    var body: some View {
        Button("Shade Smooth", systemImage: "circle.righthalf.filled") { shade(true) }
            .disabled(!hasObject)
        // Greyed out without the library, where it would fail every time: the
        // device's bpy has none. The subtitle is the reason, since a menu row
        // on an iPad has no tooltip to give it in.
        Button {
            perform(LastOperator.shadeAutoSmooth())
        } label: {
            Text("Shade Auto Smooth")
            if essentialsLibrary == false {
                Text("Needs Blender's Essentials library — Smooth by Angle below does not")
            }
        }
        .disabled(!meshInObjectMode || essentialsLibrary == false)
        Button("Shade Flat", systemImage: "square.righthalf.filled") { shade(false) }
            .disabled(!hasObject)
        Button("Shade Smooth by Angle") { perform(LastOperator.shadeSmoothByAngle()) }
            .disabled(!meshInObjectMode)
    }
}

/// The Object menu's Duplicate Linked and Join (after Duplicate Objects, as
/// Blender has them), then Parent and Convert — VIEW3D_MT_object's rows in
/// 5.2.1's order. Each is Blender's operator through `perform`, so its redo
/// panel (Keep Transform, the Clear type, Keep Original) opens where Blender's
/// undo keeps the history, and what it did — a hierarchy in the Outliner, a
/// joined mesh, a curve — comes back through the mirror.
///
/// `withKeys` gives the rows Blender's keys, for the Mac menu bar: Alt+D for
/// Duplicate Linked, and Ctrl+J for Join as ⌘J (Blender's Ctrl is ⌘ here, as
/// Bevel's ⌘B is). Parent's Ctrl+P and Clear Parent's Alt+P open menus in
/// Blender, and a SwiftUI submenu cannot carry a key.
struct ObjectRelationItems: View {
    var state: ObjectRelationState
    var withKeys = false
    var perform: (LastOperator) -> Void

    var body: some View {
        Button("Duplicate Linked", systemImage: "link") { perform(.duplicateLinked()) }
            .keyboardShortcut(withKeys ? KeyboardShortcut("d", modifiers: .option) : nil)
            .disabled(!state.canDuplicate)
        Button("Join", systemImage: "arrow.triangle.merge") { perform(.join()) }
            .keyboardShortcut(withKeys ? KeyboardShortcut("j", modifiers: .command) : nil)
            .disabled(!state.canJoin)
        Divider()
        // Blender's Ctrl+P menu offers Keep Transform as a row of its own;
        // its Object ▸ Parent menu then the three ways to clear.
        Menu("Parent") {
            Button("Object") { perform(.parent(keepTransform: false)) }
                .disabled(!state.canParent)
            Button("Object (Keep Transform)") { perform(.parent(keepTransform: true)) }
                .disabled(!state.canParent)
            Divider()
            ForEach(LastOperator.ClearParentType.allCases, id: \.self) { type in
                Button(type.label) { perform(.clearParent(type)) }
                    .disabled(!state.canClearParent)
            }
            if !state.canParent && state.available {
                Text("Select the children, then the parent last")
            }
        }
        .disabled(!state.available)
        Menu("Convert") {
            ForEach(LastOperator.ConvertTarget.allCases, id: \.self) { target in
                Button(target.label) { perform(.convert(to: target)) }
            }
        }
        .disabled(!state.canConvert)
    }
}
