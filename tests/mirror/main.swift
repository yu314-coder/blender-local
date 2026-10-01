import Foundation
import simd
import CoreGraphics

// The mirror's Swift half, on the Mac: what one `sync_push` becomes, a mesh with
// no faces carried by its edges, the merge of a pass into what is on screen,
// and a wire object picked by its lines. The `bk_sync_*` entry points only copy
// buffers out of Python into these; what Blender's own sync sends through them
// is scripts/run-mirror-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// One `sync_push`, as the entry point hands it over.
func push(_ name: String, kind: String = "MESH", _ vertices: [SIMD3<Float>],
          triangles: [UInt32] = [], at location: SIMD3<Float> = .zero,
          previous: BKObject? = nil) -> (object: BKObject, unchanged: Bool)? {
    // Blender's matrix_world, row-major.
    var matrix = [Double](repeating: 0, count: 16)
    matrix[0] = 1; matrix[5] = 1; matrix[10] = 1; matrix[15] = 1
    matrix[3] = Double(location.x); matrix[7] = Double(location.y); matrix[11] = Double(location.z)
    let positions: [Float] = vertices.flatMap { [$0.x, $0.y, $0.z] }
    let normals = [Float](repeating: 0, count: positions.count).enumerated().map { $0.offset % 3 == 2 ? 1 : $0.element }
    return matrix.withUnsafeBufferPointer { m in
        positions.withUnsafeBufferPointer { p in
            normals.withUnsafeBufferPointer { n in
                triangles.withUnsafeBufferPointer { t in
                    SceneMirror.object(named: name, kind: kind, matrix: m, positions: p, normals: n,
                                       triangles: t, colour: nil, previous: previous)
                }
            }
        }
    }
}

func circle(_ count: Int = 32, radius: Float = 1) -> (points: [SIMD3<Float>], edges: [UInt32]) {
    let points = (0..<count).map { i -> SIMD3<Float> in
        let a = Float(i) / Float(count) * 2 * .pi
        return SIMD3(cos(a) * radius, sin(a) * radius, 0)
    }
    let edges = (0..<count).flatMap { [UInt32($0), UInt32(($0 + 1) % count)] }
    return (points, edges)
}

func checked(_ values: [UInt32], vertexCount: Int) -> [UInt32]? {
    values.withUnsafeBufferPointer { SceneMirror.edges($0, vertexCount: vertexCount) }
}

print("== an object with no faces reaches the mirror, by its edges ==")
do {
    let (points, edges) = circle()
    guard let made = push("Circle", points) else {
        check("a mesh with no triangles is pushed at all", false); exit(1)
    }
    check("a mesh with no triangles is pushed", made.object.mesh.vertices.count == 32
          && made.object.mesh.indices.isEmpty)
    check("its edges are valid", checked(edges, vertexCount: 32) == edges)
    check("an odd count is not", checked([0, 1, 2], vertexCount: 32) == nil)
    check("nor a vertex that is not there", checked([0, 32], vertexCount: 32) == nil)
    check("installing them changes the mesh", SceneMirror.installEdges(edges, on: made.object))
    check("into a wire of 32 edges and no faces", made.object.mesh.isWire
          && made.object.mesh.edges.count == 64 && made.object.mesh.indices.isEmpty)
    check("installed as Blender's evaluated mesh", made.object.meshIsEvaluated)

    let cube = push("Cube", MeshBuilder.cube(size: 2).vertices.map(\.position),
                    triangles: MeshBuilder.cube(size: 2).indices)!.object
    let before = cube.mesh.edges
    check("edges are never forced onto a mesh with faces",
          !SceneMirror.installEdges([0, 1], on: cube) && cube.mesh.edges == before)
    check("a triangle naming a missing vertex is refused",
          push("Bad", [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)], triangles: [0, 1, 3]) == nil)

    let bounds = push("Huge", kind: "MESH|bounds=12000000", points)!.object
    check("`|bounds=N` says how many vertices are not drawn", bounds.undrawnVertexCount == 12_000_000)
    let hidden = push("Hidden", kind: "MESH|hidden|norender", points)!.object
    check("and leaves the other flags alone", !hidden.visible && hidden.hideRender
          && hidden.undrawnVertexCount == nil && hidden.blenderType == "MESH")
}

print("\n== the next pass: the same wire is unchanged, a changed one is not ==")
do {
    let (points, edges) = circle()
    let first = push("Circle", points)!.object
    SceneMirror.installEdges(edges, on: first)
    let again = push("Circle", points, previous: first)!
    check("the same vertices come back as unchanged", again.unchanged)
    check("with the edges the previous pass installed", again.object.mesh.edges == edges)
    check("and the same edges install nothing", !SceneMirror.installEdges(edges, on: again.object))
    let fewer = Array(edges.prefix(62))
    let dissolved = push("Circle", points, previous: first)!
    check("an edge dissolved between two vertices that both stay is a change",
          SceneMirror.installEdges(fewer, on: dissolved.object)
          && dissolved.object.mesh.edges.count == 62)
}

