import SwiftUI
import simd

/// Blender's Properties editor, showing the Object tab for the active object.
/// The transform fields write to Blender through the bridge, as one undo step
/// per drag, and the Python that did it is what lands in the Info log.
struct PropertiesView: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @State private var tab: PropertiesTab = PropertiesView.initialTab

    /// Debug builds accept `-properties-tab modifiers` (any tab's raw value),
    /// so a tab behind `-panel "Object Details"` can be photographed without
    /// a tap.
    private static var initialTab: PropertiesTab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-properties-tab"), i + 1 < args.count,
           let tab = PropertiesTab(rawValue: args[i + 1]) {
            return tab
        }
        #endif
        return .object
    }

    var body: some View {
        HStack(spacing: 0) {
            PropertiesTabColumn(selection: $tab, hasActiveObject: scene.active != nil)
            BEditorDivider(.vertical)
            content
        }
        .background(BTheme.properties)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: tab.icon)
                    .font(.system(size: 11)).foregroundStyle(tab.accent)
                Text(scene.active?.name ?? "Properties")
                    .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Text(tab.label)
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                Spacer()
            }

            switch tab {
            case .object, .modifiers, .data, .material: objectTabs
            case .scene:                                sceneTab
            default:                                    EmptyView()
            }
        }
    }

    @ViewBuilder
    private var sceneTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BPanel("Statistics") {
                    labelled("Objects", "\(scene.objects.count)")
                    labelled("Selected", "\(scene.selection.count)")
                    // What is drawn, as Blender's statistics and the status
                    // bar count it: a hidden object keeps the mesh it was last
                    // drawn with (SceneMirror.merge), and it is not counted.
                    labelled("Vertices", "\(scene.objects.filter(\.visible).reduce(0) { $0 + $1.mesh.vertices.count })")
                    labelled("Triangles", "\(scene.objects.filter(\.visible).reduce(0) { $0 + $1.mesh.indices.count / 3 })")
                }
                BPanel("Units") {
                    labelled("Unit System", "Metric")
                    labelled("Unit Scale", "1.000")
                    labelled("Length", "Meters")
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var objectTabs: some View {
            if let obj = scene.active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if tab == .object {
                        // These write to Blender when the finger lifts.
                        //
                        // They used to set the display cache and only *log* the
                        // Python they would have run, so an object typed to
                        // (0, 0, 3) moved on screen while Blender still had it
                        // at the origin: the next mirroring pass put it back,
                        // and every operator in between acted on the old place.
                        // One write per drag sample would be a Python round trip
                        // per sample, which is what `commit` exists to avoid.
                        // What they show and write is `ObjectTransformFields`'.
                        BPanel("Transform") {
                            ObjectTransformFields(object: obj, scene: scene, bridge: bridge)
                        }

                        BPanel("Relations") {
                            labelled("Collection", "Collection")
                            // Blender's `parent`, as the mirror read it after
                            // the last command — the Outliner's tree reads the
                            // same value. It said "None" whatever Object ▸
                            // Parent had done.
                            labelled("Parent", obj.parentName ?? "None")
                            // Blender's Object ▸ Visibility ▸ Show In
                            // Viewports: `hide_viewport`, and only that. It
                            // used to show whether the object was drawn at all,
                            // so an object hidden with H read as off here and
                            // turning it on wrote a flag that was already off.
                            HStack {
                                Text("Show in Viewports")
                                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                                Spacer()
                                Toggle("", isOn: Binding(get: { !obj.disabledInViewports },
                                                         set: { bridge?.run(
                                                             Bpy.setDisabledInViewports(obj.name, !$0),
                                                             undo: "Show in Viewports") }))
                                    .labelsHidden()
                                    .scaleEffect(0.7)
                            }
                            .frame(height: 22)
                            if obj.hiddenInViewLayer {
                                Text("Hidden in the view layer — Show Hidden Objects (Alt+H) or the Outliner's eye brings it back")
                                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // Blender's other Object-tab panels are not here.
                        // Delta Transform, Instancing, Motion Paths, Line Art
                        // and Custom Properties each held one line explaining
                        // what they could not do, and Collections and
                        // Visibility repeated what Relations already shows —
                        // the same visibility toggle, bound to the same value.
                        // Seven panels to scroll past to reach two that work.
                        }

                        if tab == .modifiers {
                        BPanel("Modifiers") {
                            Menu {
                                // Blender refuses six of these on a curve,
                                // text or surface (`ModifierKind.meshOnly`).
                                ForEach(ModifierKind.addable(on: obj.blenderType), id: \.self) { kind in
                                    Button {
                                        bridge?.run(Bpy.addModifier(kind, on: obj.mesh),
                                                    undo: "Add Modifier")
                                    } label: {
                                        Label(kind.label, systemImage: kind.icon)
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 11))
                                    Text("Add Modifier").font(BTheme.Font.ui(12))
                                    Spacer()
                                }
                                .foregroundStyle(BTheme.text)
                                .padding(.horizontal, 9)
                                .frame(height: BTheme.Metric.rowHeight)
                                .frame(maxWidth: .infinity)
                                .background(BTheme.widget)
                                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                            }

                            // Every modifier Blender has on the object, in its
                            // order: the mirror sends them all, and a kind with
                            // no settings rows here still gets the controls
                            // every modifier has.
                            ForEach(obj.modifiers) { modifier in
                                modifierRow(obj: obj, modifier: modifier)
                            }
                            if obj.modifiers.isEmpty {
                                Text("No modifiers")
                                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        }

                        if tab == .material {
                        // This used to set object.color and log the Python
                        // rather than run it, so the colour reached neither
                        // Blender nor a render. object.color is a viewport
                        // display property in the first place: Cycles ignores
                        // it unless a material reads it through an Object Info
                        // node, which is why a scene coloured here still
                        // rendered entirely grey. These three write the
                        // Principled BSDF the object actually shades with.
                        BPanel("Surface") {
                            HStack {
                                Text("Base Color")
                                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: {
                                        Color(.sRGB, red: Double(obj.material.baseColor.x),
                                              green: Double(obj.material.baseColor.y),
                                              blue: Double(obj.material.baseColor.z))
                                    },
                                    set: { newValue in
                                        let c = UIColor(newValue).cgColor.components ?? [0.8, 0.8, 0.8, 1]
                                        let rgb = SIMD4(Float(c[0]),
                                                        Float(c.count > 2 ? c[1] : c[0]),
                                                        Float(c.count > 2 ? c[2] : c[0]), 1)
                                        obj.material.baseColor = rgb
                                        // Solid shading draws object.color, so
                                        // keep the two agreeing; writeMaterial
                                        // sets it on Blender's side too.
                                        obj.color = rgb
                                        writeMaterial(obj)
                                    }), supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 40)
                            }
                            .frame(height: 24)
                            Spacer().frame(height: 6)
                            BNumberField("Metallic",
                                         value: Binding(get: { obj.material.metallic },
                                                        set: { obj.material.metallic = min(max($0, 0), 1) }),
                                         step: 0.01,
                                         commit: { _ in writeMaterial(obj) })
                            Spacer().frame(height: 4)
                            BNumberField("Roughness",
                                         value: Binding(get: { obj.material.roughness },
                                                        set: { obj.material.roughness = min(max($0, 0), 1) }),
                                         step: 0.01,
                                         commit: { _ in writeMaterial(obj) })
                            Text("Principled BSDF — what Solid, Material Preview and a render all read")
                                .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        }

                        if tab == .data, obj.overlayDisplay != nil {
                        CameraLightPanel(scene: scene, session: session, bridge: bridge,
                                         object: obj, camera: nil)
                        }

                        if tab == .data, let settings = obj.dataSettings {
                        curveOrLatticePanels(obj, settings)
                        }

                        if tab == .data, obj.overlayDisplay == nil, obj.dataSettings == nil {
                        BPanel("Mesh") {
                            labelled("Name", obj.name)
                            labelled("Source", obj.kind.displayName)
                            if !obj.visible {
                                // A hidden object keeps the mesh it was last
                                // drawn with (`SceneMirror.merge`), but the
                                // pass sends it no geometry while hidden, so a
                                // change made meanwhile — an Array's count
                                // raised, measured in 5.2.1 — never reaches
                                // it: a count here could be one Blender no
                                // longer holds.
                                Text("Hidden: its mesh reaches the app when it is shown")
                                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let undrawn = obj.undrawnVertexCount {
                                // Past the mirror's limit, the viewport shows
                                // the object's bounding box; these are Blender's.
                                labelled("Vertices", "\(undrawn), drawn as its bounds")
                            } else {
                                labelled("Vertices", "\(obj.mesh.vertices.count)")
                                labelled("Triangles", "\(obj.mesh.indices.count / 3)")
                                labelled("Edges", "\(obj.mesh.edges.count / 2)")
                            }
                        }
                        if obj.visible {
                        BPanel("Dimensions") {
                            let d = dimensions(of: obj)
                            labelled("X", String(format: "%.3f m", d.x))
                            labelled("Y", String(format: "%.3f m", d.y))
                            labelled("Z", String(format: "%.3f m", d.z))
                        }
                        }
                        // Blender's Vertex Groups and Shape Keys panels, read
                        // from the mirror and written through the bridge.
                        if obj.hasEditMode {
                            MeshGroupsPanels(scene: scene, session: session, bridge: bridge, object: obj)
                        }
                        }
                    }
                    .padding(.bottom, 12)
                }
            } else {
                VStack {
                    Spacer()
                    Text("No active object")
                        .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
    }

    // MARK: curve and lattice data

    /// Blender's Curve and Lattice data panels: the settings the mirror read
    /// back (`_blenderkit_points.record`), each control sending one change
    /// through the bridge and showing what comes back — nothing is written
    /// here first.
    @ViewBuilder
    private func curveOrLatticePanels(_ obj: BKObject, _ settings: ObjectDataSettings) -> some View {
        switch settings {
        case .curve(let curve):
            BPanel("Shape") {
                HStack(spacing: 3) {
                    Text("Dimensions").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Spacer()
                    ForEach(["2D", "3D"], id: \.self) { d in
                        axisToggle(d, on: curve.dimensions == d) {
                            if curve.dimensions != d { setData(obj, "dimensions", "'\(d)'", undo: "Dimensions") }
                        }
                    }
                }
                .frame(height: 22)
                stepper("Resolution Preview U", value: curve.resolutionU, range: 1...64) { v in
                    setData(obj, "resolution_u", "\(v)", undo: "Resolution Preview U")
                }
                labelled("Splines", "\(curve.splines), \(curve.points) points")
            }
            BPanel("Geometry") {
                number("Offset", curve.offset, step: 0.01, unit: .meters) { v in
                    setData(obj, "offset", Self.python(v), undo: "Offset")
                }
                number("Extrude", curve.extrude, step: 0.01, unit: .meters, clamp: { max($0, 0) }) { v in
                    setData(obj, "extrude", Self.python(v), undo: "Extrude")
                }
            }
            BPanel("Bevel") {
                number("Depth", curve.bevelDepth, step: 0.005, unit: .meters, clamp: { max($0, 0) }) { v in
                    setData(obj, "bevel_depth", Self.python(v), undo: "Depth")
                }
                stepper("Resolution", value: curve.bevelResolution, range: 0...32) { v in
                    setData(obj, "bevel_resolution", "\(v)", undo: "Resolution")
                }
                Menu {
                    ForEach(curve.fillModes, id: \.identifier) { mode in
                        Button(mode.label) { setData(obj, "fill_mode", "'\(mode.identifier)'", undo: "Fill Mode") }
                    }
                } label: {
                    fieldLabel("Fill Mode", curve.fillModes.first { $0.identifier == curve.fillMode }?.label
                               ?? curve.fillMode, dim: false)
                }
                if curve.dimensions == "3D" && curve.bevelDepth == 0 && curve.extrude == 0 {
                    // Measured in 5.2.1 (run-points-blender-check.sh): Fill
                    // Mode changes nothing on a 3D curve with neither depth
                    // nor extrusion — the wire stays a wire. A closed 2D
                    // curve fills with no depth (48 vertices, 46 faces for a
                    // circle with Both), so the note is for 3D alone.
                    Text("A depth or an extrusion gives the curve a surface")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .lattice(let lattice):
            BPanel("Lattice") {
                // Greyed out with shape keys, as Blender's are: a write there
                // came back as the raw "attribute "points_u" from "Lattice"
                // is read-only" (48 times in a review's sweep).
                Group {
                    stepper("Resolution U", value: lattice.pointsU, range: LatticeSettings.resolutionRange) { v in
                        setData(obj, "points_u", "\(v)", undo: "Resolution U")
                    }
                    stepper("V", value: lattice.pointsV, range: LatticeSettings.resolutionRange) { v in
                        setData(obj, "points_v", "\(v)", undo: "Resolution V")
                    }
                    stepper("W", value: lattice.pointsW, range: LatticeSettings.resolutionRange) { v in
                        setData(obj, "points_w", "\(v)", undo: "Resolution W")
                    }
                }
                .disabled(!lattice.resolutionEditable)
                .opacity(lattice.resolutionEditable ? 1 : 0.5)
                if !lattice.resolutionEditable {
                    Text("A lattice with shape keys keeps its resolution")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(0..<3, id: \.self) { axis in
                    let key = "interpolation_type_" + ["u", "v", "w"][axis]
                    Menu {
                        ForEach(LatticeSettings.interpolations, id: \.identifier) { item in
                            Button(item.label) { setData(obj, key, "'\(item.identifier)'", undo: "Interpolation Type") }
                        }
                    } label: {
                        fieldLabel(["Interpolation U", "V", "W"][axis],
                                   LatticeSettings.interpolations.first { $0.identifier == lattice.interpolation[axis] }?.label
                                   ?? lattice.interpolation[axis], dim: false)
                    }
                }
                flag("Outside", on: lattice.useOutside) { on in
                    setData(obj, "use_outside", on ? "True" : "False", undo: "Outside")
                }
            }
        }
    }

    private func setData(_ obj: BKObject, _ property: String, _ value: String, undo: String) {
        bridge?.run(PointsBpy.set(property, to: value, object: obj.name), undo: undo)
    }

    private static func python(_ v: Float) -> String { String(format: "%.6g", Double(v)) }

    /// The other object a Boolean cuts with, a Shrinkwrap wraps onto or a
    /// Lattice deforms by, which is a pointer rather than a number. `modifier_add` cannot take it, so it
    /// rides along with the rest of the modifier's settings in `update`.
    private func setModifierTarget(_ obj: BKObject, _ modifier: Modifier, to name: String) {
        update(obj, modifier) { $0.targetName = name }
    }

    /// One material per object, named after it, applied to the whole selection.
    ///
    /// Per object, because a material made by `bpy.data.materials.new` is
    /// shared the moment a second object is given it — colouring one wheel
    /// would colour every object made from the same primitive, including ones
    /// in a different model.
    ///
    /// To the whole selection, because the alternative is colouring four
    /// wheels one at a time. Blender's own answer is Link Materials
    /// (Ctrl+L); selecting the parts that should match and setting the colour
    /// once is the same intent with nothing extra to find. One `run`, so it is
    /// one undo step however many objects it covers.
    private func writeMaterial(_ obj: BKObject) {
        let targets = scene.objects.filter { scene.selection.contains($0.id) && $0.hasEditMode }
        let names = targets.isEmpty ? [obj.name] : targets.map(\.name)
        for target in targets where target.id != obj.id {
            target.material = obj.material
            target.color = obj.color
        }
        bridge?.run(names.map {
            Bpy.setMaterial($0, baseColor: obj.material.baseColor,
                            metallic: obj.material.metallic,
                            roughness: obj.material.roughness)
        }, undo: names.count > 1 ? "Set Material on \(names.count) Objects" : "Set Material")
    }

    /// One modifier, with the settings that kind actually uses — the same
    /// per-type layout Blender's modifier stack shows.
    @ViewBuilder
    private func modifierRow(obj: BKObject, modifier: Modifier) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Blender's header, for every kind: its icon and name, Show in
            // Viewport and in Render, the dropdown with Apply and the moves,
            // and remove. Each writes through `bridge.run` and shows what the
            // mirror brings back, like the settings below it.
            HStack(spacing: 5) {
                Image(systemName: modifier.kind.icon)
                    .font(.system(size: 10)).foregroundStyle(BTheme.textDim)
                Text(modifier.name)
                    .font(BTheme.Font.ui(11, weight: .medium)).foregroundStyle(BTheme.text)
                    .lineLimit(1)
                if modifier.kind == .other || modifier.name != modifier.kind.displayName {
                    // The type, when the name does not say it — always for a
                    // kind this panel has no settings for, which is what the
                    // row is named by then.
                    Text(modifier.typeLabel)
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .lineLimit(1)
                }
                Spacer()
                headerSwitch("display", on: modifier.showInViewport, obj: obj, modifier: modifier,
                             action: .toggleViewport)
                headerSwitch("camera", on: modifier.showInRender, obj: obj, modifier: modifier,
                             action: .toggleRender)
                Menu {
                    Button { perform(.apply, obj: obj, modifier: modifier) } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                    }
                    Button { perform(.moveUp, obj: obj, modifier: modifier) } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                    .disabled(obj.modifiers.first?.name == modifier.name)
                    Button { perform(.moveDown, obj: obj, modifier: modifier) } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                    .disabled(obj.modifiers.last?.name == modifier.name)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(BTheme.textDim)
                        .frame(width: 18, height: 18)
                }
                .accessibilityLabel("Modifier actions")
                Button { perform(.remove, obj: obj, modifier: modifier) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9)).foregroundStyle(BTheme.textDim)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Remove Modifier")
            }

            switch modifier.kind {
            case .subdivision:
                stepper("Levels", value: modifier.levels, range: 0...3) { v in
                    update(obj, modifier) { $0.levels = v }
                }
            case .array:
                stepper("Count", value: modifier.count, range: 1...64) { v in
                    update(obj, modifier) { $0.count = v }
                }
            case .mirror:
                // Blender's own rows, in its order: Axis, Bisect, Flip, then
                // Clipping and Merge. Each writes through `update` and shows
                // what the mirror brings back.
                HStack(spacing: 3) {
                    Text("Axis").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Spacer()
                    axisToggle("X", on: modifier.mirrorX) { update(obj, modifier) { $0.mirrorX = !$0.mirrorX } }
                    axisToggle("Y", on: modifier.mirrorY) { update(obj, modifier) { $0.mirrorY = !$0.mirrorY } }
                    axisToggle("Z", on: modifier.mirrorZ) { update(obj, modifier) { $0.mirrorZ = !$0.mirrorZ } }
                }
                .frame(height: 22)
                HStack(spacing: 3) {
                    Text("Bisect").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Spacer()
                    axisToggle("X", on: modifier.bisectX) { update(obj, modifier) { $0.bisectX.toggle() } }
                    axisToggle("Y", on: modifier.bisectY) { update(obj, modifier) { $0.bisectY.toggle() } }
                    axisToggle("Z", on: modifier.bisectZ) { update(obj, modifier) { $0.bisectZ.toggle() } }
                }
                .frame(height: 22)
                // Which side of the cut is kept. Blender dims an axis's Flip
                // while that axis does not bisect, since it then changes
                // nothing; so does this.
                HStack(spacing: 3) {
                    Text("Flip").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Spacer()
                    axisToggle("X", on: modifier.bisectFlipX) { update(obj, modifier) { $0.bisectFlipX.toggle() } }
                        .opacity(modifier.bisectX ? 1 : 0.4)
                    axisToggle("Y", on: modifier.bisectFlipY) { update(obj, modifier) { $0.bisectFlipY.toggle() } }
                        .opacity(modifier.bisectY ? 1 : 0.4)
                    axisToggle("Z", on: modifier.bisectFlipZ) { update(obj, modifier) { $0.bisectFlipZ.toggle() } }
                        .opacity(modifier.bisectZ ? 1 : 0.4)
                }
                .frame(height: 22)
                flag("Clipping", on: modifier.mirrorClip) { on in
                    update(obj, modifier) { $0.mirrorClip = on }
                }
                flag("Merge", on: modifier.mirrorMerge) { on in
                    update(obj, modifier) { $0.mirrorMerge = on }
                }
                // Clipping reads this distance too, so it stays editable with
                // Merge off; Blender only dims it.
                number("Merge Distance", modifier.mergeThreshold, step: 0.0001,
                       unit: .fineMeters, clamp: { max(0, $0) }) { v in
                    update(obj, modifier) { $0.mergeThreshold = v }
                }
                .opacity(modifier.mirrorMerge ? 1 : 0.6)

            case .solidify:
                number("Thickness", modifier.thickness, step: 0.005) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
            case .bevel:
                number("Width", modifier.thickness, step: 0.002, clamp: { max(0, $0) }) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
                stepper("Segments", value: modifier.segments, range: 1...12) { v in
                    update(obj, modifier) { $0.segments = v }
                }
            case .boolean:
                Picker("", selection: Binding(
                    get: { modifier.booleanOperation },
                    set: { m in update(obj, modifier) { $0.booleanOperation = m } })) {
                    ForEach(Modifier.BooleanOperation.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(height: 24)
                // A Boolean with nothing to cut with does nothing at all, in
                // Blender as much as here, so the other object is picked in
                // the row rather than left to be discovered as a puzzle.
                targetPicker(obj: obj, modifier: modifier, label: "Object")
            case .shrinkwrap:
                targetPicker(obj: obj, modifier: modifier, label: "Target")
                if modifier.targetName.isEmpty {
                    // Measured: with `target` None the evaluated mesh comes
                    // back untouched and Blender raises nothing at all. The
                    // row says so rather than looking finished.
                    Text("No target — this modifier does nothing")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                }
                // A Menu rather than a segmented Picker: "Nearest Surface" and
                // "Target Project" truncate to nonsense at four segments in
                // this panel's width.
                Menu {
                    ForEach(Modifier.WrapMethod.allCases, id: \.self) { w in
                        Button(w.label) { update(obj, modifier) { $0.wrapMethod = w } }
                    }
                } label: {
                    fieldLabel("Method", modifier.wrapMethod.label, dim: false)
                }
                number("Offset", modifier.thickness, step: 0.005) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
            case .screw:
                number("Angle", modifier.angle * 180 / .pi, step: 1) { v in
                    update(obj, modifier) { $0.angle = v * .pi / 180 }
                }
                stepper("Steps", value: modifier.count, range: 1...512) { v in
                    update(obj, modifier) { $0.count = v }
                }
                // Blender labels screw_offset "Screw". At 0 this is a lathe;
                // a thread or a spiral needs it nonzero.
                number("Screw", modifier.thickness, step: 0.01) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
                axisRow(obj: obj, modifier: modifier)
            case .decimate:
                if modifier.decimateType != "COLLAPSE" {
                    // Ratio is inert in UNSUBDIV and DISSOLVE. Editing it sends
                    // COLLAPSE with it, so say that before it happens.
                    Text("Set to \(modifier.decimateType.capitalized) by a script — editing switches it to Collapse")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                }
                number("Ratio", modifier.ratio, step: 0.01, clamp: { max(0, min($0, 1)) }) { v in
                    update(obj, modifier) {
                        $0.ratio = v
                        $0.decimateType = "COLLAPSE"
                    }
                }
                // Blender's own face_count, mirrored back; in the simulator,
                // the count its own collapse produced. Measured: a default
                // cube at ratio 0.5 still evaluates to 6 faces, so without
                // this number the row is indistinguishable from a dead control
                // on exactly the primitives reached for first.
                labelled("Faces", "\(modifier.faceCount)")
            case .remesh:
                Picker("", selection: Binding(
                    get: { modifier.remeshMode },
                    set: { m in update(obj, modifier) { $0.remeshMode = m } })) {
                    ForEach(Modifier.RemeshMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(height: 24)
                if modifier.remeshMode == .voxel {
                    // The floor scales with the object: its largest dimension
                    // over 256 (ModifierStack.remeshVoxelFloor has the
                    // measurements). A fixed 0.01 let a 6 m cube reach 2.17
                    // million vertices, and a 13 m one past the mirror's limit.
                    // Measured on the Remesh's input, not on obj.mesh, which on
                    // device is what the Remesh made of it.
                    let floor = ModifierStack.remeshVoxelFloor(for: modifier, on: obj.mesh)
                    number("Voxel Size", modifier.voxelSize, step: 0.01,
                           clamp: { max(floor, min($0, max(2, floor))) }) { v in
                        update(obj, modifier) { $0.voxelSize = v }
                    }
                } else {
                    // Blender's soft maximum is 12; this stops at 8. Measured
                    // on a 32x16 UV sphere in desktop Blender: depth 4 gives
                    // 968 vertices, 6 gives 15,560, 8 gives 248,552 in 0.22 s
                    // and 9 gives 994,280 in 0.84 s — 4x per level, re-run on
                    // every edit, and slower on an iPad. At that rate depth 11
                    // passes the mirror's 10,000,000-vertex limit, where the
                    // object is silently not drawn at all.
                    stepper("Octree Depth", value: modifier.octreeDepth, range: 1...8) { v in
                        update(obj, modifier) { $0.octreeDepth = v }
                    }
                }
            case .displace:
                number("Strength", modifier.thickness, step: 0.005) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
            case .smooth:
                number("Factor", modifier.factor, step: 0.01, clamp: { max(0, min($0, 1)) }) { v in
                    update(obj, modifier) { $0.factor = v }
                }
                stepper("Repeat", value: modifier.iterations, range: 1...10) { v in
                    update(obj, modifier) { $0.iterations = v }
                }
            case .cast:
                number("Factor", modifier.factor, step: 0.01, clamp: { max(0, min($0, 1)) }) { v in
                    update(obj, modifier) { $0.factor = v }
                }
            case .wave:
                number("Height", modifier.thickness, step: 0.005) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
                // Blender's Motion X / Y, not an axis: Wave always rises along
                // Z, and these say which way the ripple travels.
                HStack(spacing: 3) {
                    Text("Motion").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Spacer()
                    axisToggle("X", on: modifier.waveX) { update(obj, modifier) { $0.waveX.toggle() } }
                    axisToggle("Y", on: modifier.waveY) { update(obj, modifier) { $0.waveY.toggle() } }
                }
                .frame(height: 22)
            case .simpleDeform:
                Picker("", selection: Binding(
                    get: { modifier.deformMode },
                    set: { m in update(obj, modifier) { $0.deformMode = m } })) {
                    ForEach(Modifier.DeformMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(height: 26)
                number("Angle", modifier.angle * 180 / .pi, step: 0.5) { v in
                    update(obj, modifier) { $0.angle = v * .pi / 180 }
                }
                axisRow(obj: obj, modifier: modifier)
            case .geometryNodes:
                if modifier.smoothByAngle {
                    // Blender's Smooth by Angle, which Shade Auto Smooth adds:
                    // the two inputs its panel draws, read from the modifier.
                    number("Angle", modifier.angle, step: 0.005, unit: .degrees,
                           clamp: { max(0, min($0, .pi)) }) { v in
                        update(obj, modifier) { $0.angle = v }
                    }
                    flag("Ignore Sharpness", on: modifier.ignoreSharpness) { on in
                        update(obj, modifier) { $0.ignoreSharpness = on }
                    }
                } else if modifier.nodeGroup.isEmpty {
                    // An empty Geometry Nodes modifier passes the mesh through.
                    Text("Geometry Nodes with no node group — this modifier does nothing")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    labelled("Node Group", modifier.nodeGroup)
                    Text("Geometry Nodes: its inputs are edited in Blender's node editor, which this app does not have")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .weightedNormal:
                Picker("", selection: Binding(
                    get: { modifier.weightMode },
                    set: { w in update(obj, modifier) { $0.weightMode = w } })) {
                    ForEach(Modifier.WeightMode.allCases, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .frame(height: 24)
                // RNA's range for `weight` is 1…100, in whole numbers.
                number("Weight", Float(modifier.weight), step: 1, unit: .count,
                       clamp: { max(1, min($0.rounded(), 100)) }) { v in
                    update(obj, modifier) { $0.weight = Int(v) }
                }
                number("Threshold", modifier.threshold, step: 0.01,
                       clamp: { max(0, min($0, 10)) }) { v in
                    update(obj, modifier) { $0.threshold = v }
                }
                flag("Keep Sharp", on: modifier.keepSharp) { on in
                    update(obj, modifier) { $0.keepSharp = on }
                }
                flag("Face Influence", on: modifier.faceInfluence) { on in
                    update(obj, modifier) { $0.faceInfluence = on }
                }
            case .multires:
                multiresRows(obj: obj, modifier: modifier)
            case .edgeSplit:
                flag("Edge Angle", on: modifier.edgeSplitAngle) { on in
                    update(obj, modifier) { $0.edgeSplitAngle = on }
                }
                // RNA's range is 0…180 degrees. Blender dims it with Edge
                // Angle off, where it changes nothing; so does this.
                number("Split Angle", modifier.angle, step: 0.005, unit: .degrees,
                       clamp: { max(0, min($0, .pi)) }) { v in
                    update(obj, modifier) { $0.angle = v }
                }
                .opacity(modifier.edgeSplitAngle ? 1 : 0.6)
                flag("Sharp Edges", on: modifier.edgeSplitSharp) { on in
                    update(obj, modifier) { $0.edgeSplitSharp = on }
                }
            case .laplacianSmooth:
                stepper("Repeat", value: modifier.iterations, range: 0...200) { v in
                    update(obj, modifier) { $0.iterations = v }
                }
                number("Factor", modifier.lambdaFactor, step: 0.01) { v in
                    update(obj, modifier) { $0.lambdaFactor = v }
                }
                number("Border", modifier.lambdaBorder, step: 0.01) { v in
                    update(obj, modifier) { $0.lambdaBorder = v }
                }
                HStack(spacing: 3) {
                    Text("Axis").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    Spacer()
                    axisToggle("X", on: modifier.smoothX) { update(obj, modifier) { $0.smoothX.toggle() } }
                    axisToggle("Y", on: modifier.smoothY) { update(obj, modifier) { $0.smoothY.toggle() } }
                    axisToggle("Z", on: modifier.smoothZ) { update(obj, modifier) { $0.smoothZ.toggle() } }
                }
                .frame(height: 22)
                flag("Preserve Volume", on: modifier.preserveVolume) { on in
                    update(obj, modifier) { $0.preserveVolume = on }
                }
                flag("Normalized", on: modifier.normalized) { on in
                    update(obj, modifier) { $0.normalized = on }
                }
            case .correctiveSmooth:
                number("Factor", modifier.factor, step: 0.01) { v in
                    update(obj, modifier) { $0.factor = v }
                }
                stepper("Repeat", value: modifier.iterations, range: 0...200) { v in
                    update(obj, modifier) { $0.iterations = v }
                }
                number("Scale", modifier.smoothScale, step: 0.01) { v in
                    update(obj, modifier) { $0.smoothScale = v }
                }
                Picker("", selection: Binding(
                    get: { modifier.smoothType },
                    set: { t in update(obj, modifier) { $0.smoothType = t } })) {
                    ForEach(Modifier.SmoothType.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(height: 24)
                flag("Only Smooth", on: modifier.onlySmooth) { on in
                    update(obj, modifier) { $0.onlySmooth = on }
                }
                flag("Pin Boundaries", on: modifier.pinBoundary) { on in
                    update(obj, modifier) { $0.pinBoundary = on }
                }
                if modifier.restSource != "ORCO" {
                    // Set by a script or another app: shown as Blender holds
                    // it, since this panel does not bind.
                    labelled("Rest Source", modifier.isBound ? "Bind (bound)" : "Bind (not bound)")
                }
            case .lattice:
                latticePicker(obj: obj, modifier: modifier)
                if modifier.targetName.isEmpty {
                    // Measured: with no object Blender leaves the mesh alone,
                    // raises nothing, and refuses Apply with "Modifier is
                    // disabled, skipping apply".
                    Text("No lattice — this modifier does nothing")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                }
                number("Strength", modifier.thickness, step: 0.01) { v in
                    update(obj, modifier) { $0.thickness = v }
                }
            case .other:
                // A kind this panel has no settings rows for. The header's
                // controls are Blender's own for any modifier and work on it.
                // Its settings are Blender's RNA, which the Every Property
                // browser reads and writes through `set_property` — opened
                // here on this modifier rather than on the object, so they are
                // one tap away, not a hunt through `modifiers`.
                if session.usesRealBlender {
                    NavigationLink {
                        BlenderDataBrowser(bridge: bridge,
                                           startPath: Bpy.modifierDataPath(modifier.name),
                                           revision: session.backendRevision)
                    } label: {
                        fieldLabel("Settings", "Every Property ›", dim: false)
                    }
                    .buttonStyle(.plain)
                }
                // A kind the panel does model reaches here only when the
                // mirror could not read its settings (`unread`), and then
                // "no rows of its own" would be untrue.
                Text(ModifierKind.modelled(modifier.blenderType) == nil
                     ? "\(modifier.typeLabel) has no rows of its own in this panel"
                     : "Blender's settings for this \(modifier.typeLabel) could not be read")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            case .weld:
                // Weld has one setting the row offers: its Vertex Group, below.
                if !session.usesRealBlender {
                    Text("No settings")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                }
            case .triangulate:
                Text("No settings")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }
            // The Vertex Group field, for the kinds whose result it changes
            // (`ModifierKind.takesVertexGroup`). Only on the real backend: the
            // simulator's stand-in has no vertex groups to pick. Decimate
            // reads it only when collapsing, the one mode the row drives.
            if modifier.kind.takesVertexGroup, session.usesRealBlender,
               modifier.kind != .decimate || modifier.decimateType == "COLLAPSE" {
                vertexGroupPicker(obj: obj, modifier: modifier)
            }
        }
        .padding(6)
        .background(BTheme.field.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        // A modifier off in the viewport reads as off, as Blender greys it.
        .opacity(modifier.showInViewport ? 1 : 0.7)
    }

    /// Multiresolution: its three levels, what Subdivide has made, and the
    /// four operators its panel in Blender has. The levels are clamped to the
    /// total, as Blender clamps them (measured: 5 on a Multires of 2 reads
    /// back 2), so a stepper past it would be a control that does nothing.
    @ViewBuilder
    private func multiresRows(obj: BKObject, modifier: Modifier) -> some View {
        let total = max(modifier.totalLevels, 0)
        stepper("Level Viewport", value: modifier.levels, range: 0...total) { v in
            update(obj, modifier) { $0.levels = v }
        }
        stepper("Sculpt", value: modifier.sculptLevels, range: 0...total) { v in
            update(obj, modifier) { $0.sculptLevels = v }
        }
        stepper("Render", value: modifier.renderLevels, range: 0...total) { v in
            update(obj, modifier) { $0.renderLevels = v }
        }
        labelled("Total Levels", "\(total)")
        HStack(spacing: 4) {
            multiresButton(.subdivide, obj: obj, modifier: modifier)
            multiresButton(.unsubdivide, obj: obj, modifier: modifier)
        }
        // Delete Higher removes the levels above the one Blender shows: the
        // sculpt level while Blender has the object in Sculpt Mode (where the
        // mirror puts this interface in Sculpt Mode too), the viewport level
        // otherwise (`_blenderkit_multires`, measured against Blender's own).
        let shown = session.usesRealBlender && scene.mode == .sculpt
            ? modifier.sculptLevels : modifier.levels
        HStack(spacing: 4) {
            multiresButton(.deleteHigher, obj: obj, modifier: modifier)
                .disabled(shown >= total)
            multiresButton(.applyBase, obj: obj, modifier: modifier)
                .disabled(total == 0)
        }
    }

    @ViewBuilder
    private func multiresButton(_ op: Bpy.MultiresOperation, obj: BKObject,
                                modifier: Modifier) -> some View {
        Button { perform(.multires(op), obj: obj, modifier: modifier) } label: {
            Text(op.label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
                .frame(maxWidth: .infinity).frame(height: 22)
                .background(BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// One of the header's two switches: lit while Blender has it on.
    @ViewBuilder
    private func headerSwitch(_ icon: String, on: Bool, obj: BKObject, modifier: Modifier,
                              action: ModifierRowAction) -> some View {
        Button { perform(action, obj: obj, modifier: modifier) } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(on ? BTheme.text : BTheme.textDim.opacity(0.45))
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(action == .toggleViewport ? "Show in Viewport" : "Show in Render")
        .accessibilityValue(on ? "On" : "Off")
    }

    /// Sends one of the controls every row has (`ModifierRowAction`), as the
    /// launch hook does. Nothing is written here: the row shows what comes
    /// back, as `update` does for the settings.
    private func perform(_ action: ModifierRowAction, obj: BKObject, modifier: Modifier) {
        guard let command = action.command(for: modifier, in: obj.modifiers),
              !command.lines.isEmpty else { return }
        bridge?.run(command.lines, undo: command.undo)
    }

    /// A Lattice's object: only lattices, since Blender leaves the pointer
    /// None for anything else without a word (measured in 5.2.1).
    @ViewBuilder
    private func latticePicker(obj: BKObject, modifier: Modifier) -> some View {
        let lattices = scene.objects.filter { $0.blenderType == "LATTICE" && $0.id != obj.id }
        Menu {
            ForEach(lattices, id: \.id) { other in
                Button(other.name) { setModifierTarget(obj, modifier, to: other.name) }
            }
            if lattices.isEmpty {
                Text("No lattice object in the scene")
            }
            // Sends `object = None` (`Bpy.modifierSettings`), so a wrong pick
            // can be taken back, not only replaced.
            if !modifier.targetName.isEmpty {
                Button("None") { setModifierTarget(obj, modifier, to: "") }
            }
        } label: {
            fieldLabel("Object",
                       modifier.targetName.isEmpty ? "Pick a lattice" : modifier.targetName,
                       dim: modifier.targetName.isEmpty)
        }
    }

    /// Sends one change to a modifier, and nothing else: the settings that
    /// differ from `modifier` — the row as the mirror last reported it.
    ///
    /// Nothing is written here. The row shows what comes back, on device
    /// through the mirror and in the simulator through the shim, both before
    /// `run` returns. It used to write the display cache first, so a change
    /// Blender refused stayed on screen, and a refused setting was resent with
    /// every later edit of the others (see `Bpy.modifierEdit`).
    private func update(_ obj: BKObject, _ modifier: Modifier, _ change: (inout Modifier) -> Void) {
        var changed = modifier
        change(&changed)
        let lines = Bpy.modifierEdit(from: modifier, to: changed)
        guard !lines.isEmpty else { return }
        bridge?.run(lines, undo: "Edit Modifier")
    }

    /// A float setting, scrubbed like Blender's number fields and sent once,
    /// when the drag ends. `clamp` holds the draft to what the row would send.
    @ViewBuilder
    private func number(_ label: String, _ value: Float, step: Float,
                        unit: BNumberField.Unit = .none,
                        clamp: @escaping (Float) -> Float = { $0 },
                        set: @escaping (Float) -> Void) -> some View {
        ModifierNumberField(label: label, value: value, step: step, unit: unit,
                            clamp: clamp, commit: set)
    }

    /// Blender's X/Y/Z axis selector, for Screw and Simple Deform.
    @ViewBuilder
    private func axisRow(obj: BKObject, modifier: Modifier) -> some View {
        HStack(spacing: 3) {
            Text("Axis").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            ForEach(0..<3, id: \.self) { i in
                axisToggle(["X", "Y", "Z"][i], on: modifier.axis == i) {
                    update(obj, modifier) { $0.axis = i }
                }
            }
        }
        .frame(height: 22)
    }

    /// A modifier's Vertex Group, with Blender's Invert beside it: the
    /// object's own groups, as the mirror read them, and None. The same
    /// pattern as the object pickers: the pick goes through `update`, and the
    /// row shows what comes back — Blender clears a name that is not a group.
    @ViewBuilder
    private func vertexGroupPicker(obj: BKObject, modifier: Modifier) -> some View {
        let groups = obj.meshGroups?.groups ?? []
        HStack(spacing: 3) {
            Menu {
                Button("None") { update(obj, modifier) { $0.vertexGroup = "" } }
                ForEach(groups, id: \.name) { group in
                    Button(group.name) { update(obj, modifier) { $0.vertexGroup = group.name } }
                }
            } label: {
                fieldLabel("Vertex Group",
                           !modifier.vertexGroup.isEmpty ? modifier.vertexGroup
                               : groups.isEmpty ? "No groups on \(obj.name)" : "None",
                           dim: modifier.vertexGroup.isEmpty)
            }
            // Blender greys Invert while no group is set: it changes nothing then.
            axisToggle("⇄", on: modifier.invertVertexGroup) {
                update(obj, modifier) { $0.invertVertexGroup.toggle() }
            }
            .opacity(modifier.vertexGroup.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Invert Vertex Group")
            .accessibilityValue(modifier.invertVertexGroup ? "On" : "Off")
        }
    }

    /// The other object a Boolean cuts with or a Shrinkwrap wraps onto. Only
    /// meshes, and never the object the modifier is on.
    @ViewBuilder
    private func targetPicker(obj: BKObject, modifier: Modifier, label: String) -> some View {
        Menu {
            ForEach(scene.objects.filter { $0.hasEditMode && $0.id != obj.id }, id: \.id) { other in
                Button(other.name) { setModifierTarget(obj, modifier, to: other.name) }
            }
        } label: {
            fieldLabel(label,
                       modifier.targetName.isEmpty ? "Pick a mesh" : modifier.targetName,
                       dim: modifier.targetName.isEmpty)
        }
    }

    /// The label a Menu wears to read as one of the panel's fields: a dim
    /// caption, the current value, and the same pill the number fields use.
    @ViewBuilder
    private func fieldLabel(_ label: String, _ value: String, dim: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11))
                .foregroundStyle(dim ? BTheme.textDim : BTheme.text)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    @ViewBuilder
    private func stepper(_ label: String, value: Int, range: ClosedRange<Int>,
                         set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Button { if value > range.lowerBound { set(value - 1) } } label: {
                Image(systemName: "minus").font(.system(size: 9))
                    .frame(width: 22, height: 20).background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight).foregroundStyle(BTheme.text)
            Text("\(value)").font(BTheme.Font.mono(11))
                .foregroundStyle(BTheme.text).frame(width: 26)
            Button { if value < range.upperBound { set(value + 1) } } label: {
                Image(systemName: "plus").font(.system(size: 9))
                    .frame(width: 22, height: 20).background(BTheme.widget)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
                .hoverEffect(.highlight).foregroundStyle(BTheme.text)
        }
        .frame(height: 22)
    }

    /// One of Blender's checkboxes, as Mirror's Clipping and Merge. It shows
    /// `on` — the modifier as the mirror last reported it — and a tap sends
    /// the change; the switch moves when Blender's answer comes back.
    @ViewBuilder
    private func flag(_ label: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: set))
                .labelsHidden()
                .scaleEffect(0.7)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private func axisToggle(_ label: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Text(label)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(on ? Color.white : BTheme.textDim)
                .frame(width: 24, height: 20)
                .background(on ? BTheme.select : BTheme.widget)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
                .hoverEffect(.highlight)
    }

    /// World-space bounding-box size, as Blender's Dimensions field reports it.
    private func dimensions(of obj: BKObject) -> SIMD3<Float> {
        guard !obj.mesh.vertices.isEmpty else { return .zero }
        let m = obj.modelMatrix
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in obj.mesh.vertices {
            let w = (m * SIMD4(v.position, 1)).xyz
            lo = min(lo, w); hi = max(hi, w)
        }
        return hi - lo
    }

    @ViewBuilder
    private func labelled(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.text)
        }
        .frame(height: 20)
    }
}

/// A modifier row's number: the value Blender holds, and while a finger is on
/// it, a draft.
///
/// Every sample of a drag used to be a `bridge.run` — for a Remesh that is a
/// voxel remesh, a whole mirroring pass and an undo step per frame. Now the
/// drag moves the draft and the finger lifting sends one change. `run` mirrors
/// before it returns, so dropping the draft then shows what Blender took: the
/// new value, or the old one if Blender refused it.
private struct ModifierNumberField: View {
    let label: String
    let value: Float
    let step: Float
    let unit: BNumberField.Unit
    let clamp: (Float) -> Float
    let commit: (Float) -> Void
    @State private var draft: Float?

    var body: some View {
        BNumberField(label, value: Binding(get: { draft ?? value },
                                           set: { draft = clamp($0) }),
                     step: step,
                     unit: unit,
                     commit: { v in
                         commit(clamp(v))
                         draft = nil
                     })
    }
}

/// Blender's Transform fields — Location, Rotation, Scale — as Properties ▸
/// Object and the N panel's Item tab both show them. Each of those had its own
/// copy, and both showed a decomposition of `matrix_world` while writing
/// `location`, `rotation_euler` and `scale`: under a parent that had moved, a
/// nudge of 0.01 sent a child 3.16 m away (`TransformChannels` has the
/// measurement).
///
/// The fields show what Blender holds (`BKObject.shownChannels`): the
/// object's own channels, the rotation in its own mode and property. A drag
/// previews in the viewport — the object where Blender will put it, its
/// children with it (`TransformFieldEdit`) — and the finger lifting writes the
/// field changed and nothing else, as one undo step
/// (`BpyBridge.commitTransformField`). The mirroring pass that write ends with
/// is what the fields show next.
struct ObjectTransformFields: View {
    var object: BKObject
    var scene: BKScene
    var bridge: BpyBridge?
    @State private var edit: TransformFieldEdit?

    var body: some View {
        let shown = edit.flatMap { $0.object === object ? $0.edited : nil } ?? object.shownChannels
        if let shown {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(TransformChannels.Group.allCases, id: \.self) { group in
                    row(group, shown)
                }
            }
        } else {
            Text("Blender's transform channels for \(object.name) did not arrive with the scene, "
                 + "so the fields are left out rather than shown wrong.")
                .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ group: TransformChannels.Group, _ shown: TransformChannels) -> some View {
        let axes = shown.axes(group)
        let values = shown.values(group)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.title).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                Spacer()
                if group == .rotation {
                    // Which property the fields are: Blender's Mode menu.
                    Text(shown.rotationMode.label)
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                }
            }
            ForEach(axes.indices, id: \.self) { i in
                BNumberField(axes[i],
                             value: Binding(get: { values[i] },
                                            set: { change(group, axis: i, to: $0) }),
                             step: 0.01,
                             accent: Self.accent(axes[i]),
                             unit: group == .location ? .meters
                                 : shown.isAngle(group, axis: i) ? .degrees : .none,
                             commit: { _ in commit(group) })
            }
        }
    }

    private static func accent(_ axis: String) -> Color? {
        switch axis {
        case "X": return BTheme.axisX
        case "Y": return BTheme.axisY
        case "Z": return BTheme.axisZ
        default:  return nil
        }
    }

    private func change(_ group: TransformChannels.Group, axis: Int, to value: Float) {
        if edit?.object !== object {
            edit?.rollBackDrawing()
            edit = TransformFieldEdit(object: object, scene: scene)
        }
        edit?.change(group, axis: axis, to: value)
    }

    private func commit(_ group: TransformChannels.Group) {
        guard let pending = edit else { return }
        edit = nil
        if let bridge {
            bridge.commitTransformField(pending, group: group)
        } else {
            pending.rollBackDrawing()
        }
    }
}
