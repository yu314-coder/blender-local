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
        if editing { editRows } else { objectRows }
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
            // Both walk Blender's selection history, which a selection handed
            // over from the viewport does not carry: measured, Next Active
            // changed nothing.
            BUnavailable("Next Active")
            BUnavailable("Previous Active")
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
        // Needs the active vertex, which is Blender's selection history
        // again: measured, it returns CANCELLED.
        BUnavailable("Side of Active")
        Divider()
        // Needs an active boolean attribute ("There must be an active
        // attribute"), and nothing here sets one.
        BUnavailable("By Attribute")
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
        // Fails its poll without a window, even inside the 3D View override
        // the app's other view operators use (measured in 5.2.1).
        BUnavailable("Select Grouped")
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
