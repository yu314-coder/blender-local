import CoreGraphics
import Foundation

// Blender's pie menus on the app's side: the order the places fill, the
// number keys, where an item hangs off its point, which item the pointer
// chooses, and what letting go of the key does. Each rule is Blender's own
// (5.2.1): radial_dir_order and radial_dir_to_angle (interface.cc),
// LayoutRadial::resolve_impl (interface_layout.cc), but_isect_pie_seg
// (interface_query.cc), ui_pie_handler (interface_handlers.cc).

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
typealias D = PieDirection
typealias G = PieGeometry

/// A pointer `degrees` counter-clockwise from the right (y up), `distance` out.
func pointer(_ degrees: Double, _ distance: CGFloat = 60, from c: CGPoint = .zero) -> CGPoint {
    let a = degrees * .pi / 180
    return CGPoint(x: c.x + distance * CGFloat(cos(a)), y: c.y - distance * CGFloat(sin(a)))
}

print("== the places fill as Blender's radial_dir_order ==")
check("left, right, bottom, top, then the corners",
      (0..<8).compactMap(D.forItem) == [.west, .east, .south, .north, .northWest, .northEast, .southWest, .southEast])
check("no ninth place (PIE_MAX_ITEMS)", D.forItem(8) == nil)
check("Shading's four values: Wireframe left, Solid right, Material Preview bottom, Rendered top",
      ["Wireframe", "Solid", "Material Preview", "Rendered"].indices.map { D.forItem($0)! } == [.west, .east, .south, .north])

print("== number keys as a numpad (CASE_NUM_TO_DIR) ==")
check("1 2 3 4 6 7 8 9", [1, 2, 3, 4, 6, 7, 8, 9].map { D.forDigit($0)! }
      == [.southWest, .south, .southEast, .west, .east, .northWest, .north, .northEast])
check("5 and 0 pick nothing", D.forDigit(5) == nil && D.forDigit(0) == nil)

print("== where an item goes (resolve_impl's factors) ==")
do {
    let c = CGPoint(x: 500, y: 400), size = CGSize(width: 120, height: 30)
    let e = G.frame(.east, size: size, center: c)
    check("right: its left edge on the radius, centred on the middle's height",
          near(e.minX, 600) && near(e.midY, 400), "\(e)")
    let w = G.frame(.west, size: size, center: c)
    check("left: its right edge on the radius", near(w.maxX, 400) && near(w.midY, 400), "\(w)")
    let n = G.frame(.north, size: size, center: c)
    check("top: its foot on the radius, centred across", near(n.maxY, 300) && near(n.midX, 500), "\(n)")
    let s = G.frame(.south, size: size, center: c)
    check("bottom: its head on the radius", near(s.minY, 500) && near(s.midX, 500), "\(s)")
    let ne = G.frame(.northEast, size: size, center: c)
    let r = 100 * CGFloat(0.5.squareRoot())
    check("top right: left edge at r·cos 45°, centred at r·sin 45° up", near(ne.minX, 500 + r, 1e-4)
          && near(ne.midY, 400 - r, 1e-4), "\(ne)")
    let sw = G.frame(.southWest, size: size, center: c)
    check("bottom left: right edge at -r·cos 45°", near(sw.maxX, 500 - r, 1e-4) && near(sw.midY, 400 + r, 1e-4))
    let t = G.titleFrame(size: CGSize(width: 80, height: 20), center: c)
    check("the title centred over the middle, its foot 21 above", near(t.midX, 500) && near(t.maxY, 379))
}

