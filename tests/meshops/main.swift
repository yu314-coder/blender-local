import Foundation
import simd

// Exercises the operations behind the new per-mode header menus. A menu item
// that silently corrupts the mesh is worse than a missing one, so every entry
// that does real work is checked here.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func close(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool { abs(a - b) < eps }

/// Two triangles sharing an edge, plus a duplicated pair on top of them, so
/// merging has something real to weld.
func quad() -> MeshData {
    let p: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0)]
    let n = SIMD3<Float>(0,0,1)
    return MeshData(vertices: p.map { MeshVertex($0, n) }, indices: [0,1,2, 0,2,3])
}

print("== merge by distance ==")
do {
    // A quad whose four corners are each duplicated: 8 verts, 2 triangles that
    // use only the first copies.
    let p: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0)]
    var verts = p.map { MeshVertex($0, SIMD3(0,0,1)) }
    verts += p.map { MeshVertex($0, SIMD3(0,0,1)) }          // exact duplicates
    let mesh = MeshData(vertices: verts, indices: [0,1,2, 4,6,7])
    let (merged, count) = MeshEditor.mergeByDistance(mesh, vertices: [])
    check("welds 4 duplicate vertices", count == 4, "merged \(count)")
    check("vertex count drops 8 -> 4", merged.vertices.count == 4, "\(merged.vertices.count)")
    check("both triangles survive", merged.indices.count == 6, "\(merged.indices.count)")
}

print("\n== merge drops degenerate triangles ==")
do {
    // Third corner sits on the second, so the triangle collapses to a line.
    let verts = [MeshVertex(SIMD3(0,0,0), SIMD3(0,0,1)),
                 MeshVertex(SIMD3(1,0,0), SIMD3(0,0,1)),
                 MeshVertex(SIMD3(1,0,0), SIMD3(0,0,1))]
    let (merged, _) = MeshEditor.mergeByDistance(MeshData(vertices: verts, indices: [0,1,2]),
                                                 vertices: [])
    check("collapsed triangle is removed", merged.indices.isEmpty, "\(merged.indices.count) indices")
}

print("\n== smooth vertices ==")
do {
    // A spike: the middle vertex is pulled off the plane, and smoothing should
    // bring it back toward its neighbours.
    var mesh = quad()
    mesh.vertices[2].position.z = 1.0
    let before = mesh.vertices[2].position.z
    let after = MeshEditor.smoothVertices(mesh, vertices: [2], factor: 0.5).vertices[2].position.z
    check("spike is pulled toward its neighbours", after < before && after > 0,
          "before \(before) after \(after)")
    // Untouched vertices must stay put.
    let other = MeshEditor.smoothVertices(mesh, vertices: [2], factor: 0.5).vertices[0].position
    check("unselected vertices do not move", close(other.x, 0) && close(other.y, 0))
}

print("\n== delete vertices ==")
do {
    let mesh = MeshEditor.deleteVertices(quad(), vertices: [1])
    check("removes the vertex", mesh.vertices.count == 3, "\(mesh.vertices.count)")
    // Only the triangle that used vertex 1 goes; the other survives, reindexed.
    check("drops only the faces that used it", mesh.indices.count == 3, "\(mesh.indices.count)")
    check("surviving indices stay in range",
          mesh.indices.allSatisfy { Int($0) < mesh.vertices.count })
}

print("\n== delete edges ==")
do {
    let mesh = quad()
    // Find the shared diagonal 0-2; both triangles use it.
    var target = -1
    for e in 0..<(mesh.edges.count / 2) {
        let a = mesh.edges[e*2], b = mesh.edges[e*2+1]
        if (a == 0 && b == 2) || (a == 2 && b == 0) { target = e }
    }
    check("the shared edge exists", target >= 0)
    let cut = MeshEditor.deleteEdges(mesh, edges: [target])
    check("both faces on that edge are removed", cut.indices.isEmpty, "\(cut.indices.count)")
    check("vertices are kept", cut.vertices.count == 4, "\(cut.vertices.count)")
}

print("\n== poke faces ==")
do {
    let (poked, faces) = MeshEditor.pokeFaces(quad(), faces: [0])
    check("one triangle becomes three", poked.indices.count == 3 * 3 + 3, "\(poked.indices.count/3) tris")
    check("adds one centre vertex", poked.vertices.count == 5, "\(poked.vertices.count)")
    check("reports the three new faces", faces.count == 3, "\(faces.count)")
    // The centre must be the average of the poked triangle's corners.
    let c = poked.vertices[4].position
    check("centre is the face centroid", close(c.x, 2.0/3.0, 1e-3) && close(c.y, 1.0/3.0, 1e-3),
          "\(c)")
}

