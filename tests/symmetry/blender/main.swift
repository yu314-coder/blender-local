import Foundation
import simd
import CoreGraphics

// Mirror editing, previewed by the Swift the device runs and printed for a
// headless Blender to commit: each drag goes through the real gizmo session
// (make, begin, resolve, snap, preview) on Blender's own meshes, with the
// mesh's symmetry as the mirror would install it. What is printed is the
// Python the release sends, where the preview left every vertex, and where
// the same drag would have left them with the symmetry off — so verify.py can
// hold Blender's result against the first and show it differs from the second.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func numbers(_ values: [Float]) -> String {
    values.map { String(format: "%.6f", $0) }.joined(separator: " ")
}
func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

let meshes = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
func floats(_ any: Any?) -> [Float] { (any as! [NSNumber]).map(\.floatValue) }
func ints(_ any: Any?) -> [UInt32] { (any as! [NSNumber]).map { UInt32($0.intValue) } }

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

// MARK: - the flags, as the mirror carries them

do {
    let kinds = meshes["kinds"] as! [String: String]
    var parsed: [String: String] = [:]
    for (key, kind) in kinds {
        let s = SceneMirror.symmetry(kind.components(separatedBy: "|"))
        parsed[key] = s.label.lowercased() + (s.topology ? "t" : "")
    }
    emit("KINDS_PARSED", json(parsed))
}

// MARK: - what the toggles send

var toggles: [String: String] = [:]
for fixture in ["grid", "cube", "monkey", "skewed", "twisted"] {
    for flag in SymmetryBpy.Flag.allCases {
        for on in [true, false] {
            toggles["\(fixture):\(flag.property)=\(on)"] = SymmetryBpy.set(flag, on, objectNamed: fixture)
        }
    }
}
emit("TOGGLES", json(toggles))

// MARK: - what the Mesh menu's transforms send

var menuCases: [String] = []
for op in [LastOperator.Mesh.shrinkFatten, .pushPull, .toSphere, .slideVertices, .edgeSlide, .smooth, .inset] {
    for on in [true, false] {
        let made = LastOperator.mesh(op, spinningAround: nil, symmetry: MeshSymmetry(x: on))
        let name = "MENU_\(op.rawValue)_\(on ? "ON" : "OFF")"
        menuCases.append(name)
        emit(name, made.executedPython)
        emit(name + "_SETUP", json(["op": op.rawValue, "honours": op.honoursMeshSymmetry, "symmetry": on,
                                    "column": op == .edgeSlide]))
    }
}
emit("MENU_CASES", menuCases.joined(separator: " "))

// MARK: - drags

