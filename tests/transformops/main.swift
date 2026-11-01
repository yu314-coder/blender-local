import Foundation
import simd
import CoreGraphics

// Typed values in Edit Mode, transform orientations, the gizmo's redo panel
// and typed Dimensions: the Swift half. What Blender makes of it is
// scripts/run-transformops-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool { simd_distance(a, b) < eps }

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

func scene(rotation: SIMD3<Float> = SIMD3(0, 0, .pi / 6)) -> (BKScene, BKObject) {
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = SIMD3(1, 0, 0)
    o.rotation = rotation
    s.selection = [o.id]
    s.activeID = o.id
    return (s, o)
}

/// A 30° turn about X: Blender's Normal of a cube's top face turned that way.
let tilted = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, cos(Float.pi / 6), sin(Float.pi / 6)),
                           SIMD3(0, -sin(Float.pi / 6), cos(Float.pi / 6)))

print("== the orientations, by Blender's names ==")
check("seven, in Blender's order (TransformOrientationSlot.type)",
      TransformOrientation.allCases.map(\.bpyIdentifier)
        == ["GLOBAL", "LOCAL", "NORMAL", "GIMBAL", "VIEW", "CURSOR", "PARENT"])
check("named as Blender's menu names them",
      TransformOrientation.allCases.map(\.label) == ["Global", "Local", "Normal", "Gimbal", "View", "Cursor", "Parent"])
check("and read back from their identifiers",
      TransformOrientation.allCases.allSatisfy { TransformOrientation(identifier: $0.bpyIdentifier) == $0 }
        && TransformOrientation(identifier: "CUSTOM") == nil)
check("the menu writes Blender's slot through the tool settings",
      OrientationBpy.set(.normal) == "import _blenderkit_tools\n_blenderkit_tools.set_tools(orientation='NORMAL')")
check("Global and a Local scale go bare; the rest with their matrix",
      TransformOrientation.global.commitsBare(scaling: false) && TransformOrientation.local.commitsBare(scaling: true)
        && !TransformOrientation.local.commitsBare(scaling: false) && !TransformOrientation.normal.commitsBare(scaling: true))

print("\n== what the report says ==")
let line = "NORMAL 1.0 0.0 0.0 0.0 0.8660254 0.5 0.0 -0.5 0.8660254"
if let state = OrientationState.parse(line), let a = state.axes {
    check("a report is a type and three axes", state.type == .normal && close(a.columns.1, SIMD3(0, 0.8660254, 0.5))
          && close(a.columns.2, SIMD3(0, -0.5, 0.8660254)), "\(a)")
} else { check("a report reads", false, line) }
let custom = OrientationState.parse("My Face 0 1 0 -1 0 0 0 0 1")
check("a custom orientation's name may have spaces", custom?.type == nil && custom?.customName == "My Face"
      && custom?.axes.map { close($0.columns.0, SIMD3(0, 1, 0)) } == true && custom?.label == "My Face")
let pipe = OrientationState.parse("Pipe none 0 1 0 -1 0 0 0 0 1")
check("a custom orientation whose name holds ' none' is still its matrix (round 4's review)",
      pipe?.customName == "Pipe none" && pipe?.axes != nil && pipe?.unavailable == nil, "\(String(describing: pipe))")
let pipeNone = OrientationState.parse("Pipe none none The PIPE NONE orientation could not be worked out here (X: y).")
check("and with no matrix, none", pipeNone?.axes == nil && pipeNone?.unavailable != nil)
let none = OrientationState.parse("NORMAL none Normal orientation for a curve's points is not worked out here.")
check("none and a reason", none?.type == .normal && none?.axes == nil
      && none?.unavailable?.hasPrefix("Normal orientation") == true)
check("View reports no matrix, and no reason", OrientationState.parse("VIEW none")?.unavailable == nil
      && OrientationState.parse("VIEW none")?.axes == nil)
check("a broken line is no report (it must be able to fail)",
      OrientationState.parse("NORMAL 1 0 0") == nil && OrientationState.parse("") == nil
        && OrientationState.parse("NORMAL 1 0 0 0 1 0 0 0 nan") == nil)