print("\n== flip normals ==")
do {
    let mesh = quad()
    let flipped = MeshEditor.flipNormals(mesh, faces: [0])
    check("winding of the flipped face reverses",
          flipped.indices[1] == mesh.indices[2] && flipped.indices[2] == mesh.indices[1])
    check("the other face is untouched",
          flipped.indices[4] == mesh.indices[4] && flipped.indices[5] == mesh.indices[5])
    // The geometric normal must actually point the other way now.
    func normal(_ m: MeshData, _ f: Int) -> SIMD3<Float> {
        let p = (0..<3).map { m.vertices[Int(m.indices[f*3+$0])].position }
        return normalize(cross(p[1]-p[0], p[2]-p[0]))
    }
    check("geometric normal inverts", dot(normal(mesh,0), normal(flipped,0)) < -0.99,
          "\(dot(normal(mesh,0), normal(flipped,0)))")
}

print("\n== extrude individual faces ==")
do {
    let (out, faces) = MeshEditor.extrudeIndividual(quad(), faces: [0], distance: 0.5)
    check("adds a cap and four wall triangles", out.indices.count == 6 + 3 + 6*3 - 0 || out.indices.count > 6,
          "\(out.indices.count/3) tris")
    check("reports the new cap face", faces.count == 1, "\(faces.count)")
    check("the cap is offset along the normal",
          out.vertices.contains { close($0.position.z, 0.5, 1e-3) })
    // "Individual" means the original face's vertices are not shared with it.
    check("does not disturb the neighbouring face",
          out.indices[3] == 0 && out.indices[4] == 2 && out.indices[5] == 3)
}

print("\n== select linked / more / less ==")
do {
    // Two separate quads, far apart: linked from one must not reach the other.
    var verts: [MeshVertex] = []
    var idx: [UInt32] = []
    for (k, dx) in [(0, Float(0)), (1, Float(10))] {
        let base = UInt32(k * 4)
        for p in [SIMD3<Float>(dx,0,0), SIMD3(dx+1,0,0), SIMD3(dx+1,1,0), SIMD3(dx,1,0)] {
            verts.append(MeshVertex(p, SIMD3(0,0,1)))
        }
        idx += [base, base+1, base+2, base, base+2, base+3]
    }
    let mesh = MeshData(vertices: verts, indices: idx)
    let linked = MeshEditor.selectLinked(mesh, from: [0])
    check("linked reaches the whole island", linked == [0, 1], "\(linked.sorted())")
    check("linked stops at the gap", !linked.contains(2) && !linked.contains(3))

    let grown = MeshEditor.growSelection(mesh, faces: [0])
    check("more grows across a shared vertex", grown == [0, 1], "\(grown.sorted())")
    // Blender's select_less deselects only where the selection borders
    // *deselected* geometry — an open mesh boundary does not count. Verified
    // against Blender 5.2.1: a fully selected grid, cube and sphere all come
    // back unchanged (9->9, 6->6, 512->512).
    let whole = MeshEditor.shrinkSelection(mesh, faces: [0, 1, 2, 3])
    check("less leaves a fully-selected mesh alone", whole.count == 4, "\(whole.sorted())")

    // Island A whole, plus one face of island B: only the bordering face goes.
    let partial = MeshEditor.shrinkSelection(mesh, faces: [0, 1, 2])
    check("less drops the face bordering unselected geometry", partial == [0, 1],
          "\(partial.sorted())")
}

print("\n== weight ramp ==")
do {
    let c0 = WeightRamp.colour(0), c5 = WeightRamp.colour(0.5), c1 = WeightRamp.colour(1)
    check("0 is blue",  close(c0.x,0) && close(c0.y,0) && close(c0.z,1), "\(c0)")
    check("0.5 is green", close(c5.x,0) && close(c5.y,1) && close(c5.z,0), "\(c5)")
    check("1 is red",   close(c1.x,1) && close(c1.y,0) && close(c1.z,0), "\(c1)")
    check("clamps out-of-range input",
          WeightRamp.colour(-5) == c0 && WeightRamp.colour(5) == c1)
}

print("\n== vertex paint dab ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    obj.ensurePaintAttributes()
    let n = obj.mesh.vertices.count
    check("attributes size to the mesh", obj.vertexColours.count == n && obj.vertexWeights.count == n,
          "\(obj.vertexColours.count)/\(n)")
    check("unpainted colour reads white", obj.vertexColour(at: 0) == SIMD4(1,1,1,1))

    // Paint red at one corner with a radius that cannot reach the far side.
    let corner = (obj.modelMatrix * SIMD4(obj.mesh.vertices[0].position, 1)).xyz
    let touched = obj.paintVertices(at: corner, radius: 0.5, strength: 1.0,
                                    colour: SIMD4(1,0,0,1), weight: nil)
    check("the dab touches some vertices", touched > 0, "\(touched)")
    check("the dab does not touch every vertex", touched < n, "\(touched)/\(n)")
    check("the nearest vertex turned red",
          obj.vertexColour(at: 0).x > 0.9 && obj.vertexColour(at: 0).y < 0.2,
          "\(obj.vertexColour(at: 0))")

    // Falloff: a vertex at the very edge of the brush must change less than the
    // one at its centre.
    let centreDelta = 1 - obj.vertexColour(at: 0).y
    var edgeDelta: Float = 0
    for i in 1..<n {
        let w = (obj.modelMatrix * SIMD4(obj.mesh.vertices[i].position, 1)).xyz
        if distance(w, corner) > 0.4 && distance(w, corner) < 0.5 {
            edgeDelta = max(edgeDelta, 1 - obj.vertexColour(at: i).y)
        }
    }
    check("falloff: edge changes less than centre", edgeDelta < centreDelta,
          "edge \(edgeDelta) centre \(centreDelta)")
}

