import Foundation
import CoreGraphics
import simd

// The Cursor tool's, the Measure tool's and Edit Mode's overlays' Swift half
// (CursorTool.swift, Ruler.swift, EditMeasure.swift, BlenderUnits.swift): the
// records, the calls, the hits on the mirror, the drag, the ruler's picks and
// points, the label positions and text. What Blender makes of the calls, and
// whether the strings are Blender's, is scripts/run-measure-blender-check.sh.
//
//     scripts/run-measure-tests.sh

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "\n        " + detail()))
    if !ok { failures += 1 }
}
func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool { simd_distance(a, b) <= eps }

/// A cube of side 2 as the mirror hands it over, through `matrix`.
func cube(_ name: String = "Cube", matrix: simd_float4x4 = matrix_identity_float4x4) -> BKObject {
    let p: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
                             SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
    // Counter-clockwise seen from outside, as Blender's faces wind.
    let quads: [[UInt32]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
    var indices: [UInt32] = []
    for q in quads { indices += [q[0], q[1], q[2], q[0], q[2], q[3]] }
    let object = BKObject(name: name, kind: .cube)
    object.setEvaluatedMesh(MeshData(vertices: p.map { MeshVertex($0, normalize($0)) }, indices: indices))
    object.setMirroredTransform(matrix)
    return object
}

/// A view from the front, `distance` out, as the app's camera makes one:
/// Metal's clip space, z from 0 to 1.
func frontView(distance: Float = 10, orthographic: Bool = false, size: SIMD2<Float> = SIMD2(800, 600))
    -> (GeometrySnap.View, eye: SIMD3<Float>, forward: SIMD3<Float>) {
    let eye = SIMD3<Float>(0, -distance, 0)
    let forward = SIMD3<Float>(0, 1, 0)
    // look-at: x right, y up (world z), z back (world -y).
    let view = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, -distance), SIMD4(0, 0, 0, 1)])
    let aspect = size.x / size.y
    let proj: simd_float4x4
    if orthographic {
        let h: Float = 4, w = h * aspect, near: Float = -100, far: Float = 100
        proj = simd_float4x4(rows: [SIMD4(1 / w, 0, 0, 0), SIMD4(0, 1 / h, 0, 0),
                                    SIMD4(0, 0, -1 / (far - near), -near / (far - near)), SIMD4(0, 0, 0, 1)])
    } else {
        let f = 1 / tan(Float(0.35)), near: Float = 0.05, far: Float = 1000
        proj = simd_float4x4(rows: [SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                    SIMD4(0, 0, far / (near - far), near * far / (near - far)), SIMD4(0, 0, -1, 0)])
    }
    return (GeometrySnap.View(viewProjection: proj * view, size: size), eye, forward)
}

print("\n== the scene's units, as Blender writes them ==")
do {
    let m = UnitSettings.factory
    var adaptive = m; adaptive.lengthUnit = "ADAPTIVE"
    let cases: [(String, String)] = [
        (BlenderUnits.string(2, prec: 6, kind: .length, settings: m), "2 m"),
        (BlenderUnits.string(0.02, prec: 2, kind: .length, settings: m), "0.02 m"),
        (BlenderUnits.string(0, prec: 6, kind: .length, settings: m), "0 m"),
        (BlenderUnits.string(0.02, prec: 2, kind: .length, settings: adaptive), "2 cm"),
        (BlenderUnits.string(1234.5678, prec: 2, kind: .length, settings: adaptive), "1.2 km"),
        (BlenderUnits.string(1234.5678, prec: 2, kind: .length, settings: m), "1235 m"),
        (BlenderUnits.string(2.828427, prec: 2, kind: .length, settings: m), "2.8 m"),
        (BlenderUnits.string(Double.pi / 4, prec: 2, kind: .rotation, settings: m, scaled: false), "45°"),
        (BlenderUnits.string(4, prec: 3, kind: .area, settings: m), "4 m²"),
    ]
    for (got, want) in cases { check("\"\(want)\"", got == want, "got \"\(got)\"") }
    var radians = m; radians.rotation = .radians
    check("Radians: π/2 is \"1.6 rad\"",
          BlenderUnits.string(Double.pi / 2, prec: 2, kind: .rotation, settings: radians, scaled: false) == "1.6 rad")
    var centimetres = m; centimetres.scaleLength = 0.01; centimetres.lengthUnit = "CENTIMETERS"
    check("Unit Scale 0.01 with Centimeters: 2 is \"2 cm\" (the scale applied before the unit)",
          BlenderUnits.string(2, prec: 6, kind: .length, settings: centimetres) == "2 cm",
          BlenderUnits.string(2, prec: 6, kind: .length, settings: centimetres))
    check("…and not scaled when asked not to (`BKE_unit_value_as_string`)",
          BlenderUnits.string(2, prec: 6, kind: .length, settings: centimetres, scaled: false) == "200 cm")
    // Nanometers and picometers are under `#if 0` in unit.cc: a table with
    // them printed this as "10 pm".
    check("1e-11 m adaptively is \"0 m\", not picometers", BlenderUnits.string(1e-11, prec: 6, kind: .length,
                                                                                 settings: adaptive) == "0 m",
          BlenderUnits.string(1e-11, prec: 6, kind: .length, settings: adaptive))
    var feet = UnitSettings(system: .imperial, lengthUnit: "FEET", separate: true)
    check("Imperial, Separate Units: 1 ft 4 in", BlenderUnits.string(0.3048 + 4 * 0.0254, prec: 3, kind: .length,
                                                                      settings: feet) == "1' 4\"",
          BlenderUnits.string(0.3048 + 4 * 0.0254, prec: 3, kind: .length, settings: feet))
    feet.separate = false
    check("…and without: 1.33'", BlenderUnits.string(0.3048 + 4 * 0.0254, prec: 3, kind: .length, settings: feet)
          == "1.33'", BlenderUnits.string(0.3048 + 4 * 0.0254, prec: 3, kind: .length, settings: feet))
    let record = UnitSettings(record: "system=IMPERIAL;rotation=RADIANS;scale=0.5;length=INCHES;split=1;grid=2.0;snap_tool=DEFAULT")
    check("the units record reads back", record == UnitSettings(system: .imperial, rotation: .radians, scaleLength: 0.5,
                                                                  lengthUnit: "INCHES", separate: true, grid: 2))
    check("a broken units record is refused", UnitSettings(record: "system=METRIC;rotation=DEGREES;scale=nan;length=METERS;split=0;grid=1") == nil
          && UnitSettings(record: "system=OTHER;rotation=DEGREES;scale=1;length=METERS;split=0;grid=1") == nil)
    check("the overlays' precision follows the grid (conv_float)", BlenderUnits.overlayFormat(grid: 1) == "%.4g"
          && BlenderUnits.overlayFormat(grid: 0.01) == "%.6g" && BlenderUnits.overlayFormat(grid: 100) == "%.2g")
}

