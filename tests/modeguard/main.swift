import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func mode(_ s: String) -> String { BpyModeGuard.requiredMode(for: s) ?? "nil" }

print("Mode guard")

print("\n  the mode comes from Blender's own namespace")
check("object operators need object mode",
      mode("bpy.ops.object.select_all(action='SELECT')") == "OBJECT",
      mode("bpy.ops.object.select_all(action='SELECT')"))
check("object.delete too", mode("bpy.ops.object.delete(use_global=False)") == "OBJECT")
check("mesh operators need edit mode",
      mode("bpy.ops.mesh.extrude_region_move()") == "EDIT")
check("mesh.delete too", mode("bpy.ops.mesh.delete(type='VERT')") == "EDIT")
check("uv operators need edit mode",
      mode("bpy.ops.uv.unwrap(method='ANGLE_BASED')") == "EDIT")

print("\n  adds are the exception")
// They live under `mesh`, but in edit mode they add into the edited mesh, and
// in sculpt mode they crash Blender outright.
check("an add needs object mode, not edit mode",
      mode("bpy.ops.mesh.primitive_cube_add(size=2)") == "OBJECT",
      mode("bpy.ops.mesh.primitive_cube_add(size=2)"))

print("\n  what is left alone")
// Move means an object in object mode and a vertex in edit mode. Forcing
// either would take away the one that was meant.
check("transforms keep whatever mode they are in",
      mode("bpy.ops.transform.translate(value=(1, 0, 0))") == "nil")
check("data access is not an operator",
      mode("bpy.data.objects[\"Cube\"].location = (0, 0, 0)") == "nil")
check("a script manages its own modes",
      mode("import bpy\nbpy.ops.object.select_all(action='SELECT')") == "nil")
check("explicit mode_set is the caller's business",
      mode("bpy.ops.object.mode_set(mode='EDIT')") == "nil")
check("and so is anything that contains one",
      mode("bpy.ops.object.select_all(action='SELECT')\nbpy.ops.object.mode_set(mode='EDIT')") == "nil")
check("an empty string needs nothing", mode("") == "nil")

print("\n  several statements are judged by the first")
let tapSelect = """
bpy.ops.object.select_all(action='DESELECT')
bpy.data.objects["Cube"].select_set(True)
bpy.context.view_layer.objects.active = bpy.data.objects["Cube"]
"""
check("a tap-select is an object operation", mode(tapSelect) == "OBJECT", mode(tapSelect))
check("a leading comment is skipped",
      mode("# flip them\nbpy.ops.mesh.flip_normals()") == "EDIT")

print("\n  the wrapping")
check("something needing no mode comes back untouched",
      BpyModeGuard.wrap("bpy.ops.transform.translate(value=(1, 0, 0))")
        == "bpy.ops.transform.translate(value=(1, 0, 0))")
let wrapped = BpyModeGuard.wrap("bpy.ops.mesh.flip_normals()")
check("it switches to the mode it needs", wrapped.contains("mode_set(mode='EDIT')"), wrapped)
check("only when not already there", wrapped.contains("if _bk_g_prev != 'EDIT':"), wrapped)
check("the operator runs inside try", wrapped.contains("try:\n    bpy.ops.mesh.flip_normals()"), wrapped)
// Restoring in `finally` means a failing operator still hands the mode back —
// otherwise the first error would strand Blender exactly as before.
check("and the mode is restored in finally, so a failure cannot strand it",
      wrapped.contains("finally:") && wrapped.contains("mode_set(mode=_bk_g_prev)"), wrapped)
check("the exception is not swallowed",
      !wrapped.contains("except Exception:\n        pass\nfinally"), wrapped)
check("every line of a multi-line operator is indented into the try",
      BpyModeGuard.wrap(tapSelect).contains("    bpy.data.objects[\"Cube\"].select_set(True)"))

print("\n  through the bridge")
// The guard is Python. The command-subset fallback — what runs when embedded
// Python fails to start — reads one line at a time and has no modes, so
// wrapping there turned every menu action into a failure. The checks above
// only ever looked at the string, which is how that got as far as the redo
// suite: an add that worked and then reported that it had not.
final class RecordingRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = false
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
}

