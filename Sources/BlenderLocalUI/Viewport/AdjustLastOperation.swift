import SwiftUI

/// Blender's redo panel: the collapsed strip in the bottom-left of the viewport
/// naming the operation that just ran, which opens into its arguments.
///
/// The thing it is for is the gap between asking for a shape and knowing what
/// shape you wanted. A cylinder with thirty-two sides looks like a tube; you
/// find out you wanted twelve by looking at thirty-two. Every other way of
/// changing it — undo, reopen the menu, retype — throws away the look that told
/// you.
///
/// It draws itself over the viewport rather than in a sidebar because in
/// Blender it is a *transient*: it belongs to the last operation and vanishes
/// when the next one starts — or when the operation is undone, since adjusting
/// an undone operation would re-run it over the scene the undo restored.
struct AdjustLastOperation: View {
    var bridge: BpyBridge?

    @AppStorage("bl_redo_expanded") private var expanded = false
    /// The panel edits its own copy and pushes it through the bridge, rather
    /// than binding into the bridge's. A binding would re-run the operator
    /// while SwiftUI was still deciding what the value was.
    @State private var draft: LastOperator?
    @State private var generation = -1
    /// When the operator last re-ran, for the drag throttle.
    @State private var lastRun = Date.distantPast
    /// The re-run the throttle is holding back until the interval is up.
    @State private var trailing: Task<Void, Never>?
    /// A re-run has happened that its undo step does not record yet.
    @State private var unrecorded = false

    /// Re-runs a second while a field is being dragged, at most.
    ///
    /// Every re-run is a full evaluation of the operator and a read-back of the
    /// scene. At one per frame of a drag that was sixty a second, each with a
    /// `.blend` file written for its undo step, and the panel lagged far behind
    /// the finger.
    static let runsPerSecond: Double = 6

    var body: some View {
        Group {
            if let draft, bridge?.adjustable != nil {
                VStack(alignment: .leading, spacing: 0) {
                    header(draft)
                    if expanded {
                        parameters(draft)
                    }
                }
                .frame(width: expanded ? 236 : nil)
                .fixedSize(horizontal: !expanded, vertical: false)
                .background(BTheme.menuBack.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: BTheme.Metric.corner)
                        .strokeBorder(BTheme.outline, lineWidth: BTheme.Metric.hairline)
                )
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
        }
        // The panel belongs to one operation. A new one replaces the draft; the
        // same one being adjusted must not, or the value would snap back to
        // where the drag started on every frame of the drag.
        .onChange(of: bridge?.adjustableGeneration ?? -1, initial: true) { _, new in
            guard new != generation else { return }
            generation = new
            trailing?.cancel()
            trailing = nil
            unrecorded = false
            draft = bridge?.adjustable
        }
        .onDisappear { finishDrag() }
    }

