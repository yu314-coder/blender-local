import SwiftUI

/// Blender's tool-settings row — the strip under the 3D viewport header,
/// toggled from View ▸ Tool Settings.
///
/// Blender builds it in two halves, and so does this:
///
/// * `draw_tool_settings` on the left — the active tool and its own options.
///   In the brush modes that means the brush, its size and strength, and the
///   popovers that hold the rest.
/// * `draw_mode_settings` on the right — options belonging to the *mode*
///   rather than the tool: the falloff and the mode's Options popover. Mesh
///   symmetry, which Blender also draws there, is LayoutWorkspace's mirror
///   row now, through `bridge.run` (SymmetryBpy).
///
/// Object mode has no tool settings of its own in Blender beyond the tool
/// itself, which is why its left half is the selection modes and nothing more.
///
/// Nothing instantiates this: `grep -rn "ToolHeader" Sources/ tests/` finds
/// only this declaration. Its Snap and Proportional toggles, which changed a
/// local copy and ran nothing, were removed rather than fixed — the controls
/// that are on screen are LayoutWorkspace's Pivot, Snap and Proportional
/// menus and its More ▸ Transform Tools sheet (TransformToolsPanel), and they
/// go through `bridge.run`. SidebarN has them too, but nothing instantiates
/// that either. Auto Merge went the same way: its toggle wrote a local copy
/// and logged a line, so the preview welded while Blender, which never heard
/// of it, did not. It is in TransformToolsPanel now, as Blender's setting.
/// Its X / Y / Z toggles went too, for the same reason: they set
/// `BKObject.symmetry` here and logged `use_mesh_mirror_x`, a property
/// Blender does not have, and sent nothing — while the mirror never read the
/// mesh's real flags, so no drag mirrored either way.
struct ToolHeader: View {
    var tool: ActiveTool
    var scene: BKScene
    var session: BpySession
    @Binding var selectMode: SelectAction
    @Binding var options: ViewportOptions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                toolSettings

                Spacer(minLength: 20)

