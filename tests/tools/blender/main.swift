import Foundation
import simd
import CoreGraphics

// Every string the snapping, pivot and proportional controls send, printed for
// a headless Blender to run. For the transforms, what the drag's preview left
// behind is printed too, so Blender's result can be held against it: a pivot
// that previews one place and commits another is the failure worth catching.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func numbers(_ values: [Float]) -> String {
    values.map { String(format: "%.6f", $0) }.joined(separator: " ")
}

// MARK: the settings, as each control writes them

emit("SET_SNAP_ON", ToolsBpy.useSnap(true))
emit("SET_ELEMENTS", ToolsBpy.elements([.vertex, .edge, .faceMidpoint]))
emit("SET_INDIVIDUAL", ToolsBpy.individual([.faceNearest]))
emit("SET_TARGET", ToolsBpy.target(.median))
emit("SET_PIVOT", ToolsBpy.pivot(.individualOrigins))
emit("SET_PROPORTIONAL_EDIT", ToolsBpy.proportional(true, editing: true))
emit("SET_PROPORTIONAL_OBJECTS", ToolsBpy.proportional(true, editing: false))
emit("SET_CONNECTED", ToolsBpy.connected(true))
emit("SET_FALLOFF", ToolsBpy.falloff(.inverseSquare))
emit("SET_SIZE", ToolsBpy.size(2.5))
// Clamped in Swift, and clamped again by bpy: both ends must agree.
emit("SET_SIZE_HUGE", ToolsBpy.size(90000))

emit("SET_CURSOR", ToolsBpy.setCursor(SIMD3(1.5, 0, -2)))
emit("SET_AUTOMERGE", ToolsBpy.autoMerge(true))
emit("SET_AUTOMERGE_OFF", ToolsBpy.autoMerge(false))
emit("SET_MERGE_THRESHOLD", ToolsBpy.mergeThreshold(0.0025))
emit("SET_MERGE_THRESHOLD_HUGE", ToolsBpy.mergeThreshold(5))
emit("SET_SNAP_SELF_OFF", ToolsBpy.snapSelf(false))
emit("SET_SNAP_NONEDIT_OFF", ToolsBpy.snapNonEdited(false))
emit("SET_AUTOMERGE_SPLIT", ToolsBpy.autoMergeSplit(true))
emit("SET_SKIP_CHILDREN", ToolsBpy.affectOnlyParents(true))
emit("SET_DATA_ORIGIN", ToolsBpy.affectOnlyOrigins(true))
emit("SET_AFFECT_OFF", ToolsBpy.affectOnlyParents(false) + "\n" + ToolsBpy.affectOnlyOrigins(false))
// The eleventh int, as TransformToolsMirror packs it with all five on.
do {
    var all = TransformToolSettings()
    all.autoMergeSplit = true; all.affectOnlyParents = true; all.affectOnlyOrigins = true
    emit("FLAGS_ALL", "\(TransformToolsMirror.scalars(.init(tools: all, cursor: .zero)).ints[10])")
}
// Unticking the base set's last element with Face Project beside it, which
// `holdsLastSnapElement` allows.
emit("SET_INDIVIDUAL_PROJECT", ToolsBpy.individual([.faceProject]))
emit("SET_ELEMENTS_NONE", ToolsBpy.elements([]))

// MARK: the Shift+S menu

emit("SNAP_CURSOR_TO_CENTER", ToolsBpy.snap(.cursorToCenter))
emit("SNAP_CURSOR_TO_SELECTED", ToolsBpy.snap(.cursorToSelection))
emit("SNAP_SELECTION_TO_CURSOR", ToolsBpy.snap(.selectionToCursor))
emit("SNAP_SELECTION_TO_CURSOR_OFFSET", ToolsBpy.snap(.selectionToCursorKeepingOffset))
emit("SNAP_SELECTION_TO_GRID", ToolsBpy.snap(.selectionToGrid, increment: 1))
emit("SNAP_SELECTION_TO_ACTIVE", ToolsBpy.snap(.selectionToActive))
emit("SNAP_CURSOR_TO_GRID", ToolsBpy.snap(.cursorToGrid, increment: 0.5))
emit("SNAP_CURSOR_TO_ACTIVE", ToolsBpy.snap(.cursorToActive))
emit("SNAP_MENU_ORDER", SnapAction.allCases.map(\.title).joined(separator: "|"))

// MARK: what a drag commits, per pivot

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

/// Three cubes at 0, 4 and 10 on X: the median is 4.667 and the bounds centre
/// is 5.0, so a pivot that reads the wrong one shows.
func spread() -> (BKScene, [BKObject]) {
    let s = BKScene(startupFile: false)
    let objects = [Float(0), 4, 10].map { x -> BKObject in
        let o = s.add(.cube)
        o.name = ["A", "B", "C"][[Float(0), 4, 10].firstIndex(of: x)!]
        o.location = SIMD3(x, 0, 0)
        return o
    }
    s.selection = Set(objects.map(\.id))
    s.activeID = objects.last!.id
    return (s, objects)
}

/// A quarter turn on the Z ring, measured on screen around its centre.
func turn(in scene: BKScene) -> String {
    let g = TransformGizmo.make(mode: .rotate, scene: scene, options: options,
                                camera: camera, size: size)!
    let centre = TransformGizmo.Projection(camera: camera, size: size).project(g.origin)!
    let session = TransformGizmo.beginSession(handle: .axis(2),
                                              at: CGPoint(x: centre.x + 100, y: centre.y),
                                              gizmo: g, scene: scene, camera: camera,
                                              size: size, options: options)
    let result = TransformGizmo.resolve(session, at: CGPoint(x: centre.x, y: centre.y + 100))!
    TransformGizmo.apply(result, session: session)
    return TransformGizmo.python(result, session: session)
}

func places(_ objects: [BKObject]) -> String {
    numbers(objects.flatMap { [$0.location.x, $0.location.y, $0.location.z, $0.rotation.z] })
}

for pivot in [TransformPivot.medianPoint, .boundingBoxCenter, .cursor, .activeElement,
              .individualOrigins] {
    let (s, objects) = spread()
    s.tools.pivot = pivot
    s.cursor = SIMD3(1.5, 0, -2)
    let name = pivot.bpyIdentifier
    emit("TURN_" + name, turn(in: s))
    emit("TURN_" + name + "_EXPECT", places(objects))
}

