import Foundation
import simd

// The modifier panel's three halves: the Python each row sends to Blender, the
// mirror record Blender sends back, and the simulator's own mesh operations.
//
// The panel has shipped controls that wrote to the display cache and reached
// Blender with nothing at all, three times. A row is only finished when the
// Python leaves here and the value comes back, so both directions are checked
// for every setting — including the ones that were already here, because the
// integer half of the readback had never worked.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) < eps }

/// A record in exactly the shape `_blenderkit_sync.py` builds: `key=value`
/// joined by `;`, entries joined by `|`, and — this is the part that bit —
/// every number run through `repr(float(v))`, so an integer arrives as "2.0".
func record(_ entries: String...) -> String { entries.joined(separator: "|") }

print("== integers survive the round trip ==")
do {
    // repr(float(3)) is "3.0" and Int("3.0") is nil, so every integer setting
    // used to fall back to its default on the first sync after it was set.
    let stack = Modifier.stack(from: record(
        "kind=SUBSURF;name=Subdivision;levels=3.0",
        "kind=ARRAY;name=Array;count=7.0",
        "kind=BEVEL;name=Bevel;width=0.02;segments=4.0",
        "kind=SMOOTH;name=Smooth;factor=0.75;iterations=6.0"))
    check("levels", stack[0].levels == 3, "\(stack[0].levels)")
    check("count", stack[1].count == 7, "\(stack[1].count)")
    check("segments", stack[2].segments == 4, "\(stack[2].segments)")
    check("iterations", stack[3].iterations == 6, "\(stack[3].iterations)")
    check("floats still parse", close(stack[3].factor, 0.75), "\(stack[3].factor)")
}

print("\n== nonsense in the record cannot crash the panel ==")
do {
    // Int(Float) traps on both of these, and the record is written by whatever
    // a script left in the scene.
    let stack = Modifier.stack(from: record(
        "kind=SUBSURF;name=Subdivision;levels=nan",
        "kind=ARRAY;name=Array;count=1e30"))
    check("a NaN integer is ignored", stack[0].levels == 1, "\(stack[0].levels)")
    check("an out-of-range integer is ignored", stack[1].count == 2, "\(stack[1].count)")
}

print("\n== Shrinkwrap ==")
do {
    let m = Modifier.stack(from: record(
        "kind=SHRINKWRAP;name=Shrinkwrap;wrap_method=NEAREST_SURFACEPOINT;"
        + "offset=0.25;target=Cube"))[0]
    check("kind", m.kind == .shrinkwrap)
    // Matched on the identifier: NEAREST_SURFACEPOINT is one word where the
    // label is two, so a lowercased rawValue would never match.
    check("wrap_method", m.wrapMethod == .nearestSurfacePoint, "\(m.wrapMethod)")
    check("offset", close(m.thickness, 0.25), "\(m.thickness)")
    check("target", m.targetName == "Cube", m.targetName)

    var set = Modifier(kind: .shrinkwrap)
    set.targetName = "Cube"
    let lines = Bpy.modifierSettings(set)
    // ShrinkwrapModifier has no `object`; assigning it raises AttributeError,
    // which would take the rest of this batch down with it.
    check("the pointer is `target`, never `object`",
          lines.contains { $0.contains(".target = bpy.data.objects[\"Cube\"]") }
          && !lines.contains { $0.contains(".object =") }, lines.joined(separator: " / "))
    check("the pointer goes last", lines.last!.contains(".target ="), lines.last!)
    check("no target, no assignment",
          !Bpy.modifierSettings(Modifier(kind: .shrinkwrap)).contains { $0.contains("target") })
    check("offset is still sent with no target",
          Bpy.modifierSettings(Modifier(kind: .shrinkwrap)).contains { $0.contains(".offset =") })
}

print("\n== Screw ==")
do {
    let m = Modifier.stack(from: record(
        "kind=SCREW;name=Screw;angle=6.2831854820251465;steps=24.0;axis=Y;screw_offset=0.5"))[0]
    check("kind", m.kind == .screw)
    check("steps", m.count == 24, "\(m.count)")
    check("angle", close(m.angle, 2 * .pi), "\(m.angle)")
    // Screw spells it `axis`, Simple Deform spells it `deform_axis` and Wave
    // spells it as booleans. Three names for one idea, all in Blender.
    check("axis Y is index 1", m.axis == 1, "\(m.axis)")
    check("screw_offset", close(m.thickness, 0.5), "\(m.thickness)")

    let fresh = Modifier(kind: .screw)
    check("a new Screw is Blender's full turn, not 45 degrees",
          close(fresh.angle, 2 * .pi), "\(fresh.angle)")
    check("a new Screw is 16 steps", fresh.count == 16, "\(fresh.count)")
    check("a new Screw is a lathe until screw_offset is set", fresh.thickness == 0)

    let lines = Bpy.modifierSettings(fresh)
    // The Subdivision levels/render_levels trap: a viewport value a render
    // would otherwise ignore.
    check("render_steps rides with steps", lines.contains { $0.contains("render_steps = 16") })
    check("axis is the enum string, not an index",
          lines.contains { $0.contains("axis = \"Z\"") })
}

print("\n== Decimate ==")
do {
    let m = Modifier.stack(from: record(
        "kind=DECIMATE;name=Decimate;ratio=0.25;decimate_type=COLLAPSE;face_count=220.0"))[0]
    check("kind", m.kind == .decimate)
    check("ratio", close(m.ratio, 0.25), "\(m.ratio)")
    // Blender computes this one; the panel only ever displays it. Without it
    // the row looks dead on a cube, where ratio 0.5 leaves all six faces.
    check("face_count comes back", m.faceCount == 220, "\(m.faceCount)")
    check("a new Decimate keeps every face", Modifier(kind: .decimate).ratio == 1)

    // `ratio` is inert in UNSUBDIV and DISSOLVE, so the type is pinned rather
    // than left wherever a script put it.
    check("the type is pinned to COLLAPSE",
          Bpy.modifierSettings(Modifier(kind: .decimate))
              .contains { $0.contains("decimate_type = \"COLLAPSE\"") })
}

print("\n== Remesh ==")
do {
    let m = Modifier.stack(from: record(
        "kind=REMESH;name=Remesh;mode=BLOCKS;voxel_size=0.05;octree_depth=6.0"))[0]
    check("kind", m.kind == .remesh)
    check("mode", m.remeshMode == .blocks, "\(m.remeshMode)")
    check("voxel_size", close(m.voxelSize, 0.05), "\(m.voxelSize)")
    check("octree_depth", m.octreeDepth == 6, "\(m.octreeDepth)")

    let fresh = Modifier(kind: .remesh)
    check("a new Remesh is VOXEL at 0.1", fresh.remeshMode == .voxel && fresh.voxelSize == 0.1)
    // Both resolutions every time: each is inert in the modes that do not use
    // it, and sending only the live one loses the other on a mode change.
    check("both resolutions are sent", Bpy.modifierSettings(fresh).count == 3)
}

print("\n== every kind the panel offers can be added and mirrored ==")
do {
    for kind in ModifierKind.allCases where kind != .other {
        let entry = "kind=\(kind.bpyType);name=\(kind.displayName)"
        let back = Modifier.stack(from: entry)
        check("\(kind.displayName) round-trips its type",
              back.count == 1 && back[0].kind == kind, entry)
    }
}

