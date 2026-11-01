import Foundation
import simd

// The normals the 3D View shades a mesh with, the Swift half: what
// `sync_shading` installs (`SceneMirror.installShading`), the normal each
// triangle corner is drawn with (`MeshData.shadingNormal`), the fast path's
// unchanged meshes, a frame change's way onto the screen (`carryShading`), and
// a drag's preview turning a flat face's normal with the face
// (`MeshData.carryShading`). What Blender's own sync sends through it is
// scripts/run-shading-blender-check.sh.
//
//     scripts/run-shading-tests.sh

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "\n        " + detail()))
    if !ok { failures += 1 }
}

/// One `sync_push`, as the entry point hands it over: the vertex normals all
/// (0, 0, 1), as a smooth plane's are.
func push(_ name: String, _ vertices: [SIMD3<Float>], triangles: [UInt32],
          previous: BKObject? = nil) -> (object: BKObject, unchanged: Bool)? {
    var matrix = [Double](repeating: 0, count: 16)
    matrix[0] = 1; matrix[5] = 1; matrix[10] = 1; matrix[15] = 1
    let positions: [Float] = vertices.flatMap { [$0.x, $0.y, $0.z] }
    let normals: [Float] = vertices.flatMap { _ in [Float(0), 0, 1] }
    return matrix.withUnsafeBufferPointer { m in
        positions.withUnsafeBufferPointer { p in
            normals.withUnsafeBufferPointer { n in
                triangles.withUnsafeBufferPointer { t in
                    SceneMirror.object(named: name, kind: "MESH", matrix: m, positions: p, normals: n,
                                       triangles: t, colour: nil, previous: previous)
                }
            }
        }
    }
}

/// One `sync_shading`, as the entry point hands it over.
func shade(_ domain: UInt32, loops: [UInt32], normals: [Float], on obj: BKObject) -> Bool? {
    loops.withUnsafeBufferPointer { l in
        normals.withUnsafeBufferPointer { n in
            SceneMirror.installShading(domain: domain, triangleLoops: l, loopNormals: n, on: obj)
        }
    }
}

/// The angle between two directions, by atan2 in doubles: acos of a Float
/// dot product cannot tell 0° from 0.028° (1 - 1.2e-7).
func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let x = SIMD3<Double>(a), y = SIMD3<Double>(b)
    return Float(atan2(simd_length(simd_cross(x, y)), simd_dot(x, y)) * 180 / .pi)
}

// Two faces of a cube's corner, as Blender's loop triangles split them: the
// top (z = 1, loops 0-3) and the front (y = -1, loops 4-7), sharing the edge
// from (-1, -1, 1) to (1, -1, 1). Six vertices, four triangles.
let corner: [SIMD3<Float>] = [SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1),
                              SIMD3(-1, -1, -1), SIMD3(1, -1, -1)]
let tris: [UInt32] = [0, 1, 2, 0, 2, 3, 4, 5, 1, 4, 1, 0]
let loops: [UInt32] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
// Blender's corner normals for a flat (FACE) mesh: each loop its face's.
let up: [Float] = [0, 0, 1], front: [Float] = [0, -1, 0]
let flatLoops: [Float] = Array([[Float]](repeating: up, count: 4).joined()) + Array([[Float]](repeating: front, count: 4).joined())

