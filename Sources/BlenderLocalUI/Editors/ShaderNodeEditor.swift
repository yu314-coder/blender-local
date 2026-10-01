import SwiftUI

/// Blender's Shader Editor, showing the active material's node graph.
///
/// Blender evaluates an arbitrary graph; this shows the graph a new material
/// starts with — a Principled BSDF wired into a Material Output — and edits the
/// BSDF's inputs, which is what the viewport shades with. Adding arbitrary
/// nodes would need a graph evaluator, so the Add menu says so rather than
/// dropping in nodes that do nothing.
struct ShaderNodeEditor: View {
    var scene: BKScene
    var session: BpySession
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var panning = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let obj = scene.active {
                canvas(for: obj)
            } else {
                VStack {
                    Spacer()
                    Text("No active object").font(BTheme.Font.ui(12))
                        .foregroundStyle(BTheme.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(hex: 0x1D1D1D))
    }

    private var header: some View {
        BHeader {
            Image(systemName: "circle.hexagonpath")
                .font(.system(size: 11)).foregroundStyle(BTheme.textDim)
            Text("Shader Editor").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
            Menu("Add") {
                BUnavailable("Texture")
                BUnavailable("Color")
                BUnavailable("Vector")
                BUnavailable("Converter")
                Divider()
                Text("Adding nodes needs a graph evaluator").disabled(true)
            }
            .menuStyle(BlenderMenuStyle())
            Spacer()
            if let obj = scene.active {
                Text(obj.material.name)
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
        }
    }

    private func canvas(for obj: BKObject) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Blender's node editor has a dotted backdrop.
                Canvas { context, size in
                    let spacing: CGFloat = 24
                    for x in stride(from: 0, through: size.width, by: spacing) {
                        for y in stride(from: 0, through: size.height, by: spacing) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                                         with: .color(.white.opacity(0.05)))
                        }
                    }
                }

                // The link, drawn behind the nodes as Blender draws it.
                if obj.shaderGraph.isConnected,
                   let bsdf = obj.shaderGraph.principled,
                   let out = obj.shaderGraph.output {
                    Path { p in
                        let a = CGPoint(x: CGFloat(bsdf.x) + 180 + pan.width,
                                        y: CGFloat(bsdf.y) + 34 + pan.height)
                        let b = CGPoint(x: CGFloat(out.x) + pan.width,
                                        y: CGFloat(out.y) + 34 + pan.height)
                        p.move(to: a)
                        // Blender's noodles are horizontal-tangent beziers.
                        p.addCurve(to: b,
                                   control1: CGPoint(x: a.x + 60, y: a.y),
                                   control2: CGPoint(x: b.x - 60, y: b.y))
                    }
                    .stroke(Color(hex: 0x9CCC65), lineWidth: 2)
                }

                ForEach(obj.shaderGraph.nodes) { node in
                    nodeBody(node, obj: obj)
                        .offset(x: CGFloat(node.x) + pan.width,
                                y: CGFloat(node.y) + pan.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .draggableControl(panning, corner: 0)
            .gesture(
                DragGesture()
                    .onChanged { g in
                        panning = true
                        pan = CGSize(width: panStart.width + g.translation.width,
                                     height: panStart.height + g.translation.height)
                    }
                    .onEnded { _ in panStart = pan; panning = false }
            )
        }
    }

    @ViewBuilder
    private func nodeBody(_ node: ShaderNode, obj: BKObject) -> some View {
        VStack(spacing: 0) {
            Text(node.kind.label)
                .font(BTheme.Font.ui(11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: node.kind.headerHex))

            VStack(alignment: .leading, spacing: 3) {
                ForEach(node.kind.outputs, id: \.self) { socket in
                    HStack {
                        Spacer()
                        Text(socket).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.text)
                        Circle().fill(Color(hex: 0x9CCC65)).frame(width: 7, height: 7)
                    }
                }
                if node.kind == .principledBSDF {
                    principledInputs(obj)
                } else {
                    ForEach(node.kind.inputs, id: \.self) { socket in
                        HStack {
                            Circle().fill(Color(hex: 0x9CCC65)).frame(width: 7, height: 7)
                            Text(socket).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                            Spacer()
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 180)
        .background(Color(hex: 0x303030))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(BTheme.outline, lineWidth: 1)
        }
    }

    /// The Principled BSDF's editable inputs — what the viewport shades with.
    @ViewBuilder
    private func principledInputs(_ obj: BKObject) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: 0xC7C729)).frame(width: 7, height: 7)
            Text("Base Color").font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            Spacer()
            ColorPicker("", selection: Binding(
                get: {
                    Color(.sRGB, red: Double(obj.material.baseColor.x),
                          green: Double(obj.material.baseColor.y),
                          blue: Double(obj.material.baseColor.z))
                },
                set: { newValue in
                    let c = UIColor(newValue).cgColor.components ?? [0.8, 0.8, 0.8, 1]
                    obj.material.baseColor = SIMD4(Float(c[0]),
                                                   Float(c.count > 2 ? c[1] : c[0]),
                                                   Float(c.count > 2 ? c[2] : c[0]), 1)
                    obj.color = obj.material.baseColor
                }), supportsOpacity: false)
                .labelsHidden().frame(width: 30)
        }
        .frame(height: 20)

        socketSlider("Metallic", value: Binding(
            get: { obj.material.metallic },
            set: { obj.material.metallic = max(0, min($0, 1)) }))
        socketSlider("Roughness", value: Binding(
            get: { obj.material.roughness },
            set: { obj.material.roughness = max(0, min($0, 1)) }))
        socketSlider("IOR", value: Binding(
            get: { obj.material.ior },
            set: { obj.material.ior = max(1, min($0, 3)) }), step: 0.01)
        socketSlider("Emission", value: Binding(
            get: { obj.material.emissionStrength },
            set: { obj.material.emissionStrength = max(0, min($0, 10)) }), step: 0.02)
    }

    @ViewBuilder
    private func socketSlider(_ label: String, value: Binding<Float>,
                              step: Float = 0.01) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: 0x9C9C9C)).frame(width: 7, height: 7)
            BNumberField(label, value: value, step: step)
        }
        .frame(height: 20)
    }
}