print("\n== saved scenes: every field round-trips, and old files still open ==")
do {
    // Every field off its default, so a field the decoder forgets comes back
    // as the default and the re-encoded JSON differs.
    var m = Modifier(kind: .screw, name: "Thread")
    m.levels = 3; m.count = 40; m.relativeOffset = SIMD3(0.5, 1.5, -2)
    m.mirrorX = false; m.mirrorY = true; m.mirrorZ = true
    m.thickness = 0.37; m.factor = 0.2; m.iterations = 7; m.angle = 1.25; m.axis = 1
    m.waveX = false; m.waveY = false
    m.deformMode = .taper; m.segments = 5; m.booleanOperation = .intersect
    m.targetName = "Bolt"; m.ratio = 0.3; m.decimateType = "DISSOLVE"; m.faceCount = 99
    m.voxelSize = 0.07; m.octreeDepth = 6; m.wrapMethod = .targetProject
    m.remeshMode = .sharp
    m.bisectX = true; m.bisectY = false; m.bisectZ = true
    m.bisectFlipX = false; m.bisectFlipY = true; m.bisectFlipZ = true
    m.mirrorClip = true; m.mirrorMerge = false; m.mergeThreshold = 0.0025
    m.showInViewport = false
    m.nodeGroup = "Twist"; m.smoothByAngle = true; m.ignoreSharpness = true
    m.blenderType = "SURFACE_DEFORM"; m.typeLabel = "Surface Deform"; m.showInRender = false
    m.weightMode = .cornerAngle; m.weight = 70; m.threshold = 0.5; m.keepSharp = true
    m.faceInfluence = true; m.sculptLevels = 2; m.renderLevels = 3; m.totalLevels = 4
    m.edgeSplitAngle = false; m.edgeSplitSharp = false; m.lambdaFactor = 0.3; m.lambdaBorder = 0.2
    m.smoothX = false; m.smoothY = false; m.smoothZ = false; m.preserveVolume = false
    m.normalized = false; m.smoothScale = 2; m.smoothType = .lengthWeighted; m.onlySmooth = true
    m.pinBoundary = true; m.restSource = "BIND"; m.isBound = true

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(m)
    let back = try? JSONDecoder().decode(Modifier.self, from: data)
    check("a modifier decodes", back != nil)
    if let back {
        check("every field survives the round trip",
              (try? encoder.encode(back)) == data,
              String(decoding: (try? encoder.encode(back)) ?? Data(), as: UTF8.self))
    }

    // A modifier as the build before this one wrote it: the same JSON without
    // the seven keys added for Shrinkwrap, Screw, Decimate and Remesh. The
    // synthesized decoder threw keyNotFound on this, which would have stopped
    // any saved file or autosave with a modifier in it from opening.
    var old = try! JSONSerialization.jsonObject(with: encoder.encode(Modifier(kind: .subdivision)))
        as! [String: Any]
    for key in ["ratio", "decimateType", "faceCount", "voxelSize", "octreeDepth",
                "wrapMethod", "remeshMode", "waveX", "waveY",
                "nodeGroup", "smoothByAngle", "ignoreSharpness",
                // and the fields added with every-modifier rows
                "blenderType", "typeLabel", "showInRender", "weightMode", "weight", "threshold",
                "keepSharp", "faceInfluence", "sculptLevels", "renderLevels", "totalLevels",
                "edgeSplitAngle", "edgeSplitSharp", "lambdaFactor", "lambdaBorder", "smoothX",
                "smoothY", "smoothZ", "preserveVolume", "normalized", "smoothScale", "smoothType",
                "onlySmooth", "pinBoundary", "restSource", "isBound"] {
        old.removeValue(forKey: key)
    }
    old["levels"] = 2
    let oldData = try! JSONSerialization.data(withJSONObject: old)
    let decoded = try? JSONDecoder().decode(Modifier.self, from: oldData)
    check("a modifier saved before these fields existed still opens", decoded != nil)
    check("and keeps what it did save", decoded?.levels == 2, "\(String(describing: decoded?.levels))")
    check("and takes the kind's defaults for the rest",
          decoded?.ratio == 1 && decoded?.voxelSize == 0.1 && decoded?.remeshMode == .voxel
              && decoded?.waveX == true && decoded?.waveY == true)
    check("including its type and the render switch, which a file from before them never turned off",
          decoded?.blenderType == "SUBSURF" && decoded?.typeLabel == "Subdivision Surface"
              && decoded?.showInRender == true && decoded?.weight == 50)
    // A Mirror saved before Bisect, Flip, Clipping and Merge were rows.
    var oldMirror = try! JSONSerialization.jsonObject(with: encoder.encode(Modifier(kind: .mirror)))
        as! [String: Any]
    for key in ["bisectX", "bisectY", "bisectZ", "bisectFlipX", "bisectFlipY", "bisectFlipZ",
                "mirrorClip", "mirrorMerge", "mergeThreshold", "showInViewport"] {
        oldMirror.removeValue(forKey: key)
    }
    oldMirror["mirrorY"] = true
    let mirrorBack = try? JSONDecoder().decode(
        Modifier.self, from: JSONSerialization.data(withJSONObject: oldMirror))
    check("a Mirror saved before its new rows opens with Blender's defaults for them",
          mirrorBack?.mirrorY == true && mirrorBack?.bisectX == false && mirrorBack?.mirrorClip == false
              && mirrorBack?.mirrorMerge == true && mirrorBack?.mergeThreshold == 0.001
              && mirrorBack?.showInViewport == true)

    let scene = """
    {"version": 1, "selection": [], "objects": [{"name": "Cube", "kind": "cube",
     "location": [0,0,0], "rotation": [0,0,0], "scale": [1,1,1], "color": [1,1,1,1],
     "visible": true, "modifiers": [\(String(decoding: oldData, as: UTF8.self))]}]}
    """
    check("a whole saved scene with an old modifier opens",
          (try? JSONDecoder().decode(SceneSnapshot.self, from: Data(scene.utf8)))?
              .objects.first?.modifiers.first?.levels == 2)
}

print("\n== the simulator's mesh operations ==")
do {
    let sphere = MeshBuilder.uvSphere(radius: 1, segments: 32, rings: 16)
    let distinct = (ModifierStack.weldMap(sphere.vertices).max() ?? 0) + 1

    var decimate = Modifier(kind: .decimate)
    decimate.ratio = 0.25
    let reduced = ModifierStack.apply([decimate], to: sphere)
    // Clustering lands near the ratio, not on it — it is not Blender's quadric
    // collapse, and the comment on `decimate` says so.
    check("decimate reduces toward the ratio",
          reduced.vertices.count < distinct / 2 && reduced.vertices.count > 8,
          "\(reduced.vertices.count) of \(distinct)")
    decimate.ratio = 1
    check("ratio 1 keeps every triangle",
          ModifierStack.apply([decimate], to: sphere).indices.count == sphere.indices.count)

    var voxel = Modifier(kind: .remesh)
    voxel.voxelSize = 0.5
    let coarse = ModifierStack.apply([voxel], to: sphere).vertices.count
    voxel.voxelSize = 0.05
    let fine = ModifierStack.apply([voxel], to: sphere).vertices.count
    check("a coarser voxel gives fewer vertices", coarse < fine, "\(coarse) vs \(fine)")

    var octree = Modifier(kind: .remesh)
    octree.remeshMode = .blocks
    octree.octreeDepth = 3
    let shallow = ModifierStack.apply([octree], to: sphere).vertices.count
    octree.octreeDepth = 6
    let deep = ModifierStack.apply([octree], to: sphere).vertices.count
    check("a deeper octree gives more vertices", shallow < deep, "\(shallow) vs \(deep)")

    let plane = MeshBuilder.plane(size: 0.4)
    var screw = Modifier(kind: .screw)
    screw.count = 8
    screw.thickness = 1
    let screwed = ModifierStack.apply([screw], to: plane)
    // Eight separate copies, not a bridged sweep: Blender's Screw on a closed
    // cube at steps 8 gives 96 faces from 6, which needs boundary-edge walking
    // that MeshData has no structure for.
    check("screw makes one copy per step",
          screwed.vertices.count == plane.vertices.count * 8, "\(screwed.vertices.count)")
    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
    for v in screwed.vertices { lo = min(lo, v.position.z); hi = max(hi, v.position.z) }
    check("screw_offset raises the copies along the axis", hi - lo > 0.5, "\(hi - lo)")
    check("the rotation produces no NaN",
          screwed.vertices.allSatisfy {
              $0.position.x.isFinite && $0.position.y.isFinite && $0.normal.x.isFinite
          })

    var shrinkwrap = Modifier(kind: .shrinkwrap)
    shrinkwrap.targetName = "Cube"
    // The target's evaluated surface is what every wrap method searches, and a
    // per-mesh stack does not have it. Unchanged beats quietly wrong.
    check("shrinkwrap leaves the mesh alone here",
          ModifierStack.apply([shrinkwrap], to: sphere).vertices.count == sphere.vertices.count)
}

