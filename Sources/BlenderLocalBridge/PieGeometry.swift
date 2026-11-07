import CoreGraphics
import Foundation

/// The eight places of a Blender pie menu (`RadialDirection`, interface_intern.hh,
/// 5.2.1), in the order Blender fills them (`radial_dir_order`, interface.cc): a
/// pie's first item goes left, the second right, then bottom, top, top-left,
/// top-right, bottom-left and bottom-right. That is why Z's Shading pie has
/// Wireframe on the left and Rendered at the top: they are the first and fourth
/// values of the shading type.
public enum PieDirection: Int, CaseIterable, Sendable {
    case west, east, south, north, northWest, northEast, southWest, southEast

    /// Blender's angle (`radial_dir_to_angle`), in degrees counter-clockwise
    /// from the right, with y up.
    public var degrees: Double {
        switch self {
        case .north:     return 90
        case .northEast: return 45
        case .east:      return 0
        case .southEast: return 315
        case .south:     return 270
        case .southWest: return 225
        case .west:      return 180
        case .northWest: return 135
        }
    }

    /// The direction on a screen, where y grows downwards.
    public var unit: CGVector {
        let a = degrees * .pi / 180
        return CGVector(dx: cos(a), dy: -sin(a))
    }

    /// The number key that picks it, laid out as a numpad (`CASE_NUM_TO_DIR`,
    /// interface_handlers.cc): 4 left, 6 right, 2 bottom, 8 top, 7, 9, 1 and 3
    /// the corners. Both the number row and the numpad's keys pick.
    public var digit: Int {
        switch self {
        case .southWest: return 1
        case .south:     return 2
        case .southEast: return 3
        case .west:      return 4
        case .east:      return 6
        case .northWest: return 7
        case .north:     return 8
        case .northEast: return 9
        }
    }

    public static func forDigit(_ digit: Int) -> PieDirection? {
        allCases.first { $0.digit == digit }
    }

    /// The place of a pie's item, by its position in the menu; nil past the
    /// eighth (`PIE_MAX_ITEMS`), which Blender does not draw either.
    public static func forItem(_ index: Int) -> PieDirection? {
        PieDirection(rawValue: index)
    }

    /// Top, bottom, left and right, rather than a corner.
    public var isAxisAligned: Bool {
        switch self {
        case .north, .south, .east, .west: return true
        default: return false
        }
    }
}

/// Where a pie's items go and which one the pointer is choosing, as Blender
/// lays them out (`LayoutRadial::resolve_impl`, interface_layout.cc) and reads
/// the pointer (`block_calc_pie_segment`, interface_handlers.cc;
/// `but_isect_pie_seg`, interface_query.cc), with the Preferences' factory
/// values read from 5.2.1 (`preferences.view`): Radius 100, Threshold 12, Tap
/// Key Timeout 20 (hundredths of a second), Confirm Threshold 0.
public enum PieGeometry {
    /// `pie_menu_radius`: from the middle to each item's near edge.
    public static let radius: CGFloat = 100
    /// `pie_menu_threshold`: nearer the middle than this, nothing is chosen.
    public static let threshold: CGFloat = 12
    /// The ring around the middle runs from the threshold to 7 further out
    /// (`draw_pie_center`).
    public static let ringWidth: CGFloat = 7
    /// `pie_tap_timeout`: a key let go sooner than this, without the pointer
    /// having moved, leaves the pie open to be clicked (`PIE_CLICK_STYLE`);
    /// later, letting go chooses what the pointer points at.
    public static let tapTimeout: TimeInterval = 0.2
    /// `PIE_CLICK_THRESHOLD_SQ` is 50: past √50 from where the pie opened, the
    /// pointer is steering it (`PIE_DRAG_STYLE`), and letting go of the key
    /// chooses even within the tap timeout.
    public static let dragDistance: CGFloat = 50.squareRoot()
    /// An item is 1.5 rows tall (`rect.ymax *= 1.5`).
    public static let itemHeight: CGFloat = 30
    /// The title sits centred over the middle, its foot this far above it
    /// (`pie_menu_threshold + 9`).
    public static let titleGap: CGFloat = 21

    /// An item's frame. Blender puts the point `radius` along the item's
    /// direction, then hangs the item off it: to the right of it on the right,
    /// to the left on the left, centred on it at the top and bottom; above it
    /// at the top, below at the bottom, centred on it otherwise.
    public static func frame(_ direction: PieDirection, size: CGSize, center: CGPoint) -> CGRect {
        let v = direction.unit
        let point = CGPoint(x: center.x + v.dx * radius, y: center.y + v.dy * radius)
        let fx: CGFloat = v.dx > 0.01 ? 0 : (v.dx < -0.01 ? -1 : -0.5)
        // Blender's y grows upwards: its "above" is a smaller y here.
        let fy: CGFloat = v.dy < -0.99 ? -1 : (v.dy > 0.99 ? 0 : -0.5)
        return CGRect(x: point.x + fx * size.width, y: point.y + fy * size.height,
                      width: size.width, height: size.height)
    }

