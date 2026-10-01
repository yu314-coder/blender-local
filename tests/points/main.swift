import Foundation
import simd
import CoreGraphics

// Edit Mode on curves and lattices, the Swift half: the cage the mirror hands
// over (`ControlCage`, `carryPoints`), what a tap, a box and the gizmo do with
// it, the settings the Data tab shows, and the Python each control sends.
// What Blender does with that Python is run-points-blender-check.sh's.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

// A Bézier spline of two points (left, knot, right each), then a poly
// spline of three points: what `_blenderkit_points.cage` sends, flags and all.
let auto: UInt8 = 1 << 4, aligned: UInt8 = 3 << 4
let bezierFlags: [UInt8] = [4 | auto, 0, 8 | auto, 4 | aligned | 1, 1, 8 | aligned | 1]
let polyFlags: [UInt8] = [64, 64 | 2, 64]
let positions: [Float] = [-1.5, 0, 0, -1, 0, 0, -0.5, 0, 0,   0.5, 0, 0, 1, 0, 0, 1.5, 0, 0,
                          0, 2, 0, 1, 2, 0, 2, 2, 0]
let lines: [UInt32] = [0, 1, 1, 2, 3, 4, 4, 5, 6, 7, 7, 8]

print("== the cage ==")
let cage = ControlCage(positions: positions, flags: bezierFlags + polyFlags, lines: lines)!
check("nine points", cage.count == 9 && cage.positions[4] == SIMD3(1, 0, 0))
check("parts read from the flags", cage.part(0) == .leftHandle && cage.part(1) == .point
      && cage.part(2) == .rightHandle && cage.part(6) == .point)
check("handle types read from the flags", cage.handleType(0) == .auto && cage.handleType(3) == .aligned
      && cage.handleType(1) == nil && cage.handleType(6) == nil)
check("selection and hiding", cage.selected == [3, 4, 5] && cage.isHidden(7) && !cage.isHidden(6))
check("the poly spline's points are its polygon's", cage.isPolygonPoint(6) && !cage.isPolygonPoint(1))
check("not a lattice", !cage.isLattice)
check("a malformed cage is refused: a flag short",
      ControlCage(positions: positions, flags: Array(bezierFlags + polyFlags).dropLast(), lines: lines) == nil)
check("a line naming a point that is not there is refused",
      ControlCage(positions: positions, flags: bezierFlags + polyFlags, lines: [0, 9]) == nil)
check("an odd line list is refused",
      ControlCage(positions: positions, flags: bezierFlags + polyFlags, lines: [0, 1, 2]) == nil)
let lattice = ControlCage(positions: [Float](repeating: 0, count: 24), flags: [UInt8](repeating: 0, count: 8),
                          lines: [0, 1])!
check("a lattice's cage is a lattice", lattice.isLattice)

print("== a tap ==")
check("a knot takes its handles", cage.tapped(1) == [0, 1, 2] && cage.tapped(4) == [3, 4, 5])
check("a handle is itself", cage.tapped(0) == [0] && cage.tapped(5) == [5])
check("a poly point is itself", cage.tapped(6) == [6])
check("past the end is nothing", cage.tapped(9) == [] && cage.tapped(-1) == [])
// Seen from above, the scene's x and y onto the view.
var camera = ViewportCamera()
camera.snap(to: .top)
camera.target = SIMD3(0.5, 1, 0)
camera.distance = 6
let size = CGSize(width: 1000, height: 800)
let vp = camera.viewProjection(aspect: Float(size.width / size.height))
let screen = cage.screenPoints(model: matrix_identity_float4x4, viewProjection: vp, size: size)
check("every point projects", screen.allSatisfy { $0 != nil })
let knotPoint = screen[4]!
check("a tap beside a knot picks it",
      cage.pick(at: CGPoint(x: knotPoint.x + 4, y: knotPoint.y), model: matrix_identity_float4x4,
                viewProjection: vp, size: size, radius: 22) == 4)
