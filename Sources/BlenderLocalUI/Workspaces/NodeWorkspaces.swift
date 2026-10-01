import SwiftUI
import simd

/// A node in a linear chain, drawn Blender-style: coloured header, parameters
/// below, a noodle to the next node.
///
/// Both the compositor and the geometry node tree are chains here, so they
/// share this rather than each drawing their own.
private struct ChainNodeView: View {
    var title: String
    var headerHex: UInt32
    var parameters: [(name: String, range: ClosedRange<Float>, value: Float)]
    var removable: Bool
    var onChange: (String, Float) -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(BTheme.Font.ui(11, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                if removable {
                    Button(action: onRemove) {
                        Image(systemName: "xmark").font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                .hoverEffect(.highlight)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(hex: headerHex))

            VStack(alignment: .leading, spacing: 3) {
                if parameters.isEmpty {
                    Text("—").font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                } else {
                    ForEach(parameters, id: \.name) { p in
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: 0x9C9C9C)).frame(width: 6, height: 6)
                            BNumberField(p.name,
                                         value: Binding(get: { p.value },
                                                        set: { v in
                                                            onChange(p.name,
                                                                     max(p.range.lowerBound,
                                                                         min(v, p.range.upperBound)))
                                                        }),
                                         step: (p.range.upperBound - p.range.lowerBound) / 200)
                        }
                        .frame(height: 20)
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 176)
        .background(Color(hex: 0x303030))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(BTheme.outline, lineWidth: 1) }
    }
}

/// The noodles between nodes in a chain.
private struct ChainLinks: View {
    var count: Int
    var spacing: CGFloat
    var colour: Color

    var body: some View {
        Canvas { context, _ in
            guard count > 1 else { return }
            for i in 0..<(count - 1) {
                let a = CGPoint(x: 20 + CGFloat(i) * spacing + 176, y: 74)
                let b = CGPoint(x: 20 + CGFloat(i + 1) * spacing, y: 74)
                var path = Path()
                path.move(to: a)
                path.addCurve(to: b,
                              control1: CGPoint(x: a.x + 30, y: a.y),
                              control2: CGPoint(x: b.x - 30, y: b.y))
                context.stroke(path, with: .color(colour), lineWidth: 2)
            }
        }
    }
}

/// Blender's Compositing workspace: the composited image above, the node graph
/// below. Nodes run in order over the render result.
struct CompositingWorkspace: View {
    var scene: BKScene
    var session: BpySession
    @State private var composited: TextureImage?
    @State private var version = 0

    var body: some View {
        VStack(spacing: 0) {
            ImageEditor(title: "Viewer",
                        image: composited ?? scene.renderResult,
                        version: version &+ scene.renderVersion,
                        emptyMessage: "No render to composite\nMake one with More ▸ Render.",
                        headerContent: AnyView(
                            BButton("Composite", icon: "wand.and.rays") { runGraph() }
                                .disabled(scene.renderResult == nil)))
                .frame(maxHeight: .infinity)

            BEditorDivider(.horizontal)
            editor.frame(height: 260)
        }
        .onChange(of: scene.renderVersion) { _, _ in composited = nil }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "camera.filters").font(.system(size: 11))
                    .foregroundStyle(BTheme.textDim)
                Text("Compositor").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Menu("Add") {
                    ForEach(CompositorNodeKind.allCases.filter {
                        $0 != .renderLayers && $0 != .composite
                    }, id: \.self) { kind in
                        Button(kind.label) {
                            scene.compositor.insert(kind)
                            session.log("# compositor: added \(kind.label)")
                        }
                    }
                }
                .menuStyle(BlenderMenuStyle())
                Spacer()
                Text("runs in order, left to right")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ChainLinks(count: scene.compositor.nodes.count, spacing: 190,
                               colour: Color(hex: 0xC7C729))
                    ForEach(Array(scene.compositor.nodes.enumerated()), id: \.element.id) { i, node in
                        ChainNodeView(
                            title: node.kind.label,
                            headerHex: node.kind.headerHex,
                            parameters: node.kind.parameters.map {
                                ($0.name, $0.range, node.value($0.name))
                            },
                            removable: node.kind != .renderLayers && node.kind != .composite,
                            onChange: { name, v in
                                if let idx = scene.compositor.nodes.firstIndex(where: { $0.id == node.id }) {
                                    scene.compositor.nodes[idx].values[name] = v
                                }
                            },
                            onRemove: { scene.compositor.remove(node.id) })
                            .offset(x: 20 + CGFloat(i) * 190, y: 40)
                    }
                }
                .frame(width: CGFloat(scene.compositor.nodes.count) * 190 + 60, height: 220)
            }
            .background(Color(hex: 0x1D1D1D))
        }
    }

    private func runGraph() {
        guard let source = scene.renderResult else { return }
        composited = Compositor.evaluate(scene.compositor, on: source)
        version &+= 1
        session.log("# compositor evaluated over the render result")
    }
}

