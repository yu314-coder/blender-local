import Foundation
import simd
import CoreGraphics

// Snapping, the pivot point and proportional editing, on the Swift side: the
// mirror's packing, the Python the controls send, and where the gizmo pivots.
// What Blender makes of that Python is tests/tools/blender/verify.py.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
    abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

/// Three cubes at 0, 4 and 10 on X — the spread that tells a median (4.667)
/// from a bounds centre (5.0).
func spread() -> BKScene {
    let s = BKScene(startupFile: false)
    let objects = [Float(0), 4, 10].map { x -> BKObject in
        let o = s.add(.cube)
        o.location = SIMD3(x, 0, 0)
        return o
    }
    // After the last add, not as they go in: adding selects what it added.
    s.selection = Set(objects.map(\.id))
    s.activeID = objects.last!.id
    return s
}

print("== the mirror packs and unpacks every field ==")
do {
    var tools = TransformToolSettings()
    tools.useSnap = true
    tools.elements = [.vertex, .faceMidpoint]
    tools.individual = [.faceNearest]
    tools.target = .median
    tools.pivot = .individualOrigins
    tools.proportionalEdit = true
    tools.proportionalObjects = true
    tools.connected = true
    tools.falloff = .inverseSquare
    tools.size = 2.5
    tools.autoMerge = true
    tools.mergeThreshold = 0.0025
    tools.snapSelf = false
    tools.snapNonEdited = true
    let state = TransformToolsMirror.State(tools: tools, cursor: SIMD3(1.5, -2, 0.25))
    let scalars = TransformToolsMirror.scalars(state)
    check("eleven ints and five doubles", scalars.ints.count == 11 && scalars.doubles.count == 5,
          "\(scalars)")
    check("Auto Merge, Target Selection's bits and the threshold at the end",
          scalars.ints[9] == 1 && scalars.ints[10] == TransformToolsMirror.SnapTargetFlag.nonEdited
              && scalars.doubles[4] == Double(Float(0.0025)), "\(scalars)")
    let back = TransformToolsMirror.state(ints: scalars.ints, doubles: scalars.doubles)
    check("everything survives the round trip", back == state, String(describing: back))

    // The bit positions are the enum's raw values, which is what
    // _blenderkit_tools.ELEMENTS packs against.
    check("snap elements are a bit field",
          scalars.ints[1] == (1 << SnapElement.vertex.rawValue) | (1 << SnapElement.faceMidpoint.rawValue),
          "\(scalars.ints[1])")
    check("the enums are indices", scalars.ints[3] == 2 && scalars.ints[4] == 2,
          "\(scalars.ints[3]), \(scalars.ints[4])")
}

do {
    // A Blender that grew an identifier this build does not know must not trap.
    let state = TransformToolsMirror.state(ints: [1, 0, 0, 99, 99, 0, 0, 0, 99, 0, 3],
                                           doubles: [0, 0, 0, 0, -1])
    check("an unknown enum index falls back to Blender's default",
          state?.tools.target == .closest && state?.tools.pivot == .medianPoint
              && state?.tools.falloff == .smooth, String(describing: state))
    check("a size of zero falls back to 1", state?.tools.size == 1)
    check("a threshold outside bl_rna's 0..1 falls back to the factory's 0.001",
          state?.tools.mergeThreshold == 0.001)
    check("the factory's Auto Merge off and both Target Selection options on",
          TransformToolSettings().autoMerge == false && TransformToolSettings().mergeThreshold == 0.001
              && TransformToolSettings().snapSelf && TransformToolSettings().snapNonEdited)
    check("the old nine-and-four layout mirrors nothing, rather than shifting a field",
          TransformToolsMirror.state(ints: [1, 0, 0, 0, 0, 0, 0, 0, 0], doubles: [1, 0, 0, 0]) == nil)
    check("too few scalars mirror nothing",
          TransformToolsMirror.state(ints: [0], doubles: []) == nil)
}

print("\n== every control's Python names the helper and one setting ==")
do {
    let lines = [ToolsBpy.useSnap(true), ToolsBpy.elements([.vertex, .edge]),
                 ToolsBpy.individual([.faceNearest]), ToolsBpy.target(.median),
                 ToolsBpy.pivot(.cursor), ToolsBpy.proportional(true, editing: true),
                 ToolsBpy.connected(true), ToolsBpy.falloff(.inverseSquare),
                 ToolsBpy.size(2.5)]
    check("each imports _blenderkit_tools",
          lines.allSatisfy { $0.hasPrefix("import _blenderkit_tools\n_blenderkit_tools.set_tools(") })
    check("the magnet", ToolsBpy.useSnap(true).hasSuffix("set_tools(use_snap=True)"),
          ToolsBpy.useSnap(true))
    check("a set of identifiers, sorted so the log reads the same every time",
          ToolsBpy.elements([.vertex, .edge]).hasSuffix("set_tools(elements={'EDGE', 'VERTEX'})"),
          ToolsBpy.elements([.vertex, .edge]))
    check("proportional editing writes the mode's own switch",
          ToolsBpy.proportional(true, editing: true).hasSuffix("proportional_edit=True)")
              && ToolsBpy.proportional(true, editing: false).hasSuffix("proportional_objects=True)"))
    check("INVERSE_SQUARE is spelled out, not uppercased",
          ToolsBpy.falloff(.inverseSquare).contains("'INVERSE_SQUARE'"),
          ToolsBpy.falloff(.inverseSquare))
    check("the size is clamped to Blender's range",
          ToolsBpy.size(0).contains("size=0.00001") && ToolsBpy.size(90000).contains("size=5000.00000"),
          ToolsBpy.size(0) + " / " + ToolsBpy.size(90000))
    check("the cursor takes three numbers",
          ToolsBpy.setCursor(SIMD3(1.5, 0, -2)).hasSuffix("_blenderkit_tools.set_cursor(1.5000, 0.0000, -2.0000)"),
          ToolsBpy.setCursor(SIMD3(1.5, 0, -2)))
    check("the snap menu names the action",
          ToolsBpy.snap(.selectionToCursorKeepingOffset)
              .hasSuffix("_blenderkit_tools.snap('SELECTED_TO_CURSOR', use_offset=True)"))
    check("Auto Merge and its threshold, six places and clamped",
          ToolsBpy.autoMerge(true).hasSuffix("set_tools(automerge=True)")
              && ToolsBpy.mergeThreshold(0.0015).hasSuffix("set_tools(merge_threshold=0.001500)")
              && ToolsBpy.mergeThreshold(-1).hasSuffix("merge_threshold=0.000000)")
              && ToolsBpy.mergeThreshold(3).hasSuffix("merge_threshold=1.000000)"),
          ToolsBpy.mergeThreshold(0.0015))
    check("Target Selection's two",
          ToolsBpy.snapSelf(false).hasSuffix("set_tools(snap_self=False)")
              && ToolsBpy.snapNonEdited(true).hasSuffix("set_tools(snap_nonedit=True)"))
    var last = TransformToolSettings()
    check("the factory's lone Increment is the last element and cannot untick",
          last.holdsLastSnapElement)
    last.individual = [.faceProject]
    check("with Face Project beside it, either can (measured in 5.2.1)", !last.holdsLastSnapElement)
    last.elements = []
    check("and then Face Project cannot", last.holdsLastSnapElement)
    check("Selection to Grid carries the viewport's increment",
          ToolsBpy.snap(.selectionToGrid, increment: 0.25).hasSuffix("step=0.2500)"),
          ToolsBpy.snap(.selectionToGrid, increment: 0.25))
}

