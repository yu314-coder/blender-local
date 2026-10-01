import Foundation
import simd

// The Transform fields on the Swift side: the eleven numbers the mirror sends,
// where they go, what the fields show when they are missing, the Python one
// field's edit sends, and the preview of it. What Blender makes of all of it
// is scripts/run-transformfields-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// One `sync_push` with an identity mesh-less object at `matrix`.
func pushed(_ name: String, _ m: simd_float4x4 = matrix_identity_float4x4) -> BKObject {
    var rowMajor = [Double](repeating: 0, count: 16)
    for c in 0..<4 { for r in 0..<4 { rowMajor[4 * r + c] = Double(m[c][r]) } }
    return rowMajor.withUnsafeBufferPointer { matrix in
        [Float]().withUnsafeBufferPointer { empty in
            [UInt32]().withUnsafeBufferPointer { none in
                SceneMirror.object(named: name, kind: "MESH", matrix: matrix, positions: empty,
                                   normals: empty, triangles: none, colour: nil, previous: nil)!.object
            }
        }
    }
}

print("== the eleven numbers ==")
do {
    let c = TransformChannels([1, 2, 3, 4, 0.1, 0.2, 0.3, 0, 1, 2, 3])
    check("location, mode, rotation, scale", c?.location == SIMD3(1, 2, 3) && c?.rotationMode == .euler("ZXY")
          && c?.rotation == SIMD4(0.1, 0.2, 0.3, 0) && c?.scale == SIMD3(1, 2, 3))
    let orders = (0..<6).compactMap { TransformChannels([0, 0, 0, Double($0), 0, 0, 0, 0, 1, 1, 1])?.rotationMode }
    check("the six Euler orders in _ROTATION_MODES' order",
          orders == ["XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX"].map { .euler($0) })
    check("6 is a quaternion, 7 an axis angle",
          TransformChannels([0, 0, 0, 6, 1, 0, 0, 0, 1, 1, 1])?.rotationMode == .quaternion
          && TransformChannels([0, 0, 0, 7, 0, 0, 0, 1, 1, 1, 1])?.rotationMode == .axisAngle)
    for bad in [8.0, 2.5, -1, .nan] {
        check("a mode numbered \(bad) is no mode", TransformChannels([0, 0, 0, bad, 0, 0, 0, 0, 1, 1, 1]) == nil)
    }
    check("ten numbers are not channels", TransformChannels([0, 0, 0, 0, 0, 0, 0, 1, 1, 1]) == nil)
    let nan = TransformChannels([.nan, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1])
    check("a NaN Blender holds is shown, not hidden", nan != nil && nan!.location.x.isNaN)
}

print("\n== the fields of each mode ==")
do {
    let euler = TransformChannels(location: SIMD3(1, 2, 3), rotationMode: .euler("XYZ"),
                                  rotation: SIMD4(0.1, 0.2, 0.3, 0), scale: SIMD3(4, 5, 6))
    check("Euler: X Y Z, in degrees", euler.axes(.rotation) == ["X", "Y", "Z"]
          && euler.values(.rotation) == [0.1, 0.2, 0.3] && (0..<3).allSatisfy { euler.isAngle(.rotation, axis: $0) })
    let quat = TransformChannels(location: .zero, rotationMode: .quaternion,
                                 rotation: SIMD4(1, 0.1, 0.2, 0.3), scale: .one)
    check("Quaternion: W X Y Z, none an angle", quat.axes(.rotation) == ["W", "X", "Y", "Z"]
          && quat.values(.rotation) == [1, 0.1, 0.2, 0.3] && !(0..<4).contains { quat.isAngle(.rotation, axis: $0) })
    let axisAngle = TransformChannels(location: .zero, rotationMode: .axisAngle,
                                      rotation: SIMD4(0.5, 0, 0, 1), scale: .one)
    check("Axis Angle: W is the angle, in degrees, the axis is not",
          axisAngle.isAngle(.rotation, axis: 0) && !axisAngle.isAngle(.rotation, axis: 1))
    check("Location and Scale are never angles",
          !euler.isAngle(.location, axis: 0) && !euler.isAngle(.scale, axis: 0))
    check("each writes its own property", euler.rotationMode.property == "rotation_euler"
          && quat.rotationMode.property == "rotation_quaternion"
          && axisAngle.rotationMode.property == "rotation_axis_angle")
    check("setting a field changes that field alone",
          euler.setting(.scale, axis: 1, to: 9) == TransformChannels(location: SIMD3(1, 2, 3), rotationMode: .euler("XYZ"),
                                                                     rotation: SIMD4(0.1, 0.2, 0.3, 0), scale: SIMD3(4, 9, 6)))
    check("an Euler has no fourth field to set", euler.setting(.rotation, axis: 3, to: 9) == euler)
    check("a quaternion's W is its first", quat.setting(.rotation, axis: 0, to: 0.5).rotation == SIMD4(0.5, 0.1, 0.2, 0.3))
}