/// Blender's Geometry Nodes workspace: the viewport with the evaluated result,
/// the node tree below, and a spreadsheet of what came out.
struct GeometryNodesWorkspace: View {
    var scene: BKScene
    var session: BpySession
    @Binding var camera: ViewportCamera
    @State private var options = ViewportOptions()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MetalViewportView(scene: scene, camera: $camera,
                                  shading: .solid, options: options,
                                  onSelectionChange: { _ in })
                    .frame(maxWidth: .infinity)

                BEditorDivider(.vertical)
                spreadsheet.frame(width: 200)
            }
            BEditorDivider(.horizontal)
            editor.frame(height: 260)
        }
    }

    /// Blender's Spreadsheet editor, showing what the tree produced.
    private var spreadsheet: some View {
        VStack(spacing: 0) {
            BHeader(background: BTheme.headerOutliner) {
                Image(systemName: "tablecells").font(.system(size: 11))
                    .foregroundStyle(BTheme.textDim)
                Text("Spreadsheet").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Spacer()
            }
            if let obj = scene.active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        row("Domain", "Point")
                        row("Vertices", "\(obj.mesh.vertices.count)")
                        row("Triangles", "\(obj.mesh.indices.count / 3)")
                        row("Edges", "\(obj.mesh.edges.count / 2)")
                        row("UVs", obj.mesh.hasUVs
                            ? (obj.mesh.uvMapName.isEmpty ? "yes" : obj.mesh.uvMapName) : "none")
                        Divider().overlay(BTheme.outline).padding(.vertical, 4)
                        row("Nodes", "\(max(0, obj.geometryNodes.nodes.count - 2))")
                        row("Tree", obj.geometryNodes.enabled ? "enabled" : "off")
                    }
                    .padding(6)
                }
            } else {
                Spacer()
                Text("No active object").font(BTheme.Font.ui(11))
                    .foregroundStyle(BTheme.textDim).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(BTheme.outliner)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.text)
        }
        .frame(height: 20)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 11)).foregroundStyle(BTheme.textDim)
                Text("Geometry Nodes").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Menu("Add") {
                    ForEach(GeometryNodeKind.allCases.filter {
                        $0 != .groupInput && $0 != .groupOutput
                    }, id: \.self) { kind in
                        Button(kind.label) { insert(kind) }
                    }
                }
                .menuStyle(BlenderMenuStyle())
                .disabled(scene.active == nil)
                Spacer()
                Text("evaluated after the modifier stack")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }

            if let obj = scene.active {
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ChainLinks(count: obj.geometryNodes.nodes.count, spacing: 200,
                                   colour: Color(hex: 0x6ECC8E))
                        ForEach(Array(obj.geometryNodes.nodes.enumerated()),
                                id: \.element.id) { i, node in
                            ChainNodeView(
                                title: node.kind.label,
                                headerHex: node.kind.headerHex,
                                parameters: node.kind.parameters.map {
                                    ($0.name, $0.range, node.value($0.name))
                                },
                                removable: node.kind != .groupInput && node.kind != .groupOutput,
                                onChange: { name, v in update(obj) { tree in
                                    if let idx = tree.nodes.firstIndex(where: { $0.id == node.id }) {
                                        tree.nodes[idx].values[name] = v
                                    }
                                } },
                                onRemove: { update(obj) { $0.remove(node.id) } })
                                .offset(x: 20 + CGFloat(i) * 200, y: 40)
                        }
                    }
                    .frame(width: CGFloat(obj.geometryNodes.nodes.count) * 200 + 60, height: 220)
                }
                .background(Color(hex: 0x1D1D1D))
            } else {
                Color(hex: 0x1D1D1D)
            }
        }
    }

    private func insert(_ kind: GeometryNodeKind) {
        guard let obj = scene.active else { return }
        update(obj) { $0.insert(kind) }
        session.log("# geometry nodes: added \(kind.label)")
    }

    /// Reassigning the whole tree is what triggers the mesh rebuild.
    private func update(_ obj: BKObject, _ change: (inout GeometryNodeTree) -> Void) {
        var tree = obj.geometryNodes
        change(&tree)
        obj.geometryNodes = tree
    }
}
