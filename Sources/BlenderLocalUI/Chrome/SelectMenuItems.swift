import SwiftUI

/// Blender's Select menu — `VIEW3D_MT_select_object` in Object Mode,
/// `VIEW3D_MT_select_edit_mesh` while editing — with its rows in 5.2.1's
/// order (SelectMenu.swift in the bridge has what each sends and why).
///
/// Nothing here holds a selection: every row is one command through the
/// bridge, and what is selected afterwards is what the mirror reads back from
/// Blender. The three gesture rows pick the tool, as Blender's own rows start
/// the gesture.
struct SelectMenuItems: View {
    var editing: Bool
    var selectMode: MeshSelectMode
    var tool: ActiveTool
    /// Whether Blender has an active object, which Parent, Child and Select
    /// Linked start from.
    var hasActive: Bool
    /// How many vertex groups the mirror reported on the active mesh, nil
    /// when it reported none (the simulator): Ungrouped Vertices' poll.
    var vertexGroups: Int? = nil
    var choose: (ActiveTool) -> Void
    var send: (SelectMenu.Command) -> Void
    /// Select Pattern…, which needs the pattern typed.
    var askPattern: () -> Void
    /// What a finger's tap does while editing a mesh: one of Blender's pick
    /// selections, or nil for an ordinary select (MetalViewportView.pick).
    var pick: SelectPick? = nil
    var pickShift = false
    var setPick: (SelectPick?) -> Void = { _ in }
    var setPickShift: (Bool) -> Void = { _ in }
    /// Whether the 3D View hands a tap to the pick: while a mesh is edited,
    /// not a curve's or a lattice's points (LayoutWorkspace gives the view
    /// `pick` only then). The rows that set it are drawn only then too —
    /// round 4's review: a row ticked there that taps then ignore is a
    /// control that reaches nothing. Off unless the caller says so.
    var picks = false

    var body: some View {
        Button("All") { send(.all) }
        Button("None") { send(.none) }
        Button("Invert") { send(.invert) }
        Divider()
        ForEach([ActiveTool.boxSelect, .circleSelect, .lassoSelect], id: \.self) { t in
            Button { choose(t) } label: {
                Label(t.label, systemImage: tool == t ? "checkmark" : t.icon)
            }
        }
        Divider()
        if editing {
            if picks {
                pickRows
                Divider()
            }
            editRows
        } else { objectRows }
    }

    // MARK: picks

    /// Blender's pick selections, which are keys and not rows in Blender's
    /// menu (Alt+click, Ctrl+Alt+click, Ctrl+click, L): a touch screen has no
    /// Alt or Ctrl, so here each is a row that makes it what a tap does,
    /// ticked while it is, with Blender's keys under its name, and the row of
    /// what Shift adds in Blender's keymap (to an ordinary click, Toggle
    /// Selection). Select puts the tap back.
    @ViewBuilder private var pickRows: some View {
        Button { setPick(nil) } label: {
            Label("Select", systemImage: pick == nil ? "checkmark" : "cursorarrow.click")
        }
        ForEach(SelectPick.allCases, id: \.self) { item in
            Button { setPick(item) } label: {
                Label { Text(item.operatorName); Text(item.keys) } icon: {
                    Image(systemName: pick == item ? "checkmark" : item.icon)
                }
            }
        }
        Toggle(pick?.shiftLabel ?? SelectPick.toggleLabel,
               isOn: Binding(get: { pickShift }, set: { setPickShift($0) }))
    }

    // MARK: edit mode

    @ViewBuilder private var editRows: some View {
        mesh(.mirror)
        mesh(.random)
        mesh(.checkerDeselect)
        Divider()
        Menu("More/Less") {
            mesh(.more)
            mesh(.less)
            Divider()
            // Both walk Blender's selection order, which a tap now leaves
            // as Blender's click does (`EditSelection.history`).
            mesh(.nextActive)
            mesh(.previousActive)
        }
        Divider()
        Menu("Select Similar") {
            // Blender lists the types of the select mode in use and refuses
            // the others by name.
            ForEach(SelectMenu.SimilarType.offered(in: selectMode), id: \.self) { type in
                Button(type.label) { send(.similar(type)) }
            }
            Divider()
            mesh(.similarRegion)
        }
        Menu("Select All by Trait") {
            if SelectMenu.MeshItem.nonManifold.isOffered(in: selectMode) { mesh(.nonManifold) }
            mesh(.loose)
            mesh(.interiorFaces)
            mesh(.facesBySides)
            mesh(.polesByCount)
            Divider()
            // Drawn greyed where Blender's poll fails, as its menu draws it.
            mesh(.ungrouped)
                .disabled(!SelectMenu.MeshItem.ungrouped.isEnabled(in: selectMode, vertexGroups: vertexGroups))
        }
        Menu("Select Linked") {
            mesh(.linked)
            mesh(.shortestPath)
            mesh(.linkedFlat)
        }
        Menu("Select Loops") {
            Button("Edge Loops") { send(.loops(.selectEdgeLoops)) }
            Button("Edge Rings") { send(.loops(.selectEdgeRings)) }
            mesh(.boundaryLoops)
            Divider()
            mesh(.loopInnerRegion)
            mesh(.boundaryOfSelected)
        }
        Divider()
        mesh(.sharpEdges)
        // From the active vertex, the one tapped last.
        mesh(.sideOfActive)
        Divider()
        // Blender's poll says why when the mesh has no active boolean
        // attribute ("There must be an active attribute").
        mesh(.byAttribute)
    }