print("\n== the gizmo pivots where the tool settings say ==")
do {
    let s = spread()
    let cases: [(TransformPivot, SIMD3<Float>)] = [
        (.medianPoint, SIMD3(14.0 / 3, 0, 0)),
        (.boundingBoxCenter, SIMD3(5, 0, 0)),
        (.cursor, SIMD3(-1, 2, 3)),
        (.activeElement, SIMD3(10, 0, 0)),
        // No single point; Blender draws the gizmo at the median for it too.
        (.individualOrigins, SIMD3(14.0 / 3, 0, 0)),
    ]
    s.cursor = SIMD3(-1, 2, 3)
    for (pivot, want) in cases {
        s.tools.pivot = pivot
        check("\(pivot.label) pivots at \(want)",
              close(TransformGizmo.pivot(of: s) ?? .zero, want, 1e-3),
              String(describing: TransformGizmo.pivot(of: s)))
    }
    s.selection = []
    s.tools.pivot = .cursor
    check("and there is no gizmo at all with nothing selected",
          TransformGizmo.pivot(of: s) == nil)
}

print("\n== what a drag commits ==")

/// One drag on an axis handle, from `from` to `to` as fractions of the
/// handle's on-screen length, returning the Python the release sends.
func drag(_ mode: TransformGizmo.Mode, axis: Int, from: CGFloat, to: CGFloat,
          in scene: BKScene) -> (String, TransformGizmo.Session) {
    let g = TransformGizmo.make(mode: mode, scene: scene, options: options,
                                camera: camera, size: size)!
    let projection = TransformGizmo.Projection(camera: camera, size: size)
    let centre = projection.project(g.origin)!
    let tip = projection.project(g.origin + g.axes[axis] * g.radius)!
    func along(_ f: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + (tip.x - centre.x) * f, y: centre.y + (tip.y - centre.y) * f)
    }
    let session = TransformGizmo.beginSession(handle: .axis(axis), at: along(from), gizmo: g,
                                              scene: scene, camera: camera, size: size,
                                              options: options)
    let result = TransformGizmo.resolve(session, at: along(to))!
    TransformGizmo.apply(result, session: session)
    return (TransformGizmo.python(result, session: session), session)
}

/// A quarter turn on a rotation ring, measured on screen around its centre, as
/// tests/gizmo drives one.
func turn(axis: Int, in scene: BKScene) -> (String, TransformGizmo.Session) {
    let g = TransformGizmo.make(mode: .rotate, scene: scene, options: options,
                                camera: camera, size: size)!
    let centre = TransformGizmo.Projection(camera: camera, size: size).project(g.origin)!
    let session = TransformGizmo.beginSession(handle: .axis(axis),
                                              at: CGPoint(x: centre.x + 100, y: centre.y),
                                              gizmo: g, scene: scene, camera: camera, size: size,
                                              options: options)
    let result = TransformGizmo.resolve(session, at: CGPoint(x: centre.x, y: centre.y + 100))!
    TransformGizmo.apply(result, session: session)
    return (TransformGizmo.python(result, session: session), session)
}

do {
    let s = spread()
    let (median, _) = turn(axis: 2, in: s)
    // Not "no argument at all": measured in 5.2.1 headless, every
    // transform_pivot_point turns about the bounds centre (x = 5 for cubes at
    // 0, 4 and 10) while the gizmo previews about the median (4.667), so the
    // median has to be said out loud.
    check("Median Point sends the median it previewed",
          median.contains("center_override=(4.6667, 0.0000, 0.0000)"), median)

    let t = spread()
    t.tools.pivot = .cursor
    t.cursor = SIMD3(1.5, 0, -2)
    let (cursor, _) = turn(axis: 2, in: t)
    check("3D Cursor rotates about the cursor",
          cursor.contains("center_override=(1.5000, 0.0000, -2.0000)"), cursor)

    let u = spread()
    u.tools.pivot = .boundingBoxCenter
    let (bounds, _) = drag(.scale, axis: 0, from: 1, to: 1.6, in: u)
    check("Bounding Box Center scales about the bounds centre",
          bounds.contains("center_override=(5.0000, 0.0000, 0.0000)"), bounds)

    let v = spread()
    v.tools.pivot = .individualOrigins
    let (individual, _) = turn(axis: 2, in: v)
    check("Individual Origins is the helper, not one operator",
          individual.hasPrefix("import _blenderkit_tools\n_blenderkit_tools.transform_individual('ROTATE', ")
              && !individual.contains("center_override"), individual)
    check("and it leaves every object where it stood",
          v.objects.map(\.location).elementsEqual([SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(10, 0, 0)],
                                                  by: { close($0, $1) }),
          String(describing: v.objects.map(\.location)))
    check("while still turning them",
          v.objects.allSatisfy { abs($0.rotation.z) > 1e-3 },
          String(describing: v.objects.map(\.rotation)))
}

do {
    // Edit mode has no per-island origin to turn about, so Individual Origins
    // falls back to the gizmo's pivot — and that point still has to be named,
    // or Blender turns the vertices about the bounds centre instead.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.location = SIMD3(2, 0, 0)
    s.selection = [o.id]
    s.activeID = o.id
    s.setMode(.edit)
    s.editSelection.vertices = Set(o.mesh.vertices.indices.filter {
        o.mesh.vertices[$0].position.x > 0
    })
    s.tools.pivot = .individualOrigins
    let (python, session) = turn(axis: 2, in: s)
    check("Individual Origins while editing is one operator, about the pivot",
          python.hasPrefix("bpy.ops.transform.rotate(") && python.contains("center_override="),
          python)
    check("and the drag knows it is not the per-object path",
          !session.usesIndividualOrigins)
}