check("nothing within reach picks nothing",
      cage.pick(at: CGPoint(x: knotPoint.x, y: knotPoint.y + 200), model: matrix_identity_float4x4,
                viewProjection: vp, size: size, radius: 22) == nil)
check("a hidden point is never picked", cage.pick(at: screen[7]!, model: matrix_identity_float4x4,
                                                 viewProjection: vp, size: size, radius: 3) == nil)
// A handle sitting on its knot: the knot wins the tie, as a short handle
// would otherwise make its knot unreachable.
var stacked = cage
stacked.positions[5] = stacked.positions[4]
check("a knot wins a tie with its own handle",
      stacked.pick(at: screen[4]!, model: matrix_identity_float4x4, viewProjection: vp, size: size, radius: 22) == 4)
let model = simd_float4x4(translation: SIMD3(10, 0, 0))
// Half a unit along X keeps the knot in view: its point must be where (1.5,
// 0, 0) projects. (This passed for any answer once, `moved[4] == nil` — the
// knot at x 11 is off screen.)
let nudged = cage.screenPoints(model: simd_float4x4(translation: SIMD3(0.5, 0, 0)), viewProjection: vp, size: size)
let expectedNudge = BoxSelect.project(SIMD3(1.5, 0, 0), viewProjection: vp, size: size)
check("the object's matrix places its points", nudged[4] != nil && expectedNudge != nil
      && hypot(nudged[4]!.x - expectedNudge!.x, nudged[4]!.y - expectedNudge!.y) < 1e-3
      && hypot(nudged[4]!.x - screen[4]!.x, nudged[4]!.y - screen[4]!.y) > 10,
      "\(String(describing: nudged[4])) vs \(String(describing: expectedNudge))")

print("== a box ==")
// From just left of the knot's left handle to past its right one.
let box = SelectionRegion.box(CGRect(x: screen[3]!.x - 5, y: knotPoint.y - 30,
                                     width: screen[5]!.x - screen[3]!.x + 10, height: 60))
let inside = cage.inside(box, model: matrix_identity_float4x4, viewProjection: vp, size: size)
check("each point inside counts by itself", inside == [3, 4, 5], "\(inside.sorted())")
let all = SelectionRegion.box(CGRect(x: 0, y: 0, width: 1000, height: 800))
check("a hidden point is never boxed", !cage.inside(all, model: matrix_identity_float4x4, viewProjection: vp,
                                                    size: size).contains(7))
check("Extend adds, Subtract takes away", SelectAction.extend.applyRegion([0], inside: inside) == [0, 3, 4, 5]
      && SelectAction.subtract.applyRegion([3, 4, 5, 6], inside: inside) == [6])

print("== the gizmo's points ==")
let world = cage.selectedWorld(model: model)
check("the selected points in world space", world.count == 3 && world[1] == SIMD3(11, 0, 0))
var hiddenSelected = cage
hiddenSelected.flags[7] |= ControlCage.selectedFlag
check("a hidden point is not a pivot point", hiddenSelected.selectedWorld(model: model).count == 3
      && hiddenSelected.transformCentres(model: model).count == 3)

// Blender's centres, by `createTransCurveVerts`: a handle whose knot is
// selected is measured at its knot. A knot at the origin with Free handles at
// (-1, 0, 0) and (3, 0, 0), then a second point at (6, 1, 0) with handles at
// (5, 2, 0) and (8, 1, 0) — the case where the mean of the entries is wrong
// (scratchpad pivot_rules_probe.py measured each answer below in 5.2.1 by a
// 180° turn with no centre given, under the app's VIEW_3D override).
let free: UInt8 = 0
let freeCage = ControlCage(positions: [-1, 0, 0, 0, 0, 0, 3, 0, 0,   5, 2, 0, 6, 1, 0, 8, 1, 0],
                           flags: [4 | free, 0, 8 | free, 4 | free, 0, 8 | free], lines: [0, 1, 1, 2, 3, 4, 4, 5])!