print("\n== the matrix as the call writes it ==")
check("rows are the axes, six places, never -0",
      OrientationBpy.literal(simd_float3x3(SIMD3(1, -0.0000001, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)))
        == "((1.000000, 0.000000, 0.000000), (0.000000, 1.000000, 0.000000), (0.000000, 0.000000, 1.000000))")
check("printed is what the literal says", OrientationBpy.printed(tilted).columns.1.y == 0.866025)
check("orient_type alone, or with its matrix and an equal orient_matrix_type",
      OrientationBpy.orientType(.global, axes: nil) == "'GLOBAL'"
        && OrientationBpy.orientType(.normal, axes: tilted).hasPrefix("'NORMAL', orient_matrix=((1.000000")
        && OrientationBpy.orientType(.normal, axes: tilted).hasSuffix("orient_matrix_type='NORMAL'"))

print("\n== the gizmo follows Blender's orientation ==")
do {
    let (s, o) = scene()
    let global = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    check("Global by default, as in a new file", close(global.axes[0], SIMD3(1, 0, 0)) && close(global.axes[2], SIMD3(0, 0, 1)))
    s.orientation = OrientationState(type: .normal, axes: tilted)
    let normal = TransformGizmo.make(mode: .rotate, scene: s, options: options, camera: camera, size: size)!
    check("Normal: the axes Blender reported", close(normal.axes[1], tilted.columns.1) && close(normal.axes[2], tilted.columns.2))
    let scale = TransformGizmo.make(mode: .scale, scene: s, options: options, camera: camera, size: size)!
    check("a scale's handles too", close(scale.axes[2], tilted.columns.2))
    s.orientation = OrientationState(type: .local)
    let local = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    check("Local before Blender has answered: the object's own axes", close(local.axes[0], SIMD3(cos(.pi / 6), sin(.pi / 6), 0)),
          "\(local.axes)")
    _ = o
    s.orientation = OrientationState(type: .view)
    let view = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    check("View: the view's right, up and back", close(view.axes[0], camera.right) && close(view.axes[1], camera.trueUp)
          && close(view.axes[2], simd_normalize(camera.eye - camera.target)))
    s.orientation = OrientationState(type: .gimbal)
    check("an orientation Blender has not reported yet draws no gizmo",
          TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size) == nil)
    s.orientation = OrientationState(type: .normal, unavailable: "Normal orientation for a curve's points is not worked out here")
    check("nor one it cannot work out here", TransformGizmo.make(mode: .translate, scene: s, options: options,
                                                                 camera: camera, size: size) == nil)
}

print("\n== a drag commits in its orientation ==")
func moveZ(_ s: BKScene, amount: CGFloat = 1.6) -> (TransformGizmo.Session, TransformGizmo.Result) {
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let p = TransformGizmo.Projection(camera: camera, size: size)
    let c = p.project(g.origin)!, t = p.project(g.origin + g.axes[2] * g.radius)!
    let session = TransformGizmo.beginSession(handle: .axis(2), at: t, gizmo: g, scene: s, camera: camera, size: size)
    let b = CGPoint(x: c.x + (t.x - c.x) * amount, y: c.y + (t.y - c.y) * amount)
    return (session, TransformGizmo.resolve(session, at: b)!)
}
do {
    let (s, _) = scene()
    s.orientation = OrientationState(type: .normal, axes: tilted)
    let (session, result) = moveZ(s)
    guard case .translate(let d) = result else { fatalError() }
    let op = TransformGizmo.commitOperator(result, session: session)
    let values = LastOperator.committedValues(op)!
    check("the move is along the Normal's Z, its value in the Normal's axes",
          abs(values.x) < 1e-4 && abs(values.y) < 1e-4 && abs(values.z - simd_length(d)) < 1e-3, "\(values) \(d)")
    check("the call is Move with the matrix and its type",
          op.name == "Move" && op.python.hasPrefix("bpy.ops.transform.translate(value=(")
            && op.python.contains("orient_type='NORMAL', orient_matrix=((1.000000, 0.000000, 0.000000), (0.000000, 0.866025, 0.500000)")
            && op.python.contains("orient_matrix_type='NORMAL'"), op.python)
    let preview = TransformGizmo.operation(result, session: session)
    guard case .translate(let shown) = preview.kind else { fatalError() }
    check("the preview moves by the printed value times the printed matrix, as Blender multiplies",
          shown == OrientationBpy.printed(tilted) * values, "\(shown)")
    check("and that is the drag, to the printed digits", close(shown, d, 1e-3))
    check("a move sends no center_override (translate has none)", !op.python.contains("center_override"))
    check("it is adjusted through Blender's undo", op.restoration == .throughBlenderUndo && !op.needsEditMode)
    check("the undo step is Move", TransformGizmo.Mode.translate.undoName == op.name)
}
do {
    let (s, _) = scene()
    let (session, result) = moveZ(s)
    let op = TransformGizmo.commitOperator(result, session: session)
    check("in Global it goes bare, Blender's own identity",
          op.python.contains("orient_type='GLOBAL'") && !op.python.contains("orient_matrix"), op.python)
    var normal = op
    normal["orient_type"] = Double(TransformOrientation.normal.rawValue)
    check("in Object Mode the panel's Normal goes bare: Blender's is Local there, the active object's for all",
          normal.python.contains("orient_type='NORMAL'") && !normal.python.contains("orient_matrix"), normal.python)
}