do {
    let s = spread()
    s.tools.proportionalObjects = true
    s.tools.falloff = .sharp
    s.tools.size = 3
    s.tools.connected = true
    let (python, session) = drag(.translate, axis: 0, from: 1, to: 1.5, in: s)
    check("proportional editing rides on the operator, not on tool_settings",
          python.contains("use_proportional_edit=True")
              && python.contains("proportional_edit_falloff='SHARP'")
              && python.contains("proportional_size=3.00000")
              && python.contains("use_proportional_connected=True"), python)
    check("and the drag captured the same falloff, size and Connected Only",
          session.proportional == ProportionalEdit(falloff: .sharp, size: 3, connected: true),
          String(describing: session.proportional))

    // Object mode reads use_proportional_edit_objects; edit mode reads the
    // other switch, so a scene with only the object one set must not turn it
    // on for an edit-mode drag.
    let t = spread()
    t.tools.proportionalObjects = true
    check("the object-mode switch does not apply while editing",
          !t.tools.isProportional(editing: true) && t.tools.isProportional(editing: false))
}

print("\n== the magnet is the scene's, the increment is the view's ==")
do {
    var tools = TransformToolSettings()
    check("off by default", !tools.snapsDrag && TransformSnap(tools: tools, step: 0.25) == nil)
    tools.useSnap = true
    check("on with Increment, which is Blender's default element",
          tools.snapsDrag && TransformSnap(tools: tools, step: 0.25)?.increment == true)
    tools.elements = [.vertex]
    check("on with Vertex alone, which GeometrySnap does and TransformSnap leaves alone",
          tools.snapsDrag && TransformSnap(tools: tools, step: 0.25) == nil)
    tools.elements = [.volume, .edgePerpendicular]
    check("off with only the two a drag does not reproduce",
          !tools.snapsDrag && TransformSnap(tools: tools, step: 0.25) == nil)
    tools.elements = [.grid]
    check("and on with Grid alone", tools.snapsDrag && TransformSnap(tools: tools, step: 0.25)?.grid == true)
    check("every element but Volume and Edge Perpendicular is honoured, and each says what it does",
          SnapElement.allCases.filter(\.isHonouredByDrag)
              == [.increment, .grid, .vertex, .edge, .face, .edgeMidpoint, .faceMidpoint]
              && SnapElement.increment.dragNote == "steps" && SnapElement.grid.dragNote == "moves only"
              && SnapElement.vertex.dragNote == "moves only" && SnapElement.face.dragNote == "moves only"
              && SnapElement.volume.dragNote == "scene setting"
              && SnapElement.edgePerpendicular.dragNote == "scene setting")
}

print("\n== Blender's falloff curves, over (size − d) / size ==")
do {
    // calculatePropRatio in transform_generics.cc, at half the size.
    let half: [(MeshEditor.ProportionalFalloff, Float)] = [
        (.sharp, 0.25), (.smooth, 0.5), (.root, 0.70710677), (.linear, 0.5),
        (.constant, 1), (.sphere, 0.8660254), (.inverseSquare, 0.75)]
    for (falloff, want) in half {
        let got = ProportionalEdit(falloff: falloff, size: 2).factor(distance: 1, random: 0.5)
        check("\(falloff.label) at half the size is \(want)", abs(got - want) < 1e-5, "\(got)")
    }
    check("Root is Blender's √(1 − t), not 1 − √t",
          abs(MeshEditor.ProportionalFalloff.root.weight(0.5) - 0.70710677) < 1e-5,
          "\(MeshEditor.ProportionalFalloff.root.weight(0.5))")
    let constant = ProportionalEdit(falloff: .constant, size: 2)
    check("strictly beyond the size, nothing", constant.factor(distance: 2.0001, random: 0.5) == 0)
    check("and Constant keeps its 1 right up to the rim", constant.factor(distance: 2, random: 0.5) == 1)
    let r = ProportionalEdit.previewRandom(7)
    check("Random's preview weight holds still for a drag",
          r == ProportionalEdit.previewRandom(7) && r >= 0 && r < 1
              && r != ProportionalEdit.previewRandom(8), "\(r)")
}

print("\n== proportional editing on objects, against Blender 5.2.1 ==")
do {
    // Measured: cubes at x = 0 (selected), 1, 2 and 5, LINEAR at size 3.
    let proportional = ProportionalEdit(falloff: .linear, size: 3)
    let poses = [Float(0), 1, 2, 5].map { ObjectPose(location: SIMD3($0, 0, 0), rotation: .zero, scale: .one) }
    let factors = [1] + TransformOperation.objectFactors(selected: [poses[0].location],
                                                         neighbours: poses.dropFirst().map(\.location),
                                                         proportional: proportional)
    func run(_ kind: TransformOperation.Kind) -> [ObjectPose] {
        TransformOperation(kind: kind, pivot: .point(.zero), orientation: .local, proportional: proportional)
            .apply(to: poses, factors: factors, selectedLocations: [.zero])
    }
    let moved = run(.translate(SIMD3(0, 0, 1)))
    check("a move pulls them 1, 0.6667, 0.3333 and 0 of the way",
          zip(moved.map(\.location.z), [Float(1), 0.6667, 0.3333, 0]).allSatisfy { abs($0 - $1) < 1e-4 },
          "\(moved.map(\.location.z))")
    let turned = run(.rotate(axis: SIMD3(0, 0, 1), angle: .pi / 2))
    check("a quarter turn turns them 60° and 30° about the centre",
          close(turned[1].location, SIMD3(0.5, 0.866, 0), 1e-3) && abs(turned[1].rotation.z - 1.0472) < 1e-3
              && close(turned[2].location, SIMD3(1.7321, 1, 0), 1e-3) && abs(turned[2].rotation.z - 0.5236) < 1e-3,
          "\(turned.map(\.location)) \(turned.map(\.rotation))")
    let scaled = run(.resize(SIMD3(repeating: 2)))
    check("a doubling scales them 1.6667 and 1.3333, and spreads them to 1.6667 and 2.6667",
          abs(scaled[1].scale.x - 1.6667) < 1e-4 && abs(scaled[2].scale.x - 1.3333) < 1e-4
              && abs(scaled[1].location.x - 1.6667) < 1e-4 && abs(scaled[2].location.x - 2.6667) < 1e-4,
          "\(scaled.map(\.location)) \(scaled.map(\.scale))")

    // Measured: B turned 45° at (1, 0, 0), CONSTANT, a LOCAL (2, 1, 1): B
    // scales along its own X, and its offset from the pivot does too.
    let b = ObjectPose(location: SIMD3(1, 0, 0), rotation: SIMD3(0, 0, .pi / 4), scale: .one)
    let local = TransformOperation(kind: .resize(SIMD3(2, 1, 1)), pivot: .point(.zero),
                                   orientation: .local,
                                   proportional: ProportionalEdit(falloff: .constant, size: 3))
        .apply(to: [ObjectPose(location: .zero, rotation: .zero, scale: .one), b],
               factors: [1, 1], selectedLocations: [.zero])
    check("a LOCAL resize reaches a turned neighbour along its own axes: (1.5, 0.5, 0), scale (2, 1, 1)",
          close(local[1].location, SIMD3(1.5, 0.5, 0), 1e-4) && close(local[1].scale, SIMD3(2, 1, 1), 1e-4),
          "\(local[1])")

    // Measured with a VIEW_3D override, so desktop Blender read Individual
    // Origins: A and B selected at 0 and 3, C at 1, D at (1.5, 1), LINEAR 2.
    let islands = [SIMD3<Float>(0, 0, 0), SIMD3(3, 0, 0), SIMD3(1, 0, 0), SIMD3(1.5, 1, 0)]
        .map { ObjectPose(location: $0, rotation: .zero, scale: .one) }
    let weights = [1, 1] + TransformOperation.objectFactors(
        selected: [islands[0].location, islands[1].location],
        neighbours: [islands[2].location, islands[3].location],
        proportional: ProportionalEdit(falloff: .linear, size: 2))
    let apart = TransformOperation(kind: .resize(SIMD3(repeating: 2)), pivot: .individualOrigins,
                                   orientation: .local)
        .apply(to: islands, factors: weights, selectedLocations: [islands[0].location, islands[1].location])
    check("Individual Origins scales each in place, neighbours by their share: 1.5 and 1.0986",
          zip(apart, islands).allSatisfy { close($0.location, $1.location) }
              && abs(apart[2].scale.x - 1.5) < 1e-4 && abs(apart[3].scale.x - 1.0986) < 1e-4,
          "\(apart.map(\.scale.x))")
}