print("\n== the merge: a pass onto what is on screen ==")
do {
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let base = MeshBuilder.cube(size: 2)
    let first = push("Cube", base.vertices.map(\.position), triangles: base.indices)!.object
    SceneMirror.merge([first], into: scene, unchanged: [], selection: [first.id], active: first.id)
    let onScreen = scene.objects[0]
    check("a new object goes on screen", scene.objects.count == 1 && onScreen === first)

    // Screw, 16 steps, added in Blender to the object already on screen. The
    // record rides on the pass's fresh object, which the merge throws away.
    let screw = Modifier.stack(from: "kind=SCREW;name=Screw;angle=6.283185;steps=16.0;axis=Z;screw_offset=0.0")
    let evaluated = ModifierStack.apply(screw, to: base)
    let second = push("Cube", evaluated.vertices.map(\.position), triangles: evaluated.indices,
                      previous: onScreen)!.object
    second.modifiers = screw
    SceneMirror.merge([second], into: scene, unchanged: [], selection: [second.id], active: second.id)
    check("the object on screen keeps its identity", scene.objects.count == 1 && scene.objects[0] === onScreen)
    check("and gets the row Blender's modifier added", onScreen.modifiers.map(\.kind) == [.screw])
    check("over Blender's own evaluated mesh, not a second Screw on top of it",
          onScreen.mesh.vertices.count == evaluated.vertices.count,
          "\(onScreen.mesh.vertices.count) drawn, \(evaluated.vertices.count) in Blender")
    check("the selection and the active object land on it",
          scene.selection == [onScreen.id] && scene.activeID == onScreen.id)
    let row = onScreen.modifiers[0].id

    let third = push("Cube", evaluated.vertices.map(\.position), triangles: evaluated.indices,
                     previous: onScreen)!
    third.object.modifiers = Modifier.stack(
        from: "kind=SCREW;name=Screw;angle=6.283185;steps=24.0;axis=Z;screw_offset=0.0")
    SceneMirror.merge([third.object], into: scene, unchanged: third.unchanged ? ["Cube"] : [],
                      selection: [], active: nil)
    check("a row keeps its identity from pass to pass, so a drag on it survives one",
          onScreen.modifiers[0].id == row && onScreen.modifiers[0].count == 24)
    check("an unchanged mesh is not reinstalled", third.unchanged)

    // An object new to the screen: the stack is set after the mesh, as the
    // entry points do it, and does not run over it.
    let fresh = push("Fresh", evaluated.vertices.map(\.position), triangles: evaluated.indices)!.object
    fresh.modifiers = screw
    SceneMirror.merge([third.object, fresh], into: scene, unchanged: ["Cube"], selection: [], active: nil)
    check("a new object's mesh is Blender's count under its stack too",
          scene.objects.last?.mesh.vertices.count == evaluated.vertices.count)
    check("an object Blender no longer has leaves the screen",
          scene.objects.map(\.name) == ["Cube", "Fresh"])
    SceneMirror.merge([fresh], into: scene, unchanged: [], selection: [], active: nil)
    check("…whichever it was", scene.objects.map(\.name) == ["Fresh"])

    let (points, edges) = circle()
    let wire = push("Circle", points)!.object
    SceneMirror.installEdges(edges, on: wire)
    let huge = push("Huge", kind: "MESH|bounds=12000000", points)!.object
    SceneMirror.merge([fresh, wire, huge], into: scene, unchanged: [], selection: [], active: nil)
    check("a wire object merges in as a wire", scene.objects.first { $0.name == "Circle" }?.mesh.isWire == true)
    let smaller = push("Huge", kind: "MESH", points, previous: huge)!.object
    SceneMirror.merge([fresh, wire, smaller], into: scene, unchanged: [], selection: [], active: nil)
    check("and an object that fits again stops saying it is not drawn",
          scene.objects.first { $0.name == "Huge" }?.undrawnVertexCount == nil)
}

/// One `sync_uvs`, as the entry point hands it over.
func installUVs(_ name: String = "UVMap", loops: [UInt32], uvs: [Float], seams: [UInt32] = [],
                on obj: BKObject) -> Bool? {
    loops.withUnsafeBufferPointer { l in
        uvs.withUnsafeBufferPointer { u in
            seams.withUnsafeBufferPointer { s in
                SceneMirror.installUVs(mapName: name, triangleLoops: l, loopUVs: u, seams: s, on: obj)
            }
        }
    }
}