/// The fixture as the mirror would install it, in edit mode, with Blender's
/// selection report for `selected` and `hidden` — the device's own path to
/// editTopology and Blender's edges.
///
/// `coordinates` false leaves Blender's own coordinates out of the report,
/// which is what the app did before `_edit_coordinates`: for a fixture under
/// a modifier, the mirror pairs on the drawn positions then.
func editScene(_ fixture: String, selected: Set<Int>, hidden: Set<Int> = [],
               symmetry: MeshSymmetry, coordinates: Bool = true) -> (BKScene, BKObject) {
    let d = meshes[fixture] as! [String: Any]
    let co = floats(d["co"])
    let m = floats(d["matrix"])
    let edges = ints(d["edges"])
    let vertices = stride(from: 0, to: co.count, by: 3).map {
        MeshVertex(SIMD3(co[$0], co[$0 + 1], co[$0 + 2]), SIMD3(0, 0, 1))
    }
    // Hidden faces do not reach the viewport while editing.
    let allTris = ints(d["tris"])
    let allPolys = ints(d["tri_poly"])
    var tris: [UInt32] = [], polys: [UInt32] = []
    for t in 0..<allPolys.count {
        let corners = allTris[(3 * t)..<(3 * t + 3)]
        if corners.contains(where: { hidden.contains(Int($0)) }) { continue }
        tris += corners
        polys.append(allPolys[t])
    }
    var mesh = MeshData(vertices: vertices, indices: tris)
    ModifierStack.recomputeNormals(&mesh, welded: true)
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.name = fixture
    o.setEvaluatedMesh(mesh)
    o.setMirroredTransform(simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]),
                                                    SIMD4(m[4], m[5], m[6], m[7]),
                                                    SIMD4(m[8], m[9], m[10], m[11]),
                                                    SIMD4(m[12], m[13], m[14], m[15]))))
    o.symmetry = symmetry
    s.selection = [o.id]
    s.activeID = o.id
    s.setMode(.edit)
    let report = BlenderEditReport(
        selectMode: 1,
        vertexSelected: vertices.indices.map { selected.contains($0) ? 1 : 0 },
        trianglePolygons: polys,
        polygonSelected: Array(repeating: 0, count: (d["polygons"] as! NSNumber).intValue),
        edgeVertices: edges,
        edgeSelected: stride(from: 0, to: edges.count, by: 2).map {
            selected.contains(Int(edges[$0])) && selected.contains(Int(edges[$0 + 1])) ? 1 : 0
        },
        vertexHidden: hidden.isEmpty ? [] : vertices.indices.map { hidden.contains($0) ? 1 : 0 },
        vertexCoordinates: coordinates && d["blender_co"] != nil ? floats(d["blender_co"]) : [])
    let mirrored = s.mirrorEditSelection(report, on: o)
    precondition(mirrored, "the fixture \(fixture) did not mirror as Blender's mesh")
    return (s, o)
}

/// The vertices nearest each of `points`, in the mesh's own space — on the
/// edit mesh, which for a fixture under a modifier is not what is drawn.
func nearest(_ fixture: String, to points: [SIMD3<Float>]) -> Set<Int> {
    let d = meshes[fixture] as! [String: Any]
    let co = floats(d["blender_co"] ?? d["co"])
    return Set(points.map { q in
        (0..<(co.count / 3)).min { a, b in
            simd_distance(SIMD3(co[3 * a], co[3 * a + 1], co[3 * a + 2]), q)
                < simd_distance(SIMD3(co[3 * b], co[3 * b + 1], co[3 * b + 2]), q)
        }!
    })
}