print("\n== proportional editing on vertices ==")
do {
    // A row 0.25 apart. Measured in 5.2.1: the reach is in world space — a
    // grid scaled ×2 in X reached 11 vertices where the unscaled one reached 21.
    let row = (0..<9).map { SIMD3<Float>(Float($0) * 0.25, 0, 0) }
    let proportional = ProportionalEdit(falloff: .linear, size: 1)
    let plain = TransformOperation.vertexFactors(positions: row, selected: [0],
                                                 model: matrix_identity_float4x4,
                                                 proportional: proportional, connectivity: nil)
    let stretched = TransformOperation.vertexFactors(positions: row, selected: [0],
                                                     model: simd_float4x4(scale: SIMD3(2, 1, 1)),
                                                     proportional: proportional, connectivity: nil)
    check("the reach is measured in world space",
          plain.filter { $0 > 0 }.count == 4 && stretched.filter { $0 > 0 }.count == 2,
          "\(plain) \(stretched)")

    // A rotation in world space, on an object scaled unevenly: rotating the
    // mesh's own coordinates about a mapped axis shears it instead.
    let model = simd_float4x4(scale: SIMD3(2, 1, 1))
    let square = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0)]
    let turned = TransformOperation(kind: .rotate(axis: SIMD3(0, 0, 1), angle: .pi / 2), pivot: .point(.zero))
        .apply(toVertices: square, factors: [1, 1], selected: [0, 1], model: model)
    check("a quarter turn of a mesh scaled (2, 1, 1) keeps its world shape",
          close(turned[0], SIMD3(0, 2, 0)) && close(turned[1], SIMD3(-0.5, 0, 0)), "\(turned)")

    // The k-d tree against every pair.
    var generator = SystemRandomNumberGenerator()
    let cloud = (0..<400).map { _ in SIMD3<Float>(Float.random(in: -2...2, using: &generator),
                                                  Float.random(in: -2...2, using: &generator),
                                                  Float.random(in: -2...2, using: &generator)) }
    let chosen = Set((0..<400).filter { $0 % 13 == 0 })
    let tree = TransformOperation.nearestDistances(from: chosen, positions: cloud, within: 1.3)
    let brute = cloud.enumerated().map { i, p -> Float in
        if chosen.contains(i) { return 0 }
        let d = chosen.map { simd_distance(cloud[$0], p) }.min()!
        return d <= 1.3 ? d : .infinity
    }
    check("the nearest selected vertex, found by the tree, is the nearest by brute force",
          zip(tree, brute).allSatisfy { $0 == $1 || abs($0 - $1) < 1e-6 })

    // Connected Only: a strip bent into a U. Its two ends are 1 apart in the
    // air and 5 along the strip.
    var strip: [SIMD3<Float>] = []
    let path: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 2), SIMD2(1, 2), SIMD2(1, 0)]
    for p in path { strip += [SIMD3(p.x, p.y, 0), SIMD3(p.x, p.y, 0.2)] }
    var triangles: [UInt32] = []
    for k in 0..<3 {
        let a = UInt32(2 * k), b = a + 1, c = a + 2, d = a + 3
        triangles += [a, c, b, b, c, d]
    }
    let walk = MeshConnectivity(triangles: triangles, vertexCount: strip.count)
        .distances(from: [0], positions: strip)
    check("along the surface, the far end of a U is 5 away, not 1",
          abs(walk[6] - 5) < 1e-4, "\(walk)")
    let through = TransformOperation.nearestDistances(from: [0], positions: strip, within: 10)
    check("while through the air it is 1", abs(through[6] - 1) < 1e-5, "\(through)")

    // A vertex Blender has hidden (mesh.hide) is out of the transform: measured
    // in 5.2.1, the one hidden beside the selected corner of a 5 × 5 grid
    // stayed put under a LINEAR move of size 3 that lifted all 23 others.
    let hiddenFactors = TransformOperation.vertexFactors(positions: row, selected: [0],
                                                         model: matrix_identity_float4x4,
                                                         proportional: proportional, connectivity: nil,
                                                         hidden: [1])
    check("a hidden vertex in reach gets no share", hiddenFactors[1] == 0 && hiddenFactors[2] > 0,
          "\(hiddenFactors)")
    // Nor is it clipped: Blender's TransData never holds it.
    let clipped = TransformOperation(kind: .translate(SIMD3(0, 0, 0)), pivot: .point(.zero),
                                     proportional: proportional)
        .apply(toVertices: [SIMD3(0.0004, 0, 0), SIMD3(0.0004, 1, 0)], factors: [0, 0], selected: [],
               model: matrix_identity_float4x4,
               clipping: [MirrorClip(axes: [true, false, false], tolerance: 0.001)], hidden: [1])
    check("and a Mirror's clipping leaves it where it is",
          clipped[0].x == 0 && clipped[1].x == 0.0004, "\(clipped)")

    // The gizmo's edit drag reads them from the mirror's report.
    let s = BKScene(startupFile: false)
    let o = s.add(.plane)
    o.setMirroredMesh(MeshData(vertices: row.map { MeshVertex($0, SIMD3(0, 0, 1)) }, wireEdges: []))
    o.editTopology = EditTopology(vertexCount: row.count, polygonCount: 0, trianglePolygons: [],
                                  hiddenVertices: [1])
    check("an object says which of its vertices are hidden while its report still fits",
          o.hiddenEditVertices == [1])
    o.setMirroredMesh(MeshData(vertices: Array(row.prefix(3)).map { MeshVertex($0, SIMD3(0, 0, 1)) },
                               wireEdges: []))
    check("and none once the mesh has changed under it", o.hiddenEditVertices.isEmpty)
}