print("\n== the simulator's Apply and Origin to Geometry evaluate the stack once ==")
do {
    // Blender bakes `object.data` and evaluates the stack on top. The shim
    // used to bake `mesh` — already the stack's output — and hand it to
    // `setMirroredMesh`, which ran the stack over it again.
    func subdivided(scale: SIMD3<Float>) -> (BKScene, BKObject) {
        let scene = BKScene(startupFile: false)
        scene.objects = []
        let cube = scene.add(.cube)
        cube.scale = scale
        cube.addModifier(.subdivision)
        scene.selection = [cube.id]
        scene.activeID = cube.id
        return (scene, cube)
    }
    let (scene, cube) = subdivided(scale: SIMD3(1, 1, 2))
    let once = cube.mesh.vertices.count
    let twice = ModifierStack.apply(cube.modifiers, to: cube.mesh).vertices.count
    check("baking the evaluated mesh would have subdivided it again", twice > once, "\(once) vs \(twice)")
    check("Apply Scale bakes one object", scene.bakeSelectedTransforms(location: false, rotation: false,
                                                                     scale: true) == 1)
    check("and the stack is still applied once", cube.mesh.vertices.count == once,
          "\(cube.mesh.vertices.count), was \(once)")
    check("to a base that holds the scale",
          abs(cube.evaluatedBase.vertices.map(\.position.z).max()! - 2) < 1e-5
              && cube.scale == SIMD3(repeating: 1), "\(cube.scale)")

    // The median Blender moves the origin to is the base's. An Array pushes
    // the evaluated mesh off to one side; the base cube's median stays at 0.
    let arrayScene = BKScene(startupFile: false)
    arrayScene.objects = []
    let arrayed = arrayScene.add(.cube)
    arrayed.addModifier(.array)
    arrayScene.selection = [arrayed.id]
    let evaluatedMedian = arrayed.mesh.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position }
        / Float(arrayed.mesh.vertices.count)
    let arrayOnce = arrayed.mesh.vertices.count
    check("an Array moves the evaluated median off the origin", abs(evaluatedMedian.x) > 0.5,
          "\(evaluatedMedian)")
    arrayScene.moveSelectedOriginsToMedian()
    check("Origin to Geometry takes the base's median, which is where the origin already was",
          length(arrayed.location) < 1e-5, "\(arrayed.location)")
    check("and the Array is still applied once", arrayed.mesh.vertices.count == arrayOnce,
          "\(arrayed.mesh.vertices.count), was \(arrayOnce)")

    // A camera beside a mesh is left where it is, as Blender leaves it.
    let mixed = BKScene(startupFile: false)
    mixed.objects = []
    let mesh = mixed.add(.cube)
    mesh.scale = SIMD3(repeating: 2)
    let camera = mixed.add(.cube)
    camera.blenderType = "CAMERA"
    camera.location = SIMD3(1, 2, 3)
    camera.scale = SIMD3(repeating: 2)
    mixed.selection = [mesh.id, camera.id]
    check("Apply bakes the mesh and not the camera",
          mixed.bakeSelectedTransforms(location: true, rotation: true, scale: true) == 1
              && camera.location == SIMD3(1, 2, 3) && camera.scale == SIMD3(repeating: 2)
              && mesh.scale == SIMD3(repeating: 1))

    // Every row leaves the object where it is, and bakes what Blender bakes.
    // The corner that starts at (-1,-1,-1), and where desktop Blender 5.2.1
    // put it in `object.data` for a cube at (1,2,3) turned (0.3, 0, 0.5):
    // scale (1,2,3), then a zero X scale, which Blender cannot invert.
    let rows: [(l: Bool, r: Bool, s: Bool, scale: SIMD3<Float>, corner: SIMD3<Float>?)] = [
        (true, false, false, SIMD3(1, 2, 3), SIMD3(0.83643, 0.05266, -0.17033)),
        (false, true, false, SIMD3(1, 2, 3), SIMD3(-0.3866, -0.68908, -1.15235)),
        (false, false, true, SIMD3(1, 2, 3), SIMD3(-1, -2, -3)),
        (true, true, true, SIMD3(1, 2, 3), SIMD3(0.6134, 0.62183, -0.45705)),
        (true, true, false, SIMD3(1, 2, 3), SIMD3(0.6134, 0.31092, -0.15235)),
        (true, false, true, SIMD3(1, 2, 3), SIMD3(0.83643, 0.10532, -0.511)),
        (false, true, true, SIMD3(1, 2, 3), SIMD3(-0.3866, -1.37817, -3.45705)),
        // Blender's adjugate moves this one; Blender's world vertices moved 3.74.
        (true, false, false, SIMD3(0, 2, 3), SIMD3(10.0186, -1, -1)),
        // CANCELLED in Blender: "non-invertible transformation matrix".
        (false, true, false, SIMD3(0, 2, 3), nil),
    ]
    for row in rows {
        let scene = BKScene(startupFile: false)
        scene.objects = []
        let cube = scene.add(.cube, at: SIMD3(1, 2, 3))
        cube.rotation = SIMD3(0.3, 0, 0.5)
        cube.scale = row.scale
        let corner = cube.evaluatedBase.vertices.firstIndex {
            length($0.position - SIMD3(-1, -1, -1)) < 1e-6
        }!
        let world = { cube.evaluatedBase.vertices.map { (cube.modelMatrix * SIMD4($0.position, 1)).xyz } }
        let before = world()
        let baked = scene.bakeSelectedTransforms(location: row.l, rotation: row.r, scale: row.s)
        let label = "Apply" + (row.l ? " Location" : "") + (row.r ? " Rotation" : "")
            + (row.s ? " Scale" : "") + (row.scale.x == 0 ? ", zero X scale" : "")
        guard let want = row.corner else {
            check("\(label) is skipped, as Blender skips it", baked == 0
                      && cube.rotation == SIMD3(0.3, 0, 0.5) && before == world())
            continue
        }
        let got = cube.evaluatedBase.vertices[corner].position
        check("\(label) bakes the corner where Blender does", baked == 1 && length(got - want) < 1e-4,
              "\(got), Blender \(want)")
        let moved = zip(before, world()).map { length($0 - $1) }.max()!
        check("\(label) " + (row.scale.x == 0 ? "moves the object as Blender does"
                                                 : "leaves the object where it is"),
              row.scale.x == 0 ? abs(moved - 3.741657) < 1e-3 : moved < 1e-4, "moved \(moved)")
        check("\(label) resets only its own channels",
              cube.location == (row.l ? .zero : SIMD3(1, 2, 3))
                  && cube.rotation == (row.r ? .zero : SIMD3(0.3, 0, 0.5))
                  && cube.scale == (row.s ? SIMD3(repeating: 1) : row.scale))
    }
}

print("\n== an edit sends its own change, and the row writes nothing itself ==")
do {
    // The record says the target is gone — Blender clears the pointer when
    // the object is deleted — so the row's current value is none, and an
    // Offset edit cannot drag a stale `target =` line along with it.
    let gone = Modifier.stack(from: "kind=SHRINKWRAP;name=Shrinkwrap;wrap_method=NEAREST_SURFACEPOINT;"
                                  + "offset=0.02;target=")[0]
    var offset = gone
    offset.thickness = 0.07
    let lines = Bpy.modifierEdit(from: gone, to: offset)
    check("an Offset edit is one line", lines.count == 1 && lines[0].contains(".offset = 0.0700"),
          lines.joined(separator: " / "))
    var picked = gone
    picked.targetName = "Cube"
    check("picking a target sends the target alone",
          Bpy.modifierEdit(from: gone, to: picked) == [Bpy.setModifierProperty(
              "Shrinkwrap", "target", "bpy.data.objects[\"Cube\"]")],
          Bpy.modifierEdit(from: gone, to: picked).joined(separator: " / "))
    check("nothing changed, nothing sent", Bpy.modifierEdit(from: gone, to: gone).isEmpty)

    var mirror = Modifier(kind: .mirror)
    var y = mirror
    y.mirrorY = true
    check("a Mirror axis toggle is one assignment of the three Blender holds",
          Bpy.modifierEdit(from: mirror, to: y)
              == [Bpy.setModifierProperty("Mirror", "use_axis", "(True, True, False)")],
          Bpy.modifierEdit(from: mirror, to: y).joined(separator: " / "))
    mirror.mirrorZ = true
    check("with the axes Blender has, not the ones the row started with",
          Bpy.modifierEdit(from: mirror, to: { var m = mirror; m.mirrorY = true; return m }())
              == [Bpy.setModifierProperty("Mirror", "use_axis", "(True, True, True)")])

    let unsubdiv = Modifier.stack(from: "kind=DECIMATE;name=Decimate;ratio=1.0;decimate_type=UNSUBDIV")[0]
    var ratio = unsubdiv
    ratio.ratio = 0.5; ratio.decimateType = "COLLAPSE"
    let decimate = Bpy.modifierEdit(from: unsubdiv, to: ratio)
    check("a Ratio edit on a scripted Un-Subdivide sends the type it switches to",
          decimate.count == 2 && decimate.contains { $0.contains("decimate_type = \"COLLAPSE\"") },
          decimate.joined(separator: " / "))
    var collapse = ratio
    collapse.ratio = 0.25
    check("and on Collapse the ratio alone", Bpy.modifierEdit(from: ratio, to: collapse).count == 1)

    let remesh = Modifier.stack(from: "kind=REMESH;name=Remesh;mode=VOXEL;voxel_size=0.3;octree_depth=4.0")[0]
    var blocks = remesh
    blocks.remeshMode = .blocks
    check("a Remesh mode change leaves the voxel size Blender holds alone",
          Bpy.modifierEdit(from: remesh, to: blocks) == [Bpy.setModifierProperty("Remesh", "mode", "\"BLOCKS\"")],
          Bpy.modifierEdit(from: remesh, to: blocks).joined(separator: " / "))
}

print("\n== Wave: Motion X and Y, mirrored ==")
do {
    let fresh = Modifier(kind: .wave)
    check("a new Wave has both, Blender's ring", fresh.waveX && fresh.waveY)
    let lines = Bpy.modifierSettings(fresh)
    check("the row sends use_x and use_y, never an axis",
          lines.contains { $0.hasSuffix(".use_x = True") } && lines.contains { $0.hasSuffix(".use_y = True") }
          && !lines.contains { $0.contains("axis") }, lines.joined(separator: " / "))
    let back = Modifier.stack(from: "kind=WAVE;name=Wave;height=0.3;use_x=False;use_y=True")[0]
    check("the record's Motion comes back", !back.waveX && back.waveY && close(back.thickness, 0.3))

    // Blender 5.2.1, a grid 8 m across with 41 subdivisions, height 0.5,
    // Motion X alone, frame 1: z at three columns, and none from x = 1.854.
    let grid = MeshBuilder.grid(size: 8, divisions: 41)
    func z(at x: Float, motionX: Bool = true, motionY: Bool = false) -> Float? {
        let out = ModifierStack.wave(grid, height: 0.5, motionX: motionX, motionY: motionY)
        guard let i = grid.vertices.firstIndex(where: { abs($0.position.x - x) < 1e-4 }) else { return nil }
        return out.vertices[i].position.z
    }
    let step: Float = 8 / 41
    for (column, blender) in [(21, Float(0.47136)), (22, 0.49479), (13, 0.0089), (30, 0)] {
        let x = -4 + Float(column) * step
        let mine = z(at: x) ?? .nan
        check(String(format: "Motion X: z at x = %.3f is Blender's %.5f", x, blender),
              abs(mine - blender) < 2e-4, "\(mine)")
    }
    let ring = ModifierStack.wave(grid, height: 0.5, motionX: true, motionY: true)
    let line = ModifierStack.wave(grid, height: 0.5, motionX: true, motionY: false)
    let flat = ModifierStack.wave(grid, height: 0.5, motionX: false, motionY: false)
    // The column through x = 0.098, where the first crest is passing.
    func heightsAlongY(_ m: MeshData) -> Int {
        let x = -4 + 21 * step
        let column = m.vertices.filter { abs($0.position.x - x) < 1e-4 }
        return Set(column.map { ($0.position.z * 1e5).rounded() }).count
    }
    check("Motion X alone: one height all along Y", heightsAlongY(line) == 1, "\(heightsAlongY(line))")
    check("both: a ring, so the height changes along Y too", heightsAlongY(ring) > 1,
          "\(heightsAlongY(ring))")
    check("neither: every vertex lifted by the same amount",
          Set(flat.vertices.map { ($0.position.z * 1e5).rounded() }).count == 1
              && flat.vertices[0].position.z > 0)
}

