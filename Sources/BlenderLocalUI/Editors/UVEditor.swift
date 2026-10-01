import SwiftUI
import simd

/// Blender's UV Editor: the active object's UV map laid out in the 0–1 square.
///
/// On the real backend what is drawn is Blender's own map, per face corner, as
/// the mirror carries it (`SceneMirror.installUVs`) — and for an object whose
/// modifiers change it, the map before them, which is the one Blender's UV
/// Editor draws (`BKObject.uvLayout`); in the simulator it is the stand-in's
/// projection. Blender draws the layout over an image; there is no
/// image system here, so the backdrop is the checker Blender shows before one
/// is loaded.
struct UVEditor: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let obj = scene.active, Self.map(of: obj).hasUVs {
                layout(for: obj)
            } else {
                empty
            }
        }
        .background(Color(hex: 0x1D1D1D))
    }

    private var header: some View {
        BHeader {
            Image(systemName: "grid").font(.system(size: 11)).foregroundStyle(BTheme.textDim)
            Text("UV Editor").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)

            Menu("UV") {
                ForEach(UVOperator.allCases) { op in
                    Button(op.label) { run(op) }
                    if op.endsGroup { Divider() }
                }
            }
            .menuStyle(BlenderMenuStyle())
            .disabled(scene.active == nil)

            // Blender's operators act on the selected faces, and only in Edit
            // Mode; from object mode `_blenderkit_uv` works on the whole mesh
            // of every mesh Edit Mode would open. Which a row will do is not
            // visible anywhere else.
            Text(scope).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)

            Spacer()
            if let obj = scene.active, Self.map(of: obj).hasUVs {
                let map = Self.map(of: obj)
                if !map.uvMapName.isEmpty {
                    Text(map.uvMapName).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                }
                let stretch = UVUnwrap.averageStretch(map)
                Text(String(format: "stretch %.0f%%", stretch * 100))
                    .font(BTheme.Font.mono(10))
                    .foregroundStyle(stretch > 0.5 ? Color(hex: 0xE5486A) : BTheme.textDim)
            }
        }
    }

    private var scope: String {
        if scene.mode == .edit { return "selected faces" }
        // Edit Mode opens the active mesh and every selected one with it —
        // meshes only: a curve, text or metaball has triangles on screen too,
        // and `_blenderkit_uv._edited` leaves them out (round 2's review).
        // Two objects sharing one mesh still count twice; the mirror does not
        // say which mesh an object uses.
        let meshes = scene.objects.filter {
            ($0.id == scene.activeID || scene.selection.contains($0.id)) && $0.blenderType == "MESH"
                && !$0.mesh.indices.isEmpty
        }.count
        return meshes > 1 ? "\(meshes) whole meshes" : "whole mesh"
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(emptyMessage).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
            if let obj = scene.active, !obj.mesh.indices.isEmpty {
                Text("UV ▸ Unwrap").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        guard let obj = scene.active else { return "No active object" }
        if obj.mesh.indices.isEmpty { return "\(obj.name) has no faces to unwrap" }
        return "No UV map on this mesh"
    }

    private func layout(for obj: BKObject) -> some View {
        GeometryReader { geo in
            // Blender keeps the UV square square, whatever the editor's shape.
            let side = min(geo.size.width, geo.size.height) - 32
            let originX = (geo.size.width - side) / 2
            let originY = (geo.size.height - side) / 2

            Canvas { context, _ in
                let square = CGRect(x: originX, y: originY, width: side, height: side)

                // Checker backdrop, as Blender shows with no image loaded.
                let cells = 8
                let cell = side / CGFloat(cells)
                for row in 0..<cells {
                    for col in 0..<cells where (row + col) % 2 == 0 {
                        context.fill(Path(CGRect(x: square.minX + CGFloat(col) * cell,
                                                 y: square.minY + CGFloat(row) * cell,
                                                 width: cell, height: cell)),
                                     with: .color(.white.opacity(0.035)))
                    }
                }
                context.stroke(Path(square), with: .color(.white.opacity(0.25)), lineWidth: 1)

                let paths = UVEditor.paths(for: Self.map(of: obj), in: square)
                // A faint fill over the area the map covers, as Blender tints
                // faces in its UV Editor.
                context.fill(paths.faces, with: .color(Color(hex: 0x4772B3).opacity(0.12)))
                context.stroke(paths.edges, with: .color(Color(hex: 0x4772B3).opacity(0.85)),
                               lineWidth: 0.8)
                // Blender's theme colour for a seam (Edge Seam, #DB2512).
                context.stroke(paths.seams, with: .color(Color(hex: 0xDB2512)), lineWidth: 1.6)
            }
        }
    }

    /// The mesh whose map is drawn: the one before the modifiers when the
    /// mirror sent it, the drawn mesh otherwise.
    static func map(of obj: BKObject) -> MeshData { obj.uvLayout ?? obj.mesh }

    /// The map as Blender's UV Editor draws it: polygon outlines, seams apart
    /// (`MeshData.uvEditorLines`). V is flipped because UV space has its
    /// origin at the bottom-left and the canvas at the top-left.
    static func paths(for mesh: MeshData, in square: CGRect) -> (faces: Path, edges: Path, seams: Path) {
        func point(_ corner: Int) -> CGPoint {
            let uv = mesh.cornerUV(corner)
            return CGPoint(x: square.minX + CGFloat(uv.x) * square.width,
                           y: square.minY + CGFloat(1 - uv.y) * square.height)
        }
        var faces = Path()
        var t = 0
        while 3 * t + 2 < mesh.indices.count {
            let p = [point(3 * t), point(3 * t + 1), point(3 * t + 2)]
            // Every triangle wound the same way: under the non-zero rule a
            // flipped island overlapping an unflipped one would otherwise
            // cancel it out and draw as a hole.
            let turn = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x)
            faces.move(to: p[0])
            faces.addLine(to: turn >= 0 ? p[1] : p[2])
            faces.addLine(to: turn >= 0 ? p[2] : p[1])
            faces.closeSubpath()
            t += 1
        }
        let lines = mesh.uvEditorLines()
        var edges = Path(), seams = Path()
        for (a, b) in lines.edges { edges.move(to: point(a)); edges.addLine(to: point(b)) }
        for (a, b) in lines.seams { seams.move(to: point(a)); seams.addLine(to: point(b)) }
        return (faces, edges, seams)
    }

    private func run(_ op: UVOperator) {
        bridge?.run(Bpy.uv(op), undo: op.label)
    }
}