print("\n== snapping a drag: Increment steps, Grid lands ==")
do {
    var tools = TransformToolSettings()
    tools.useSnap = true
    let increment = TransformSnap(tools: tools, step: 0.25)!
    let axes = [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    func move(_ snap: TransformSnap, _ d: SIMD3<Float>, _ c: TransformSnap.Constraint,
              source: SIMD3<Float> = SIMD3(0.1, 0.37, 0.45),
              ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)? = nil) -> SIMD3<Float> {
        snap.translate(d, constraint: c, axes: axes, pivot: source, source: source, ray: ray,
                       viewNormal: SIMD3(0, 0, 1))
    }
    check("Increment rounds the drag, not where it lands",
          close(move(increment, SIMD3(0.37, 0, 0), .axis(0)), SIMD3(0.25, 0, 0))
              && close(move(increment, SIMD3(0.38, 0, 0), .axis(0)), SIMD3(0.5, 0, 0)))
    check("on a plane handle, the two axes of the plane",
          close(move(increment, SIMD3(0.37, -0.13, 0.2), .plane(2)), SIMD3(0.25, -0.25, 0)))
    check("and with no constraint, all three",
          close(move(increment, SIMD3(0.37, -0.13, 0.2), .free), SIMD3(0.25, -0.25, 0.25)))
    check("a turn in 5° steps, a scale in steps of 0.1",
          abs(increment.angle(37 * .pi / 180) - 35 * .pi / 180) < 1e-6
              && close(increment.factors(SIMD3(1.37, 1, 1)), SIMD3(1.4, 1, 1)))

    tools.elements = [.grid]
    let grid = TransformSnap(tools: tools, step: 0.25)!
    let along = move(grid, SIMD3(0.37, 0, 0), .axis(0))
    check("Grid puts the source on a grid line along the axis, and nowhere else",
          abs((0.1 + along.x) / 0.25 - ((0.1 + along.x) / 0.25).rounded()) < 1e-5
              && along.y == 0 && along.z == 0, "\(along)")
    let ground = move(grid, SIMD3(3, 3, 3), .free,
                      ray: (SIMD3(1.3, 0.6, 5), SIMD3(0, 0, -1)))
    check("with no constraint, onto the ground grid under the pointer",
          close(SIMD3(0.1, 0.37, 0.45) + ground, SIMD3(1.25, 0.5, 0)), "\(ground)")
    check("and Grid does not turn or scale", grid.angle(0.3) == 0.3 && grid.factors(SIMD3(1.37, 1, 1)).x == 1.37)
    tools.elements = [.grid, .increment]
    let both = TransformSnap(tools: tools, step: 0.25)!
    check("with both, Grid wins the move, Increment still steps a turn",
          close(move(both, SIMD3(0.37, 0, 0), .axis(0)), along)
              && abs(both.angle(37 * .pi / 180) - 35 * .pi / 180) < 1e-6)
}

print("\n== a drag commits what it previewed ==")
do {
    // Snapped: the value the preview moved by is the value the Python sends.
    let (s, made) = { () -> (BKScene, [BKObject]) in
        let s = BKScene(startupFile: false)
        let a = s.add(.cube); a.location = SIMD3(0.1, 0.37, 0.45)
        let b = s.add(.cube); b.location = SIMD3(4.3, -0.2, 0.45)
        s.selection = [a.id, b.id]; s.activeID = b.id
        s.tools.useSnap = true
        return (s, [a, b])
    }()
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let p = TransformGizmo.Projection(camera: camera, size: size)
    let c = p.project(g.origin)!, tip = p.project(g.origin + g.axes[0] * g.radius)!
    let start = CGPoint(x: tip.x, y: tip.y)
    let end = CGPoint(x: c.x + (tip.x - c.x) * 1.37, y: c.y + (tip.y - c.y) * 1.37)
    let session = TransformGizmo.beginSession(handle: .axis(0), at: start, gizmo: g, scene: s,
                                              camera: camera, size: size, options: options)
    let result = TransformGizmo.snapped(TransformGizmo.resolve(session, at: end)!, session: session, at: end)
    TransformGizmo.apply(result, session: session)
    let python = TransformGizmo.python(result, session: session)
    let dx = made[0].location.x - 0.1
    check("the preview moved by whole steps",
          abs(dx / 0.25 - (dx / 0.25).rounded()) < 1e-5 && abs(dx) > 0.2, "\(dx)")
    check("and the Python sends exactly that step",
          python.hasPrefix(String(format: "bpy.ops.transform.translate(value=(%.4f, 0.0000, 0.0000)", dx)),
          python)

    // Printed to four places, previewed to four places.
    check("the committed value is the printed one",
          TransformGizmo.committed(.translate(SIMD3(0.123456, -1.00004, 2))) == .translate(SIMD3(0.1235, -1, 2)))

    // Proportional in object mode: the neighbour moves in the preview and
    // comes back on a roll-back.
    let t = BKScene(startupFile: false)
    let a = t.add(.cube); a.location = .zero
    let n = t.add(.cube); n.location = SIMD3(1, 0, 0)
    let far = t.add(.cube); far.location = SIMD3(9, 0, 0)
    t.selection = [a.id]; t.activeID = a.id
    t.tools.proportionalObjects = true
    t.tools.falloff = .linear
    t.tools.size = 2
    let tg = TransformGizmo.make(mode: .translate, scene: t, options: options, camera: camera, size: size)!
    let ts = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: tg, scene: t,
                                         camera: camera, size: size, options: options)
    check("the drag finds the neighbour in reach and leaves the far one",
          ts.neighbours.count == 1 && ts.neighbours[0].object === n && abs(ts.neighbours[0].factor - 0.5) < 1e-6)
    TransformGizmo.apply(.translate(SIMD3(0, 0, 1)), session: ts)
    check("and the preview pulls it half way, as the commit will",
          abs(n.location.z - 0.5) < 1e-5 && far.location.z == 0, "\(n.location)")
    TransformGizmo.rollBack(ts)
    check("a roll-back puts the neighbour back too", n.location == SIMD3(1, 0, 0), "\(n.location)")

    // An edit-mode preview must not run the modifier stack over Blender's
    // evaluated mesh a second time.
    let e = BKScene(startupFile: false)
    let o = e.add(.cube)
    o.modifiers = [Modifier(kind: .subdivision)]
    let evaluated = MeshBuilder.make(.cube)
    o.setEvaluatedMesh(evaluated)
    e.selection = [o.id]; e.activeID = o.id
    e.setMode(.edit)
    e.editSelection.vertices = [0]
    let eg = TransformGizmo.make(mode: .translate, scene: e, options: options, camera: camera, size: size)!
    let es = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: eg, scene: e,
                                         camera: camera, size: size, options: options)
    TransformGizmo.apply(.translate(SIMD3(0, 0, 0.5)), session: es)
    check("an edit-mode preview keeps Blender's evaluated mesh evaluated",
          o.meshIsEvaluated && o.mesh.vertices.count == evaluated.vertices.count,
          "\(o.mesh.vertices.count) vertices, evaluated \(o.meshIsEvaluated)")
    TransformGizmo.rollBack(es)
    check("and so does its roll-back",
          o.meshIsEvaluated && o.mesh.vertices.map(\.position) == evaluated.vertices.map(\.position))
}

