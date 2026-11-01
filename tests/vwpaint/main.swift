import Foundation
import simd

// Weight Paint and Vertex Paint, the Swift half (PaintModeBpy.swift): the
// Python the paint header and the stroke send, the names they carry, and the
// state Blender answers with. What Blender does with them is
// scripts/run-vwpaint-blender-check.sh. Also the Cycles warning's strings
// (CyclesKernels), which a script render is armed with.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

print("== Blender's names ==")
// Blender 5.2.1's Weight Paint and Vertex Paint toolbars start Brush, Blur,
// Average, Smear (tests/names/reference/blender_toolbar.json).
let reference = ["Brush", "Blur", "Average", "Smear"]
check("the four tools carry the toolbar's names, in its order", PaintTool.allCases.map(\.label) == reference,
      "\(PaintTool.allCases.map(\.label))")
check("each is the app's toolbar tool of that name", PaintTool.allCases.allSatisfy { $0.tool.label == $0.label },
      "\(PaintTool.allCases.map { ($0.label, $0.tool.label) })")
check("and back", PaintTool.allCases.allSatisfy { PaintTool($0.tool) == $0 } && PaintTool(.select) == nil)
check("the mode steps are Blender's (measured: Weight Paint Mode, Vertex Paint Mode)",
      PaintModeBpy.modeUndo(.weightPaint) == "Weight Paint Mode" && PaintModeBpy.modeUndo(.vertexPaint) == "Vertex Paint Mode")
check("and the strokes' (Weight Paint, Vertex Paint)",
      PaintModeBpy.strokeName(.weightPaint) == "Weight Paint" && PaintModeBpy.strokeName(.vertexPaint) == "Vertex Paint")
check("the bar's rows are the mode menu's (Weight Paint, Vertex Paint)",
      PaintModeBpy.modes.map(\.label).sorted() == ["Vertex Paint", "Weight Paint"])
check("a stroke's failure is reported under its mode's name",
      BpyBridge.BrushStroke.paint(.weightPaint).name == "Weight Paint"
        && BpyBridge.BrushStroke.paint(.vertexPaint).name == "Vertex Paint"
        && BpyBridge.BrushStroke.sculpt.name == "Sculpt")

print("\n== the Python ==")
check("into the mode through _blenderkit_vwpaint, not a bare mode_set",
      PaintModeBpy.enter(.weightPaint) == "import _blenderkit_vwpaint\n_blenderkit_vwpaint.enter('WEIGHT_PAINT')"
        && PaintModeBpy.enter(.vertexPaint).hasSuffix("enter('VERTEX_PAINT')"), PaintModeBpy.enter(.weightPaint))
check("a Weight past Blender's range is sent as 1", PaintModeBpy.setWeight(7).hasSuffix("set_weight(1.0000)"),
      PaintModeBpy.setWeight(7))
check("a negative one as 0", PaintModeBpy.setWeight(-1).hasSuffix("set_weight(0.0000)"))
check("a colour is sent held to 0...1", PaintModeBpy.setColor(SIMD3(1.5, -0.2, 0.25))
        .hasSuffix("set_color((1.0000, 0.0000, 0.2500))"), PaintModeBpy.setColor(SIMD3(1.5, -0.2, 0.25)))
check("a Size of 0 is sent as 1", PaintModeBpy.setSize(0).hasSuffix("set_size(1)"))
check("each tool by Blender's identifier", PaintModeBpy.setTool(.blur).hasSuffix("set_tool('BLUR')"))
check("a brush name is quoted", PaintModeBpy.activate("Paint \"Hard\"").contains("activate(\"Paint \\\"Hard\\\"\")"),
      PaintModeBpy.activate("Paint \"Hard\""))
let camera = SculptCamera(target: SIMD3(0, 0, 0), distance: 5, azimuth: 0.5, elevation: 0.25, fovY: 0.7,
                          orthographic: false, near: 0.05, far: 1000)
let begin = PaintModeBpy.begin(object: "Ball", camera: camera, viewWidth: 1194, viewHeight: 730)
check("a stroke begins on the object with the 3D View's camera and size",
      begin.contains("_bk_vw.begin(\"Ball\", \(camera.python), (1194.000, 730.000), 'NORMAL')"), begin)
check("Ctrl's other direction is Blender's INVERT",
      PaintModeBpy.begin(object: "Ball", camera: camera, viewWidth: 1, viewHeight: 1, invert: true).contains("'INVERT'"))
