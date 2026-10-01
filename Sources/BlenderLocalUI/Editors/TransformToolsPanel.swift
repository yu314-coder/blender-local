import SwiftUI
import simd

/// Snapping, the pivot point, proportional editing and the 3D cursor, with room
/// for the numbers.
///
/// The header's menus carry the same settings, but a menu on iOS holds controls
/// rather than fields, and two of these — the proportional size and the cursor's
/// three coordinates — are numbers you type. This is where they are typeable.
///
/// Everything here is `scene.tools` and `scene.cursor`, which are Blender's
/// `tool_settings` and `scene.cursor` mirrored back after every command
/// (TransformTools.swift). Every control runs Python; none writes the cache.
struct TransformToolsPanel: View {
    var scene: BKScene
    var bridge: BpyBridge?
    /// The app's own increment, not Blender's: Blender takes it from the 3D
    /// View's grid, which is a property of a view this app does not have.
    @Binding var increment: Float

    /// A number field's value while it is being dragged or typed. It goes to
    /// Blender once, when the drag ends — `bridge.run` per drag sample cost a
    /// mirroring pass over every object's evaluated mesh and an Info line
    /// each — and the field shows Blender's value again once it has.
    @State private var sizeDraft: Float?
    @State private var cursorDraft: SIMD3<Float>?
    @State private var thresholdDraft: Float?