print("\n== the simulator numbers the edit selection on the cage, as Blender does ==")
do {
    // Round 2's review: taps picked on `obj.mesh`, the Swift stack's output,
    // while the drag moved `editCage`, the base. With a Mirror X and Bisect X
    // the stack renumbers: 22 of the first 24 output vertices sat somewhere
    // other than base[k], and a tap on output vertex 0 at (0,-1,1) put the
    // gizmo at (-1,-1,1), a cut-away base vertex, which the drag then moved.
    // Blender picks, selects, counts and edits on its edit mesh.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    var bisect = Modifier(kind: .mirror)
    bisect.bisectX = true
    o.modifiers = [bisect]
    s.selection = [o.id]; s.activeID = o.id
    s.setMode(.edit)
    let cage = o.editCage
    let shown = o.mesh
    let renumbered = (0..<min(cage.vertices.count, shown.vertices.count))
        .filter { simd_distance(cage.vertices[$0].position, shown.vertices[$0].position) > 1e-5 }.count
    check("the stack renumbers what it draws (\(renumbered) of \(cage.vertices.count) moved index)",
          cage.vertices.count == 24 && shown.vertices.count != 24 && renumbered > 0,
          "cage \(cage.vertices.count), shown \(shown.vertices.count)")
    let aspect = Float(size.width / size.height)
    let vp = camera.viewProjection(aspect: aspect) * o.modelMatrix
    var tapped = 0, rightVertex = 0, pivotOn = 0
    // The corner facing away is behind the cube, where a tap picks what is in
    // front of it; every other corner has its dot on screen.
    let eyeLocal = (o.modelMatrix.inverse * SIMD4(camera.eye, 1)).xyz
    let back = cage.vertices.map(\.position).max { simd_distance($0, eyeLocal) < simd_distance($1, eyeLocal) }!
    for k in cage.vertices.indices where simd_distance(cage.vertices[k].position, back) > 1e-5 {
        let c = vp * SIMD4(cage.vertices[k].position, 1)
        guard c.w > 0 else { continue }
        let ndc = SIMD2(c.x / c.w, c.y / c.w)
        let (origin, direction) = camera.ray(atNDC: ndc, aspect: aspect)
        let hit = MeshPicker.pick(mesh: o.editCage, topology: nil, mode: .vertex, ndc: ndc,
                                  viewSize: SIMD2(Float(size.width), Float(size.height)),
                                  viewProjection: vp, eye: camera.eye, ray: (origin, direction))
        guard let v = hit.vertex else { continue }
        tapped += 1
        if simd_distance(cage.vertices[v].position, cage.vertices[k].position) < 1e-5 { rightVertex += 1 }
        s.editSelection.vertices = [v]
        if let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size),
           simd_distance(g.origin, cage.vertices[v].position) < 1e-5 { pivotOn += 1 }
    }
    check("a tap on a vertex's dot picks that vertex of the cage (\(rightVertex) of \(tapped))",
          tapped > 0 && rightVertex == tapped)
    check("and the gizmo sits on the vertex tapped (\(pivotOn) of \(tapped))", pivotOn == tapped)
    // Box select numbers the cage too.
    let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    let all = o.editElements(in: rect, mode: .vertex, viewProjection: camera.viewProjection(aspect: aspect), size: size)
    check("a box around everything selects the cage's 24 vertices, not the drawn \(shown.vertices.count)",
          all.vertices == Set(0..<24), "\(all.vertices.count)")
}
do {
    // The simulator's mesh operators ran on the stack's output and put it
    // back as the base: Smooth Vertices took a cube under Mirror X from
    // 24 / 48 to 48 / 96, and Shade Smooth after it to 96 / 192.
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.modifiers = [Modifier(kind: .mirror)]
    s.selection = [o.id]; s.activeID = o.id
    s.setMode(.edit)
    s.editSelection.vertices = [0, 1]
    // What bk_scene_mesh_op and bk_scene_mesh_select_all run.
    let smooth = s.editMeshOperator("vertices_smooth", amount: 0.5)
    let flat = s.editMeshOperator("shade_smooth", amount: 0)
    let all = s.selectAllEditElements(true)
    check("Smooth Vertices and Shade Smooth keep 24 under the stack, drawn as 48",
          smooth == 0 && flat == 0 && o.evaluatedBase.vertices.count == 24 && o.mesh.vertices.count == 48,
          "\(o.evaluatedBase.vertices.count) / \(o.mesh.vertices.count)")
    check("and Select All selects the cage's 24", all >= 0 && s.editSelection.vertices == Set(0..<24),
          "\(s.editSelection.vertices.count)")
}

