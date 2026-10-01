import SwiftUI
import simd

/// The N-panel — the sidebar Blender toggles with the N key, overlaid on the
/// right edge of the viewport.
///
/// Blender splits it into vertical tabs down the outer edge: **Item** for the
/// active object, **Tool** for the active tool, **View** for the viewport. It
/// previously showed Item's contents with the View panels stacked underneath,
/// which is not where Blender keeps them.
///
/// Nothing instantiates it: `grep -rn "SidebarN" Sources/ tests/` finds only
/// this declaration. The panels that are on screen are the sheets LayoutWorkspace
/// opens — Transform Tools holds the 3D cursor and the precision settings.
struct SidebarN: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera
    var tool: ActiveTool = .select
    @State private var tab: Tab = .item
    /// The 3D cursor's fields while they are dragged; Blender's once written.
    @State private var cursorDraft: SIMD3<Float>?

    enum Tab: String, CaseIterable, Identifiable {
        case item = "Item"
        case tool = "Tool"
        case view = "View"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                BHeader {
                    Text(tab.rawValue)
                        .font(BTheme.Font.ui(12, weight: .medium))
                        .foregroundStyle(BTheme.text)
                    Spacer()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case .item: itemPanels
                        case .tool: toolPanels
                        case .view: viewPanels
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity)

            tabStrip
        }
        .frame(width: BTheme.Metric.sidebarWidth)
        .background(BTheme.header.opacity(0.94))
    }

    /// Blender draws the tabs as rotated labels on the panel's outer edge.
    private var tabStrip: some View {
        VStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(BTheme.Font.ui(10, weight: tab == t ? .medium : .regular))
                        .foregroundStyle(tab == t ? BTheme.title : BTheme.textDim)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                        .frame(width: 22, height: 48)
                        .background(tab == t ? BTheme.widget : Color.clear)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            Spacer()
        }
        .padding(.top, 6)
        .frame(width: 22)
        .background(BTheme.header)
    }

    // MARK: Item

    @ViewBuilder
    private var itemPanels: some View {
        if let obj = scene.active {
            // The same fields as Properties ▸ Object (`ObjectTransformFields`):
            // these showed `matrix_world` and wrote the local channels, one
            // Python run per drag sample with no undo step.
            BPanel("Transform") {
                ObjectTransformFields(object: obj, scene: scene, bridge: bridge)
            }

            // Blender shows the world-space size of the object, which is the
            // one transform figure you cannot type — it follows from the rest.
            BPanel("Dimensions") {
                let d = dimensions(of: obj)
                ForEach(0..<3, id: \.self) { i in
                    readout(["X", "Y", "Z"][i], d.map { String(format: "%.3f m", $0[i]) } ?? "hidden",
                            accent: [BTheme.axisX, BTheme.axisY, BTheme.axisZ][i])
                }
            }

            BPanel("Relations") {
                readout("Name", obj.name)
                readout("Type", obj.kind.rawValue.capitalized)
                // Blender's statistics leave out what is not drawn, and a
                // hidden object's mesh is the one it was last drawn with.
                readout("Vertices", obj.visible ? "\(obj.mesh.vertices.count)" : "hidden")
                readout("Triangles", obj.visible ? "\(obj.mesh.indices.count / 3)" : "hidden")
            }
        } else {
            Text("No active object")
                .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                .padding(10)
        }
    }

    // MARK: Tool

    @ViewBuilder
    private var toolPanels: some View {
        BPanel("Active Tool") {
            HStack(spacing: 6) {
                Image(systemName: tool.icon).font(.system(size: 13))
                    .foregroundStyle(BTheme.title)
                Text(tool.label).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Spacer()
            }
            .frame(height: 22)
            if !tool.isImplemented {
                Text(tool.requirement)
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            readout("Mode", scene.mode.label)
        }

        if scene.mode == .sculpt, let blender = scene.sculptBlender {
            // Blender's own brush, read back from Blender; edited in the
            // sculpt header (SculptHeader), which writes through bridge.run.
            BPanel("Brush") {
                readout("Brush", blender.brush ?? "none")
                readout("Size", blender.size.map { "\($0) px" } ?? "-")
                readout("Strength", blender.strength.map { String(format: "%.3f", $0) } ?? "-")
                readout("Direction", scene.sculpt.invert ? "Invert (Ctrl)" : "Normal")
            }
        } else if scene.mode == .sculpt {
            // The simulator's approximation of Blender's brushes.
            BPanel("Brush") {
                readout("Type", scene.sculpt.brush.label)
                BNumberField("Radius", value: Binding(
                    get: { scene.sculpt.radius },
                    set: { scene.sculpt.radius = max(0.05, min($0, 4)) }), step: 0.01)
                BNumberField("Strength", value: Binding(
                    get: { scene.sculpt.strength },
                    set: { scene.sculpt.strength = max(0.01, min($0, 1)) }), step: 0.01)
                readout("Direction", scene.sculpt.invert ? "Subtract" : "Add")
            }
        }

        // Texture Paint's brush is in its tool row (TexturePaintHeader); these
        // settings are vertex and weight paint's, and do nothing to it.
        if scene.mode == .vertexPaint || scene.mode == .weightPaint {
            BPanel("Brush") {
                BNumberField("Radius", value: Binding(
                    get: { scene.paint.radius },
                    set: { scene.paint.radius = max(0.005, min($0, 0.5)) }), step: 0.005)
                BNumberField("Strength", value: Binding(
                    get: { scene.paint.strength },
                    set: { scene.paint.strength = max(0.01, min($0, 1)) }), step: 0.01)
                if scene.mode == .weightPaint {
                    BNumberField("Weight", value: Binding(
                        get: { scene.paint.weight },
                        set: { scene.paint.weight = max(0, min($0, 1)) }), step: 0.01)
                } else {
                    readout("Blend", scene.paint.blend.label)
                }
                readout("Falloff", scene.paint.falloff.label)
            }
        }

        if scene.mode != .object, let obj = scene.active {
            BPanel("Symmetry") {
                readout("Mirror", obj.symmetry.isOn ? obj.symmetry.label : "None")
            }
        }
    }

    // MARK: View

    @ViewBuilder
    private var viewPanels: some View {
        BPanel("3D Cursor") {
            // Through bpy, not into the cache: `scene.cursor` is mirrored from
            // `bpy.context.scene.cursor.location` after every command, so a
            // field that wrote it directly would be overwritten by the next
            // pass — which is what these three used to do.
            // Once, when the drag ends: `bridge.run` per drag sample cost a
            // full mirroring pass and an Info line each.
            ForEach(0..<3, id: \.self) { i in
                BNumberField(["Location X", "Location Y", "Location Z"][i],
                             value: Binding(get: { (cursorDraft ?? scene.cursor)[i] },
                                            set: { value in
                                                var next = cursorDraft ?? scene.cursor
                                                next[i] = value
                                                cursorDraft = next
                                            }),
                             step: 0.01,
                             accent: [BTheme.axisX, BTheme.axisY, BTheme.axisZ][i],
                             commit: { _ in
                                 bridge?.run(ToolsBpy.setCursor(cursorDraft ?? scene.cursor))
                                 cursorDraft = nil
                             })
            }
            BButton("Cursor to World Origin", icon: "scope") {
                bridge?.run(ToolsBpy.snap(.cursorToCenter),
                            undo: SnapAction.cursorToCenter.undoName)
            }
        }

        BPanel("View") {
            readout("Focal Length", String(format: "%.0f mm", 18 / tan(camera.fovY / 2)))
            BNumberField("Distance", value: Binding(get: { camera.distance },
                                                    set: { camera.distance = max(0.4, $0) }),
                         step: 0.05)
            readout("Clip Start", String(format: "%.3f m", camera.near))
            readout("End", String(format: "%.0f m", camera.far))
            readout("Projection", camera.isOrthographic ? "Orthographic" : "Perspective")
            BButton("Frame All", icon: "viewfinder") {
                camera.frameAll(scene.objects)
                session.log("bpy.ops.view3d.view_all()")
            }
        }

        BPanel("View Lock") {
            readout("Pivot", String(format: "%.2f, %.2f, %.2f",
                                    camera.target.x, camera.target.y, camera.target.z))
            BButton("Centre Cursor and Frame All", icon: "dot.viewfinder") {
                bridge?.run(ToolsBpy.snap(.cursorToCenter),
                            undo: SnapAction.cursorToCenter.undoName)
                camera.frameAll(scene.objects)
            }
        }
    }

    // MARK: pieces

    /// The object's world-space bounding size — Blender's Dimensions row.
    ///
    /// Nil for an object that is not drawn and never has been since it
    /// reached the mirror: the sync sends such an object as its origin alone,
    /// and measured from that one vertex a hidden cube read 0.000 m on every
    /// axis while Blender held 2 m. Once drawn, an object keeps its mesh
    /// through being hidden (`SceneMirror.merge`), so its size stays right.
    private func dimensions(of obj: BKObject) -> SIMD3<Float>? {
        if !obj.visible, obj.mesh.vertices.count <= 1, obj.mesh.indices.isEmpty {
            return nil
        }
        guard !obj.mesh.vertices.isEmpty else { return .zero }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let m = obj.modelMatrix
        for v in obj.mesh.vertices {
            let w = (m * SIMD4(v.position, 1)).xyz
            lo = min(lo, w); hi = max(hi, w)
        }
        return hi - lo
    }

    private func readout(_ label: String, _ value: String,
                         accent: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let accent {
                Rectangle().fill(accent).frame(width: 2, height: 13)
            }
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.text)
                .lineLimit(1)
        }
        .frame(height: 20)
    }
}
