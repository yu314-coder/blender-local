import Foundation
import simd
import CoreGraphics

// Every string the interface sends to add, adjust, select, move, turn, scale,
// delete and duplicate a camera, a light or an empty, printed for a headless
// Blender (verify.py) and for the simulator's shim (tests/camlight/shim/main.py)
// to run. For the transforms, where the drag's preview left the object is
// printed too, so Blender's result can be held against it.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func numbers(_ values: [Float]) -> String {
    values.map { String(format: "%.6f", $0) }.joined(separator: " ")
}
func performed(_ op: LastOperator) -> String {
    BpyBridge.script(push: nil, discardBackup: false, body: BpyBridge.performBody(for: op))
}

let size = CGSize(width: 1000, height: 800)
var camera = ViewportCamera()
camera.azimuth = 0.9
camera.elevation = 0.45
camera.distance = 12
let options = ViewportOptions()

// MARK: adding, as the Add menus perform it

let cursor = SIMD3<Float>(1, -2, 0.5)
emit("CURSOR", numbers([cursor.x, cursor.y, cursor.z]))

let addCamera = LastOperator.add(.camera, at: cursor, viewRotation: camera.objectRotation)
emit("ADD_CAMERA", performed(addCamera))
emit("ADD_CAMERA_LOG", addCamera.python)
let r = camera.objectRotation
emit("ADD_CAMERA_AXES", numbers([r.columns.0.x, r.columns.0.y, r.columns.0.z,
                                 r.columns.1.x, r.columns.1.y, r.columns.1.z,
                                 r.columns.2.x, r.columns.2.y, r.columns.2.z]))
var rerunCamera = addCamera
rerunCamera.subject = "@SUBJECT@"
rerunCamera.location = SIMD3<Double>(0, 0, 3)
emit("RERUN_CAMERA", rerunCamera.rerunPython)

for kind in LightDisplay.Kind.allCases {
    emit("ADD_LIGHT_\(kind.rawValue)", performed(LastOperator.add(.light(kind), at: cursor)))
}
var light = LastOperator.add(.light(.point), at: cursor)
light.subject = "@SUBJECT@"
light["radius"] = 2
emit("RERUN_LIGHT_RADIUS", light.rerunPython)
light["type"] = Double(LightDisplay.Kind.allCases.firstIndex(of: .area)!)
emit("RERUN_LIGHT_TYPE", light.rerunPython)

for kind in EmptyDisplay.Kind.allCases {
    emit("ADD_EMPTY_\(kind.rawValue)", performed(LastOperator.add(.empty(kind), at: cursor)))
}
var empty = LastOperator.add(.empty(.plainAxes), at: cursor)
empty.subject = "@SUBJECT@"
empty["radius"] = 0.25
empty["type"] = Double(EmptyDisplay.Kind.allCases.firstIndex(of: .cube)!)
emit("RERUN_EMPTY", empty.rerunPython)

// MARK: selecting, deleting, duplicating — as a tap, the Delete key and Duplicate send them

emit("TAP_SELECT", BpyBridge.selectionScript(Bpy.select("Camera")))
// What `BpyBridge.select` runs against the simulator's shim instead: the same
// selection, without the read-back, which only Blender's module needs.
emit("TAP_SELECT_RUN", BpyModeGuard.wrap(Bpy.select("Camera")))
emit("DELETE", BpyModeGuard.wrap(Bpy.deleteSelection(editing: false, mode: .vertex)))
emit("DUPLICATE", BpyModeGuard.wrap(Bpy.duplicate))
// Set Origin's and Apply's refusals, which the simulator's shim has to be able
// to reach: they read `obj.type` and a light's `data.type`.
emit("ORIGIN_GUARD", Bpy.originReach.guardPython)
emit("APPLY_GUARD", Bpy.applyReach.guardPython)
// finishBoxSelect's form, for the names a box over a camera and a light takes.
let boxed = ["Camera", "Point"]
emit("BOX_SELECT", ([Bpy.deselectAll] + boxed.map { "bpy.data.objects[\(Bpy.quote($0))].select_set(True)" }
                    + ["bpy.context.view_layer.objects.active = bpy.data.objects[\(Bpy.quote(boxed[0]))]"])
    .joined(separator: "\n"))

