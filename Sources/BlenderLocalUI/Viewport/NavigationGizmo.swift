import SwiftUI
import simd

/// Blender's navigation gizmo — the axis ball in the top-right of the 3D
/// viewport. Tapping a ball snaps to that axis view, which is what it is for.
///
/// Positive axes carry a filled ball with its letter; negative axes get a
/// hollow one. Balls nearer the camera draw on top, so the ball reads as a
/// sphere rather than a flat diagram.
struct NavigationGizmo: View {
    var camera: ViewportCamera
    var onPick: (ViewportCamera.Viewpoint) -> Void

    private static let radius: CGFloat = 34
    private static let ball: CGFloat = 9

    /// The six axis ends, with Blender's colours and the view each snaps to.
    private static let axes: [(dir: SIMD3<Float>, label: String,
                               colour: Color, positive: Bool,
                               viewpoint: ViewportCamera.Viewpoint)] = [
        (SIMD3( 1, 0, 0), "X", BTheme.axisX, true,  .right),
        (SIMD3(-1, 0, 0), "X", BTheme.axisX, false, .left),
        (SIMD3(0,  1, 0), "Y", BTheme.axisY, true,  .back),
        (SIMD3(0, -1, 0), "Y", BTheme.axisY, false, .front),
        (SIMD3(0, 0,  1), "Z", BTheme.axisZ, true,  .top),
        (SIMD3(0, 0, -1), "Z", BTheme.axisZ, false, .bottom),
    ]

    var body: some View {
        let projected = Self.axes.map { axis -> (point: CGPoint, depth: Float, index: Int) in
            let v = project(axis.dir)
            return (CGPoint(x: CGFloat(v.x) * Self.radius, y: CGFloat(-v.y) * Self.radius),
                    v.z, Self.axes.firstIndex { $0.label == axis.label && $0.positive == axis.positive } ?? 0)
        }
        // Painter's order: furthest first, so nearer balls overlap them.
        let order = projected.indices.sorted { projected[$0].depth < projected[$1].depth }

        ZStack {
            // Spokes from the centre to the positive ends only, as Blender draws.
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in order where Self.axes[i].positive {
                    var path = Path()
                    path.move(to: centre)
                    path.addLine(to: CGPoint(x: centre.x + projected[i].point.x,
                                             y: centre.y + projected[i].point.y))
                    context.stroke(path, with: .color(Self.axes[i].colour.opacity(0.9)),
                                   lineWidth: 2)
                }
            }

            ForEach(order, id: \.self) { i in
                let axis = Self.axes[i]
                Button {
                    onPick(axis.viewpoint)
                } label: {
                    Circle()
                        .fill(axis.positive ? axis.colour : BTheme.header)
                        .overlay {
                            Circle().strokeBorder(axis.colour, lineWidth: axis.positive ? 0 : 1.5)
                        }
                        .frame(width: Self.ball * 2, height: Self.ball * 2)
                        .overlay {
                            if axis.positive {
                                Text(axis.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.75))
                            }
                        }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .offset(x: projected[i].point.x, y: projected[i].point.y)
            }
        }
        .frame(width: Self.radius * 2 + Self.ball * 2,
               height: Self.radius * 2 + Self.ball * 2)
        .contentShape(Rectangle())
    }

    /// World direction into the camera's view space, so the ball turns as the
    /// view orbits.
    private func project(_ dir: SIMD3<Float>) -> SIMD3<Float> {
        let view = camera.viewMatrix
        let v = view * SIMD4(dir, 0)
        return SIMD3(v.x, v.y, v.z)
    }
}

/// Blender's viewport text, top-left: the view type and the active object's
/// path through the collection tree.
struct ViewportInfoText: View {
    var scene: BKScene
    var camera: ViewportCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(camera.isOrthographic ? "User Orthographic" : "User Perspective")
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.text.opacity(0.85))
            Text("(1) Collection" + (scene.active.map { " | \($0.name)" } ?? ""))
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.text.opacity(0.85))
        }
        .shadow(color: .black.opacity(0.6), radius: 1, y: 0.5)
    }
}

/// The zoom / pan / camera / projection buttons Blender stacks under the
/// navigation gizmo.
struct ViewportNavButtons: View {
    @Binding var camera: ViewportCamera

    var body: some View {
        VStack(spacing: 4) {
            navButton("plus.magnifyingglass", "Zoom In") { camera.dolly(factor: 0.8) }
            navButton("minus.magnifyingglass", "Zoom Out") { camera.dolly(factor: 1.25) }
            navButton(camera.isOrthographic ? "grid" : "perspective",
                      camera.isOrthographic ? "Orthographic" : "Perspective") {
                camera.isOrthographic.toggle()
            }
        }
    }

    @ViewBuilder
    private func navButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(BTheme.text.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(BTheme.widget.opacity(0.75))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
                .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}