print("\n== Blender's UV map and seams ride with the mesh ==")
do {
    // One quad, as Blender's loop triangles split it: loops 0-3 round the
    // face, triangles (0, 1, 2) and (0, 2, 3), the loops the same numbers as
    // the vertices. UVs per loop, so the corners pick them out by loop.
    let quad: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
    let tris: [UInt32] = [0, 1, 2, 0, 2, 3]
    let loops: [UInt32] = [0, 1, 2, 0, 2, 3]
    let square: [Float] = [0, 0, 1, 0, 1, 1, 0, 1]

    let made = push("Quad", quad, triangles: tris)!.object
    check("no UVs until the mirror sends a map", !made.mesh.hasUVs)
    check("a map is installed", installUVs(loops: loops, uvs: square, on: made) == true)
    check("one UV per triangle corner", made.mesh.cornerUVs.count == 6 && made.mesh.hasUVs)
    check("each corner reads its own loop's UV",
          made.mesh.cornerUV(4) == SIMD2(1, 1) && made.mesh.cornerUV(5) == SIMD2(0, 1),
          "\(made.mesh.cornerUVs)")
    check("under Blender's name for the map", made.mesh.uvMapName == "UVMap")
    check("installed as Blender's evaluated mesh", made.meshIsEvaluated)
    // Triangle 0's third edge (corners 2 -> 0) and triangle 1's first
    // (corners 0 -> 1) are both loops 0-2: the diagonal, and only it.
    check("the quad's diagonal is marked on both halves, and no other edge",
          made.mesh.uvDiagonals == [0b100, 0b001], "\(made.mesh.uvDiagonals)")
    check("the same map again installs nothing",
          installUVs(loops: loops, uvs: square, on: made) == false)
    let outline = made.mesh.uvEditorLines()
    check("the UV Editor strokes the quad's four sides and not its diagonal",
          outline.edges.count == 4 && outline.seams.isEmpty
              && !outline.edges.contains { Set([made.mesh.indices[$0.0], made.mesh.indices[$0.1]]) == [0, 2] })

    print("\n  the unchanged-mesh fast path")
    let version = made.meshVersion
    let again = push("Quad", quad, triangles: tris, previous: made)!
    check("the same geometry is still unchanged", again.unchanged)
    check("and keeps the map the previous pass installed",
          again.object.mesh.cornerUVs == made.mesh.cornerUVs && again.object.mesh.uvMapName == "UVMap")
    check("the same map leaves it unchanged",
          installUVs(loops: loops, uvs: square, on: again.object) == false)
    let scene = BKScene(startupFile: false)
    scene.objects = [made]
    SceneMirror.merge([again.object], into: scene, unchanged: ["Quad"], selection: [], active: nil)
    check("so the object on screen is not reinstalled, nor re-uploaded",
          scene.objects[0] === made && made.meshVersion == version)

    // An unwrap moves no vertex: the geometry is unchanged and the map is not.
    let unwrapped = push("Quad", quad, triangles: tris, previous: made)!
    let half = square.map { $0 * 0.5 }
    check("an unwrap's geometry comes back unchanged", unwrapped.unchanged)
    check("but its new UVs are a change", installUVs(loops: loops, uvs: half, on: unwrapped.object) == true)
    SceneMirror.merge([unwrapped.object], into: scene, unchanged: [], selection: [], active: nil)
    check("which the object on screen takes", made.mesh.cornerUV(2) == SIMD2(0.5, 0.5)
          && made.meshVersion != version)

    print("\n  what tells a polygon's edges from a diagonal")
    // The same two triangles as two faces: six loops, none shared. Vertices,
    // normals and UVs all identical — only the loops say the diagonal is now
    // an edge.
    let faces = push("Quad", quad, triangles: tris, previous: made)!
    let sixLoops: [UInt32] = [0, 1, 2, 3, 4, 5]
    let sixUVs: [Float] = [0, 0, 0.5, 0, 0.5, 0.5, 0, 0, 0.5, 0.5, 0, 0.5]
    check("the same triangles split into two faces are a change",
          installUVs(loops: sixLoops, uvs: sixUVs, on: faces.object) == true)
    check("and have no diagonal", faces.object.mesh.uvDiagonals == [0, 0])
    check("with the same corners as before", faces.object.mesh.cornerUVs == made.mesh.cornerUVs)

    print("\n  seams, and a map taken away")
    let seamed = push("Quad", quad, triangles: tris)!.object
    check("seams arrive as vertex pairs",
          installUVs(loops: loops, uvs: square, seams: [0, 1, 1, 2], on: seamed) == true
              && seamed.mesh.seamEdges == [0, 1, 1, 2])
    let marked = seamed.mesh.uvEditorLines()
    check("and the UV Editor strokes those two sides as seams, the other two as edges",
          marked.seams.count == 2 && marked.edges.count == 2)
    check("marking one more is a change",
          installUVs(loops: loops, uvs: square, seams: [0, 1, 1, 2, 2, 3], on: seamed) == true)
    check("a map removed in Blender is removed here",
          installUVs("", loops: [], uvs: [], seams: [0, 1], on: seamed) == true
              && !seamed.mesh.hasUVs && seamed.mesh.uvMapName.isEmpty)
    check("while its seams stay: they are marked before an unwrap",
          seamed.mesh.seamEdges == [0, 1])

    print("\n  what is refused")
    let probe = push("Quad", quad, triangles: tris)!.object
    check("loops for another triangle count", installUVs(loops: [0, 1, 2], uvs: square, on: probe) == nil)
    check("a loop past the UVs", installUVs(loops: [0, 1, 2, 0, 2, 4], uvs: square, on: probe) == nil)
    check("an odd UV buffer", installUVs(loops: loops, uvs: [0, 0, 1], on: probe) == nil)
    check("a seam naming a vertex that is not there",
          installUVs(loops: loops, uvs: square, seams: [0, 4], on: probe) == nil)
    check("an odd seam buffer", installUVs(loops: loops, uvs: square, seams: [0], on: probe) == nil)
    check("and a refusal leaves the mesh alone", !probe.mesh.hasUVs && probe.mesh.seamEdges.isEmpty)

    print("\n  stretch reads the corners")
    check("a square face on a square map is not stretched",
          abs(UVUnwrap.averageStretch(made.mesh)) < 1e-6, "\(UVUnwrap.averageStretch(made.mesh))")
    let skewed = push("Quad", quad, triangles: tris)!.object
    _ = installUVs(loops: loops, uvs: [0, 0, 1, 0, 1, 0.2, 0, 1], on: skewed)
    check("a squashed half is", UVUnwrap.averageStretch(skewed.mesh) > 0.1,
          "\(UVUnwrap.averageStretch(skewed.mesh))")
}