let chunk = PaintModeBpy.chunk([SculptPoint(x: 1, y: 2, pressure: 0.5, time: 0.25)])
check("a chunk's points are (x, y, pressure, seconds)", chunk.contains("_bk_vw.chunk([(1.000, 2.000, 0.5000, 0.2500)])"),
      chunk)

print("\n== what Blender answers ==")
let line = """
    {"real": true, "mode": "WEIGHT_PAINT", "object": "Ball", "essentials": true, "brush": "Paint", "region": [1194, 730], "brush_type": "DRAW", "tool": "BRUSH", "stroke_method": "SPACE", "blend": "MIX", "blends": [["MIX", "Mix"], ["ADD", "Add"]], "size": 60, "strength": 0.3, "weight": 0.6, "group": "Group", "group_locked": false, "groups": 1, "undo_stack": 4}
    """
let state = PaintModeState.parse("Warning: something Blender printed first\n" + line)
check("the header's state is read past what Blender printed first", state?.brush == "Paint"
      && state?.size == 60 && state?.weight == 0.6 && state?.paintTool == .brush
      && state?.blends?.first == ["MIX", "Mix"] && state?.groupLocked == false, "\(String(describing: state))")
check("a region one point to a pixel scales by 1", state?.regionScale(viewWidth: 1194, viewHeight: 730) == 1)
check("a view larger than the region scales down", state?.regionScale(viewWidth: 2388, viewHeight: 730) == 0.5)
check("negative control: a line that is not the state reads as none",
      PaintModeState.parse("Traceback (most recent call last):") == nil)
// Vertex Paint's colour: the swatch's sRGB beside what Blender holds, scene
// linear (round 4's review: the swatch showed a colour Blender did not hold).
let colourLine = """
    {"real": true, "mode": "VERTEX_PAINT", "object": "Ball", "brush": "Paint Hard", "color": [0.5, 0.5, 0.5], "color_held": [0.214, 0.214, 0.214], "color_space": "SCENE_LINEAR"}
    """
let colourState = PaintModeState.parse(colourLine)
check("the colour is read as the swatch shows it and as Blender holds it",
      colourState?.color == [0.5, 0.5, 0.5] && colourState?.colorHeld == [0.214, 0.214, 0.214]
        && colourState?.colorSpace == "SCENE_LINEAR", "\(String(describing: colourState))")

print("\n== a chunk Blender refuses ==")
// It ends the stroke without replaying what the throttle held back, which
// would meet the same refusal and say it twice (round 4's review).
check("the stroke's cancel is _blenderkit_vwpaint's, which does not flush",
      PaintModeBpy.cancel.hasSuffix("print(json.dumps(_bk_vw.cancel()))") && PaintModeBpy.cancel != PaintModeBpy.end)
let inputSource = (try? String(contentsOfFile: "Sources/BlenderLocalUI/Viewport/SculptStrokeInput.swift",
                                encoding: .utf8)) ?? ""
let bridgeSource = (try? String(contentsOfFile: "Sources/BlenderLocalBridge/BpyBridge.swift", encoding: .utf8)) ?? ""
check("a refused chunk ends the stroke through finish(afterRefusal: true)",
      inputSource.contains("_ = finish(afterRefusal: true)")
        && inputSource.contains("lastEnd = bridge?.sculptEnd(afterRefusal: afterRefusal)"))
check("and the bridge sends cancel for a paint stroke then, end otherwise",
      bridgeSource.contains("(afterRefusal ? PaintModeBpy.cancel : PaintModeBpy.end)"))

print("\n== a script's first Cycles render ==")
check("the warning is the Render panel's, word for word", CyclesKernels.warning
      == "Cycles renders on the GPU. The first one builds its shaders, which takes a few minutes once; every render after that is quick. EEVEE needs no wait.")
check("the key is the Render panel's", CyclesKernels.builtKey == "bl_cycles_kernels_built")
check("a script that renders arms it", CyclesKernels.mayRender("import bpy\nbpy.ops.render.render(write_still=True)"))
check("one that does not, does not", !CyclesKernels.mayRender("import bpy\nbpy.ops.mesh.primitive_cube_add()"))
check("arming sends the warning", CyclesKernels.arm.contains("_blenderkit_cycles.arm(") && CyclesKernels.arm.contains("EEVEE needs no wait."))
check("a GPU render read back as True marks the kernels built", CyclesKernels.finishedOnGPU(["", "True"])
      && !CyclesKernels.finishedOnGPU(["False"]) && !CyclesKernels.finishedOnGPU([]))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