// The bridge does not own its scene — in the app the root view does — so
// whoever builds one has to keep the scene alive. A helper that returned only
// the bridge let it go, and every call answered "no scene bound".
struct Rig {
    let scene: BKScene
    let undo: UndoStack
    let session: BpySession
    let bridge: BpyBridge
}

func makeRig(_ runtime: BpyRuntime) -> Rig {
    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    undo.seed(scene)
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    return Rig(scene: scene, undo: undo, session: session,
               bridge: BpyBridge(session: session, scene: scene, undo: undo))
}

let recorder = RecordingRuntime()
let pythonRig = makeRig(recorder)
_ = pythonRig.bridge.run("bpy.ops.mesh.flip_normals()")
check("with Python behind it, the bridge sends the bracketed operator",
      recorder.sources.last == BpyModeGuard.wrap("bpy.ops.mesh.flip_normals()"),
      recorder.sources.last ?? "nothing sent")
check("and the Info log still reads as the bare operator",
      pythonRig.session.infoLog.last == "bpy.ops.mesh.flip_normals()",
      pythonRig.session.infoLog.last ?? "nothing logged")

let stubRig = makeRig(StubBpyRuntime())
let selected = stubRig.bridge.run("bpy.ops.object.select_all(action='SELECT')")
check("the command-subset fallback still runs a menu operator",
      selected.succeeded, selected.error ?? "")
let added = stubRig.bridge.perform(LastOperator.add(.cylinder, at: .zero))
check("and an add there still leaves something to adjust",
      added.succeeded && stubRig.bridge.adjustable != nil,
      added.error ?? "nothing to adjust")

print("\n  one evaluation per operator")
// Every evaluation on a device is a mirroring pass, which re-reads every mesh
// in the scene. A mesh operator used to cost five of them.

/// Records what was run and answers the bridge's questions as Blender would.
final class ScriptedRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender: Bool
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    var queries: [String] = []
    /// The error a source fails with, if any.
    var failing: (String) -> String? = { _ in nil }
    init(realBlender: Bool) { usesRealBlender = realBlender }
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "scripted" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return failing(source).map { [BpyLine(.error, $0)] } ?? []
    }
    func query(_ source: String, scene: BKScene) -> [BpyLine] {
        queries.append(source)
        if source.contains("print(_bk_adjustable)") {
            return [BpyLine(.output, "True"), BpyLine(.output, "Cube")]
        }
        if source.contains("objects.active.name") { return [BpyLine(.output, "Cube")] }
        return []
    }
}

func inOrder(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for part in parts {
        guard let found = text.range(of: part, range: from..<text.endIndex) else { return false }
        from = found.upperBound
    }
    return true
}

let scripted = ScriptedRuntime(realBlender: false)
let meshRig = makeRig(scripted)
_ = meshRig.scene.add(.cube)
var sent = scripted.sources.count
meshRig.bridge.perform(LastOperator.mesh(.bevel))
check("a mesh operator is one evaluation, so one mirroring pass",
      scripted.sources.count - sent == 1, "\(scripted.sources.count - sent) evaluations")
let bevelSource = scripted.sources.last ?? ""
check("into edit mode, then the backup, then the operator",
      inOrder(bevelSource, ["mode_set(mode='EDIT')", "_bk_redo", "bpy.ops.mesh.bevel("]), bevelSource)
check("and the mode put back in a finally, whether or not it worked",
      inOrder(bevelSource, ["bpy.ops.mesh.bevel(", "finally:", "mode_set(mode=_bk_prev_mode)"]),
      bevelSource)
check("adjustable once Blender says the backup took, on the object it named",
      meshRig.bridge.adjustable?.name == "Bevel" && meshRig.bridge.adjustable?.subject == "Cube",
      "\(String(describing: meshRig.bridge.adjustable))")