print("\n== Knife Project lists what the mirror now carries ==")
do {
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let plane = push("Plane", MeshBuilder.plane(size: 4).vertices.map(\.position),
                     triangles: MeshBuilder.plane(size: 4).indices)!.object
    let (points, edges) = circle()
    let wire = push("Circle", points)!.object
    SceneMirror.installEdges(edges, on: wire)
    let curve = push("BezierCircle", kind: "CURVE", points)!.object
    SceneMirror.installEdges(edges, on: curve)
    let hidden = push("Hidden", kind: "MESH|hidden", [.zero])!.object
    let camera = push("Camera", kind: "CAMERA", [.zero])!.object
    SceneMirror.merge([plane, wire, curve, hidden, camera], into: scene, unchanged: [],
                      selection: [plane.id], active: plane.id)
    check("the wire circle and the unfilled curve, not the plane being edited, a hidden object or a camera",
          scene.knifeProjectCutters.map(\.name) == ["Circle", "BezierCircle"],
          scene.knifeProjectCutters.map(\.name).joined(separator: ", "))
}

print("\n== a wire object is picked by its lines ==")
do {
    // Looking straight down at the origin from 10 m, 50 degrees across.
    let eye = SIMD3<Float>(0, 0, 10)
    let view = simd_float4x4(rows: [SIMD4(1, 0, 0, -eye.x), SIMD4(0, 1, 0, -eye.y),
                                    SIMD4(0, 0, 1, -eye.z), SIMD4(0, 0, 0, 1)])
    let f = 1 / tan(Float(25) * .pi / 180), near: Float = 0.1, far: Float = 100
    let size = CGSize(width: 800, height: 800)
    let projection = simd_float4x4(rows: [SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0),
                                          SIMD4(0, 0, (far + near) / (near - far), 2 * far * near / (near - far)),
                                          SIMD4(0, 0, -1, 0)])
    let overlay = OverlayView(view: view, projection: projection, size: size)

    let scene = BKScene(startupFile: false)
    scene.objects = []
    let (points, edges) = circle()
    let wire = push("Circle", points)!.object
    SceneMirror.installEdges(edges, on: wire)
    SceneMirror.merge([wire], into: scene, unchanged: [], selection: [], active: nil)

    let onEdge = overlay.project(SIMD3(1, 0, 0))!
    check("a tap on its edge takes it", ObjectOverlayPicking.object(at: onEdge, in: scene, view: overlay) === wire)
    let nearEdge = CGPoint(x: onEdge.x + 10, y: onEdge.y)
    check("so does one a fingertip off", ObjectOverlayPicking.object(at: nearEdge, in: scene, view: overlay) === wire)
    let centre = overlay.project(.zero)!
    check("its middle, where nothing is drawn, does not",
          ObjectOverlayPicking.object(at: centre, in: scene, view: overlay) == nil,
          "\(ObjectOverlayPicking.nearest(to: centre, on: wire, in: scene, view: overlay)?.distance ?? -1) pt from its lines")
    // Blender draws it in the wireframe overlay, which runs in Wireframe
    // shading or with the overlays on (overlay_instance.cc).
    check("with the overlays hidden in Solid it is not drawn, so not taken",
          ObjectOverlayPicking.object(at: onEdge, in: scene, view: overlay, overlays: false) == nil)
    check("in Wireframe it is, overlays or not",
          ObjectOverlayPicking.object(at: onEdge, in: scene, view: overlay, overlays: false,
                                      wireframe: true) === wire)

    var axes = EmptyDisplay()
    axes.kind = .plainAxes
    let empty = scene.addObject(.empty(axes), named: "Empty", at: SIMD3(3, 0, 0), select: false)
    let onEmpty = overlay.project(SIMD3(3.5, 0, 0))!
    check("an empty is taken with the overlays on",
          ObjectOverlayPicking.object(at: onEmpty, in: scene, view: overlay) === empty)
    check("and not with them hidden, as Blender draws and selects neither",
          ObjectOverlayPicking.object(at: onEmpty, in: scene, view: overlay, overlays: false) == nil)

    // A plane between the eye and the circle has the tap.
    let wall = scene.add(.plane)
    wall.location = SIMD3(0, 0, 5)
    wall.scale = SIMD3(repeating: 3)
    check("a face in front of it has the tap", ObjectOverlayPicking.object(at: onEdge, in: scene, view: overlay) == nil)
}

