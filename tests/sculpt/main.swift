import Foundation
import simd

// The Swift half of Sculpt Mode with Blender's brushes: the Python each
// control sends, what Blender's answers read as, when a stroke's points go,
// and the camera the strokes are aimed with. The Blender half, which puts
// these strings through Blender, is scripts/run-sculpt-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

print("The Python a stroke sends")

let camera = SculptCamera(target: SIMD3(0.25, -1.5, 2), distance: 11, azimuth: 0.6041,
                          elevation: 0.4909, fovY: 0.6911, orthographic: false, near: 0.05, far: 1000)
check("the camera is the dict _blenderkit_sculpt.begin reads, nine significant figures",
      camera.python == "dict(target=(0.25, -1.5, 2), distance=11, azimuth=0.604099989, "
        + "elevation=0.49090001, fov_y=0.691100001, ortho=False, near=0.0500000007, far=1000)",
      camera.python)
var ortho = camera; ortho.orthographic = true
check("orthographic says so", ortho.python.contains("ortho=True"))

let begin = SculptBpy.begin(object: "Ball \"2\" \\ x", camera: camera, viewWidth: 1100, viewHeight: 800.5,
                            mode: .invert)
check("begin names the object as a Python string, quotes and backslashes escaped",
      begin.contains(#"_bk_sculpt.begin("Ball \"2\" \\ x", "#), begin)
check("begin sends the view in points and Blender's stroke mode",
      begin.hasSuffix("(1100.000, 800.500), 'INVERT')))"), begin)
check("and prints its answer as one line of JSON", begin.hasPrefix("import json, _blenderkit_sculpt as _bk_sculpt\nprint(json.dumps("))
let chunk = SculptBpy.chunk([SculptPoint(x: 10, y: 20.125, pressure: 0.5, time: 0.25),
                             SculptPoint(x: 11, y: 21, time: 0.3)])
check("a chunk is its points: x, y, pressure, seconds",
      chunk.hasSuffix("_bk_sculpt.chunk([(10.000, 20.125, 0.5000, 0.2500), (11.000, 21.000, 1.0000, 0.3000)])))"),
      chunk)
check("a finger's pressure is 1", SculptPoint(x: 0, y: 0, time: 0).pressure == 1)
check("the modes are brush_stroke's", SculptStrokeMode.allCases.map(\.rawValue) == ["NORMAL", "INVERT", "SMOOTH"])

print("\nThe header's Python")

check("a brush is picked by its Essentials name", SculptBpy.activate("Clay Strips")
      == "import _blenderkit_sculpt\n_blenderkit_sculpt.activate(\"Clay Strips\")")
check("Size is whole pixels, at least one", SculptBpy.setSize(0).hasSuffix("set_size(1)")
      && SculptBpy.setSize(80).hasSuffix("set_size(80)"))
check("Strength is kept within what Blender takes", SculptBpy.setStrength(-2).hasSuffix("set_strength(0.0000)")
      && SculptBpy.setStrength(0.35).hasSuffix("set_strength(0.3500)"))
check("the mask menu sends Blender's flood fill modes",
      SculptMaskAction.allCases.map { SculptBpy.mask($0) }
        == ["CLEAR", "INVERT", "FILL"].map { "import _blenderkit_sculpt\n_blenderkit_sculpt.mask('\($0)')" })
check("Initialize Face Sets sends sculpt.face_sets_init's modes",
      SculptFaceSetInit.allCases.map(\.rawValue)
        == ["LOOSE_PARTS", "MATERIALS", "NORMALS", "UV_SEAMS", "CREASES", "SHARP_EDGES"])
check("the operations are undo steps named as Blender names them",
      [SculptBpy.dyntopoUndo, SculptBpy.voxelRemeshUndo, SculptBpy.multiresSubdivideUndo, SculptBpy.maskUndo]
        == ["Dynamic Topology Toggle", "Voxel Remesh", "Multires Subdivide", "Mask Flood Fill"])
check("Sculpt Mode is Blender's own mode_set, refused for what is not a mesh",
      SculptBpy.enter.contains("bpy.ops.object.mode_set(mode='SCULPT')")
        && SculptBpy.enter.contains("works on meshes"))
if let heavy = SculptBpy.enter.range(of: "_blenderkit_sculpt.refuse_heavy_multires()"),
   let set = SculptBpy.enter.range(of: "bpy.ops.object.mode_set(mode='SCULPT')") {
    check("and refused before Blender enters for a Multires too heavy to sculpt here",
          heavy.upperBound <= set.lowerBound)
} else {
    check("and refused before Blender enters for a Multires too heavy to sculpt here", false, SculptBpy.enter)
}
check("no bare-operator bracketing for the module's calls (they manage their own modes)",
      BpyModeGuard.requiredMode(for: SculptBpy.multiresSubdivide) == nil
        && BpyModeGuard.requiredMode(for: SculptBpy.mask(.fill)) == nil)

print("\nWhat Blender answers")

let stateText = """
Info: Loaded "brushes/essentials_brushes-mesh_sculpt.blend"
{"real": true, "essentials": true, "object": "Ball", "mode": "SCULPT", "brush": "Draw", "region": [1574, 954], "size": 100, "strength": 0.5, "unified_size": true, "unified_strength": false, "brush_type": "DRAW", "stroke_method": "SPACE", "spacing": 10, "direction": "ADD", "strategy": "replay", "undo_stack": 3, "detail_type": "RELATIVE", "detail_size": 12.0, "detail_percent": 25.0, "detail_resolution": 12.0, "dyntopo": false, "voxel_size": 0.1, "vertices": 1986, "faces": 2048, "multires": {"name": "Multires", "levels": 2, "sculpt_levels": 2, "total_levels": 2}, "masked": 12, "face_sets": 3}
"""
let state = SculptState.parse(stateText)
check("the state reads past Blender's informational lines", state != nil)
check("the brush, Size and Strength as Blender holds them",
      state?.brush == "Draw" && state?.size == 100 && state?.strength == 0.5 && state?.unifiedSize == true)
check("Multires, the mask and the face sets", state?.multires?.totalLevels == 2
      && state?.multires?.sculptLevels == 2 && state?.masked == 12 && state?.faceSets == 3)
check("Blender's stack is readable", state?.undoStack == 3)
check("Relative detail is edited in pixels", state?.detailValue == 12 && state?.detailUnit == "px")
var brushDetail = state!; brushDetail.detailType = "BRUSH"
check("Brush detail in percent", brushDetail.detailValue == 25 && brushDetail.detailUnit == "%")
var constant = state!; constant.detailType = "CONSTANT"
check("Constant detail as a resolution", constant.detailValue == 12 && constant.detailUnit == "")
check("a view that fits the region is one pixel to a point",
      state?.regionScale(viewWidth: 1100, viewHeight: 800) == 1)
check("a wider one is scaled down to fit, as _blenderkit_sculpt.mapping does",
      abs((state?.regionScale(viewWidth: 2000, viewHeight: 800) ?? 0) - 0.787) < 1e-6)
let multiresText = #"{"real": true, "essentials": true, "object": "Orb", "mode": "SCULPT", "brush": "Draw", "masked": null, "face_sets": 1, "vertices": 8066, "multires_base_budget": 2000, "voxel_size": 0.1, "scale": [0.01, 0.01, 0.01], "multires": {"name": "Multires", "levels": 1, "sculpt_levels": 1, "total_levels": 1}}"#
let onLevel = SculptState.parse(multiresText)
check("a mask Blender holds on a Multires level reads as unknown, not as none",
      onLevel != nil && onLevel?.masked == nil)
check("a base mesh over the Multires budget says so", onLevel?.multiresOverBudget == true
      && state?.multiresOverBudget == false)
check("a scaled object's voxel size is in its own units, and what it is in the scene",
      onLevel?.isScaled == true && abs((onLevel?.voxelSizeInScene ?? 0) - 0.001) < 1e-9
        && state?.isScaled == false)
var stretched = onLevel!; stretched.scale = [1, 2, 1]
check("stretched unevenly, it has no one size in the scene", stretched.isScaled && stretched.voxelSizeInScene == nil)
let simulator = SculptState.parse(#"{"real": false, "essentials": false, "object": null, "mode": "OBJECT", "brush": null}"#)
check("the simulator's answer reads, with nothing to show", simulator?.real == false && simulator?.size == nil)
check("a traceback reads as nothing", SculptState.parse("Traceback (most recent call last):\nRuntimeError: x") == nil)

let end = SculptJSON.last(SculptStrokeEnd.self, in: #"{"pushed": 2, "counted": true, "chunks": 23, "cuts": 0, "strategy": "replay", "dabs": 36, "stroke_ms": [3.1, 9.4], "mirror_ms": [0.6, 0.5]}"#)
check("a stroke's end: its undo steps, counted on Blender's stack", end?.pushed == 2 && end?.counted == true
      && end?.chunks == 23 && end?.strokeMs == [3.1, 9.4])
let refusedEnd = SculptJSON.last(SculptStrokeEnd.self, in: #"{"pushed": 0, "counted": true, "chunks": 0, "cuts": 0, "strategy": "deferred", "dabs": 12, "stroke_ms": [0.2], "mirror_ms": [0.0], "refused": "The stroke's object left Sculpt Mode part way through."}"#)
check("a stroke gathered for the lift that could not be made says why", refusedEnd?.refused?.contains("left Sculpt Mode") == true
      && end?.refused == nil)
let chunkResult = SculptJSON.last(SculptChunkResult.self, in: #"{"dabs": 5, "applied": true, "strategy": "anchored", "replayed": 0, "undo_ms": 0.3, "run_ms": 2.1, "stroke_ms": 4.0, "mirror_ms": 1.2}"#)
check("a chunk's answer", chunkResult?.applied == true && chunkResult?.undoMs == 0.3 && chunkResult?.cut == nil)

print("\nWhen a stroke's points go to Blender")

var policy = SculptStreamPolicy()
check("nothing waiting: nothing sent", !policy.shouldSend(at: 0, pending: 0))
check("the first point goes at once", policy.shouldSend(at: 10, pending: 1))
policy.sent(at: 10, cost: 0.010)
check("then not before a thirtieth of a second", !policy.shouldSend(at: 10.030, pending: 3))
check("and after it", policy.shouldSend(at: 10.045, pending: 3))
policy.sent(at: 10.045, cost: 0.120)
check("after a slow chunk, not before its cost again", !policy.shouldSend(at: 10.045 + 0.120 + 0.1, pending: 5))
check("and then", policy.shouldSend(at: 10.045 + 0.120 + 0.121, pending: 5))

print("\nA brush's Size in its field")

let px = NumberFieldUnit.pixels
check("shows whole pixels", px.format(79.6) == "80 px", px.format(79.6))
check("edits as a whole number", px.editable(80) == "80")
check("takes a number typed with or without its unit", px.typed("64 px") == 64 && px.typed("72") == 72
      && px.typed("12.6") == 13)
check("and nothing from what is not a number", px.typed("big") == nil)
let fine = NumberFieldUnit.fine
check("a voxel size in an object's own units: six places, and no metres",
      fine.format(0.0001) == "0.0001" && fine.format(0.1) == "0.100" && fine.editable(0.0001) == "0.0001",
      fine.format(0.0001) + " " + fine.format(0.1))

print("\nThe simulator's stand-in brush, and Blender's mesh")

// A dab at a cube's corner, as MetalViewportView.sculptDab sends one.
func dab(_ mesh: MeshData) -> MeshData {
    SculptEngine.stroke(mesh, at: SIMD3(1, 1, 1), direction: normalize(SIMD3(1, 1, 1)),
                        brush: .draw, radius: 0.6, strength: 0.5 * 0.35)
}
let subdivided = [Modifier(kind: .subdivision)]

// What a device holds: Blender's evaluated mesh, and the stack mirrored as a
// description. Round 3's review measured the old install on exactly this,
// 54 → 150 → 486 → … → 1,579,014 vertices over 8 dabs; four are replayed
// here so the check can tell the two installs apart.
func onDevice() -> BKObject {
    let o = BKObject(name: "Cube", kind: .cube)
    o.modifiers = subdivided
    o.setEvaluatedMesh(ModifierStack.apply(subdivided, to: MeshBuilder.make(.cube)))
    return o
}
let old = onDevice()
var grown: [Int] = [old.mesh.vertices.count]
for _ in 0..<4 {
    old.setMirroredMesh(dab(old.mesh))      // the install sculptDab had
    grown.append(old.mesh.vertices.count)
}
print("        the old install, 4 dabs: \(grown.map(String.init).joined(separator: " → ")) vertices")
check("the old install multiplied Blender's mesh on every dab (the negative control)",
      grown.last! > 4 * grown.first!, "\(grown)")

let device = onDevice()
let before = device.mesh.vertices.map(\.position)
let version = device.meshVersion
var refusals: [String?] = []
for _ in 0..<8 { refusals.append(device.sculptStandIn(dab)) }
check("on Blender's evaluated mesh every dab is refused, with a sentence",
      refusals.allSatisfy { $0?.contains("Sculpting tab") == true }, "\(refusals.first.map { "\($0 ?? "nil")" } ?? "")")
check("and the mesh is Blender's, untouched: same vertices, same version, still evaluated",
      device.mesh.vertices.map(\.position) == before && device.meshVersion == version && device.meshIsEvaluated,
      "\(device.mesh.vertices.count) vertices, version \(device.meshVersion)")

// The simulator: the mesh is the Swift stack's output over a base.
let sim = BKObject(name: "Cube", kind: .cube)
sim.modifiers = subdivided
let shownCount = sim.mesh.vertices.count
let baseCount = sim.evaluatedBase.vertices.count
var counts: [Int] = []
var installed = 0
for _ in 0..<8 {
    if sim.sculptStandIn(dab) == nil { installed += 1 }
    counts.append(sim.mesh.vertices.count)
}
check("in the simulator all 8 dabs are installed", installed == 8, "\(installed)")
check("and keep the stack's output at its size (\(shownCount) over \(baseCount))",
      counts.allSatisfy { $0 == shownCount } && sim.evaluatedBase.vertices.count == baseCount,
      "\(counts), base \(sim.evaluatedBase.vertices.count)")
check("the dabs moved the base, and the stack ran over it once",
      sim.evaluatedBase.vertices.map(\.position) != MeshBuilder.make(.cube).vertices.map(\.position)
        && sim.mesh.vertices.map(\.position)
            == ModifierStack.apply(subdivided, to: sim.evaluatedBase).vertices.map(\.position))
let plain = BKObject(name: "Plain", kind: .cube)
_ = plain.sculptStandIn(dab)
check("with no stack, the dab is on the mesh itself",
      plain.mesh.vertices.count == 24
        && plain.mesh.vertices.map(\.position) == dab(MeshBuilder.make(.cube)).vertices.map(\.position))

// The call sites themselves: a viewport dab and the shim's `sculpt_stroke`
// install through `sculptStandIn`, never `setMirroredMesh` over a mesh.
func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let viewport = source("Sources/BlenderLocalUI/Viewport/MetalViewportView.swift")
// Nothing else may run while a stroke streams into Blender (round 3's review:
// an Undo or a header operation between two chunks was undone by the next).
let runtime = source("Sources/BlenderLocalBridge/BpyRuntime.swift")
let bridgeSource = source("Sources/BlenderLocalBridge/BpyBridge.swift")
func body(_ text: String, after marker: String, length: Int = 400) -> String {
    guard let r = text.range(of: marker) else { return "" }
    return String(text[r.upperBound...].prefix(length))
}
// The guards read `gestureHold`, which holds for an open stroke and for a
// drag of a curve's points alike (BpySession.pointDragOpen).
let held = BpySession()
held.sculptStrokeOpen = true
check("an open stroke is a gesture that holds, in the stroke's words",
      held.gestureHold == BpySession.strokeOpenMessage)
check("Undo and Redo wait for an open stroke", body(runtime, after: "public func performUndo()").contains("gestureHold")
      && body(runtime, after: "public func performRedo()").contains("gestureHold"))
check("so do scripts, console lines and file opens",
      body(runtime, after: "public func runScript(", length: 900).contains("gestureHold")
        && body(runtime, after: "public func runConsole(").contains("gestureHold")
        && body(runtime, after: "public func submit(", length: 700).contains("gestureHold")
        && body(runtime, after: "public func openDocument(").contains("gestureHold"))
check("and every command the bridge runs", body(bridgeSource, after: "private func execute(", length: 2400)
      .contains("if let message = session.gestureHold"))
let strokeInput = source("Sources/BlenderLocalUI/Viewport/SculptStrokeInput.swift")
check("a drag owns its stroke to the lift, whatever the mode does meanwhile",
      strokeInput.contains("if let current = sculptInput.owner")
        && strokeInput.contains("endBlenderSculpt(keepingDrag: true)"))
let shimSource = source("Sources/BlenderLocalBridge/Python/EmbeddedBpyRuntime.swift")
check("MetalViewportView installs no mesh with setMirroredMesh, and dabs through sculptStandIn",
      !viewport.isEmpty && !viewport.contains("setMirroredMesh(") && viewport.contains("sculptStandIn"))
let shimInstalls = shimSource.components(separatedBy: "setMirroredMesh(").dropFirst()
check("the shim's entry points install only freshly built primitives with setMirroredMesh",
      !shimSource.isEmpty && shimInstalls.allSatisfy { $0.hasPrefix("MeshBuilder.") }
        && shimSource.contains("target.sculptStandIn"),
      shimInstalls.map { String($0.prefix(30)) }.joined(separator: " | "))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