print("\n== the Python an edit sends ==")
do {
    let start = TransformChannels(location: SIMD3(1.234567, 2, 3), rotationMode: .euler("XYZ"),
                                  rotation: SIMD4(.pi / 2, 0, 0, 0), scale: .one)
    let name = Bpy.quote("Cube")
    check("one field, one assignment to that component",
          start.python(writing: start.setting(.location, axis: 2, to: 3.01), to: "Cube")
              == "bpy.data.objects[\(name)].location[2] = 3.01")
    // The old write sent all three at four places: a 90° X came back 90.0002°
    // when Z was edited, and X 1.234567 came back 1.2346.
    let turned = start.python(writing: start.setting(.rotation, axis: 2, to: 0.5), to: "Cube") ?? ""
    check("the fields left alone are not written at all", turned == "bpy.data.objects[\(name)].rotation_euler[2] = 0.5"
          && !turned.contains("1.2346"), turned)
    let tiny = start.python(writing: start.setting(.scale, axis: 0, to: 1e-5), to: "Cube") ?? ""
    check("the number is the field's own Float, to its shortest exact form",
          tiny.hasSuffix("scale[0] = 1e-05") && Float(tiny.components(separatedBy: " = ").last!) == 1e-5, tiny)
    check("nothing changed sends nothing", start.python(writing: start, to: "Cube") == nil)
    check("a value Python cannot read sends nothing",
          start.python(writing: start.setting(.location, axis: 0, to: .infinity), to: "Cube") == nil)
    let quat = TransformChannels(location: .zero, rotationMode: .quaternion, rotation: SIMD4(1, 0, 0, 0), scale: .one)
    check("a quaternion's W is rotation_quaternion[0]",
          quat.python(writing: quat.setting(.rotation, axis: 0, to: 0.5), to: "Cube")
              == "bpy.data.objects[\(name)].rotation_quaternion[0] = 0.5")
    check("a name with quotes is quoted",
          start.python(writing: start.setting(.location, axis: 0, to: 0), to: "it's \"x\"")?
              .hasPrefix("bpy.data.objects[\(Bpy.quote("it's \"x\""))]") == true)
}

print("\n== the turn each mode makes ==")
do {
    let e = SIMD3<Float>(0.3, -0.7, 1.1)
    let xyz = TransformChannels(location: .zero, eulerXYZ: e, scale: .one)
    let built = simd_float4x4(xyz.turn), expected = simd_float4x4(eulerXYZ: e)
    check("XYZ is the viewport's own Euler", (0..<4).allSatisfy { simd_distance(built[$0], expected[$0]) < 1e-6 })
    // ZXY: Z first, then X, then Y, so Y is the leftmost factor.
    let zxy = TransformChannels(location: .zero, rotationMode: .euler("ZXY"), rotation: SIMD4(e, 0), scale: .one)
    let rx = simd_float4x4(eulerXYZ: SIMD3(e.x, 0, 0)), ry = simd_float4x4(eulerXYZ: SIMD3(0, e.y, 0))
    let rz = simd_float4x4(eulerXYZ: SIMD3(0, 0, e.z))
    let zxyBuilt = simd_float4x4(zxy.turn), zxyExpected = ry * rx * rz
    check("ZXY turns about Z, then X, then Y", (0..<4).allSatisfy { simd_distance(zxyBuilt[$0], zxyExpected[$0]) < 1e-6 })
    let zero = TransformChannels(location: .zero, rotationMode: .quaternion, rotation: .zero, scale: .one)
    check("a zero quaternion is a half turn about X, as Blender normalises it",
          simd_distance(simd_float4x4(zero.turn).columns.1, SIMD4(0, -1, 0, 0)) < 1e-6)
    let noAxis = TransformChannels(location: .zero, rotationMode: .axisAngle, rotation: SIMD4(1, 0, 0, 0), scale: .one)
    check("an axis angle with no axis turns nothing", abs(noAxis.turn.angle) < 1e-6)
}

print("\n== where the mirror puts them ==")
do {
    let values: [Double] = [0, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1]
    let a = pushed("A"), b = pushed("B")
    check("during a pass, onto the object the pass pushed",
          SceneMirror.carryChannels(values, named: "A", pass: [a, b], screen: []) == 1
              && a.channels?.location == SIMD3(0, 3, 0) && b.channels == nil)
    check("a pass that never pushed the name is refused",
          SceneMirror.carryChannels(values, named: "C", pass: [a, b], screen: []) == -1)
    check("a frame change updates the object on screen",
          SceneMirror.carryChannels([0, 4, 0, 0, 0, 0, 0, 0, 1, 1, 1], named: "B", pass: nil, screen: [a, b]) == 1
              && b.channels?.location == SIMD3(0, 4, 0))
    check("and skips a name the screen does not hold",
          SceneMirror.carryChannels(values, named: "Gone", pass: nil, screen: [a, b]) == 0)
    check("ten numbers are malformed",
          SceneMirror.carryChannels(Array(values.prefix(10)), named: "A", pass: [a], screen: []) == -1)
    check("an unknown mode arrives as unknown",
          SceneMirror.carryChannels([0, 0, 0, 9, 0, 0, 0, 0, 1, 1, 1], named: "A", pass: [a], screen: []) == 1
              && a.channels == nil)

    // The merge: an object already on screen takes the channels and parent the
    // new pass brought.
    let scene = BKScene(startupFile: false)
    let onScreen = pushed("Cube")
    _ = SceneMirror.carryChannels(values, named: "Cube", pass: [onScreen], screen: [])
    scene.objects = [onScreen]
    let fresh = pushed("Cube")
    _ = SceneMirror.carryChannels([5, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1], named: "Cube", pass: [fresh], screen: [])
    _ = SceneMirror.carryRelations(parent: "Holder", dependencies: ["Holder"], named: "Cube", pass: [fresh])
    SceneMirror.merge([fresh], into: scene, unchanged: [], selection: [], active: nil)
    check("the merge carries a new pass's channels onto the object on screen",
          scene.objects.first === onScreen && onScreen.channels?.location == SIMD3(5, 0, 0))
    check("and its parent, which Properties ▸ Relations shows", onScreen.parentName == "Holder")
}

print("\n== what the fields show without them ==")
do {
    let local = BKObject(name: "Local", kind: .cube, location: SIMD3(1, 2, 3), rotation: SIMD3(0.1, 0, 0), scale: .one)
    check("an object nothing mirrors shows its own channels, XYZ Euler",
          local.shownChannels == TransformChannels(location: SIMD3(1, 2, 3), eulerXYZ: SIMD3(0.1, 0, 0), scale: .one))
    let mirrored = pushed("Mirrored", simd_float4x4(translation: SIMD3(7, 0, 0)))
    check("an object from Blender without its channels shows nothing rather than its world position",
          mirrored.shownChannels == nil && mirrored.location == SIMD3(7, 0, 0))
    check("and no edit can start on it", TransformFieldEdit(object: mirrored, scene: BKScene(startupFile: false)) == nil)
}

print("\n== the preview ==")
do {
    // The review's scene, as the mirror would send it: Parent at (2, 0, 0)
    // turned 90° about Z, Child's location (0, 3, 0) under it with an identity
    // parent inverse, so Child is drawn at (-1, 0, 0).
    let parentWorld = simd_float4x4(translation: SIMD3(2, 0, 0)) * simd_float4x4(eulerXYZ: SIMD3(0, 0, .pi / 2))
    let childWorld = parentWorld * simd_float4x4(translation: SIMD3(0, 3, 0))
    let scene = BKScene(startupFile: false)
    let parent = pushed("Parent", parentWorld), child = pushed("Child", childWorld)
    _ = SceneMirror.carryChannels([2, 0, 0, 0, 0, 0, Double.pi / 2, 0, 1, 1, 1], named: "Parent", pass: [parent], screen: [])
    _ = SceneMirror.carryLocal([2, 0, 0, cos(.pi / 4), 0, 0, sin(.pi / 4), 1, 1, 1], named: "Parent", pass: [parent], screen: [])
    _ = SceneMirror.carryChannels([0, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1], named: "Child", pass: [child], screen: [])
    _ = SceneMirror.carryLocal([0, 3, 0, 1, 0, 0, 0, 1, 1, 1], named: "Child", pass: [child], screen: [])
    _ = SceneMirror.carryRelations(parent: "Parent", dependencies: ["Parent"], named: "Child", pass: [child])
    scene.objects = [parent, child]
    check("the child is drawn at (-1, 0, 0) and its field shows (0, 3, 0)",
          simd_distance(child.modelMatrix.columns.3, SIMD4(-1, 0, 0, 1)) < 1e-5
              && child.shownChannels?.location == SIMD3(0, 3, 0))

    var nudge = TransformFieldEdit(object: child, scene: scene)!
    nudge.change(.location, axis: 2, to: 0.01)
    check("a nudge of Z by 0.01 is previewed 0.01 up, where Blender will put it",
          simd_distance(child.modelMatrix.columns.3, SIMD4(-1, 0, 0.01, 1)) < 1e-5, "\(child.modelMatrix.columns.3)")
    check("the edit holds the field's value", nudge.edited.location == SIMD3(0, 3, 0.01))
    nudge.rollBackDrawing()
    check("the roll-back draws it where it was", child.modelMatrix == childWorld)

    var turn = TransformFieldEdit(object: parent, scene: scene)!
    turn.change(.rotation, axis: 2, to: 0)
    check("turning the parent back to 0 carries the child to (2, 3, 0)",
          simd_distance(child.modelMatrix.columns.3, SIMD4(2, 3, 0, 1)) < 1e-5, "\(child.modelMatrix.columns.3)")
    turn.rollBackDrawing()
    check("and the roll-back puts both back", parent.modelMatrix == parentWorld && child.modelMatrix == childWorld)

    // An object nothing mirrors previews by its own channels.
    let local = BKObject(name: "Local", kind: .cube, location: SIMD3(1, 2, 3))
    let plain = BKScene(startupFile: false)
    plain.objects = [local]
    var move = TransformFieldEdit(object: local, scene: plain)!
    move.change(.location, axis: 0, to: 5)
    check("an object nothing mirrors is previewed by its own channels", local.location == SIMD3(5, 2, 3))
    move.rollBackDrawing()
    check("and put back", local.location == SIMD3(1, 2, 3))

    // Mid gizmo drag: Blender's channels, no matrix. Not where it is drawn, so
    // nothing is previewed and nothing is moved.
    let dragged = pushed("Dragged")
    _ = SceneMirror.carryChannels([0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1], named: "Dragged", pass: [dragged], screen: [])
    dragged.location = SIMD3(4, 0, 0)          // what a gizmo drag does
    let mid = BKScene(startupFile: false)
    mid.objects = [dragged]
    var during = TransformFieldEdit(object: dragged, scene: mid)!
    during.change(.location, axis: 1, to: 2)
    check("channels without a matrix preview nothing, and move nothing",
          during.previewedWorld == nil && dragged.location == SIMD3(4, 0, 0))

    // A zero scale hides the delta scale the preview would need.
    let flat = pushed("Flat", simd_float4x4(scale: SIMD3(0, 1, 1)))
    _ = SceneMirror.carryChannels([0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1], named: "Flat", pass: [flat], screen: [])
    _ = SceneMirror.carryLocal([0, 0, 0, 1, 0, 0, 0, 0, 1, 1], named: "Flat", pass: [flat], screen: [])
    let flatScene = BKScene(startupFile: false)
    flatScene.objects = [flat]
    var squash = TransformFieldEdit(object: flat, scene: flatScene)!
    squash.change(.location, axis: 0, to: 1)
    check("a zero scale previews nothing rather than a guess", squash.previewedWorld == nil
          && flat.modelMatrix == simd_float4x4(scale: SIMD3(0, 1, 1)))
    check("but the edit still writes", squash.python != nil)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