func along(_ g: TransformGizmo, _ p: TransformGizmo.Projection, _ axis: Int,
           _ f: CGFloat) -> CGPoint {
    let c = p.project(g.origin)!, t = p.project(g.origin + g.axes[axis] * g.radius)!
    return CGPoint(x: c.x + (t.x - c.x) * f, y: c.y + (t.y - c.y) * f)
}
func around(_ g: TransformGizmo, _ p: TransformGizmo.Projection,
            _ degrees: CGFloat) -> (CGPoint, CGPoint) {
    let c = p.project(g.origin)!, r: CGFloat = 110, a = degrees * .pi / 180
    return (CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
}
func across(_ g: TransformGizmo, _ p: TransformGizmo.Projection,
            _ dx: CGFloat, _ dy: CGFloat) -> (CGPoint, CGPoint) {
    let c = p.project(g.origin)!
    return (CGPoint(x: c.x + 3, y: c.y + 2), CGPoint(x: c.x + 3 + dx, y: c.y + 2 + dy))
}
func outward(_ g: TransformGizmo, _ p: TransformGizmo.Projection,
             _ ratio: CGFloat) -> (CGPoint, CGPoint) {
    let c = p.project(g.origin)!
    return (CGPoint(x: c.x + 48, y: c.y - 36), CGPoint(x: c.x + 48 * ratio, y: c.y - 36 * ratio))
}

/// One drag, snapped and previewed as MetalViewportView does it; the Python
/// its release sends.
func drag(_ mode: TransformGizmo.Mode, _ handle: TransformGizmo.Handle, in scene: BKScene,
          points: (TransformGizmo, TransformGizmo.Projection) -> (CGPoint, CGPoint)) -> String {
    let g = TransformGizmo.make(mode: mode, scene: scene, options: options, camera: camera, size: size)!
    let p = TransformGizmo.Projection(camera: camera, size: size)
    let (a, b) = points(g, p)
    let session = TransformGizmo.beginSession(handle: handle, at: a, gizmo: g, scene: scene,
                                              camera: camera, size: size, options: options)
    let result = TransformGizmo.snapped(TransformGizmo.resolve(session, at: b)!, session: session, at: b)
    TransformGizmo.apply(result, session: session)
    return TransformGizmo.python(result, session: session)
}

typealias Run = (BKScene) -> String

var cases: [String] = []
/// Emits a case: its setup, its Python, the preview, and the same drag
/// previewed with the symmetry off.
/// `control` names a case where the symmetry should find nothing to do, and
/// says why: the drag moves what it would with the symmetry off, or with
/// `still`, nothing at all.
func symmetryCase(_ name: String, _ fixture: String, selected: Set<Int>, hidden: Set<Int> = [],
                  symmetry: MeshSymmetry, mirror: Modifier? = nil, control: String? = nil, still: Bool = false,
                  configure: @escaping (BKScene) -> Void = { _ in }, run: @escaping Run) {
    func scene(_ s: MeshSymmetry, coordinates: Bool = true) -> (BKScene, BKObject) {
        let (sc, o) = editScene(fixture, selected: selected, hidden: hidden, symmetry: s, coordinates: coordinates)
        if let mirror { o.modifiers = [mirror] }
        configure(sc)
        return (sc, o)
    }
    let (plain, plainObject) = scene(MeshSymmetry())
    _ = run(plain)
    let (s, o) = scene(symmetry)
    let python = run(s)
    // What the drag found, for the record: which vertices followed which.
    var setup: [String: Any] = ["fixture": fixture, "selected": selected.sorted(), "hidden": hidden.sorted(),
                                "symmetry": ["x": symmetry.x, "y": symmetry.y, "z": symmetry.z,
                                             "topology": symmetry.topology],
                                "vertices": o.mesh.vertices.count]
    if let mirror {
        setup["mirror"] = ["axes": [mirror.mirrorX, mirror.mirrorY, mirror.mirrorZ],
                           "clip": mirror.mirrorClip, "merge_threshold": mirror.mergeThreshold]
    }
    if s.tools.autoMerge { setup["automerge"] = s.tools.mergeThreshold }
    if let control { setup["control"] = control; setup["still"] = still }
    cases.append(name)
    emit(name + "_SETUP", json(setup))
    emit(name, python)
    emit(name + "_EXPECT", numbers(o.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
    emit(name + "_PLAIN", numbers(plainObject.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
    if (meshes[fixture] as! [String: Any])["blender_co"] != nil {
        // The same drag paired on the drawn positions, as before the report
        // carried Blender's: verify.py shows Blender disagrees with it.
        let (drawn, drawnObject) = scene(symmetry, coordinates: false)
        _ = run(drawn)
        emit(name + "_DRAWN_PAIRS", numbers(drawnObject.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
    }
}

let X = MeshSymmetry(x: true)
let moveZ: Run = { drag(.translate, .axis(2), in: $0) { g, p in (along(g, p, 2, 1), along(g, p, 2, 1.6)) } }
let moveX: Run = { drag(.translate, .axis(0), in: $0) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.45)) } }
let moveFree: Run = { drag(.translate, .screen, in: $0) { g, p in across(g, p, 47, -29) } }
let turn: Run = { drag(.rotate, .axis(2), in: $0) { g, p in around(g, p, 50) } }
let grow: Run = { drag(.scale, .screen, in: $0) { g, p in outward(g, p, 1.6) } }

// The grid: x and y run -1…1 in steps of 0.2.
func grid(_ points: [SIMD3<Float>]) -> Set<Int> { nearest("grid", to: points) }
symmetryCase("X_ONE", "grid", selected: grid([SIMD3(0.6, 0.4, 0)]), symmetry: X, run: moveFree)
symmetryCase("X_FAR_SIDE", "grid", selected: grid([SIMD3(-0.6, 0.4, 0)]), symmetry: X, run: moveFree)
// Both sides selected: the sum is 0, its sign +, and the -X one follows.
symmetryCase("X_BOTH_SIDES", "grid", selected: grid([SIMD3(0.6, 0.4, 0), SIMD3(-0.6, 0.4, 0)]),
             symmetry: X, run: moveFree)
// On the plane: moved along X, it stays at x = 0.
symmetryCase("X_ON_PLANE", "grid", selected: grid([SIMD3(0, 0.4, 0), SIMD3(0.4, 0.4, 0)]),
             symmetry: X, run: moveX)
symmetryCase("Y_ONE", "grid", selected: grid([SIMD3(0.4, 0.6, 0)]), symmetry: MeshSymmetry(y: true), run: moveFree)
symmetryCase("XY_ONE", "grid", selected: grid([SIMD3(0.4, 0.6, 0)]), symmetry: MeshSymmetry(x: true, y: true),
             run: moveZ)
symmetryCase("X_TURN", "grid", selected: grid([SIMD3(0.4, 0.2, 0), SIMD3(0.6, 0.4, 0)]), symmetry: X, run: turn)
symmetryCase("X_SCALE", "grid", selected: grid([SIMD3(0.4, 0.2, 0), SIMD3(0.6, 0.4, 0), SIMD3(0.8, 0.8, 0)]),
             symmetry: X, run: grow)
symmetryCase("X_PROPORTIONAL", "grid", selected: grid([SIMD3(0.4, 0.4, 0)]), symmetry: X,
             configure: { s in
                 s.tools.proportionalEdit = true
                 s.tools.falloff = .smooth
                 s.tools.size = 0.7
             }, run: moveZ)
symmetryCase("X_PROPORTIONAL_CONNECTED", "grid", selected: grid([SIMD3(0.2, 0.4, 0), SIMD3(-0.6, -0.4, 0)]),
             symmetry: X,
             configure: { s in
                 s.tools.proportionalEdit = true
                 s.tools.falloff = .linear
                 s.tools.size = 0.9
                 s.tools.connected = true
             }, run: moveZ)
// Its mirror image hidden: Blender leaves a hidden vertex out of the pairing.
symmetryCase("X_MIRROR_HIDDEN", "grid", selected: grid([SIMD3(0.6, 0.4, 0), SIMD3(0.6, -0.4, 0)]),
             hidden: grid([SIMD3(-0.6, 0.4, 0)]), symmetry: X, run: moveFree)
// A Mirror modifier clipping on X as well: clipped first, then mirrored.
var clipMirror = Modifier(kind: .mirror)
clipMirror.mirrorClip = true
symmetryCase("X_CLIPPED", "grid", selected: grid([SIMD3(0.2, 0.4, 0), SIMD3(0.4, 0.6, 0)]), symmetry: X,
             mirror: clipMirror, run: { drag(.translate, .axis(0), in: $0) { g, p in (along(g, p, 0, 1), along(g, p, 0, -0.8)) } })
// Auto Merge: a vertex dropped on the X = 0 column welds there, and so does
// the mirror image Blender moves with it.
symmetryCase("X_AUTOMERGE", "grid", selected: grid([SIMD3(0.2, 0.4, 0)]), symmetry: X,
             configure: { s in
                 s.tools.autoMerge = true
                 s.tools.mergeThreshold = 0.05
             }, run: { s in
                 let o = s.active!
                 let i = s.editSelection.vertices.first!
                 let m = o.modelMatrix
                 let here = (m * SIMD4(o.mesh.vertices[i].position, 1)).xyz
                 var target = o.mesh.vertices[i].position
                 target.x = 0.01
                 let there = (m * SIMD4(target, 1)).xyz
                 let g = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                             camera: camera, size: size)!
                 let session = TransformGizmo.beginSession(handle: .screen, at: .zero, gizmo: g, scene: s,
                                                           camera: camera, size: size, options: options)
                 TransformGizmo.apply(.translate(there - here), session: session)
                 return TransformGizmo.python(.translate(there - here), session: session)
             })

// The cube, symmetric on every axis: a corner moved with X, Y and Z on takes
// all seven of its images with it.
let corner = nearest("cube", to: [SIMD3(1, 1, 1)])
symmetryCase("XYZ_CORNER", "cube", selected: corner, symmetry: MeshSymmetry(x: true, y: true, z: true), run: moveFree)
symmetryCase("XY_TURN", "cube", selected: nearest("cube", to: [SIMD3(1, 1, 1), SIMD3(1, 0.33, 1)]),
             symmetry: MeshSymmetry(x: true, y: true), run: turn)
symmetryCase("XZ_PROPORTIONAL", "cube", selected: corner, symmetry: MeshSymmetry(x: true, z: true),
             configure: { s in
                 s.tools.proportionalEdit = true
                 s.tools.falloff = .sphere
                 s.tools.size = 1.2
             }, run: moveX)

// Suzanne, by position and by topology; and with her +X half out of place,
// where only the topology still pairs her.
let ear = nearest("monkey", to: [SIMD3(1.36, 0.5, 0.3), SIMD3(0.7, 0.4, 0.6)])
symmetryCase("MONKEY_X", "monkey", selected: ear, symmetry: X, run: moveFree)
symmetryCase("MONKEY_TOPOLOGY", "monkey", selected: ear, symmetry: MeshSymmetry(x: true, topology: true), run: moveFree)
let skewedEar = nearest("skewed", to: [SIMD3(1.38, 0.5, 0.3), SIMD3(0.72, 0.4, 0.61)])
symmetryCase("SKEWED_X", "skewed", selected: skewedEar, symmetry: X,
             control: "out of place, her +X half has no mirror image by position", run: moveFree)
symmetryCase("SKEWED_TOPOLOGY", "skewed", selected: skewedEar, symmetry: MeshSymmetry(x: true, topology: true),
             run: moveFree)
symmetryCase("SKEWED_TOPOLOGY_PROPORTIONAL", "skewed", selected: skewedEar,
             symmetry: MeshSymmetry(x: true, topology: true),
             configure: { s in
                 s.tools.proportionalEdit = true
                 s.tools.falloff = .smooth
                 s.tools.size = 0.6
             }, run: moveZ)
// Topology Mirror ignores the axis, so with Y on as well each pair is found
// twice, and the second pass makes every selected vertex a mirror of itself:
// nothing is left to transform, and Blender cancels.
symmetryCase("MONKEY_TOPOLOGY_XY", "monkey", selected: ear,
             symmetry: MeshSymmetry(x: true, y: true, topology: true),
             control: "X and Y with Topology Mirror leave nothing to transform", still: true, run: moveFree)
// The grid under SimpleDeform's Twist: the vertex at (0.6, 0.4) on the edit
// mesh, whose image Blender moves with it although no drawn vertex mirrors it.
let twistOne = nearest("twisted", to: [SIMD3(0.6, 0.4, 0)])
symmetryCase("TWIST_X", "twisted", selected: twistOne, symmetry: X, run: moveFree)
symmetryCase("TWIST_X_MOVE_Z", "twisted", selected: nearest("twisted", to: [SIMD3(0.6, 0.4, 0), SIMD3(0.2, -0.8, 0)]),
             symmetry: X, run: moveZ)
symmetryCase("TWIST_XY", "twisted", selected: twistOne, symmetry: MeshSymmetry(x: true, y: true), run: moveFree)
symmetryCase("TWIST_X_ON_PLANE", "twisted", selected: nearest("twisted", to: [SIMD3(0, 0.4, 0), SIMD3(0.4, 0.6, 0)]),
             symmetry: X, run: moveX)
emit("CASES", cases.joined(separator: " "))

// What the Swift found as Topology Mirror's pairs, for the record.
for fixture in ["monkey", "skewed", "cube", "grid", "sphere", "cylinder", "torus", "monkey2"] {
    let d = meshes[fixture] as! [String: Any]
    let table = SymmetricEdit.topologyTable(vertexCount: floats(d["co"]).count / 3, edges: ints(d["edges"]))
    emit("TOPOLOGY_" + fixture, json(table.map { Int($0) }))
}

print(out.joined(separator: "\n#--\n"))