print("\n== the cursor's record ==")
do {
    let full = CursorState(record: "loc=1.0,2.0,3.0;quat=0.5,0.5,0.5,0.5;mode=QUATERNION;depth=0;orient=GEOM")
    check("a full record", full?.location == SIMD3(1, 2, 3) && full?.rotationMode == "QUATERNION"
          && full?.surfaceProject == false && full?.orientation == .geometry && full?.settingsKnown == true)
    let bare = CursorState(record: "loc=1.0,2.0,3.0;quat=1,0,0,0;mode=XYZ")
    check("a record without the settings (a pass off the main thread)", bare?.settingsKnown == false)
    let shown = CursorState(surfaceProject: false, orientation: .transform)
    let merged = bare!.merged(onto: shown)
    check("…keeps the settings shown and takes the cursor", merged.surfaceProject == false
          && merged.orientation == .transform && merged.location == SIMD3(1, 2, 3))
    check("…while a full record replaces them", full!.merged(onto: shown).orientation == .geometry)
    check("a record with a number that is not one is refused",
          CursorState(record: "loc=nan,2,3;quat=1,0,0,0;mode=XYZ;depth=1;orient=VIEW") == nil)
    check("an Orientation Blender does not have is refused",
          CursorState(record: "loc=1,2,3;quat=1,0,0,0;mode=XYZ;depth=1;orient=SIDEWAYS") == nil)
    check("Blender's names for the Orientation's items", CursorTool.Orientation.allCases.map(\.label)
          == ["None", "View", "Transform", "Geometry"]
          && CursorTool.Orientation.allCases.map(\.rawValue) == ["NONE", "VIEW", "XFORM", "GEOM"])
}