do {
    // Proportional editing in object mode: the far cube should follow the near
    // one part of the way, which only the operator's own arguments can do.
    let (s, _) = spread()
    s.tools.proportionalObjects = true
    s.tools.falloff = .smooth
    s.tools.size = 8
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options,
                                camera: camera, size: size)!
    let projection = TransformGizmo.Projection(camera: camera, size: size)
    let centre = projection.project(g.origin)!
    let tip = projection.project(g.origin + g.axes[2] * g.radius)!
    let session = TransformGizmo.beginSession(handle: .axis(2), at: centre, gizmo: g,
                                              scene: s, camera: camera, size: size,
                                              options: options)
    let result = TransformGizmo.resolve(session, at: tip)!
    emit("MOVE_PROPORTIONAL", TransformGizmo.python(result, session: session))
}

// MARK: - Preview against commit, drag by drag
//
// Each case below is a whole drag through the real session: begin, resolve,
// snap, preview. What is printed is the Python the release sends and the
// state the preview left on screen, so verify.py can run the first and hold
// Blender's result against the second.

func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

/// Objects named A, B, C… at `places`.
func objects(_ places: [SIMD3<Float>], selected: [Int], active: Int,
             cursor: SIMD3<Float> = .zero, parents: [(child: Int, parent: Int)] = []) -> (BKScene, [BKObject]) {
    let s = BKScene(startupFile: false)
    let made = places.enumerated().map { i, p -> BKObject in
        let o = s.add(.cube)
        o.name = String(UnicodeScalar(UInt8(65 + i)))
        o.location = p
        return o
    }
    // As the mirror reports Blender's `parent`.
    for (child, parent) in parents {
        made[child].parentName = made[parent].name
        made[child].dependencies = [made[parent].name]
    }
    s.selection = Set(selected.map { made[$0].id })
    s.activeID = made[active].id
    s.cursor = cursor
    return (s, made)
}

func setup(_ places: [SIMD3<Float>], selected: [Int], active: Int,
           cursor: SIMD3<Float> = .zero, parents: [(child: Int, parent: Int)] = []) -> String {
    json(["places": places.map { [$0.x, $0.y, $0.z] }, "selected": selected, "active": active,
          "cursor": [cursor.x, cursor.y, cursor.z], "parents": parents.map { [$0.child, $0.parent] }])
}

/// Each object's world matrix as drawn, columns 0…3, xyz: 12 numbers apiece.
func matrices(_ objects: [BKObject]) -> String {
    numbers(objects.flatMap { o -> [Float] in
        let m = o.modelMatrix
        return [m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz, m.columns.3.xyz]
            .flatMap { [$0.x, $0.y, $0.z] }
    })
}

/// One drag, snapped and previewed as MetalViewportView does it; the Python
/// its release sends.
func drag(_ mode: TransformGizmo.Mode, _ handle: TransformGizmo.Handle, in scene: BKScene,
          step: Float = 0.25,
          points: (TransformGizmo, TransformGizmo.Projection) -> (CGPoint, CGPoint)) -> String {
    var o = options
    o.snapIncrement = step
    let g = TransformGizmo.make(mode: mode, scene: scene, options: o, camera: camera, size: size)!
    let p = TransformGizmo.Projection(camera: camera, size: size)
    let (a, b) = points(g, p)
    let session = TransformGizmo.beginSession(handle: handle, at: a, gizmo: g, scene: scene,
                                              camera: camera, size: size, options: o)
    let result = TransformGizmo.snapped(TransformGizmo.resolve(session, at: b)!,
                                        session: session, at: b)
    TransformGizmo.apply(result, session: session)
    return TransformGizmo.python(result, session: session)
}

/// A fraction of the way out along an axis handle, on screen.
func along(_ g: TransformGizmo, _ p: TransformGizmo.Projection, _ axis: Int,
           _ f: CGFloat) -> CGPoint {
    let c = p.project(g.origin)!, t = p.project(g.origin + g.axes[axis] * g.radius)!
    return CGPoint(x: c.x + (t.x - c.x) * f, y: c.y + (t.y - c.y) * f)
}

/// Round the gizmo's centre on screen, from 0° to `degrees`.
func around(_ g: TransformGizmo, _ p: TransformGizmo.Projection,
            _ degrees: CGFloat) -> (CGPoint, CGPoint) {
    let c = p.project(g.origin)!, r: CGFloat = 110, a = degrees * .pi / 180
    return (CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
}

/// A drag across the screen, offset from the gizmo's centre.
func across(_ g: TransformGizmo, _ p: TransformGizmo.Projection,
            _ dx: CGFloat, _ dy: CGFloat) -> (CGPoint, CGPoint) {
    let c = p.project(g.origin)!
    return (CGPoint(x: c.x + 3, y: c.y + 2), CGPoint(x: c.x + 3 + dx, y: c.y + 2 + dy))
}

/// From 60 points out to `ratio` times as far, for a uniform scale.
func outward(_ g: TransformGizmo, _ p: TransformGizmo.Projection,
             _ ratio: CGFloat) -> (CGPoint, CGPoint) {
    let c = p.project(g.origin)!
    return (CGPoint(x: c.x + 48, y: c.y - 36), CGPoint(x: c.x + 48 * ratio, y: c.y - 36 * ratio))
}

/// Emits one object-mode case: its scene, its Python and its preview.
func objectCase(_ name: String, _ places: [SIMD3<Float>], selected: [Int], active: Int,
                cursor: SIMD3<Float> = .zero, parents: [(child: Int, parent: Int)] = [],
                configure: (BKScene) -> Void, run: (BKScene) -> String) {
    let (s, made) = objects(places, selected: selected, active: active, cursor: cursor, parents: parents)
    configure(s)
    emit(name + "_SETUP", setup(places, selected: selected, active: active, cursor: cursor, parents: parents))
    emit(name, run(s))
    emit(name + "_EXPECT", matrices(made))
}

// Snapping. Two cubes off the grid, so a raw drag and a snapped one differ,
// and so Increment (steps from the start) and Grid (onto the grid) differ too.
let offGrid: [SIMD3<Float>] = [SIMD3(0.1, 0.37, 0.45), SIMD3(4.3, -0.2, 0.45)]
func snapping(_ elements: Set<SnapElement>, target: SnapTarget = .median) -> (BKScene) -> Void {
    { s in
        s.tools.useSnap = true
        s.tools.elements = elements
        s.tools.target = target
    }
}
objectCase("SNAP_INC_AXIS", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.increment])) { s in
    drag(.translate, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.37)) }
}
objectCase("SNAP_GRID_AXIS", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.grid])) { s in
    drag(.translate, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.37)) }
}
objectCase("SNAP_BOTH_AXIS", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.increment, .grid])) { s in
    drag(.translate, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.37)) }
}
objectCase("SNAP_GRID_PLANE", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.grid])) { s in
    drag(.translate, .plane(2), in: s) { g, p in across(g, p, 57, -31) }
}
objectCase("SNAP_GRID_FREE", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.grid])) { s in
    drag(.translate, .screen, in: s) { g, p in across(g, p, 83, 41) }
}
objectCase("SNAP_GRID_ACTIVE", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.grid], target: .active)) { s in
    drag(.translate, .axis(1), in: s) { g, p in (along(g, p, 1, 1), along(g, p, 1, 1.61)) }
}
objectCase("SNAP_INC_ROTATE", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.increment])) { s in
    drag(.rotate, .axis(2), in: s) { g, p in around(g, p, 37) }
}
objectCase("SNAP_INC_SCALE", offGrid, selected: [0, 1], active: 1,
           configure: snapping([.increment])) { s in
    drag(.scale, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.37)) }
}
emit("SNAP_STEP", "0.25")