print("\n== the two reasons an object is not drawn, as the Outliner shows them ==")
do {
    let square: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)]
    let shown = push("Shown", square, triangles: [0, 1, 2])!.object
    check("an object with no flags is drawn, its eye open, not disabled",
          shown.visible && !shown.hiddenInViewLayer && !shown.disabledInViewports)
    // What `_kind` sends for an object hidden with H: not drawn, the view
    // layer's flag set.
    let hidden = push("Hidden", kind: "MESH|hidden|layerhidden", square)!.object
    check("H: not drawn, the eye closed, not disabled",
          !hidden.visible && hidden.hiddenInViewLayer && !hidden.disabledInViewports)
    let disabled = push("Off", kind: "MESH|hidden|disabled|norender", square)!.object
    check("Disable in Viewports: not drawn, the eye open, disabled — and the render flag still read",
          !disabled.visible && !disabled.hiddenInViewLayer && disabled.disabledInViewports
              && disabled.hideRender && disabled.blenderType == "MESH")
    // A hidden collection hides an object with neither flag.
    let inHidden = push("InHiddenCollection", kind: "MESH|hidden", square)!.object
    check("a hidden collection: not drawn, with neither flag",
          !inHidden.visible && !inHidden.hiddenInViewLayer && !inHidden.disabledInViewports)

    // The next pass shows it again, onto the object on screen.
    let scene = BKScene(startupFile: false)
    scene.objects = []
    SceneMirror.merge([hidden], into: scene, unchanged: [], selection: [], active: nil)
    let again = push("Hidden", square)!.object
    SceneMirror.merge([again], into: scene, unchanged: [], selection: [], active: nil)
    check("a pass that shows it again opens the eye on the object already listed",
          scene.objects.count == 1 && scene.objects[0] === hidden
              && hidden.visible && !hidden.hiddenInViewLayer)
    let off = push("Hidden", kind: "MESH|hidden|disabled", square)!.object
    SceneMirror.merge([off], into: scene, unchanged: [], selection: [], active: nil)
    check("and one that disables it says so", hidden.disabledInViewports && !hidden.visible)
    check("a duplicate keeps both flags",
          { () -> Bool in
              scene.selection = [hidden.id]
              let copy = scene.duplicateSelection().first
              return copy?.disabledInViewports == true && copy?.hiddenInViewLayer == false
          }())
}

/// One `anim_mesh`, as `bk_anim_set_mesh` hands it over: a frame change's
/// evaluated mesh, with the edges of one that has no faces.
func frameMesh(_ name: String, _ vertices: [SIMD3<Float>], normals: [SIMD3<Float>]? = nil,
               triangles: [UInt32] = [], edges: [UInt32]? = nil, in scene: BKScene) -> Int {
    let positions: [Float] = vertices.flatMap { [$0.x, $0.y, $0.z] }
    let n: [Float] = (normals ?? vertices.map { _ in SIMD3<Float>(0, 0, 1) }).flatMap { [$0.x, $0.y, $0.z] }
    return positions.withUnsafeBufferPointer { p in
        n.withUnsafeBufferPointer { nn in
            triangles.withUnsafeBufferPointer { t in
                guard let edges else {
                    return AnimationMirror.applyMesh(named: name, positions: p, normals: nn,
                                                     triangles: t, to: scene)
                }
                return edges.withUnsafeBufferPointer { e in
                    AnimationMirror.applyMesh(named: name, positions: p, normals: nn,
                                              triangles: t, edges: e, to: scene)
                }
            }
        }
    }
}