print("\n== a tap's hits on the mirror ==")
do {
    let (view, eye, forward) = frontView()
    let centre = SIMD2<Float>(400, 300)
    let objects = [cube()]
    let ray = CursorTool.ray(view, centre)!
    check("the line of sight from the middle of the view looks along the view",
          near(ray.direction, forward, 1e-5), "\(ray.direction)")
    let surface = CursorTool.surfaceHit(objects: objects, ray: ray)
    check("the face in front is met at y = -1, its normal towards the eye",
          surface.map { near($0.location, SIMD3(0, -1, 0), 1e-4) && near($0.normal, SIMD3(0, -1, 0)) } == true,
          "\(String(describing: surface))")
    // A sheared object: Blender carries the face's normal by the inverse
    // transpose, which keeps it square to the face; the matrix itself would
    // lean it with the shear.
    var shear = matrix_identity_float4x4
    shear.columns.1.x = 0.6          // x += 0.6 y
    let sheared = cube("Sheared", matrix: shear)
    let top = CursorTool.surfaceHit(objects: [sheared], ray: (SIMD3(0.3, 0.1, 5), SIMD3(0, 0, -1)))
    if let top {
        // The face's own directions in the world: x and the sheared y.
        let u = SIMD3<Float>(1, 0, 0), v = SIMD3<Float>(0.6, 1, 0)
        check("a sheared cube's top face normal is square to the face (the inverse transpose)",
              abs(simd_dot(top.normal, u)) < 1e-5 && abs(simd_dot(top.normal, v)) < 1e-5 && top.normal.z > 0.99,
              "\(top.normal)")
    } else {
        check("a sheared cube's top face is met", false)
    }
    let front = CursorTool.surfaceHit(objects: [sheared], ray: (SIMD3(0.1, -5, 0.2), SIMD3(0, 1, 0)))
    if let front {
        let u = SIMD3<Float>(1, 0, 0), w = SIMD3<Float>(0, 0, 1)
        let byMatrix = simd_normalize((shear * SIMD4(0, -1, 0, 0)).xyz)
        check("the sheared front face's normal is square to it, not the matrix's lean (\(byMatrix))",
              abs(simd_dot(front.normal, u)) < 1e-5 && abs(simd_dot(front.normal, w)) < 1e-5
              && simd_dot(front.normal, byMatrix) < 0.99, "\(front.normal)")
    } else {
        check("a sheared cube's front face is met", false)
    }
    // A mirrored object: the inverse transpose keeps the normal outward,
    // where the world cross product turns it round (the negative control).
    let mirrored = cube("Mirrored", matrix: simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1)))
    let side = CursorTool.surfaceHit(objects: [mirrored], ray: (SIMD3(-5, 0, 0.2), SIMD3(1, 0, 0)))
    check("a mirrored cube's face seen from -X has the normal -X (Blender's inverse transpose)",
          side.map { near($0.normal, SIMD3(-1, 0, 0)) } == true, "\(String(describing: side?.normal))")
    if let side {
        let m = mirrored.modelMatrix
        let w = mirrored.mesh.vertices.map { (m * SIMD4($0.position, 1)).xyz }
        // The triangle the ray met, as world positions: its cross product.
        var crossed: SIMD3<Float>?
        var t = 0
        while t + 2 < mirrored.mesh.indices.count {
            let a = w[Int(mirrored.mesh.indices[t])], b = w[Int(mirrored.mesh.indices[t + 1])], c = w[Int(mirrored.mesh.indices[t + 2])]
            if MeshPicker.rayTriangle(SIMD3(-5, 0, 0.2), SIMD3(1, 0, 0), a, b, c) != nil { crossed = simd_normalize(simd_cross(b - a, c - a)); break }
            t += 3
        }
        check("negative control: the world cross product points the other way", crossed.map { simd_dot($0, side.normal) < -0.99 } == true)
    }
    let wire = cube("Wire")
    wire.displaysWire = true
    check("an object drawn as wire is passed through", CursorTool.surfaceHit(objects: [wire], ray: ray) == nil)
    let bounds = cube("Bounds")
    bounds.displaysBounds = true
    check("…and one drawn as bounds", CursorTool.surfaceHit(objects: [bounds], ray: ray) == nil)

    let depth = CursorTool.depthHit(objects: objects, view: view, pointer: centre, forward: forward)
    check("Surface Project's depth over the cube is the face's", depth.map { near($0, SIMD3(0, -1, 0), 1e-4) } == true,
          "\(String(describing: depth))")
    // Just past the silhouette: nothing at the pixel, the cube within 2.
    guard let edge = view.project(SIMD3(1, -1, 0)) else { fatalError() }
    let past = SIMD2<Float>(edge.x + 1.5, 300)
    check("1.5 points past the side, nothing is met exactly", CursorTool.surfaceHit(objects: objects, ray: CursorTool.ray(view, past)!) == nil)
    let margin = CursorTool.depthHit(objects: objects, view: view, pointer: past, forward: forward)
    check("…and the margin finds the face's depth, on the pointer's own line",
          margin.map { abs($0.y + 1) < 1e-3 && $0.x > 1 } == true, "\(String(describing: margin))")
    check("8 points past it nothing is found", CursorTool.depthHit(objects: objects, view: view,
                                                                   pointer: SIMD2(edge.x + 8, 300), forward: forward) == nil)
    // The margin's rectangle is 2m a side (BLI_rcti_init_pt_radius, its far
    // edges left out): at margin 2 it reaches 2 to the left and 1 to the
    // right, and on the view's y (down) 1 up and 2 down.
    let two = CursorTool.marginOffsets(2)
    check("margin 2 reads 16 pixels, x from -2 to 1 and y (down) from -1 to 2",
          two.count == 16 && two.map(\.x).min() == -2 && two.map(\.x).max() == 1
          && two.map(\.y).min() == -1 && two.map(\.y).max() == 2, "\(two)")
    check("…margin 0 the pixel alone", CursorTool.marginOffsets(0) == [.zero])
    // So the cube 1.5 points to the left of the pointer is in reach at margin
    // 2 and one 1.5 points to the right is not (a symmetric square, the
    // control, would reach both).
    guard let leftSide = view.project(SIMD3(-1, -1, 0)) else { fatalError() }
    check("the side 1.5 points to the left is found",
          CursorTool.depthHit(objects: objects, view: view, pointer: SIMD2(leftSide.x - 1.5, 300), forward: forward) != nil)
    let rightOnly = cube("Right", matrix: simd_float4x4(translation: SIMD3(-1.2, 0, 0)) * simd_float4x4(diagonal: SIMD4(0.2, 1, 1, 1)))
    guard let rEdge = view.project(SIMD3(-1.4, -1, 0)) else { fatalError() }
    let reach = CursorTool.depthHit(objects: [rightOnly], view: view, pointer: SIMD2(rEdge.x - 1.5, 300), forward: forward)
    check("a face 1.5 points to the right is still found, at margin 4 (its depth is the face's)",
          reach.map { abs($0.y + 1) < 1e-3 } == true, "\(String(describing: reach))")
}