    private func mesh(_ item: SelectMenu.MeshItem) -> some View {
        Button(item.title) { send(.mesh(item)) }
    }

    // MARK: object mode

    @ViewBuilder private var objectRows: some View {
        object(.activeCamera)
        object(.mirror)
        object(.random)
        Divider()
        Menu("More/Less") {
            object(.more)
            object(.less)
            Divider()
            object(.parent)
            object(.child)
            Divider()
            object(.extendParent)
            object(.extendChild)
        }
        Divider()
        Menu("Select All by Type") {
            ForEach(SelectMenu.objectTypes, id: \.identifier) { type in
                Button(type.label) { send(.byType(type.identifier)) }
            }
        }
        // Blender's operator fails its poll without an interface, so this is
        // its exec, type for type (`_blenderkit_select.select_grouped`).
        Menu("Select Grouped") {
            ForEach(SelectMenu.groupedTypes, id: \.identifier) { type in
                Button(type.label) { send(.grouped(type.identifier)) }
            }
        }
        .disabled(!hasActive)
        Menu("Select Linked") {
            ForEach(SelectMenu.linkedTypes, id: \.identifier) { type in
                Button(type.label) { send(.linked(type.identifier)) }
            }
        }
        .disabled(!hasActive)
        Button("Select Pattern…") { askPattern() }
    }

    private func object(_ item: SelectMenu.ObjectItem) -> some View {
        Button(item.title) { send(.object(item)) }
            .disabled(item.needsActive && !hasActive)
    }
}

/// What a Circle or Lasso select drag has drawn so far: the circle's painted
/// stroke, with the circle itself at the finger, or the lasso's outline. Drawn
/// from the same `SelectionRegion` the selection is then made from, and its
/// shaded area is `shaded(_:)`, which the `-region-select` hook samples
/// against `SelectionRegion.contains` — so that what is shown being swept is
/// what is selected is measured on the shape drawn, not assumed.
struct SelectionStrokeOverlay: View {
    var region: SelectionRegion

    /// The area the overlay shades, and the rule it is filled by: the
    /// circle's stroke as the outline of a round-capped line `2 × radius`
    /// wide, the lasso even-odd (Blender's rule, and `contains`'), the box
    /// its rectangle.
    static func shaded(_ region: SelectionRegion) -> (path: Path, style: FillStyle)? {
        switch region {
        case .circle(let path, let radius):
            guard let last = path.last, radius > 0 else { return nil }
            // A drag that never moved a sample's width is one disc, drawn as
            // one rather than left to how a zero-length line is capped.
            guard path.count > 1 else {
                return (Path(ellipseIn: CGRect(x: last.x - radius, y: last.y - radius,
                                               width: 2 * radius, height: 2 * radius)), FillStyle())
            }
            var stroke = Path()
            stroke.addLines(path)
            return (stroke.strokedPath(StrokeStyle(lineWidth: 2 * radius, lineCap: .round, lineJoin: .round)),
                    FillStyle())
        case .lasso(let points):
            guard points.count > 1 else { return nil }
            var outline = Path()
            outline.addLines(points)
            outline.closeSubpath()
            return (outline, FillStyle(eoFill: true))
        case .box(let rect):
            return (Path(rect), FillStyle())
        }
    }

    var body: some View {
        Canvas { context, _ in
            guard let (area, style) = Self.shaded(region) else { return }
            switch region {
            case .circle(let path, let radius):
                context.fill(area, with: .color(BTheme.select.opacity(0.14)), style: style)
                if let last = path.last {
                    let ring = Path(ellipseIn: CGRect(x: last.x - radius, y: last.y - radius,
                                                      width: 2 * radius, height: 2 * radius))
                    context.stroke(ring, with: .color(BTheme.select), lineWidth: 1)
                }
            case .lasso:
                context.fill(area, with: .color(BTheme.select.opacity(0.10)), style: style)
                context.stroke(area, with: .color(BTheme.select),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .box:
                context.fill(area, with: .color(BTheme.select.opacity(0.14)), style: style)
                context.stroke(area, with: .color(BTheme.select), lineWidth: 1)
            }
        }
    }
}
