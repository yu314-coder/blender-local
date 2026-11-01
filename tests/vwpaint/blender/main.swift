import Foundation
import simd

// What Weight Paint and Vertex Paint send, printed for a headless Blender to
// run: every string comes from `PaintModeBpy` and `BackendHistoryPython`, the
// code the app runs. `@NAME@` marks what the check fills in.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

emit("ENTER_WEIGHT", PaintModeBpy.enter(.weightPaint))
emit("ENTER_VERTEX", PaintModeBpy.enter(.vertexPaint))
emit("MODE_UNDO_WEIGHT", PaintModeBpy.modeUndo(.weightPaint))
emit("MODE_UNDO_VERTEX", PaintModeBpy.modeUndo(.vertexPaint))
emit("STROKE_NAME_WEIGHT", PaintModeBpy.strokeName(.weightPaint))
emit("STROKE_NAME_VERTEX", PaintModeBpy.strokeName(.vertexPaint))
emit("LEAVE", PaintModeBpy.leave)
emit("STATE", PaintModeBpy.stateQuery)
emit("BRUSHES", PaintModeBpy.brushesQuery)
emit("END", PaintModeBpy.end)
emit("ACTIVATE", PaintModeBpy.activate("@BRUSH@"))
for tool in PaintTool.allCases { emit("TOOL_\(tool.rawValue)", PaintModeBpy.setTool(tool)) }
emit("TOOL_LABELS", PaintTool.allCases.map(\.label).joined(separator: ","))
emit("SIZE_60", PaintModeBpy.setSize(60))
emit("STRENGTH_0.3", PaintModeBpy.setStrength(0.3))
emit("STRENGTH_1", PaintModeBpy.setStrength(1))
emit("SIZE_10", PaintModeBpy.setSize(10))
emit("WEIGHT_0.6", PaintModeBpy.setWeight(0.6))
emit("WEIGHT_PAST", PaintModeBpy.setWeight(7))
emit("COLOR_RED", PaintModeBpy.setColor(SIMD3(1, 0, 0)))
// Colours that differ between sRGB and scene linear: the picker's sRGB.
emit("COLOR_GREY", PaintModeBpy.setColor(SIMD3(0.5, 0.5, 0.5)))
emit("COLOR_MIXED", PaintModeBpy.setColor(SIMD3(0.2, 0.6, 0.9)))
emit("CANCEL", PaintModeBpy.cancel)
emit("BLEND_ADD", PaintModeBpy.setBlend("ADD"))
emit("BLEND_MIX", PaintModeBpy.setBlend("MIX"))

let camera = SculptCamera(target: SIMD3(0, 0, 0), distance: 5.5, azimuth: 0.6,
                          elevation: 0.4, fovY: 2 * atan(18.0 / 50.0), orthographic: false,
                          near: 0.05, far: 1000)
emit("CAMERA", camera.python)
emit("BEGIN", PaintModeBpy.begin(object: "@OBJECT@", camera: camera, viewWidth: 1100, viewHeight: 800)
        .replacingOccurrences(of: camera.python, with: "@CAMERA@"))
emit("CHUNK", PaintModeBpy.chunk([SculptPoint(x: 11.5, y: 22.25, pressure: 1, time: 0.5)])
        .replacingOccurrences(of: "(11.500, 22.250, 1.0000, 0.5000)", with: "@POINTS@"))
emit("HISTORY_PUSH", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false,
                                               forceCheckpoints: false))
emit("HISTORY_UNDO", BackendHistoryPython.step(-1))
emit("HISTORY_REDO", BackendHistoryPython.step(1))

print(out.joined(separator: "\n#--\n"))