// MARK: transforms, with where the preview put things

func drag(_ mode: TransformGizmo.Mode, handle: TransformGizmo.Handle, in scene: BKScene,
          from: (CGPoint, TransformGizmo) -> CGPoint,
          to: (CGPoint, TransformGizmo) -> CGPoint) -> String {
    let g = TransformGizmo.make(mode: mode, scene: scene, options: options, camera: camera, size: size)!
    let centre = TransformGizmo.Projection(camera: camera, size: size).project(g.origin)!
    let session = TransformGizmo.beginSession(handle: handle, at: from(centre, g), gizmo: g,
                                              scene: scene, camera: camera, size: size,
                                              options: options)
    let result = TransformGizmo.resolve(session, at: to(centre, g))!
    TransformGizmo.apply(result, session: session)
    return TransformGizmo.python(result, session: session)
}

func along(_ axis: Int, _ reach: CGFloat) -> (CGPoint, TransformGizmo) -> CGPoint {
    { centre, g in
        let tip = TransformGizmo.Projection(camera: camera, size: size)
            .project(g.origin + g.axes[axis] * g.radius)!
        return CGPoint(x: centre.x + (tip.x - centre.x) * reach,
                       y: centre.y + (tip.y - centre.y) * reach)
    }
}

func rotationRows(_ o: BKObject) -> [Float] {
    let m = o.modelMatrix
    return (0..<3).flatMap { row in (0..<3).map { column in m[column][row] } }
}

do {
    let s = BKScene(startupFile: false)
    let o = s.addObject(.camera(CameraDisplay()), named: "Camera", at: SIMD3(1, 2, 0.5))
    o.rotation = SIMD3(0.3, -0.2, 0.9)
    emit("MOVE_CAMERA", drag(.translate, handle: .axis(0), in: s, from: along(0, 1), to: along(0, 2)))
    emit("MOVE_CAMERA_START", numbers([1, 2, 0.5, 0.3, -0.2, 0.9]))
    emit("MOVE_CAMERA_EXPECT", numbers([o.location.x, o.location.y, o.location.z]))
}
do {
    let s = BKScene(startupFile: false)
    let o = s.addObject(.light(LightDisplay()), named: "Point", at: SIMD3(-1, 0.5, 2))
    o.rotation = SIMD3(0.1, 0.2, 0.3)
    emit("ROTATE_LIGHT", drag(.rotate, handle: .screen, in: s,
                              from: { c, _ in CGPoint(x: c.x + 150, y: c.y + 10) },
                              to: { c, _ in CGPoint(x: c.x + 20, y: c.y + 140) }))
    emit("ROTATE_LIGHT_START", numbers([-1, 0.5, 2, 0.1, 0.2, 0.3]))
    emit("ROTATE_LIGHT_EXPECT", numbers(rotationRows(o)))
}
do {
    let s = BKScene(startupFile: false)
    var cube = EmptyDisplay(); cube.kind = .cube
    let o = s.addObject(.empty(cube), named: "Empty", at: .zero)
    o.rotation = SIMD3(0, 0, .pi / 4)
    emit("SCALE_EMPTY", drag(.scale, handle: .axis(0), in: s, from: along(0, 1), to: along(0, 2)))
    emit("SCALE_EMPTY_START", numbers([0, 0, 0, 0, 0, .pi / 4]))
    emit("SCALE_EMPTY_EXPECT", numbers([o.scale.x, o.scale.y, o.scale.z]))
}

print(out.joined(separator: "\n#--\n"))
