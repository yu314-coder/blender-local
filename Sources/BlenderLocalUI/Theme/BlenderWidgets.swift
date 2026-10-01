import SwiftUI

// Blender's widget vocabulary, rebuilt as SwiftUI views: flat fills, 4px
// corners, a 1px outline, no shadows or gradients. Matching these primitives is
// what makes the rest of the interface read as Blender rather than as iOS.

/// A header strip — the bar that runs along the top of every Blender editor.
public struct BHeader<Content: View>: View {
    var background: Color
    @ViewBuilder var content: Content

    public init(background: Color = BTheme.header, @ViewBuilder content: () -> Content) {
        self.background = background
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 4) { content }
            .padding(.horizontal, 6)
            .frame(height: BTheme.Metric.headerHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(BTheme.editorOutline)
                    .frame(height: BTheme.Metric.hairline)
            }
    }
}

/// Blender's standard push button.
public struct BButton: View {
    var title: String
    var icon: String?
    var active: Bool = false
    var action: () -> Void

    public init(_ title: String, icon: String? = nil, active: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.active = active; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                if !title.isEmpty { Text(title).font(BTheme.Font.ui(12)) }
            }
            .foregroundStyle(BTheme.text)
            .padding(.horizontal, 9)
            .frame(height: BTheme.Metric.rowHeight)
            .background(active ? BTheme.select : BTheme.widget)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            .overlay {
                RoundedRectangle(cornerRadius: BTheme.Metric.corner)
                    .strokeBorder(BTheme.outline, lineWidth: BTheme.Metric.hairline)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The one action a workspace exists for — Run, in Scripting — filled with
/// the selection orange so it is found without being looked for. Everything
/// else stays a `BButton`: a bar of orange buttons would single out nothing.
public struct BPrimaryButton: View {
    var title: String
    var icon: String?
    var shortcut: String?
    var action: () -> Void

    public init(_ title: String, icon: String? = nil, shortcut: String? = nil,
                action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.shortcut = shortcut; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                Text(title).font(BTheme.Font.ui(12, weight: .semibold))
                if let shortcut { Text(shortcut).font(BTheme.Font.ui(12)).opacity(0.7) }
            }
            // White rather than the theme's text colour: #E6E6E6 on this
            // orange is 2.8:1, too faint for a label; white is 3.5:1.
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(BTheme.select)
            .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// Blender draws menu titles as plain text in the header, not as bordered
/// buttons; this keeps SwiftUI's `Menu` looking that way.
struct BlenderMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .font(BTheme.Font.ui(12))
            .foregroundStyle(BTheme.text)
            .padding(.horizontal, 7)
    }
}

/// A collapsible panel — the building block of the Properties editor and the
/// N-panel, with Blender's disclosure triangle and inset body.
public struct BPanel<Content: View>: View {
    var title: String
    @State private var open: Bool
    @ViewBuilder var content: Content

