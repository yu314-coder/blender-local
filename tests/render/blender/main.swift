import Foundation
import simd

// Every string the Render panel and the camera menu items send, printed for a
// headless Blender (verify.py) to run — plus where the app says a few world
// points land in the picture, so Blender can be asked the same question.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func numbers(_ values: [Float]) -> String {
    values.map { String(format: "%.6f", $0) }.joined(separator: " ")
}

// A view that is not an axis view, so a mistake in any of the three angles
// shows up.
var view = ViewportCamera()
view.azimuth = 0.9
view.elevation = 0.45
view.distance = 12
view.target = SIMD3(0.5, -0.25, 0.75)

let width = 320, height = 180

emit("RENDER_CAMERA", RenderRequest(engine: .workbench, quality: .draft, width: width, height: height,
                                    source: .sceneCamera, output: "@OUT@").python)
emit("RENDER_VIEW", RenderRequest(engine: .workbench, quality: .draft, width: width, height: height,
                                  source: .view(view.renderCamera), output: "@OUT@").python)
emit("RENDER_CYCLES", RenderRequest(engine: .cycles, quality: .best, width: width, height: height,
                                    source: .sceneCamera, output: "@OUT@",
                                    deviceReport: "@DEVICE@").python)

// Where the app puts these points in the picture, as fractions across and up
// from the bottom left — what Blender's world_to_camera_view answers.
let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
                              SIMD3(0, 0, 1), SIMD3(-1.5, 0.5, 0.25)]
let viewProjection = view.viewProjection(aspect: Float(width) / Float(height))
var projected: [Float] = []
for p in points {
    let clip = viewProjection * SIMD4(p, 1)
    projected += [(clip.x / clip.w + 1) / 2, (clip.y / clip.w + 1) / 2]
}
emit("POINTS", points.flatMap { [$0.x, $0.y, $0.z] }.map { String(format: "%.6f", $0) }.joined(separator: " "))
emit("PROJECTED", numbers(projected))

// The camera menu items.
emit("SET_SCENE_CAMERA", Bpy.setSceneCamera("Camera"))
emit("AIM_CAMERA", Bpy.alignCameraToView("Camera", view.renderCamera))
emit("VIEW_ROTATION", numbers([view.renderCamera.rotation.x, view.renderCamera.rotation.y,
                               view.renderCamera.rotation.z]))
emit("VIEW_LOCATION", numbers([view.renderCamera.location.x, view.renderCamera.location.y,
                               view.renderCamera.location.z]))

// The property editor.
emit("LIGHT_ENERGY", Bpy.setObjectData("Light", "energy", 250))
emit("LIGHT_COLOUR", Bpy.setObjectData("Light", "color", colour: SIMD3(1, 0.5, 0.25)))
emit("LIGHT_TYPE", Bpy.setObjectData("Light", "type", choice: "SUN"))
emit("LIGHT_RADIUS", Bpy.setObjectData("Light", "shadow_soft_size", 0.35))
emit("CAMERA_LENS", Bpy.setObjectData("Camera", "lens", 35))
emit("CAMERA_CLIP_START", Bpy.setObjectData("Camera", "clip_start", 0.25))
emit("CAMERA_CLIP_END", Bpy.setObjectData("Camera", "clip_end", 250))
emit("CAMERA_TYPE", Bpy.setObjectData("Camera", "type", choice: "ORTHO"))
emit("CAMERA_ORTHO_SCALE", Bpy.setObjectData("Camera", "ortho_scale", 9))

print(out.joined(separator: "\n#--\n"))