func choosing(_ chosen: Set<Int>) -> ControlCage {
    var c = freeCage
    for i in c.flags.indices where chosen.contains(i) { c.flags[i] |= ControlCage.selectedFlag }
    return c
}
func near(_ a: SIMD3<Float>?, _ b: SIMD3<Float>) -> Bool { a.map { simd_distance($0, b) < 1e-5 } ?? false }
func mean(_ p: [SIMD3<Float>]) -> SIMD3<Float> { p.reduce(.zero, +) / Float(p.count) }
let id4 = matrix_identity_float4x4
check("a tapped knot is measured at the knot three times, not at its handles' mean",
      choosing([0, 1, 2]).transformCentres(model: id4) == [.zero, .zero, .zero])
check("Blender's median of a tapped knot and the other point's right handle: (2, 0.25, 0)",
      near(mean(choosing([0, 1, 2, 5]).transformCentres(model: id4)), SIMD3(2, 0.25, 0)))
check("a handle without its knot is measured where it is",
      choosing([2, 3]).transformCentres(model: id4) == [SIMD3(3, 0, 0), SIMD3(5, 2, 0)])
check("Select All's median is the knots' mean, (3, 0.5, 0)",
      near(mean(choosing([0, 1, 2, 3, 4, 5]).transformCentres(model: id4)), SIMD3(3, 0.5, 0)))
check("one point moved: a lone handle is that point, its knot",
      near(choosing([0]).singlePoint(model: id4), .zero) && near(choosing([3, 5]).singlePoint(model: id4), SIMD3(6, 1, 0)))
check("two points moved are not one", choosing([2, 3]).singlePoint(model: id4) == nil
      && choosing([]).singlePoint(model: id4) == nil)
check("a poly point alone is itself",
      near(ControlCage(positions: [0, 2, 0, 1, 2, 0], flags: [64 | 1, 64], lines: [0, 1])!.singlePoint(model: id4),
           SIMD3(0, 2, 0)))

print("== what is drawn ==")
let overlay = ControlCageOverlay(cage)
check("a line per cage line", overlay.lines.count == cage.lines.count / 2)
check("a handle line wears its handle's type: Auto unselected, Aligned selected",
      overlay.lines[0].colour == ControlCageOverlay.handleColour(.auto, selected: false)
      && overlay.lines[2].colour == ControlCageOverlay.handleColour(.aligned, selected: true))
check("the poly spline's polygon in the NURBS line colour", overlay.lines[4].colour == SIMD4(0.565, 0.565, 0.0, 1))
let dotted = overlay.dots.flatMap(\.points).map(Int.init)
check("every visible point has a dot, the hidden one none", Set(dotted) == Set(0..<9).subtracting([7])
      && dotted.count == 8)
check("selected points orange, drawn last", overlay.dots.last?.colour == ControlCageOverlay.selected
      && Set(overlay.dots.last!.points.map(Int.init)) == [3, 4, 5])
check("an unselected handle in its type's colour", overlay.dots.contains {
    $0.colour == ControlCageOverlay.handleColour(.auto, selected: false) && $0.points.contains(0) })
let gridOverlay = ControlCageOverlay(lattice)
check("a lattice's lines are black until both ends are selected", gridOverlay.lines.first?.colour == ControlCageOverlay.unselected)

print("== the settings ==")
let curveRecord = "dimensions=3D;resolution_u=12.0;bevel_depth=0.1;bevel_resolution=4.0;extrude=0.0;"
    + "offset=0.0;fill_mode=FULL;splines=2.0;points=5.0;bezier=1.0;cyclic=0.0"
if case .curve(let c)? = ObjectDataSettings.parse(type: "CURVE", record: curveRecord) {
    check("a curve's record, integers sent as floats", c.resolutionU == 12 && c.bevelResolution == 4
          && c.bevelDepth == 0.1 && c.splines == 2 && c.points == 5 && c.fillMode == "FULL", "\(c)")
    check("a 3D curve's fill modes", c.fillModes.map(\.identifier) == ["FULL", "BACK", "FRONT", "HALF"])
    var flat = c
    flat.dimensions = "2D"
    check("a 2D curve's fill modes", flat.fillModes.map(\.identifier) == ["NONE", "BACK", "FRONT", "BOTH"])
} else { check("a curve's record parses", false) }
let latticeRecord = "points_u=3.0;points_v=2.0;points_w=2.0;interpolation_type_u=KEY_LINEAR;"
    + "interpolation_type_v=KEY_BSPLINE;interpolation_type_w=KEY_BSPLINE;use_outside=1"