    private func header(_ op: LastOperator) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(BTheme.textDim)
                Text(op.name)
                    .font(BTheme.Font.ui(11, weight: .medium))
                    .foregroundStyle(BTheme.text)
                    .fixedSize()
                // Collapsed, the panel is as wide as its title and no wider —
                // it is sitting on top of the viewport, and a strip spanning
                // the whole width would be a bar rather than a label.
                if expanded { Spacer(minLength: 8) }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func parameters(_ op: LastOperator) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(op.parameters.enumerated()), id: \.element.id) { index, parameter in
                Group {
                    switch parameter.kind {
                    case .choice(let options), .literal(let options):
                        // A literal picks between pieces of Python rather than
                        // between enum names; to a finger it is the same row.
                        choiceRow(parameter, options: options, at: index)
                    case .float, .integer, .nested:
                        // A nested value is what the sub-operator takes — a
                        // distance for Extrude, a factor for Offset Edge Slide;
                        // to a finger it is a number field like any other.
                        RedoNumberField(parameter.label,
                                        value: binding(at: index),
                                        step: Float(parameter.step),
                                        unit: parameter.unit,
                                        onEnded: finishDrag)
                    case .component(_, let heading, let axis):
                        // One argument drawn as the column Blender draws for a
                        // vector — Spin's Center looks like Location does below.
                        if axis == 0 { groupHeading(heading) }
                        RedoNumberField(parameter.label,
                                        value: binding(at: index),
                                        step: Float(parameter.step),
                                        accent: Self.axisColours[min(max(axis, 0), 2)],
                                        unit: .meters,
                                        onEnded: finishDrag)
                    }
                }
                // Greyed, not hidden, while another row makes it inert
                // (`Parameter.activeWhen`), as Blender greys one.
                .opacity(op.isActive(parameter) ? 1 : 0.45)
            }

            // Blender draws Location as a labelled XYZ column, colour-coded to
            // match the gizmo, and so does this. A mesh operator places
            // nothing, so it gets no such column — an inset with a Location on
            // it would be inventing an argument the operator does not take.
            if op.location != nil {
                groupHeading("Location")
                RedoNumberField("X", value: location(0), step: 0.01,
                                accent: BTheme.axisX, unit: .meters, onEnded: finishDrag)
                RedoNumberField("Y", value: location(1), step: 0.01,
                                accent: BTheme.axisY, unit: .meters, onEnded: finishDrag)
                RedoNumberField("Z", value: location(2), step: 0.01,
                                accent: BTheme.axisZ, unit: .meters, onEnded: finishDrag)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private static let axisColours = [BTheme.axisX, BTheme.axisY, BTheme.axisZ]

    /// The dim caption over an XYZ column.
    private func groupHeading(_ title: String) -> some View {
        Text(title)
            .font(BTheme.Font.ui(10))
            .foregroundStyle(BTheme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
    }

    private func choiceRow(_ parameter: LastOperator.Parameter,
                           options: [LastOperator.Parameter.Option],
                           at index: Int) -> some View {
        HStack(spacing: 0) {
            Text(parameter.label)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.textDim)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    Button(option.label) { commit { $0.parameters[index].value = Double(i) } }
                }
            } label: {
                Text(parameter.display)
                    .font(BTheme.Font.mono(11))
                    .foregroundStyle(BTheme.text)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 22)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
    }

    // MARK: bindings

    /// A parameter as a `Float` the scrub field can move, clamped on the way in
    /// to the soft range Blender gives it — the field itself has no notion of a
    /// range, and an unclamped drag reaches a five-hundred-sided circle in
    /// about an inch.
    private func binding(at index: Int) -> Binding<Float> {
        Binding(
            get: { Float(draft?.parameters[index].settled ?? 0) },
            set: { new in
                adjust { op in
                    let p = op.parameters[index]
                    op.parameters[index].value = min(max(Double(new), p.softMin), p.softMax)
                }
            })
    }

    private func location(_ axis: Int) -> Binding<Float> {
        Binding(
            get: { Float(draft?.location?[axis] ?? 0) },
            set: { new in adjust { $0.location?[axis] = Double(new) } })
    }

    // MARK: re-running

    /// One frame of a drag. The field follows the finger at once; Blender
    /// re-runs at most `runsPerSecond` times a second, and the last value
    /// always runs.
    private func adjust(_ change: (inout LastOperator) -> Void) {
        guard let previous = draft else { return }
        var op = previous
        change(&op)
        guard op != previous else { return }
        draft = op
        let wait = 1 / Self.runsPerSecond - Date().timeIntervalSince(lastRun)
        if wait <= 0 {
            trailing?.cancel()
            trailing = nil
            rerun(record: false)
        } else if trailing == nil {
            trailing = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                trailing = nil
                rerun(record: false)
            }
        }
    }

    /// A change that is complete as it is made — a choice from a menu.
    private func commit(_ change: (inout LastOperator) -> Void) {
        guard let previous = draft else { return }
        var op = previous
        change(&op)
        guard op != previous else { return }
        trailing?.cancel()
        trailing = nil
        draft = op
        rerun(record: true)
    }

    /// The drag is over: a value still waiting runs now, and the undo step is
    /// written once for the whole drag.
    private func finishDrag() {
        if trailing != nil {
            trailing?.cancel()
            trailing = nil
            rerun(record: true)
        } else if unrecorded {
            bridge?.recordAdjustment()
            unrecorded = false
        }
    }

    /// Re-runs the draft, keeping whatever Blender named the object it made
    /// this time so the next change removes the right one.
    private func rerun(record: Bool) {
        guard let op = draft, let bridge else { return }
        lastRun = Date()
        // Show what is in the scene, not what was asked for. If the re-run did
        // not happen — the object was deleted from the Outliner, the backup is
        // gone — the fields go back to the values that are still true, because
        // a slider reading 5 next to geometry that is still 32 is a worse
        // answer than a slider that will not move.
        if let updated = bridge.readjust(op, record: record) {
            draft = updated
            unrecorded = !record
        } else if let still = bridge.adjustable {
            draft = still
        }
    }
}

/// The redo panel's number field: Blender's scrubbable field, which also says
/// when the finger lifts, so a drag can be recorded as one step.
private struct RedoNumberField: View {
    var label: String
    @Binding var value: Float
    var step: Float
    var accent: Color?
    var unit: BNumberField.Unit
    var onEnded: () -> Void

    @State private var dragStart: Float?

    init(_ label: String, value: Binding<Float>, step: Float, accent: Color? = nil,
         unit: BNumberField.Unit, onEnded: @escaping () -> Void) {
        self.label = label
        self._value = value
        self.step = step
        self.accent = accent
        self.unit = unit
        self.onEnded = onEnded
    }

    var body: some View {
        HStack(spacing: 0) {
            if let accent {
                Rectangle().fill(accent).frame(width: 3)
            }
            Text(label)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.textDim)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            Text(unit.format(value))
                .font(BTheme.Font.mono(11))
                .foregroundStyle(dragStart == nil ? BTheme.text : BTheme.active)
                .padding(.trailing, 8)
        }
        .frame(height: 22)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        .overlay {
            if dragStart != nil {
                HStack {
                    Image(systemName: "chevron.compact.left")
                    Spacer()
                    Image(systemName: "chevron.compact.right")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BTheme.active)
                .padding(.leading, 8)
                .padding(.trailing, 3)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .draggableControl(dragStart != nil)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    value = (dragStart ?? value) + Float(g.translation.width) * step
                }
                .onEnded { _ in
                    dragStart = nil
                    onEnded()
                }
        )
    }
}