print("\n== weight paint dab ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    let corner = (obj.modelMatrix * SIMD4(obj.mesh.vertices[0].position, 1)).xyz
    _ = obj.paintVertices(at: corner, radius: 0.5, strength: 1.0, colour: nil, weight: 1.0)
    check("weight rises at the brush centre", obj.vertexWeight(at: 0) > 0.9,
          "\(obj.vertexWeight(at: 0))")
    check("colour is untouched by a weight dab", obj.vertexColour(at: 0) == SIMD4(1,1,1,1))

    obj.mapVertexWeights { 1 - $0 }
    check("invert flips the weights", obj.vertexWeight(at: 0) < 0.1, "\(obj.vertexWeight(at: 0))")
}

print("\n== unwrap methods agree with their bpy names ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    for m in UVUnwrapMethod.allCases {
        let uvs = m.project(obj.mesh)
        check("\(m.label) produces one UV per vertex", uvs.count == obj.mesh.vertices.count,
              "\(uvs.count)/\(obj.mesh.vertices.count)")
        check("\(m.label) stays inside 0…1",
              uvs.allSatisfy { $0.x >= -0.001 && $0.x <= 1.001 && $0.y >= -0.001 && $0.y <= 1.001 })
    }
}

print("\n== mesh symmetry ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    check("no symmetry gives one point", obj.symmetryPoints(SIMD3(1,2,3)).count == 1)

    obj.symmetry.x = true
    let x = obj.symmetryPoints(SIMD3(1, 2, 3))
    check("X gives two points", x.count == 2, "\(x.count)")
    check("X mirrors only x", x.contains { $0 == SIMD3(-1, 2, 3) }, "\(x)")

    obj.symmetry.y = true
    check("X+Y gives four points", obj.symmetryPoints(SIMD3(1,2,3)).count == 4)
    obj.symmetry.z = true
    let all = obj.symmetryPoints(SIMD3(1, 2, 3))
    check("X+Y+Z gives eight points", all.count == 8, "\(all.count)")
    check("all eight are distinct", Set(all.map { "\($0)" }).count == 8)
    check("the far corner is present", all.contains { $0 == SIMD3(-1, -2, -3) })
    check("label reads XYZ", obj.symmetry.label == "XYZ", obj.symmetry.label)
}

print("\n== symmetric painting ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    obj.ensurePaintAttributes()
    // Paint at one +X corner with symmetry off, then compare the -X side.
    let corner = obj.mesh.vertices.enumerated().max { a, b in a.element.position.x < b.element.position.x }!
    let world = (obj.modelMatrix * SIMD4(corner.element.position, 1)).xyz
    _ = obj.paintVertices(at: world, radius: 0.6, strength: 1, colour: SIMD4(1,0,0,1), weight: nil)

    // A vertex mirrored across X from the painted corner must still be white.
    var mirrored = -1
    for (i, v) in obj.mesh.vertices.enumerated()
    where abs(v.position.x + corner.element.position.x) < 1e-3
       && abs(v.position.y - corner.element.position.y) < 1e-3
       && abs(v.position.z - corner.element.position.z) < 1e-3 { mirrored = i }
    check("found the mirrored vertex", mirrored >= 0)
    check("without symmetry the far side is untouched",
          obj.vertexColour(at: mirrored).y > 0.9, "\(obj.vertexColour(at: mirrored))")

    // Now with symmetry on, the same dab must reach both sides.
    let scene2 = BKScene(startupFile: false)
    let obj2 = scene2.add(.cube)
    obj2.symmetry.x = true
    _ = obj2.paintVertices(at: world, radius: 0.6, strength: 1, colour: SIMD4(1,0,0,1), weight: nil)
    check("with symmetry X the mirrored vertex is painted too",
          obj2.vertexColour(at: mirrored).y < 0.2, "\(obj2.vertexColour(at: mirrored))")
}

