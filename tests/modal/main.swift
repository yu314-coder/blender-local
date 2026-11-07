import Foundation

// Blender's G, R and S on the keyboard's side: X, Y and Z and Shift with them
// cycling the orientation as `transform_event_xyz_constraint` does (5.2.1),
// and the typed numbers (NumInput). The drag itself is the gizmo's, held to
// Blender by the gizmo and tools checks.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
typealias M = ModalTransformInput

print("== X, Y, Z: the scene's orientation, the other, none ==")
do {
    var m = M(mode: .translate)
    m.press(axis: 0, plane: false)
    check("X once: X in the scene's", m.constraint == .axis(0, .scene))
    m.press(axis: 0, plane: false)
    check("X twice: X in the other", m.constraint == .axis(0, .alternate))
    m.press(axis: 0, plane: false)
    check("X three times: none", m.constraint == .none)
    m.press(axis: 0, plane: false)
    check("a fourth: the scene's again", m.constraint == .axis(0, .scene))
}
do {
    var m = M(mode: .translate)
    m.press(axis: 0, plane: false)
    m.press(axis: 0, plane: false)
    m.press(axis: 1, plane: false)
    check("another letter starts at the scene's", m.constraint == .axis(1, .scene))
    m.press(axis: 2, plane: true)
    check("Shift+Z: the XY plane, the scene's", m.constraint == .plane(2, .scene))
    check("its free axes are X and Y", m.constraint.freeAxes == [0, 1])
    m.press(axis: 2, plane: false)
    check("Z after Shift+Z: the same letter, so the other orientation, on the axis",
          m.constraint == .axis(2, .alternate))
    m.press(axis: 2, plane: true)
    check("Shift+Z then: none", m.constraint == .none)
}

