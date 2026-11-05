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

    // A finger's balls: 24 points across (Blender draws them for a pointer,
    // at a third of that), on a ring that keeps them apart.
    private static let radius: CGFloat = 40
    private static let ball: CGFloat = 12

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
                                    .font(.system(size: 12, weight: .bold))
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

/// Blender's viewport text, top-left, as `draw_selected_name` and the view
/// name write it (view3d_draw.cc): the view type with " (Local)" in Local
/// View, then the frame, in Object Mode the active collection, and the
/// active object. It said "(1) Collection" whatever the frame and the
/// collections were.
struct ViewportInfoText: View {
    var scene: BKScene
    var camera: ViewportCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text((camera.isOrthographic ? "User Orthographic" : "User Perspective")
                 + (scene.localView != nil ? " (Local)" : ""))
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.text.opacity(0.85))
            Text(Self.selectedName(scene))
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.text.opacity(0.85))
        }
        .shadow(color: .black.opacity(0.6), radius: 1, y: 0.5)
    }

    static func selectedName(_ scene: BKScene) -> String {
        var text = "(\(scene.frameCurrent))"
        if scene.mode == .object {
            text += " " + (scene.collections?.active?.name ?? "Scene Collection")
            if scene.active != nil { text += " |" }
        }
        if let active = scene.active { text += " " + active.name }
        return text
    }
}

/// The buttons Blender stacks under the navigation gizmo — zoom, move, the
/// camera and the projection (the 3D View's navigation gizmos) — each a
/// finger's size, with Frame All under them. The magnifier and the hand are
/// dragged, as Blender's are: up and down on the magnifier zooms, the hand
/// moves the view with the finger. A tap on the magnifier zooms in a step, on
/// the camera looks through the scene's camera and back, on the grid switches
/// perspective and orthographic. They were drawn nowhere since the 3D View
/// was simplified (2eadf65); on a tablet they are the way to a view that a
/// keyboard's numpad is on a desktop (Blender's iPad design keeps them,
/// code.blender.org, "Beyond Mouse & Keyboard").
struct ViewportNavButtons: View {
    @Binding var camera: ViewportCamera
    var inCameraView: Bool
    var hasCamera: Bool
    var toggleCameraView: () -> Void
    var frameAll: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            DragNavButton(icon: "plus.magnifyingglass", label: "Zoom",
                          tap: { camera.dolly(factor: 0.8) },
                          drag: { d in camera.dolly(factor: Float(exp(Double(d.height) * 0.01))) })
            DragNavButton(icon: "hand.raised", label: "Move the View", tap: nil,
                          drag: { d in camera.pan(dx: Float(d.width), dy: Float(d.height)) })
            navButton(inCameraView ? "video.fill" : "video", "Toggle Camera View",
                      lit: inCameraView, enabled: hasCamera || inCameraView, action: toggleCameraView)
            navButton(camera.isOrthographic ? "square.grid.3x3" : "perspective",
                      camera.isOrthographic ? "Orthographic" : "Perspective",
                      lit: camera.isOrthographic) { camera.isOrthographic.toggle() }
            navButton("viewfinder", "Frame All", action: frameAll)
        }
    }

    private func navButton(_ icon: String, _ label: String, lit: Bool = false, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NavButtonFace(icon: icon, lit: lit)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// One of the navigation buttons' faces: a 40-point circle.
private struct NavButtonFace: View {
    var icon: String
    var lit = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(lit ? Color.white : BTheme.text.opacity(0.9))
            .frame(width: 40, height: 40)
            .background(lit ? BTheme.select : BTheme.header.opacity(0.85), in: Circle())
            .contentShape(Circle())
    }
}

/// A navigation button that is dragged, as Blender's zoom and move gizmos
/// are: each step of the drag goes to `drag` as it happens, and a touch that
/// did not move is a tap.
private struct DragNavButton: View {
    var icon: String
    var label: String
    var tap: (() -> Void)?
    var drag: (CGSize) -> Void
    @State private var last: CGSize?
    @State private var moved = false

    var body: some View {
        NavButtonFace(icon: icon, lit: last != nil && moved)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { g in
                        let previous = last ?? .zero
                        last = g.translation
                        if !moved, hypot(g.translation.width, g.translation.height) > 4 { moved = true }
                        guard moved else { return }
                        drag(CGSize(width: g.translation.width - previous.width,
                                    height: g.translation.height - previous.height))
                    }
                    .onEnded { _ in
                        if !moved { tap?() }
                        last = nil
                        moved = false
                    }
            )
            .hoverEffect(.highlight)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap?() }
    }
}
