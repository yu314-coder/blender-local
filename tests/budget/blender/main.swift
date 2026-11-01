import Foundation
import simd

// The vertex budget's strings for desktop Blender (scripts/run-budget-blender-check.sh):
// Add Modifier's rows by object type, and the lines the panels send for the
// edits round 4's reviews found going round the budget — each exactly as the
// app builds it, so the Blender check runs what the app runs.
//
//   dump calls     every block, `###name` then the Python, then `#--`

func block(_ name: String, _ body: String) {
    print("###\(name)")
    print(body)
    print("#--")
}

let cube = MeshBuilder.cube(size: 2)
for type in ["MESH", "CURVE", "FONT", "SURFACE"] {
    let rows = ModifierCatalog.rows(for: type).filter { !$0.asset }
    block("CATALOG \(type)", rows.map(\.type).joined(separator: "\n"))
    for row in rows {
        block("ADD \(type) \(row.type)", Bpy.addModifierRow(row, on: cube).joined(separator: "\n"))
    }
}

/// A row's edit: the lines `Bpy.modifierEdit` sends to change `m` as `change`
/// says, as every panel row sends them.
func edit(_ name: String, _ m: Modifier, _ change: (inout Modifier) -> Void) {
    var changed = m
    change(&changed)
    block("ROW \(name)", Bpy.modifierEdit(from: m, to: changed).joined(separator: "\n"))
}

let bevel = Modifier(kind: .bevel, name: "Bevel")
edit("bevel segments 12", bevel) { $0.segments = 12 }
let subsurf = Modifier(kind: .subdivision, name: "Subdivision")
edit("subdivision level 2", subsurf) { $0.levels = 2 }
edit("subdivision level 3", subsurf) { $0.levels = 3 }
var mirror = Modifier(kind: .mirror, name: "Mirror")
mirror.mirrorMerge = false
edit("mirror xyz", mirror) { $0.mirrorY = true; $0.mirrorZ = true }
edit("mirror xy", mirror) { $0.mirrorY = true }
let screw = Modifier(kind: .screw, name: "Screw")
edit("screw angle", screw) { $0.angle = 3.0 }
let array = Modifier(kind: .array, name: "Array")
edit("array count 64", array) { $0.count = 64 }
var hidden = Modifier(kind: .subdivision, name: "Subdivision")
hidden.showInViewport = false
edit("show subdivision", hidden) { $0.showInViewport = true }
let remesh = Modifier(kind: .remesh, name: "Remesh")
edit("remesh voxel 0.005", remesh) { $0.voxelSize = 0.005 }

for (key, value) in [("bevel_depth", "0.05"), ("bevel_resolution", "32"), ("resolution_u", "64"),
                     ("extrude", "0.5"), ("resolution_u", "4")] {
    block("DATA \(key)=\(value)", PointsBpy.set(key, to: value, object: "Curve"))
}
for (key, value) in [("size", 1.0), ("size", 4.0), ("size", 16.0), ("size", 1000.0), ("offset", 10.0),
                     ("offset", 3.4e38), ("bevel_depth", 3.4e38), ("offset_x", 3.4e38)] as [(String, Float)] {
    block("TEXT \(key)=\(value)", TextBpy.set(key, to: TextBpy.python(key, value), object: "Text"))
}