print("== typed numbers ==")
do {
    var m = M(mode: .translate)
    check("nothing typed: the pointer decides", !m.isTyping && m.values == nil)
    m.type("2")
    check("G 2: X 2, Y and Z 0", m.values == [2, 0, 0], "\(String(describing: m.values))")
    check("shown with the caret on X", m.shownValues == ["[2|]", "0", "0"], "\(m.shownValues)")
    m.nextValue()
    m.type("1"); m.type("."); m.type("5"); m.type(".")
    check("Tab, 1.5: Y 1.5 (a second point ignored)", m.values == [2, 1.5, 0], "\(String(describing: m.values))")
    m.type("-")
    check("minus negates the value being typed", m.values == [2, -1.5, 0])
    m.type("-")
    check("and again un-negates it", m.values == [2, 1.5, 0])
    m.nextValue(); m.nextValue()
    check("Tab goes round to X", m.component == 0)
    m.type("a")
    check("a letter is not a number", m.values == [2, 1.5, 0])
}
do {
    var m = M(mode: .translate)
    m.press(axis: 2, plane: false)
    m.type("3")
    check("G Z 3: one value", m.valueCount == 1 && m.values == [3])
    m.nextValue()
    check("Tab with one value stays on it", m.component == 0)
    m.backspace()
    check("Backspace to nothing: the pointer again", !m.isTyping && m.values == nil)
}
do {
    var m = M(mode: .scale)
    m.type("2")
    check("S 2: every axis 2", m.values == [2, 2, 2])
    check("shown on all three", m.shownValues == ["[2|]", "2", "2"], "\(m.shownValues)")
    m.nextValue(); m.type("3")
    check("Tab, 3: each its own, the third 1", m.values == [2, 3, 1], "\(String(describing: m.values))")
    var p = M(mode: .scale)
    p.press(axis: 2, plane: true)
    p.type("0"); p.type("."); p.type("5")
    check("S Shift+Z 0.5: X and Y", p.values == [0.5, 0.5])
}
do {
    var m = M(mode: .rotate)
    m.press(axis: 0, plane: false)
    m.type("9"); m.type("0")
    check("R X 90: one value", m.valueCount == 1 && m.values == [90])
    m.type("-")
    check("R X -90", m.values == [-90])
    m.switchMode(.translate)
    check("G during R: nothing typed, no constraint", m.mode == .translate && !m.isTyping && m.constraint == .none)
}
do {
    // R R: Trackball, which takes no constraint (T_NO_CONSTRAINT) and two
    // angles in degrees, Tab between them.
    var m = M(mode: .rotate)
    m.switchMode(.trackball)
    check("Trackball is Blender's name", m.mode.label == "Trackball")
    m.press(axis: 0, plane: false)
    check("X does nothing in Trackball", m.constraint == .none)
    m.type("3"); m.type("0")
    check("Trackball 30: two values, the second 0", m.valueCount == 2 && m.values == [30, 0],
          "\(String(describing: m.values))")
    m.nextValue(); m.type("-"); m.type("1"); m.type("5")
    check("Tab, -15", m.values == [30, -15], "\(String(describing: m.values))")
    m.nextValue()
    check("Tab again: back to the first", m.component == 0)
    m.switchMode(.rotate)
    check("R again: Rotate, nothing typed", m.mode == .rotate && !m.isTyping)
}
do {
    // G G: the slides take one factor and no constraint.
    for mode in [M.Mode.edgeSlide, .vertexSlide] {
        var m = M(mode: .translate)
        m.press(axis: 2, plane: false)
        m.switchMode(mode)
        check("\(mode.label): no constraint left from the Move", m.constraint == .none)
        m.press(axis: 1, plane: true)
        check("\(mode.label): Shift+Y does nothing", m.constraint == .none)
        m.type("."); m.type("2"); m.type("5")
        check("\(mode.label): one factor, 0.25", m.valueCount == 1 && m.values == [0.25])
        m.nextValue()
        check("\(mode.label): Tab stays on it", m.component == 0)
    }
    check("Blender's names", M.Mode.edgeSlide.label == "Edge Slide" && M.Mode.vertexSlide.label == "Vertex Slide")
    check("the three that take X, Y and Z", [M.Mode.translate, .rotate, .scale].allSatisfy(\.takesConstraint)
          && ![M.Mode.trackball, .edgeSlide, .vertexSlide].contains(where: \.takesConstraint))
}
do {
    check(".5 is a half", M.number(".5") == 0.5)
    check("-.25", M.number("-.25") == -0.25)
    check("'-' alone is minus nothing", M.number("-") == 0)
    check("'' is nothing", M.number("") == nil)
}

print("== Ctrl+M, Interactive Mirror (transform_mode_mirror.cc) ==")
do {
    var m = M(mode: .mirror)
    check("named Mirror, takes X, Y and Z", m.mode.label == "Mirror" && m.mode.takesConstraint)
    check("waits for an axis", m.mirrorHeader(space: "global") == "Select a mirror axis (X, Y, Z)"
          && m.mirrorFactors == SIMD3(1, 1, 1))
    m.type("5")
    check("takes no numbers", !m.isTyping && m.valueCount == 0)
    m.press(axis: 0, plane: false)
    check("X: flips X, along global X", m.mirrorFactors == SIMD3(-1, 1, 1)
          && m.mirrorHeader(space: "global") == "Mirror along global X")
    m.press(axis: 0, plane: false)
    check("X again: the other orientation", m.constraint == .axis(0, .alternate)
          && m.mirrorHeader(space: "local") == "Mirror along local X")
    m.press(axis: 0, plane: false)
    check("X a third time: none", m.constraint == .none && m.mirrorFactors == SIMD3(1, 1, 1))
    m.press(axis: 1, plane: true)
    check("Shift+Y: flips X and Z, locking global Y", m.mirrorFactors == SIMD3(-1, 1, -1)
          && m.mirrorHeader(space: "global") == "Mirror locking global Y")
    m.nextValue()
    check("Tab does nothing", !m.isTyping)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
