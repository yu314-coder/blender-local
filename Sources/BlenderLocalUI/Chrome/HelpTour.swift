import SwiftUI

/// The help tour: each part of the screen in turn, lit, with a card that says
/// what it is and how a finger uses it. The ? in the top bar opens it, and it
/// opens by itself the first time the app does (the user, November 5: "a
/// help button (first open) show how to use each").
///
/// The parts mark themselves with `.helpAnchor(_:)`; the root view draws the
/// tour over everything with `.helpTourOverlay()`, which finds them through
/// their anchors. A part that is not on screen — the editors closed, the
/// toolbar hidden, the timeline in a workspace without one — is left out of
/// the tour rather than pointed at in the wrong place.

/// The parts of the screen the tour points at, in the tour's order.
enum HelpSpot: Hashable, CaseIterable {
    case toolbar, modifierKeys, modeMenu, headerMenus, transform, editorsToggle, more
    case navigation, sidebarTab, viewport, statusRow, outliner, properties, timeline
    case fileMenu, workspaces, history, help
}

/// One card of the tour.
struct HelpStep {
    /// The part it lights; none for the welcome card, which sits in the middle.
    var spot: HelpSpot?
    var icon: String
    var title: String
    var text: String

    /// Every card, in order. The names of Blender's parts are Blender's own
    /// (5.2.1); the app's own parts (Image to 3D, the Shift/Ctrl/Alt keys,
    /// More) keep the app's names.
    static let all: [HelpStep] = [
        HelpStep(spot: nil, icon: "cube.transparent", title: "Welcome to Blender Local",
                 text: "Real Blender, made for touch. This tour lights each part of the screen and says how to use it. "
                     + "Tap Next to go on, or Skip to start; the ? button at the top brings the tour back."),
        HelpStep(spot: .toolbar, icon: "hand.point.up.left", title: "Toolbar",
                 text: "Pick a tool, then use it in the 3D Viewport. The first button holds the select tools: "
                     + "Tweak, Select Box, Select Circle and Select Lasso. Move, Rotate and Scale drag what is selected. "
                     + "In Object Mode, Image to 3D turns a photo into a model."),
        HelpStep(spot: .modifierKeys, icon: "shift", title: "Shift, Ctrl and Alt",
                 text: "The keyboard's keys, for a finger. Turn Shift on and each tap adds an object to the selection, "
                     + "or takes it away again. Tap Shift once more to turn it off."),
        HelpStep(spot: .modeMenu, icon: "square.on.square", title: "Mode",
                 text: "Object Mode works on whole objects. Edit Mode works on a mesh's vertices, edges and faces, "
                     + "and Sculpt Mode shapes it with brushes. With a keyboard, Tab switches between Object and Edit Mode."),
        HelpStep(spot: .headerMenus, icon: "menubar.rectangle", title: "Header menus",
                 text: "Blender's menus for the mode: Select, Add, Object and Mesh in Object Mode. "
                     + "Add puts a new object at the 3D cursor. Object ▸ Transform ▸ Move, Rotate and Scale "
                     + "follow your finger anywhere in the view until you tap; the bar over the view locks X, Y or Z. "
                     + "When the row is too long, swipe it sideways."),
        HelpStep(spot: .transform, icon: "move.3d", title: "Transform settings",
                 text: "The orientation, the pivot point, snapping and proportional editing, in one button. "
                     + "What is turned on shows in orange."),
        HelpStep(spot: .editorsToggle, icon: "sidebar.right", title: "Outliner and Properties",
                 text: "Shows or hides the two editors beside the 3D Viewport, to give the view the whole screen."),
        HelpStep(spot: .more, icon: "ellipsis", title: "More",
                 text: "The view's own settings: Frame All, Local View, Viewport Shading, X-Ray, the overlays and the Sidebar."),
        HelpStep(spot: .navigation, icon: "rotate.3d", title: "Navigate",
                 text: "Tap a ball on the axis gizmo to look along that axis. Drag the magnifier to zoom and the hand "
                     + "to move the view. Under them: Toggle Camera View, Perspective or Orthographic, and Frame All."),
        HelpStep(spot: .sidebarTab, icon: "chevron.left", title: "Sidebar",
                 text: "Opens the Sidebar: the active object's numbers in Item, the tool's settings in Tool, "
                     + "and the view's in View. Its × closes it again."),
        HelpStep(spot: .viewport, icon: "cube", title: "3D Viewport",
                 text: "Tap to select. Drag to rotate the view, or to use the tool in hand. "
                     + "Two fingers move the view and a pinch zooms. With a trackpad or mouse, a right-click opens the context menu. "
                     + "With a keyboard, G, R and S move, rotate and scale the selection: X, Y or Z locks an axis, "
                     + "a number sets the amount, Return confirms and Esc cancels."),
        HelpStep(spot: .statusRow, icon: "hand.tap", title: "What a touch does",
                 text: "This row says what a tap and a drag will do with the tool in hand, "
                     + "and shows the numbers while you drag."),
        HelpStep(spot: .outliner, icon: "list.bullet.indent", title: "Outliner",
                 text: "Every object in the scene. Tap a row to select it and tap it twice to rename it; "
                     + "the eye hides it. Hold a row for Delete and its other commands."),
        HelpStep(spot: .properties, icon: "slider.horizontal.3", title: "Properties",
                 text: "The active object's settings, by the tabs down its left side: Object, Modifiers, "
                     + "Constraints, Data, Material and Scene. Tap a tab to open it."),
        HelpStep(spot: .timeline, icon: "play.rectangle", title: "Timeline",
                 text: "Play the animation, move to any frame, and insert keyframes."),
        HelpStep(spot: .fileMenu, icon: "doc", title: "File",
                 text: "New, Open, Save, Import and Export. Your .blend files are in the Blender Local folder of the Files app."),
        HelpStep(spot: .workspaces, icon: "rectangle.split.2x1", title: "Layout and Scripting",
                 text: "Layout is for modelling. Scripting is for Python: the Python Console, a terminal and the Text Editor."),
        HelpStep(spot: .history, icon: "arrow.uturn.backward", title: "Undo and Redo",
                 text: "Undo and Redo, and beside them what the last command did."),
        HelpStep(spot: .help, icon: "questionmark.circle", title: "Help",
                 text: "Opens this tour again, and is where to send feedback or report a bug."),
    ]
}