// One object scaled about the 3D cursor: the preview used to leave its
// location alone whenever only one object was selected, and the commit moved
// it away from the cursor.
objectCase("SCALE_ABOUT_CURSOR", [SIMD3(1, 0.5, 0)], selected: [0], active: 0,
           cursor: SIMD3(-1.5, 0, 2), configure: { $0.tools.pivot = .cursor }) { s in
    drag(.scale, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.45)) }
}

// Proportional editing in object mode: A is selected, B, C and D are in
// reach at three distances and E is out of it.
let neighbourhood: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2.2, 0.4, 0),
                                     SIMD3(0.6, 1.3, -0.5), SIMD3(7, 0, 0)]
var proportionalCases: [String] = []
for falloff in MeshEditor.ProportionalFalloff.allCases where falloff != .random {
    for (mode, handle) in [(TransformGizmo.Mode.translate, TransformGizmo.Handle.axis(2)),
                           (.rotate, .axis(2)), (.scale, .screen)] {
        let name = "PROP_OBJECT_\(falloff.bpyIdentifier)_\(mode)"
        proportionalCases.append(name)
        objectCase(name, neighbourhood, selected: [0], active: 0, configure: { s in
            s.tools.proportionalObjects = true
            s.tools.falloff = falloff
            s.tools.size = 3
            // Connected Only means nothing to objects; sent anyway, it must
            // not change the result.
            s.tools.connected = falloff == .smooth
        }) { s in
            switch mode {
            case .translate:
                return drag(mode, handle, in: s) { g, p in (along(g, p, 2, 1), along(g, p, 2, 1.6)) }
            case .rotate:
                return drag(mode, handle, in: s) { g, p in around(g, p, 70) }
            case .scale:
                return drag(mode, handle, in: s) { g, p in outward(g, p, 1.6) }
            }
        }
    }
}
// About the cursor, with two selected, so the neighbours turn about a point
// that is none of theirs.
for (mode, handle) in [(TransformGizmo.Mode.rotate, TransformGizmo.Handle.axis(2)),
                       (.scale, .axis(0))] {
    let name = "PROP_OBJECT_CURSOR_\(mode)"
    proportionalCases.append(name)
    objectCase(name, neighbourhood, selected: [0, 1], active: 1, cursor: SIMD3(-1, 2, 0.5),
               configure: { s in
                   s.tools.proportionalObjects = true
                   s.tools.falloff = .sphere
                   s.tools.size = 2.5
                   s.tools.pivot = .cursor
               }) { s in
        mode == .rotate
            ? drag(mode, handle, in: s) { g, p in around(g, p, -50) }
            : drag(mode, handle, in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.5)) }
    }
}
// Parent chains: P is A's parent, C is A's child and G is C's, N is
// unrelated and NC its child. Moved by A, each child is carried by its parent
// on top of its own share, and P, A's parent, gets none (all measured in 5.2.1
// headless).
let family: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 2, 0.5),
                              SIMD3(0, -1, 0), SIMD3(0, -2.5, 0), SIMD3(4, 4, 0)]
let lineage: [(child: Int, parent: Int)] = [(0, 1), (2, 0), (3, 2), (5, 4)]
var familyCases: [String] = []
for (mode, handle) in [(TransformGizmo.Mode.translate, TransformGizmo.Handle.axis(2)),
                       (.rotate, .axis(2)), (.scale, .screen)] {
    let name = "FAMILY_PROPORTIONAL_\(mode)"
    familyCases.append(name)
    objectCase(name, family, selected: [0], active: 0, parents: lineage, configure: { s in
        s.tools.proportionalObjects = true
        s.tools.falloff = .linear
        s.tools.size = 3
    }) { s in
        switch mode {
        case .translate: return drag(mode, handle, in: s) { g, p in (along(g, p, 2, 1), along(g, p, 2, 1.6)) }
        case .rotate:    return drag(mode, handle, in: s) { g, p in around(g, p, 40) }
        case .scale:     return drag(mode, handle, in: s) { g, p in outward(g, p, 1.4) }
        }
    }
}
// A and its child C both selected: Blender deselects C for the transform
// (BA_WAS_SEL), so C only follows A. Through Individual Origins each one
// turns about its own origin and C is carried by A as well.
for pivot in [TransformPivot.medianPoint, .individualOrigins] {
    let name = "FAMILY_SELECTED_\(pivot.bpyIdentifier)"
    familyCases.append(name)
    objectCase(name, family, selected: [0, 2], active: 0, parents: lineage,
               configure: { $0.tools.pivot = pivot }) { s in
        drag(.rotate, .axis(2), in: s) { g, p in around(g, p, 50) }
    }
}
emit("FAMILY_CASES", familyCases.joined(separator: " "))