    /// The title's frame: centred over the middle, its foot `titleGap` above.
    public static func titleFrame(size: CGSize, center: CGPoint) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - titleGap - size.height,
               width: size.width, height: size.height)
    }

    /// The direction the pointer chooses among the ones that have an item:
    /// none within `threshold` of the middle; otherwise the one nearest the
    /// pointer's direction, if it is within 45° of it. That is Blender's rule
    /// (`but_isect_pie_seg`): an item owns ±22.5° when its neighbour has an
    /// item too and ±45° when the neighbour is empty — the nearest item, with
    /// nothing past 45°. An exact tie (the pointer on a boundary) goes to one
    /// of the two every time, as Blender's tie breaker does.
    public static func pick(pointer: CGPoint, center: CGPoint, present: Set<PieDirection>) -> PieDirection? {
        let dx = pointer.x - center.x, dy = pointer.y - center.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= threshold else { return nil }
        let ux = dx / length, uy = dy / length
        var best: (direction: PieDirection, cos: CGFloat)?
        for direction in PieDirection.allCases where present.contains(direction) {
            let v = direction.unit
            let c = ux * v.dx + uy * v.dy
            if let b = best, c < b.cos || (c == b.cos && direction.rawValue < b.direction.rawValue) { continue }
            best = (direction, c)
        }
        // cos 45° (Blender's `angle_4th_cos`, with its bias).
        guard let best, best.cos >= CGFloat(0.5.squareRoot()) - 1e-4 else { return nil }
        return best.direction
    }

    /// How wide the lit arc of the ring is (`draw_pie_center`): a quarter turn,
    /// or an eighth when the pie has items both on the axes and in the corners.
    public static func arcRange(present: Set<PieDirection>) -> Double {
        let aligned = present.contains { $0.isAxisAligned }
        let diagonal = present.contains { !$0.isAxisAligned }
        return aligned && diagonal ? .pi / 4 : .pi / 2
    }

    /// Where the middle goes so that every item and the title fit in `bounds`
    /// with `margin` to spare: the pointer's point, moved in from an edge as
    /// Blender moves a pie that would not fit.
    public static func center(anchor: CGPoint, frames: [CGRect], in bounds: CGSize,
                              margin: CGFloat = 4) -> CGPoint {
        guard let first = frames.first else { return anchor }
        // The frames are laid out around `anchor`; take their extent from it.
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        var c = anchor
        let left = union.minX - margin, right = union.maxX + margin
        let top = union.minY - margin, bottom = union.maxY + margin
        if right - left > bounds.width {
            c.x += (bounds.width - (left + right)) / 2
        } else if left < 0 {
            c.x -= left
        } else if right > bounds.width {
            c.x -= right - bounds.width
        }
        if bottom - top > bounds.height {
            c.y += (bounds.height - (top + bottom)) / 2
        } else if top < 0 {
            c.y -= top
        } else if bottom > bounds.height {
            c.y -= bottom - bounds.height
        }
        return c
    }

    /// What letting go of the key that opened the pie does
    /// (`ui_pie_handler`): within the tap timeout and with the pointer not yet
    /// steering, the pie stays open for a click (Blender's click style);
    /// otherwise it chooses what the pointer points at, or closes when that is
    /// nothing.
    public enum Release: Equatable, Sendable {
        case stayOpen
        case choose(PieDirection)
        case close
    }

    public static func release(heldFor seconds: TimeInterval, steered: Bool, pointing: PieDirection?) -> Release {
        if seconds < tapTimeout && !steered { return .stayOpen }
        return pointing.map { .choose($0) } ?? .close
    }
}

/// Blender's accelerator keys: the letter each row of a menu or a pie is
/// chosen by, drawn underlined (`menu_block_set_keyaccels`, interface.cc,
/// 5.2.1). Two passes over the rows in order. The first gives a row the first
/// unused letter that starts one of its words — a word being a run of letters,
/// what follows one character after it the next word — so first letters go
/// first across the whole menu; the second gives a row that found none the
/// first unused letter anywhere in it. Rows that take a key are Blender's
/// buttons, menus and pie items, greyed or not (a greyed one's key does
/// nothing); separators and headings take none.
public enum MenuAccelerators {
    /// `titles`: each row's label, nil for a row that takes no key.
    public static func keys(_ titles: [String?]) -> [Character?] {
        var used = Set<UInt8>()
        var keys = [Character?](repeating: nil, count: titles.count)
        for pass in 0..<2 {
            var missing = 0
            for (i, title) in titles.enumerated() {
                guard let title, keys[i] == nil, !title.isEmpty else { continue }
                let bytes = Array(title.utf8)
                var p = 0
                var found: UInt8?
                while p < bytes.count {
                    let c = lower(bytes[p])
                    if c >= 97, c <= 122, !used.contains(c) {
                        found = c
                        break
                    }
                    if pass == 0 {
                        // Over the rest of the word, then the one character
                        // after it (`isalpha`, C's: ASCII letters only).
                        while p < bytes.count, isLetter(bytes[p]) { p += 1 }
                        if p < bytes.count { p += 1 }
                    } else {
                        p += 1
                    }
                }
                if let found {
                    used.insert(found)
                    keys[i] = Character(UnicodeScalar(found))
                } else {
                    missing += 1
                }
                if used.count == 26 { return keys }
            }
            if missing == 0 { break }
        }
        return keys
    }

    /// Where Blender underlines `key` in `title`: its first capital, else its
    /// first lower case (`widget_draw_text`); nil when neither is there.
    public static func underline(_ key: Character, in title: String) -> Range<String.Index>? {
        title.range(of: String(key).uppercased()) ?? title.range(of: String(key))
    }

    private static func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
    private static func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
}
