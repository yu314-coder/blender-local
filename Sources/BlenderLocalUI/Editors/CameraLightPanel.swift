import SwiftUI
import simd

/// What Blender's Properties ▸ Object Data holds for a camera or a light, for
/// the objects that have no mesh to show there.
///
/// Before this the only way to change a light's power or a camera's lens in
/// the app was the RNA browser or a line of Python. The values shown are the
/// ones mirrored from Blender (`ObjectDisplay`), and every edit is one Python
/// assignment on the data-block, so it undoes as one step and the viewport's
/// overlays follow it.
struct CameraLightPanel: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var object: BKObject
    /// The 3D View, so a camera can be aimed at it. The Properties editor has
    /// no viewport of its own, and leaves it out.
    var camera: Binding<ViewportCamera>?
    /// Looking through the camera is the 3D View's own action — it draws the
    /// frame guide too — so the button calls back rather than moving the view
    /// itself.
    var lookThrough: (() -> Void)?

    var body: some View {
        switch object.overlayDisplay {
        case .camera(let display): cameraPanels(display)
        case .light(let display):  lightPanels(display)
        default: EmptyView()
        }
    }

    // MARK: cameras

    @ViewBuilder private func cameraPanels(_ display: CameraDisplay) -> some View {
        BPanel("Lens") {
            picker("Type", choices: [("PERSP", "Perspective"), ("ORTHO", "Orthographic")],
                   selected: display.projection.rawValue) { set("type", choice: $0) }
            if display.projection == .orthographic {
                number("Orthographic Scale", display.orthoScale, step: 0.05, unit: .meters) {
                    set("ortho_scale", max($0, 0.001))
                }
            } else {
                number("Focal Length", display.lens, step: 0.5) { set("lens", min(max($0, 1), 5000)) }
                Text("\(Int(display.verticalAngle * 180 / .pi))° tall at \(Int(display.aspectX)) × \(Int(display.aspectY))")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }
        }
        BPanel("Clipping") {
            number("Start", display.clipStart, step: 0.01, unit: .meters) { set("clip_start", max($0, 1e-4)) }
            number("End", display.clipEnd, step: 1, unit: .meters) { set("clip_end", max($0, 0.001)) }
        }
        BPanel("Scene Camera") {
            if display.isSceneCamera {
                Text("Renders go through this camera.")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            } else {
                BButton("Make This the Scene Camera", icon: "video") {
                    _ = bridge?.run(Bpy.setSceneCamera(object.name), undo: "Set Scene Camera")
                }
            }
            if let camera {
                BButton("Aim at This View", icon: "camera.metering.center.weighted") {
                    _ = bridge?.run(Bpy.alignCameraToView(object.name, camera.wrappedValue.renderCamera),
                                    undo: "Aim Camera at View")
                }
            }
            if let lookThrough {
                BButton("Look Through It", icon: "eye") { lookThrough() }
            }
        }
    }

    // MARK: lights

    @ViewBuilder private func lightPanels(_ display: LightDisplay) -> some View {
        BPanel("Light") {
            picker("Type", choices: LightDisplay.Kind.allCases.map { ($0.rawValue, $0.label) },
                   selected: display.kind.rawValue) { set("type", choice: $0) }
            HStack {
                Text("Colour").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { Color(.sRGB, red: Double(display.color.x), green: Double(display.color.y),
                                 blue: Double(display.color.z)) },
                    set: { new in
                        let c = UIColor(new).cgColor.components ?? [1, 1, 1, 1]
                        set("color", colour: SIMD3(Float(c[0]), Float(c.count > 2 ? c[1] : c[0]),
                                                   Float(c.count > 2 ? c[2] : c[0])))
                    }), supportsOpacity: false)
                    .labelsHidden().frame(width: 40)
            }
            .frame(height: 24)
            // A sun's strength is irradiance, not wattage, and its numbers are
            // small — Blender labels and steps them differently.
            if display.kind == .sun {
                number("Strength", display.energy, step: 0.05) { set("energy", max($0, 0)) }
                Text("W/m², the sun's power at the surface")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            } else {
                number("Power", display.energy, step: 5) { set("energy", max($0, 0)) }
                Text("Watts")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }
            if display.kind != .sun {
                number("Radius", display.radius, step: 0.01, unit: .meters) {
                    set("shadow_soft_size", max($0, 0))
                }
                Text("Bigger is softer shadows")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }
        }
        if display.kind == .spot {
            BPanel("Spot Shape") {
                number("Cone Size", display.spotSize, step: 0.02, unit: .degrees) {
                    set("spot_size", min(max($0, 0.0175), .pi))
                }
                number("Blend", display.spotBlend, step: 0.01) { set("spot_blend", min(max($0, 0), 1)) }
            }
        }
        if display.kind == .area {
            BPanel("Area Shape") {
                picker("Shape", choices: LightDisplay.Shape.allCases.map { ($0.rawValue, $0.label) },
                       selected: display.shape.rawValue) { set("shape", choice: $0) }
                number("Size", display.size, step: 0.02, unit: .meters) { set("size", max($0, 0.001)) }
                if display.shape == .rectangle || display.shape == .ellipse {
                    number("Size Y", display.sizeY, step: 0.02, unit: .meters) { set("size_y", max($0, 0.001)) }
                }
            }
        }
    }

    // MARK: the pieces

    private func number(_ label: String, _ value: Float, step: Float,
                        unit: BNumberField.Unit = .none,
                        set: @escaping (Float) -> Void) -> some View {
        DataNumberField(label: label, value: value, step: step, unit: unit, write: set)
    }

    @ViewBuilder
    private func picker(_ label: String, choices: [(String, String)], selected: String,
                        set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Menu {
                ForEach(choices, id: \.0) { value, title in
                    Button {
                        set(value)
                    } label: {
                        Label(title, systemImage: value == selected ? "checkmark" : "")
                    }
                }
            } label: {
                Text(choices.first { $0.0 == selected }?.1 ?? selected)
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }
        }
        .frame(height: 24)
    }

    private func set(_ key: String, _ value: Float) {
        _ = bridge?.run(Bpy.setObjectData(object.name, key, value), undo: label(key))
    }

    private func set(_ key: String, choice: String) {
        _ = bridge?.run(Bpy.setObjectData(object.name, key, choice: choice), undo: label(key))
    }

    private func set(_ key: String, colour: SIMD3<Float>) {
        _ = bridge?.run(Bpy.setObjectData(object.name, key, colour: colour), undo: label(key))
    }

    /// What the undo step is called: Blender names it after the property.
    private func label(_ key: String) -> String {
        "Change " + key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// A number field for a value that lives in Blender.
///
/// The drag is shown from a local draft and written once when it ends: a write
/// per sample would be a Python call and an undo step per sample, and the
/// value read back lags a frame behind the finger, which made a drag jump.
private struct DataNumberField: View {
    var label: String
    var value: Float
    var step: Float
    var unit: BNumberField.Unit
    var write: (Float) -> Void

    @State private var draft: Float?

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? value }, set: { draft = $0 }),
                     step: step, unit: unit) { final in
            draft = nil
            write(final)
        }
    }
}