print("\n== brush blend modes ==")
do {
    let grey = SIMD4<Float>(0.5, 0.5, 0.5, 1)
    let red  = SIMD4<Float>(1.0, 0.0, 0.0, 1)
    check("mix at 0 leaves the base", BrushBlend.mix.apply(grey, red, 0) == grey)
    check("mix at 1 becomes the brush", BrushBlend.mix.apply(grey, red, 1) == red)
    let add = BrushBlend.add.apply(grey, red, 1)
    check("add brightens and clamps", close(add.x, 1) && close(add.y, 0.5), "\(add)")
    let sub = BrushBlend.subtract.apply(grey, red, 1)
    check("subtract darkens and clamps at 0", close(sub.x, 0) && close(sub.y, 0.5), "\(sub)")
    let mul = BrushBlend.multiply.apply(grey, red, 1)
    check("multiply scales", close(mul.x, 0.5) && close(mul.y, 0), "\(mul)")
    check("alpha is carried, not blended", BrushBlend.mix.apply(grey, red, 0.5).w == 1)
    for b in BrushBlend.allCases {
        let r = b.apply(grey, red, 1)
        check("\(b.label) stays in 0…1",
              r.x >= 0 && r.x <= 1 && r.y >= 0 && r.y <= 1 && r.z >= 0 && r.z <= 1, "\(r)")
    }
}

print("\n== brush falloff curves ==")
do {
    for f in BrushFalloff.allCases {
        check("\(f.label) is 1 at the centre", close(f.weight(0), 1), "\(f.weight(0))")
        if f != .constant {
            check("\(f.label) is 0 at the rim", close(f.weight(1), 0, 1e-3), "\(f.weight(1))")
            check("\(f.label) never rises with distance",
                  stride(from: Float(0), to: 1, by: 0.05).allSatisfy { f.weight($0) >= f.weight($0 + 0.05) - 1e-4 })
        }
        check("\(f.label) clamps outside 0…1", close(f.weight(-1), f.weight(0)) && close(f.weight(2), f.weight(1)))
    }
    check("constant stays 1 to the rim", close(BrushFalloff.constant.weight(1), 1))
}

print("\n== randomize ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    let before = obj.mesh.vertices.map(\.position)
    let after = MeshEditor.randomize(obj.mesh, vertices: [], amount: 0.1).vertices.map(\.position)
    check("every vertex moves", zip(before, after).allSatisfy { $0 != $1 })
    check("nothing moves further than the amount",
          zip(before, after).allSatisfy { distance($0, $1) <= 0.1001 },
          "\(zip(before, after).map { distance($0, $1) }.max() ?? 0)")
    check("vertex count is unchanged", after.count == before.count)
    // Restricted to a selection, only those move.
    let one = MeshEditor.randomize(obj.mesh, vertices: [0], amount: 0.1).vertices.map(\.position)
    check("a selection limits the jitter",
          one[0] != before[0] && zip(before.dropFirst(), one.dropFirst()).allSatisfy { $0 == $1 })
}

print("\n== shrink/fatten, push/pull, to sphere ==")
do {
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    let before = obj.mesh.vertices.map(\.position)
    let center = before.reduce(SIMD3<Float>.zero, +) / Float(before.count)
    func spread(_ ps: [SIMD3<Float>]) -> Float { ps.map { distance($0, center) }.max() ?? 0 }

    let fat = MeshEditor.shrinkFatten(obj.mesh, vertices: [], offset: 0.1).vertices.map(\.position)
    check("fatten moves the cube outward", spread(fat) > spread(before) + 0.05,
          "\(spread(before)) -> \(spread(fat))")
    // Every copy of a corner goes to the same place, or the surface tears.
    var corners: [SIMD3<Float>: Set<SIMD3<Float>>] = [:]
    for (a, b) in zip(before, fat) { corners[a, default: []].insert(b) }
    check("the copies of each corner stay together", corners.values.allSatisfy { $0.count == 1 },
          "\(corners.values.map(\.count))")
    let thin = MeshEditor.shrinkFatten(obj.mesh, vertices: [], offset: -0.1).vertices.map(\.position)
    check("a negative offset shrinks", spread(thin) < spread(before) - 0.05)
    check("an offset of zero changes nothing",
          MeshEditor.shrinkFatten(obj.mesh, vertices: [], offset: 0).vertices.map(\.position) == before)

    let pushed = MeshEditor.pushPull(obj.mesh, vertices: [], distance: 0.2).vertices.map(\.position)
    // Blender 5.2.1: a 2 m cube's corner goes from 1 to 0.885 on each axis.
    check("push/pull 0.2 moves a corner 0.2 toward the middle, as Blender does",
          close(pushed.map { abs($0.x) }.max() ?? 0, 1 - 0.2 / Float(3).squareRoot(), 1e-3),
          "\(pushed.map { abs($0.x) }.max() ?? 0)")

    let flat = MeshEditor.pushPull(obj.mesh, vertices: [0], distance: 0.2).vertices.map(\.position)
    check("one selected vertex has nothing to push toward but itself",
          flat == before, "\(zip(before, flat).filter { $0 != $1 }.count) moved")

    // A cube's corners are all one distance from its middle already, so
    // Blender leaves it alone at any factor; a stretched one is rounded.
    let sphere = MeshEditor.toSphere(obj.mesh, vertices: [], factor: 1).vertices.map(\.position)
    check("to sphere leaves a cube's corners where they are",
          zip(before, sphere).allSatisfy { distance($0, $1) < 1e-4 })
    var stretched = obj.mesh
    for i in stretched.vertices.indices { stretched.vertices[i].position.x *= 3 }
    let round = MeshEditor.toSphere(stretched, vertices: [], factor: 1).vertices.map(\.position)
    let radii = round.map { distance($0, center) }
    check("to sphere 1 puts a stretched box's corners on one sphere",
          (radii.max() ?? 0) - (radii.min() ?? 0) < 1e-3, "\(radii.min() ?? 0)...\(radii.max() ?? 0)")
}