print("\n== the calls a tap and a drag make ==")
do {
    let view = CursorTool.View(eye: SIMD3(0, -10, 0), forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), orthographic: false,
                               center: .zero, axisAligned: true)
    let call = CursorTool.placePython(view: view, point: SIMD3(0.5, -0.25, 1), depth: SIMD3(0.5, -1, 1), surface: nil)
    check("the tap's call carries the view, the line, the depth and no surface",
          call == "import _blenderkit_cursor\n_blenderkit_cursor.place(eye=(0, -10, 0), forward=(0, 1, 0), up=(0, 0, 1), "
            + "ortho=False, point=(0.5, -0.25, 1), center=(0, 0, 0), axis_view=True, depth=(0.5, -1, 1), surface=None)",
          call ?? "nil")
    check("a view that is not a number makes no call",
          CursorTool.placePython(view: CursorTool.View(eye: SIMD3(.nan, 0, 0), forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1),
                                                       orthographic: false, center: .zero), point: .zero, depth: nil,
                                 surface: nil) == nil)
    check("the settings' call", CursorTool.settingsPython(surfaceProject: false, orientation: .geometry)
          == "import _blenderkit_cursor\n_blenderkit_cursor.set_settings(use_depth=False, orientation='GEOM')")
    check("the drag's call is Blender's translate of the cursor",
          CursorTool.dragPython(from: SIMD3(1, 1, 1), to: SIMD3(2, 0.5, 1))
            == "bpy.ops.transform.translate(value=(1, -0.5, 0), orient_type='GLOBAL', snap=False, cursor_transform=True, release_confirm=True)",
          CursorTool.dragPython(from: SIMD3(1, 1, 1), to: SIMD3(2, 0.5, 1)) ?? "nil")
    check("its step is Blender's (Move)", CursorTool.dragUndo == "Move")
    check("the line point is as far out as the view's centre",
          near(CursorTool.linePoint((SIMD3(0, -9.95, 0), SIMD3(0, 1, 0)), center: .zero), SIMD3(0, 0, 0), 1e-5))

    // The drag: in the view's plane through the cursor, or onto the snap.
    let (snapView, eye, forward) = frontView()
    guard let start = snapView.project(SIMD3(0, -3, 0)) else { fatalError() }
    let moved = CursorTool.dragTarget(start: SIMD3(0, -3, 0), pointer: start + SIMD2(80, 0), view: snapView, eye: eye,
                                      forward: forward, orthographic: false, snap: nil)
    check("unsnapped, the cursor stays at its depth", moved.map { abs($0.location.y + 3) < 1e-4 && $0.location.x > 0.1 } == true,
          "\(String(describing: moved?.location))")
    let targets = GeometrySnap.Targets(objects: [cube()], view: snapView, elements: [.vertex], excludedObjects: [])
    guard let corner = snapView.project(SIMD3(1, -1, 1)) else { fatalError() }
    let snapped = CursorTool.dragTarget(start: SIMD3(-2, -3, 2), pointer: corner + SIMD2(3, 2), view: snapView, eye: eye,
                                        forward: forward, orthographic: false, snap: targets)
    // The first build put the cursor at the move itself, (3, 2, -1) here.
    check("snapped to a vertex, the cursor is on it (not at the move)",
          snapped.map { near($0.location, SIMD3(1, -1, 1)) && $0.hit?.kind == .vertex } == true,
          "\(String(describing: snapped))")

    // Geometry where Blender's snap meets a mesh the mirror does not hold —
    // under a Subdivision Surface evaluated last (`|subdivlast`): said, not
    // guessed. Under a Mirror or an Array it meets the mirror's mesh, as
    // round 4's review measured, and the tap places.
    let edited = cube("Edited")
    edited.modifiers = [Modifier(kind: .subdivision, name: "Subdivision")]
    edited.subdividesLastInEditMode = true
    let surface = CursorTool.Surface(location: .zero, normal: SIMD3(0, -1, 0), axes: matrix_identity_float3x3, object: "Edited")
    let refusal = CursorTool.geometryRefusal(surface, orientation: .geometry, edited: edited)
    check("Geometry under a last Subdivision Surface is refused in words, naming the modifier",
          refusal?.contains("Subdivision") == true && refusal?.contains("Geometry orientation") == true,
          refusal ?? "nil")
    check("…View there is not", CursorTool.geometryRefusal(surface, orientation: .view, edited: edited) == nil)
    check("…nor Geometry on another object", CursorTool.geometryRefusal(
        CursorTool.Surface(location: .zero, normal: SIMD3(0, -1, 0), axes: matrix_identity_float3x3, object: "Other"),
        orientation: .geometry, edited: edited) == nil)
    let mirrored = cube("Edited")
    mirrored.modifiers = [Modifier(kind: .mirror, name: "Mirror")]
    check("Geometry under a Mirror (Blender's snap meets the copy the mirror holds) places",
          CursorTool.geometryRefusal(surface, orientation: .geometry, edited: mirrored) == nil)
    check("…where the rule for picking Blender's elements, the old test, refused it (the control)",
          mirrored.editRegionRefusal(picking: "x", toDo: "y") != nil)
    let excluded = CursorTool.dragExcluded(edited: edited)
    check("a Cursor drag leaves the object out of its snap under a last Subdivision Surface, and says why",
          excluded.ids == [edited.id] && excluded.reason?.contains("Subdivision") == true, "\(excluded)")
    check("…and keeps it under a Mirror, and outside Edit Mode",
          CursorTool.dragExcluded(edited: mirrored).ids.isEmpty && CursorTool.dragExcluded(edited: nil).ids.isEmpty)
    check("Increment alone, Blender's factory Snap Target, is said not to move the cursor",
          CursorTool.snapNote(elements: [.increment]) == "(Snap Target Increment does not move the cursor here)",
          CursorTool.snapNote(elements: [.increment]) ?? "nil")
    check("…two of them in Blender's order; Vertex says nothing",
          CursorTool.snapNote(elements: [.grid, .increment, .vertex]) == "(Snap Target Increment and Grid do not move the cursor here)"
          && CursorTool.snapNote(elements: [.vertex, .face]) == nil,
          CursorTool.snapNote(elements: [.grid, .increment, .vertex]) ?? "nil")
    check("a Cursor drag sends no auto keying follow-up (it moves no object); an object move does",
          BpyAnimation.transformMode(of: CursorTool.dragPython(from: .zero, to: SIMD3(1, 0, 0))!) == nil
          && BpyAnimation.transformMode(of: "bpy.ops.transform.translate(value=(1, 0, 0))") == "TRANSLATE")
}