if case .lattice(let l)? = ObjectDataSettings.parse(type: "LATTICE", record: latticeRecord) {
    check("a lattice's record", l.pointsU == 3 && l.pointsV == 2 && l.pointsW == 2
          && l.interpolation == ["KEY_LINEAR", "KEY_BSPLINE", "KEY_BSPLINE"] && l.useOutside
          && l.resolutionEditable, "\(l)")
} else { check("a lattice's record parses", false) }
if case .lattice(let keyed)? = ObjectDataSettings.parse(type: "LATTICE", record: latticeRecord + ";points_editable=0") {
    check("a lattice with shape keys keeps its resolution: not editable", !keyed.resolutionEditable)
} else { check("a keyed lattice's record parses", false) }
check("a record missing a field is no settings", ObjectDataSettings.parse(type: "CURVE", record: "dimensions=3D") == nil)
check("a mesh has none", ObjectDataSettings.parse(type: "MESH", record: curveRecord) == nil)
check("Blender's resolution range", LatticeSettings.resolutionRange == 1...64)

print("== the mirror ==")
let curve = BKObject(name: "Curve", kind: .cube)
curve.blenderType = "CURVE"
check("carried during a pass onto the pushed object",
      SceneMirror.carryPoints(record: curveRecord, positions: positions, flags: bezierFlags + polyFlags,
                              lines: lines, named: "Curve", pass: [curve], screen: [])
      && curve.controlCage == cage && curve.dataSettings != nil)
check("a name the pass does not hold is refused",
      !SceneMirror.carryPoints(record: curveRecord, positions: [], flags: [], lines: [], named: "Other",
                               pass: [curve], screen: [curve]))
check("outside a pass, onto the object on screen; no points is no cage",
      SceneMirror.carryPoints(record: curveRecord, positions: [], flags: [], lines: [], named: "Curve",
                              pass: nil, screen: [curve]) && curve.controlCage == nil && curve.dataSettings != nil)
check("malformed points are refused and change nothing",
      !SceneMirror.carryPoints(record: curveRecord, positions: [0, 0], flags: [0], lines: [], named: "Curve",
                               pass: nil, screen: [curve]) && curve.controlCage == nil)
// The merge keeps the object on screen and takes the pass's points.
let scene = BKScene(startupFile: false)
scene.objects = [curve]
let fresh = BKObject(name: "Curve", kind: .cube)
fresh.blenderType = "CURVE"
fresh.controlCage = cage
fresh.dataSettings = ObjectDataSettings.parse(type: "CURVE", record: curveRecord)
SceneMirror.merge([fresh], into: scene, unchanged: [], selection: [], active: nil)
check("the merge carries the points onto the object already on screen",
      scene.objects.first === curve && curve.controlCage == cage)
let leaving = BKObject(name: "Curve", kind: .cube)
leaving.blenderType = "CURVE"
SceneMirror.merge([leaving], into: scene, unchanged: [], selection: [], active: nil)
check("and drops them when Blender sends none (Done)", curve.controlCage == nil && curve.dataSettings == nil)

print("== objects and modes ==")
let latticeObject = BKObject(name: "Lattice", kind: .cube)
latticeObject.blenderType = "LATTICE"
let mesh = BKObject(name: "Cube", kind: .cube)
let light = BKObject(name: "Light", kind: .cube)
light.blenderType = "LIGHT"
check("curves and lattices edit points; a mesh does not", curve.editsPoints && latticeObject.editsPoints
      && !mesh.editsPoints && !light.editsPoints)
check("Edit Mode is a mesh's, a curve's and a lattice's", mesh.canEnterEditMode && curve.canEnterEditMode
      && latticeObject.canEnterEditMode && !light.canEnterEditMode)
