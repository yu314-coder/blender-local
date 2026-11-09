import Foundation
import simd

// Grease Pencil: what the Swift sends Blender, printed for a headless Blender
// to run (verify.py) — Add ▸ Grease Pencil, Draw Mode in and out, strokes the
// app makes from samples through its own camera (with what they should come
// to), the Eraser's three modes, the Layers panel's rows, a new material, and
// Onion Skinning's settings.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("#-- \(name)\n\(body)") }
func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

for kind in ObjectAddition.GreasePencilKind.allCases {
    emit("ADD_\(kind.rawValue)", LastOperator.add(.greasePencil(kind), at: SIMD3(0, 0, 0)).executedPython)
}
emit("ENTER", GreasePencilBpy.enter)
emit("LEAVE", GreasePencilBpy.leave)
emit("STATE", GreasePencilBpy.stateQuery)

// The cameras: Front (orthographic, as Numpad 1 leaves it) and a perspective
// view from the side and above.
let size = SIMD2<Float>(1100, 800)
func view(_ c: ViewportCamera) -> GPView {
    GPView(viewProjection: c.viewProjection(aspect: size.x / size.y), size: size, forward: c.target - c.eye)
}
func literal(_ c: ViewportCamera) -> String {
    SculptCamera(target: c.target, distance: c.distance, azimuth: c.azimuth, elevation: c.elevation,
                 fovY: c.fovY, orthographic: c.isOrthographic, near: c.near, far: c.far, roll: c.roll).python
}
var front = ViewportCamera()
front.snap(to: .front)
front.distance = 8
var angled = ViewportCamera()
angled.azimuth = 0.6
angled.elevation = 0.45
angled.distance = 9
angled.target = SIMD3(0.3, -0.2, 0.4)

/// A stroke drawn with `brush` under `camera`, as `GreasePencilStrokeInput`
/// makes it: the Python the app sends and what it should leave.
func stroke(_ name: String, camera: ViewportCamera, samples: [GPSample], brush: GPBrush,
            plane: String = "VIEW", placement: String = "ORIGIN", toWorld: simd_float4x4 = matrix_identity_float4x4,
            object: String = "GPencil") {
    var state = GPDrawState()
    state.brush = brush
    state.plane = plane
    state.placement = placement
    let v = view(camera)
    let made = GreasePencilStroke.make(samples, state: state, toWorld: toWorld, view: v)
    emit(name, GreasePencilStroke.python(object: object, points: made))
    emit(name + "_EXPECT", json([
        "camera": literal(camera),
        "view": [size.x, size.y],
        "positions": made.map { [$0.position.x, $0.position.y, $0.position.z] },
        "world": made.map { [$0.world.x, $0.world.y, $0.world.z] },
        "radii": made.map(\.radius), "opacities": made.map(\.opacity),
        // Where each point was drawn, after the stroke's own smoothing: the
        // world points must project back here through Blender's own view.
        "screen": made.map { let p = v.project($0.world).point; return [p.x, p.y] },
    ]))
}

var pencil = GPBrush()       // Pencil: Size Unit Scene, Unprojected Size 0.06, pressure on
let line = (0...40).map { GPSample(SIMD2(300 + Float($0) * 12, 420), pressure: 0.5 + Float($0) / 80) }
stroke("STROKE_LINE", camera: front, samples: line, brush: pencil)
var pixels = GPBrush()
pixels.sceneUnit = false
pixels.size = 20
pixels.usePressureSize = false
pixels.usePressureStrength = false
let wave = (0...40).map { GPSample(SIMD2(350 + Float($0) * 10, 400 + 60 * sin(Float($0) / 6)), pressure: 1) }
stroke("STROKE_PIXELS", camera: angled, samples: wave, brush: pixels)
// Front (X-Z) on an object turned 0.5 about Z and moved to (1, 2, 0.5).
var turned = simd_float4x4(simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1)))
turned.columns.3 = SIMD4(1, 2, 0.5, 1)
stroke("STROKE_FRONT_PLANE", camera: angled, samples: wave, brush: pencil, plane: "AXIS_Y", toWorld: turned,
       object: "Turned")