print("\n== the 3D cursor as Blender draws it ==")
do {
    let camera = OverlayView(view: simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, -10),
                                                        SIMD4(0, 0, 0, 1)]),
                             projection: simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                                              SIMD4(0, 0, -1, -0.1), SIMD4(0, 0, -1, 0)]),
                             size: CGSize(width: 800, height: 800))
    let at = SIMD3<Float>(0.5, 0, 0.25)
    let plain = CursorGlyph.lines(location: at, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), view: camera)
    check("three axes of four segments and a circle of twelve", plain.count == 2 * (3 * 4 + 12), "\(plain.count)")
    let unit = camera.worldPerPoint(at: at) * CursorGlyph.widgetUnit
    check("unturned, X's outer end is along world X, a widget unit out",
          near(plain[0].position, at + SIMD3(unit, 0, 0), 1e-5), "\(plain[0].position) unit \(unit)")
    let turned = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
    let rotated = CursorGlyph.lines(location: at, rotation: turned, view: camera)
    check("turned 90° about Z, X's outer end points along world Y (Blender draws `cursor->rotation()`)",
          near(rotated[0].position, at + SIMD3(0, unit, 0), 1e-5), "\(rotated[0].position)")
    check("…where the world-aligned drawing it replaces kept it on X (the control)",
          !near(rotated[0].position, at + SIMD3(unit, 0, 0), 1e-3))
    check("the axes in the theme's colours: X #FF3352, its negative end shaded to (195, 42, 65)",
          near(SIMD3(plain[0].colour.x, plain[0].colour.y, plain[0].colour.z), SIMD3(255, 51, 82) / 255, 1e-6)
          && near(SIMD3(plain[4].colour.x, plain[4].colour.y, plain[4].colour.z), SIMD3(195, 42, 65) / 255, 1e-6)
          && plain[2].colour == SIMD4(0, 0, 0, 1), "\(plain[0].colour) \(plain[4].colour) \(plain[2].colour)")
    let circle = plain[24...]
    check("the circle faces the viewer, half a unit round",
          circle.allSatisfy { abs(camera.distance($0.position) - camera.distance(at)) < 1e-4
                              && abs(simd_distance($0.position, at) - unit / 2) < 1e-4 })
    check("the rotation drawn is the one Blender holds",
          simd_distance(CursorGlyph.rotation(CursorState(rotation: turned)).vector, turned.vector) < 1e-6
          && CursorGlyph.rotation(CursorState(rotation: simd_quatf(vector: SIMD4(0, 0, 0, 0)))) == simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
}