/// Whether the tour is showing, and which card.
@Observable final class HelpTour {
    static let shared = HelpTour()

    /// The card showing, as an index into the cards whose part is on screen;
    /// nil while the tour is closed.
    var step: Int?

    /// Set once the tour has been closed, by Skip or Done.
    static let seenKey = "bl_help_tour_seen"

    func start(at step: Int = 0) {
        self.step = step
        #if DEBUG
        print("[bk] help-tour open at \(step)")
        fflush(stdout)
        #endif
    }

    func close() {
        step = nil
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }

    /// The first launch: the tour has never been closed, and the app was
    /// opened as a person opens it. A launch with the app's own arguments
    /// (`-ui-audit`, `-feature-test` and the rest) is a test, and a tour
    /// over it would cover what the test looks at.
    static var opensAtLaunch: Bool {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return false }
        return !ProcessInfo.processInfo.arguments.dropFirst().contains { arg in
            arg.hasPrefix("-") && !arg.hasPrefix("-NS") && !arg.hasPrefix("-Apple")
        }
    }
}

struct HelpAnchorKey: PreferenceKey {
    static let defaultValue: [HelpSpot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [HelpSpot: Anchor<CGRect>], nextValue: () -> [HelpSpot: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a part the help tour points at. Merged with what
    /// the view's children mark, so a part may hold other parts.
    func helpAnchor(_ spot: HelpSpot) -> some View {
        transformAnchorPreference(key: HelpAnchorKey.self, value: .bounds) { parts, anchor in
            parts[spot] = anchor
        }
    }

    /// Draws the help tour over this view, which must hold every part it
    /// points at.
    func helpTourOverlay() -> some View {
        overlayPreferenceValue(HelpAnchorKey.self) { anchors in
            GeometryReader { proxy in
                HelpTourOverlay(anchors: anchors, proxy: proxy)
            }
        }
    }
}

private struct HelpTourOverlay: View {
    var anchors: [HelpSpot: Anchor<CGRect>]
    var proxy: GeometryProxy
    var tour = HelpTour.shared
    @State private var cardSize = CGSize(width: 340, height: 200)

    /// The cards whose part is on screen, and the welcome card.
    private var steps: [HelpStep] {
        HelpStep.all.filter { step in
            guard let spot = step.spot else { return true }
            guard let anchor = anchors[spot] else { return false }
            let r = proxy[anchor]
            return r.width > 1 && r.height > 1
        }
    }

    var body: some View {
        if let index = tour.step {
            let steps = steps
            let i = min(max(index, 0), steps.count - 1)
            let step = steps[i]
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let lit = step.spot.flatMap { anchors[$0] }.map { proxy[$0].insetBy(dx: -5, dy: -5) }
                .map { $0.intersection(bounds.insetBy(dx: 2, dy: 2)) }
            ZStack(alignment: .topLeading) {
                // Everything dimmed but the part; a tap anywhere outside the
                // card goes on, as a tap on a slide does.
                Path { path in
                    path.addRect(bounds)
                    if let lit { path.addRoundedRect(in: lit, cornerSize: CGSize(width: 10, height: 10)) }
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture { next(count: steps.count, from: i) }
                if let lit {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(BTheme.select, lineWidth: 2.5)
                        .frame(width: lit.width, height: lit.height)
                        .offset(x: lit.minX, y: lit.minY)
                        .allowsHitTesting(false)
                }
                card(step, index: i, count: steps.count)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                    .offset(cardOrigin(for: lit, in: bounds))
            }
            .animation(.easeInOut(duration: 0.22), value: i)
            .accessibilityAddTraits(.isModal)
            .transition(.opacity)
        }
    }

    private func next(count: Int, from i: Int) {
        if i + 1 < count { tour.step = i + 1 } else { tour.close() }
    }

    /// Where the card goes: under the part when there is room, else over it,
    /// else beside it, else in the middle of it (the 3D Viewport, which leaves no
    /// room around it). Always inside the window.
    private func cardOrigin(for lit: CGRect?, in bounds: CGRect) -> CGSize {
        let margin: CGFloat = 12, gap: CGFloat = 14
        let w = cardSize.width, h = cardSize.height
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, margin), max(bounds.width - w - margin, margin)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, margin), max(bounds.height - h - margin, margin)) }
        guard let r = lit else {
            return CGSize(width: (bounds.width - w) / 2, height: (bounds.height - h) / 2)
        }
        if r.maxY + gap + h <= bounds.height - margin {
            return CGSize(width: clampX(r.midX - w / 2), height: r.maxY + gap)
        }
        if r.minY - gap - h >= margin {
            return CGSize(width: clampX(r.midX - w / 2), height: r.minY - gap - h)
        }
        if r.maxX + gap + w <= bounds.width - margin {
            return CGSize(width: r.maxX + gap, height: clampY(r.midY - h / 2))
        }
        if r.minX - gap - w >= margin {
            return CGSize(width: r.minX - gap - w, height: clampY(r.midY - h / 2))
        }
        return CGSize(width: clampX(r.midX - w / 2), height: clampY(r.midY - h / 2))
    }

    private func card(_ step: HelpStep, index i: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: step.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(BTheme.select, in: Circle())
                Text(step.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BTheme.text)
                Spacer(minLength: 8)
                Text("\(i + 1) of \(count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(BTheme.textDim)
            }
            Text(step.text)
                .font(.system(size: 14))
                .foregroundStyle(BTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            // How far along: a dot a card.
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { d in
                    Capsule()
                        .fill(d == i ? BTheme.select : BTheme.textDim.opacity(0.35))
                        .frame(width: d == i ? 14 : 5, height: 5)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Button("Skip") { tour.close() }
                    .buttonStyle(HelpCardButton(prominent: false))
                    .keyboardShortcut(.cancelAction)
                    .opacity(i + 1 < count ? 1 : 0)
                    .disabled(i + 1 >= count)
                Spacer(minLength: 0)
                if i > 0 {
                    Button("Back") { tour.step = i - 1 }
                        .buttonStyle(HelpCardButton(prominent: false))
                }
                Button(i + 1 < count ? "Next" : "Done") { next(count: count, from: i) }
                    .buttonStyle(HelpCardButton(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: min(360, proxy.size.width - 24))
        .background(BTheme.header, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(BTheme.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }
}

/// The card's buttons: a finger's height, Next filled.
private struct HelpCardButton: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : BTheme.text)
            .padding(.horizontal, 18)
            .frame(minWidth: 72, minHeight: 44)
            .background(prominent ? BTheme.select : BTheme.outline.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