    private var editing: Bool { scene.mode == .edit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                transformPanel
                if editing { autoMergePanel } else { affectOnlyPanel }
                snappingPanel
                proportionalPanel
                cursorPanel
            }
            .padding(.bottom, 12)
        }
        .background(BTheme.properties)
    }

    // MARK: the pivot point

    private var transformPanel: some View {
        BPanel("Transform") {
            row("Pivot Point") {
                Menu {
                    ForEach(TransformPivot.allCases) { value in
                        Button {
                            bridge?.run(ToolsBpy.pivot(value))
                        } label: {
                            Label(value.label,
                                  systemImage: scene.tools.pivot == value ? "checkmark" : value.icon)
                        }
                    }
                } label: { chip(scene.tools.pivot.label) }
            }
            Text(pivotNote)
                .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What each pivot costs here, said plainly rather than left to be found
    /// out. Individual Origins is the one that cannot be a single operator,
    /// and while editing it and Active Element fall back to the median
    /// (TransformGizmo.pivot): the edit selection here carries no active
    /// element and no face islands.
    private var pivotNote: String {
        switch scene.tools.pivot {
        case .medianPoint:
            return "Rotations and scales turn about the middle of the selection."
        case .boundingBoxCenter:
            return "About the centre of the selection's bounds."
        case .cursor:
            return String(format: "About the 3D cursor, at %.3f, %.3f, %.3f.",
                          scene.cursor.x, scene.cursor.y, scene.cursor.z)
        case .activeElement:
            return editing ? "While editing, about the middle of the selection: "
                           + "there is no active vertex, edge or face to turn about."
                           : "About the active object's origin."
        case .individualOrigins:
            return editing ? "While editing, about the middle of the selection: "
                           + "face islands are not turned one by one."
                           : "Each object turns where it stands. Blender has no one "
                           + "operator for this, so it runs one per object — still one undo step."
        }
    }

    // MARK: Auto Merge

    /// Blender keeps these in the edit-mode header's Options. They are the
    /// scene's `use_mesh_automerge` and `double_threshold`, which the commit
    /// welds by and so the drag's preview does too (`AutoMerge`).
    private var autoMergePanel: some View {
        BPanel("Auto Merge") {
            Toggle("Auto Merge Vertices",
                   isOn: Binding(get: { scene.tools.autoMerge },
                                 set: { bridge?.run(ToolsBpy.autoMerge($0)) }))
                .font(BTheme.Font.ui(11))
            BNumberField("Threshold", value: Binding(
                get: { thresholdDraft ?? scene.tools.mergeThreshold },
                set: { thresholdDraft = Self.clampedThreshold($0) }),
                step: 0.0001, unit: .fineMeters,
                commit: { value in
                    bridge?.run(ToolsBpy.mergeThreshold(Self.clampedThreshold(value)))
                    thresholdDraft = nil
                })
            Text("After a move, turn or scale, a moved vertex within the "
                 + "threshold of one that stayed is welded into it.")
                .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            // `use_mesh_automerge_and_split`: the commit reads it from the
            // scene, and nothing showed it before. The drag shows where every
            // vertex lands (the split leaves them where they are: measured in
            // 5.2.1, a vertex dropped 0.0004 off another mesh's edge stayed at
            // 0.0004 and the edge bent through it), not the new edges and
            // crossing vertices, which arrive with the commit.
            Toggle("Split Edges & Faces",
                   isOn: Binding(get: { scene.tools.autoMergeSplit },
                                 set: { bridge?.run(ToolsBpy.autoMergeSplit($0)) }))
                .font(BTheme.Font.ui(11))
                .disabled(!scene.tools.autoMerge)
            if scene.tools.autoMerge && scene.tools.autoMergeSplit {
                Text("Edges a move lands on or crosses are split on release: the new "
                     + "edges, and a vertex where two edges cross, appear then.")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Affect Only

    /// Blender's Options popover (Transform ▸ Affect Only). Both are
    /// `tool_settings` the object-mode commit reads from the scene; a .blend or
    /// a script could turn them on and nothing here showed it.
    private var affectOnlyPanel: some View {
        BPanel("Affect Only") {
            Toggle("Origins",
                   isOn: Binding(get: { scene.tools.affectOnlyOrigins },
                                 set: { bridge?.run(ToolsBpy.affectOnlyOrigins($0)) }))
                .font(BTheme.Font.ui(11))
            Toggle("Parents",
                   isOn: Binding(get: { scene.tools.affectOnlyParents },
                                 set: { bridge?.run(ToolsBpy.affectOnlyParents($0)) }))
                .font(BTheme.Font.ui(11))
            if scene.tools.affectOnlyOrigins || scene.tools.affectOnlyParents {
                Text(affectOnlyNote)
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var affectOnlyNote: String {
        var parts: [String] = []
        if scene.tools.affectOnlyOrigins {
            parts.append("A move, turn or scale changes the origins; the geometry stays where it is.")
        }
        if scene.tools.affectOnlyParents {
            parts.append("Children that are not selected stay where they are.")
        }
        return parts.joined(separator: " ")
    }

    private static func clampedThreshold(_ value: Float) -> Float {
        let range = TransformToolSettings.mergeThresholdRange
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: snapping

    private var snappingPanel: some View {
        BPanel("Snapping") {
            Toggle("Snap", isOn: Binding(get: { scene.tools.useSnap },
                                         set: { bridge?.run(ToolsBpy.useSnap($0)) }))
                .font(BTheme.Font.ui(11))
            // Kept above zero: at 0 or below `TransformSnap` has no step and
            // a drag stops snapping with the magnet still lit (round 2's
            // review), and the Snap menu's grid actions quietly used 1.
            BNumberField("Increment", value: Binding(get: { increment },
                                                     set: { increment = min(max($0, 0.001), 1000) }),
                         step: 0.05, unit: .meters)

            Text("Snap To").font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            ForEach(SnapElement.allCases) { element in
                let on = scene.tools.elements.contains(element)
                checkRow(element.label, on: on, note: element.dragNote) {
                    var next = scene.tools.elements
                    if next.contains(element) { next.remove(element) } else { next.insert(element) }
                    bridge?.run(ToolsBpy.elements(next))
                }
                // Blender keeps at least one element across this list and the
                // two below (`holdsLastSnapElement` has the measurement), so
                // the last one left could not untick.
                .disabled(on && scene.tools.holdsLastSnapElement)
            }
            ForEach(SnapElementIndividual.allCases) { element in
                let on = scene.tools.individual.contains(element)
                checkRow(element.label, on: on, note: "scene setting") {
                    var next = scene.tools.individual
                    if next.contains(element) { next.remove(element) } else { next.insert(element) }
                    bridge?.run(ToolsBpy.individual(next))
                }
                .disabled(on && scene.tools.holdsLastSnapElement)
            }

            row("Snap With") {
                Menu {
                    ForEach(SnapTarget.allCases) { value in
                        Button {
                            bridge?.run(ToolsBpy.target(value))
                        } label: {
                            Label(value.label,
                                  systemImage: scene.tools.target == value ? "checkmark" : "")
                        }
                    }
                } label: { chip(scene.tools.target.label) }
            }

            // Blender's Target Selection. Both are edit mode's alone, as
            // Blender's own descriptions say.
            Toggle("Include Active",
                   isOn: Binding(get: { scene.tools.snapSelf },
                                 set: { bridge?.run(ToolsBpy.snapSelf($0)) }))
                .font(BTheme.Font.ui(11))
            Toggle("Include Non-edited",
                   isOn: Binding(get: { scene.tools.snapNonEdited },
                                 set: { bridge?.run(ToolsBpy.snapNonEdited($0)) }))
                .font(BTheme.Font.ui(11))

            // Said once, here, rather than left to be discovered by a drag.
            // A headless Blender does not snap a transform at all — measured
            // in 5.2.1, translate(value=(0.3,0,0)) with INCREMENT on landed on
            // 0.3, and snap_elements={'VERTEX'} left an object where it was —
            // so the drag snaps itself and sends Blender the snapped value
            // (TransformSnap, GeometrySnap). Volume and Edge Perpendicular are
            // not reproduced, and stay scene settings.
            Text("Increment moves in steps of the size above from where a drag "
                 + "starts, turns in 5° steps and scales in steps of 0.1. Grid "
                 + "puts the Snap With point on the grid, for moves only; it "
                 + "wins when both are ticked. Vertex, Edge, Edge Center, Face "
                 + "and Face Center snap a move to what is within 30 points of "
                 + "the finger, and win over both. Volume and Edge Perpendicular "
                 + "are real scene settings, saved in the .blend and meaningful "
                 + "on a desktop, but no drag here uses them.")
                .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: proportional editing

    private var proportionalPanel: some View {
        BPanel("Proportional Editing") {
            // Blender keeps edit mode's switch apart from object mode's, and
            // the header toggle writes whichever the current mode uses.
            Toggle(editing ? "Proportional Editing" : "Proportional Editing (Objects)",
                   isOn: Binding(get: { scene.tools.isProportional(editing: editing) },
                                 set: { bridge?.run(ToolsBpy.proportional($0, editing: editing)) }))
                .font(BTheme.Font.ui(11))
            row("Falloff") {
                Menu {
                    ForEach(MeshEditor.ProportionalFalloff.allCases) { value in
                        Button {
                            bridge?.run(ToolsBpy.falloff(value))
                        } label: {
                            Label(value.label,
                                  systemImage: scene.tools.falloff == value ? "checkmark" : "")
                        }
                    }
                } label: { chip(scene.tools.falloff.label) }
            }
            // Clamped to Blender's own range, the draft too. Measured in
            // 5.2.1: bpy clamps rather than raising, so an unclamped field
            // would show a number Blender never held.
            BNumberField("Size", value: Binding(
                get: { sizeDraft ?? scene.tools.size },
                set: { sizeDraft = Self.clampedSize($0) }),
                step: 0.05, unit: .meters,
                commit: { value in
                    bridge?.run(ToolsBpy.size(Self.clampedSize(value)))
                    sizeDraft = nil
                })
            Toggle("Connected Only",
                   isOn: Binding(get: { scene.tools.connected },
                                 set: { bridge?.run(ToolsBpy.connected($0)) }))
                .font(BTheme.Font.ui(11))
            if scene.tools.falloff == .random {
                // The one curve no preview can match: Blender seeds its
                // generator from the clock for every transform.
                Text("Random: Blender draws its own weights when the drag is "
                     + "committed, so the drag shows the reach, not the result.")
                    .font(BTheme.Font.ui(10)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func clampedSize(_ value: Float) -> Float {
        min(max(value, TransformToolSettings.sizeRange.lowerBound),
            TransformToolSettings.sizeRange.upperBound)
    }

    // MARK: the 3D cursor

    private var cursorPanel: some View {
        BPanel("3D Cursor") {
            ForEach(0..<3, id: \.self) { i in
                BNumberField(["Location X", "Location Y", "Location Z"][i],
                             value: Binding(get: { (cursorDraft ?? scene.cursor)[i] },
                                            set: { value in
                                                var next = cursorDraft ?? scene.cursor
                                                next[i] = value
                                                cursorDraft = next
                                            }),
                             step: 0.01,
                             accent: [BTheme.axisX, BTheme.axisY, BTheme.axisZ][i],
                             unit: .meters,
                             commit: { _ in
                                 bridge?.run(ToolsBpy.setCursor(cursorDraft ?? scene.cursor))
                                 cursorDraft = nil
                             })
            }
            ForEach(SnapAction.allCases) { action in
                if action == SnapAction.allCases.first(where: \.movesCursor) {
                    // Blender's menu has a separator here.
                    Divider().padding(.vertical, 2)
                }
                BButton(action.title, icon: action.movesCursor ? "scope" : "magnet") {
                    bridge?.run(ToolsBpy.snap(action, increment: increment), undo: action.undoName)
                }
                .disabled(!action.isOffered(in: scene))
            }
        }
    }

    // MARK: pieces

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            Spacer(minLength: 4)
            content()
        }
        .frame(height: BTheme.Metric.rowHeight)
    }

    private func chip(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
            Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(BTheme.textDim)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(BTheme.widget)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    private func checkRow(_ label: String, on: Bool, note: String?,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(on ? BTheme.select : BTheme.textDim)
                Text(label).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.text)
                Spacer(minLength: 4)
                if let note {
                    Text(note).font(BTheme.Font.ui(9)).foregroundStyle(BTheme.textDim)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