print("\n== Mirror: Bisect, Flip, Clipping and Merge ==")
do {
    let fresh = Modifier(kind: .mirror)
    // What `modifiers.new(type='MIRROR')` holds in 5.2.1.
    check("a new Mirror is Blender's: no bisect, no flip, no clipping, Merge on at 0.001",
          !fresh.bisectX && !fresh.bisectY && !fresh.bisectZ
              && !fresh.bisectFlipX && !fresh.bisectFlipY && !fresh.bisectFlipZ
              && !fresh.mirrorClip && fresh.mirrorMerge && fresh.mergeThreshold == 0.001)
    let lines = Bpy.modifierSettings(fresh)
    check("the row's whole list, in Blender's names", lines == [
        Bpy.setModifierProperty("Mirror", "use_axis", "(True, False, False)"),
        Bpy.setModifierProperty("Mirror", "use_bisect_axis", "(False, False, False)"),
        Bpy.setModifierProperty("Mirror", "use_bisect_flip_axis", "(False, False, False)"),
        Bpy.setModifierProperty("Mirror", "use_clip", "False"),
        Bpy.setModifierProperty("Mirror", "use_mirror_merge", "True"),
        Bpy.setModifierProperty("Mirror", "merge_threshold", "0.001000")],
          lines.joined(separator: " / "))

    // As `_modifier_record` writes it: every flag 1 or 0, every number a float.
    let back = Modifier.stack(from: "kind=MIRROR;name=Mirror;use_clip=1;use_mirror_merge=0;"
        + "merge_threshold=0.0024999999441206455;show_viewport=0;"
        + "use_axis_x=1;use_axis_y=0;use_axis_z=1;"
        + "use_bisect_axis_x=1;use_bisect_axis_y=0;use_bisect_axis_z=0;"
        + "use_bisect_flip_axis_x=0;use_bisect_flip_axis_y=0;use_bisect_flip_axis_z=1")[0]
    check("the record's Bisect comes back per axis", back.bisectX && !back.bisectY && !back.bisectZ)
    check("and Flip", !back.bisectFlipX && !back.bisectFlipY && back.bisectFlipZ)
    check("Clipping and Merge", back.mirrorClip && !back.mirrorMerge)
    check("the merge distance", close(back.mergeThreshold, 0.0025, 1e-7), "\(back.mergeThreshold)")
    check("and whether it is on in the viewport", !back.showInViewport)
    check("the axes still come back", back.mirrorX && !back.mirrorY && back.mirrorZ)

    // One change, one line: each is its own assignment.
    func edit(_ change: (inout Modifier) -> Void) -> [String] {
        var changed = fresh
        change(&changed)
        return Bpy.modifierEdit(from: fresh, to: changed)
    }
    check("Clipping on sends use_clip alone",
          edit { $0.mirrorClip = true } == [Bpy.setModifierProperty("Mirror", "use_clip", "True")])
    check("Merge off sends use_mirror_merge alone",
          edit { $0.mirrorMerge = false } == [Bpy.setModifierProperty("Mirror", "use_mirror_merge", "False")])
    check("Bisect Y sends the three Blender holds, Y changed",
          edit { $0.bisectY = true }
              == [Bpy.setModifierProperty("Mirror", "use_bisect_axis", "(False, True, False)")])
    check("Flip Z likewise",
          edit { $0.bisectFlipZ = true }
              == [Bpy.setModifierProperty("Mirror", "use_bisect_flip_axis", "(False, False, True)")])
    check("a merge distance goes at Blender's six places, so 0.00005 is not sent as 0.0001",
          edit { $0.mergeThreshold = 0.00005 }
              == [Bpy.setModifierProperty("Mirror", "merge_threshold", "0.000050")],
          edit { $0.mergeThreshold = 0.00005 }.joined(separator: " / "))
    check("and the field shows it at six, not rounded to three",
          NumberFieldUnit.fineMeters.format(0.00005) == "0.00005 m"
              && NumberFieldUnit.fineMeters.format(0.001) == "0.001 m"
              && NumberFieldUnit.fineMeters.format(0.1) == "0.100 m"
              && NumberFieldUnit.fineMeters.typed("0.0005 m") == 0.0005
              && NumberFieldUnit.fineMeters.editable(0.00005) == "5e-05",
          NumberFieldUnit.fineMeters.format(0.00005) + " " + NumberFieldUnit.fineMeters.editable(0.00005))

    // The simulator's own Mirror, against what Blender 5.2.1 made of the same
    // shapes. An eight-corner cube with shared corners, as Blender's is, so
    // the counts compare.
    func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> MeshData {
        let corners = (0..<8).map { i -> MeshVertex in
            MeshVertex(SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y,
                             i & 4 == 0 ? lo.z : hi.z), .zero)
        }
        let quads: [[UInt32]] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4],
                                 [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        return MeshData(vertices: corners,
                        indices: quads.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] })
    }
    func xs(_ m: MeshData) -> [Float] {
        Array(Set(m.vertices.map { ($0.position.x * 1e4).rounded() / 1e4 })).sorted()
    }
    var mirror = Modifier(kind: .mirror)
    let touching = box(SIMD3(0, -1, -1), SIMD3(2, 1, 1))
    let merged = ModifierStack.apply([mirror], to: touching)
    check("a cube touching the plane merges its four corners there: 12 vertices, as Blender's",
          merged.vertices.count == 12 && xs(merged) == [-2, 0, 2], "\(merged.vertices.count) \(xs(merged))")
    check("and its face on the plane is not doubled: 11 of Blender's quads, 22 triangles",
          merged.indices.count / 3 == 22, "\(merged.indices.count / 3)")
    mirror.mirrorMerge = false
    let apart = ModifierStack.apply([mirror], to: touching)
    check("Merge off: 16 vertices, 12 quads, as Blender's",
          apart.vertices.count == 16 && apart.indices.count / 3 == 24,
          "\(apart.vertices.count) \(apart.indices.count / 3)")

    mirror.mirrorMerge = true
    let near = box(SIMD3(0.01, -1, -1), SIMD3(2.01, 1, 1))
    mirror.mergeThreshold = 0.019
    check("0.01 from the plane, the gap to its image is 0.02: not merged at 0.019",
          ModifierStack.apply([mirror], to: near).vertices.count == 16)
    mirror.mergeThreshold = 0.021
    let welded = ModifierStack.apply([mirror], to: near)
    check("merged at 0.021, onto the plane, as Blender's",
          welded.vertices.count == 12 && xs(welded) == [-2.01, 0, 2.01], "\(xs(welded))")

    mirror.mergeThreshold = 0.001
    let across = box(SIMD3(-0.5, -1, -1), SIMD3(1.5, 1, 1))
    check("without Bisect a cube across the plane is mirrored whole, as Blender's",
          xs(ModifierStack.apply([mirror], to: across)) == [-1.5, -0.5, 0.5, 1.5],
          "\(xs(ModifierStack.apply([mirror], to: across)))")
    mirror.bisectX = true
    let cut = ModifierStack.apply([mirror], to: across)
    check("Bisect X cuts it at the plane first: it spans ±1.5 with nothing left at ±0.5, as Blender's",
          xs(cut) == [-1.5, 0, 1.5], "\(xs(cut))")
    mirror.bisectFlipX = true
    let flipped = ModifierStack.apply([mirror], to: across)
    check("Flip keeps the other side: ±0.5, as Blender's", xs(flipped) == [-0.5, 0, 0.5], "\(xs(flipped))")
    mirror.bisectFlipX = false
    mirror.mirrorX = false
    mirror.mirrorY = true
    check("an axis that is not mirrored cuts nothing, as Blender's bisect Y with only X on",
          xs(ModifierStack.apply([mirror], to: across)) == [-0.5, 1.5])

    // Clipping: what an edit-mode drag commits, and so what it previews.
    var clip = Modifier(kind: .mirror)
    check("no clipping without Clipping on", MirrorClip.clipping([clip]).isEmpty)
    clip.mirrorClip = true
    let clips = MirrorClip.clipping([clip])
    check("with it, one clip on X at the merge distance",
          clips == [MirrorClip(axes: [true, false, false], tolerance: 0.001)], "\(clips)")
    var off = clip
    off.showInViewport = false
    check("none for a Mirror off in the viewport, which Blender does not clip for",
          MirrorClip.clipping([off]).isEmpty)
    let c = clips[0]
    check("a vertex on the plane stays on it, and moves along it",
          c.apply(start: SIMD3(0, 0, 0), moved: SIMD3(0.5, 0, 0.25)) == SIMD3(0, 0, 0.25))
    check("one crossing it stops at it: 0.2 moved -0.5 is 0, not -0.3",
          c.apply(start: SIMD3(0.2, 0, 0), moved: SIMD3(-0.3, 0, 0)) == SIMD3(0, 0, 0))
    check("within the merge distance it is pinned: 0.0008 at 0.001",
          c.apply(start: SIMD3(0.0008, 0, 0), moved: SIMD3(0.0008, 0.1, 0)) == SIMD3(0, 0.1, 0))
    check("and outside it not: 0.0015",
          c.apply(start: SIMD3(0.0015, 0, 0), moved: SIMD3(0.0015, 0.1, 0)) == SIMD3(0.0015, 0.1, 0))
    check("landing exactly on the plane is not across it",
          c.apply(start: SIMD3(0.2, 0, 0), moved: SIMD3(0, 1, 0)) == SIMD3(0, 1, 0))
    let op = TransformOperation(kind: .translate(SIMD3(0.1, 0, 0)), pivot: .point(.zero),
                                proportional: ProportionalEdit(falloff: .smooth, size: 0.5))
    let points: [SIMD3<Float>] = [SIMD3(3, 0, 0), SIMD3(0.0005, 1, 0)]
    let pulled = op.apply(toVertices: points, factors: [1, 0], selected: [0],
                          model: matrix_identity_float4x4, clipping: clips)
    check("with proportional editing every vertex is Blender's to clip, even one it does not move",
          pulled[1] == SIMD3(0, 1, 0) && pulled[0] == SIMD3(3.1, 0, 0), "\(pulled)")
    let plain = TransformOperation(kind: .translate(SIMD3(0.1, 0, 0)), pivot: .point(.zero))
    check("and without it only the selection",
          plain.apply(toVertices: points, factors: [1, 0], selected: [0],
                      model: matrix_identity_float4x4, clipping: clips)[1] == SIMD3(0.0005, 1, 0))
}