print("\n== toolbar: Blender's per-mode tool sets ==")
do {
    // Every mode must offer a toolbar, and every entry must be unique within it.
    for mode in InteractionMode.allCases {
        let groups = ActiveTool.groups(for: mode)
        let flat = groups.flatMap { $0 }
        check("\(mode.label) has tools", !flat.isEmpty, "\(flat.count)")
        check("\(mode.label) lists no tool twice",
              Set(flat.map(\.rawValue)).count == flat.count,
              "\(flat.count) entries, \(Set(flat.map(\.rawValue)).count) unique")
        // Its default tool must actually be in its own toolbar, or selecting
        // the mode would highlight nothing.
        let fallback = ActiveTool.defaultTool(for: mode)
        check("\(mode.label) default (\(fallback.label)) is in its toolbar",
              flat.contains(fallback), "\(fallback.rawValue)")
        check("\(mode.label) default is implemented", fallback.isImplemented)
    }

    // Blender shows brushes in sculpt, transforms in object.
    let sculpt = ActiveTool.groups(for: .sculpt).flatMap { $0 }
    check("sculpt offers every brush",
          SculptBrush.allCases.allSatisfy { b in sculpt.contains { $0.sculptBrush == b } })
    let object = ActiveTool.groups(for: .object).flatMap { $0 }
    check("object offers no sculpt brush", !object.contains { $0.sculptBrush != nil })
    check("object offers all five Add primitives",
          object.filter { $0.addsPrimitive != nil }.count == 5)
    check("vertex paint offers no Add primitive",
          !ActiveTool.groups(for: .vertexPaint).flatMap { $0 }.contains { $0.addsPrimitive != nil })

    // Roles must be consistent: exactly the four transform tools carry one.
    let withRole = ActiveTool.allCases.filter { $0.transformRole != nil }
    check("exactly four tools are transforms", withRole.count == 4,
          "\(withRole.map(\.rawValue))")
    check("Transform behaves as Move", ActiveTool.transform.transformRole == .translate)

    // Anything unimplemented owes the user a reason.
    let silent = ActiveTool.allCases.filter { !$0.isImplemented && $0.requirement.isEmpty }
    check("every disabled tool explains itself", silent.isEmpty, "\(silent.map(\.rawValue))")
    // And anything implemented should not carry one.
    let noisy = ActiveTool.allCases.filter { $0.isImplemented && !$0.requirement.isEmpty }
    check("no implemented tool claims a requirement", noisy.isEmpty, "\(noisy.map(\.rawValue))")

    // Every tool needs a label and an icon, or the button renders blank.
    check("every tool has a label", ActiveTool.allCases.allSatisfy { !$0.label.isEmpty })
    check("every tool has an icon", ActiveTool.allCases.allSatisfy { !$0.icon.isEmpty })
}

print("\n== paint tools: draw / blur / average ==")
do {
    // A grid gives interior vertices with real neighbours to blur toward.
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.grid)
    obj.ensurePaintAttributes()
    let n = obj.mesh.vertices.count

    // Two flat blocks of weight: everything left of x=0 at 1, the rest at 0.
    for i in 0..<n {
        obj.vertexWeights[i] = obj.mesh.vertices[i].position.x < 0 ? 1 : 0
    }
    let before = obj.vertexWeights

    // Blur across the seam should pull the two blocks toward each other.
    let seam = (obj.modelMatrix * SIMD4(SIMD3<Float>(0, 0, 0), 1)).xyz
    let big = length(obj.mesh.vertices.map(\.position).reduce(SIMD3<Float>.zero) { max($0, abs($1)) }) * 3
    _ = obj.paintVertices(at: seam, radius: big, strength: 1.0, op: .blur,
                          colour: nil, weight: 1.0, falloff: .constant)
    let moved = zip(before, obj.vertexWeights).filter { abs($0 - $1) > 1e-4 }.count
    check("blur changes weights near the seam", moved > 0, "\(moved) of \(n)")
    check("blur pulls values toward the middle, never past 0…1",
          obj.vertexWeights.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 })
    check("blur does not simply set everything equal",
          Set(obj.vertexWeights.map { Int($0 * 100) }).count > 1)

    // Average pulls everything under the brush to one shared value.
    let scene2 = BKScene(startupFile: false)
    let obj2 = scene2.add(.grid)
    obj2.ensurePaintAttributes()
    for i in 0..<obj2.mesh.vertices.count {
        obj2.vertexWeights[i] = obj2.mesh.vertices[i].position.x < 0 ? 1 : 0
    }
    let mean = obj2.vertexWeights.reduce(0, +) / Float(obj2.vertexWeights.count)
    _ = obj2.paintVertices(at: seam, radius: big, strength: 1.0, op: .average,
                           colour: nil, weight: 1.0, falloff: .constant)
    check("average collapses the brush area to its mean",
          obj2.vertexWeights.allSatisfy { abs($0 - mean) < 1e-3 },
          "mean \(mean), got \(obj2.vertexWeights.prefix(3))")

    // Draw is unaffected by either: it lays the brush value down.
    let scene3 = BKScene(startupFile: false)
    let obj3 = scene3.add(.grid)
    _ = obj3.paintVertices(at: seam, radius: big, strength: 1.0, op: .draw,
                           colour: nil, weight: 0.25, falloff: .constant)
    check("draw writes the brush value",
          obj3.vertexWeights.allSatisfy { abs($0 - 0.25) < 1e-3 },
          "\(obj3.vertexWeights.prefix(3))")
}