check("the mesh tools stay a mesh's", mesh.hasEditMode && !curve.hasEditMode && !latticeObject.hasEditMode)
scene.objects = [curve]
scene.activeID = curve.id
curve.controlCage = cage
check("not edited in Object Mode", scene.editedPoints == nil)
scene.setMode(.edit)
check("edited in Edit Mode", scene.editedPoints?.object === curve)
curve.controlCage = nil
check("not before Blender has sent its points", scene.editedPoints == nil)
curve.controlCage = cage
check("Edit Mode is held to meshes, curves and lattices", Bpy.setMode(.edit).contains("('MESH', 'CURVE', 'LATTICE')")
      && Bpy.toggleEditMode.contains("('MESH', 'CURVE', 'LATTICE')"))
check("Sculpt Mode stays held to meshes", Bpy.setMode(.sculpt).contains("_bk_o.type != 'MESH'"))

print("== the gizmo ==")
let options = ViewportOptions()
let pivot = TransformGizmo.pivot(of: scene)
check("the gizmo sits on the selected points' median", pivot.map { simd_distance($0, SIMD3(1, 0, 0)) < 1e-6 } ?? false,
      "\(String(describing: pivot))")
// The asymmetric case through the gizmo itself: each pivot setting, each
// transform, against what Blender measured (pivot_rules_probe.py).
let freeCurve = BKObject(name: "Free", kind: .cube)
freeCurve.blenderType = "CURVE"
let freeScene = BKScene(startupFile: false)
freeScene.objects = [freeCurve]
freeScene.activeID = freeCurve.id
freeScene.setMode(.edit)
for (chosen, moveAt, turnAt, boundsAt) in [
    (Set([0, 1, 2]), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0)),
    (Set([0]), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0)),
    (Set([0, 1, 2, 5]), SIMD3<Float>(2, 0.25, 0), SIMD3<Float>(2, 0.25, 0), SIMD3<Float>(4, 0.5, 0)),
    (Set([0, 1, 2, 3, 4, 5]), SIMD3<Float>(3, 0.5, 0), SIMD3<Float>(3, 0.5, 0), SIMD3<Float>(3, 0.5, 0)),
] {
    freeCurve.controlCage = choosing(chosen)
    freeScene.tools.pivot = .medianPoint
    let move = TransformGizmo.pivot(of: freeScene, for: .translate)
    let turn = TransformGizmo.pivot(of: freeScene, for: .rotate)
    let grow = TransformGizmo.pivot(of: freeScene, for: .scale)
    freeScene.tools.pivot = .boundingBoxCenter
    let bounds = TransformGizmo.pivot(of: freeScene, for: .rotate)
    check("selection \(chosen.sorted()): Move at \(moveAt), Rotate and Scale at \(turnAt), Bounds at \(boundsAt)",
          near(move, moveAt) && near(turn, turnAt) && near(grow, turnAt) && near(bounds, boundsAt),
          "\(String(describing: move)) \(String(describing: turn)) \(String(describing: grow)) \(String(describing: bounds))")
}
freeScene.tools.pivot = .medianPoint
let cube = BKObject(name: "Deformed", kind: .cube)
cube.dependencies = ["Curve"]
scene.objects = [curve, cube]
if let g = TransformGizmo.make(mode: .translate, scene: scene, options: options, camera: camera, size: size) {
    let session = TransformGizmo.beginSession(handle: .axis(2), at: CGPoint(x: 500, y: 400), gizmo: g, scene: scene,
                                              camera: camera, size: size, options: options)
    check("a points drag of the curve, its dependents following", session.points?.object === curve
          && session.points?.followers == ["Deformed"] && session.edit == nil)
    let before = curve.controlCage
    let meshBefore = curve.mesh.vertices.map(\.position)
    TransformGizmo.apply(.translate(SIMD3(0, 0, 1)), session: session)
    TransformGizmo.rollBack(session)
    check("the preview touches no display cache: Blender draws it", curve.controlCage == before
          && curve.mesh.vertices.map(\.position) == meshBefore && curve.location == .zero)
    let call = TransformGizmo.python(.translate(SIMD3(0, 0, 0.5)), session: session)
    check("the frames and the release send a plain translate", call.hasPrefix("bpy.ops.transform.translate(value=(0.0000, 0.0000, 0.5000)")
          && !call.contains("mirror="), call)
    check("each frame puts the points back, runs the call, and mirrors",
          PointsBpy.preview(call) == "import _blenderkit_points as _bk_pts\n_bk_pts.restore()\n\(call)\n_bk_pts.settle()")
} else {
    check("a gizmo for the selected points", false)
}
var none = cage
for i in none.flags.indices { none.flags[i] &= ~ControlCage.selectedFlag }
curve.controlCage = none
check("nothing selected, no gizmo", TransformGizmo.pivot(of: scene) == nil)
curve.controlCage = nil
check("no points yet, no gizmo — not the object's", TransformGizmo.pivot(of: scene) == nil)