sent = scripted.sources.count
meshRig.bridge.perform(LastOperator.mesh(.inset))
check("the next operator is one evaluation too", scripted.sources.count - sent == 1)
check("which drops the last one's backup before taking its own",
      scripted.sources.last?.hasPrefix(LastOperator.discardBackup) == true,
      scripted.sources.last ?? "")

sent = scripted.sources.count
meshRig.bridge.run(Bpy.deleteSelected, undo: "Delete")
check("any undoable command drops the backup in its own evaluation",
      scripted.sources.count - sent == 1
        && scripted.sources.last?.hasPrefix(LastOperator.discardBackup) == true,
      scripted.sources.last ?? "")
check("and ends the redo panel's operation", meshRig.bridge.adjustable == nil)

print("\n  failures are said where the reader is looking")
scripted.failing = {
    $0.contains("mesh.bevel(")
        ? "RuntimeError: Error: Operator bpy.ops.mesh.bevel.poll() failed, context is incorrect"
        : nil
}
meshRig.bridge.perform(LastOperator.mesh(.bevel))
check("a failed operator puts up a report naming it",
      meshRig.bridge.report?.operation == "Bevel", "\(String(describing: meshRig.bridge.report))")
check("in Blender's words, without the exception machinery",
      meshRig.bridge.report?.message == "Operator bpy.ops.mesh.bevel.poll() failed, context is incorrect",
      meshRig.bridge.report?.message ?? "")
check("and it is not adjustable", meshRig.bridge.adjustable == nil)
let shownID = meshRig.bridge.report?.id ?? -1
scripted.failing = { _ in "NameError: name '_bk_o' is not defined" }
meshRig.bridge.run("_bk_o.select = True", quiet: true)
check("bookkeeping nobody asked for puts nothing up", meshRig.bridge.report?.id == shownID)
scripted.failing = { _ in nil }
meshRig.bridge.dismissReport(shownID)
check("and a report can be taken down", meshRig.bridge.report == nil)

print("\n  an undone operation cannot be adjusted")
// Adjusting after an undo re-ran the operator on the restored scene and wrote
// the result over the undo step: the state from before it was gone.
let undoRig = makeRig(StubBpyRuntime())
undoRig.bridge.perform(LastOperator.add(.cube, at: .zero))
check("an add is adjustable", undoRig.bridge.adjustable != nil)
undoRig.session.performUndo()
check("until it is undone, from anywhere", undoRig.bridge.adjustable == nil)
check("and adjusting it then does nothing",
      undoRig.bridge.readjust(LastOperator.add(.cube, at: .zero)) == nil
        && undoRig.scene.objects.isEmpty,
      "\(undoRig.scene.objects.map(\.name))")
undoRig.session.performRedo()
check("redoing it makes it the last operation again", undoRig.bridge.adjustable != nil)

print("\n  a drag writes its undo step once")
let dragRig = makeRig(StubBpyRuntime())
dragRig.bridge.perform(LastOperator.add(.cylinder, at: .zero))
let thirtyTwo = dragRig.scene.objects.first?.mesh.vertices.count ?? -1
var twelve = dragRig.bridge.adjustable!
twelve["vertices"] = 12
_ = dragRig.bridge.readjust(twelve, record: false)
let adjustedCount = dragRig.scene.objects.first?.mesh.vertices.count ?? -1
check("a frame of the drag re-runs the operator", adjustedCount != thirtyTwo,
      "\(thirtyTwo) -> \(adjustedCount)")
dragRig.session.performUndo()
dragRig.session.performRedo()
check("without writing the undo step",
      dragRig.scene.objects.first?.mesh.vertices.count == thirtyTwo,
      "\(String(describing: dragRig.scene.objects.first?.mesh.vertices.count))")

let endRig = makeRig(StubBpyRuntime())
endRig.bridge.perform(LastOperator.add(.cylinder, at: .zero))
var eight = endRig.bridge.adjustable!
eight["vertices"] = 8
_ = endRig.bridge.readjust(eight, record: false)
let eightCount = endRig.scene.objects.first?.mesh.vertices.count ?? -1
endRig.bridge.recordAdjustment()
endRig.session.performUndo()
check("the end of the drag replaces the step rather than adding one",
      endRig.scene.objects.isEmpty, "\(endRig.scene.objects.map(\.name))")