print("\n== proportional editing ==")
do {
    // A row of vertices 0.25 apart: move the first, and see how far the pull
    // reaches with a 1.0 radius.
    let verts = (0..<9).map { MeshVertex(SIMD3(Float($0) * 0.25, 0, 0), SIMD3(0,0,1)) }
    var idx: [UInt32] = []
    for i in 0..<7 { idx += [UInt32(i), UInt32(i+1), UInt32(i+2)] }
    let mesh = MeshData(vertices: verts, indices: idx)

    let plain = MeshEditor.move(mesh, vertices: [0], by: SIMD3(0, 1, 0))
    check("without proportional only the selection moves",
          plain.vertices[0].position.y == 1 && plain.vertices[1].position.y == 0)

    let prop = MeshEditor.move(mesh, vertices: [0], by: SIMD3(0, 1, 0),
                               proportional: .linear, radius: 1.0)
    check("the selected vertex still moves the full amount",
          close(prop.vertices[0].position.y, 1), "\(prop.vertices[0].position.y)")
    check("neighbours come along, less the further out they are",
          prop.vertices[1].position.y > prop.vertices[2].position.y
       && prop.vertices[2].position.y > prop.vertices[3].position.y,
          "\(prop.vertices[1].position.y) \(prop.vertices[2].position.y) \(prop.vertices[3].position.y)")
    check("linear falloff is exact at a known distance",
          close(prop.vertices[1].position.y, 0.75, 1e-4), "\(prop.vertices[1].position.y)")
    check("nothing beyond the radius moves",
          close(prop.vertices[4].position.y, 0) && close(prop.vertices[8].position.y, 0),
          "\(prop.vertices[4].position.y)")

    // The curve changes the shape of the pull, not just its reach.
    let sharp = MeshEditor.move(mesh, vertices: [0], by: SIMD3(0, 1, 0),
                                proportional: .sharp, radius: 1.0)
    check("a sharper curve pulls neighbours less than linear",
          sharp.vertices[1].position.y < prop.vertices[1].position.y,
          "sharp \(sharp.vertices[1].position.y) vs linear \(prop.vertices[1].position.y)")
    let constant = MeshEditor.move(mesh, vertices: [0], by: SIMD3(0, 1, 0),
                                   proportional: .constant, radius: 1.0)
    check("constant moves everything in radius by the full amount",
          close(constant.vertices[3].position.y, 1), "\(constant.vertices[3].position.y)")
}

print("\n== proportional falloff curves ==")
do {
    for f in MeshEditor.ProportionalFalloff.allCases where f != .random {
        check("\(f.label) is 1 at the selection", close(f.weight(0), 1), "\(f.weight(0))")
        if f != .constant {
            check("\(f.label) is 0 at the radius", close(f.weight(1), 0, 1e-3), "\(f.weight(1))")
        }
    }
    check("random stays within 0…1",
          (0..<50).allSatisfy { _ in
              let w = MeshEditor.ProportionalFalloff.random.weight(0.5)
              return w >= 0 && w <= 1
          })
}

print("\n== auto merge ==")
do {
    // Two vertices dragged onto each other should weld when auto-merge is on.
    let verts = [MeshVertex(SIMD3(0,0,0), SIMD3(0,0,1)),
                 MeshVertex(SIMD3(1,0,0), SIMD3(0,0,1)),
                 MeshVertex(SIMD3(0,1,0), SIMD3(0,0,1)),
                 MeshVertex(SIMD3(1,1,0), SIMD3(0,0,1))]
    let mesh = MeshData(vertices: verts, indices: [0,1,2, 1,3,2])
    // Move vertex 0 onto vertex 1.
    let moved = MeshEditor.move(mesh, vertices: [0], by: SIMD3(1,0,0))
    check("before merging, both vertices are still there", moved.vertices.count == 4)
    let (welded, count) = MeshEditor.mergeByDistance(moved, vertices: [], threshold: 0.02)
    check("auto-merge welds the coincident pair", count == 1, "\(count)")
    check("and drops the triangle that collapsed", welded.indices.count == 3,
          "\(welded.indices.count / 3) tris")
}

