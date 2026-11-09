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
        // Greyed out without the library, where it would fail every time. The
        // app's bpy carries the library since build 59 (it had none before),
        // so this is the fallback for a bpy staged without it. The subtitle is
        // the reason, since a menu row on an iPad has no tooltip to give it in
        // — ONE short line: the iPad's menu does not grow a row for a wrapped
        // subtitle, and build 58's three-line one ("… — Smooth by Angle below
        // does not") was drawn over Shade Flat (the user's screenshot,
        // November 9).
        Button {
            perform(LastOperator.shadeAutoSmooth())
        } label: {
            Text("Shade Auto Smooth")
            if essentialsLibrary == false {
                Text("Needs the Essentials library")
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
        DuplicateLinkedJoinItems(state: state, withKeys: withKeys, perform: perform)
        Divider()
        ObjectParentMenu(state: state, perform: perform)
        ObjectConvertMenu(state: state, perform: perform)
    }
}

/// Duplicate Linked and Join, after Duplicate Objects in Blender's Object menu.
struct DuplicateLinkedJoinItems: View {
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
    }
}

/// Object ▸ Parent: Blender's Ctrl+P menu offers Keep Transform as a row of
/// its own; its Object ▸ Parent menu then the three ways to clear.
struct ObjectParentMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
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
    }
}

/// Object ▸ Convert.
struct ObjectConvertMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Menu("Convert") {
            ForEach(LastOperator.ConvertTarget.allCases, id: \.self) { target in
                Button(target.label) { perform(.convert(to: target)) }
            }
        }
        .disabled(!state.canConvert)
    }
}

/// Object menu rows that were reachable only by name in the Operator Search
/// (round 3's review, toolkit items 11, 12 and 15), each where Blender's
/// Object menu keeps it (VIEW3D_MT_object, 5.2.1): Transform's Randomize
/// Transform and Align Objects, Mirror, Collection's Move to Collection (M)
/// and Link to Collection (Shift+M), Relations ▸ Make Single User, Modifiers
/// ▸ Copy Modifiers to Selected Objects, Constraints, and Link/Transfer Data
/// (Ctrl+L). Each row is Blender's operator through `perform` (its redo
/// panel) or `run` (Move and Link, whose panel Blender draws empty), and
/// shows nothing of its own: what it did comes back through the mirror.
/// Shared by the Mac menu bar and the 3D View's More menu.
struct ObjectMenuMoreItems: View {
    var state: ObjectRelationState
    var collections: CollectionTree?
    var perform: (LastOperator) -> Void
    var run: (BlenderCommand) -> Void
    /// Move or Link to New Collection inside `parent`: the name prompt
    /// Blender's invoke shows ("Move to New Collection", Name, Create).
    var askNewCollection: (_ parent: Int, _ link: Bool) -> Void

    var body: some View {
        Menu("Transform") { RandomizeAlignItems(state: state, perform: perform) }
            .disabled(!state.available)
        ObjectMirrorMenu(state: state, perform: perform)
        ObjectCollectionMenu(state: state, collections: collections, run: run,
                             askNewCollection: askNewCollection)
        ObjectRelationsMenu(state: state, perform: perform)
        ObjectModifiersMenu(state: state, perform: perform)
        ObjectConstraintsMenu(state: state, perform: perform)
        LinkTransferDataMenu(state: state, perform: perform)
    }
}

/// Object ▸ Transform's last rows: Randomize Transform and Align Objects.
struct RandomizeAlignItems: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Button("Randomize Transform") { perform(.randomizeTransform()) }
            .disabled(!state.canDuplicate)
        Button("Align Objects") { perform(.alignObjects()) }
            .disabled(!state.canDuplicate)
    }
}

/// Object ▸ Mirror.
struct ObjectMirrorMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Menu("Mirror") {
            // Ctrl+M: waits for X, Y or Z, as Blender's row does
            // (ModalTransform.swift).
            Button("Interactive Mirror") { ModalTransformState.beginMirror() }
                .disabled(!state.canDuplicate)
            Divider()
            ForEach(Array(LastOperator.mirrorRows.enumerated()), id: \.offset) { i, row in
                if i == 3 { Divider() }
                Button(row.label) { perform(.mirror(axis: row.axis, local: row.local)) }
                    .disabled(!state.canDuplicate)
            }
        }
        .disabled(!state.available)
    }
}