// Round 4's fix-round review (October 21): the paths it found with no price,
// each as the app sends it.
edit("subdivision level 4", subsurf) { $0.levels = 4 }
edit("array camera off", array) { $0.showInRender = false }
edit("array count 32", array) { $0.count = 32 }
block("JOIN", BpyBridge.performBody(for: LastOperator.join(), backup: false))
block("COPY MODIFIERS TO SELECTED", BpyBridge.performBody(for: LastOperator.copyModifiersToSelected(), backup: false))
block("LINK OBDATA", BpyBridge.performBody(for: LastOperator.makeLinksData("OBDATA"), backup: false))
block("LINK MODIFIERS", BpyBridge.performBody(for: LastOperator.makeLinksData("MODIFIERS"), backup: false))
var subdivide = LastOperator.mesh(.subdivide)
if let i = subdivide.parameters.firstIndex(where: { $0.key == "number_cuts" }) { subdivide.parameters[i].value = 10 }
block("EDIT SUBDIVIDE 10", BpyBridge.performBody(for: subdivide, backup: false))
block("CURVE SUBDIVIDE 4", PointsBpy.subdivide(cuts: 4).executed)
block("APPLY SCALE", Bpy.applyTransform(location: false, rotation: false, scale: true))
var quadriflow = LastOperator.quadriflowRemesh()
if let i = quadriflow.parameters.firstIndex(where: { $0.key == "target_faces" }) { quadriflow.parameters[i].value = 40000 }
block("QUADRIFLOW 40000", BpyBridge.performBody(for: quadriflow, backup: false))
let channels = TransformChannels(location: SIMD3(1, 0, 0), rotationMode: .euler("XYZ"),
                                 rotation: SIMD4(0, 0, 0, 0), scale: .one)
block("FIELD O location x 0.0001", channels.python(writing: channels.setting(.location, axis: 0, to: 0.0001), to: "O") ?? "")
block("FIELD O location x 0.9", channels.python(writing: channels.setting(.location, axis: 0, to: 0.9), to: "O") ?? "")
block("DIMENSION C X", ItemBpy.setDimension(of: "C", axis: 0, to: 1_000_000))

// Round 4's second fix-round review (October 21): the paths the gate holds,
// each as the app sends it (tests/budget/blender/verify.py, part 9).
var shear = LastOperator.shearObjects()
if let i = shear.parameters.firstIndex(where: { $0.key == "angle" }) { shear.parameters[i].value = atan(0.9999) }
block("SHEAR OBJECTS", BpyBridge.performBody(for: shear, backup: false))
block("PARENT KEEP OFF", BpyBridge.performBody(for: LastOperator.parent(keepTransform: false), backup: false))
block("CONSTRAINT ADD COPY_LOCATION", ConstraintsBpy.add("COPY_LOCATION", to: "O").body)
block("CONSTRAINT TARGET T", ConstraintsBpy.setTarget("T", of: "Copy Location", on: "O").body)
block("CONSTRAINT INFLUENCE 1", ConstraintsBpy.set("influence", of: "Copy Location", on: "O", to: "1.0",
                                                   undo: "Influence").body)