// Affect Only Parents and Origins: the family again, A moved, turned and
// scaled with each on. What is compared is where each object's geometry is
// drawn — Affect Only Origins moves an origin and not the geometry, so a
// matrix alone cannot say whether the preview was right.
func drawnBounds(_ objects: [BKObject]) -> String {
    numbers(objects.flatMap { o -> [Float] in
        let m = o.modelMatrix
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for v in o.mesh.vertices {
            let w = (m * SIMD4(v.position, 1)).xyz
            lo = simd_min(lo, w); hi = simd_max(hi, w)
        }
        return [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z]
    })
}
var affectCases: [String] = []
for (flag, set) in [("SKIP_CHILDREN", { (s: BKScene) in s.tools.affectOnlyParents = true }),
                    ("DATA_ORIGIN", { (s: BKScene) in s.tools.affectOnlyOrigins = true }),
                    ("BOTH", { (s: BKScene) in s.tools.affectOnlyParents = true; s.tools.affectOnlyOrigins = true })] {
    for (mode, handle) in [(TransformGizmo.Mode.translate, TransformGizmo.Handle.axis(0)),
                           (.rotate, .axis(2)), (.scale, .screen)] {
        for selected in [[0], [0, 2]] {
            let name = "AFFECT_\(flag)_\(mode)_\(selected.count)"
            affectCases.append(name)
            let (s, made) = objects(family, selected: selected, active: 0, parents: lineage)
            set(s)
            emit(name + "_SETUP", setup(family, selected: selected, active: 0, parents: lineage))
            emit(name + "_TOOLS", json(["skip_children": s.tools.affectOnlyParents,
                                        "data_origin": s.tools.affectOnlyOrigins]))
            switch mode {
            case .translate: emit(name, drag(mode, handle, in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.6)) })
            case .rotate:    emit(name, drag(mode, handle, in: s) { g, p in around(g, p, 40) })
            case .scale:     emit(name, drag(mode, handle, in: s) { g, p in outward(g, p, 1.4) })
            }
            emit(name + "_EXPECT", drawnBounds(made))
        }
    }
}
emit("AFFECT_CASES", affectCases.joined(separator: " "))
emit("PROP_OBJECT_CASES", proportionalCases.joined(separator: " "))

// Individual Origins with proportional editing: the helper's per-object
// calls, held against this preview here and against desktop Blender in
// verify.py.
let islands: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(1, 0, 0), SIMD3(1.5, 1, 0)]
for (mode, handle) in [(TransformGizmo.Mode.rotate, TransformGizmo.Handle.axis(2)),
                       (.scale, .screen)] {
    objectCase("PROP_INDIVIDUAL_\(mode)", islands, selected: [0, 1], active: 1, configure: { s in
        s.tools.proportionalObjects = true
        s.tools.falloff = .linear
        s.tools.size = 2
        s.tools.pivot = .individualOrigins
    }) { s in
        mode == .rotate ? drag(mode, handle, in: s) { g, p in around(g, p, 55) }
                        : drag(mode, handle, in: s) { g, p in outward(g, p, 1.7) }
    }
}

// MARK: edit mode, on Blender's own meshes

let meshes = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [String: Any]]

func floats(_ any: Any?) -> [Float] { (any as! [NSNumber]).map(\.floatValue) }
func ints(_ any: Any?) -> [UInt32] { (any as! [NSNumber]).map { UInt32($0.intValue) } }

/// The fixture as the mirror would install it, in edit mode, with Blender's
/// selection report for `selected` — the device's own path to editTopology.
func editScene(_ fixture: String, selected: Set<Int>) -> (BKScene, BKObject) {
    let d = meshes[fixture]!
    let co = floats(d["co"])
    let m = floats(d["matrix"])
    let edges = ints(d["edges"])
    let vertices = stride(from: 0, to: co.count, by: 3).map {
        MeshVertex(SIMD3(co[$0], co[$0 + 1], co[$0 + 2]), SIMD3(0, 0, 1))
    }
    var mesh = MeshData(vertices: vertices, indices: ints(d["tris"]))
    ModifierStack.recomputeNormals(&mesh, welded: true)
    let s = BKScene(startupFile: false)
    let o = s.add(.cube)
    o.name = fixture
    o.setEvaluatedMesh(mesh)
    o.setMirroredTransform(simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]),
                                                    SIMD4(m[4], m[5], m[6], m[7]),
                                                    SIMD4(m[8], m[9], m[10], m[11]),
                                                    SIMD4(m[12], m[13], m[14], m[15]))))
    s.selection = [o.id]
    s.activeID = o.id
    s.setMode(.edit)
    let report = BlenderEditReport(
        selectMode: 1,
        vertexSelected: vertices.indices.map { selected.contains($0) ? 1 : 0 },
        trianglePolygons: ints(d["tri_poly"]),
        polygonSelected: Array(repeating: 0, count: (d["polygons"] as! NSNumber).intValue),
        edgeVertices: edges,
        edgeSelected: stride(from: 0, to: edges.count, by: 2).map {
            selected.contains(Int(edges[$0])) && selected.contains(Int(edges[$0 + 1])) ? 1 : 0
        })
    let mirrored = s.mirrorEditSelection(report, on: o)
    precondition(mirrored, "the fixture \(fixture) did not mirror as Blender's mesh")
    return (s, o)
}

/// The vertices nearest each of `points`, in the mesh's own space.
func nearest(_ fixture: String, to points: [SIMD3<Float>]) -> Set<Int> {
    let co = floats(meshes[fixture]!["co"])
    return Set(points.map { q in
        (0..<(co.count / 3)).min { a, b in
            simd_distance(SIMD3(co[3 * a], co[3 * a + 1], co[3 * a + 2]), q)
                < simd_distance(SIMD3(co[3 * b], co[3 * b + 1], co[3 * b + 2]), q)
        }!
    })
}