print("\n== the ruler ==")
do {
    let units = UnitSettings.factory
    let ruler = Ruler(start: SIMD3(0, 0, 0), end: SIMD3(3, 4, 0))
    check("a ruler's length and text (6 figures)", ruler.length == 5 && ruler.text(units: units) == "5 m",
          ruler.text(units: units))
    var none = units; none.system = .none
    check("…without a unit system, the bare number", ruler.text(units: none) == "5.000000")
    let angle = Ruler(points: [SIMD3(1, 0, 0), .zero, SIMD3(0, 1, 0)], usesAngle: true)
    check("an angle ruler's text: 90°", angle.text(units: units) == "90°", angle.text(units: units))
    check("…without a unit system, 90.00°", angle.text(units: none) == "90.00°", angle.text(units: none))
    check("angle_v3v3v3 with a zero arm does not fail",
          RulerTool.angle(.zero, .zero, SIMD3(1, 0, 0)).isFinite)

    // Picks, in screen terms with an identity projection onto points.
    let project: (SIMD3<Float>) -> SIMD2<Float>? = { SIMD2($0.x, $0.y) }
    let rulers = [Ruler(start: SIMD3(100, 100, 0), end: SIMD3(300, 100, 0))]
    check("a press near an end takes the end", RulerTool.pick(rulers, at: SIMD2(104, 103), project: project).map { $0.part }
          == .point(0))
    check("a press on the line takes the line", RulerTool.pick(rulers, at: SIMD2(200, 108), project: project).map { $0.part }
          == .line)
    check("a press 13 points off takes nothing", RulerTool.pick(rulers, at: SIMD2(200, 113), project: project) == nil)
    var withAngle = rulers
    let drag = RulerTool.begin(&withAngle, at: SIMD2(150, 100), project: project, placeNew: { _ in nil })
    check("a press on the line makes it an angle ruler, dragging its middle point from the world origin's depth",
          drag?.point == 1 && drag?.fresh == true && drag?.start == .zero && withAngle[0].usesAngle
          && near(withAngle[0].points[1], SIMD3(150, 100, 0)), "\(String(describing: drag)) \(withAngle[0])")
    check("an angle ruler's line away from its points takes nothing (Blender makes a new ruler there)",
          RulerTool.pick(withAngle, at: SIMD2(225, 100), project: project) == nil)
    var fresh: [Ruler] = []
    let new = RulerTool.begin(&fresh, at: SIMD2(10, 10), project: project, placeNew: { _ in SIMD3(1, 2, 3) })
    check("a press on nothing starts a ruler at the placed point, dragging its far end",
          fresh.count == 1 && new?.point == 2 && new?.start == SIMD3(1, 2, 3) && fresh[0].points[0] == SIMD3(1, 2, 3))
    check("the angle point's factor is clamped", RulerTool.lineFactor(SIMD2(-50, 0), .zero, SIMD2(100, 0)) == 0
          && RulerTool.lineFactor(SIMD2(150, 0), .zero, SIMD2(100, 0)) == 1)

    // Placing: in the view's plane through the start, or with snapping the
    // snap, else the plane through the cursor facing Z.
    let (view, eye, forward) = frontView()
    let free = RulerTool.place(pointer: SIMD2(500, 250), depth: SIMD3(0, 2, 0), snap: nil, cursor: .zero, view: view,
                               eye: eye, forward: forward, orthographic: false)
    check("unsnapped, in the view's plane through the start", free.map { abs($0.point.y - 2) < 1e-4 } == true)
    let empty = GeometrySnap.Targets(objects: [cube()], view: view, elements: [.vertex], excludedObjects: [],
                                     radius: RulerTool.snapDistance)
    let floor = RulerTool.place(pointer: SIMD2(700, 550), depth: .zero, snap: empty, cursor: SIMD3(0, 0, -0.5), view: view,
                                eye: eye, forward: forward, orthographic: false)
    check("snapping with nothing in reach: on the plane through the cursor facing Z",
          floor.map { abs($0.point.z + 0.5) < 1e-4 && $0.hit == nil } == true, "\(String(describing: floor))")
    let (ortho, oeye, oforward) = frontView(orthographic: true)
    let emptyOrtho = GeometrySnap.Targets(objects: [cube()], view: ortho, elements: [.vertex], excludedObjects: [],
                                          radius: RulerTool.snapDistance)
    let along = RulerTool.place(pointer: SIMD2(750, 50), depth: .zero, snap: emptyOrtho, cursor: SIMD3(0, 0.75, 0),
                                view: ortho, eye: oeye, forward: oforward, orthographic: true)
    check("…an orthographic view along that plane: the view's plane through the cursor",
          along.map { abs($0.point.y - 0.75) < 1e-4 } == true, "\(String(describing: along))")
    check("Geometry is vertices, edges, faces and their centres; Default the scene's",
          RulerTool.elements(snapTool: "GEOMETRY", scene: [.increment]) == [.vertex, .edge, .face, .faceMidpoint, .edgeMidpoint]
          && RulerTool.elements(snapTool: "DEFAULT", scene: [.increment]) == [.increment])
    let edited = cube("Edited")
    edited.modifiers = [Modifier(kind: .subdivision, name: "Subdivision")]
    let excluded = RulerTool.excluded([edited], edited: edited)
    check("in Edit Mode a rebuilt edit mesh is left out of the ruler's snap, and the bar says so",
          excluded.ids == [edited.id] && excluded.refusal?.contains("Subdivision") == true)
    check("…and nothing is left out outside Edit Mode", RulerTool.excluded([edited], edited: nil).ids.isEmpty)

    // Ruler Remove's angle (RULERITEM_USE_ANGLE_ACTIVE) and a tap.
    var pair = [Ruler(start: SIMD3(100, 100, 0), end: SIMD3(300, 100, 0)),
                Ruler(start: SIMD3(100, 300, 0), end: SIMD3(300, 300, 0))]
    _ = RulerTool.begin(&pair, at: SIMD2(200, 100), project: project, placeNew: { _ in nil })
    check("dragging an angle out of a line marks its angle point as the part pressed", pair[0].usesAngle && pair[0].angleActive)
    var active: Int? = 0
    RulerTool.remove(&pair, active: &active)
    check("…so Ruler Remove takes the angle away and keeps the ruler, still active",
          pair.count == 2 && !pair[0].usesAngle && active == 0, "\(pair.count) \(pair[0].usesAngle) \(String(describing: active))")
    _ = RulerTool.begin(&pair, at: SIMD2(200, 100), project: project, placeNew: { _ in nil })
    _ = RulerTool.begin(&pair, at: SIMD2(103, 100), project: project, placeNew: { _ in nil })
    check("pressing an end clears the mark", pair[0].usesAngle && !pair[0].angleActive)
    RulerTool.remove(&pair, active: &active)
    check("…and Ruler Remove then takes the whole ruler", pair.count == 1 && active == nil)
    var kept: Int? = 0
    kept = RulerTool.tap(&pair, active: kept, at: SIMD2(600, 600), project: project)
    check("a tap on nothing leaves the active ruler (Blender's click adds nothing and keeps `item_active`)",
          kept == 0)
    check("…which the old tap, the pick's answer, cleared (the control)",
          RulerTool.pick(pair, at: SIMD2(600, 600), project: project)?.index == nil)
    check("a tap on a ruler makes it active", RulerTool.tap(&pair, active: nil, at: SIMD2(150, 302), project: project) == 0)

    // Another file in front of the reader takes the rulers with the old one.
    let scene = BKScene()
    scene.rulers = pair
    scene.activeRuler = 0
    let first = SceneMirror.carryRecord(kind: "file", name: "", record: "loads=1", pass: nil, screen: [])
    check("the file record is carried", first == .scene(.fileLoads(1)))
    SceneMirror.applyScene([.fileLoads(1)], to: scene)
    check("…the first one heard keeps what is there", scene.rulers.count == 1 && scene.activeRuler == 0)
    SceneMirror.applyScene([.fileLoads(1)], to: scene)
    check("…the same count again (a pass, an Undo's checkpoint load) keeps them", scene.rulers.count == 1)
    SceneMirror.applyScene([.fileLoads(2)], to: scene)
    check("…a new count (File ▸ New, Open, Recover) clears the rulers", scene.rulers.isEmpty && scene.activeRuler == nil)
    check("…and a record that is not a count is refused",
          SceneMirror.carryRecord(kind: "file", name: "", record: "loads=x", pass: nil, screen: []) == .failure)
    check("Blender's names", RulerTool.label == "Measure" && RulerTool.removeLabel == "Ruler Remove"
          && ActiveTool.measure.label == "Measure" && ActiveTool.cursor.label == "Cursor"
          && ActiveTool.cursor.isImplemented && ActiveTool.measure.isImplemented)
}