/// Object ▸ Collection: Move to Collection (M) and Link to Collection
/// (Shift+M).
struct ObjectCollectionMenu: View {
    var state: ObjectRelationState
    var collections: CollectionTree?
    var run: (BlenderCommand) -> Void
    var askNewCollection: (_ parent: Int, _ link: Bool) -> Void

    var body: some View {
        Menu("Collection") {
            if let collections, let root = collections.sceneCollection {
                Menu("Move to Collection") {
                    CollectionPickMenu(tree: collections, entry: root, link: false, run: run,
                                       askNewCollection: askNewCollection)
                }
                Menu("Link to Collection") {
                    CollectionPickMenu(tree: collections, entry: root, link: true, run: run,
                                       askNewCollection: askNewCollection)
                }
            } else {
                Text("Blender sent no collections")
            }
        }
        .disabled(!state.canDuplicate)
    }
}

/// Object ▸ Relations ▸ Make Single User.
struct ObjectRelationsMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Menu("Relations") {
            Menu("Make Single User") {
                ForEach(LastOperator.SingleUser.allCases, id: \.self) { row in
                    Button(row.label) { perform(.makeSingleUser(row)) }
                }
            }
        }
        .disabled(!state.canDuplicate)
    }
}

/// Object ▸ Modifiers.
struct ObjectModifiersMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Menu("Modifiers") {
            Button("Copy Modifiers to Selected Objects") { perform(.copyModifiersToSelected()) }
        }
        .disabled(!state.canJoin)
    }
}

/// Object ▸ Constraints.
struct ObjectConstraintsMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Menu("Constraints") {
            Menu("Add Constraint (with Targets)") {
                ForEach(ConstraintMenu.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.types, id: \.id) { type in
                            Button(type.label) { perform(.addConstraintWithTargets(type.id)) }
                        }
                    }
                }
            }
            .disabled(!state.hasActive)
            Button("Copy Constraints to Selected Objects") { perform(.copyConstraintsToSelected()) }
                .disabled(!state.canJoin)
            Button("Clear Object Constraints") { perform(.clearObjectConstraints()) }
                .disabled(!state.canDuplicate)
        }
        .disabled(!state.available)
    }
}

/// Object ▸ Link/Transfer Data (Ctrl+L).
struct LinkTransferDataMenu: View {
    var state: ObjectRelationState
    var perform: (LastOperator) -> Void

    var body: some View {
        Menu("Link/Transfer Data") {
            ForEach(Array(LastOperator.makeLinksTypes.enumerated()), id: \.offset) { i, type in
                // Blender's separators: after Link Fonts to Text, and after
                // Copy Shadow Linking (before Copy UV Maps).
                if i == 6 { Divider() }
                Button(type.label) { perform(.makeLinksData(type.identifier)) }
            }
            Divider()
            Button("Copy UV Maps") { perform(.copyUVMaps()) }
        }
        .disabled(!state.canJoin)
    }
}

/// Blender's Move to Collection and Link to Collection menus
/// (`move_to_collection_menu_draw`): New Collection, the collection itself,
/// then its children — a child with children of its own as a submenu that
/// starts the same way.
struct CollectionPickMenu: View {
    let tree: CollectionTree
    let entry: CollectionTree.Entry
    let link: Bool
    let run: (BlenderCommand) -> Void
    let askNewCollection: (_ parent: Int, _ link: Bool) -> Void

    var body: some View {
        Button("New Collection", systemImage: "plus") { askNewCollection(entry.uid, link) }
        Divider()
        Button(entry.name) { run(CollectionsBpy.move(to: entry.uid, link: link)) }
        ForEach(tree.children(of: entry.uid)) { child in
            if tree.children(of: child.uid).isEmpty {
                Button(child.name) { run(CollectionsBpy.move(to: child.uid, link: link)) }
            } else {
                Menu(child.name) {
                    AnyView(CollectionPickMenu(tree: tree, entry: child, link: link, run: run,
                                               askNewCollection: askNewCollection))
                }
            }
        }
    }
}