var editCases: [String] = []
/// `mirror` puts that Mirror modifier on the object on both sides: in the
/// mirror's stack here, as a record would, and in Blender by verify.py.
func editCase(_ name: String, _ fixture: String, selected: Set<Int>, mirror: Modifier? = nil,
              configure: (BKScene) -> Void, run: (BKScene) -> String) {
    let (s, o) = editScene(fixture, selected: selected)
    configure(s)
    var setup: [String: Any] = ["fixture": fixture, "selected": selected.sorted()]
    if let mirror {
        o.modifiers = [mirror]
        setup["mirror"] = ["axes": [mirror.mirrorX, mirror.mirrorY, mirror.mirrorZ],
                           "clip": mirror.mirrorClip, "merge_threshold": mirror.mergeThreshold]
    }
    editCases.append(name)
    emit(name + "_SETUP", json(setup))
    emit(name, run(s))
    emit(name + "_EXPECT", numbers(o.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
}

let picks: [String: [SIMD3<Float>]] = [
    "grid": [SIMD3(0, 0, 0), SIMD3(0.4, 0.2, 0)],
    "sphere": [SIMD3(0, 0, 1)],
    "cube": [SIMD3(1, 1, 1), SIMD3(0.5, 1, 1)],
]
let reach: [String: Float] = ["grid": 0.9, "sphere": 1.2, "cube": 1.6]
for fixture in ["grid", "sphere", "cube"] {
    let chosen = nearest(fixture, to: picks[fixture]!)
    for connected in [false, true] {
        for (mode, handle) in [(TransformGizmo.Mode.translate, TransformGizmo.Handle.axis(2)),
                               (.rotate, .axis(0)), (.scale, .screen)] {
            for falloff in [MeshEditor.ProportionalFalloff.smooth, .root] {
                let name = "EDIT_\(fixture)_\(connected ? "CONNECTED" : "NEAREST")_\(falloff.bpyIdentifier)_\(mode)"
                editCase(name, fixture, selected: chosen, configure: { s in
                    s.tools.proportionalEdit = true
                    s.tools.falloff = falloff
                    s.tools.size = reach[fixture]!
                    s.tools.connected = connected
                }) { s in
                    switch mode {
                    case .translate:
                        return drag(mode, handle, in: s) { g, p in (along(g, p, 2, 1), along(g, p, 2, 1.7)) }
                    case .rotate:
                        return drag(mode, handle, in: s) { g, p in around(g, p, 60) }
                    case .scale:
                        return drag(mode, handle, in: s) { g, p in outward(g, p, 1.8) }
                    }
                }
            }
        }
    }
}
// Snapping while editing, with and without proportional editing.
let gridPick = nearest("grid", to: picks["grid"]!)
editCase("EDIT_SNAP_INC", "grid", selected: gridPick,
         configure: snapping([.increment])) { s in
    drag(.translate, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, 1.43)) }
}
editCase("EDIT_SNAP_GRID", "grid", selected: gridPick, configure: { s in
    snapping([.grid])(s)
    s.tools.proportionalEdit = true
    s.tools.falloff = .linear
    s.tools.size = 0.8
}) { s in
    drag(.translate, .plane(2), in: s) { g, p in across(g, p, 47, -23) }
}
editCase("EDIT_SNAP_ROTATE", "grid", selected: gridPick,
         configure: snapping([.increment])) { s in
    drag(.rotate, .axis(1), in: s) { g, p in around(g, p, 33) }
}

// Mirror's Clipping. The grid's column at local x = 0 and a vertex 0.4 off
// it are selected, under a Mirror on X with Clipping on: Blender keeps the
// one on the plane and stops the other at it, for a move, a turn and a
// proportional move whose reach takes in the rest of the column. Each case
// also prints the same drag previewed without the modifier, so verify.py can
// show the case would catch a preview that ignored it.
var clipMirror = Modifier(kind: .mirror)
clipMirror.mirrorClip = true
var clipCases: [String] = []
func clipCase(_ name: String, configure: @escaping (BKScene) -> Void = { _ in },
              run: @escaping (BKScene) -> String) {
    let (plain, plainObject) = editScene("grid", selected: gridPick)
    configure(plain)
    _ = run(plain)
    emit(name + "_UNCLIPPED",
         numbers(plainObject.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
    clipCases.append(name)
    editCase(name, "grid", selected: gridPick, mirror: clipMirror, configure: configure, run: run)
}
clipCase("EDIT_CLIP_MOVE") { s in
    drag(.translate, .axis(0), in: s) { g, p in (along(g, p, 0, 1), along(g, p, 0, -1.2)) }
}
clipCase("EDIT_CLIP_ROTATE") { s in
    drag(.rotate, .axis(2), in: s) { g, p in around(g, p, 60) }
}
clipCase("EDIT_CLIP_PROPORTIONAL", configure: { s in
    s.tools.proportionalEdit = true
    s.tools.falloff = .smooth
    s.tools.size = 0.9
}) { s in
    drag(.translate, .axis(1), in: s) { g, p in (along(g, p, 1, 1), along(g, p, 1, 1.8)) }
}
emit("CLIP_CASES", clipCases.joined(separator: " "))
emit("EDIT_CASES", editCases.joined(separator: " "))

// MARK: - Snapping to geometry, onto Blender's own meshes
//
// Blender cannot snap headless, so what these hold down is the other half:
// that what the search found is geometry Blender has — a vertex it has, a
// point on one of its edges and not on a triangulation diagonal, a centre it
// computes — and that the move sent puts Blender's own Snap With point on it.
// The target is a fixture installed as the mirror installs it, loops and all.

func mirrored(_ fixture: String, into s: BKScene) -> BKObject {
    let d = meshes[fixture]!
    let co = floats(d["co"]), m = floats(d["matrix"])
    var mesh = MeshData(vertices: stride(from: 0, to: co.count, by: 3).map {
        MeshVertex(SIMD3(co[$0], co[$0 + 1], co[$0 + 2]), SIMD3(0, 0, 1))
    }, indices: ints(d["tris"]))
    ModifierStack.recomputeNormals(&mesh, welded: true)
    let o = s.add(.cube)
    o.name = fixture
    o.setEvaluatedMesh(mesh)
    o.setMirroredTransform(simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))))
    let loops = ints(d["loops"]), uvs = floats(d["uvs"])
    let seams: [UInt32] = []
    let installed = loops.withUnsafeBufferPointer { l in
        uvs.withUnsafeBufferPointer { u in
            seams.withUnsafeBufferPointer { e in
                SceneMirror.installUVs(mapName: "UVMap", triangleLoops: l, loopUVs: u, seams: e, on: o)
            }
        }
    }
    precondition(installed == true && !o.mesh.uvDiagonals.isEmpty, "\(fixture) took no loops")
    return o
}