print("== which item the pointer chooses (but_isect_pie_seg) ==")
do {
    let four: Set<D> = [.west, .east, .south, .north]
    let six: Set<D> = [.west, .east, .south, .north, .northWest, .northEast]
    let eight = Set(D.allCases)
    check("nothing within the threshold", G.pick(pointer: pointer(0, 11.9), center: .zero, present: eight) == nil)
    check("at the threshold, the right", G.pick(pointer: pointer(0, 12), center: .zero, present: eight) == .east)
    check("four items: 44° is still the right", G.pick(pointer: pointer(44), center: .zero, present: four) == .east)
    check("four items: 46° is the top", G.pick(pointer: pointer(46), center: .zero, present: four) == .north)
    check("eight: 20° the right", G.pick(pointer: pointer(20), center: .zero, present: eight) == .east)
    check("eight: 25° the top right", G.pick(pointer: pointer(25), center: .zero, present: eight) == .northEast)
    check("six (View): 300° the bottom, its empty corner beside it",
          G.pick(pointer: pointer(300), center: .zero, present: six) == .south)
    check("six: 340° the right", G.pick(pointer: pointer(340), center: .zero, present: six) == .east)
    check("only the top: pointing down chooses nothing",
          G.pick(pointer: pointer(270), center: .zero, present: [.north]) == nil)
    check("only the top: 50° off chooses nothing", G.pick(pointer: pointer(140), center: .zero, present: [.north]) == nil)
    check("only the top: 40° off chooses it", G.pick(pointer: pointer(130), center: .zero, present: [.north]) == .north)
    let c = CGPoint(x: 300, y: 200)
    check("measured from the middle, not the origin", G.pick(pointer: pointer(90, 50, from: c), center: c, present: four) == .north)
}

print("== the ring's lit arc (draw_pie_center) ==")
check("axes only: a quarter turn", G.arcRange(present: [.west, .east, .south, .north]) == .pi / 2)
check("axes and corners: an eighth", G.arcRange(present: Set(D.allCases)) == .pi / 4)
check("corners only: a quarter turn", G.arcRange(present: [.northWest, .southEast]) == .pi / 2)

print("== a pie at the window's edge moves in ==")
do {
    let size = CGSize(width: 100, height: 30)
    let anchor = CGPoint(x: 20, y: 300)
    let frames = D.allCases.map { G.frame($0, size: size, center: anchor) }
    let c = G.center(anchor: anchor, frames: frames, in: CGSize(width: 1000, height: 800))
    let moved = D.allCases.map { G.frame($0, size: size, center: c) }
    let left = moved.map(\.minX).min()!
    check("its leftmost item is inside, by the margin", near(left, 4, 1e-6), "\(left)")
    check("only across", near(c.y, 300))
    let inside = G.center(anchor: CGPoint(x: 500, y: 400), frames: D.allCases.map {
        G.frame($0, size: size, center: CGPoint(x: 500, y: 400)) }, in: CGSize(width: 1000, height: 800))
    check("one that fits stays where it was", inside == CGPoint(x: 500, y: 400))
    let low = CGPoint(x: 500, y: 790)
    let up = G.center(anchor: low, frames: D.allCases.map { G.frame($0, size: size, center: low) },
                      in: CGSize(width: 1000, height: 800))
    let bottom = D.allCases.map { G.frame($0, size: size, center: up).maxY }.max()!
    check("at the foot it moves up", near(bottom, 796, 1e-6), "\(bottom)")
}

print("== letting go of the key (ui_pie_handler) ==")
check("quickly, not steered: stays open for a click", G.release(heldFor: 0.1, steered: false, pointing: .north) == .stayOpen)
check("quickly but steered: chooses", G.release(heldFor: 0.1, steered: true, pointing: .north) == .choose(.north))
check("held: chooses what it points at", G.release(heldFor: 0.5, steered: false, pointing: .east) == .choose(.east))
check("held, pointing at nothing: closes", G.release(heldFor: 0.5, steered: false, pointing: nil) == .close)
check("steered back to the middle: closes", G.release(heldFor: 0.1, steered: true, pointing: nil) == .close)
check("the tap timeout is 20 hundredths", G.tapTimeout == 0.2)
check("the drag distance is √50", near(G.dragDistance * G.dragDistance, 50, 1e-9))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
