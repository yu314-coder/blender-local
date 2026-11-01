import SwiftUI
import simd

/// The Measure tool's rulers and Edit Mode's measurement labels, drawn over
/// the 3D View in screen space, following the view as it moves.
///
/// The rulers are drawn as `gizmo_ruler_draw` draws them while the Measure
/// tool is in hand (view3d_gizmo_ruler.cc): the active one white and the rest
/// black, ticks across the ends, an angle ruler's two arms and its arc, the
/// value in Blender's mono font with a backing box. Blender stops drawing its
/// gizmos when the tool is left (its rulers then live on as annotation
/// strokes); these stay in the scene for when the tool is picked again.
///
/// The labels are `DRW_text_edit_mesh_measure_stats`'s, in the theme's
/// colours, at the points Blender computes (EditMeasurements.labels). They are
/// left out while a transform drag is previewing: they are Blender's numbers
/// for the mesh as it is, which the drag has not changed yet.
struct MeasureOverlay: View {
    var scene: BKScene
    var camera: ViewportCamera
    var showsRulers: Bool
    var overlays: MeasureOverlays
    /// A mesh is being edited in Blender, which the labels are about.
    var editingMesh: Bool

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            // A camera drag's camera, while one is under way (`ViewportCameraFeed`).
            let view = (ViewportCameraFeed.shared.live ?? camera).snapView(size)
            if editingMesh, overlays.measures, scene.transformReadout == nil, let measured = scene.editMeasurements {
                let vp = view.viewProjection
                for label in measured.labels(units: scene.units, viewProjection: vp, overlays: overlays) {
                    // Blender draws a label only where its anchor projects
                    // inside the region (`DRW_text_cache_draw`:
                    // V3D_PROJ_TEST_CLIP_WIN | CLIP_NEAR), which is also all
                    // the read culls to (`_blenderkit_measure`).
                    guard let p = view.project(label.at), p.x >= 0, p.y >= 0,
                          CGFloat(p.x) <= size.width, CGFloat(p.y) <= size.height else { continue }
                    let c = EditMeasurements.colour(label.kind)
                    context.draw(Text(label.text).font(.system(size: 11))
                                    .foregroundColor(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))),
                                 at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y - label.raise)), anchor: .bottomLeading)
                }
            }
            if showsRulers {
                for (index, ruler) in scene.rulers.enumerated() {
                    draw(ruler, active: index == scene.activeRuler, view: view, in: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ ruler: Ruler, active: Bool, view: GeometrySnap.View, in context: inout GraphicsContext) {
        let s = ruler.points.map { view.project($0) }
        let colour: Color = active ? .white : .black
        func pt(_ v: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)) }
        let text = ruler.text(units: scene.units)
        if ruler.usesAngle {
            guard let a = s[0], let b = s[1], let c = s[2] else { return }
            var arms = Path()
            arms.move(to: pt(a)); arms.addLine(to: pt(b)); arms.addLine(to: pt(c))
            context.stroke(arms, with: .color(colour), lineWidth: 1)
            context.stroke(arms, with: .color(Color(white: 0.67)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // The arc between the arms at the angle point, 64 points out.
            let d0 = simd_normalize(a - b), d1 = simd_normalize(c - b)
            if d0.x.isFinite, d1.x.isFinite {
                let start = atan2(Double(d0.y), Double(d0.x)), end = atan2(Double(d1.y), Double(d1.x))
                var sweep = end - start
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                var arc = Path()
                arc.addArc(center: pt(b), radius: 64, startAngle: .radians(start), endAngle: .radians(start + sweep),
                           clockwise: sweep < 0)
                context.stroke(arc, with: .color(colour.opacity(0.8)), lineWidth: 1)
            }
            label(text, at: pt(b), in: &context)
        } else {
            guard let a = s[0], let c = s[2] else { return }
            var line = Path()
            line.move(to: pt(a)); line.addLine(to: pt(c))
            context.stroke(line, with: .color(colour), lineWidth: 1)
            context.stroke(line, with: .color(Color(white: 0.67)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // The caps: 4 points either side, across the line.
            let dir = c - a
            if simd_length(dir) > 0 {
                let across = simd_normalize(SIMD2(-dir.y, dir.x)) * 4
                var caps = Path()
                for e in [a, c] { caps.move(to: pt(e + across)); caps.addLine(to: pt(e - across)) }
                context.stroke(caps, with: .color(colour), lineWidth: 1)
            }
            label(text, at: pt((a + c) / 2), in: &context)
        }
    }

    private func label(_ text: String, at p: CGPoint, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.system(size: 14, design: .monospaced)).foregroundColor(.white))
        let size = resolved.measure(in: CGSize(width: 1000, height: 100))
        let box = CGRect(x: p.x - size.width / 2 - 4, y: p.y - size.height / 2 - 4,
                         width: size.width + 8, height: size.height + 8)
        context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(.black.opacity(0.5)))
        context.draw(resolved, at: p, anchor: .center)
    }
}

/// The Statistics overlay's rows, top left (`ED_info_draw_stats`), from
/// Blender's counts.
struct StatisticsOverlay: View {
    var statistics: EditMeasurements.Statistics

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 1) {
            ForEach(Array(statistics.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                    Text(row.value)
                }
            }
        }
        .font(BTheme.Font.ui(11))
        .foregroundStyle(BTheme.text.opacity(0.9))
        .shadow(color: .black.opacity(0.6), radius: 1, y: 0.5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MeasureOverlays.statisticsLabel + ": "
                            + statistics.rows.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
    }
}