                modeSettings
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 700, alignment: .leading)
        }
        .frame(height: 28)
        .background(BTheme.header.opacity(0.85))
        .overlay(alignment: .bottom) {
            Rectangle().fill(BTheme.editorOutline).frame(height: BTheme.Metric.hairline)
        }
    }

    // MARK: - left half: the active tool

    @ViewBuilder
    private var toolSettings: some View {
        switch scene.mode {
        case .object:
            objectToolSettings
        case .edit:
            meshSelectModes
            Divider().frame(height: 14).overlay(BTheme.outline)
            objectToolSettings
        case .sculpt:
            sculptSettings
        case .vertexPaint:
            colourBrushSettings(weightMode: false)
        case .weightPaint:
            weightBrushSettings
        case .texturePaint:
            TexturePaintHeader(scene: scene, tool: tool)
        }
    }

    @ViewBuilder
    private var objectToolSettings: some View {
        if tool.transformRole != nil {
            transformSettings
        } else if tool == .select || tool == .boxSelect
                    || tool == .circleSelect || tool == .lassoSelect {
            selectModes
        } else {
            Text(tool.label)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.textDim)
        }
    }

    // MARK: - right half: the mode

    @ViewBuilder
    private var modeSettings: some View {
        HStack(spacing: 4) {
            // Texture Paint's falloff is its brush's, in TexturePaintHeader.
            if scene.mode == .sculpt || scene.mode == .vertexPaint || scene.mode == .weightPaint {
                falloffMenu
            }
            optionsMenu
        }
    }

    /// Blender keeps the brush falloff curve in its own popover; this is the
    /// part of it that has behaviour behind it.
    private var falloffMenu: some View {
        Menu {
            Section("Falloff") {
                ForEach(BrushFalloff.allCases) { f in
                    Button {
                        scene.paint.falloff = f
                        session.log("bpy.context.tool_settings.unified_paint_settings"
                                    + ".curve_preset = '\(f.rawValue.uppercased())'")
                    } label: {
                        Label(f.label, systemImage: scene.paint.falloff == f ? "checkmark" : "")
                    }
                }
            }
            Divider()
            BUnavailable("Stroke Spacing")
            BUnavailable("Brush Texture")
            BUnavailable("Brush Display")
        } label: {
            headerChip("Falloff", value: scene.paint.falloff.label)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Gizmos", isOn: $options.showGizmos)
            Toggle("Show Overlays", isOn: $options.showOverlays)
            Toggle("X-Ray", isOn: $options.xray)
            Divider()
            BUnavailable("Transform Affect Only Origins")
            BUnavailable("Transform Affect Only Locations")
            BUnavailable("Transform Affect Only Parents")
        } label: {
            HStack(spacing: 4) {
                Text("Options").font(BTheme.Font.ui(11))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(BTheme.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
    }

    // MARK: - brush rows

    /// Blender's sculpt header: brush, size, strength, then the Add/Subtract
    /// direction pair — which is `brush.direction`, not a checkbox.
    private var sculptSettings: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(SculptBrush.allCases) { b in
                    Button {
                        // The simulator's Swift brushes: nothing is sent to
                        // Blender, so nothing is logged as if it were. Blender's
                        // own brushes are SculptHeader's.
                        scene.sculpt.brush = b
                    } label: {
                        Label(b.label, systemImage: scene.sculpt.brush == b ? "checkmark" : b.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: scene.sculpt.brush.icon).font(.system(size: 11))
                    Text(scene.sculpt.brush.label).font(BTheme.Font.ui(11))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }

            BNumberField("Radius", value: Binding(
                get: { scene.sculpt.radius },
                set: { scene.sculpt.radius = max(0.05, min($0, 4)) }), step: 0.01, unit: .meters)
                .frame(width: 112)
            BNumberField("Strength", value: Binding(
                get: { scene.sculpt.strength },
                set: { scene.sculpt.strength = max(0.01, min($0, 1)) }), step: 0.01)
                .frame(width: 112)

            // Blender draws Direction as two exclusive buttons.
            HStack(spacing: 1) {
                ForEach([false, true], id: \.self) { invert in
                    Button {
                        // Held like Blender's Ctrl (brush_stroke mode INVERT),
                        // not written into the brush, so nothing is logged.
                        scene.sculpt.invert = invert
                    } label: {
                        Text(invert ? "Subtract" : "Add")
                            .font(BTheme.Font.ui(11))
                            .foregroundStyle(scene.sculpt.invert == invert ? .white : BTheme.textDim)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(scene.sculpt.invert == invert
                                        ? Color(hex: 0x4772B3) : BTheme.widget)
                    }
                    .buttonStyle(.plain)
                .hoverEffect(.highlight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
    }

    /// Vertex Paint and Texture Paint: a colour swatch, a blend mode, then size
    /// and strength — Blender's `brush_basic__draw_color_selector` row.
    private func colourBrushSettings(weightMode: Bool) -> some View {
        HStack(spacing: 5) {
            ColorPicker("", selection: Binding(
                get: {
                    let c = scene.paint.colour
                    return Color(.sRGB, red: Double(c.x), green: Double(c.y),
                                 blue: Double(c.z), opacity: 1)
                },
                set: { new in
                    let r = UIColor(new).cgColor.components ?? [1, 1, 1, 1]
                    scene.paint.colour = SIMD4(Float(r[0]), Float(r.count > 2 ? r[1] : r[0]),
                                               Float(r.count > 2 ? r[2] : r[0]), 1)
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30, height: 22)

            Menu {
                ForEach(BrushBlend.allCases) { b in
                    Button {
                        scene.paint.blend = b
                        session.log("bpy.context.tool_settings.vertex_paint.brush.blend "
                                    + "= '\(b.bpyValue)'")
                    } label: {
                        Label(b.label, systemImage: scene.paint.blend == b ? "checkmark" : "")
                    }
                }
            } label: {
                headerChip("Blend", value: scene.paint.blend.label)
            }

            BNumberField("Radius", value: Binding(
                get: { scene.paint.radius },
                set: { scene.paint.radius = max(0.005, min($0, 0.5)) }), step: 0.005)
                .frame(width: 112)
            BNumberField("Strength", value: Binding(
                get: { scene.paint.strength },
                set: { scene.paint.strength = max(0.01, min($0, 1)) }), step: 0.01)
                .frame(width: 112)
        }
    }

    /// Weight Paint: Blender shows Weight, then Size and Strength — and no
    /// colour, because the weight *is* the colour.
    private var weightBrushSettings: some View {
        HStack(spacing: 5) {
            BNumberField("Weight", value: Binding(
                get: { scene.paint.weight },
                set: { scene.paint.weight = max(0, min($0, 1)) }), step: 0.01)
                .frame(width: 112)
            BNumberField("Radius", value: Binding(
                get: { scene.paint.radius },
                set: { scene.paint.radius = max(0.005, min($0, 0.5)) }), step: 0.005)
                .frame(width: 112)
            BNumberField("Strength", value: Binding(
                get: { scene.paint.strength },
                set: { scene.paint.strength = max(0.01, min($0, 1)) }), step: 0.01)
                .frame(width: 112)

            // The ramp, so the number means something without painting first.
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { i in
                    let c = WeightRamp.colour(Float(i) / 23)
                    Rectangle()
                        .fill(Color(.sRGB, red: Double(c.x), green: Double(c.y),
                                    blue: Double(c.z), opacity: 1))
                        .frame(width: 3, height: 14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(alignment: .leading) {
                // A tick at the current weight.
                Rectangle().fill(Color.white).frame(width: 2, height: 18)
                    .offset(x: CGFloat(scene.paint.weight) * 70)
            }
        }
    }

    // MARK: - shared pieces

    /// Blender's vertex / edge / face buttons, bound to 1, 2 and 3.
    private var meshSelectModes: some View {
        HStack(spacing: 1) {
            ForEach(MeshSelectMode.allCases) { mode in
                Button {
                    scene.selectMode = mode
                    session.log("bpy.ops.mesh.select_mode(type='\(mode.rawValue.uppercased())')")
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(scene.selectMode == mode ? .white : BTheme.textDim)
                        .frame(width: 26, height: 22)
                        .background(scene.selectMode == mode ? Color(hex: 0x4772B3) : BTheme.widget)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help("\(mode.label)  (\(mode.shortcut))")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    /// The five mode buttons Blender groups together, drawn as one segmented
    /// block with the active one highlighted.
    private var selectModes: some View {
        HStack(spacing: 1) {
            ForEach(SelectAction.allCases) { mode in
                Button {
                    selectMode = mode
                    session.log("# select mode: \(mode.bpyValue)")
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(selectMode == mode ? .white : BTheme.textDim)
                        .frame(width: 26, height: 22)
                        .background(selectMode == mode ? Color(hex: 0x4772B3) : BTheme.widget)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(mode.label)
                .help(mode.label)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private var transformSettings: some View {
        HStack(spacing: 4) {
            Text(tool.label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
            Divider().frame(height: 14).overlay(BTheme.outline)
            Menu {
                ForEach(ViewportOptions.TransformOrientation.allCases) { o in
                    Button {
                        if o.isImplemented { options.orientation = o }
                    } label: {
                        Label(o.label, systemImage: options.orientation == o ? "checkmark" : "")
                    }
                    .disabled(!o.isImplemented)
                }
            } label: {
                headerChip("Orientation", value: options.orientation.label)
            }
        }
    }

    private func headerChip(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            Text(value).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
            Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(BTheme.textDim)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(BTheme.widget)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }
}