stroke("STROKE_DOT", camera: front, samples: [GPSample(SIMD2(550, 400), pressure: 1)], brush: pencil)

// The Eraser, across the middle of the Front view.
let swipe: [SIMD2<Float>] = (0...20).map { SIMD2(300 + Float($0) * 25, 420) }
for mode in GPEraserMode.allCases {
    emit("ERASE_\(mode.rawValue)", GreasePencilStroke.erasePython(object: "GPencil", view: view(front), path: swipe,
                                                                  radius: 15, mode: mode.rawValue, strength: 1,
                                                                  activeLayerOnly: false))
}
emit("ERASE_CAMERA", json(["camera": literal(front), "view": [size.x, size.y]]))

// The Layers panel's rows.
emit("LAYER_ADD", GreasePencilBpy.layerAdd)
emit("LAYER_REMOVE", GreasePencilBpy.layerRemove)
emit("LAYER_UP", GreasePencilBpy.layerMove(up: true))
emit("LAYER_DOWN", GreasePencilBpy.layerMove(up: false))
emit("LAYER_ACTIVE", GreasePencilBpy.layerActive("GPencil", layer: "Layer"))
emit("LAYER_HIDE", GreasePencilBpy.layerSet("GPencil", layer: "Layer", "hide", "True"))
emit("LAYER_LOCK", GreasePencilBpy.layerSet("GPencil", layer: "Layer", "lock", "True"))
emit("LAYER_OPACITY", GreasePencilBpy.layerSet("GPencil", layer: "Layer", "opacity", "0.25"))
emit("LAYER_RENAME", GreasePencilBpy.layerSet("GPencil", layer: "Layer", "name", Bpy.quote("Ink")))
emit("LAYER_UNDO_NAMES", json(["hide": GreasePencilBpy.layerUndo("hide"), "lock": GreasePencilBpy.layerUndo("lock"),
                               "opacity": GreasePencilBpy.layerUndo("opacity"),
                               "use_onion_skinning": GreasePencilBpy.layerUndo("use_onion_skinning"),
                               "add": GreasePencilBpy.layerAddUndo, "remove": GreasePencilBpy.layerRemoveUndo,
                               "move": GreasePencilBpy.layerMoveUndo, "active": GreasePencilBpy.layerActiveUndo,
                               "mode": GreasePencilBpy.modeUndo, "stroke": GreasePencilBpy.strokeUndo,
                               "material": GreasePencilBpy.materialAddUndo,
                               "material_active": GreasePencilBpy.materialActiveUndo]))
emit("MATERIAL_ADD", GreasePencilBpy.materialAdd("GPencil", colour: SIMD3(1, 0.5, 0)))
emit("MATERIAL_ACTIVE", GreasePencilBpy.materialActive("GPencil", index: 0))
emit("MATERIAL_COLOUR", GreasePencilBpy.materialColour("GPencil", index: 0, colour: SIMD4(0, 0.5, 1, 1)))
emit("ONION_MODE", GreasePencilBpy.onionSet("GPencil", "onion_mode", "'ABSOLUTE'"))
emit("ONION_BEFORE", GreasePencilBpy.onionSet("GPencil", "ghost_before_range", "4"))
emit("AUTOKEY_ON", GreasePencilBpy.setTool("use_keyframe_insert_auto", true))
emit("ADDITIVE_ON", GreasePencilBpy.setTool("use_gpencil_draw_additive", true))
emit("BRUSH_SIZE", GreasePencilBpy.setBrush("unprojected_size", "0.1"))
emit("BRUSH_INK", GreasePencilBpy.activate("Ink Pen"))
emit("ONION_NAMES", json(["modes": GreasePencilBpy.onionModes.map { [$0.0, $0.1] },
                          "filters": GreasePencilBpy.onionFilters.map { [$0.0, $0.1] },
                          "eraser": GPEraserMode.allCases.map { [$0.rawValue, $0.label] },
                          "add": ObjectAddition.GreasePencilKind.allCases.map { [$0.rawValue, $0.label] },
                          "tools": [ActiveTool.gpDraw.label, ActiveTool.gpErase.label],
                          "mode": InteractionMode.drawGreasePencil.label]))
print(out.joined(separator: "\n"))