print("\n== the redo panel's rows, as Blender's ==")
do {
    let (s, _) = scene()
    s.orientation = OrientationState(type: .normal, axes: tilted)
    s.tools.falloff = .sphere
    s.tools.size = 2.5
    let (session, result) = moveZ(s)
    var op = TransformGizmo.commitOperator(result, session: session)
    let shown = op.parameters.filter { op.isShown($0) }.map(\.label)
    check("Object Mode: Move X, Y, Z, Orientation, Proportional Editing", shown == ["X", "Y", "Z", "Orientation", "Proportional Editing"],
          "\(shown)")
    check("under Move's heading", op.parameters.first.map {
        if case .component(_, let heading, _) = $0.kind { return heading == "Move" } else { return false } } ?? false)
    check("Constraint Axis is no row (Blender hides it; its exec forces all three for a move)",
          !op.parameters.contains { $0.label.contains("Constraint") } && op.python.contains("constraint_axis=(False, False, True)"))
    op["use_proportional_edit"] = 1
    let on = op.parameters.filter { op.isShown($0) }.map(\.label)
    check("Proportional Editing on shows its Falloff, Size and Connected",
          on.suffix(4) == ["Proportional Editing", "Proportional Falloff", "Proportional Size", "Connected"], "\(on)")
    check("starting at the scene's settings, size to five places",
          op.python.contains("use_proportional_edit=True, proportional_edit_falloff='SPHERE', proportional_size=2.50000"),
          op.python)
    check("and no Projected (2D): a headless Blender has no view to project in", !op.python.contains("projected"))
    let options = op.parameters.first { $0.key == "orient_type" }.flatMap { p -> [LastOperator.Parameter.Option]? in
        if case .literal(let o) = p.kind { return o } else { return nil } } ?? []
    check("Orientation lists Blender's seven", options.map(\.label) == TransformOrientation.allCases.map(\.label))
    check("its own with its matrix, View with the view's, the rest bare for Blender to work out",
          options[2].identifier.contains("orient_matrix=") && options[4].identifier.contains("orient_matrix_type='VIEW'")
            && options[0].identifier == "'GLOBAL'" && options[1].identifier == "'LOCAL'" && options[3].identifier == "'GIMBAL'",
          options.map(\.identifier).joined(separator: " | "))
    op["orient_type"] = Double(TransformOrientation.cursor.rawValue)
    check("switching it re-runs in that orientation", op.python.contains("orient_type='CURSOR'")
          && !op.python.contains("orient_matrix_type='NORMAL'"), op.python)
    op["value.x"] = 0.5
    check("a typed Move X goes in as typed", op.python.contains("value=(0.5000, "), op.python)
    op["use_proportional_edit"] = 1
    let sizeRow = op.parameters.first { $0.key == "proportional_size" }
    check("Proportional Size is unitless, as Blender's (PROP_NONE)", sizeRow?.display == "2.500"
          && sizeRow?.unit == NumberFieldUnit.none, sizeRow?.display ?? "no row")
}
do {
    let (s, o) = scene()
    s.setMode(.edit)
    o.setEvaluatedMesh(o.mesh)
    s.editSelection.vertices = [0, 1]
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(0), at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    var op = TransformGizmo.commitOperator(.translate(SIMD3(0.5, 0, 0)), session: session)
    check("Edit Mode adds Mirror Editing, and needs Edit Mode", op.needsEditMode
          && op.parameters.contains { $0.label == "Mirror Editing" } && op.python.contains("mirror=False"), op.python)
    // A drag in Global, then the panel's Orientation switched to Normal: the
    // matrix is the port's, worked out when the re-run runs, with the
    // scene's pivot — not left to a headless Blender, which takes the bounds
    // centre and so the whole selection's normal under Active Element.
    op["orient_type"] = Double(TransformOrientation.normal.rawValue)
    check("Edit Mode: the panel's Normal is worked out by the port when the re-run runs",
          op.python.contains("orient_type='NORMAL', orient_matrix=__import__('_blenderkit_orient').redo_matrix('NORMAL'), "
                             + "orient_matrix_type='NORMAL'"), op.python)
    op["orient_type"] = Double(TransformOrientation.cursor.rawValue)
    check("and the others still go bare", op.python.contains("orient_type='CURSOR'") && !op.python.contains("redo_matrix"),
          op.python)
}