print("\n== a frame change installs Blender's evaluated mesh, as a pass does ==")
do {
    // A Screw of 16 steps: its record rides with the pass, and the mesh the
    // pass and the frame change both push is Blender's evaluated one. Measured
    // before this was fixed: 384 vertices after the pass, 6,144 after one
    // frame change of the same mesh, the Swift Screw run over Blender's.
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let screw = Modifier.stack(from: "kind=SCREW;name=Screw;angle=6.283185;steps=16.0;axis=Z;screw_offset=0.0")
    let evaluated = ModifierStack.apply(screw, to: MeshBuilder.cube(size: 2))
    let pushed = push("Screwed", evaluated.vertices.map(\.position), triangles: evaluated.indices)!.object
    pushed.modifiers = screw
    SceneMirror.merge([pushed], into: scene, unchanged: [], selection: [], active: nil)
    let drawn = scene.objects[0].mesh.vertices.count
    check("the pass draws Blender's count", drawn == evaluated.vertices.count, "\(drawn)")
    let moved = evaluated.vertices.map { $0.position + SIMD3(0, 0, 0.01) }
    check("a frame change that moved it is taken",
          frameMesh("Screwed", moved, normals: evaluated.vertices.map(\.normal),
                    triangles: evaluated.indices, in: scene) == 1)
    check("and drawn at Blender's count, not with a second Screw run over it",
          scene.objects[0].mesh.vertices.count == evaluated.vertices.count,
          "\(scene.objects[0].mesh.vertices.count) drawn, \(evaluated.vertices.count) in Blender")
    check("installed as Blender's evaluated mesh", scene.objects[0].meshIsEvaluated)
    check("with the vertices where Blender put them",
          scene.objects[0].mesh.vertices[0].position == moved[0])
    let same = frameMesh("Screwed", moved, normals: evaluated.vertices.map(\.normal),
                         triangles: evaluated.indices, in: scene)
    check("the same frame again is unchanged", same == 0, "\(same)")
    // A row edit rebuilds nothing over it either: the panel's stack is a
    // description while the mesh is Blender's.
    scene.objects[0].modifiers[0].count = 24
    check("editing the row leaves Blender's mesh alone until the next pass",
          scene.objects[0].mesh.vertices.count == evaluated.vertices.count)

    // A duplicate starts from the geometry on screen, which is Blender's.
    scene.selection = [scene.objects[0].id]
    let copy = scene.duplicateSelection().first
    check("a duplicate of it is drawn at Blender's count too, its stack not run over it again",
          copy?.mesh.vertices.count == evaluated.vertices.count,
          "\(copy?.mesh.vertices.count ?? -1) drawn, \(evaluated.vertices.count) in Blender")
    if let copy { scene.objects.removeAll { $0 === copy } }

    // A wire: `push_mesh` sends its edges, since it has no triangles to
    // derive them from.
    let (points, edges) = circle()
    let wire = push("Wire", points)!.object
    SceneMirror.installEdges(edges, on: wire)
    SceneMirror.merge([scene.objects[0], wire], into: scene, unchanged: ["Screwed"], selection: [], active: nil)
    let lifted = points.map { $0 + SIMD3(0, 0, 0.25) }
    check("a frame change moves a wire", frameMesh("Wire", lifted, edges: edges, in: scene) == 1
          && wire.mesh.vertices[5].position == lifted[5])
    check("and it is still a wire of 32 edges", wire.mesh.isWire && wire.mesh.edges == edges)
    check("the same frame again is unchanged", frameMesh("Wire", lifted, edges: edges, in: scene) == 0)
    check("the same vertices with an edge fewer are not",
          frameMesh("Wire", lifted, edges: Array(edges.prefix(62)), in: scene) == 1
            && wire.mesh.edges.count == 62)
    check("nor with none: no line is drawn",
          frameMesh("Wire", lifted, edges: [], in: scene) == 1 && !wire.mesh.isWire && wire.mesh.edges.isEmpty)
    check("an edge naming a vertex that is not there is refused",
          frameMesh("Wire", lifted, edges: [0, 32], in: scene) == -1)
    check("and so is an odd one", frameMesh("Wire", lifted, edges: [0, 1, 2], in: scene) == -1)
}

print("\n== an object's own channels: onto the pass, or onto the screen ==")
do {
    // Location, rotation (w, x, y, z), scale — as `push_local` sends them.
    let turned: [Double] = [1, 2, 3, 1, 0, 0, 0, 2, 2, 2]
    let a = push("A", [SIMD3(0, 0, 0)])!.object
    let b = push("B", [SIMD3(0, 0, 0)])!.object
    check("during a pass they go on the object that pass pushed",
          SceneMirror.carryLocal(turned, named: "A", pass: [a, b], screen: []) == 1
              && a.localTransform?.location == SIMD3(1, 2, 3) && b.localTransform == nil)
    let late = push("Late", [SIMD3(0, 0, 0)])!.object
    check("a pass that never pushed the name is refused: that is a mirroring bug",
          SceneMirror.carryLocal(turned, named: "Late", pass: [a, b], screen: [late]) == -1
              && late.localTransform == nil)

    // A frame change: outside any pass, onto what is on screen.
    let onScreen = push("OnScreen", [SIMD3(0, 0, 0)])!.object
    check("a frame change updates the object on screen",
          SceneMirror.carryLocal(turned, named: "OnScreen", pass: nil, screen: [onScreen]) == 1
              && onScreen.localTransform?.scale == SIMD3(2, 2, 2))
    // Returned as -1 this became the ValueError that cost a frame change its
    // `anim_frame`; `AnimationMirror.applyFrame` skips an unknown name.
    check("and skips a name the screen does not hold, as a frame's matrices do",
          SceneMirror.carryLocal(turned, named: "NotMirroredYet", pass: nil, screen: [onScreen]) == 0)
    let stale = LocalTransform([0, 0, 0, 1, 0, 0, 0, 1, 1, 1])
    onScreen.localTransform = stale
    check("channels Blender holds as NaN arrive as unknown, which offers every row",
          SceneMirror.carryLocal([.nan, 0, 0, 1, 0, 0, 0, 1, 1, 1], named: "OnScreen",
                                 pass: nil, screen: [onScreen]) == 1
              && onScreen.localTransform == nil)
    check("nine numbers are malformed", SceneMirror.carryLocal(
        Array(turned.prefix(9)), named: "OnScreen", pass: nil, screen: [onScreen]) == -1)
}