    public init(_ title: String, open: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self._open = State(initialValue: open)
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(title).font(BTheme.Font.ui(12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(BTheme.text)
                .padding(.horizontal, 8)
                .frame(height: BTheme.Metric.rowHeight)
                .frame(maxWidth: .infinity)
                .background(BTheme.widget.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 4) { content }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// Blender's number field: a dark slider-style field, dragged horizontally to
/// change the value rather than tapped and typed.

// MARK: - Drag feedback

/// Marks a control as draggable, and shows when it is being dragged.
///
/// Every draggable control here already tracked whether a drag was in
/// progress; none of them showed it. A number field scrubs its value when you
/// drag across it, a split handle moves the divider, the timeline scrubs the
/// frame — and all three looked identical mid-gesture to how they look at
/// rest, so there was no way to tell a drag had taken hold. That is worst with
/// a trackpad or a Pencil, where the finger is not on the glass covering the
/// control and giving its own feedback.
///
/// Two signals, so it reads the same way whatever is doing the dragging: the
/// control lifts and takes an accent outline while the drag is live, and
/// `hoverEffect` morphs a trackpad pointer to the control's shape before the
/// drag starts, which is how iPadOS says "this is interactive".
///
/// SwiftUI's `pointerStyle` would give a resize cursor, but every shape worth
/// having — `columnResize`, `rowResize`, `grabIdle` — is marked unavailable on
/// iOS; they are macOS-only. `UIPointerInteraction` is the iPad equivalent and
/// is used on the split handles, where a resize affordance earns its keep.
public struct DraggableControl: ViewModifier {
    var isDragging: Bool
    var corner: CGFloat

    public func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(BTheme.active, lineWidth: 1)
                    .opacity(isDragging ? 1 : 0)
            }
            .background {
                RoundedRectangle(cornerRadius: corner)
                    .fill(BTheme.active.opacity(isDragging ? 0.16 : 0))
            }
            .scaleEffect(isDragging ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: isDragging)
            .hoverEffect(.highlight)
    }
}

public extension View {
    /// See `DraggableControl`.
    func draggableControl(_ isDragging: Bool,
                          corner: CGFloat = BTheme.Metric.corner) -> some View {
        modifier(DraggableControl(isDragging: isDragging, corner: corner))
    }
}

public struct BNumberField: View {
    /// Blender labels its number fields with a unit, and the unit tells you
    /// what the value means at a glance. The unit itself, and the reading and
    /// writing of its text, live in the bridge so they can be tested without
    /// a screen.
    public typealias Unit = NumberFieldUnit

    var label: String
    @Binding var value: Float
    var step: Float = 0.01
    var accent: Color? = nil
    var unit: Unit = .none
    /// Called once when the drag ends, for values that are expensive to write
    /// — a light's power goes to Blender as Python and back through the
    /// mirror, so it is written when the finger lifts rather than per sample.
    var commit: ((Float) -> Void)? = nil

    @State private var dragStart: Float? = nil
    /// The typed value, while it is being typed. Blender's own fields scrub
    /// on a drag and take a number on a click; on a tablet, typing an exact
    /// number is often the only way to get one.
    @State private var lastTranslation: CGFloat = 0
    @State private var typing: String? = nil
    @FocusState private var typingFocused: Bool

    public init(_ label: String, value: Binding<Float>, step: Float = 0.01,
                accent: Color? = nil, unit: Unit = .none,
                commit: ((Float) -> Void)? = nil) {
        self.label = label; self._value = value; self.step = step
        self.accent = accent; self.unit = unit; self.commit = commit
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let accent {
                Rectangle().fill(accent).frame(width: 3)
            }
            Text(label)
                .font(BTheme.Font.ui(11))
                .foregroundStyle(BTheme.textDim)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            if let typed = typing {
                TextField("", text: Binding(get: { typed }, set: { typing = $0 }))
                    .font(BTheme.Font.mono(11))
                    .foregroundStyle(BTheme.text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($typingFocused)
                    .onSubmit { finishTyping() }
                    .padding(.trailing, 8)
                    .frame(maxWidth: 90)
            } else {
                Text(unit.format(value))
                    .font(BTheme.Font.mono(11))
                    .foregroundStyle(dragStart == nil ? BTheme.text : BTheme.active)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 22)
        .background(BTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: BTheme.Metric.corner))
        // Blender puts a pair of arrows on a number field to say it scrubs.
        // They appear once the drag is live rather than always, so a column of
        // fields at rest stays readable.
        .overlay {
            if dragStart != nil {
                HStack {
                    Image(systemName: "chevron.compact.left")
                    Spacer()
                    Image(systemName: "chevron.compact.right")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BTheme.active)
                // Clear of the axis colour strip on the left and the value on
                // the right, so the arrows read as arrows and not as clutter.
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
                    if typing != nil { return }
                    if dragStart == nil { dragStart = value }
                    // A finger cannot cross the screen between two frames. A
                    // jump that big is a stray event, and following it sets
                    // the value to something absurd — which is how a drag of
                    // a light's power landed on zero.
                    guard abs(g.translation.width - lastTranslation) < 400 || lastTranslation == 0 else {
                        lastTranslation = g.translation.width
                        return
                    }
                    lastTranslation = g.translation.width
                    value = (dragStart ?? value) + Float(g.translation.width) * step
                }
                .onEnded { _ in
                    lastTranslation = 0
                    guard typing == nil else { return }
                    dragStart = nil
                    commit?(value)
                }
        )
        // Scrubbing is a drag and typing is a tap, so without this the field
        // cannot be used by VoiceOver — or by anything else driving the app.
        // Adjustable is what Blender's own fields are: step up, step down.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(unit.format(value))
        // VoiceOver's double tap, and what a tap does by hand: type a number.
        .accessibilityAction {
            typing = unit.editable(value)
            typingFocused = true
        }
        .accessibilityAdjustableAction { direction in
            let amount = step * 10
            value += direction == .increment ? amount : -amount
            commit?(value)
        }
        // A tap types. The drag gesture takes anything that moves, so this
        // only fires on a tap that stayed put.
        .onTapGesture {
            guard typing == nil else { return }
            typing = unit.editable(value)
            typingFocused = true
        }
        .onChange(of: typingFocused) { _, focused in
            // Tapping elsewhere keeps what was typed, as Blender does.
            if !focused, typing != nil { finishTyping() }
        }
    }

    private func finishTyping() {
        defer { typing = nil; typingFocused = false }
        guard let text = typing, let number = unit.typed(text),
              number != value else { return }
        value = number
        commit?(number)
    }
}

/// A single row in the Outliner.
public struct BOutlinerRow: View {
    var icon: String
    var name: String
    var depth: Int
    var selected: Bool
    var action: () -> Void

    public init(icon: String, name: String, depth: Int = 0, selected: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.name = name; self.depth = depth
        self.selected = selected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(depth) * 14)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? BTheme.active : BTheme.textDim)
                Text(name)
                    .font(BTheme.Font.ui(12))
                    .foregroundStyle(selected ? BTheme.active : BTheme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(selected ? BTheme.select.opacity(0.22) : .clear)
        }
        .buttonStyle(.plain)
    }
}

/// The hairline Blender draws between adjacent editors.
public struct BEditorDivider: View {
    var axis: Axis
    public init(_ axis: Axis) { self.axis = axis }
    public var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.5))
            .frame(
                width:  axis == .vertical   ? BTheme.Metric.hairline : nil,
                height: axis == .horizontal ? BTheme.Metric.hairline : nil
            )
    }
}
