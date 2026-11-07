import GameController
import SwiftUI
import UIKit

/// Blender's pie menus — Z's Shading, `'s View, Shift+S's Snap, Period's Pivot
/// Point, Comma's Orientation, Ctrl+Tab's Mode, Shift+O's Proportional Editing
/// Falloff — drawn round the pointer as Blender draws them
/// (`wm.call_menu_pie`): each item in its place (PieGeometry), a ring in the
/// middle lit towards the pointer, the title over the ring.
///
/// Used as Blender's is:
/// - Point and click: the item the pointer points at lights; a click anywhere
///   chooses it, a click in the middle closes the pie.
/// - Hold the key, point, let go: letting go chooses. A key let go within
///   0.2 s without the pointer moving leaves the pie open for a click
///   (`pie_tap_timeout`).
/// - The number keys choose by place, as a numpad lies: 4 left, 6 right, 8
///   top, 2 bottom, 7 9 1 3 the corners. Return chooses what is lit; Escape
///   closes.
/// - A finger: tap an item, or touch down and slide towards one, then lift.
struct PieMenuOverlay: View {
    let model: PopupMenuModel
    let dismiss: () -> Void

    @State private var pointer: CGPoint?
    @State private var sizes: [Int: CGSize] = [:]
    @State private var titleSize: CGSize = .zero
    @State private var area: CGSize = .zero
    /// Blender's PIE_CLICK_STYLE: the key is up and a click chooses.
    @State private var clickStyle = false
    /// PIE_DRAG_STYLE: the pointer has moved since the pie opened.
    @State private var dragStyle = false
    @State private var openedAt = Date()
    /// 0 with the items in the middle, 1 in their places: Blender's opening
    /// animation (`pie_animation_timeout`, 6 hundredths).
    @State private var spread: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "bk-pie"

    /// Blender's pie colours (`wcol_pie_menu`, the default theme in 5.2.1).
    static let inner = Color(hex: 0x181818)
    static let innerSelected = Color(hex: 0x4772B3)
    static let item = Color(hex: 0x545454)
    static let outline = Color(hex: 0x242424)
    static let text = Color(hex: 0xD9D9D9)

    /// The items in their places; a separator keeps its place empty, as in
    /// Blender.
    private var slots: [(direction: PieDirection, index: Int, item: PopupItem)] {
        model.items.prefix(8).enumerated().compactMap { i, item in
            guard let direction = PieDirection.forItem(i) else { return nil }
            switch item.kind {
            case .action, .submenu: return (direction, i, item)
            default: return nil
            }
        }
    }

    private var present: Set<PieDirection> { Set(slots.map(\.direction)) }