print("\n== the simulator's object operators run on the mesh its stack runs over ==")
do {
    // Round 3's review: Shade Smooth / Flat, the UV projections and Join, as
    // bk_scene_object_shade, bk_scene_uv_project and bk_scene_join_selected
    // ran them, took `obj.mesh`, the stack's output, and `setMirroredMesh`
    // ran the stack over it again: a cube under Mirror X went from 24 / 48
    // to 48 / 96. Each now delegates to the BKScene method run here.
    func mirroredCube(_ s: BKScene, at x: Float = 0) -> BKObject {
        let o = s.add(.cube, at: SIMD3(x, 0, 0))
        o.modifiers = [Modifier(kind: .mirror)]
        return o
    }
    func counts(_ o: BKObject) -> String { "\(o.evaluatedBase.vertices.count) / \(o.mesh.vertices.count)" }
    let s = BKScene(startupFile: false)
    let o = mirroredCube(s)
    s.selection = [o.id]; s.activeID = o.id
    let flat = s.setShading(smooth: false)
    check("Shade Flat keeps 24 under the Mirror, drawn as 48", flat == 1 && counts(o) == "24 / 48", counts(o))
    let smooth = s.setShading(smooth: true)
    let again = s.setShading(smooth: true)
    check("and Shade Smooth, twice, too", smooth == 1 && again == 1 && counts(o) == "24 / 48", counts(o))
    for kind in ["smart", "unwrap", "cube", "cylinder", "sphere"] {
        let u = mirroredCube(BKScene(startupFile: false))
        let projected = s.projectUVs(of: u, kind: kind)
        check("a \(kind) projection keeps 24 / 48 and maps the base's corners",
              projected?.count == 24 && counts(u) == "24 / 48", "\(counts(u)), \(String(describing: projected))")
    }
    let untouched = mirroredCube(BKScene(startupFile: false))
    check("a projection the stand-in does not model changes nothing",
          s.projectUVs(of: untouched, kind: "lightmap") == nil && counts(untouched) == "24 / 48")

    // Measured in desktop 5.2.1: a cube under Mirror joined with one under
    // Subdivision holds 8 + 8 vertices, keeps its Mirror and shows 32. The
    // stand-in's cube has 24 corners, so 24 + 24 under the Mirror, 96 shown.
    let j = BKScene(startupFile: false)
    let target = mirroredCube(j)
    let other = j.add(.cube, at: SIMD3(4, 0, 0))
    other.modifiers = [Modifier(kind: .subdivision)]
    j.selection = [target.id, other.id]; j.activeID = target.id
    let merged = j.joinSelection()
    check("Join merges the objects' own meshes and runs the target's stack once: 48 / 96",
          merged == 1 && counts(target) == "48 / 96" && j.objects.count == 1
            && target.modifiers.map(\.kind) == [.mirror], "\(merged), \(counts(target)), \(j.objects.count)")
}