print("\n== a flat mesh is shaded by its faces' normals, as Blender's Solid view shades it ==")
do {
    let made = push("Corner", corner, triangles: tris)!.object
    check("until Blender's are sent, by the vertex normals", !made.mesh.shadingFits
          && made.mesh.shadingNormal(corner: 6) == SIMD3(0, 0, 1))
    let version = made.meshVersion
    check("FACE is installed", shade(1, loops: loops, normals: flatLoops, on: made) == true)
    check("  one normal per triangle, a third of the corners'",
          made.mesh.shadingDomain == .triangle && made.mesh.shadingNormals.count == 3 * 4 && made.mesh.shadingFits)
    check("  each corner of the front face is drawn by the front's normal, not the vertex's (0, 0, 1)",
          (6..<12).allSatisfy { made.mesh.shadingNormal(corner: $0) == SIMD3(0, -1, 0) }
          && (0..<6).allSatisfy { made.mesh.shadingNormal(corner: $0) == SIMD3(0, 0, 1) })
    check("  as Blender's evaluated mesh, a new version for the renderer",
          made.meshIsEvaluated && made.meshVersion != version)
    check("the same normals again install nothing", shade(1, loops: loops, normals: flatLoops, on: made) == false)

    // A custom normal on one corner: CORNER keeps every corner's.
    var custom = flatLoops
    custom[3 * 5] = 0.6; custom[3 * 5 + 1] = -0.8; custom[3 * 5 + 2] = 0
    check("CORNER is installed", shade(2, loops: loops, normals: custom, on: made) == true)
    check("  one normal per corner", made.mesh.shadingDomain == .corner && made.mesh.shadingNormals.count == 36)
    // Loop 5 is corner 7 (triangle 2's second corner), the vertex (1, -1, -1).
    check("  the corner of loop 5 is drawn by loop 5's normal, the others by their faces'",
          made.mesh.shadingNormal(corner: 7) == SIMD3(0.6, -0.8, 0)
          && made.mesh.shadingNormal(corner: 6) == SIMD3(0, -1, 0)
          && made.mesh.shadingNormal(corner: 0) == SIMD3(0, 0, 1))
    check("POINT clears them: Shade Smooth draws by the vertex normals again",
          shade(0, loops: [], normals: [], on: made) == true && !made.mesh.shadingFits
          && made.mesh.shadingNormal(corner: 7) == SIMD3(0, 0, 1))
    check("  and POINT again changes nothing", shade(0, loops: [], normals: [], on: made) == false)

    print("\n  malformed: nil, and the mesh as it was")
    _ = shade(1, loops: loops, normals: flatLoops, on: made)
    let before = made.mesh.shadingNormals
    check("a loop past Blender's loops", shade(1, loops: loops.map { $0 == 7 ? 8 : $0 }, normals: flatLoops, on: made) == nil)
    check("loops that are not one per triangle corner", shade(1, loops: Array(loops.dropLast(3)), normals: flatLoops, on: made) == nil)
    check("normals that are not three floats each", shade(2, loops: loops, normals: Array(flatLoops.dropLast()), on: made) == nil)
    check("POINT with buffers", shade(0, loops: loops, normals: flatLoops, on: made) == nil)
    check("a domain Blender has not got", shade(3, loops: loops, normals: flatLoops, on: made) == nil)
    check("  none of them changed what is drawn", made.mesh.shadingNormals == before)
    var nan = flatLoops
    nan[0] = .nan
    check("a normal that is not a number draws the mesh by its vertex normals",
          shade(2, loops: loops, normals: nan, on: made) == true && !made.mesh.shadingFits)
}

print("\n== the fast path: the same geometry, other normals ==")
do {
    let first = push("Corner", corner, triangles: tris)!.object
    _ = shade(1, loops: loops, normals: flatLoops, on: first)
    let again = push("Corner", corner, triangles: tris, previous: first)!
    check("Shade Smooth moves no vertex: the geometry comes back unchanged", again.unchanged)
    check("  and keeps the face normals the last pass installed", again.object.mesh.shadingDomain == .triangle)
    var changed = false
    let carried = SceneMirror.carryShading(domain: 0, triangleLoops: UnsafeBufferPointer(start: nil, count: 0),
                                           loopNormals: UnsafeBufferPointer(start: nil, count: 0), named: "Corner",
                                           pass: [again.object], screen: [], changed: &changed)
    check("POINT on it is a change, which takes it out of the pass's unchanged set (bk_sync_shading)",
          carried == 1 && changed && !again.object.mesh.shadingFits)
    let scene = BKScene(startupFile: false)
    scene.objects = [first]
    let version = first.meshVersion
    // What the entry point does: `unchanged` no longer names it.
    SceneMirror.merge([again.object], into: scene, unchanged: [], selection: [], active: nil)
    check("  so the merge puts the new normals on the object on screen",
          scene.objects[0] === first && !first.mesh.shadingFits && first.meshVersion != version)
    // Negative control: left in `unchanged`, the screen keeps the face normals.
    let stale = push("Corner", corner, triangles: tris)!.object
    _ = shade(1, loops: loops, normals: flatLoops, on: stale)
    let fresh = push("Corner", corner, triangles: tris, previous: stale)!.object
    _ = shade(0, loops: [], normals: [], on: fresh)
    let screen = BKScene(startupFile: false)
    screen.objects = [stale]
    SceneMirror.merge([fresh], into: screen, unchanged: ["Corner"], selection: [], active: nil)
    check("  (negative control: kept as unchanged, the screen would still draw the faces' normals)",
          stale.mesh.shadingFits)
}