print("\n== a frame's names looked up once, not once per moved object ==")
do {
    let turned: [Double] = [1, 2, 3, 1, 0, 0, 0, 2, 2, 2]
    let first = push("Twin", [SIMD3(0, 0, 0)])!.object
    let second = push("Twin", [SIMD3(0, 0, 0)])!.object
    let other = push("Other", [SIMD3(0, 0, 0)])!.object
    var screen = [first, second, other]
    let index = ObjectNameIndex()
    check("the index gives the first object of a name, as screen.first did",
          SceneMirror.carryLocal(turned, named: "Twin", pass: nil, screen: screen, index: index) == 1
              && first.localTransform != nil && second.localTransform == nil)
    other.name = "Renamed"
    check("a hit renamed since the build is not taken for the old name",
          SceneMirror.carryLocal(turned, named: "Other", pass: nil, screen: screen, index: index) == 0
              && other.localTransform == nil)
    check("and the new name is found", index.object(named: "Renamed", in: screen) === other)
    let added = push("Added", [SIMD3(0, 0, 0)])!.object
    screen.append(added)
    check("an object added since the build is found (the count changed)",
          SceneMirror.carryLocal(turned, named: "Added", pass: nil, screen: screen, index: index) == 1)
    index.invalidate()
    check("and an invalidated index is rebuilt from what is on screen now",
          index.object(named: "Twin", in: [second]) === second)

    // Round 2's review: carryLocal walked the screen per moved object, 10.3 ms
    // a frame with 1,000 keyed objects and 88 ms with 3,000 (swiftc -O). One
    // frame with every object keyed, the way push_frame sends it: one index
    // for the frame, invalidated after, as bk_anim_set_frame does.
    for n in [1000, 3000] {
        let objects = (0..<n).map { BKObject(name: "Object.\(String(format: "%04d", $0))", kind: .cube) }
        let shared = ObjectNameIndex()
        var carried = 0
        let t0 = Date()
        for o in objects {
            carried += SceneMirror.carryLocal(turned, named: o.name, pass: nil, screen: objects, index: shared)
        }
        shared.invalidate()
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "        %d keyed objects: %.2f ms for the frame's channels", n, ms))
        // A quarter of a 24 fps frame is 10.4 ms; the walk took 88 ms at 3,000.
        check("\(n) keyed objects' channels take well under a quarter of a 24 fps frame",
              carried == n && ms < 5, String(format: "%.2f ms, %d carried", ms, carried))
    }
}

print("\n== an object not drawn keeps the mesh, and the paint, it was drawn with ==")
do {
    // The app's vertex paint and weights live on the display cache alone; bpy
    // has no copy to send back. H sends the cube as its origin alone.
    let base = MeshBuilder.cube(size: 2)
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let first = push("Cube", base.vertices.map(\.position), triangles: base.indices)!.object
    SceneMirror.merge([first], into: scene, unchanged: [], selection: [first.id], active: first.id)
    let n = first.mesh.vertices.count
    first.vertexColours = Array(repeating: SIMD4(1, 0, 0, 1), count: n)
    first.vertexWeights = Array(repeating: 0.5, count: n)
    let version = first.meshVersion

    for kind in ["MESH|hidden|layerhidden", "MESH|hidden|disabled", "MESH|hidden"] {
        let hidden = push("Cube", kind: kind, [.zero], previous: first)!
        SceneMirror.merge([hidden.object], into: scene, unchanged: hidden.unchanged ? ["Cube"] : [],
                          selection: [], active: first.id)
        check("\(kind): the object on screen is not drawn, and keeps its \(n) vertices",
              !first.visible && first.mesh.vertices.count == n, "\(first.mesh.vertices.count)")
        check("\(kind): and its \(n) painted colours and weights",
              first.vertexColours.count == n && first.vertexWeights.count == n,
              "\(first.vertexColours.count), \(first.vertexWeights.count)")
        let shown = push("Cube", base.vertices.map(\.position), triangles: base.indices, previous: first)!
        SceneMirror.merge([shown.object], into: scene, unchanged: shown.unchanged ? ["Cube"] : [],
                          selection: [], active: first.id)
        check("\(kind): shown again, it is drawn, painted, and its mesh was never reinstalled",
              first.visible && first.vertexColours.count == n && first.vertexWeights.count == n
                  && first.meshVersion == version, "version \(version) → \(first.meshVersion)")
    }

    // A drawn mesh whose count changed is another mesh: its layers go.
    let subdivided = ModifierStack.apply(Modifier.stack(from: "kind=SUBSURF;name=Subdivision;levels=1.0"), to: base)
    let grown = push("Cube", subdivided.vertices.map(\.position), triangles: subdivided.indices, previous: first)!
    SceneMirror.merge([grown.object], into: scene, unchanged: [], selection: [], active: nil)
    check("a drawn mesh with another vertex count still drops them",
          first.mesh.vertices.count != n && first.vertexColours.isEmpty && first.vertexWeights.isEmpty,
          "\(first.mesh.vertices.count) vertices, \(first.vertexColours.count) colours")

    // Never drawn: nothing to keep, so it arrives as what was sent.
    let never = push("Never", kind: "MESH|hidden|layerhidden", [.zero])!.object
    SceneMirror.merge([first, never], into: scene, unchanged: [], selection: [], active: nil)
    check("an object hidden since it arrived is its origin alone",
          scene.objects.last === never && never.mesh.vertices.count == 1)
}

