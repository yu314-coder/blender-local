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

    /// Blender's Display Mode dropdown. Only the two that mean something for a
    /// scene this size are live.
    enum DisplayMode: String, CaseIterable, Identifiable {
        case viewLayer = "View Layer"
        case scene = "Scene"
        case blenderFile = "Blender File"
        case orphanData = "Orphan Data"

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

    /// The tree Blender's View Layer shows with Object Children on: each
    /// child under its parent, a level in (`BKScene.outlinerRows`). The
    /// parent is Blender's, read back by the mirror after every command, so
    /// Object ▸ Parent shows here the moment Blender has done it. Children
    /// stay listed under a parent whose data is folded, where Blender hides
    /// them: here the triangle folds the object's own data, and a hierarchy
    /// that vanished behind it would read as objects that had gone.
    private var rows: [OutlinerRow] { scene.outlinerRows(matching: search) }

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
            Text(display == .scene ? "Scene" : "Scene Collection")
                .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
            Spacer()
            Text("\(scene.objects.count)")
                .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
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
                row(icon: "square.stack.3d.up", name: "Collection", depth: 0,
                    selected: false, id: nil) {}

                let rows = rows
                ForEach(rows, id: \.object.id) { row in
                    let obj = row.object
                    objectRow(obj, depth: row.depth)
                    if expanded.contains(obj.id) {
                        if obj.overlayDisplay == nil {
                            childRows(of: obj, depth: row.depth)
                        } else {
                            OutlinerObjectData(object: obj)
                                .padding(.leading, CGFloat(row.depth) * Self.indent)
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

    @ViewBuilder
    private func objectRow(_ obj: BKObject, depth: Int = 0) -> some View {
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
                // reason — Blender greys the row the same way.
                Text(obj.name)
                    .font(BTheme.Font.ui(11))
                    .foregroundStyle(scene.selection.contains(obj.id) ? BTheme.title
                                     : obj.visible ? BTheme.text : BTheme.textDim)
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
                Button {
                    bridge?.run(Bpy.setDisabledInViewports(obj.name, false), undo: "Enable in Viewports")
                } label: {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 9))
                        .foregroundStyle(BTheme.active)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help("Disabled in Viewports")
                .accessibilityLabel("Disabled in viewports: enable")
            }
            Button {
                bridge?.run(Bpy.setHidden(obj.name, !obj.hiddenInViewLayer),
                            undo: obj.hiddenInViewLayer ? "Show" : "Hide")
            } label: {
                Image(systemName: obj.hiddenInViewLayer ? "eye.slash" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(obj.hiddenInViewLayer ? BTheme.active : BTheme.textDim)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight)
            .help(obj.hiddenInViewLayer ? "Show in Viewport" : "Hide in Viewport")
            .accessibilityLabel(obj.hiddenInViewLayer ? "Hidden: show" : "Shown: hide")

            Button {
                bridge?.run(Bpy.setHideRender(obj.name, !obj.hideRender), undo: "Disable in Render")
            } label: {
                Image(systemName: obj.hideRender ? "camera.fill" : "camera")
                    .font(.system(size: 9))
                    .foregroundStyle(obj.hideRender ? BTheme.active : BTheme.textDim.opacity(0.7))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight)
            .help(obj.hideRender ? "Disabled in Render" : "Enabled in Render")
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
