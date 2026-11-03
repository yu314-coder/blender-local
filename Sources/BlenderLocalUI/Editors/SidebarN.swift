import SwiftUI
import simd

/// The N-panel — the sidebar Blender toggles with the N key, overlaid on the
/// right edge of the viewport.
///
/// Blender splits it into vertical tabs down the outer edge: **Item** for the
/// active object, **Tool** for the active tool, **View** for the viewport.
///
/// It is on screen now (View ▸ Sidebar in the More menu, and N), over the 3D
/// View's right edge in the Layout tab. Until round 4 nothing instantiated it,
/// so Edit Mode had no way to type a position at all (round 3's review,
/// toolkit item 3). Its Item tab is Blender's Transform panel: in Object Mode
/// Location, Rotation, Scale (`ObjectTransformFields`) and Dimensions; in a
/// mesh's Edit Mode the selection's Median or one Vertex, Global or Local,
/// and the Vertex Data and Edge Data weights (`_blenderkit_item`, read back
/// from the edit mesh, each typed number one undo step).
struct SidebarN: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var camera: ViewportCamera
    var tool: ActiveTool = .select
    @State private var tab: Tab = .item
    /// The 3D cursor's fields while they are dragged; Blender's once written.
    @State private var cursorDraft: SIMD3<Float>?
    /// Blender's Global / Local pair under the Median. It is the 3D View's
    /// own flag (V3D_GLOBAL_STATS, not in the Python API), so it is kept here,
    /// per device. Local to begin with, as Blender's: the flag is off in every
    /// View3D of the factory startup file (release/datafiles/startup.blend,
    /// read through its SDNA: `flag` 0x0808, 0x0800, 0x080c — bit 13 clear).
    @AppStorage("bl_sidebar_item_local") private var itemLocal = true
    private var itemGlobal: Bool {
        get { !itemLocal }
        nonmutating set { itemLocal = !newValue }
    }
    /// What Blender's edit mesh holds for the Item tab, read back after every
    /// change to it or to the selection.
    @State private var editItem: EditItemState?
    /// The active object's Dimensions, as Blender reports them.
    @State private var dimensions: SIMD3<Float>?

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
        // Keyed in a view of its own: the frame redraws it, not the sidebar
        // (KeyedRefresh).
        .background(KeyedRefresh(key: { itemKey }, refresh: { refreshItem() }))
    }

    /// What the Item tab's numbers may change with: any command or undo (the
    /// revision), the mode, the active object, Global or Local, the
    /// viewport's edit selection, which reaches Blender before it is read
    /// (`captureWithSelection`) — and the frame, whose change is a `capture`
    /// (TimelineDriver.setFrame) that moves no revision, while an animated
    /// transform moves the Global Median and the Dimensions.
    private struct ItemKey: Equatable {
        var revision: Int
        var running: Bool
        var mode: InteractionMode
        var active: UUID?
        var global: Bool
        var edit: [Set<Int>]
        var history: [EditElement]
        var tab: Tab
        var frame: Int
        var subframe: Float
    }

    private var itemKey: ItemKey {
        let edit = scene.editSelection
        return ItemKey(revision: session.backendRevision, running: session.isRunning, mode: scene.mode,
                       active: scene.activeID, global: itemGlobal,
                       edit: [edit.vertices, edit.edges, edit.faces], history: edit.history, tab: tab,
                       // Only the Item tab's numbers move with the frame.
                       frame: tab == .item ? scene.frameCurrent : 0,
                       subframe: tab == .item ? scene.animation.subframe : 0)
    }

    private func refreshItem() {
        guard tab == .item, let bridge, session.usesRealBlender, !session.isRunning,
              let obj = scene.active else {
            editItem = nil; dimensions = nil
            return
        }
        editItem = scene.mode == .edit && obj.hasEditMode ? ItemActions.state(bridge, global: itemGlobal) : nil
        dimensions = scene.mode == .object ? ItemActions.dimensions(bridge, of: obj.name) : nil
        #if DEBUG
        // For `-transform-ops frame:<n>`: when the tab read Blender, and what.
        if ProcessInfo.processInfo.arguments.contains("-transform-ops") {
            print("[bk] sidebar Item read at frame \(scene.frameCurrent): dimensions "
                  + (dimensions.map { String(format: "(%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) } ?? "none")
                  + (editItem?.median.map { String(format: ", median (%.4f, %.4f, %.4f)", $0.x, $0.y, $0.z) } ?? ""))
            fflush(stdout)
        }
        #endif
    }

    /// Blender draws the tabs as rotated labels on the panel's outer edge.
    private var tabStrip: some View {
        VStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(BTheme.Font.ui(12, weight: tab == t ? .medium : .regular))
                        .foregroundStyle(tab == t ? BTheme.title : BTheme.textDim)
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                        // A finger's tab: 36 points across, 64 down.
                        .frame(width: 36, height: 64)
                        .background(tab == t ? BTheme.widget : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            Spacer()
        }
        .padding(.top, 6)
        .frame(width: 36)
        .background(BTheme.header)
    }

    // MARK: Item

    @ViewBuilder
    private var itemPanels: some View {
        if let obj = scene.active {
            BPanel("Transform") {
                if scene.mode == .edit && obj.hasEditMode {
                    editTransform(obj)
                } else if scene.mode == .edit {
                    // Blender's Control Point: / Median: for a curve or a
                    // lattice — not built here yet.
                    Text("Typed positions for a curve's or a lattice's points are not offered here: "
                         + "drag them with the gizmo, or set them from a script.")
                        .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // The same fields as Properties ▸ Object
                    // (`ObjectTransformFields`): Blender's own channels.
                    ObjectTransformFields(object: obj, scene: scene, bridge: bridge)
                    if scene.mode == .object { dimensionFields(obj) }
                }
            }
        } else {
            Text("No active object")
                .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                .padding(10)
        }
    }

    /// Blender's Dimensions: X, Y and Z, typed or dragged, each written as the
    /// N panel writes it (`_blenderkit_item.set_dimension`).
    @ViewBuilder
    private func dimensionFields(_ obj: BKObject) -> some View {
        if let bridge, let d = dimensions {
            heading("Dimensions:")
            ForEach(0..<3, id: \.self) { i in
                ItemNumberField(label: ["X:", "Y:", "Z:"][i], value: d[i], unit: .meters,
                                accent: [BTheme.axisX, BTheme.axisY, BTheme.axisZ][i]) { v in
                    ItemActions.dimension(bridge, of: obj.name, axis: i, to: max(v, 0))
                    refreshItem()
                }
            }
        }
    }

    /// Blender's Transform panel in a mesh's Edit Mode (`v3d_editvertex_buts`).
    @ViewBuilder
    private func editTransform(_ obj: BKObject) -> some View {
        if !session.usesRealBlender {
            Text("Typed positions in Edit Mode are Blender's: the simulator's stand-in has none.")
                .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        } else if let item = editItem, item.object == obj.name, let bridge {
            if item.vertices == 0 {
                Text("Nothing selected")
                    .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
                    .frame(height: BTheme.Metric.touchField)
            } else if let median = item.median {
                heading(item.medianTitle)
                ForEach(0..<3, id: \.self) { i in
                    ItemNumberField(label: ["X:", "Y:", "Z:"][i], value: median[i], unit: .meters,
                                    accent: [BTheme.axisX, BTheme.axisY, BTheme.axisZ][i]) { v in
                        ItemActions.median(bridge, axis: i, to: v, global: itemGlobal)
                        refreshItem()
                    }
                }
                globalLocal
                let rows = item.dataRows
                ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                    if index == 0, item.vertices > 0 { heading(item.vertexDataTitle) }
                    if entry.row == .bevelWeightEdge { heading(item.edgeDataTitle) }
                    ItemNumberField(label: entry.label, value: entry.value, unit: .none, step: 0.01) { v in
                        ItemActions.data(bridge, entry.row, label: entry.label, to: v)
                        refreshItem()
                    }
                }
            }
        } else {
            Text("Reading the selection from Blender")
                .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                .frame(height: BTheme.Metric.touchField)
        }
    }

    /// Blender's Global and Local toggle pair: which space the Median is in.
    private var globalLocal: some View {
        HStack(spacing: 1) {
            ForEach([true, false], id: \.self) { global in
                Button { itemGlobal = global } label: {
                    Text(global ? "Global" : "Local")
                        .font(BTheme.Font.ui(13))
                        .foregroundStyle(itemGlobal == global ? Color.white : BTheme.textDim)
                        .frame(maxWidth: .infinity).frame(height: BTheme.Metric.touchField)
                        .background(itemGlobal == global ? BTheme.select : BTheme.widget)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(itemGlobal == global ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        .padding(.vertical, 3)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: BTheme.Metric.touchField)
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
            .frame(height: BTheme.Metric.touchField)
            if !tool.isImplemented {
                Text(tool.requirement)
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
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
                readout("Type", scene.sculpt.brush.name)
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
        if (scene.mode == .vertexPaint || scene.mode == .weightPaint), let blender = scene.paintBlender {
            // Blender's own brush, read back from Blender; edited in the
            // paint header (PaintModeHeader), which writes through bridge.run.
            BPanel("Brush") {
                readout("Brush", blender.brush ?? "none")
                readout("Size", blender.size.map { "\($0) px" } ?? "-")
                readout("Strength", blender.strength.map { String(format: "%.3f", $0) } ?? "-")
                if scene.mode == .weightPaint {
                    readout("Weight", blender.weight.map { String(format: "%.3f", $0) } ?? "-")
                }
            }
        } else if (scene.mode == .vertexPaint || scene.mode == .weightPaint), !session.usesRealBlender {
            // The simulator's stand-in's Swift brush.
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
            readout("View Pivot", String(format: "%.2f, %.2f, %.2f",
                                    camera.target.x, camera.target.y, camera.target.z))
            BButton("Center Cursor and Frame All", icon: "dot.viewfinder") {
                bridge?.run(ToolsBpy.snap(.cursorToCenter),
                            undo: SnapAction.cursorToCenter.undoName)
                camera.frameAll(scene.objects)
            }
        }
    }

    // MARK: pieces

    private func readout(_ label: String, _ value: String,
                         accent: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let accent {
                Rectangle().fill(accent).frame(width: 2, height: 13)
            }
            Text(label).font(BTheme.Font.ui(13)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(13)).foregroundStyle(BTheme.text)
                .lineLimit(1)
        }
        .frame(height: BTheme.Metric.touchField)
    }
}

/// A number Blender holds, with a draft while a finger drags it: the drag
/// moves the draft, and the finger lifting — or Return after typing — sends
/// the one change. The mirroring pass that follows is what it shows next, so
/// a value Blender refused goes back to the one it holds.
struct ItemNumberField: View {
    let label: String
    let value: Float
    var unit: BNumberField.Unit = .meters
    var accent: Color? = nil
    var step: Float = 0.01
    let commit: (Float) -> Void
    @State private var draft: Float?

    init(label: String, value: Float, unit: BNumberField.Unit = .meters, accent: Color? = nil,
         step: Float = 0.01, commit: @escaping (Float) -> Void) {
        self.label = label; self.value = value; self.unit = unit; self.accent = accent
        self.step = step; self.commit = commit
    }

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? value }, set: { draft = $0 }),
                     step: step, accent: accent, unit: unit,
                     commit: { v in
                         draft = nil
                         commit(v)
                     })
    }
}