print("\n== the simulator's undo keeps both reasons an object is not drawn ==")
do {
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let off = scene.add(.cube)
    off.name = "Off"
    let hidden = scene.add(.cube)
    hidden.name = "Hidden"
    scene.setHidden(off, true, inViewLayer: false)
    scene.setHidden(hidden, true, inViewLayer: true)
    scene.restore(scene.snapshot())
    let restoredOff = scene.objects.first { $0.name == "Off" }
    let restoredHidden = scene.objects.first { $0.name == "Hidden" }
    check("a disabled object comes back disabled, its eye open, not drawn",
          restoredOff?.disabledInViewports == true && restoredOff?.hiddenInViewLayer == false
              && restoredOff?.visible == false,
          "disabled \(restoredOff?.disabledInViewports ?? false), hidden \(restoredOff?.hiddenInViewLayer ?? false)")
    check("a hidden one comes back hidden, not disabled",
          restoredHidden?.hiddenInViewLayer == true && restoredHidden?.disabledInViewports == false
              && restoredHidden?.visible == false)
    // A step written before the flags were kept: `visible` is all it has.
    var old = scene.snapshot()
    for i in old.objects.indices {
        old.objects[i].hiddenInViewLayer = nil
        old.objects[i].disabledInViewports = nil
    }
    scene.restore(old)
    check("a step from before the two flags reads not drawn as hidden",
          scene.objects.allSatisfy { $0.hiddenInViewLayer && !$0.disabledInViewports })
    let encoded = try? JSONEncoder().encode(scene.snapshot())
    let decoded = encoded.flatMap { try? JSONDecoder().decode(SceneSnapshot.self, from: $0) }
    check("and the flags go to disk and back", decoded?.objects.allSatisfy { $0.hiddenInViewLayer == true } == true)
}

print("\n== the simulator's Hide and Show Hidden, as Blender 5.2.1 was measured ==")
do {
    let scene = BKScene(startupFile: false)
    scene.objects = []
    let a = scene.add(.cube), b = scene.add(.cube), c = scene.add(.cube)
    a.name = "A"; b.name = "B"; c.name = "C"
    scene.selection = [a.id, b.id]
    scene.setHidden(a, true, inViewLayer: true)
    check("hide_set(True) deselects, as Blender's does", !scene.selection.contains(a.id) && !a.visible)
    scene.setHidden(a, false, inViewLayer: true)
    check("hide_set(False) selects nothing", !scene.selection.contains(a.id) && a.visible)
    scene.setHidden(b, true, inViewLayer: false)
    check("hide_viewport = True deselects too", !scene.selection.contains(b.id) && !b.visible)
    scene.setHidden(b, false, inViewLayer: false)

    // Hidden and disabled at once: Blender's Show Hidden clears the hide,
    // leaves it disabled and unselected, and answers FINISHED.
    scene.selection = []
    scene.setHidden(c, true, inViewLayer: true)
    scene.setHidden(c, true, inViewLayer: false)
    check("Show Hidden clears the hide of an object also disabled, and counts it",
          scene.showHiddenObjects(select: true) == 1 && !c.hiddenInViewLayer && c.disabledInViewports)
    check("which stays undrawn and unselected", !c.visible && !scene.selection.contains(c.id))
    check("an object only disabled is not Show Hidden's: CANCELLED", scene.showHiddenObjects(select: true) == 0)
    scene.setHidden(c, false, inViewLayer: false)

    scene.selection = [a.id]
    check("Hide Selected hides the selected one", scene.hideObjects(unselected: false) == 1
          && a.hiddenInViewLayer && scene.selection.isEmpty)
    check("Show Hidden brings it back selected", scene.showHiddenObjects(select: true) == 1
          && a.visible && scene.selection == [a.id])
    check("Hide Unselected hides the other two", scene.hideObjects(unselected: true) == 2
          && b.hiddenInViewLayer && c.hiddenInViewLayer && a.visible)
    check("Show Hidden without selecting selects nothing new",
          scene.showHiddenObjects(select: false) == 2 && scene.selection == [a.id])
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