print("\n== Remesh's finest voxel scales with the object ==")
do {
    let two = ModifierStack.remeshVoxelFloor(for: MeshBuilder.cube(size: 2))
    let six = ModifierStack.remeshVoxelFloor(for: MeshBuilder.cube(size: 6))
    let hundred = ModifierStack.remeshVoxelFloor(for: MeshBuilder.cube(size: 100))
    check("2 m across: 2/256", close(two, 2 / 256, 1e-7), "\(two)")
    check("6 m across: 6/256, where 0.01 gave 2.17 million vertices", close(six, 6 / 256, 1e-7), "\(six)")
    check("100 m across: 100/256", close(hundred, 100 / 256, 1e-5), "\(hundred)")
    check("a small object may go finer than the old fixed 0.01",
          ModifierStack.remeshVoxelFloor(for: MeshBuilder.cube(size: 0.5)) < 0.01)
    check("no geometry to measure: the old fixed floor",
          ModifierStack.remeshVoxelFloor(for: MeshData(vertices: [], indices: [])) == 0.01)
    let large = Bpy.addModifier(.remesh, on: MeshBuilder.cube(size: 100))
    check("Add Modifier on a 100 m cube raises Blender's 0.1 to the floor, on the one it added",
          large.count == 2 && large[1] == "bpy.context.object.modifiers.active.voxel_size = 0.390625",
          large.joined(separator: " / "))
    check("and on a 2 m cube adds it as Blender would",
          Bpy.addModifier(.remesh, on: MeshBuilder.cube(size: 2)) == [Bpy.addModifier("REMESH")])
    check("other kinds are added as they always were",
          Bpy.addModifier(.subdivision, on: MeshBuilder.cube(size: 100)) == [Bpy.addModifier("SUBSURF")])
    var remesh = Modifier(kind: .remesh)
    remesh.voxelSize = two
    check("the floor goes to Blender with six places: 0.007812, where four sent 0.0078",
          Bpy.modifierSettings(remesh).contains { $0.hasSuffix("voxel_size = 0.007812") },
          Bpy.modifierSettings(remesh).joined(separator: " / "))

    // The row's floor comes from the Remesh's input. On device the mesh on
    // screen is what the Remesh made: a 2 m cube at 2.0 is a 0.667 m cube
    // there (measured in 5.2.1), which put the floor at 0.0026.
    let shrunk = MeshBuilder.cube(size: 2 / 3)
    let record = Modifier.stack(from: "kind=REMESH;name=Remesh;mode=VOXEL;voxel_size=2.0;octree_depth=4.0;input_size=2.0")
    check("the mirror's record carries the Remesh's input size", record.first?.inputSize == 2)
    let row = ModifierStack.remeshVoxelFloor(for: record[0], on: shrunk)
    check("and the row's floor is 2/256 from it, not 0.0026 from the Remesh's own output",
          close(row, 2 / 256, 1e-7), "\(row)")
    let unknown = Modifier.stack(from: "kind=REMESH;name=Remesh;mode=VOXEL;voxel_size=2.0")[0]
    check("with no input size, the mesh on screen is all there is",
          close(ModifierStack.remeshVoxelFloor(for: unknown, on: shrunk), (2 / 3) / 256, 1e-7))
    check("a nonsense input size is not taken",
          Modifier.stack(from: "kind=REMESH;name=R;input_size=nan|kind=REMESH;name=S;input_size=-1")
            .allSatisfy { $0.inputSize == 0 })

    // The simulator is its own evaluator, so it knows the input exactly.
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let cube = scene.add(.cube)
    cube.addModifier(.remesh)
    var stack = cube.modifiers
    stack[0].voxelSize = 2
    cube.modifiers = stack
    check("the simulator's Remesh records its input: the 2 m cube",
          close(cube.modifiers[0].inputSize, 2, 1e-5), "\(cube.modifiers[0].inputSize)")
    check("and the row's floor is the cube's, whatever the Remesh made of it",
          close(ModifierStack.remeshVoxelFloor(for: cube.modifiers[0], on: cube.mesh), 2 / 256, 1e-7),
          "\(ModifierStack.remeshVoxelFloor(for: cube.modifiers[0], on: cube.mesh))")
    let arrayed = scene.add(.cube)
    arrayed.addModifier(.array)
    arrayed.addModifier(.remesh)
    check("under an Array of two, its input is the 4 m row the Array made",
          close(arrayed.modifiers[1].inputSize, 4, 1e-4), "\(arrayed.modifiers[1].inputSize)")
}

print("\n== the simulator's Decimate reports its face count ==")
do {
    // Blender's `face_count` is the collapse's own output; nothing wrote the
    // simulator's, and its Faces row read 0 for ever.
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let sphere = scene.add(.uvSphere)
    sphere.addModifier(.decimate)
    check("ratio 1: every face", sphere.modifiers[0].faceCount == sphere.mesh.indices.count / 3
          && sphere.modifiers[0].faceCount > 0, "\(sphere.modifiers[0].faceCount)")
    var stack = sphere.modifiers
    stack[0].ratio = 0.25
    sphere.modifiers = stack
    let faces = sphere.modifiers[0].faceCount
    check("ratio 0.25: the count the collapse produced", faces == sphere.mesh.indices.count / 3
          && faces < MeshBuilder.make(.uvSphere).indices.count / 3, "\(faces)")
    // A Subdivision after it: the Decimate's own output is what it reports.
    sphere.addModifier(.subdivision)
    check("measured at the Decimate, not at the end of the stack",
          sphere.modifiers[0].faceCount == faces && sphere.mesh.indices.count / 3 > faces,
          "\(sphere.modifiers[0].faceCount) vs \(faces)")
}

print("\n== on device the stack describes Blender's mesh, and is never run over it ==")
do {
    // The critical pair of round 1: Screw at 16 steps turned Blender's 384
    // evaluated vertices into 6144 on screen. `setEvaluatedMesh` is what the
    // mirror installs; `setMirroredMesh` (the simulator's own edits) is the
    // path that does run the stack.
    let base = MeshBuilder.cube(size: 2)
    let screw = Modifier.stack(from: "kind=SCREW;name=Screw;angle=6.283185;steps=16.0;axis=Z;screw_offset=0.0")
    let evaluated = ModifierStack.apply(screw, to: base)
    let obj = BKObject(name: "Cube", kind: .cube)
    obj.setEvaluatedMesh(evaluated)
    obj.modifiers = screw
    check("a mirrored mesh keeps Blender's vertex count under its stack",
          obj.mesh.vertices.count == evaluated.vertices.count, "\(obj.mesh.vertices.count)")
    var stack = obj.modifiers
    stack[0].count = 512
    obj.modifiers = stack
    check("and an edit to the stack does not evaluate it here",
          obj.mesh.vertices.count == evaluated.vertices.count, "\(obj.mesh.vertices.count)")
    let local = BKObject(name: "Local", kind: .cube)
    local.setMirroredMesh(base)
    local.modifiers = screw
    check("while the simulator's own edit path does run it",
          local.mesh.vertices.count == base.vertices.count * 16, "\(local.mesh.vertices.count)")
}

print("\n== a Geometry Nodes modifier has a row, and Smooth by Angle its settings ==")
do {
    // What `_modifier_record` sends for the modifier Shade Auto Smooth adds
    // (5.2.1: the group "Smooth by Angle", Angle 30 degrees, Ignore Sharpness off).
    let auto = Modifier.stack(from: record(
        "kind=NODES;name=Smooth by Angle;group=Smooth by Angle;angle=0.5235987901687622;ignore_sharpness=0"))
    check("it is read, not dropped", auto.count == 1 && auto.first?.kind == .geometryNodes)
    if let m = auto.first {
        check("with its name and group", m.name == "Smooth by Angle" && m.nodeGroup == "Smooth by Angle")
        check("and the two settings the row offers", m.smoothByAngle && close(m.angle, .pi / 6) && !m.ignoreSharpness,
              "\(m.smoothByAngle) \(m.angle) \(m.ignoreSharpness)")
        let lines = Bpy.modifierSettings(m)
        check("each written through the mirror's helper, which finds the input by name and re-evaluates",
              lines.count == 2 && lines.allSatisfy { $0.contains("set_node_input(bpy.context.object, \"Smooth by Angle\"") }
                  && lines[0].contains("\"Angle\", 0.5236") && lines[1].contains("\"Ignore Sharpness\", False"),
              lines.joined(separator: " / "))
        var wider = m
        wider.angle = .pi / 3
        let edit = Bpy.modifierEdit(from: m, to: wider)
        check("an Angle edit sends the angle alone", edit.count == 1 && edit[0].contains("1.0472"), edit.joined())
    }
    // Any other group: named, and nothing sent for inputs the row does not know.
    let other = Modifier.stack(from: record("kind=NODES;name=GeometryNodes;group=Twist"))
    check("another group is a row too, with no Smooth by Angle numbers",
          other.first?.nodeGroup == "Twist" && other.first?.smoothByAngle == false)
    check("which sends nothing", other.first.map { Bpy.modifierSettings($0).isEmpty } == true)
    let empty = Modifier.stack(from: record("kind=NODES;name=GeometryNodes;group="))
    check("and an empty one says it has no group", empty.first?.nodeGroup == "")
    check("Add Modifier does not offer one: an empty one does nothing",
          !ModifierKind.addable.contains(.geometryNodes) && !ModifierKind.addable.contains(.other)
              && ModifierKind.addable.count == ModifierKind.allCases.count - 2)
    // In the simulator the stack never evaluates a node graph.
    let cube = MeshBuilder.cube(size: 2)
    check("the simulator's stack passes the mesh through it",
          ModifierStack.apply(auto, to: cube).vertices.count == cube.vertices.count)
}