/// What the Item tab's fields send and read, shared with the DEBUG hook that
/// drives them (`-transform-ops`), so what is tested is what a field does.
enum ItemActions {
    static func state(_ bridge: BpyBridge, global: Bool) -> EditItemState? {
        bridge.captureWithSelection(ItemBpy.state(global: global)).flatMap(EditItemState.parse)
    }

    static func dimensions(_ bridge: BpyBridge, of name: String) -> SIMD3<Float>? {
        bridge.capture(ItemBpy.dimensions(of: name)).flatMap(ItemBpy.parseDimensions)
    }

    /// One typed Median or Vertex number: one undo step, on the selection the
    /// viewport shows (the bridge pushes it first, in the same evaluation).
    @discardableResult
    static func median(_ bridge: BpyBridge, axis: Int, to value: Float, global: Bool) -> BpyBridge.Outcome {
        bridge.run(ItemBpy.setMedian(axis: axis, to: value, global: global), undo: ItemBpy.undoName(axis: axis))
    }

    @discardableResult
    static func data(_ bridge: BpyBridge, _ row: ItemDataRow, label: String, to value: Float) -> BpyBridge.Outcome {
        bridge.run(ItemBpy.setData(row, to: value), undo: ItemBpy.undoName(label))
    }

    @discardableResult
    static func dimension(_ bridge: BpyBridge, of name: String, axis: Int, to value: Float) -> BpyBridge.Outcome {
        bridge.run(ItemBpy.setDimension(of: name, axis: axis, to: value), undo: ItemBpy.undoName(axis: axis))
    }
}