print("\n== rotate and scale ==")
do {
    let (s, _) = scene()
    s.orientation = OrientationState(type: .normal, axes: tilted)
    let g = TransformGizmo.make(mode: .rotate, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(1), at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    let op = TransformGizmo.commitOperator(.rotate(axis: g.axes[1], angle: 0.5, axisIndex: 1), session: session)
    check("Rotate: Angle and Axis, about the orientation's Y",
          op.name == "Rotate" && op.python.hasPrefix("bpy.ops.transform.rotate(value=0.5000, orient_axis='Y', orient_type='NORMAL'")
            && op.python.contains("center_override=") && !op.python.contains("constraint_axis"), op.python)
    let shown = op.parameters.filter { op.isShown($0) }.map(\.label)
    check("its rows", shown == ["Angle", "Axis", "Orientation", "Proportional Editing"], "\(shown)")
    check("Angle in degrees", op.parameters[0].unit == .degrees && op.parameters[0].display.hasSuffix("°"))
    let view = TransformGizmo.commitOperator(.rotate(axis: SIMD3(0, 1, 0), angle: 0.3, axisIndex: nil), session: session)
    check("the view ring turns in View, about its Z", view.python.contains("orient_axis='Z', orient_type='VIEW', orient_matrix=")
          && view.python.contains("orient_matrix_type='VIEW'"), view.python)
    let sg = TransformGizmo.make(mode: .scale, scene: s, options: options, camera: camera, size: size)!
    let ss = TransformGizmo.beginSession(handle: .axis(0), at: .zero, gizmo: sg, scene: s, camera: camera, size: size)
    let resize = TransformGizmo.commitOperator(.scale(SIMD3(2, 1, 1)), session: ss)
    check("Resize: Scale X, Y, Z in Normal", resize.name == "Resize"
          && resize.python.hasPrefix("bpy.ops.transform.resize(value=(2.0000, 1.0000, 1.0000), orient_type='NORMAL'")
          && resize.parameters.first?.unit == NumberFieldUnit.none, resize.python)
    if case .axes = TransformGizmo.operation(.scale(SIMD3(2, 1, 1)), session: ss).orientation {
        check("and its preview scales along that matrix", true)
    } else { check("and its preview scales along that matrix", false) }
    s.orientation = OrientationState(type: .local)
    let lg = TransformGizmo.make(mode: .scale, scene: s, options: options, camera: camera, size: size)!
    let ls = TransformGizmo.beginSession(handle: .axis(0), at: .zero, gizmo: lg, scene: s, camera: camera, size: size)
    check("a Local scale's preview is each object's own", TransformGizmo.operation(.scale(SIMD3(2, 1, 1)), session: ls).orientation == .local)
}
do {
    let s = BKScene(startupFile: false)
    let a = s.add(.cube), b = s.add(.cube)
    b.location = SIMD3(3, 0, 0)
    s.selection = [a.id, b.id]; s.activeID = a.id
    s.tools.pivot = .individualOrigins
    let g = TransformGizmo.make(mode: .rotate, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    let op = TransformGizmo.commitOperator(.rotate(axis: g.axes[2], angle: 0.5, axisIndex: 2), session: session)
    check("Individual Origins: the helper, its kind first, no centre",
          op.python.hasPrefix("import _blenderkit_tools\n_blenderkit_tools.transform_individual('ROTATE', value=0.5000")
            && !op.python.contains("center_override"), op.python)
}

print("\n== auto keying rides along, out of the log ==")
do {
    var c = GizmoCommit(kind: .translate(values: SIMD3(1, 0, 0), constraint: "(True, False, False)"), orientation: .global,
                        axes: matrix_identity_float3x3, viewAxes: matrix_identity_float3x3, editing: false)
    c.afterward = "import _blenderkit_anim\n_blenderkit_anim.after_transform('TRANSLATE')"
    let op = LastOperator.gizmo(c)
    check("the Info log's line is the call alone", !op.python.contains("_blenderkit_anim"))
    check("what runs keys after it", op.executedPython.hasSuffix("_blenderkit_anim.after_transform('TRANSLATE')"))
    check("and auto keying recognises the call", BpyAnimation.transformMode(of: op.python) == "TRANSLATE")
}

print("\n== Blender's 3×3 inverse, as a scale takes it ==")
do {
    // Gimbal at gimbal lock: X and Z antiparallel, none zero.
    let lock = simd_float3x3(SIMD3(0, 0, -1), SIMD3(0.198669, 0.980067, 0), SIMD3(0, 0, 1))
    check("a gimbal-locked matrix has no inverse, and Blender takes the identity",
          BlenderMatrix.inverse(lock) == nil && BlenderMatrix.safeInverse(lock) == matrix_identity_float3x3)
    // Local of a child of a turned parent scaled (2, 1, 1): not at right angles.
    let skew = simd_float3x3(simd_normalize(SIMD3(2, 0.3, 0)), simd_normalize(SIMD3(-0.4, 1, 0.2)), SIMD3(0, 0, 1))
    let inv = BlenderMatrix.safeInverse(skew)
    let product = skew * inv
    check("a sheared one is inverted, not transposed",
          (0..<3).allSatisfy { close(product[$0], matrix_identity_float3x3[$0], 1e-5) }
            && !(0..<3).allSatisfy { close(inv[$0], skew.transpose[$0], 1e-3) })
    // A zero axis is rebuilt from the other two (orthogonalize_m3_zero_axes).
    let flat = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), .zero)
    let rebuilt = BlenderMatrix.safeInverse(flat)
    check("a zero axis is rebuilt before inverting", close(rebuilt[2], SIMD3(0, 0, 1)) && close(rebuilt[0], SIMD3(1, 0, 0)),
          "\(rebuilt)")
    // The preview's scale at the lock: A · diag · I, as Blender commits it.
    let op = TransformOperation(kind: .resize(SIMD3(2.5, 1, 1)), pivot: .point(.zero), orientation: .axes(lock))
    let moved = op.apply(toVertices: [SIMD3(1, 0, 0)], factors: [1], selected: [0], model: matrix_identity_float4x4)
    check("so a gimbal-locked Scale X of 2.5 moves (1, 0, 0) as Blender does, to (0, 0, -2.5)",
          close(moved[0], SIMD3(0, 0, -2.5)), "\(moved[0])")
}