print("\n== outside a pass: a frame change, a sculpt stroke's chunk ==")
do {
    let onScreen = push("Corner", corner, triangles: tris)!.object
    var changed = false
    let taken = loops.withUnsafeBufferPointer { l in
        flatLoops.withUnsafeBufferPointer { n in
            SceneMirror.carryShading(domain: 1, triangleLoops: l, loopNormals: n, named: "Corner",
                                     pass: nil, screen: [onScreen], changed: &changed)
        }
    }
    check("onto the object on screen of that name", taken == 1 && changed && onScreen.mesh.shadingFits)
    let unknown = loops.withUnsafeBufferPointer { l in
        flatLoops.withUnsafeBufferPointer { n in
            SceneMirror.carryShading(domain: 1, triangleLoops: l, loopNormals: n, named: "Nothing",
                                     pass: nil, screen: [onScreen], changed: &changed)
        }
    }
    check("an object the screen does not hold is not an error then (0, as sync_local's)", unknown == 0)
    let inPass = loops.withUnsafeBufferPointer { l in
        flatLoops.withUnsafeBufferPointer { n in
            SceneMirror.carryShading(domain: 1, triangleLoops: l, loopNormals: n, named: "Nothing",
                                     pass: [onScreen], screen: [], changed: &changed)
        }
    }
    check("  but during a pass it is (-1)", inPass == -1)
}

print("\n== a drag's preview turns a flat face's normal with the face ==")
do {
    let made = push("Corner", corner, triangles: tris)!.object
    _ = shade(1, loops: loops, normals: flatLoops, on: made)
    let old = made.mesh
    // The front face's bottom edge pulled out along -y by 1: the face tilts.
    var moved = old
    moved.vertices[4].position = SIMD3(-1, -2, -1)
    moved.vertices[5].position = SIMD3(1, -2, -1)
    let tilted = simd_normalize(simd_cross(moved.vertices[5].position - moved.vertices[4].position,
                                           moved.vertices[1].position - moved.vertices[4].position))
    var carried = moved
    carried.carryShading(from: old)
    let worst = (6..<12).map { degrees(carried.shadingNormal(corner: $0), tilted) }.max() ?? 180
    check("the tilted face is drawn by its new normal (worst \(String(format: "%.5f", worst))°)", worst < 1e-3)
    check("  the top, which did not move, keeps its own",
          (0..<6).allSatisfy { degrees(carried.shadingNormal(corner: $0), SIMD3(0, 0, 1)) < 1e-4 })
    let stale = (6..<12).map { degrees(moved.shadingNormal(corner: $0), tilted) }.max() ?? 0
    check("  (negative control: not carried, it would be \(String(format: "%.1f", stale))° off)", stale > 20)
    // A custom normal keeps its angle to its face.
    _ = shade(2, loops: loops, normals: flatLoops.enumerated().map { $0.offset / 3 == 5 ? [Float(0.6), -0.8, 0][$0.offset % 3] : $0.element }, on: made)
    let customOld = made.mesh
    var customMoved = customOld
    customMoved.vertices[4].position = SIMD3(-1, -2, -1)
    customMoved.vertices[5].position = SIMD3(1, -2, -1)
    customMoved.carryShading(from: customOld)
    let before = degrees(customOld.shadingNormal(corner: 7), SIMD3(0, -1, 0))
    let after = degrees(customMoved.shadingNormal(corner: 7), tilted)
    check("a custom normal keeps its angle to its face (\(String(format: "%.3f", before))° then \(String(format: "%.3f", after))°)",
          abs(before - after) < 1e-3)
    var welded = moved
    welded.indices = Array(welded.indices.dropLast(3))
    welded.carryShading(from: old)
    check("another topology (a weld) is left alone, and then drawn by its vertex normals",
          !welded.shadingFits && welded.shadingNormal(corner: 0) == welded.vertices[0].normal)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