endRig.session.performRedo()
check("with what the drag left", endRig.scene.objects.first?.mesh.vertices.count == eightCount,
      "\(String(describing: endRig.scene.objects.first?.mesh.vertices.count)) vs \(eightCount)")

print("\n  what was tapped reaches Blender before the command that acts on it")
let device = ScriptedRuntime(realBlender: true)
let editRig = makeRig(device)
_ = editRig.scene.add(.cube)
editRig.scene.setMode(.edit)
editRig.scene.editSelection.vertices = [0, 1]
editRig.scene.editSelectionPending = true
sent = device.sources.count
editRig.bridge.run(Bpy.deleteSelection(editing: true, mode: .vertex), undo: "Delete")
check("in the command's own evaluation", device.sources.count - sent == 1)
let deleteSource = device.sources.last ?? ""
check("the selection first, then the operator",
      inOrder(deleteSource, ["import bmesh", "bpy.ops.mesh.delete(type='VERT')"]), deleteSource)
check("and only once", !editRig.scene.editSelectionPending)
editRig.bridge.run(Bpy.invertSelection(editing: true), undo: "Invert Selection")
check("a command with nothing new to hand over sends only itself",
      device.sources.last.map { !$0.contains("import bmesh") } == true, device.sources.last ?? "")

print("\n  a tap sends its selection once")
let tapRuntime = RecordingRuntime()
let tapRig = makeRig(tapRuntime)
let tapsBefore = tapRuntime.sources.count
tapRig.bridge.select(Bpy.select("Cube"))
check("without Blender behind it, it runs once", tapRuntime.sources.count - tapsBefore == 1,
      "\(tapRuntime.sources.count - tapsBefore)")
let deviceTap = ScriptedRuntime(realBlender: true)
let deviceRig = makeRig(deviceTap)
_ = deviceRig.scene.add(.cube)
let evaluations = deviceTap.sources.count
deviceRig.bridge.select(Bpy.select("Cube"))
check("on a device it skips reading every mesh back", deviceTap.sources.count == evaluations,
      "\(deviceTap.sources.count - evaluations) full evaluations")
check("and mirrors only the selection",
      deviceTap.queries.last == BpyBridge.selectionScript(Bpy.select("Cube")), deviceTap.queries.last ?? "")
check("which the Info log still records",
      deviceRig.session.infoLog.contains("bpy.data.objects[\"Cube\"].select_set(True)"),
      "\(deviceRig.session.infoLog)")

print("\n  a tool says which mode it needs")
check("a brush takes the view into sculpt mode", ActiveTool.sculptDraw.mode(whenChosenFrom: .object) == .sculpt)
let leaving: [ActiveTool] = [.select, .boxSelect, .move, .rotate, .scale]
check("Select, Box, Move, Rotate and Scale leave sculpt mode",
      leaving.allSatisfy { $0.mode(whenChosenFrom: .sculpt) == .object })
check("and texture paint", leaving.allSatisfy { $0.mode(whenChosenFrom: .texturePaint) == .object })
check("but leave edit mode to Blender", leaving.allSatisfy { $0.mode(whenChosenFrom: .edit) == nil })
check("and object mode alone", leaving.allSatisfy { $0.mode(whenChosenFrom: .object) == nil })
check("another brush of the same mode changes nothing",
      ActiveTool.sculptGrab.mode(whenChosenFrom: .sculpt) == nil)
check("a brush Blender shares between paint modes keeps the one in use: Draw in Weight Paint",
      ActiveTool.paintDraw.mode(whenChosenFrom: .weightPaint) == nil
      && ActiveTool.paintBlur.mode(whenChosenFrom: .vertexPaint) == nil
      && ActiveTool.paintSmear.mode(whenChosenFrom: .texturePaint) == nil)
check("Average stays in Weight Paint, as Blender has it there too",
      ActiveTool.paintAverage.mode(whenChosenFrom: .weightPaint) == nil)