print("== the Python ==")
check("a selection names the object, quoted as a Python string, its indices in order",
      PointsBpy.select([5, 1, 3], object: "It's") ==
      "import _blenderkit_points as _bk_pts\n_bk_pts.select(\"It's\", [1, 3, 5])", PointsBpy.select([5, 1, 3], object: "It's"))
check("a drag remembers its followers", PointsBpy.beginDrag(object: "Lattice", followers: ["Cube", "A\"b"]) ==
      "import _blenderkit_points as _bk_pts\n_bk_pts.begin_drag(\"Lattice\", [\"Cube\", \"A\\\"b\"])",
      PointsBpy.beginDrag(object: "Lattice", followers: ["Cube", "A\"b"]))
let subdivide = PointsBpy.subdivide(cuts: 2)
check("Subdivide logs the bare call", subdivide.python == "bpy.ops.curve.subdivide(number_cuts=2)")
check("and runs it held to a selection and to a change of anything, not of the count",
      subdivide.executed.contains("_bk_pts.require_selection(")
      && subdivide.executed.contains("\nif _bk_pts.fingerprint() == _bk_before:\n")
      && subdivide.executed.contains("\n_bk_result = bpy.ops.curve.subdivide(number_cuts=2)\n"), subdivide.executed)
check("Make Regular needs no selection, and a CANCELLED is a refusal only when nothing changed",
      !PointsBpy.makeRegular.executed.contains("require_selection")
      && PointsBpy.makeRegular.executed.contains("_bk_before = _bk_pts.fingerprint()")
      && PointsBpy.makeRegular.executed.contains("\nif 'CANCELLED' in _bk_result and _bk_pts.fingerprint() == _bk_before:\n"),
      PointsBpy.makeRegular.executed)
check("Set Handle Type's five types, Blender's identifiers", PointsBpy.handleTypes.map(\.identifier)
      == ["AUTOMATIC", "VECTOR", "ALIGNED", "FREE_ALIGN", "TOGGLE_FREE_ALIGN"])
check("Select All for a curve and a lattice", PointsBpy.selectAll("INVERT", lattice: false)
      == "bpy.ops.curve.select_all(action='INVERT')" && PointsBpy.selectAll("SELECT", lattice: true)
      == "bpy.ops.lattice.select_all(action='SELECT')")
check("a Data tab field", PointsBpy.set("bevel_depth", to: "0.1", object: "Bé") ==
      "bpy.data.objects[\"Bé\"].data.bevel_depth = 0.1", PointsBpy.set("bevel_depth", to: "0.1", object: "Bé"))
let add = LastOperator.add(.lattice, at: SIMD3(1, 2, 3))
check("Add ▸ Lattice", add.name == "Add Lattice" && add.python.hasPrefix("bpy.ops.object.add(radius=1")
      && add.python.contains("type='LATTICE'") && add.dataCollection == "lattices"
      && add.restoration == .removeCreated, add.python)
check("the Add menu calls it Lattice", ObjectAddition.lattice.label == "Lattice")