/// A fixture's polygons as the mirror's triangles group them, in world space:
/// centre and corners, those facing the eye first, nearest first.
func facingPolygons(_ fixture: String, _ o: BKObject) -> [(centre: SIMD3<Float>, corners: [Int])] {
    let tris = ints(meshes[fixture]!["tris"]), polys = ints(meshes[fixture]!["tri_poly"])
    let m = o.modelMatrix
    let w = o.mesh.vertices.map { (m * SIMD4($0.position, 1)).xyz }
    var corners: [Int: [Int]] = [:], normal: [Int: SIMD3<Float>] = [:]
    for t in 0..<polys.count {
        let p = Int(polys[t])
        let a = Int(tris[3 * t]), b = Int(tris[3 * t + 1]), c = Int(tris[3 * t + 2])
        for v in [a, b, c] where !(corners[p]?.contains(v) ?? false) { corners[p, default: []].append(v) }
        normal[p] = simd_normalize(simd_cross(w[b] - w[a], w[c] - w[a]))
    }
    let eye = camera.eye
    return corners.keys.sorted().compactMap { p -> (SIMD3<Float>, [Int])? in
        let centre = corners[p]!.reduce(SIMD3<Float>.zero) { $0 + w[$1] } / Float(corners[p]!.count)
        return simd_dot(normal[p]!, simd_normalize(eye - centre)) > 0.3 ? (centre, corners[p]!) : nil
    }.sorted { simd_distance($0.0, eye) < simd_distance($1.0, eye) }
}