print("\n== the simulator edits the mesh its modifier stack runs over ==")
do {
    // In the simulator `obj.mesh` is the stack's output, and installing it
    // back through `setMirroredMesh` ran the stack over it again. Measured
    // by this block before the fix: the preview showed 95 vertices over a
    // base of 48, the roll-back left 96, and the commit plus two more
    // translates reached 761 over a base of 381. The drag has to move the
    // base and let the stack run once, in the preview, the roll-back and the
    // commit alike.
    func mirrored(_ stack: [Modifier]) -> (BKScene, BKObject, Int) {
        let s = BKScene(startupFile: false)
        let o = s.add(.cube)
        o.modifiers = stack
        s.selection = [o.id]; s.activeID = o.id
        s.setMode(.edit)
        // A corner at x = +1: a -1.5 move takes it across the plane.
        let picked = o.evaluatedBase.vertices.firstIndex { $0.position.x > 0.9 }!
        s.editSelection.vertices = [picked]
        return (s, o, picked)
    }
    var clip = Modifier(kind: .mirror)
    clip.mirrorClip = true
    let (s, o, picked) = mirrored([clip])
    let base = o.evaluatedBase.vertices.map(\.position)
    let shown = o.mesh.vertices.count
    check("a cube with a Mirror X shows twice its base", base.count == 24 && shown == 48,
          "base \(base.count), shown \(shown)")

    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(0), at: .zero, gizmo: g, scene: s,
                                              camera: camera, size: size, options: options)
    let result = TransformGizmo.Result.translate(SIMD3(-1.5, 0, 0))
    TransformGizmo.apply(result, session: session)
    let previewBase = o.evaluatedBase.vertices.map(\.position)
    let previewShown = o.mesh.vertices.map(\.position)
    // 47, not 48: the clipped corner now sits on the plane, and Merge welds
    // it to its own image, as Blender's merge map does.
    check("the preview keeps the base's 24 and shows the stack's 47",
          previewBase.count == 24 && previewShown.count == 47,
          "base \(previewBase.count), shown \(previewShown.count)")
    check("the preview clips the picked corner to the plane rather than past it",
          previewBase.count > picked && previewBase[picked].x == 0
              && abs(previewBase[picked].y - base[picked].y) < 1e-6,
          previewBase.count > picked ? "\(previewBase[picked])" : "")
    check("and its mirrored image follows it, as Blender's does",
          previewShown == ModifierStack.apply(o.modifiers, to: o.evaluatedBase).vertices.map(\.position))

    TransformGizmo.rollBack(session)
    check("the roll-back restores the base and the 48 shown",
          o.evaluatedBase.vertices.map(\.position) == base && o.mesh.vertices.count == 48,
          "base \(o.evaluatedBase.vertices.count), shown \(o.mesh.vertices.count)")

    // A drag rolls back and then commits: the commit must land where the
    // preview did.
    s.perform(TransformGizmo.operation(result, session: session))
    check("the commit lands the base where the preview put it",
          o.evaluatedBase.vertices.map(\.position) == previewBase)
    check("and shows what the preview showed", o.mesh.vertices.map(\.position) == previewShown,
          "shown \(o.mesh.vertices.count)")

    for _ in 0..<2 {
        s.perform(TransformOperation(json: #"{"kind": "translate", "value": [0, 0, 0.25], "center": null}"#)!)
    }
    check("three commits leave the base at 24 and the view at 47",
          o.evaluatedBase.vertices.count == 24 && o.mesh.vertices.count == 47,
          "base \(o.evaluatedBase.vertices.count), shown \(o.mesh.vertices.count)")

    // Any modifier that makes geometry, not just a Mirror.
    let (t, sub, subPicked) = mirrored([Modifier(kind: .subdivision)])
    let subShown = sub.mesh.vertices.count
    t.perform(TransformOperation(json: #"{"kind": "translate", "value": [0, 0, 0.5], "center": null}"#)!)
    check("a Subdivision's base is moved, not its output",
          sub.evaluatedBase.vertices.count == 24 && sub.mesh.vertices.count == subShown
              && abs(sub.evaluatedBase.vertices[subPicked].position.z
                     - MeshBuilder.make(.cube).vertices[subPicked].position.z - 0.5) < 1e-6,
          "base \(sub.evaluatedBase.vertices.count), shown \(sub.mesh.vertices.count) of \(subShown)")

    // A vertex only the stack made has no base vertex to move: Blender's
    // cage does not contain it, so it cannot be picked there at all.
    let (u, only, _) = mirrored([clip])
    u.editSelection.vertices = [30]
    let untouched = only.evaluatedBase.vertices.map(\.position)
    check("a selection of stack-made vertices alone gets no gizmo",
          TransformGizmo.make(mode: .translate, scene: u, options: options, camera: camera, size: size) == nil)
    u.perform(TransformOperation(json: #"{"kind": "translate", "value": [1, 0, 0], "center": null}"#)!)
    check("and moves nothing when committed",
          only.evaluatedBase.vertices.map(\.position) == untouched && only.mesh.vertices.count == 48)
}

print("\n== the simulator's operators run the preview's operation ==")
do {
    func spreadWithReach() -> (BKScene, [BKObject]) {
        let s = BKScene(startupFile: false)
        let made = [SIMD3<Float>(0, 0, 0), SIMD3(4, 0, 0), SIMD3(1, 1, 0), SIMD3(9, 0, 0)].map { p -> BKObject in
            let o = s.add(.cube); o.location = p; return o
        }
        s.selection = [made[0].id, made[1].id]; s.activeID = made[1].id
        s.cursor = SIMD3(-1, 2, 0.5)
        s.tools.pivot = .cursor
        s.tools.proportionalObjects = true
        s.tools.falloff = .sphere
        s.tools.size = 2.5
        return (s, made)
    }
    let (previewed, shown) = spreadWithReach()
    let g = TransformGizmo.make(mode: .rotate, scene: previewed, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .axis(2), at: .zero, gizmo: g, scene: previewed,
                                              camera: camera, size: size, options: options)
    let result = TransformGizmo.Result.rotate(axis: SIMD3(0, 0, 1), angle: 0.7, axisIndex: 2)
    TransformGizmo.apply(result, session: session)
    // What _TransformOps in bpy/__init__.py sends for the Python this drag
    // commits: rotate(value=0.7000, orient_axis='Z', …, center_override=(-1, 2, 0.5)).
    let json = """
        {"kind": "rotate", "value": [0.7], "axis": [0, 0, 1], "orientation": "GLOBAL",
         "center": [-1.0, 2.0, 0.5],
         "proportional": {"falloff": "SPHERE", "size": 2.5, "connected": false}}
        """
    let (committed, landed) = spreadWithReach()
    guard let operation = TransformOperation(json: json) else {
        check("the stand-in reads its own call", false, json)
        exit(1)
    }
    committed.perform(operation)
    check("the stand-in's rotate lands every object where the preview put it",
          zip(shown, landed).allSatisfy {
              close($0.location, $1.location) && close($0.rotation, $1.rotation) && close($0.scale, $1.scale)
          }, "\(shown.map(\.location)) vs \(landed.map(\.location))")
    check("the neighbour in reach included, and not the far one",
          landed[2].location != SIMD3(1, 1, 0) && landed[3].location == SIMD3(9, 0, 0))

    // Edit mode: the selected vertices of the active object, not the object.
    let e = BKScene(startupFile: false)
    let o = e.add(.cube)
    o.location = SIMD3(1, 0, 0)
    e.selection = [o.id]; e.activeID = o.id
    e.setMode(.edit)
    e.editSelection.vertices = [0, 1]
    let before = o.mesh.vertices.map(\.position)
    e.perform(TransformOperation(json: #"{"kind": "translate", "value": [0, 0, 0.5], "center": null}"#)!)
    let after = o.mesh.vertices.map(\.position)
    check("while editing, a translate moves the selected vertices and leaves the object",
          o.location == SIMD3(1, 0, 0) && abs(after[0].z - before[0].z - 0.5) < 1e-5
              && zip(before, after).enumerated().allSatisfy { i, pair in i < 2 || pair.0 == pair.1 })

    check("anything it cannot read is refused rather than guessed at",
          TransformOperation(json: "{}") == nil
              && TransformOperation(json: #"{"kind": "shear", "value": [1]}"#) == nil
              && TransformOperation(json: #"{"kind": "resize", "value": [2, 2, 2], "orientation": "NORMAL"}"#) == nil
              && TransformOperation(json: #"{"kind": "translate", "value": [1, 0, 0], "proportional": {"falloff": "WOBBLY", "size": 1}}"#) == nil)
}

print("\n== the Snap menu, in Blender's order ==")
do {
    // VIEW3D_MT_snap in 5.2.1's space_view3d.py; the Blender check reads it
    // from Blender itself.
    check("four Selection actions, then four Cursor ones",
          SnapAction.allCases.map(\.title) == ["Selection to Grid", "Selection to Cursor",
                                               "Selection to Cursor (Keep Offset)", "Selection to Active",
                                               "Cursor to Selected", "Cursor to World Origin",
                                               "Cursor to Grid", "Cursor to Active"])
    check("the cursor's own two need nothing selected; the two 'to Active' need an active object",
          SnapAction.allCases.filter { !$0.needsSelection } == [.cursorToCenter, .cursorToGrid]
              && SnapAction.allCases.filter(\.needsActive) == [.selectionToActive, .cursorToActive])
    check("Cursor to Grid carries the viewport's increment",
          ToolsBpy.snap(.cursorToGrid, increment: 0.5).hasSuffix("snap('CURSOR_TO_GRID', step=0.5000)"),
          ToolsBpy.snap(.cursorToGrid, increment: 0.5))

    // The simulator's own versions.
    let s = BKScene(startupFile: false)
    let a = s.add(.cube); a.location = SIMD3(0.3, 0.7, -1.2)
    let b = s.add(.cube); b.location = SIMD3(4.4, 0.5, 0)
    s.selection = [a.id, b.id]; s.activeID = b.id
    s.cursor = SIMD3(-0.25, 0.25, 1.25)
    s.snapCursorToGrid(increment: 0.5)
    check("Cursor to Grid rounds halves upward, as view3d_snap.cc does",
          s.cursor == SIMD3(0, 0.5, 1.5), "\(s.cursor)")
    s.snapCursorToActive()
    check("Cursor to Active", s.cursor == SIMD3(4.4, 0.5, 0))
    s.snapSelectionToActive()
    check("Selection to Active", a.location == SIMD3(4.4, 0.5, 0) && b.location == SIMD3(4.4, 0.5, 0))
}

print("\n== undo carries the cursor and the settings ==")
do {
    let s = BKScene(startupFile: false)
    s.cursor = SIMD3(3, -1, 0.5)
    s.tools.pivot = .cursor
    s.tools.useSnap = true
    s.tools.size = 4
    let snapshot = s.snapshot()
    s.cursor = .zero
    s.tools = TransformToolSettings()
    s.restore(snapshot)
    check("the cursor comes back", close(s.cursor, SIMD3(3, -1, 0.5)), "\(s.cursor)")
    check("and the tool settings", s.tools.pivot == .cursor && s.tools.useSnap && s.tools.size == 4,
          String(describing: s.tools))

    // A snapshot written before either existed still restores.
    var old = snapshot
    old.cursor = nil
    old.tools = nil
    s.cursor = SIMD3(9, 9, 9)
    s.restore(old)
    check("an older snapshot leaves them alone rather than zeroing them",
          close(s.cursor, SIMD3(9, 9, 9)), "\(s.cursor)")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