check("and from outside those modes a shared brush goes to its own",
      ActiveTool.paintDraw.mode(whenChosenFrom: .object) == .texturePaint
      && ActiveTool.paintAverage.mode(whenChosenFrom: .texturePaint) == .vertexPaint
      && ActiveTool.paintClone.mode(whenChosenFrom: .vertexPaint) == .texturePaint
      && ActiveTool.gradient.mode(whenChosenFrom: .vertexPaint) == .weightPaint)
check("a paint brush from sculpt mode goes to texture paint",
      ActiveTool.paintDraw.mode(whenChosenFrom: .sculpt) == .texturePaint)

print("\n  while editing, commands mean elements")
check("Tab asks Blender which mode it is in, and brackets nothing",
      Bpy.toggleEditMode.contains("'mode', 'OBJECT') == 'EDIT'")
        && Bpy.toggleEditMode.contains("mode_set(mode='EDIT')")
        && mode(Bpy.toggleEditMode) == "nil",
      Bpy.toggleEditMode)

// A light has no edit mode, and mode_set handed 'EDIT' answers with the enum
// it was given -- "enum \"EDIT\" not found in ('OBJECT')" -- which says
// nothing about the Sun that was selected. Real Blender is held to the
// wording in scripts/run-3dview-blender-check.sh.
// Since 2026-10-01 a curve and a lattice have Edit Mode too (their control
// points, ControlPoints.swift); the sculpt and paint modes stay a mesh's.
check("and the way in is held to a mesh, a curve or a lattice",
      Bpy.toggleEditMode.contains("_bk_o.type not in ('MESH', 'CURVE', 'LATTICE')"))
check("as is Edit Mesh itself", Bpy.setMode(.edit).contains("_bk_o.type not in ('MESH', 'CURVE', 'LATTICE')")
        && Bpy.setMode(.edit).hasSuffix("bpy.ops.object.mode_set(mode='EDIT')"))
check("and every other mode a mesh alone has",
      InteractionMode.allCases.filter { $0 != .object && $0 != .edit }
          .allSatisfy { Bpy.setMode($0).contains("_bk_o.type != 'MESH'") })
check("object mode is the way back, and is never refused",
      Bpy.setMode(.object) == "bpy.ops.object.mode_set(mode='OBJECT')")
check("the refusal names the mode that was asked for",
      Bpy.setMode(.sculpt).contains("\"Sculpt Mode\"")
        && Bpy.setMode(.edit).contains("\"Edit Mode\""))
check("a light is called a light, not LIGHT", Bpy.setMode(.edit).contains("'LIGHT': 'a light'"))
check("the guard leaves all of it alone: it manages its own mode",
      mode(Bpy.setMode(.edit)) == "nil" && mode(Bpy.setMode(.object)) == "nil")
check("Select All selects elements while editing",
      Bpy.selectAll(editing: true) == "bpy.ops.mesh.select_all(action='SELECT')")
check("and objects otherwise", Bpy.selectAll(editing: false) == Bpy.selectAll)
check("Deselect All too", Bpy.deselectAll(editing: true) == "bpy.ops.mesh.select_all(action='DESELECT')")
check("and Invert", Bpy.invertSelection(editing: true) == "bpy.ops.mesh.select_all(action='INVERT')")
check("Delete removes the elements of the select mode",
      Bpy.deleteSelection(editing: true, mode: .vertex) == "bpy.ops.mesh.delete(type='VERT')"
        && Bpy.deleteSelection(editing: true, mode: .edge) == "bpy.ops.mesh.delete(type='EDGE')"
        && Bpy.deleteSelection(editing: true, mode: .face) == "bpy.ops.mesh.delete(type='FACE')")
check("and objects outside edit mode", Bpy.deleteSelection(editing: false, mode: .face) == Bpy.deleteSelected)
check("select_mode is sent VERT, which Blender accepts, not VERTEX",
      Bpy.meshSelectMode(.vertex) == "bpy.ops.mesh.select_mode(type='VERT')")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
