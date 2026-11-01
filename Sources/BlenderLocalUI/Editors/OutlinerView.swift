import SwiftUI

/// Blender's Outliner: the scene tree, with the restriction columns down its
/// right edge.
///
/// Blender shows more than a list of names. Each object expands to the data it
/// owns — its mesh, its modifier stack, its material — and each row carries the
/// toggles that decide whether it is visible, renderable and selectable. Those
/// columns are the reason the Outliner is worth opening at all, so they are
/// here rather than only the names.
struct OutlinerView: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    @State private var expanded: Set<UUID> = []
    @State private var search = ""
    @State private var display: DisplayMode = .viewLayer
    @State private var renaming: UUID?
    @State private var draftName = ""
    /// Collections folded by their triangle, by uid. Blender's start open.
    /// Folded collection rows and the one being renamed, by the instance's
    /// key (`CollectionTree.Entry.id`): a collection linked into two parents
    /// is two rows, each folded and renamed by itself.
    @State private var collapsed: Set<String> = []
    @State private var renamingCollection: String?
    @State private var draftCollectionName = ""
    @FocusState private var collectionNameFocused: Bool

    /// Blender's Display Mode dropdown. Only the two that mean something for a
    /// scene this size are live.
    enum DisplayMode: String, CaseIterable, Identifiable {
        // Blender's display modes, by their names in 5.2.1
        // (`SpaceOutliner.display_mode`): Scenes, and Unused Data — which
        // was Orphan Data before 4.2.
        case viewLayer = "View Layer"
        case scene = "Scenes"
        case blenderFile = "Blender File"
        case orphanData = "Unused Data"

        var id: String { rawValue }
        var isImplemented: Bool { self == .viewLayer || self == .scene }
        var icon: String {
            switch self {
            case .viewLayer:   return "square.3.layers.3d"
            case .scene:       return "photo"
            case .blenderFile: return "doc"
            case .orphanData:  return "trash"
            }
        }
    }

    /// The tree Blender's View Layer shows: the Scene Collection, its
    /// collections as Blender holds them (`BKScene.collections`, read back
    /// every pass), each object under every collection it is in, and with
    /// Object Children on each child under its parent (`outlinerTree`). It
    /// used to be one hard-coded row called "Collection" over every object,
    /// whatever collections the scene had. Children stay listed under a
    /// parent whose data is folded, where Blender hides them: here the
    /// object's triangle folds its own data, and a hierarchy that vanished
    /// behind it would read as objects that had gone.
    private var rows: [OutlinerTreeRow] { scene.outlinerTree(matching: search, collapsed: collapsed) }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchRow
            tree
        }
        .background(BTheme.outliner)
    }

    private var header: some View {
        BHeader(background: BTheme.headerOutliner) {
            Menu {
                ForEach(DisplayMode.allCases) { m in
                    Button {
                        if m.isImplemented { display = m }
                    } label: {
                        Label(m.rawValue, systemImage: display == m ? "checkmark" : m.icon)
                    }
                    .disabled(!m.isImplemented)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: display.icon).font(.system(size: 10))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(BTheme.textDim)
            }
            Text(display == .scene ? "Scene" : (scene.collections?.viewLayer ?? "View Layer"))
                .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
            Spacer()
            Text("\(scene.objects.count)")
                .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
            // Blender's header button: a new collection inside the one
            // that is active (the Outliner's `collection_new`, nested).
            if let tree = scene.collections, let parent = tree.active ?? tree.sceneCollection {
                Button {
                    bridge?.run(CollectionsBpy.new(inside: parent.uid))
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11)).foregroundStyle(BTheme.textDim)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help("New Collection")
                .accessibilityLabel("New Collection")
                .disabled(session.isRunning)
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.text)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(BTheme.field.opacity(0.5))
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let rows = rows
                ForEach(rows) { row in
                    switch row.item {
                    case .collection(let entry):
                        collectionRow(entry, excluded: row.excluded, hasChildren: row.hasChildren)
                    case .object(let obj):
                        objectRow(obj, depth: row.depth, excluded: row.excluded)
                        if expanded.contains(obj.id) {
                            if obj.overlayDisplay == nil {
                                childRows(of: obj, depth: row.depth)
                            } else {
                                OutlinerObjectData(object: obj)
                                    .padding(.leading, CGFloat(row.depth) * Self.indent)
                            }
                        }
                    }
                }

                if rows.isEmpty && !search.isEmpty {
                    Text("No match for “\(search)”")
                        .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    /// How far in each level of the parent tree sits.
    static let indent: CGFloat = 14

    // MARK: collections

    /// A collection's row, as Blender's Outliner draws one: the triangle, the
    /// Exclude from View Layer checkbox, the icon (highlighted for the active
    /// collection), the name, and the restriction columns. A tap makes it
    /// Blender's active collection, where new objects go; a double-tap
    /// renames it; a long press has New Collection, Delete and Delete
    /// Hierarchy. Every one writes through the bridge and the row shows what
    /// the next pass reads back.
    @ViewBuilder
    private func collectionRow(_ entry: CollectionTree.Entry, excluded: Bool, hasChildren: Bool) -> some View {
        let tree = scene.collections ?? CollectionTree(viewLayer: "", entries: [entry])
        HStack(spacing: 2) {
            Button {
                if collapsed.contains(entry.id) { collapsed.remove(entry.id) }
                else { collapsed.insert(entry.id) }
            } label: {
                Image(systemName: collapsed.contains(entry.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(BTheme.textDim.opacity(hasChildren ? 1 : 0.3))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(collapsed.contains(entry.id) ? "Expand" : "Collapse")

            if !entry.isSceneCollection {
                // The checkbox: Exclude from View Layer, ticked when included.
                Button {
                    bridge?.run(CollectionsBpy.set(.exclude, of: entry, in: tree, on: entry.excluded))
                } label: {
                    Image(systemName: entry.excluded ? "square" : "checkmark.square.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.excluded ? BTheme.textDim : BTheme.text)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help(CollectionsBpy.Toggle.exclude.label)
                .accessibilityLabel(CollectionsBpy.Toggle.exclude.label)
                .accessibilityValue(entry.excluded ? "On" : "Off")
            }

            Image(systemName: entry.isSceneCollection ? "photo" : "square.stack.3d.up")
                .font(.system(size: 10))
                .foregroundStyle(entry.active ? BTheme.active : BTheme.textDim)
                .frame(width: 16)

            if renamingCollection == entry.id {
                TextField("", text: $draftCollectionName)
                    .textFieldStyle(.plain)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(BTheme.text)
                    .autocorrectionDisabled()
                    .focused($collectionNameFocused)
                    .onAppear { collectionNameFocused = true }
                    .onSubmit { commitCollectionRename(entry) }
                    // Ended by a tap elsewhere too, as Blender's field is.
                    .onChange(of: collectionNameFocused) { _, now in
                        if !now, renamingCollection == entry.id { commitCollectionRename(entry) }
                    }
            } else {
                Text(entry.name)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(excluded || entry.hidden ? BTheme.textDim : BTheme.text)
                    .lineLimit(1)
                    .accessibilityLabel(entry.active ? "\(entry.name), active collection" : entry.name)
                    .onTapGesture(count: 2) {
                        guard !entry.isSceneCollection else { return }
                        renamingCollection = entry.id
                        draftCollectionName = entry.name
                    }
            }
            Spacer(minLength: 4)
            if !entry.isSceneCollection {
                collectionColumns(entry, in: tree)
            }
        }
        .padding(.leading, 8 + CGFloat(entry.depth) * Self.indent)
        .frame(height: 20)
        .background(entry.active ? BTheme.select.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard renamingCollection != entry.id, !entry.active, !excluded else { return }
            bridge?.run(CollectionsBpy.setActive(entry, in: tree))
        }
        .contextMenu {
            Button("New Collection", systemImage: "folder.badge.plus") {
                bridge?.run(CollectionsBpy.new(inside: entry.uid))
            }
            if !entry.isSceneCollection {
                Divider()
                Button("Delete", role: .destructive) {
                    bridge?.run(CollectionsBpy.delete(entry.uid, hierarchy: false))
                }
                Button("Delete Hierarchy", role: .destructive) {
                    bridge?.run(CollectionsBpy.delete(entry.uid, hierarchy: true))
                }
            }
        }
    }

    /// A collection's restriction columns, as Blender's Outliner can show
    /// them: the eye (the view layer's Hide in Viewport), the arrow (Disable
    /// Selection) and the camera (Disable in Renders). The monitor, Disable
    /// in Viewports, shows only when it is set, as for objects.
    private func collectionColumns(_ entry: CollectionTree.Entry, in tree: CollectionTree) -> some View {
        HStack(spacing: 2) {
            if entry.disabled {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 9)).foregroundStyle(BTheme.active)
                    .frame(width: 18)
                    .help("Disable in Viewports")
                    .accessibilityLabel("Disable in Viewports")
                    .accessibilityValue("On")
            }
            columnButton(entry.hidden ? "eye.slash" : "eye", on: entry.hidden,
                         label: CollectionsBpy.Toggle.hide.label) {
                bridge?.run(CollectionsBpy.set(.hide, of: entry, in: tree, on: entry.hidden))
            }
            columnButton(entry.selectable ? "cursorarrow" : "cursorarrow.slash", on: !entry.selectable,
                         label: CollectionsBpy.Toggle.selectable.label) {
                bridge?.run(CollectionsBpy.set(.selectable, of: entry, in: tree, on: !entry.selectable))
            }
            columnButton(entry.renders ? "camera" : "camera.fill", on: !entry.renders,
                         label: CollectionsBpy.Toggle.render.label) {
                bridge?.run(CollectionsBpy.set(.render, of: entry, in: tree, on: !entry.renders))
            }
        }
        .padding(.trailing, 6)
    }

    /// One restriction toggle. `on` is the property's own state (hidden,
    /// selection disabled, render disabled), which Blender's tooltip names.
    private func columnButton(_ icon: String, on: Bool, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(on ? BTheme.active : BTheme.textDim.opacity(0.8))
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
        .disabled(session.isRunning)
    }

    private func commitCollectionRename(_ entry: CollectionTree.Entry) {
        let wanted = draftCollectionName.trimmingCharacters(in: .whitespaces)
        renamingCollection = nil
        guard !wanted.isEmpty, wanted != entry.name else { return }
        bridge?.run(CollectionsBpy.rename(entry.uid, from: entry.name, to: wanted))
    }

    // MARK: objects

    @ViewBuilder
    private func objectRow(_ obj: BKObject, depth: Int = 0, excluded: Bool = false) -> some View {
        HStack(spacing: 0) {
            // A child's guide back to its parent, as Blender's Outliner draws
            // one down the left of every nested row.
            if depth > 0 {
                Rectangle()
                    .fill(BTheme.textDim.opacity(0.35))
                    .frame(width: 1, height: 20)
                    .padding(.leading, 14 + CGFloat(depth - 1) * Self.indent)
                    .padding(.trailing, Self.indent - 7)
                    .accessibilityHidden(true)
            }
            // The disclosure triangle, as Blender draws it.
            Button {
                if expanded.contains(obj.id) { expanded.remove(obj.id) }
                else { expanded.insert(obj.id) }
            } label: {
                Image(systemName: expanded.contains(obj.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(BTheme.textDim)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight)
            .padding(.leading, depth > 0 ? 0 : 8)

            Image(systemName: obj.outlinerIcon)
                .font(.system(size: 10))
                .foregroundStyle(obj.id == scene.activeID ? BTheme.active : BTheme.textDim)
                .frame(width: 16)

            if renaming == obj.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(BTheme.text)
                    .autocorrectionDisabled()
                    .onSubmit { commitRename(obj) }
            } else {
                // Dimmed when the viewport does not draw it, for whatever
                // reason — Blender greys the row the same way — except Local
                // View's, which Blender's Outliner does not show; and in an
                // excluded collection, where the object is not in the view
                // layer at all. Outside Local View and hidden with H (or
                // disabled) as well, it is dimmed for that: it read
                // `MESH|hidden|notlocal|layerhidden` and was drawn ungreyed.
                let dimmed = !obj.visible
                    && (!obj.outsideLocalView || obj.hiddenInViewLayer || obj.disabledInViewports)
                Text(obj.name)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(scene.selection.contains(obj.id) ? BTheme.title
                                     : excluded ? BTheme.textDim.opacity(0.6)
                                     : dimmed ? BTheme.textDim : BTheme.text)
                    .lineLimit(1)
                    .accessibilityLabel(obj.parentName.map { "\(obj.name), child of \($0)" } ?? obj.name)
                    // Blender renames from the Outliner with a double-click.
                    .onTapGesture(count: 2) {
                        renaming = obj.id
                        draftName = obj.name
                    }
            }

            Spacer(minLength: 4)
            restrictionColumns(obj)
        }
        .frame(height: 20)
        .background(scene.selection.contains(obj.id)
                    ? BTheme.select.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard renaming != obj.id else { return }
            // Selection only: no reason to read every mesh back for a click.
            bridge?.select(Bpy.select(obj.name))
        }
    }

    /// Blender's restriction columns: the eye (hide in viewport) and the camera
    /// (disable in render), with the monitor (disable in viewports) shown only
    /// for an object that has it set — Blender's Outliner hides that column by
    /// default, and here it is the way back for such an object, which Show
    /// Hidden Objects leaves off.
    ///
    /// The eye is the view layer's flag, `hide_get()`, the one H and Alt+H
    /// change. It used to show whether the object was drawn and write
    /// `hide_viewport`, so an object hidden with H showed a closed eye whose
    /// tap set a flag that was already off, and stayed hidden.
    private func restrictionColumns(_ obj: BKObject) -> some View {
        HStack(spacing: 2) {
            if obj.disabledInViewports {
                // The monitor: `hide_viewport`, whose name — "Disable in
                // Viewports" — is what Blender's tooltip and its step say,
                // turned on or off.
                Button {
                    bridge?.run(Bpy.setDisabledInViewports(obj.name, false), undo: "Disable in Viewports")
                } label: {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 9))
                        .foregroundStyle(BTheme.active)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help("Disable in Viewports")
                .accessibilityLabel("Disable in Viewports")
                .accessibilityValue("On")
            }
            // The eye: the view layer's `hide_viewport`, "Hide in Viewport".
            Button {
                bridge?.run(Bpy.setHidden(obj.name, !obj.hiddenInViewLayer), undo: "Hide in Viewport")
            } label: {
                Image(systemName: obj.hiddenInViewLayer ? "eye.slash" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(obj.hiddenInViewLayer ? BTheme.active : BTheme.textDim)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight)
            .help("Hide in Viewport")
            .accessibilityLabel("Hide in Viewport")
            .accessibilityValue(obj.hiddenInViewLayer ? "On" : "Off")

            // The camera: `hide_render`, "Disable in Renders".
            Button {
                bridge?.run(Bpy.setHideRender(obj.name, !obj.hideRender), undo: "Disable in Renders")
            } label: {
                Image(systemName: obj.hideRender ? "camera.fill" : "camera")
                    .font(.system(size: 9))
                    .foregroundStyle(obj.hideRender ? BTheme.active : BTheme.textDim.opacity(0.7))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight)
            .help("Disable in Renders")
            .accessibilityLabel("Disable in Renders")
            .accessibilityValue(obj.hideRender ? "On" : "Off")
        }
        .padding(.trailing, 6)
    }

    /// What an object owns, which is what Blender nests beneath it.
    @ViewBuilder
    private func childRows(of obj: BKObject, depth level: Int = 0) -> some View {
        let inset = CGFloat(level) * Self.indent
        Group {
            dataRows(of: obj)
        }
        .padding(.leading, inset)
    }

    @ViewBuilder
    private func dataRows(of obj: BKObject) -> some View {
        row(icon: "triangle", name: "\(obj.name) Mesh", depth: 2, selected: false, id: nil) {}
        // A hidden object keeps the mesh it was last drawn with, and nothing
        // it changes to while hidden reaches the app: its counts could be
        // ones Blender no longer holds.
        Text(obj.visible ? "\(obj.mesh.vertices.count) verts · \(obj.mesh.indices.count / 3) tris"
                         : "hidden · not mirrored until shown")
            .font(BTheme.Font.mono(9))
            .foregroundStyle(BTheme.textDim.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 62)
            .frame(height: 16)

        // By name, as Blender's Outliner lists them: a Geometry Nodes
        // modifier's kind says nothing, and "Smooth by Angle" does.
        ForEach(obj.modifiers) { mod in
            row(icon: "wrench.and.screwdriver", name: mod.name,
                depth: 2, selected: false, id: nil) {}
        }
        row(icon: "circle.fill", name: obj.material.name, depth: 2, selected: false, id: nil) {}
        if obj.mesh.hasUVs {
            // Blender's name for the map when the mirror carried one; the
            // simulator's projection has none and Blender's default stands in.
            row(icon: "grid", name: obj.mesh.uvMapName.isEmpty ? "UVMap" : obj.mesh.uvMapName,
                depth: 2, selected: false, id: nil) {}
        }
        if !obj.vertexColours.isEmpty {
            row(icon: "paintpalette", name: "Col", depth: 2, selected: false, id: nil) {}
        }
        if !obj.vertexWeights.isEmpty {
            row(icon: "scalemass", name: "Group", depth: 2, selected: false, id: nil) {}
        }
    }

    private func row(icon: String, name: String, depth: Int, selected: Bool,
                     id: UUID?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
            Text(name)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(selected ? BTheme.title : BTheme.text)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16 + 12)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func commitRename(_ obj: BKObject) {
        let wanted = draftName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !wanted.isEmpty, wanted != obj.name else { return }
        // Blender's `.001` rule lives in the data layer, so the name that comes
        // back may not be the one asked for — which is why the rename goes
        // through bpy rather than being applied here and echoed.
        bridge?.run(Bpy.rename(obj.name, to: wanted), undo: "Rename")
    }
}