    /// Each slot's accelerator, by item index: Blender's pies have them too
    /// (BLOCK_NUMSELECT in interface_region_menu_pie.cc), a letter choosing
    /// its item at once (`ui_pie_handler`).
    private var accelerators: [Int: Character] {
        let keys = MenuAccelerators.keys(slots.map(\.item.title))
        var out: [Int: Character] = [:]
        for (slot, key) in zip(slots, keys) { if let key { out[slot.index] = key } }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let center = middle(in: geo.size)
            let lit = pointer.flatMap { PieGeometry.pick(pointer: $0, center: center, present: present) }
            ZStack(alignment: .topLeading) {
                // Anything outside the items chooses what the pointer points
                // at, or closes the pie in the middle — a finger's touch steers
                // as it slides and chooses where it lifts.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { move(to: $0.location) }
                        .onEnded { click(at: $0.location, center: center) })
                ring(center: center, lit: lit)
                if let title = model.title, !title.isEmpty {
                    titleView(title)
                        .offset(at(PieGeometry.titleFrame(size: titleSize, center: center), center: center))
                }
                ForEach(slots, id: \.index) { slot in
                    let size = sizes[slot.index] ?? .zero
                    itemView(slot.item, lit: lit == slot.direction, digit: slot.direction.digit,
                             accelerator: accelerators[slot.index])
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { sizes[slot.index] = g.size }
                                .onChange(of: g.size) { _, s in sizes[slot.index] = s }
                        })
                        .onTapGesture { choose(slot.item) }
                        .offset(at(PieGeometry.frame(slot.direction, size: size, center: center), center: center))
                }
                keys(center: center, lit: lit)
            }
            .opacity(sizes.count < slots.count ? 0 : 1)
            .coordinateSpace(name: Self.space)
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case .active(let p) = phase { move(to: p) }
            }
            .onAppear { area = geo.size }
            .onChange(of: geo.size) { _, s in area = s }
            .onReceive(NotificationCenter.default.publisher(for: PieKeys.released)) { note in
                guard let usage = note.userInfo?["usage"] as? Int else { return }
                keyReleased(usage, center: center, lit: lit)
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: PieKeys.testPointer)) { note in
                // `-menu-ops pie-point:x,y`: the pointer, in the 3D View's
                // coordinates, as the pie's own (the overlay covers the window;
                // the hook passes the window point).
                if let p = note.userInfo?["point"] as? CGPoint { move(to: p) }
            }
            #endif
        }
        .onAppear(perform: open)
        .onDisappear { PieKeys.stopWatching() }
    }

    // MARK: geometry

    /// The middle: where the pie was asked for, moved in from an edge so that
    /// every item fits.
    private func middle(in bounds: CGSize) -> CGPoint {
        let anchor = model.anchor
        var frames = slots.map { PieGeometry.frame($0.direction, size: sizes[$0.index] ?? .zero, center: anchor) }
        if model.title != nil { frames.append(PieGeometry.titleFrame(size: titleSize, center: anchor)) }
        let ring = PieGeometry.threshold + PieGeometry.ringWidth
        frames.append(CGRect(x: anchor.x - ring, y: anchor.y - ring, width: 2 * ring, height: 2 * ring))
        return PieGeometry.center(anchor: anchor, frames: frames, in: bounds)
    }

    /// A frame's top-left, as an offset from the overlay's, with the frame
    /// drawn `spread` of the way out from the pie's middle (placed as the
    /// pop-up menus place theirs, from the top-left).
    private func at(_ frame: CGRect, center: CGPoint) -> CGSize {
        let midX = center.x + (frame.midX - center.x) * spread
        let midY = center.y + (frame.midY - center.y) * spread
        return CGSize(width: midX - frame.width / 2, height: midY - frame.height / 2)
    }

    // MARK: drawing

    private func ring(center: CGPoint, lit: PieDirection?) -> some View {
        let inner = PieGeometry.threshold, outer = PieGeometry.threshold + PieGeometry.ringWidth
        let mid = (inner + outer) / 2
        // Blender lights the arc towards the pointer, not towards the item.
        let angle: Double? = pointer.flatMap { p in
            let dx = p.x - center.x, dy = p.y - center.y
            return (dx * dx + dy * dy).squareRoot() < inner ? nil : atan2(dy, dx)
        }
        let range = PieGeometry.arcRange(present: present)
        return ZStack {
            Circle().stroke(Self.inner, lineWidth: PieGeometry.ringWidth).frame(width: 2 * mid, height: 2 * mid)
            if let angle {
                Path { path in
                    path.addArc(center: CGPoint(x: outer, y: outer), radius: mid,
                                startAngle: .radians(angle - range / 2), endAngle: .radians(angle + range / 2),
                                clockwise: false)
                }
                .stroke(Self.innerSelected, lineWidth: PieGeometry.ringWidth)
                .frame(width: 2 * outer, height: 2 * outer)
            }
            Circle().stroke(Self.outline, lineWidth: 1).frame(width: 2 * inner, height: 2 * inner)
            Circle().stroke(Self.outline, lineWidth: 1).frame(width: 2 * outer, height: 2 * outer)
        }
        .frame(width: 2 * outer, height: 2 * outer)
        .offset(x: center.x - outer, y: center.y - outer)
        .allowsHitTesting(false)
        .opacity(Double(spread))
    }

    private func titleView(_ title: String) -> some View {
        Text(title)
            .font(BTheme.Font.ui(12))
            .foregroundStyle(Self.text)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Self.inner.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Self.outline, lineWidth: 1))
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { titleSize = g.size }
                    .onChange(of: g.size) { _, s in titleSize = s }
            })
            .allowsHitTesting(false)
    }

    /// Blender's pie item (`widget_state_pie_menu_item`): the current value
    /// blue, what the pointer points at grey, the text white on either.
    private func itemView(_ item: PopupItem, lit: Bool, digit: Int, accelerator: Character?) -> some View {
        let fill: Color = item.checked ? Self.innerSelected
            : lit ? (item.enabled ? Self.item : Self.item.opacity(0.25)) : Self.inner
        let text: Color = !item.enabled ? Self.text.opacity(0.5) : (item.checked || lit ? .white : Self.text)
        return HStack(spacing: 6) {
            if let glyph = item.glyph {
                glyph.frame(width: 16, height: 16)
            } else if let icon = item.icon {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
            }
            PopupItem.titled(item.title, key: accelerator).font(BTheme.Font.ui(12.5)).lineLimit(1)
        }
        .foregroundStyle(text)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(minWidth: 96, minHeight: PieGeometry.itemHeight, maxHeight: PieGeometry.itemHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(lit || item.checked ? Color.white.opacity(0.35) : Self.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .fixedSize()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("Key \(digit)"))
    }

    // MARK: input

    private func open() {
        openedAt = Date()
        clickStyle = model.openedByKey == nil
        pointer = model.anchor
        if let key = model.openedByKey { PieKeys.startWatching(key) }
        if reduceMotion {
            spread = 1
        } else {
            withAnimation(.easeOut(duration: 0.06)) { spread = 1 }
        }
    }

    private func move(to p: CGPoint) {
        pointer = p
        let dx = p.x - model.anchor.x, dy = p.y - model.anchor.y
        if !dragStyle, dx * dx + dy * dy > PieGeometry.dragDistance * PieGeometry.dragDistance { dragStyle = true }
    }

    /// A click, or a finger lifted, away from the items.
    private func click(at p: CGPoint, center: CGPoint) {
        move(to: p)
        guard let direction = PieGeometry.pick(pointer: p, center: center, present: present),
              let slot = slots.first(where: { $0.direction == direction }) else {
            dismiss()
            return
        }
        choose(slot.item)
    }

    private func keyReleased(_ usage: Int, center: CGPoint, lit: PieDirection?) {
        guard !clickStyle, let key = model.openedByKey, PieKeys.usage(ofChordKey: key) == usage else { return }
        let outcome = PieGeometry.release(heldFor: Date().timeIntervalSince(openedAt), steered: dragStyle, pointing: lit)
        #if DEBUG
        print(String(format: "[bk] pie key %@ let go after %.2f s: %@", key, Date().timeIntervalSince(openedAt),
                     "\(outcome)"))
        fflush(stdout)
        #endif
        switch outcome {
        case .stayOpen:
            clickStyle = true
            PieKeys.stopWatching()
        case .choose(let direction):
            if let slot = slots.first(where: { $0.direction == direction }) { choose(slot.item) } else { dismiss() }
        case .close:
            dismiss()
        }
    }

    private func choose(_ item: PopupItem) {
        guard item.enabled, case .action(let run) = item.kind else { return }
        dismiss()
        // After the pie has gone, as a menu row runs.
        DispatchQueue.main.async { run() }
    }

    private func digit(_ n: Int) {
        guard let direction = PieDirection.forDigit(n),
              let slot = slots.first(where: { $0.direction == direction }) else { return }
        choose(slot.item)
    }

    private func keys(center: CGPoint, lit: PieDirection?) -> some View {
        ZStack {
            Button("") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            Button("") {
                if let lit, let slot = slots.first(where: { $0.direction == lit }) { choose(slot.item) }
            }
            .keyboardShortcut(.return, modifiers: [])
            ForEach([1, 2, 3, 4, 6, 7, 8, 9], id: \.self) { n in
                Button("") { digit(n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
            // The items' letters; not the held key's own while it is down,
            // whose repeats are no press.
            let held = clickStyle ? nil : model.openerLetter
            ForEach(accelerators.sorted(by: { $0.key < $1.key }).filter { $0.value != held }, id: \.key) { index, letter in
                Button("") {
                    if let slot = slots.first(where: { $0.index == index }) { choose(slot.item) }
                }
                .keyboardShortcut(KeyEquivalent(letter), modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// The key that opened a pie, watched for its release: Blender's pies choose
/// when it is let go. Two sources, either enough: the 3D View's own
/// `pressesEnded`, and the GameController keyboard, which sees a hardware
/// key go up whichever view has the keyboard.
enum PieKeys {
    /// Posted with `usage`, the key's HID usage, when a key goes up.
    static let released = Notification.Name("bk.pie.keyReleased")
    #if DEBUG
    static let testPointer = Notification.Name("bk.pie.testPointer")
    #endif

    /// The chord a key press is running, while it runs: what a pie opened by
    /// it waits to see let go.
    @MainActor static var pressing: String?

    /// Whether anything waits for a key to go up.
    @MainActor private(set) static var watching = false

    /// The HID usage (UIKeyboardHIDUsage, GCKeyCode) of a chord's key: "z",
    /// "shift+s", "accent_grave", "ctrl+tab".
    static func usage(ofChordKey chord: String) -> Int? {
        guard let key = chord.split(separator: "+").last.map(String.init) else { return nil }
        if key.count == 1, let c = key.unicodeScalars.first, ("a"..."z").contains(Character(c)) {
            return 4 + Int(c.value - UnicodeScalar("a").value)
        }
        switch key {
        case "accent_grave": return 53
        case "comma": return 54
        case "period": return 55
        case "tab": return 43
        case "space": return 44
        default: return nil
        }
    }

    @MainActor static func startWatching(_ chord: String) {
        watching = true
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
        input.keyChangedHandler = { _, _, code, pressed in
            guard !pressed else { return }
            let usage = Int(code.rawValue)
            DispatchQueue.main.async {
                #if DEBUG
                print("[bk] pie: the GameController keyboard saw key \(usage) go up"); fflush(stdout)
                #endif
                post(usage)
            }
        }
    }

    @MainActor static func stopWatching() {
        watching = false
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
    }

    /// A key went up (the 3D View's `pressesEnded` calls this too).
    @MainActor static func post(_ usage: Int) {
        guard watching else { return }
        NotificationCenter.default.post(name: released, object: nil, userInfo: ["usage": usage])
    }
}

/// A proportional-editing falloff drawn as Blender's curve icons draw it
/// (SMOOTHCURVE, SPHERECURVE…): the weight from 1 at the selection, on the
/// left, to 0 at the edge of the radius, on the right — the app's own curves
/// (`ProportionalFalloff.curve`), so the icon is the curve a drag uses.
struct FalloffGlyph: View {
    let falloff: MeshEditor.ProportionalFalloff

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let steps = 24
            for i in 0...steps {
                let x = CGFloat(i) / CGFloat(steps)
                // Random's jitter, fixed so the icon does not change.
                let jitter = Float((i * 7919) % 13) / 13
                let w = CGFloat(falloff.curve(Float(1 - x), random: falloff == .random ? 0.35 + 0.65 * jitter : 1))
                let point = CGPoint(x: 1 + x * (size.width - 2), y: 1 + (1 - w) * (size.height - 2))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .foreground, lineWidth: 1.4)
        }
        .accessibilityHidden(true)
    }
}