print("\n== Edit Mode's overlays ==")
do {
    let json = #"{"lengths":[[0,0,0,2,0,0,2.0],[0,0,0,0,2,0,2.0]],"edge_angles":[[0,0,0,2,0,0,1.5707963]],"areas":[[1,1,0,4.0]],"face_angles":[[0.2,0.2,0,1.5707963]],"stats":[1,2,4,8,4,12,1,6,12]}"#
    guard let m = EditMeasurements(json: "noise\n" + json) else { fatalError("did not parse") }
    check("the record parses, after any line Blender printed", m.lengths.count == 2 && m.areas.count == 1)
    check("a record with a value that is not a number is refused",
          EditMeasurements(json: #"{"lengths":[[0,0,0,1,0,0,"x"]],"edge_angles":[],"areas":[],"face_angles":[]}"#) == nil)
    check("the statistics' rows, as Blender's overlay writes them",
          m.statistics!.rows.map { "\($0.label) \($0.value)" }
            == ["Objects 1 / 2", "Vertices 4 / 8", "Edges 4 / 12", "Faces 1 / 6", "Triangles 12"],
          "\(m.statistics!.rows)")
    check("numbers grouped by thousands", EditMeasurements.grouped(1234567) == "1,234,567"
          && EditMeasurements.grouped(999) == "999" && EditMeasurements.grouped(1000) == "1,000")
    let units = UnitSettings.factory
    let identity = simd_float4x4(diagonal: SIMD4(0.1, 0.1, 0.1, 1))
    let all = MeasureOverlays(statistics: true, edgeLength: true, edgeAngle: true, faceArea: true, faceAngle: true)
    let labels = m.labels(units: units, viewProjection: identity, overlays: all)
    check("every label, in Blender's order", labels.map(\.kind) == [.length, .length, .edgeAngle, .area, .faceAngle])
    check("texts: 2 m, 90.000°, 4 m²", labels.map(\.text) == ["2 m", "2 m", "90.000°", "4 m²", "90.000°"],
          "\(labels.map(\.text))")
    check("with both edge texts on, the length 5 above and the angle 5 below",
          labels[0].raise == 5 && labels[2].raise == -5)
    let lengthsOnly = m.labels(units: units, viewProjection: identity, overlays: MeasureOverlays(edgeLength: true))
    check("…and alone, on the edge", lengthsOnly.count == 2 && lengthsOnly[0].raise == 0)
    var radians = units; radians.rotation = .radians
    check("angles in radians carry an r", EditMeasurements.angleText(1.5707963, units: radians) == "1.571r")
    var none = units; none.system = .none
    check("without a unit system, the grid's precision", EditMeasurements.lengthText(2.123456, units: none) == "2.123")
    // Clipping to the view's sides: the label goes to the middle of what is
    // in view.
    let vp = matrix_identity_float4x4
    let clipped = EditMeasurements.clip(SIMD3(-3, 0, 0), SIMD3(0.5, 0, 0), viewProjection: vp)
    check("an edge half out of view is cut at the side", clipped.map { near($0.0, SIMD3(-1, 0, 0)) && near($0.1, SIMD3(0.5, 0, 0)) } == true,
          "\(String(describing: clipped))")
    check("one wholly out of view has no label", EditMeasurements.clip(SIMD3(2, 0, 0), SIMD3(3, 0, 0), viewProjection: vp) == nil)
    let far = EditMeasurements(json: #"{"lengths":[[5,0,0,6,0,0,1.0]],"edge_angles":[],"areas":[],"face_angles":[]}"#)!
    check("…so it is left out of the labels", far.labels(units: units, viewProjection: vp, overlays: all).isEmpty)
    check("the read's call", MeasureOverlays(statistics: true, edgeLength: true).python(global: true)
          == "import _blenderkit_measure\nprint(_blenderkit_measure.edit_overlay(stats=True, edge_length=True, "
            + "edge_angle=False, face_area=False, face_angle=False, use_global=True))")
    // The view the read culls to, row by row: a translation's x is the first
    // row's last number, which column order would put at the 13th place.
    var moved = matrix_identity_float4x4
    moved.columns.3 = SIMD4(7, 8, 9, 1)
    let withView = MeasureOverlays(edgeLength: true).python(global: false, view: moved)
    check("…with the view, its 16 numbers row by row",
          withView.hasSuffix("use_global=False, view=(1, 0, 0, 7, 0, 1, 0, 8, 0, 0, 1, 9, 0, 0, 0, 1)))"), withView)
    var broken = moved
    broken.columns.0.x = .nan
    check("…and none when the view is not a number", !MeasureOverlays(edgeLength: true).python(global: false, view: broken)
            .contains("view="))
    let thinned = EditMeasurements(json: #"{"lengths":[[0,0,0,1,0,0,1.0],[0,0,0,0,1,0,1.0]],"edge_angles":[],"areas":[],"face_angles":[],"thinned":[48213,49],"culled":true}"#)
    check("a thinned read says how many were in view and which it kept",
          thinned?.thinning == EditMeasurements.Thinning(inView: 48213, every: 49, culled: true)
          && thinned?.thinningNote == "Measurement: 2 of the 48,213 values in view are drawn, one in every 49. "
             + "Zoom in or select less to read them all.", thinned?.thinningNote ?? "nil")
    let culledOnly = EditMeasurements(json: #"{"lengths":[],"edge_angles":[],"areas":[],"face_angles":[],"thinned":[700,1],"culled":true}"#)
    check("…a read culled to the view but whole there says nothing", culledOnly?.thinning?.culled == true
          && culledOnly?.thinningNote == nil)
    check("…and a whole read has no thinning", m.thinning == nil && m.thinningNote == nil)
    check("…a thinning that is not two counts is refused", EditMeasurements(
        json: #"{"lengths":[],"edge_angles":[],"areas":[],"face_angles":[],"thinned":[5]}"#) == nil)
    check("Blender's names", [MeasureOverlays.statisticsLabel, MeasureOverlays.measurementLabel,
                              MeasureOverlays.edgeLengthLabel, MeasureOverlays.edgeAngleLabel,
                              MeasureOverlays.faceAreaLabel, MeasureOverlays.faceAngleLabel]
          == ["Statistics", "Measurement", "Edge Length", "Edge Angle", "Face Area", "Face Angle"])
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
