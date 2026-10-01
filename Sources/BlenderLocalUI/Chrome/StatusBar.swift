import SwiftUI

/// Blender's status bar: the keymap hints on the left, scene statistics and
/// version on the right. Here the hints describe the touch gestures, since
/// there is no mouse to describe.
struct StatusBar: View {
    static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    var scene: BKScene
    var workspace: Workspace
    /// Only for whether a script is running and for how long — Blender puts a
    /// progress cursor up for the same reason.
    var session: BpySession

    var body: some View {
        HStack(spacing: 14) {
            if workspace == .layout || workspace == .modeling || workspace == .sculpting {
                hint("hand.draw", "Orbit")
                switch scene.mode {
                case .edit:
                    hint("hand.point.up.left", "Tap: Select \(scene.selectMode.label)")
                case .sculpt, .vertexPaint, .weightPaint, .texturePaint:
                    hint("paintbrush.pointed", "Drag: Brush")
                case .object:
                    hint("hand.point.up.left", "Tap: Select")
                }
                hint("arrow.up.left.and.down.right.magnifyingglass", "Pinch: Zoom")
                hint("hand.pinch", "Two fingers: Pan")
            } else if session.isRunning {
                // Blender puts a progress cursor up while a script runs. The
                // equivalent here is saying so, with the clock moving, because
                // an interface that is busy and an interface that has crashed
                // look identical until something on it changes.
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(String(format: "Running… %.1fs", session.runElapsed))
                        .font(BTheme.Font.mono(10))
                        .foregroundStyle(BTheme.active)
                }
            } else {
                hint("terminal", "Run Script to execute")
            }

            Spacer()

            Text(statistics)
                .font(BTheme.Font.mono(10))
                .foregroundStyle(BTheme.textDim)
            // The build number, not just the version. Working out whether a
            // report is against the build that contains a fix has cost more
            // than one round trip; the answer belongs on screen.
            Text("Blender Local \(Self.versionString)")
                .font(BTheme.Font.ui(10))
                .foregroundStyle(BTheme.textDim)
        }
        .padding(.horizontal, 10)
        .frame(height: BTheme.Metric.statusHeight)
        .background(BTheme.statusbar)
    }

    /// Blender changes what it counts with the mode: object mode reports the
    /// whole scene, edit mode reports selected-over-total for each component of
    /// the mesh being edited. Reporting scene totals while you are editing one
    /// mesh tells you nothing about the edit.
    private var statistics: String {
        if scene.mode == .edit, let obj = scene.active, obj.editsPoints {
            // Selected over total, as Blender's `stats_object_edit` counts
            // them: a curve's every knot and handle as points, a lattice's
            // points as vertices. The words are the 3D View's Statistics
            // overlay's ("Points" for a curve). Blender's status bar prints
            // "Verts" for a curve but its vertex counts, which a curve leaves
            // at nought: measured in 5.2.1, "BézierCurve | Verts:0/0" in Edit
            // Mode. A curve with every point deleted has no cage and counts
            // 0/0 here too — it is not a mesh to count.
            let cage = scene.editedPoints?.cage
            let label = obj.blenderType == "LATTICE" ? "Verts" : "Points"
            return label + " \(cage?.selected.count ?? 0)/\(cage?.count ?? 0)"
        }
        if scene.mode == .edit, let obj = scene.active {
            let sel = scene.editSelection
            // Hidden vertices are counted: Blender's edit-mode totals are the
            // BMesh's (`stats_object_edit`), and a 5 × 5 grid with one vertex
            // hidden read "Verts:24/25" (5.2.1, measured on a fresh view
            // layer, whose statistics are not cached).
            // The cage's, as the selection numbers it. In the simulator that
            // is the base under the Swift stack. On a device it is the mesh
            // the mirror drew, which is Blender's edit mesh only while no
            // modifier is shown in Edit Mode: with one it is the modifier's
            // output (round 3's review: 98 vertices for an edit mesh of 26),
            // and Faces counts triangles where Blender counts polygons. Those
            // two are values Blender's status bar does not show.
            let cage = obj.editCage
            let verts = cage.vertices.count
            let edges = cage.edges.count / 2
            let faces = cage.indices.count / 3
            return "Verts \(sel.vertices.count)/\(verts)"
                 + "  |  Edges \(sel.edges.count)/\(edges)"
                 + "  |  Faces \(sel.faces.count)/\(faces)"
        }
        // What is drawn, as Blender's scene statistics count it. A hidden
        // object keeps the mesh it was last drawn with, or is its origin alone.
        let drawn = scene.objects.filter(\.visible)
        let verts = drawn.reduce(0) { $0 + $1.mesh.vertices.count }
        let tris  = drawn.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        return "Objects \(scene.selection.count)/\(scene.objects.count)  |  Verts \(verts)  |  Tris \(tris)"
    }

    @ViewBuilder
    private func hint(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(BTheme.textDim)
            Text(label).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
        }
    }
}
