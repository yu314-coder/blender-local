import SwiftUI

/// Blender's pop-up menus: the context menu a right-click opens
/// (`VIEW3D_MT_object_context_menu`, `VIEW3D_MT_edit_mesh_context_menu`) and
/// the menus its keys call at the pointer — Shift+A's Add, Ctrl+A's Apply, M,
/// X, Ctrl+E (`wm.call_menu`, and the pies as the menus they list).
///
/// SwiftUI's own menus open only when their button is tapped, and a key can
/// tap no button, so these are drawn here: a column of rows over the window,
/// at the pointer, as Blender draws them — its title, each row's key on the
/// right, a submenu opening beside its row when the pointer reaches it.
struct PopupItem {
    enum Kind {
        case action(() -> Void)
        /// Built when it opens, so a long one (Move to Collection's tree)
        /// costs nothing until it is wanted.
        case submenu(() -> [PopupItem])
        case separator
        /// A column's heading — the Edit Mode context menu's Vertex, Edge
        /// and Face.
        case heading
        /// Columns side by side, as the Edit Mode context menu lays out one
        /// per select mode in use.
        case columns([[PopupItem]])
        /// Fields rather than rows: Blender's brush panels, which a
        /// right-click opens in Sculpt Mode and the paint modes.
        case control(AnyView)
    }

    var title = ""
    var icon: String?
    /// Blender's key for the row, drawn dimmed on the right.
    var key: String?
    var enabled = true
    var checked = false
    /// Why a row is greyed out, under its title: a menu row on an iPad has no
    /// tooltip to say it in.
    var note: String?
    /// A drawn icon in place of `icon`'s symbol: the falloff curves in
    /// Shift+O's pie, as Blender draws its curve icons.
    var glyph: AnyView?
    var kind: Kind

    static func action(_ title: String, icon: String? = nil, key: String? = nil, enabled: Bool = true,
                       checked: Bool = false, note: String? = nil, glyph: AnyView? = nil,
                       _ run: @escaping () -> Void) -> PopupItem {
        PopupItem(title: title, icon: icon, key: key, enabled: enabled, checked: checked, note: note,
                  glyph: glyph, kind: .action(run))
    }

    static func submenu(_ title: String, icon: String? = nil, enabled: Bool = true, note: String? = nil,
                        _ items: @escaping () -> [PopupItem]) -> PopupItem {
        PopupItem(title: title, icon: icon, enabled: enabled, note: note, kind: .submenu(items))
    }

    static let separator = PopupItem(kind: .separator)

    static func heading(_ title: String, icon: String? = nil) -> PopupItem {
        PopupItem(title: title, icon: icon, kind: .heading)
    }

    static func columns(_ columns: [[PopupItem]]) -> PopupItem {
        PopupItem(kind: .columns(columns))
    }

    static func control(_ view: AnyView) -> PopupItem {
        PopupItem(kind: .control(view))
    }

    var isSelectable: Bool {
        switch kind {
        case .action, .submenu: return enabled
        default: return false
        }
    }
}

/// One menu open at the pointer: Blender's menu (its `bl_idname`, for the
/// launch hooks and the Info log), its title, its rows.
struct PopupMenuModel: Identifiable {
    let id = UUID()
    var name: String
    var title: String?
    /// Where it was asked for, in the overlay's coordinates.
    var anchor: CGPoint
    var items: [PopupItem]
    /// Blender's pie (`wm.call_menu_pie`): the items round the pointer in
    /// Blender's order — left, right, bottom, top, then the corners — drawn by
    /// `PieMenuOverlay`. A separator keeps its place empty.
    var pie = false
    /// The chord whose key opened it ("z", "shift+s"), which a pie waits to
    /// see let go; nil when no key did.
    var openedByKey: String?

    /// The rows as text, submenus opened, for the launch hooks to print and
    /// a check to hold against Blender's menus.
    func dump() -> String {
        var out = [name + (title.map { " \"\($0)\"" } ?? "") + (pie ? " (pie)" : "")]
        if pie {
            for (i, item) in items.prefix(8).enumerated() {
                guard let place = PieDirection.forItem(i) else { continue }
                if case .separator = item.kind { continue }
                out.append("  \(place.digit) \(place): " + (item.checked ? "[x] " : "") + item.title
                           + (item.enabled ? "" : "  (off)"))
            }
            return out.joined(separator: "\n")
        }
        func walk(_ items: [PopupItem], _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            for item in items {
                switch item.kind {
                case .separator: out.append(pad + "---")
                case .heading: out.append(pad + "# " + item.title)
                case .columns(let columns):
                    for (i, column) in columns.enumerated() {
                        out.append(pad + "| column \(i + 1)")
                        walk(column, depth + 1)
                    }
                case .control:
                    out.append(pad + "<fields>")
                case .action:
                    out.append(pad + (item.checked ? "[x] " : "") + item.title
                               + (item.key.map { "  <\($0)>" } ?? "") + (item.enabled ? "" : "  (off)"))
                case .submenu(let build):
                    out.append(pad + item.title + " >" + (item.enabled ? "" : "  (off)"))
                    if item.enabled { walk(build(), depth + 1) }
                }
            }
        }
        walk(items, 1)
        return out.joined(separator: "\n")
    }
}