print("\n== every modifier Blender has gets a row, in Blender's order ==")
do {
    // The stack round 2's reviewer measured on a cube, in the record shape
    // `_modifier_record` now sends: only the Subdivision used to arrive. With
    // two kinds the panel has no settings for after it, one of them turned
    // off in the viewport.
    let stack = Modifier.stack(from: record(
        "kind=MULTIRES;name=Multires;show_viewport=1;show_render=1;levels=1.0;sculpt_levels=2.0;render_levels=2.0;total_levels=2.0",
        "kind=WEIGHTED_NORMAL;name=WeightedNormal;show_viewport=1;show_render=0;mode=CORNER_ANGLE;weight=70.0;thresh=0.25;keep_sharp=1;use_face_influence=1",
        "kind=EDGE_SPLIT;name=EdgeSplit;show_viewport=1;show_render=1;split_angle=0.6981317;use_edge_angle=1;use_edge_sharp=0",
        "kind=LAPLACIANSMOOTH;name=LaplacianSmooth;show_viewport=1;show_render=1;iterations=4.0;lambda_factor=0.5;lambda_border=0.2;use_x=1;use_y=0;use_z=1;use_volume_preserve=0;use_normalized=1",
        "kind=SUBSURF;name=Subdivision;show_viewport=1;show_render=1;levels=2.0",
        "kind=SURFACE_DEFORM;name=SurfaceDeform;type_label=Surface Deform;show_viewport=0;show_render=1",
        "kind=HOOK;name=Hook-Empty;type_label=Hook;show_viewport=1;show_render=1"))
    check("seven rows for seven modifiers", stack.count == 7, "\(stack.count)")
    check("in Blender's order",
          stack.map(\.name) == ["Multires", "WeightedNormal", "EdgeSplit", "LaplacianSmooth",
                                "Subdivision", "SurfaceDeform", "Hook-Empty"], "\(stack.map(\.name))")
    check("each the kind it is",
          stack.map(\.kind) == [.multires, .weightedNormal, .edgeSplit, .laplacianSmooth,
                                .subdivision, .other, .other], "\(stack.map(\.kind))")
    if stack.count == 7 {
        let multires = stack[0], normal = stack[1], split = stack[2], laplace = stack[3]
        check("Multires: its three levels and the total", multires.levels == 1 && multires.sculptLevels == 2
                  && multires.renderLevels == 2 && multires.totalLevels == 2,
              "\(multires.levels) \(multires.sculptLevels) \(multires.renderLevels) \(multires.totalLevels)")
        check("Weighted Normal: mode, weight, threshold, the two flags",
              normal.weightMode == .cornerAngle && normal.weight == 70 && close(normal.threshold, 0.25)
                  && normal.keepSharp && normal.faceInfluence)
        check("and its render switch, off", !normal.showInRender && normal.showInViewport)
        check("Edge Split: angle and flags", close(split.angle, 0.6981317) && split.edgeSplitAngle
                  && !split.edgeSplitSharp)
        check("Laplacian Smooth: repeat, factors and axes, not Wave's Motion",
              laplace.iterations == 4 && close(laplace.lambdaFactor, 0.5) && close(laplace.lambdaBorder, 0.2)
                  && laplace.smoothX && !laplace.smoothY && laplace.smoothZ
                  && !laplace.preserveVolume && laplace.normalized
                  && laplace.waveX && laplace.waveY)
        check("a kind with no settings rows keeps its own type and Blender's name for it",
              stack[5].blenderType == "SURFACE_DEFORM" && stack[5].typeLabel == "Surface Deform"
                  && !stack[5].showInViewport && stack[5].showInRender)
        check("a modelled kind knows its own", stack[4].blenderType == "SUBSURF"
                  && stack[4].typeLabel == "Subdivision Surface")
        check("such a row sends no settings of its own", Bpy.modifierSettings(stack[5]).isEmpty)
        check("but has the two switches every row has",
              Bpy.modifierVisibility(stack[5]) == [
                "bpy.context.object.modifiers[\"SurfaceDeform\"].show_viewport = False",
                "bpy.context.object.modifiers[\"SurfaceDeform\"].show_render = True"],
              Bpy.modifierVisibility(stack[5]).joined(separator: " / "))
    }
    check("a record with no label reads the identifier", Modifier.stack(from: "kind=MESH_DEFORM;name=M")
              .first?.typeLabel == "Mesh Deform")
    check("an entry with no kind is dropped", Modifier.stack(from: "kind=;name=X").isEmpty)
    // Wave's Motion is still Wave's.
    let wave = Modifier.stack(from: "kind=WAVE;name=Wave;use_x=0;use_y=1")[0]
    check("Wave still reads use_x as Motion X", !wave.waveX && wave.waveY && wave.smoothX)
    let remesh = Modifier.stack(from: "kind=REMESH;name=Remesh;mode=BLOCKS")[0]
    let weighted = Modifier.stack(from: "kind=WEIGHTED_NORMAL;name=W;mode=FACE_AREA_WITH_ANGLE")[0]
    check("`mode` is Remesh's algorithm on a Remesh and the weighting on a Weighted Normal",
          remesh.remeshMode == .blocks && weighted.weightMode == .faceAreaWithAngle
              && weighted.remeshMode == .voxel)
}

print("\n== the two switches every row has ==")
do {
    let m = Modifier.stack(from: "kind=SURFACE_DEFORM;name=SurfaceDeform;type_label=Surface Deform;show_viewport=1;show_render=1")[0]
    let viewport = ModifierRowAction.toggleViewport.command(for: m, in: [m])
    check("Show in Viewport sends show_viewport alone",
          viewport?.lines == ["bpy.context.object.modifiers[\"SurfaceDeform\"].show_viewport = False"]
              && viewport?.undo == "Edit Modifier", viewport?.lines.joined(separator: " / ") ?? "nil")
    let render = ModifierRowAction.toggleRender.command(for: m, in: [m])
    check("Show in Render sends show_render alone",
          render?.lines == ["bpy.context.object.modifiers[\"SurfaceDeform\"].show_render = False"],
          render?.lines.joined(separator: " / ") ?? "nil")
    // A settings edit still sends only its own change.
    var subsurf = Modifier(kind: .subdivision)
    var hidden = subsurf
    hidden.showInViewport = false
    check("on a modelled kind too, and only that",
          Bpy.modifierEdit(from: subsurf, to: hidden) == [Bpy.setModifierProperty("Subdivision", "show_viewport", "False")])
    subsurf.levels = 2
    // The simulator's stack honours the switch, as Blender's evaluation does.
    let cube = MeshBuilder.cube(size: 2)
    check("a Subdivision on in the viewport changes the simulator's mesh",
          ModifierStack.apply([subsurf], to: cube).vertices.count > cube.vertices.count)
    subsurf.showInViewport = false
    check("and one turned off does not",
          ModifierStack.apply([subsurf], to: cube).vertices.count == cube.vertices.count)
}

print("\n== the header's Apply, moves and remove, on any row ==")
do {
    let stack = Modifier.stack(from: record(
        "kind=MULTIRES;name=Multires;total_levels=0.0",
        "kind=WIREFRAME;name=Wireframe;type_label=Wireframe",
        "kind=SUBSURF;name=Subdivision;levels=1.0"))
    check("Move Up on the first row sends nothing: its item is disabled",
          ModifierRowAction.moveUp.command(for: stack[0], in: stack) == nil)
    check("Move Down on the last sends nothing",
          ModifierRowAction.moveDown.command(for: stack[2], in: stack) == nil)
    let up = ModifierRowAction.moveUp.command(for: stack[1], in: stack)
    check("Move Up on an unmodelled kind is Blender's operator, refusing in words when Blender cancels",
          up?.undo == "Move Up Modifier" && up?.lines.count == 1
              && up!.lines[0].contains("if 'CANCELLED' in bpy.ops.object.modifier_move_up(modifier=\"Wireframe\"):")
              && up!.lines[0].contains("raise RuntimeError("), up?.lines.joined() ?? "nil")
    // Blender's rule is about the two types that need the original mesh,
    // Multires and Soft Body, not Multires alone (round 3's review: a
    // Subdivision under a Soft Body, with no Multires, is refused too).
    check("and the refusal names both types Blender's rule is about",
          up!.lines[0].contains("a Multiresolution or a Soft Body") && !up!.lines[0].contains("must stay above"),
          up!.lines[0])
    let down = ModifierRowAction.moveDown.command(for: stack[0], in: stack)
    check("Move Down likewise", down?.undo == "Move Down Modifier"
              && down!.lines[0].contains("modifier_move_down(modifier=\"Multires\")"))
    for (i, m) in stack.enumerated() {
        let apply = ModifierRowAction.apply.command(for: m, in: stack)
        check("row \(i) (\(m.typeLabel)) has Apply: object.modifier_apply, bare, so the mode guard runs it in object mode",
              apply?.lines == ["bpy.ops.object.modifier_apply(modifier=\"\(m.name)\")"] && apply?.undo == "Apply Modifier"
                  && BpyModeGuard.requiredMode(for: apply!.lines[0]) == "OBJECT")
        check("and remove", ModifierRowAction.remove.command(for: m, in: stack)?.lines
                  == ["bpy.ops.object.modifier_remove(modifier=\"\(m.name)\")"])
    }
    check("Multires's operators are offered on a Multires only",
          ModifierRowAction.multires(.subdivide).command(for: stack[1], in: stack) == nil
              && ModifierRowAction.multires(.subdivide).command(for: stack[0], in: stack)?.undo == "Multires Subdivide")
    check("the hook names every action", ["viewport", "render", "up", "down", "apply", "remove",
                                          "subdivide", "unsubdivide", "deleteHigher", "applyBase"]
              .allSatisfy { ModifierRowAction(hookName: $0) != nil }
              && ModifierRowAction(hookName: "fly") == nil)
}

