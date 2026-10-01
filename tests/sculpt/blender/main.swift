import Foundation
import simd

// What Sculpt Mode sends, printed for a headless Blender to run: every string
// comes from `SculptBpy` and `BackendHistoryPython`, the code the app runs, so
// the check puts the app's own calls through Blender. `@NAME@` marks what the
// check fills in (an object name, a camera, points).

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

emit("ENTER", BpyModeGuard.wrap(SculptBpy.enter))
emit("LEAVE", BpyModeGuard.wrap(SculptBpy.leave))
emit("STATE", SculptBpy.stateQuery)
emit("BRUSHES", SculptBpy.brushesQuery)
emit("END", SculptBpy.end)
emit("VOXEL_REMESH", SculptBpy.voxelRemesh)
emit("MULTIRES", SculptBpy.multiresSubdivide)
emit("FACE_SET_FROM_MASK", SculptBpy.faceSetFromMask)
emit("DYNTOPO_ON", SculptBpy.dyntopo(true))
emit("DYNTOPO_OFF", SculptBpy.dyntopo(false))
for action in SculptMaskAction.allCases { emit("MASK_\(action.rawValue)", SculptBpy.mask(action)) }
for mode in SculptFaceSetInit.allCases { emit("FACE_SETS_\(mode.rawValue)", SculptBpy.faceSetsInit(mode)) }
emit("SIZE_80", SculptBpy.setSize(80))
emit("STRENGTH_0.8", SculptBpy.setStrength(0.8))
emit("DETAIL_6", SculptBpy.setDetail(6))
emit("VOXEL_0.05", SculptBpy.setVoxelSize(0.05))
emit("ACTIVATE", SculptBpy.activate("@BRUSH@"))

// A stroke, as SculptStrokeInput sends it: a camera the 3D View could have,
// and points in its 3D View points. The check projects its own points with
// the ViewportCamera maths below and fills them in.
let camera = SculptCamera(target: SIMD3(0.1, -0.2, 0.3), distance: 5.5, azimuth: 0.6,
                          elevation: 0.4, fovY: 2 * atan(18.0 / 50.0), orthographic: false,
                          near: 0.05, far: 1000)
emit("CAMERA", camera.python)
emit("BEGIN", SculptBpy.begin(object: "@OBJECT@", camera: camera, viewWidth: 1100, viewHeight: 800,
                              mode: .normal)
        .replacingOccurrences(of: camera.python, with: "@CAMERA@"))
emit("BEGIN_INVERT", SculptBpy.begin(object: "@OBJECT@", camera: camera, viewWidth: 1100, viewHeight: 800,
                                     mode: .invert)
        .replacingOccurrences(of: camera.python, with: "@CAMERA@"))
emit("CHUNK", SculptBpy.chunk([SculptPoint(x: 11.5, y: 22.25, pressure: 1, time: 0.5)])
        .replacingOccurrences(of: "(11.500, 22.250, 1.0000, 0.5000)", with: "@POINTS@"))
emit("HISTORY_PUSH", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false,
                                               forceCheckpoints: false))
emit("HISTORY_UNDO", BackendHistoryPython.step(-1))
emit("HISTORY_REDO", BackendHistoryPython.step(1))

// Where the 3D View draws points, by ViewportCamera itself — the camera a
// stroke's points are measured against — for the check to find the same
// points in Blender's aimed region. As SculptStrokeInput builds its camera.
var projections: [String] = []
var cameras: [ViewportCamera] = []
var c1 = ViewportCamera(); c1.target = SIMD3(0.2, -0.1, 0.3); c1.distance = 5.5
cameras.append(c1)
var c2 = c1; c2.isOrthographic = true; cameras.append(c2)
var c3 = c1; c3.snap(to: .top); cameras.append(c3)
var c4 = c1; c4.azimuth = 2.5; c4.elevation = -0.9; c4.distance = 3.2; cameras.append(c4)
let size = SIMD2<Float>(1100, 800)
for camera in cameras {
    let sculptCamera = SculptCamera(target: camera.target, distance: camera.distance,
                                    azimuth: camera.azimuth, elevation: camera.elevation,
                                    fovY: camera.fovY, orthographic: camera.isOrthographic,
                                    near: camera.near, far: camera.far)
    let vp = camera.viewProjection(aspect: size.x / size.y)
    var rows: [String] = []
    for p in [SIMD3<Float>(0.3, 0.2, 0.9), SIMD3(-0.8, 0.1, 0.4), SIMD3(0.1, -0.9, -0.2), SIMD3(0.7, 0.7, 0)] {
        let clip = vp * SIMD4(p, 1)
        let x = (clip.x / clip.w + 1) / 2 * size.x
        let y = (1 - clip.y / clip.w) / 2 * size.y
        rows.append(String(format: "[%.6f, %.6f, %.6f, %.6f, %.6f]", p.x, p.y, p.z, x, y))
    }
    projections.append("{\"camera\": \"\(sculptCamera.python)\", \"points\": [\(rows.joined(separator: ", "))]}")
}
emit("PROJECTIONS", "[" + projections.joined(separator: ", ") + "]")

print(out.joined(separator: "\n#--\n"))