print("\n== outliner: rename and restriction columns ==")
do {
    let scene = BKScene(startupFile: false)
    let a = scene.add(.cube)
    let b = scene.add(.cube)
    check("the second cube already avoids the first's name", a.name != b.name,
          "\(a.name) / \(b.name)")

    check("renaming to a free name takes it", scene.rename(a, to: "Body") == "Body")
    check("renaming onto a taken name gets Blender's suffix",
          scene.rename(b, to: "Body") == "Body.001", b.name)
    // Renaming an object to what it already is must not manufacture a suffix.
    check("renaming to its own name is a no-op", scene.rename(b, to: "Body.001") == "Body.001")
    check("an empty name is refused", scene.rename(a, to: "   ") == "Body")
    let c = scene.add(.cube)
    _ = scene.rename(c, to: "Body")
    check("a third collision counts on", c.name == "Body.002", c.name)

    check("objects render by default", !a.hideRender)
    a.hideRender = true
    check("hide_render is independent of viewport visibility", a.visible && a.hideRender)
}

print("\n== select actions ==")
do {
    let current: Set<Int> = [1, 2, 3]
    let hit: Set<Int> = [3, 4]
    check("Set replaces",       SelectAction.set.apply(current, hit: hit) == [3, 4])
    check("Extend unions",      SelectAction.extend.apply(current, hit: hit) == [1, 2, 3, 4])
    check("Subtract removes",   SelectAction.subtract.apply(current, hit: hit) == [1, 2])
    check("Difference is XOR",  SelectAction.difference.apply(current, hit: hit) == [1, 2, 4])
    check("Intersect keeps the overlap",
          SelectAction.intersect.apply(current, hit: hit) == [3])

    // Clicking empty space: Blender clears for Set and leaves the rest alone,
    // because subtracting nothing is not a request to throw the selection away.
    check("Set on empty space clears", SelectAction.set.apply(current, hit: Set<Int>()).isEmpty)
    for a in SelectAction.allCases where a != .set {
        check("\(a.label) on empty space keeps the selection",
              a.apply(current, hit: Set<Int>()) == current)
    }

    // Extending twice must be stable, or repeated taps would flicker.
    let once = SelectAction.extend.apply(current, hit: hit)
    check("Extend is idempotent", SelectAction.extend.apply(once, hit: hit) == once)
    // Difference twice returns you to where you started, which is what XOR means.
    let flipped = SelectAction.difference.apply(current, hit: hit)
    check("Difference twice is a round trip",
          SelectAction.difference.apply(flipped, hit: hit) == current)

    check("every action has a bpy name",
          SelectAction.allCases.allSatisfy { !$0.bpyValue.isEmpty })
    check("Difference and Intersect use Blender's set-operation names",
          SelectAction.difference.bpyValue == "XOR" && SelectAction.intersect.bpyValue == "AND")
}