/// The open menu and its open submenus, drawn over the window. A click or tap
/// anywhere else closes it, as does Escape; a row runs once the menu has
/// gone, so what it opens (a prompt, a sheet) is not opened under it.
struct PopupMenuOverlay: View {
    let model: PopupMenuModel
    let dismiss: () -> Void

    /// The submenus open beside the menu, outermost first: each one's rows
    /// and the frame of the row that opened it.
    @State private var open: [(rows: [PopupItem], from: CGRect)] = []
    @State private var sizes: [Int: CGSize] = [:]
    /// The row under the pointer or chosen with the arrow keys: (panel, row).
    @State private var hovered: (panel: Int, row: Int)?
    @State private var area: CGSize = .zero

    private static let space = "bk-popup"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Anything outside the menu closes it, without reaching what
                // is underneath — Blender's own menus swallow that click too.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                panel(0, rows: model.items, title: model.title)
                    .offset(origin(of: 0, in: geo.size))
                ForEach(Array(open.enumerated()), id: \.offset) { i, sub in
                    panel(i + 1, rows: sub.rows, title: nil)
                        .offset(origin(of: i + 1, in: geo.size))
                }
                keys
            }
            .coordinateSpace(name: Self.space)
            .onAppear { area = geo.size }
            .onChange(of: geo.size) { _, size in area = size }
        }
    }

    // MARK: placement

    /// Each panel's top-left. The menu opens with its first row under the
    /// pointer, as Blender's call_menu does; a submenu beside the row that
    /// opened it, on the left when the right has no room. Both kept inside
    /// the window.
    private func origin(of panel: Int, in bounds: CGSize) -> CGSize {
        let size = sizes[panel] ?? .zero
        var x: CGFloat
        var y: CGFloat
        if panel == 0 {
            x = model.anchor.x - 14
            y = model.anchor.y - (model.title == nil ? 14 : 36)
        } else {
            let from = open[panel - 1].from
            x = from.maxX + 2
            if x + size.width > bounds.width - 4 { x = from.minX - size.width - 2 }
            y = from.minY - 5
        }
        x = min(max(4, x), max(4, bounds.width - size.width - 4))
        y = min(max(4, y), max(4, bounds.height - size.height - 4))
        return CGSize(width: x, height: y)
    }

    // MARK: drawing

    private func panel(_ index: Int, rows: [PopupItem], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(BTheme.Font.ui(12))
                    .foregroundStyle(BTheme.textDim)
                    .padding(.horizontal, 10)
                    .frame(height: 26, alignment: .leading)
                Rectangle().fill(BTheme.outline).frame(height: 1).padding(.bottom, 3)
            }
            // A menu taller than the window — the Edit Mode context menu
            // on an upright iPad — scrolls; any other is drawn whole.
            ViewThatFits(in: .vertical) {
                column(rows, panel: index, offset: 0)
                    .padding(.vertical, 3)
                ScrollView(.vertical) {
                    column(rows, panel: index, offset: 0)
                        .padding(.vertical, 3)
                }
                .frame(maxHeight: max(area.height - 44, 60))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(BTheme.menuBack.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { sizes[index] = geo.size }
                .onChange(of: geo.size) { _, size in sizes[index] = size }
        })
        .opacity(sizes[index] == nil ? 0 : 1)
    }

    /// A column of rows. `offset` numbers the rows across columns, so the
    /// arrow keys walk one list.
    private func column(_ rows: [PopupItem], panel: Int, offset: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, item in
                switch item.kind {
                case .separator:
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 3)
                case .heading:
                    HStack(spacing: 6) {
                        if let icon = item.icon { Image(systemName: icon).frame(width: 16) }
                        Text(item.title)
                    }
                    .font(BTheme.Font.ui(12))
                    .foregroundStyle(BTheme.textDim)
                    .padding(.horizontal, 10)
                    .frame(height: 24, alignment: .leading)
                case .columns(let columns):
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { c, rows in
                            if c > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
                            column(rows, panel: panel, offset: offset + (i + 1) * 1000 + c * 100)
                        }
                    }
                case .control(let view):
                    view
                case .action, .submenu:
                    row(item, panel: panel, index: offset + i)
                }
            }
        })
    }

    private func row(_ item: PopupItem, panel: Int, index: Int) -> some View {
        let lit = hovered?.panel == panel && hovered?.row == index && item.enabled
        let isSub: Bool = { if case .submenu = item.kind { return true } else { return false } }()
        let opened = isSub && open.count > panel && openedFrom[panel] == index
        return HStack(spacing: 6) {
            Group {
                if item.checked { Image(systemName: "checkmark") }
                else if let icon = item.icon { Image(systemName: icon) }
                else { Color.clear.frame(height: 1) }
            }
            .font(.system(size: 11))
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(BTheme.Font.ui(12.5))
                if let note = item.note {
                    Text(note).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
            Spacer(minLength: 18)
            if let key = item.key {
                Text(key).font(BTheme.Font.ui(11)).foregroundStyle(lit ? Color.white.opacity(0.8) : BTheme.textDim)
            }
            if isSub {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BTheme.textDim)
            }
        }
        .foregroundStyle(item.enabled ? (lit || opened ? Color.white : BTheme.text) : BTheme.text.opacity(0.35))
        .padding(.horizontal, 8)
        .frame(minWidth: 190, minHeight: item.note == nil ? 24 : 36, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(lit || opened ? Self.highlight : Color.clear)
                        .padding(.horizontal, 3))
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear.preference(key: RowFrames.self,
                                   value: [RowKey(panel: panel, row: index): geo.frame(in: .named(Self.space))])
        })
        .onPreferenceChange(RowFrames.self) { frames in rowFrames.merge(frames) { _, new in new } }
        .onHover { inside in
            guard inside else { return }
            hovered = (panel, index)
            if isSub, item.enabled { openSubmenu(item, panel: panel, index: index) }
            else { close(after: panel) }
        }
        .onTapGesture { activate(item, panel: panel, index: index) }
    }

    /// Blender's `wcol_menu_item` highlight.
    static let highlight = Color(hex: 0x4772B3)

    // MARK: submenus and keys

    @State private var rowFrames: [RowKey: CGRect] = [:]
    /// Which row of each panel opened the submenu beside it.
    @State private var openedFrom: [Int: Int] = [:]

    private func openSubmenu(_ item: PopupItem, panel: Int, index: Int) {
        guard case .submenu(let build) = item.kind else { return }
        if openedFrom[panel] == index, open.count > panel { return }
        close(after: panel)
        let frame = rowFrames[RowKey(panel: panel, row: index)] ?? .zero
        open.append((build(), frame))
        openedFrom[panel] = index
    }

    private func close(after panel: Int) {
        if open.count > panel { open.removeSubrange(panel...) }
        for key in openedFrom.keys where key >= panel { openedFrom[key] = nil }
        for key in sizes.keys where key > panel { sizes[key] = nil }
    }

    private func activate(_ item: PopupItem, panel: Int, index: Int) {
        guard item.enabled else { return }
        switch item.kind {
        case .action(let run):
            dismiss()
            // After the menu has gone: a row that opens a prompt or a sheet
            // must not open it under a menu that is still closing.
            DispatchQueue.main.async { run() }
        case .submenu:
            if openedFrom[panel] == index { close(after: panel) }
            else { openSubmenu(item, panel: panel, index: index) }
        default:
            break
        }
    }

    /// Escape closes; Up, Down, Return, Left and Right walk the rows as they
    /// do in Blender's menus.
    private var keys: some View {
        ZStack {
            Button("") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            // A menu of fields (a brush panel) leaves Return and the arrows
            // to the field being typed into.
            if !hasFields {
                Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { enter() }.keyboardShortcut(.return, modifiers: [])
                Button("") { enter(onlySubmenu: true) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { back() }.keyboardShortcut(.leftArrow, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var hasFields: Bool {
        model.items.contains { if case .control = $0.kind { return true } else { return false } }
    }

    /// The selectable rows of a panel, in order, with the index the row
    /// views use.
    private func selectable(_ panel: Int) -> [(index: Int, item: PopupItem)] {
        let rows = panel == 0 ? model.items : (open.count >= panel ? open[panel - 1].rows : [])
        var out: [(Int, PopupItem)] = []
        func walk(_ rows: [PopupItem], _ offset: Int) {
            for (i, item) in rows.enumerated() {
                if case .columns(let columns) = item.kind {
                    for (c, column) in columns.enumerated() { walk(column, offset + (i + 1) * 1000 + c * 100) }
                } else if item.isSelectable {
                    out.append((offset + i, item))
                }
            }
        }
        walk(rows, 0)
        return out
    }

    private var activePanel: Int { min(hovered?.panel ?? 0, open.count) }

    private func step(_ by: Int) {
        let panel = activePanel
        let rows = selectable(panel)
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.index == hovered?.row && hovered?.panel == panel }
        let next = at.map { ($0 + by + rows.count) % rows.count } ?? (by > 0 ? 0 : rows.count - 1)
        hovered = (panel, rows[next].index)
        close(after: panel)
    }

    private func enter(onlySubmenu: Bool = false) {
        let panel = activePanel
        guard let row = hovered?.row, let item = selectable(panel).first(where: { $0.index == row })?.item else {
            return
        }
        if case .submenu = item.kind {
            openSubmenu(item, panel: panel, index: row)
            if let first = selectable(panel + 1).first { hovered = (panel + 1, first.index) }
        } else if !onlySubmenu {
            activate(item, panel: panel, index: row)
        }
    }

    private func back() {
        let panel = activePanel
        guard panel > 0 else { return }
        hovered = (panel - 1, openedFrom[panel - 1] ?? 0)
        close(after: panel - 1)
    }
}

private struct RowKey: Hashable {
    let panel: Int
    let row: Int
}

private struct RowFrames: PreferenceKey {
    static let defaultValue: [RowKey: CGRect] = [:]
    static func reduce(value: inout [RowKey: CGRect], nextValue: () -> [RowKey: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