func vec(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
let geometryKinds: [GeometrySnap.Kind: String] = [.point: "point", .vertex: "vertex", .edge: "edge",
                                                   .edgeMidpoint: "edge_midpoint", .face: "face",
                                                   .faceMidpoint: "face_midpoint"]

/// One snapped drag through the real session. `aim` picks where the pointer
/// ends from what the session can snap onto, so the case is about a target
/// that is there; the hit printed is the session's own.
func geometryDrag(_ scene: BKScene, _ handle: TransformGizmo.Handle, kind: GeometrySnap.Kind,
                  from start: (TransformGizmo, TransformGizmo.Projection) -> CGPoint,
                  candidates: [SIMD3<Float>], offset: SIMD2<Float>) -> (python: String, hit: GeometrySnap.Hit) {
    let g = TransformGizmo.make(mode: .translate, scene: scene, options: options, camera: camera, size: size)!
    let p = TransformGizmo.Projection(camera: camera, size: size)
    let a = start(g, p)
    let session = TransformGizmo.beginSession(handle: handle, at: a, gizmo: g, scene: scene,
                                              camera: camera, size: size, options: options)
    let targets = session.geometry!.targets
    let end = candidates.lazy.compactMap { c -> SIMD2<Float>? in
        guard let s = targets.view.project(c) else { return nil }
        return targets.find(s + offset)?.kind == kind ? s + offset : nil
    }.first!
    let b = CGPoint(x: CGFloat(end.x), y: CGFloat(end.y))
    let (result, hit) = TransformGizmo.snapping(TransformGizmo.resolve(session, at: b)!, session: session, at: b)
    precondition(hit?.kind == kind, "the drag's own search found \(String(describing: hit))")
    TransformGizmo.apply(result, session: session)
    return (TransformGizmo.python(result, session: session), hit!)
}

func snapRecord(_ hit: GeometrySnap.Hit, with target: SnapTarget, handle: TransformGizmo.Handle,
                selected: [Int]? = nil, moved: Int? = nil) -> String {
    var record: [String: Any] = ["kind": geometryKinds[hit.kind]!, "location": vec(hit.location),
                                 "with": target.bpyIdentifier]
    switch handle {
    case .axis(let i):  record["constraint"] = ["axis", i]
    case .plane(let i): record["constraint"] = ["plane", i]
    case .screen:       record["constraint"] = ["free", -1]
    }
    if let moved { record["moved"] = moved }
    return json(record)
}

var geometryCases: [String] = []
let movers: [SIMD3<Float>] = [SIMD3(-4, 0.5, 0.3), SIMD3(-4.5, 3, -0.4)]
func geometryCase(_ name: String, places movers: [SIMD3<Float>] = movers, selected: [Int], active: Int,
                  elements: Set<SnapElement>,
                  with target: SnapTarget, handle: TransformGizmo.Handle, kind: GeometrySnap.Kind,
                  offset: SIMD2<Float> = SIMD2(3, -2), parent: (child: Int, parent: Int)? = nil,
                  candidates: (String, BKObject) -> [SIMD3<Float>]) {
    let (s, made) = objects(movers, selected: selected, active: active)
    if let parent {
        // As the mirror reports Blender's `parent`.
        made[parent.child].parentName = made[parent.parent].name
        made[parent.child].dependencies = [made[parent.parent].name]
    }
    let fixture = "cube"
    let t = mirrored(fixture, into: s)
    s.selection = Set(selected.map { made[$0].id })
    s.activeID = made[active].id
    s.tools.useSnap = true
    s.tools.elements = elements
    s.tools.target = target
    let start: (TransformGizmo, TransformGizmo.Projection) -> CGPoint
    switch handle {
    case .axis(let i):  start = { g, p in p.project(g.origin + g.axes[i] * g.radius)! }
    case .plane(let i): start = { g, p in
        p.project(g.origin + (g.axes[(i + 1) % 3] + g.axes[(i + 2) % 3]) * (g.radius * 0.42))! }
    case .screen:       start = { g, p in p.project(g.origin)! }
    }
    let (python, hit) = geometryDrag(s, handle, kind: kind, from: start,
                                     candidates: candidates(fixture, t), offset: offset)
    geometryCases.append(name)
    var setup = try! JSONSerialization.jsonObject(with: Data(
        setup(movers, selected: selected, active: active).utf8)) as! [String: Any]
    setup["target"] = fixture
    if let parent { setup["parent"] = [parent.child, parent.parent] }
    emit(name + "_SETUP", json(setup))
    emit(name, python)
    emit(name + "_EXPECT", matrices(made))
    emit(name + "_SNAP", snapRecord(hit, with: target, handle: handle))
}

func fixtureVertices(_ fixture: String, _ o: BKObject) -> [SIMD3<Float>] {
    let m = o.modelMatrix
    return o.mesh.vertices.map { (m * SIMD4($0.position, 1)).xyz }
        .sorted { simd_distance($0, camera.eye) < simd_distance($1, camera.eye) }
}
func polygonCentres(_ fixture: String, _ o: BKObject) -> [SIMD3<Float>] {
    facingPolygons(fixture, o).map(\.centre)
}

geometryCase("GEO_VERTEX_FREE", selected: [0, 1], active: 1, elements: [.vertex],
             with: .closest, handle: .screen, kind: .vertex, candidates: fixtureVertices)
// On a quad's centre, where both its diagonals cross: a search that took
// triangulation's diagonals for edges would land there.
geometryCase("GEO_EDGE_FREE", selected: [0], active: 0, elements: [.edge],
             with: .closest, handle: .screen, kind: .edge, offset: .zero, candidates: polygonCentres)
geometryCase("GEO_EDGE_AXIS", selected: [0], active: 0, elements: [.edge],
             with: .closest, handle: .axis(0), kind: .edge, offset: .zero, candidates: polygonCentres)
geometryCase("GEO_EDGE_MIDPOINT_FREE", selected: [0], active: 0, elements: [.edgeMidpoint],
             with: .median, handle: .screen, kind: .edgeMidpoint, offset: .zero, candidates: polygonCentres)
geometryCase("GEO_FACE_AXIS", selected: [0], active: 0, elements: [.face],
             with: .closest, handle: .axis(2), kind: .face, candidates: polygonCentres)
// Dropped straight down onto the fixture's top: the axis meets the face.
geometryCase("GEO_FACE_AXIS_ABOVE", places: [SIMD3(0.6, -0.3, 4.5)], selected: [0], active: 0,
             elements: [.face], with: .median, handle: .axis(2), kind: .face) { fixture, o in
    let m = o.modelMatrix
    let up = simd_normalize((m * SIMD4(0, 0, 1, 0)).xyz)
    return facingPolygons(fixture, o).filter { p in
        let w = p.corners.map { (m * SIMD4(o.mesh.vertices[$0].position, 1)).xyz }
        return abs(simd_dot(simd_normalize(simd_cross(w[1] - w[0], w[2] - w[0])), up)) > 0.99
    }.map(\.centre).sorted {
        simd_length(SIMD2($0.x - 0.6, $0.y + 0.3)) < simd_length(SIMD2($1.x - 0.6, $1.y + 0.3))
    }
}
geometryCase("GEO_FACE_FREE", selected: [0, 1], active: 1, elements: [.face],
             with: .active, handle: .screen, kind: .face, candidates: polygonCentres)
geometryCase("GEO_FACE_CENTRE_PLANE", selected: [0], active: 0, elements: [.faceMidpoint],
             with: .closest, handle: .plane(2), kind: .faceMidpoint, offset: SIMD2(4, 3),
             candidates: polygonCentres)
geometryCase("GEO_VERTEX_BEFORE_FACE", selected: [0], active: 0, elements: [.vertex, .face, .grid],
             with: .closest, handle: .screen, kind: .vertex, candidates: fixtureVertices)
// A moved with B as its child: the preview carries B, and Blender's commit
// has to put it in the same place.
geometryCase("GEO_PARENT_CARRIES_CHILD", selected: [0], active: 0, elements: [.vertex],
             with: .closest, handle: .screen, kind: .vertex, parent: (child: 1, parent: 0),
             candidates: fixtureVertices)
emit("GEO_CASES", geometryCases.joined(separator: " "))

// While editing: a selected vertex of the fixture onto the rest of it.
var geometryEditCases: [String] = []
func geometryEditCase(_ name: String, _ fixture: String, selecting point: SIMD3<Float>,
                      elements: Set<SnapElement>, handle: TransformGizmo.Handle, kind: GeometrySnap.Kind,
                      offset: SIMD2<Float> = SIMD2(2, 3), configure: (BKScene) -> Void = { _ in },
                      candidates: (String, BKObject, Int) -> [SIMD3<Float>]) {
    let chosen = nearest(fixture, to: [point])
    let (s, o) = editScene(fixture, selected: chosen)
    // The mirror sends the loops in edit mode too; installed here the same way.
    let d = meshes[fixture]!
    let loops = ints(d["loops"]), uvs = floats(d["uvs"]), seams: [UInt32] = []
    loops.withUnsafeBufferPointer { l in uvs.withUnsafeBufferPointer { u in seams.withUnsafeBufferPointer { e in
        _ = SceneMirror.installUVs(mapName: "UVMap", triangleLoops: l, loopUVs: u, seams: e, on: o) } } }
    s.tools.useSnap = true
    s.tools.elements = elements
    s.tools.target = .closest
    configure(s)
    let start: (TransformGizmo, TransformGizmo.Projection) -> CGPoint
    switch handle {
    case .axis(let i): start = { g, p in p.project(g.origin + g.axes[i] * g.radius)! }
    default:           start = { g, p in p.project(g.origin)! }
    }
    let (python, hit) = geometryDrag(s, handle, kind: kind, from: start,
                                     candidates: candidates(fixture, o, chosen.first!), offset: offset)
    geometryEditCases.append(name)
    emit(name + "_SETUP", json(["fixture": fixture, "selected": chosen.sorted()]))
    emit(name, python)
    emit(name + "_EXPECT", numbers(o.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
    emit(name + "_SNAP", snapRecord(hit, with: .closest, handle: handle, moved: chosen.first!))
}
/// The fixture's vertices other than the selected one and its neighbours,
/// nearest the eye first.
func otherVertices(_ fixture: String, _ o: BKObject, _ selected: Int) -> [SIMD3<Float>] {
    let m = o.modelMatrix
    let own = o.mesh.vertices[selected].position
    return o.mesh.vertices.filter { simd_distance($0.position, own) > 0.3 }
        .map { (m * SIMD4($0.position, 1)).xyz }
        .sorted { simd_distance($0, camera.eye) < simd_distance($1, camera.eye) }
}
func otherCentres(_ fixture: String, _ o: BKObject, _ selected: Int) -> [SIMD3<Float>] {
    facingPolygons(fixture, o).filter { !$0.corners.contains(selected) }.map(\.centre)
}
geometryEditCase("EDIT_GEO_VERTEX", "grid", selecting: .zero, elements: [.vertex],
                 handle: .screen, kind: .vertex, candidates: otherVertices)
geometryEditCase("EDIT_GEO_FACE_CENTRE", "grid", selecting: .zero, elements: [.faceMidpoint],
                 handle: .screen, kind: .faceMidpoint, candidates: otherCentres)
geometryEditCase("EDIT_GEO_EDGE_AXIS", "cube", selecting: SIMD3(1, 1, 1), elements: [.edge],
                 handle: .axis(1), kind: .edge, offset: .zero, candidates: otherCentres)
geometryEditCase("EDIT_GEO_FACE", "sphere", selecting: SIMD3(0, 0, 1), elements: [.face],
                 handle: .screen, kind: .face, candidates: otherCentres)
geometryEditCase("EDIT_GEO_PROPORTIONAL", "grid", selecting: .zero, elements: [.vertex],
                 handle: .screen, kind: .vertex, configure: { s in
                     s.tools.proportionalEdit = true
                     s.tools.falloff = .smooth
                     s.tools.size = 0.5
                 }, candidates: { f, o, v in
                     otherVertices(f, o, v).filter { simd_distance($0, (o.modelMatrix * SIMD4(o.mesh.vertices[v].position, 1)).xyz) > 0.9 }
                 })
emit("GEO_EDIT_CASES", geometryEditCases.joined(separator: " "))

// MARK: - Auto Merge, as the scene holds it

// A grid vertex snapped onto another, with Auto Merge on and off: the preview
// welds by the scene's `use_mesh_automerge` and `double_threshold`, and
// Blender's commit has to make the same mesh. And one stopped 0.01 short of
// its neighbour: 0.02, the threshold the preview used to weld at, merged it,
// Blender's 0.001 does not.
var autoMergeCases: [String] = []
for on in [true, false] {
    let chosen = nearest("grid", to: [.zero])
    let (s, o) = editScene("grid", selected: chosen)
    s.tools.useSnap = true
    s.tools.elements = [.vertex]
    s.tools.target = .closest
    s.tools.autoMerge = on
    let start: (TransformGizmo, TransformGizmo.Projection) -> CGPoint = { g, p in p.project(g.origin)! }
    let (python, hit) = geometryDrag(s, .screen, kind: .vertex, from: start,
                                     candidates: otherVertices("grid", o, chosen.first!), offset: SIMD2(2, 3))
    let name = "AUTOMERGE_SNAP_\(on ? "ON" : "OFF")"
    autoMergeCases.append(name)
    emit(name + "_SETUP", json(["fixture": "grid", "selected": chosen.sorted(), "automerge": on,
                                "vertices": o.mesh.vertices.count]))
    emit(name, python)
    emit(name + "_EXPECT", numbers(o.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
    precondition(hit.kind == .vertex)
}
do {
    let chosen = nearest("grid", to: [.zero])
    let (s, o) = editScene("grid", selected: chosen)
    s.tools.autoMerge = true
    let v = chosen.first!
    let m = o.modelMatrix
    let here = (m * SIMD4(o.mesh.vertices[v].position, 1)).xyz
    // The neighbour nearest in the mesh's own space, reached in world space.
    let next = o.mesh.vertices.indices.filter { $0 != v }.min {
        simd_distance(o.mesh.vertices[$0].position, o.mesh.vertices[v].position)
            < simd_distance(o.mesh.vertices[$1].position, o.mesh.vertices[v].position)
    }!
    let there = (m * SIMD4(o.mesh.vertices[next].position, 1)).xyz
    let move = (there - here) * (1 - 0.01 / simd_distance(there, here))
    let g = TransformGizmo.make(mode: .translate, scene: s, options: options, camera: camera, size: size)!
    let session = TransformGizmo.beginSession(handle: .screen, at: .zero, gizmo: g, scene: s,
                                              camera: camera, size: size, options: options)
    TransformGizmo.apply(.translate(move), session: session)
    let name = "AUTOMERGE_NEAR_MISS"
    autoMergeCases.append(name)
    emit(name + "_SETUP", json(["fixture": "grid", "selected": chosen.sorted(), "automerge": true,
                                "vertices": o.mesh.vertices.count]))
    emit(name, TransformGizmo.python(.translate(move), session: session))
    emit(name + "_EXPECT", numbers(o.mesh.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }))
}
emit("AUTOMERGE_CASES", autoMergeCases.joined(separator: " "))

// MARK: - What moves with what

// The mirror's record of the relations fixture, as `_blenderkit_sync._relations`
// read it in meshes.py, installed as `bk_sync_relations` installs it; and for
// each object, what the Swift works out moves with it. verify.py holds that
// against Blender's depsgraph.
do {
    let records = meshes["relations"]! as! [String: [String: Any]]
    let s = BKScene(startupFile: false)
    for name in records.keys.sorted() {
        let o = s.add(.cube)
        o.name = name
    }
    for (name, record) in records {
        let parent = record["parent"] as! String
        let installed = SceneMirror.carryRelations(parent: parent, dependencies: record["depends"] as! [String],
                                                   named: name, pass: s.objects)
        precondition(installed, "no object \(name) to carry relations")
    }
    var moved: [String: [String]] = [:]
    for o in s.objects {
        moved[o.name] = s.objects.filter { s.dependents(of: [o.id]).contains($0.id) }.map(\.name).sorted()
    }
    emit("RELATIONS_MOVED", json(moved))
    let parents = Dictionary(uniqueKeysWithValues: s.objects.map { ($0.name, $0.parentName ?? "") })
    emit("RELATIONS_PARENTS", json(parents))
}

print(out.joined(separator: "\n#--\n"))