print("\n== Multires ==")
do {
    let fresh = Modifier(kind: .multires)
    check("a new Multires has no levels, as Blender's", fresh.levels == 0 && fresh.totalLevels == 0
              && fresh.sculptLevels == 0 && fresh.renderLevels == 0)
    check("its rows send the three levels, never the read-only total",
          Bpy.modifierSettings(fresh) == ["levels", "sculpt_levels", "render_levels"].map {
              Bpy.setModifierProperty("Multires", $0, "0") }, Bpy.modifierSettings(fresh).joined(separator: " / "))
    // Each goes through _blenderkit_multires, which takes the object to
    // Object Mode, checks it got there, and refuses in words if not. They
    // used to be bare operators under BpyModeGuard, whose failed mode_set
    // (an object hidden in Sculpt Mode) was swallowed and the operator run
    // in Sculpt Mode anyway; measured in 5.2.1, Apply Base there with no
    // undo stack segfaults. What the module does is checked in Blender, by
    // scripts/run-modifier-blender-check.sh; here, that every button reaches
    // it and nothing else.
    check("every Multires button calls the module with its operation and the modifier's name",
          Bpy.MultiresOperation.allCases.allSatisfy {
              Bpy.multires($0, "Multires")
                  == "import _blenderkit_multires\n_blenderkit_multires.run(\"\($0.rawValue)\", \"Multires\")"
          }, Bpy.multires(.subdivide, "Multires"))
    check("a name with quotes in it stays one Python string",
          Bpy.multires(.applyBase, "a\"b'c").hasSuffix("run(\"applyBase\", \"a\\\"b'c\")"),
          Bpy.multires(.applyBase, "a\"b'c"))
    check("and the mode guard leaves them alone: the module does the mode, and refuses when it cannot",
          Bpy.MultiresOperation.allCases.allSatisfy {
              BpyModeGuard.requiredMode(for: Bpy.multires($0, "Multires")) == nil
          })
    let source = (try? String(contentsOfFile: "Resources/python/site/_blenderkit_multires.py",
                              encoding: .utf8)) ?? ""
    check("the module knows every operation the buttons send",
          Bpy.MultiresOperation.allCases.allSatisfy { source.contains("'\($0.rawValue)': '\($0.label)'") },
          "Resources/python/site/_blenderkit_multires.py")
    var two = fresh
    two.totalLevels = 2; two.levels = 2
    let cube = MeshBuilder.cube(size: 2)
    var one = two
    one.levels = 1
    check("the simulator subdivides by the viewport level",
          ModifierStack.apply([two], to: cube).vertices.count > ModifierStack.apply([one], to: cube).vertices.count
              && ModifierStack.apply([one], to: cube).vertices.count > cube.vertices.count)
    var unmade = fresh
    unmade.levels = 3
    check("but never past what Subdivide made", ModifierStack.apply([unmade], to: cube).vertices.count
              == cube.vertices.count)
}

print("\n== Weighted Normal, Edge Split, Laplacian and Corrective Smooth, Lattice ==")
do {
    var normal = Modifier(kind: .weightedNormal)
    check("Weighted Normal's defaults are Blender's", normal.weight == 50 && close(normal.threshold, 0.01)
              && normal.weightMode == .faceArea && !normal.keepSharp && !normal.faceInfluence)
    normal.weightMode = .faceAreaWithAngle
    var heavier = normal
    heavier.weight = 80
    check("a weight edit sends the weight alone, as an integer",
          Bpy.modifierEdit(from: normal, to: heavier) == [Bpy.setModifierProperty("WeightedNormal", "weight", "80")])
    check("the mode goes as its identifier",
          Bpy.modifierSettings(normal).contains(Bpy.setModifierProperty("WeightedNormal", "mode", "\"FACE_AREA_WITH_ANGLE\"")))

    let split = Modifier(kind: .edgeSplit)
    check("Edge Split's defaults: 30 degrees, both on", close(split.angle, .pi / 6) && split.edgeSplitAngle
              && split.edgeSplitSharp)
    check("and it sends split_angle", Bpy.modifierSettings(split).first == Bpy.setModifierProperty("EdgeSplit", "split_angle", "0.5236"))

    var laplace = Modifier(kind: .laplacianSmooth)
    check("Laplacian Smooth's defaults are Blender's", laplace.iterations == 1 && close(laplace.lambdaFactor, 0.01)
              && laplace.smoothX && laplace.smoothY && laplace.smoothZ && laplace.preserveVolume && laplace.normalized)
    var noZ = laplace
    noZ.smoothZ = false
    check("an axis toggle sends that axis alone",
          Bpy.modifierEdit(from: laplace, to: noZ) == [Bpy.setModifierProperty("LaplacianSmooth", "use_z", "False")])
    laplace.lambdaFactor = 1; laplace.iterations = 3; laplace.smoothZ = false
    let sphere = MeshBuilder.uvSphere(radius: 1, segments: 16, rings: 8)
    let smoothedSphere = ModifierStack.apply([laplace], to: sphere)
    check("the simulator's Laplacian moves the mesh", zip(sphere.vertices, smoothedSphere.vertices)
              .contains { length($0.position - $1.position) > 1e-3 })
    check("and leaves an axis that is off where it was", zip(sphere.vertices, smoothedSphere.vertices)
              .allSatisfy { abs($0.position.z - $1.position.z) < 1e-6 })

    let corrective = Modifier(kind: .correctiveSmooth)
    check("Corrective Smooth's defaults are Blender's: factor 0.5, repeat 5, scale 1, Simple",
          close(corrective.factor, 0.5) && corrective.iterations == 5 && corrective.smoothScale == 1
              && corrective.smoothType == .simple && corrective.restSource == "ORCO")
    check("it sends six settings and never rest_source or is_bind",
          Bpy.modifierSettings(corrective).count == 6
              && !Bpy.modifierSettings(corrective).contains { $0.contains("rest_source") || $0.contains("is_bind") })
    let bound = Modifier.stack(from: "kind=CORRECTIVE_SMOOTH;name=CorrectiveSmooth;rest_source=BIND;is_bind=1;smooth_type=LENGTH_WEIGHTED;scale=2.0")[0]
    check("its rest source and binding are read to be shown", bound.restSource == "BIND" && bound.isBound
              && bound.smoothType == .lengthWeighted && bound.smoothScale == 2)

    var lattice = Modifier(kind: .lattice)
    check("Lattice's strength starts at Blender's 1", lattice.thickness == 1)
    check("with no lattice picked, the pointer is sent as None",
          Bpy.modifierSettings(lattice) == [Bpy.setModifierProperty("Lattice", "strength", "1.0000"),
                                            Bpy.setModifierProperty("Lattice", "object", "None")])
    var picked = lattice
    picked.targetName = "Cage"
    check("picking one sends the object alone",
          Bpy.modifierEdit(from: lattice, to: picked) == [Bpy.setModifierProperty("Lattice", "object", "bpy.data.objects[\"Cage\"]")])
    check("and the picker's None clears it, which it could not before",
          Bpy.modifierEdit(from: picked, to: lattice) == [Bpy.setModifierProperty("Lattice", "object", "None")])
    var stronger = lattice
    stronger.thickness = 0.5
    check("a strength edit with nothing picked sends the strength alone",
          Bpy.modifierEdit(from: lattice, to: stronger) == [Bpy.setModifierProperty("Lattice", "strength", "0.5000")])
    lattice = Modifier.stack(from: "kind=LATTICE;name=Lattice;strength=0.5;object=Cage")[0]
    check("and both come back from the record", lattice.targetName == "Cage" && close(lattice.thickness, 0.5))
    check("each new kind is offered by Add Modifier, under Blender's menu name",
          [ModifierKind.weightedNormal, .multires, .edgeSplit, .laplacianSmooth, .correctiveSmooth, .lattice]
              .allSatisfy { ModifierKind.addable.contains($0) }
              && ModifierKind.multires.label == "Multiresolution" && ModifierKind.multires.displayName == "Multires")
    // Measured in 5.2.1: modifier_add refuses these six on a Bézier curve, a
    // text and a NURBS surface, with a TypeError dumping its enum.
    check("on a curve, text or surface, Add Modifier leaves out the six Blender refuses there",
          ["CURVE", "FONT", "SURFACE"].allSatisfy { type in
              let offered = Set(ModifierKind.addable(on: type))
              return offered.isDisjoint(with: ModifierKind.meshOnly)
                  && offered.union(ModifierKind.meshOnly) == Set(ModifierKind.addable)
          })
    check("and offers a mesh everything", ModifierKind.addable(on: "MESH") == ModifierKind.addable)
}

