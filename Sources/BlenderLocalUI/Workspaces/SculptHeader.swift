import SwiftUI

/// Blender's sculpt header, for its own Sculpt Mode: the brush, its Size and
/// Strength, then Dynamic Topology, Remesh, Multires, Mask and Face Sets.
///
/// Every control writes through `bridge.run` into Blender (`SculptBpy`), and
/// every value shown is Blender's, read back (`BpyBridge.sculptState`)
/// whenever the history moves — a control never shows a value Blender does
/// not hold, and a script that changes the brush is seen here too.
struct SculptHeader: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?

    @State private var brushes: [String] = []
    /// Size and Strength while they are dragged; Blender's once written.
    @State private var sizeDraft: Float?
    @State private var strengthDraft: Float?
    @State private var detailDraft: Float?
    @State private var voxelDraft: Float?
    @State private var showDetails = false

    private var state: SculptState? { scene.sculptBlender }

    var body: some View {
        HStack(spacing: 8) {
            brushMenu
            if let size = state?.size {
                BNumberField("Size", value: Binding(get: { sizeDraft ?? Float(size) },
                                                    set: { sizeDraft = max(1, $0) }),
                             step: 1, unit: .pixels,
                             commit: { value in
                                 run(SculptBpy.setSize(Int(value.rounded())))
                                 sizeDraft = nil
                             })
                    .frame(width: 118)
            }
            if let strength = state?.strength {
                BNumberField("Strength", value: Binding(get: { strengthDraft ?? Float(strength) },
                                                        set: { strengthDraft = min(max($0, 0), 1) }),
                             step: 0.005,
                             commit: { value in
                                 run(SculptBpy.setStrength(value))
                                 strengthDraft = nil
                             })
                    .frame(width: 132)
            }
            invertToggle
            maskMenu
            faceSetsMenu
            Button { showDetails = true } label: {
                Label(state?.dyntopo == true ? "Dyntopo" : "Remesh", systemImage: "square.grid.3x3.fill")
                    .padding(.horizontal, 10).frame(height: 40)
                    .contentShape(Rectangle())
            }
            .popover(isPresented: $showDetails) { details.frame(width: 300).padding(14) }
        }
        .task { brushes = bridge?.sculptBrushes() ?? [] }
        // Blender's values, again whenever the history moves: a stroke, an
        // Undo, a script, a setting written here.
        .task(id: session.backendRevision) { refresh() }
    }

    private func refresh() {
        scene.sculptBlender = bridge?.sculptState()
    }

    private func run(_ python: String, undo: String? = nil) {
        // Not while a stroke is down: its chunks rewind the step on top of
        // Blender's stack (BpySession.sculptStrokeOpen). The bridge refuses it
        // too, in words; here nothing is sent at all.
        guard let bridge, !session.isRunning, !session.sculptStrokeOpen else { return }
        bridge.run(python, undo: undo)
        refresh()
    }

    /// A menu row with Blender's check mark when `checked`, and no image
    /// otherwise: `Label(_, systemImage: "")` asks SwiftUI for a symbol named
    /// "", and it logs a missing-symbol error for every row each time the
    /// menu is built (64 brushes).
    @ViewBuilder
    private func checkRow(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: the brush

    /// Blender's Essentials sculpt brushes, as its asset shelf offers them,
    /// with the one Blender has checked.
    private var brushMenu: some View {
        Menu {
            if state?.essentials == false || brushes.isEmpty {
                Text("Blender's Essentials brushes are not in this build")
            }
            ForEach(brushes, id: \.self) { name in
                Button {
                    run(SculptBpy.activate(name))
                } label: {
                    checkRow(name, checked: state?.brush == name)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed")
                Text(state?.brush ?? "No Brush").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    /// Blender's Ctrl held during a stroke: the brush's other direction
    /// (`brush_stroke(mode='INVERT')`). Held here, as the key is, not written
    /// into the brush.
    private var invertToggle: some View {
        Button {
            scene.sculpt.invert.toggle()
        } label: {
            Label("Invert", systemImage: scene.sculpt.invert ? "minus.circle.fill" : "minus.circle")
                .foregroundStyle(scene.sculpt.invert ? Color.white : BTheme.text)
                .padding(.horizontal, 10).frame(height: 32)
                .background(scene.sculpt.invert ? BTheme.select : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Invert stroke")
    }

    // MARK: Mask and Face Sets

    private var maskMenu: some View {
        Menu {
            ForEach(SculptMaskAction.allCases, id: \.self) { action in
                Button(action.label) { run(SculptBpy.mask(action), undo: SculptBpy.maskUndo) }
            }
            if brushes.contains("Mask") {
                Divider()
                Button { run(SculptBpy.activate("Mask")) } label: {
                    checkRow("Mask Brush", checked: state?.brush == "Mask")
                }
            }
            if state?.multires != nil, state?.masked == nil {
                Divider()
                Text("The mask on a Multires level is not counted here")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                Text((state?.masked ?? 0) > 0 ? "Mask · \(state?.masked ?? 0)" : "Mask")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    private var faceSetsMenu: some View {
        Menu {
            // Blender's face set operators cancel under Dynamic Topology
            // without a word (sculpt_face_set.cc, "Dyntopo not supported"),
            // so they are not offered there, and the menu says why.
            let dyntopo = state?.dyntopo == true
            if dyntopo {
                Text("Face Sets do not work under Dynamic Topology")
            }
            Section("Initialize Face Sets") {
                ForEach(SculptFaceSetInit.allCases, id: \.self) { mode in
                    Button(mode.label) { run(SculptBpy.faceSetsInit(mode), undo: SculptBpy.faceSetsInitUndo) }
                        .disabled(dyntopo)
                }
            }
            Button("Face Set from Masked") {
                run(SculptBpy.faceSetFromMask, undo: SculptBpy.faceSetFromMaskUndo)
            }
            // Masked is nil on a Multires level, where Blender holds a mask
            // no script can count: offered, and Blender says if it is empty.
            .disabled(dyntopo || state?.masked == 0)
            if brushes.contains("Face Set Paint") {
                Divider()
                Button { run(SculptBpy.activate("Face Set Paint")) } label: {
                    checkRow("Face Set Paint Brush", checked: state?.brush == "Face Set Paint")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                Text((state?.faceSets ?? 0) > 1 ? "Face Sets · \(state?.faceSets ?? 0)" : "Face Sets")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    // MARK: Dyntopo, Remesh and Multires

    /// Blender's Dyntopo and Remesh popovers, and Multires's Subdivide.
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dynamic Topology").font(BTheme.Font.ui(12, weight: .semibold))
            Toggle("Dynamic Topology", isOn: Binding(
                get: { state?.dyntopo ?? false },
                set: { run(SculptBpy.dyntopo($0), undo: SculptBpy.dyntopoUndo) }))
                .font(BTheme.Font.ui(12))
                .disabled(state?.multires != nil)
            if let detail = state?.detailValue {
                BNumberField("Detail (\(state?.detailType?.capitalized ?? ""))",
                             value: Binding(get: { detailDraft ?? Float(detail) },
                                            set: { detailDraft = max(0.1, $0) }),
                             step: 0.1,
                             commit: { value in
                                 run(SculptBpy.setDetail(value))
                                 detailDraft = nil
                             })
            }
            Divider()
            Text("Remesh").font(BTheme.Font.ui(12, weight: .semibold))
            if let voxel = state?.voxelSize {
                // Blender remeshes at this size in the mesh's own units
                // (voxel_remesh_exec), so it is metres only on an unscaled
                // object; on a scaled one the field shows the number Blender
                // holds, and the line under it what that is in the scene.
                let scaled = state?.isScaled == true
                BNumberField("Voxel Size", value: Binding(get: { voxelDraft ?? Float(voxel) },
                                                          set: { voxelDraft = max(0.0001, $0) }),
                             step: 0.001, unit: scaled ? .fine : .fineMeters,
                             commit: { value in
                                 run(SculptBpy.setVoxelSize(value))
                                 voxelDraft = nil
                             })
                if scaled, let object = state?.object {
                    Text(state?.voxelSizeInScene.map {
                        "In \(object)'s own units: its scale makes this \(NumberFieldUnit.fineMeters.format(Float($0))) in the scene."
                    } ?? "In \(object)'s own units, which its scale stretches differently on each axis.")
                        .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Voxel Remesh") { run(SculptBpy.voxelRemesh, undo: SculptBpy.voxelRemeshUndo) }
                .disabled(state?.dyntopo == true || state?.multires != nil)
            Divider()
            Text("Multiresolution").font(BTheme.Font.ui(12, weight: .semibold))
            if let multires = state?.multires {
                Text("\(multires.name): \(multires.totalLevels) level\(multires.totalLevels == 1 ? "" : "s"), "
                     + "sculpting at \(multires.sculptLevels)")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
            Button(state?.multires == nil ? "Add Multires and Subdivide" : "Subdivide") {
                run(SculptBpy.multiresSubdivide, undo: SculptBpy.multiresSubdivideUndo)
            }
            // Offered over the budget too: Blender's refusal says why, with
            // the measurements, where a greyed button would say nothing.
            .disabled(state?.dyntopo == true)
            if state?.multiresOverBudget == true, let budget = state?.multiresBaseBudget {
                Text("Multires is sculpted here on base meshes of up to \(budget.formatted()) vertices.")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let v = state?.vertices, let f = state?.faces {
                Text("\(v) vertices, \(f) faces in Blender's mesh")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
            }
        }
        .buttonStyle(.bordered)
        .foregroundStyle(BTheme.text)
    }
}