block("KEY THIN VALUE 1", GroupsBpy.setKeyValue("Thin", 1.0, editing: false, object: "B").executed)
block("KEY ACTIVE THIN", GroupsBpy.setActiveKey("Thin", object: "B").executed)
block("KEY SOLO ON", GroupsBpy.set(.showOnly, true, editing: false, object: "B").executed)
block("KEY MUTED UNMUTE", GroupsBpy.setKey("Muted", .mute, "False", editing: false, object: "B").executed)
// The gizmo's Scale commit in Edit Mode, as `TransformGizmo.commitOperator`
// builds it for a drag along X about the origin (`LastOperator.gizmo`).
func editResize(_ x: Float) -> String {
    let identity = matrix_identity_float3x3
    let commit = GizmoCommit(kind: .resize(values: SIMD3(x, 1, 1), constraint: "(True, False, False)"),
                             orientation: .global, axes: identity, viewAxes: identity, editing: true,
                             centre: SIMD3(0, 0, 0))
    return BpyBridge.performBody(for: LastOperator.gizmo(commit), backup: false)
}
block("EDIT RESIZE X 0.0001", editResize(0.0001))
block("EDIT RESIZE X 0.001", editResize(0.001))
block("EDIT RESIZE X 0.5", editResize(0.5))
// A curve's or a lattice's points in Edit Mode move through their own drag:
// the release's call is the gizmo's bare call (`TransformGizmo.python`), run
// after `PointsBpy.commitSetup` puts the points back where the drag found
// them (`BpyBridge.commitPointDrag`), each frame inside `PointsBpy.preview`.
func pointsResize(_ x: Float) -> String {
    let identity = matrix_identity_float3x3
    let commit = GizmoCommit(kind: .resize(values: SIMD3(x, 1, 1), constraint: "(True, False, False)"),
                             orientation: .global, axes: identity, viewAxes: identity, editing: true,
                             centre: SIMD3(0, 0, 0))
    return LastOperator.gizmo(commit).python
}
block("POINTS BEGIN DRAG Curve", PointsBpy.beginDrag(object: "Curve", followers: []))
block("POINTS BEGIN DRAG Lattice", PointsBpy.beginDrag(object: "Lattice", followers: ["Cube"]))
for x: Float in [0.001, 0.5] {
    block("POINTS PREVIEW RESIZE X \(x)", PointsBpy.preview(pointsResize(x)))
    block("POINTS COMMIT RESIZE X \(x)", PointsBpy.commitSetup + "\n" + pointsResize(x))
}
block("SEARCH RESIZE 30", OperatorCatalogue.runCommand(path: "transform.resize", json: #"{"value": [30, 30, 30]}"#))
block("SEARCH RESIZE 1.5", OperatorCatalogue.runCommand(path: "transform.resize", json: #"{"value": [1.5, 1.5, 1.5]}"#))
block("SEARCH RESIZE 100", OperatorCatalogue.runCommand(path: "transform.resize", json: #"{"value": [100, 100, 100]}"#))
block("EXTRUDE TO CURSOR", MeshMenuTools.extrudeToCursorPython(
    MeshPointer(eye: SIMD3(0, -20, 0), forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), orthographic: false,
                cursor: SIMD3(0, -5, 0))))
block("SEARCH TRANSFORM TRANSLATION", OperatorCatalogue.runCommand(
    path: "transform.transform", json: #"{"mode": "TRANSLATION", "value": [-0.9999, 0, 0, 0]}"#))
block("SEARCH CURVE DUPLICATE", OperatorCatalogue.runCommand(path: "curve.duplicate_move", json: "{}"))
block("SEARCH MBALL DUPLICATE", OperatorCatalogue.runCommand(path: "mball.duplicate_move", json: "{}"))
block("SEARCH MULTIRES SUBDIVIDE", OperatorCatalogue.runCommand(
    path: "object.multires_subdivide", json: #"{"modifier": "Multires", "mode": "CATMULL_CLARK"}"#))
block("ADD MONKEY", BpyBridge.performBody(for: LastOperator.add(.monkey, at: .zero), backup: false))
var circle = LastOperator.add(.circle, at: .zero)
if let i = circle.parameters.firstIndex(where: { $0.key == "vertices" }) { circle.parameters[i].value = 250 }
if let i = circle.parameters.firstIndex(where: { $0.key == "fill_type" }) {
    circle.parameters[i].value = 1  // N-Gon (Nothing, N-Gon, Triangle Fan)
}
block("ADD CIRCLE 250 NGON", BpyBridge.performBody(for: circle, backup: false))
block("DISSOLVE FACES", BpyBridge.performBody(for: LastOperator.mesh(.dissolveFaces), backup: false))
block("EDIT EXTRUDE", BpyBridge.performBody(for: LastOperator.mesh(.extrude), backup: false))
block("FILL", BpyBridge.performBody(for: LastOperator.mesh(.fillFace), backup: false))
block("JOIN CURVES", BpyBridge.performBody(for: LastOperator.join(), backup: false))

// The review of fix round 3 (October 29): the app's own loads, as it sends
// them — File ▸ New's, the launch's open of a recovery file that changed
// after the app wrote it, and the Open sheet's — with the file put in for
// `@PATH@` by the check (part 12t).
block("LOAD NEW", Bpy.newScene)
block("LOAD NEW FROM", Bpy.pricedLoad("bpy.ops.wm.read_homefile(filepath=@PATH@, load_ui=False)",
                                      words: "File ▸ New's startup file"))
block("LOAD RECOVERY CHANGED", Bpy.changedRecovery("bpy.ops.wm.open_mainfile(filepath=@PATH@, load_ui=False)"))
block("LOAD OPEN", Bpy.appLoad("bpy.ops.wm.open_mainfile(filepath=@PATH@, load_ui=False)"))