print("== a drag holds everything else ==")
// A runtime that answers as the device's does, recording what reaches it:
// what a drag of points lets through, and what it holds back.
final class DeviceRecorder: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
}
let recorder = DeviceRecorder()
let holdSession = BpySession(runtime: recorder)
let holdScene = BKScene(startupFile: false)
holdSession.bind(scene: holdScene, undo: UndoStack())
let holdBridge = BpyBridge(session: holdSession, scene: holdScene, undo: UndoStack())
check("no hold before a drag", !holdBridge.pointDragOpen && holdSession.gestureHold == nil)
check("a drag begins", holdBridge.beginPointDrag(object: "Curve", followers: [], undo: "Move")
      && holdBridge.pointDragOpen && holdSession.gestureHold == BpySession.pointDragOpenMessage)
var sentBefore = recorder.sources.count
let tab = holdBridge.run(Bpy.toggleEditMode, undo: "Toggle Edit Mode")
check("Tab mid-drag is refused, in words, and reaches nothing", !tab.succeeded
      && tab.error == BpySession.pointDragOpenMessage && recorder.sources.count == sentBefore
      && holdBridge.report?.message == BpySession.pointDragOpenMessage, "\(tab)")
let tap = holdBridge.select(PointsBpy.select([0], object: "Curve"))
check("a tap mid-drag is refused", !tap.succeeded && recorder.sources.count == sentBefore)
holdSession.performUndo()
holdSession.performRedo()
check("Undo and Redo mid-drag reach nothing, and say why", recorder.sources.count == sentBefore
      && holdSession.console.last?.text == BpySession.pointDragOpenMessage)
holdSession.submit("print(1)", scene: holdScene)
holdSession.runScript("print(1)", scene: holdScene)
check("nor do the console and a script", recorder.sources.count == sentBefore)
check("a frame still runs", holdBridge.previewPointDrag("bpy.ops.transform.translate(value=(0, 0, 1))", undo: "Move")
      && recorder.sources.count == sentBefore + 1 && recorder.sources.last!.hasSuffix("_bk_pts.settle()"))
sentBefore = recorder.sources.count
let commit = holdBridge.commitPointDrag("bpy.ops.transform.translate(value=(0, 0, 1))", undo: "Move")
check("the release commits in one evaluation, and the hold is over", commit.succeeded && !holdBridge.pointDragOpen
      && recorder.sources.dropFirst(sentBefore).contains {
          $0.contains("_bk_pts.restore(end=True)") && $0.contains("bpy.ops.transform.translate(value=(0, 0, 1))") },
      "\(commit)")
check("a cancel ends the hold too", holdBridge.beginPointDrag(object: "Curve", followers: [], undo: "Move")
      && { holdBridge.cancelPointDrag(); return !holdBridge.pointDragOpen }())
_ = holdBridge.beginPointDrag(object: "Curve", followers: [], undo: "Move")
sentBefore = recorder.sources.count
check("a drag begun over one whose end never came cancels it first",
      holdBridge.beginPointDrag(object: "Curve", followers: [], undo: "Move")
      && recorder.sources.dropFirst(sentBefore).first?.contains("_bk_pts.cancel()") == true
      && holdBridge.pointDragOpen)
holdBridge.cancelPointDrag()
let after = holdBridge.run(Bpy.toggleEditMode, undo: "Toggle Edit Mode")
check("after the drag, commands run again", after.succeeded, "\(after)")

// A curve emptied in Edit Mode has no points, and a tap on it is no mesh
// selection: nothing is pushed in front of the next command (5.2.1: the mesh
// push failed Done with "expected 'Mesh' type found 'Curve' instead").
let emptied = BKObject(name: "Emptied", kind: .cube)
emptied.blenderType = "CURVE"
holdScene.objects = [emptied]
holdScene.activeID = emptied.id
holdScene.setMode(.edit)
holdScene.editSelection.vertices = [0]
holdScene.editSelectionPending = true
sentBefore = recorder.sources.count
_ = holdBridge.run(Bpy.setMode(.object))
check("Done on a curve sends Done alone, no mesh selection in front", recorder.sources.count == sentBefore + 1
      && !recorder.sources.last!.contains("bmesh"), recorder.sources.last ?? "")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