print("\n== the simulator keeps Blender's rules for adding, moving and applying ==")
do {
    // Round 3's review: the simulator appended a Multires, swapped any two
    // rows, gave the mesh back for Only Smooth, and baked a Lattice with
    // nothing picked. Each rule is Blender's (object_modifier.cc and the
    // MOD_*.cc type flags in 5.2.1; verify.py measures them in Blender).
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let cube = scene.add(.cube)
    cube.addModifier(.wave)
    cube.addModifier(.subdivision)
    cube.addModifier(.multires)
    check("Add Multires goes above the first modifier that is not a pure deform, as Blender puts it",
          cube.modifiers.map(\.kind) == [.wave, .multires, .subdivision], cube.modifiers.map(\.name).joined(separator: ", "))
    cube.addModifier(.lattice)
    check("anything else goes at the end", cube.modifiers.last?.kind == .lattice)
    let stack = cube.modifiers
    check("a Subdivision cannot move above a Multires",
          !ModifierStack.canMove(2, up: true, in: stack))
    check("nor a Multires below a Subdivision", !ModifierStack.canMove(1, up: false, in: stack))
    check("a Wave, a pure deform, can move below the Multires",
          ModifierStack.canMove(0, up: false, in: stack))
    check("and the Multires above it", ModifierStack.canMove(1, up: true, in: stack))
    check("nothing moves past either end",
          !ModifierStack.canMove(0, up: true, in: stack) && !ModifierStack.canMove(3, up: false, in: stack))
    check("the pure deforms are Blender's OnlyDeform types",
          ModifierKind.allCases.filter(\.onlyDeforms) == [.smooth, .cast, .simpleDeform, .displace, .wave,
                                                          .shrinkwrap, .laplacianSmooth, .correctiveSmooth, .lattice])

    check("Apply on a Lattice with nothing picked is refused, and the row stays",
          !cube.applyModifier(named: "Lattice") && cube.modifiers.contains { $0.name == "Lattice" })
    var picked = Modifier(kind: .boolean)
    check("a Boolean, Shrinkwrap or Lattice with nothing picked is disabled, as Blender says",
          picked.isDisabled && Modifier(kind: .shrinkwrap).isDisabled && !Modifier(kind: .subdivision).isDisabled)
    picked.targetName = "Cutter"
    check("and with something picked it is not", !picked.isDisabled)

    let sphere = MeshBuilder.uvSphere(radius: 1, segments: 16, rings: 8)
    var corrective = Modifier(kind: .correctiveSmooth)
    let kept = ModifierStack.apply([corrective], to: sphere)
    corrective.onlySmooth = true
    let smoothedOnly = ModifierStack.apply([corrective], to: sphere)
    check("Corrective Smooth alone gives the mesh back, as in Blender",
          zip(sphere.vertices, kept.vertices).allSatisfy { length($0.position - $1.position) < 1e-6 })
    check("and with Only Smooth it smooths it outright, as in Blender",
          zip(sphere.vertices, smoothedOnly.vertices).contains { length($0.position - $1.position) > 1e-3 })
}

print("\n== the simulator's Apply bakes the one modifier ==")
do {
    // Blender applies the modifier to the object's own mesh and leaves the
    // rest of the stack on top (measured: Edge Split third in a stack turned
    // the base cube's 8 vertices into 24). The shim froze the whole evaluated
    // stack and ran the rest over it again.
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let cube = scene.add(.cube)
    cube.addModifier(.subdivision)
    cube.addModifier(.array)
    let before = cube.mesh.vertices.count
    let base = cube.evaluatedBase.vertices.count
    var subsurfOnly = cube.modifiers
    subsurfOnly.removeLast()
    let subdividedBase = ModifierStack.apply(subsurfOnly, to: cube.evaluatedBase).vertices.count
    check("Apply takes the Subdivision off the stack", cube.applyModifier(named: "Subdivision")
              && cube.modifiers.map(\.kind) == [.array])
    check("the base becomes the subdivided cube", cube.evaluatedBase.vertices.count == subdividedBase
              && subdividedBase > base, "\(cube.evaluatedBase.vertices.count) vs \(subdividedBase)")
    check("and what is drawn is unchanged: the Array ran once over it, not twice",
          cube.mesh.vertices.count == before, "\(cube.mesh.vertices.count), was \(before)")
    // Applying the second one applies it to the base alone.
    let other = scene.add(.cube)
    other.addModifier(.array)
    var hiddenSub = Modifier(kind: .subdivision)
    hiddenSub.showInViewport = false
    other.modifiers.append(hiddenSub)
    let drawn = other.mesh.vertices.count
    check("a Subdivision hidden in the viewport is applied all the same, as Blender applies it",
          other.applyModifier(named: "Subdivision") && other.evaluatedBase.vertices.count > MeshBuilder.cube(size: 2).vertices.count
              && other.mesh.vertices.count > drawn, "\(other.mesh.vertices.count) vs \(drawn)")
    check("an unknown name is refused", !other.applyModifier(named: "Nothing"))
}

print("\n== the record's separators inside a value ==")
do {
    // `_modifier_value` in _blenderkit_sync.py escapes them; Blender takes
    // 'a;b|c=d%e' as a modifier's name (measured in 5.2.1).
    let stack = Modifier.stack(from:
        "kind=WIREFRAME;name=a%3Bb%7Cc%3Dd%25e;type_label=Wireframe;show_viewport=1|kind=SUBSURF;name=Subdivision;levels=2.0")
    check("two rows, not three", stack.count == 2, "\(stack.map(\.name))")
    check("the name as Blender has it", stack.first?.name == "a;b|c=d%e", stack.first?.name ?? "nil")
    check("so the row's switch names that modifier",
          stack.first.map { ModifierRowAction.toggleViewport.command(for: $0, in: stack)?.lines }
              == [#"bpy.context.object.modifiers["a;b|c=d%e"].show_viewport = False"#])
    check("and the row after it is untouched", stack.last?.levels == 2)
    check("a stray % that is not an escape is kept",
          Modifier.stack(from: "kind=HOOK;name=100% done;type_label=Hook").first?.name == "100% done")
    let lattice = Modifier.stack(from: "kind=LATTICE;name=Lattice;object=Cage%3B2;strength=1.0")[0]
    check("an object pointer's name likewise", lattice.targetName == "Cage;2", lattice.targetName)
}

print("\n== a modifier the mirror could not read ==")
do {
    // `_modifier_record` sends it by kind and name, marked `unread`: a
    // Subdivision row there would show level 1, which Blender may not hold.
    let m = Modifier.stack(from: "kind=SUBSURF;name=Subdivision;type_label=Subdivision Surface;unread=1")[0]
    check("it still has a row, with the controls every row has", m.kind == .other
              && m.blenderType == "SUBSURF" && m.typeLabel == "Subdivision Surface")
    check("and sends no settings", Bpy.modifierSettings(m).isEmpty)
}

print("\n== a row's identity across a mirroring pass ==")
do {
    let old = Modifier.stack(from: "kind=HOOK;name=Deform;type_label=Hook|kind=SUBSURF;name=Subdivision")
    let same = SceneMirror.keepingIdentity(
        Modifier.stack(from: "kind=HOOK;name=Deform;type_label=Hook|kind=SUBSURF;name=Subdivision;levels=2.0"),
        from: old)
    check("the same modifiers keep their rows", same.map(\.id) == old.map(\.id))
    let replaced = SceneMirror.keepingIdentity(
        Modifier.stack(from: "kind=WIREFRAME;name=Deform;type_label=Wireframe"), from: old)
    check("a different type under the same name is a new row", replaced[0].id != old[0].id)
}

print("\n== the budget check rides with a level or a count ==")
do {
    // The Levels stepper had no size check (round 3's review): the check line
    // goes first, so Blender refuses before anything is set, and it carries
    // the value, so `modifierEdit` sends it with every new level.
    var one = Modifier(kind: .subdivision, name: "Subdivision")
    one.levels = 1
    var seven = one
    seven.levels = 7
    let sent = Bpy.modifierEdit(from: one, to: seven)
    check("a new level sends the check, then levels, then render_levels",
          sent.count == 3 && sent[0] == Bpy.checkModifierSetting("Subdivision", "levels", "7")
            && sent[1].hasSuffix(".levels = 7") && sent[2].hasSuffix(".render_levels = 7"),
          sent.joined(separator: " / "))
    check("the check names the module, the modifier, the key and the value",
          sent[0] == "__import__('_blenderkit_multires').check_setting(\"Subdivision\", \"levels\", 7)", sent[0])
    var array = Modifier(kind: .array, name: "Array")
    array.count = 2
    var many = array
    many.count = 40
    let counted = Bpy.modifierEdit(from: array, to: many)
    check("an Array's new count sends its check first",
          counted.first == Bpy.checkModifierSetting("Array", "count", "40"), counted.joined(separator: " / "))
    var offset = array
    offset.relativeOffset = SIMD3(2, 0, 0)
    check("a change that is not the count sends no check",
          !Bpy.modifierEdit(from: array, to: offset).contains { $0.contains("check_setting") })
}

print("\n== Duplicate in Edit Mode ==")
check("it is Blender's Edit Mode Shift+D, the mesh's elements",
      Bpy.duplicateElements == "bpy.ops.mesh.duplicate_move()" && Bpy.duplicate == "bpy.ops.object.duplicate_move()")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