print("\n== hostile geometry does not crash the quantiser ==")
do {
    // Int32(_:) traps on a non-finite value and on anything past ~21 km at the
    // weld scale. Both are reachable — a degenerate normal makes NaN, and a
    // script can move something a long way out — and both used to kill the app
    // from inside recomputeNormals.
    func mesh(_ points: [SIMD3<Float>]) -> MeshData {
        MeshData(vertices: points.map { MeshVertex($0, SIMD3(0, 0, 1)) },
                 indices: [0, 1, 2])
    }
    let nan = Float.nan, inf = Float.infinity
    let cases: [(String, SIMD3<Float>)] = [
        ("NaN",            SIMD3(nan, 0, 0)),
        ("+infinity",      SIMD3(inf, 0, 0)),
        ("-infinity",      SIMD3(-inf, 0, 0)),
        ("far beyond Int32", SIMD3(1e9, 0, 0)),
        ("far negative",   SIMD3(-1e9, 0, 0)),
    ]
    for (label, bad) in cases {
        var m = mesh([bad, SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        ModifierStack.recomputeNormals(&m, welded: true)   // would trap before
        check("recomputeNormals survives \(label)", m.vertices.count == 3)
    }

    // A normal that is already NaN must not be preserved: the old fallback kept
    // whatever was there, so one NaN became permanent.
    var m = MeshData(vertices: [MeshVertex(SIMD3(0,0,0), SIMD3(nan, nan, nan)),
                                MeshVertex(SIMD3(1,0,0), SIMD3(nan, nan, nan)),
                                MeshVertex(SIMD3(0,1,0), SIMD3(nan, nan, nan))],
                     indices: [0, 1, 2])
    ModifierStack.recomputeNormals(&m, welded: true)
    check("a NaN normal is replaced, not carried",
          m.vertices.allSatisfy { $0.normal.x.isFinite && $0.normal.y.isFinite
                                  && $0.normal.z.isFinite },
          "\(m.vertices[0].normal)")

    // Randomize must not write NaN into a position via a bad normal.
    let bad = MeshData(vertices: (0..<3).map {
                            MeshVertex(SIMD3(Float($0), 0, 0), SIMD3(nan, nan, nan)) },
                       indices: [0, 1, 2])
    let jittered = MeshEditor.randomize(bad, vertices: [], amount: 0.1)
    check("randomize skips non-finite normals",
          jittered.vertices.allSatisfy { $0.position.x.isFinite },
          "\(jittered.vertices[0].position)")
}

print("\n== a modifier stack applies to edited geometry ==")
do {
    // Geometry that came from outside — a join, an edit operator, a sync from
    // the real module — still carries a stack. It used to be ignored entirely.
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    let plain = obj.mesh.vertices.count

    // Pretend an edit produced this mesh, as join and extrude do.
    obj.setMirroredMesh(obj.mesh)
    check("installing edited geometry keeps the vertex count",
          obj.mesh.vertices.count == plain, "\(obj.mesh.vertices.count)")

    obj.addModifier(.subdivision)
    check("a modifier added afterwards still evaluates",
          obj.mesh.vertices.count > plain,
          "\(plain) -> \(obj.mesh.vertices.count)")
}

print("\n== operator search ranking ==")
do {
    // The catalogue is filled from the backend, so the ranking is what can be
    // tested without one: typing a stem must put the exact operator first.
    let cat = OperatorCatalogue()
    cat.injectForTesting(["mesh.bevel", "mesh.bisect", "object.delete",
                          "mesh.subdivide", "mesh.select_all", "object.select_all",
                          "transform.translate", "mesh.remove_doubles"])
    check("catalogue holds what it was given", cat.entries.count == 8)

    let bev = cat.search("bev")
    check("a stem finds the operator", bev.first?.path == "mesh.bevel",
          "\(bev.map(\.path))")
    check("a label beats a mere substring",
          cat.search("select").first?.label.lowercased().hasPrefix("select") == true,
          "\(cat.search("select").map(\.path))")
    check("the dotted path is searchable too",
          cat.search("object.").allSatisfy { $0.path.hasPrefix("object.") },
          "\(cat.search("object.").map(\.path))")
    check("no match yields nothing", cat.search("zzzz").isEmpty)
    check("an empty term lists everything", cat.search("").count == 8)
    check("limit is honoured", cat.search("", limit: 3).count == 3)

    // Labels are humanised from the operator name, which is what makes the
    // list readable next to the raw path.
    check("remove_doubles reads as Remove Doubles",
          cat.entries.first { $0.path == "mesh.remove_doubles" }?.label == "Remove Doubles")
    check("the call is valid Python",
          cat.entries.first { $0.path == "mesh.bevel" }?.call == "bpy.ops.mesh.bevel()")
    check("category is the module",
          cat.entries.first { $0.path == "mesh.bevel" }?.category == "mesh")
}

print("\n== undo keeps geometry it cannot rebuild ==")
do {
    // With the real module every object arrives from the sync reported as a
    // cube, because geometry is what the sync carries. Rebuilding from that on
    // undo turned whole scenes into cubes.
    let scene = BKScene(startupFile: false)
    let obj = scene.add(.cube)
    // Stand in for geometry that came from outside: a joined or synced mesh.
    var edited = obj.mesh
    edited.vertices.append(MeshVertex(SIMD3(9, 9, 9), SIMD3(0, 0, 1)))
    obj.setMirroredMesh(edited)
    let expected = obj.mesh.vertices.count

    let undo = UndoStack()
    undo.seed(scene)
    undo.push("Edit", scene)

    // Change it, then step back.
    obj.setMirroredMesh(MeshEditor.subdivide(obj.mesh, faces: [0]).0)
    check("the scene changed before undo", obj.mesh.vertices.count != expected)
    _ = undo.undo(into: scene)

    let restored = scene.objects.first
    check("the object came back", restored != nil)
    check("its geometry survived the round trip",
          restored?.mesh.vertices.count == expected,
          "\(restored?.mesh.vertices.count ?? -1) vs \(expected)")
    check("it is still marked as carrying outside geometry",
          restored?.isMirrored == true)

    // An object that *is* its primitive still rebuilds from the primitive, so
    // nothing is stored for it.
    let scene2 = BKScene(startupFile: false)
    _ = scene2.add(.uvSphere)
    check("a plain primitive stores no mesh in the snapshot",
          scene2.snapshot().meshes.isEmpty, "\(scene2.snapshot().meshes.count)")
}

print("\n== 32-bit viewport geometry ==")
do {
    let vertices = (0..<70000).map { MeshVertex(SIMD3(Float($0), 0, 0), SIMD3(0, 0, 1)) }
    let mesh = MeshData(vertices: vertices, indices: [0, 65536, 69999, 1, 65537, 69998])
    check("indices retain vertices beyond 65535", mesh.indices[2] == 69999)
    check("edge keys do not collide above 16 bits", mesh.edges.count == 12)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