print("\n== the panel's precision ==")
do {
    var p = LastOperator.Parameter(key: "proportional_size", label: "Proportional Size", kind: .float,
                                   value: 0.123456, softMin: 0, softMax: 10, step: 0.01)
    check("four places, trimmed, by default", p.python == "proportional_size=0.1235")
    p.places = 5; p.keepsZeros = true
    check("five, kept", p.python == "proportional_size=0.12346")
    check("never -0", LastOperator.fixed(-0.00001, places: 4) == "0.0000")
    var op = LastOperator(name: "Test", call: "f", parameters: [])
    op.leadingArguments = ["'A'"]
    op.fixedArguments = ["b=1"]
    check("positional first", op.python == "f('A', b=1)")
}

print("\n== the Item tab ==")
let median = EditItemState.parse(#"{"mesh": true, "object": "Cube", "tot": 4, "edges": 4, "median": [0.5, -1.25, 2.0], "bevel_weight_vert": 0.25, "crease_vert": 0.0, "bevel_weight_edge": 0.5, "crease_edge": 0.75}"#)
check("four selected: Median:, Vertices Data:, Edges Data:", median?.medianTitle == "Median:"
      && median?.vertexDataTitle == "Vertices Data:" && median?.edgeDataTitle == "Edges Data:"
      && median?.median == SIMD3(0.5, -1.25, 2.0))
check("and Blender's Mean labels", median?.dataRows.map(\.label)
      == ["Mean Bevel Weight:", "Mean Vertex Crease:", "Mean Bevel Weight:", "Mean Crease:"])
check("with their values", median?.dataRows.map(\.value) == [0.25, 0, 0.5, 0.75])
let one = EditItemState.parse(#"{"mesh": true, "object": "Cube", "tot": 1, "edges": 0, "median": [1, 2, 3], "bevel_weight_vert": 0.0, "crease_vert": 0.0}"#)
check("one vertex: Vertex:, its own weights, no Edge Data", one?.medianTitle == "Vertex:"
      && one?.dataRows.map(\.label) == ["Bevel Weight:", "Vertex Crease:"])
check("nothing being edited reads as none", EditItemState.parse(#"{"mesh": false}"#) == nil
      && EditItemState.parse("not json") == nil)
check("a Median field sends its axis, value and space",
      ItemBpy.setMedian(axis: 2, to: 1.5, global: false) == "import _blenderkit_item\n_blenderkit_item.set_median(2, 1.500000, False)")
check("a weight row its attribute", ItemBpy.setData(.creaseEdge, to: 0.25)
      == "import _blenderkit_item\n_blenderkit_item.set_data('crease_edge', 0.250000)")
check("a Dimensions field the object, escaped",
      ItemBpy.setDimension(of: "My \"Cube\"", axis: 0, to: 2) .contains("set_dimension(\"My \\\"Cube\\\"\", 0, 2.000000)")
        || ItemBpy.setDimension(of: "My \"Cube\"", axis: 0, to: 2).contains("set_dimension('My \"Cube\"', 0, 2.000000)"),
      ItemBpy.setDimension(of: "My \"Cube\"", axis: 0, to: 2))
check("undo steps by the fields' own words, the Dimensions' X:, Y:, Z: too", ItemBpy.undoName(axis: 1) == "Y"
      && ItemBpy.undoName("Mean Bevel Weight:") == "Mean Bevel Weight")
check("Dimensions read back", ItemBpy.parseDimensions("[2.0, 0.75, 4.0]") == SIMD3(2, 0.75, 4)
      && ItemBpy.parseDimensions("[1, 2]") == nil)
check("none for an object Blender draws no Dimensions for (its null)", ItemBpy.parseDimensions("null") == nil)
// What Blender holds when a script put it past float32: JSON has no word for
// it, so the module writes Blender's ('inf', 'nan'), and the panels read it
// rather than sticking on "Reading the selection from Blender".
let huge = EditItemState.parse(#"{"mesh": true, "object": "Cube", "tot": 8, "edges": 12, "median": ["inf", "nan", "nan"], "bevel_weight_vert": 0.0, "crease_vert": 0.0, "bevel_weight_edge": 0.0, "crease_edge": 0.0}"#)
check("a non-finite Median reads, as Blender's inf and nan",
      huge?.median.map { $0.x == .infinity && $0.y.isNaN && $0.z.isNaN } == true, "\(String(describing: huge))")
check("non-finite Dimensions read too", ItemBpy.parseDimensions(#"["inf", 2.0, 2.0]"#).map { $0.x == .infinity } == true)
check("a typed number past Float's range goes as float('inf'), for the module to refuse in words",
      ItemBpy.setMedian(axis: 0, to: .infinity, global: true).hasSuffix("set_median(0, float('inf'), True)")
        && ItemBpy.setDimension(of: "Cube", axis: 1, to: .nan).contains("float('nan')")
        && ItemBpy.setData(.creaseVertex, to: -.infinity).contains("float('-inf')"))

print("\n== what reaches Blender ==")
final class Recorder: BpyRuntime {
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
do {
    let recorder = Recorder()
    let session = BpySession(runtime: recorder)
    let (s, o) = scene()
    session.bind(scene: s, undo: UndoStack())
    let bridge = BpyBridge(session: session, scene: s, undo: UndoStack())
    s.orientation = OrientationState(type: .normal, axes: tilted)
    let (gs, result) = moveZ(s)
    let before = recorder.sources.count
    TransformGizmo.commit(result, session: gs, bridge: bridge)
    let sent = recorder.sources.dropFirst(before)
    check("a release is performed: the call, in the mode it needs, not bridge.run",
          sent.contains { $0.contains("_bk_adjustable = False") && $0.contains("bpy.ops.transform.translate(value=(")
              && $0.contains("orient_type='NORMAL', orient_matrix=") }, sent.joined(separator: "\n---\n"))
    // Edit Mode: a tap the viewport has not told Blender about goes first.
    s.setMode(.edit)
    o.setEvaluatedMesh(o.mesh)
    s.editSelection.vertices = [2]
    s.editSelectionPending = true
    let readsBefore = recorder.sources.count
    _ = bridge.captureWithSelection(ItemBpy.state(global: true))
    let read = recorder.sources.dropFirst(readsBefore).joined(separator: "\n")
    check("the Item tab reads after the viewport's selection is handed over",
          read.contains("_blenderkit_item.state(True)") && read.range(of: "_blenderkit_item.state")!.lowerBound
            > (read.range(of: "select") ?? read.range(of: "_blenderkit_item.state")!).lowerBound, read)
    check("and the tap stays pending, for the next command to carry", s.editSelectionPending)
    s.editSelectionPending = false
    let plainBefore = recorder.sources.count
    _ = bridge.captureWithSelection(OrientationBpy.report)
    check("and with nothing pending, the read alone", recorder.sources.dropFirst(plainBefore).joined()
          .hasPrefix("import _blenderkit_orient"), recorder.sources.dropFirst(plainBefore).joined())
}

/// A runtime that answers as Blender's undo history does (`_blenderkit_undo`):
/// enough for `perform` to remember an operator and for the redo panel to
/// rewind and re-run it, so what each sends can be read.
final class HistoryRecorder: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    var index = -1, steps = 0, rewound = false
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "history" }
    func state() -> [BpyLine] {
        [BpyLine(.output, #"{"undo": \#(index > 0), "redo": false, "undo_label": "Step", "redo_label": "", "mode": "blender", "why": "scripted", "steps": \#(steps), "index": \#(index), "timing": {}}"#)]
    }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        if source.contains("_bk_undo.push(") {
            if !source.contains("replace=True") || index < 0 || rewound { index += 1 }
            rewound = false; steps = index + 1
            return state()
        }
        if source.contains("_bk_undo.rewind()") { index -= 1; rewound = true; return state() }
        if source.contains("print(_bk_adjustable)") { return [BpyLine(.output, "True"), BpyLine(.output, "Cube")] }
        return []
    }
}

print("\n== a tap read early is still the selection the redo panel re-runs on ==")
do {
    // The headline flow of round 4's review: Normal in Edit Mode reads
    // Blender on every tap (`captureWithSelection`), then a gizmo Move, then
    // a typed Move Z in the redo panel. The panel undoes the Move and runs it
    // again; the step it lands on is from before the tap, so the re-run has
    // to hand the tap over itself.
    let recorder = HistoryRecorder()
    let session = BpySession(runtime: recorder)
    let (s, o) = scene()
    session.bind(scene: s, undo: UndoStack())
    let bridge = BpyBridge(session: session, scene: s, undo: UndoStack())
    s.setMode(.edit)
    o.setEvaluatedMesh(o.mesh)
    s.editSelection.vertices = [0]
    s.editSelectionPending = true
    _ = bridge.captureWithSelection(OrientationBpy.report)
    let tap = Bpy.pushEditSelection(s.editSelection, mode: s.selectMode, of: o)
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let gs = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    let before = recorder.sources.count
    TransformGizmo.commit(.translate(SIMD3(0, 0, 0.25)), session: gs, bridge: bridge)
    let performed = recorder.sources.dropFirst(before).first { $0.contains("bpy.ops.transform.translate(") } ?? ""
    check("the Move carries the tap, though it was handed over for the read",
          performed.contains(tap) && performed.range(of: tap)!.lowerBound
            < performed.range(of: "bpy.ops.transform.translate(")!.lowerBound, performed)
    guard var op = bridge.adjustable else { check("the Move opens the redo panel", false); exit(1) }
    op["value.z"] = 0.5
    let rerunFrom = recorder.sources.count
    let rerun = bridge.readjust(op)
    let body = recorder.sources.dropFirst(rerunFrom).first { $0.contains("bpy.ops.transform.translate(") } ?? ""
    check("the redo panel's Move Z re-runs on the tap: rewound, then the tap, then the call",
          rerun != nil && recorder.sources.dropFirst(rerunFrom).first?.contains("_bk_undo.rewind()") == true
            && body.contains(tap) && body.range(of: tap)!.lowerBound
            < body.range(of: "bpy.ops.transform.translate(")!.lowerBound, body)
}
do {
    // The same flow in the review's order — tap, then Normal from the
    // Orientation menu, then a Move, then Move Z typed: the menu's setting
    // carries the tap to Blender and records no step, and the mirror clears
    // the tap's flag, so the Move has nothing pending to push. Its redo has
    // to hand the selection over all the same.
    let recorder = HistoryRecorder()
    let session = BpySession(runtime: recorder)
    let (s, o) = scene()
    session.bind(scene: s, undo: UndoStack())
    let bridge = BpyBridge(session: session, scene: s, undo: UndoStack())
    s.setMode(.edit)
    o.setEvaluatedMesh(o.mesh)
    // A step to rewind to before anything: the session's first.
    bridge.run("pass", undo: "Edit Mode")
    o.editTopology = EditTopology(vertexCount: o.mesh.vertices.count, polygonCount: o.mesh.indices.count / 3,
                                  trianglePolygons: (0..<(o.mesh.indices.count / 3)).map { UInt32($0) })
    s.editSelection.vertices = [3]
    s.editSelectionPending = true
    let tap = Bpy.pushEditSelection(s.editSelection, mode: s.selectMode, of: o)
    let menuFrom = recorder.sources.count
    bridge.run(OrientationBpy.set(.normal))
    check("the Orientation menu carries the tap, and records no step",
          recorder.sources.dropFirst(menuFrom).contains { $0.contains(tap) && $0.contains("set_tools(orientation='NORMAL')") }
            && !recorder.sources.dropFirst(menuFrom).contains { $0.contains("_bk_undo.push(") })
    // The mirror reads Blender's selection back, the tap's, and clears the flag.
    s.editSelectionPending = false
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let gs = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: g, scene: s, camera: camera, size: size)
    TransformGizmo.commit(.translate(SIMD3(0, 0, 0.25)), session: gs, bridge: bridge)
    guard var op = bridge.adjustable else { check("the Move opens the redo panel", false); exit(1) }
    op["value.z"] = 0.5
    let rerunFrom = recorder.sources.count
    let rerun = bridge.readjust(op)
    let body = recorder.sources.dropFirst(rerunFrom).first { $0.contains("bpy.ops.transform.translate(") } ?? ""
    check("its redo re-runs on the tap the setting carried", rerun != nil && body.contains(tap)
          && body.range(of: tap)!.lowerBound < body.range(of: "bpy.ops.transform.translate(")!.lowerBound, body)
    // Once a step holds the selection, the redo needs no push of its own.
    s.editSelection.vertices = [5]
    s.editSelectionPending = true
    bridge.run("pass", undo: "Select")
    let g2 = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let gs2 = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: g2, scene: s, camera: camera, size: size)
    TransformGizmo.commit(.translate(SIMD3(0, 0, 0.25)), session: gs2, bridge: bridge)
    if var op2 = bridge.adjustable {
        op2["value.z"] = 0.5
        let from2 = recorder.sources.count
        _ = bridge.readjust(op2)
        let body2 = recorder.sources.dropFirst(from2).first { $0.contains("bpy.ops.transform.translate(") } ?? ""
        check("and after a step that holds the selection, the redo pushes none", !body2.contains("_bk_bm.select_history"),
              body2)
    } else { check("the second Move opens the redo panel", false) }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
