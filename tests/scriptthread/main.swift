import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

print("== which thread a script runs on ==")

check("a plain script stays off the main thread",
      !ScriptThread.needsMainThread("import bpy\nbpy.ops.mesh.primitive_cube_add()\n"))
check("keywords naming an area go to the main thread",
      ScriptThread.needsMainThread("""
      with bpy.context.temp_override(window=w, area=a, region=r):
          bpy.ops.view3d.snap_cursor_to_center()
      """))
check("an override built as a dict goes too",
      ScriptThread.needsMainThread("o = C.copy()\no['area'] = a\nwith C.temp_override(**o):\n    pass\n"))
check("so does a data-only override, which costs nothing but the thread",
      ScriptThread.needsMainThread("with bpy.context.temp_override(active_object=ob):\n    pass\n"))
check("a mention in a comment is enough, by design",
      ScriptThread.needsMainThread("# no temp_override here\nprint(1)\n"))
check("the old dict-argument operator style does not count",
      !ScriptThread.needsMainThread("bpy.ops.object.join({'active_object': ob})\n"))
check("the note names the reason",
      ScriptThread.mainThreadNote.contains("temp_override"))

print("\n== loading a file runs on the main thread ==")
// The script that crashed the app (BlenderLocal-2026-09-22-100656 / -100743).
check("the script that crashed the app goes to the main thread",
      ScriptThread.needsMainThread("import bpy; bpy.ops.wm.read_homefile()"))
for name in ScriptThread.fileReads {
    check("bpy.ops.wm.\(name) goes to the main thread",
          ScriptThread.needsMainThread("import bpy\nbpy.ops.wm.\(name)()\n"))
}
check("open_mainfile with a path and load_ui goes too",
      ScriptThread.needsMainThread("bpy.ops.wm.open_mainfile(filepath='/x.blend', load_ui=True)\n"))
check("saving does not: save_as_mainfile is not open_mainfile",
      !ScriptThread.needsMainThread("bpy.ops.wm.save_as_mainfile(filepath='/x.blend', copy=True)\n"))
check("nor do the operators that read preferences or the recent files",
      !ScriptThread.needsMainThread("bpy.ops.wm.read_userpref()\nbpy.ops.wm.read_history()\n"))
check("the note for a file load names the reason",
      ScriptThread.note(for: "bpy.ops.wm.read_homefile()").contains("loading a file"))
check("a temp_override script still gets its own note",
      ScriptThread.note(for: "with C.temp_override(area=a):\n    pass\n") == ScriptThread.mainThreadNote)

// The Python half refuses the same operators off the main thread, for the
// calls this check cannot see; the two lists have to name the same six.
let contextModule = "Resources/python/site/_blenderkit_context.py"
if let text = try? String(contentsOfFile: contextModule, encoding: .utf8),
   let start = text.range(of: "FILE_READS = ("),
   let end = text.range(of: ")", range: start.upperBound..<text.endIndex) {
    let names = text[start.upperBound..<end.lowerBound]
        .split(separator: "'", omittingEmptySubsequences: false)
        .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
    check("the Swift list and _blenderkit_context.FILE_READS name the same operators",
          names == ScriptThread.fileReads, "\(names) vs \(ScriptThread.fileReads)")
} else {
    check("_blenderkit_context.py has FILE_READS", false, contextModule)
}

print("\n== picking a brush runs on the main thread ==")
// Off it Blender gives out no workspace, and `brush.asset_activate` crashed
// desktop 5.2.1 with the app's context (exit 139 in
// WM_toolsystem_activate_brush_and_tool) with the mode's tool there or not.
let infoLine = "bpy.ops.brush.asset_activate(asset_library_type='ESSENTIALS', asset_library_identifier=\"\", "
    + "relative_asset_identifier=\"brushes/essentials_brushes-mesh_vertex.blend/Brush/Paint Hard\")"
check("the line Blender's Info editor logs for a brush pick goes to the main thread",
      ScriptThread.needsMainThread("import bpy\n" + infoLine + "\n"))
check("its note names the reason", ScriptThread.note(for: infoLine) == ScriptThread.brushPickNote
      && ScriptThread.brushPickNote.contains("brush"))
check("a script that also loads a file gets the file's note",
      ScriptThread.note(for: "bpy.ops.wm.open_mainfile(filepath='/x.blend')\n" + infoLine) == ScriptThread.fileReadNote)
check("one that also overrides the context gets the override's",
      ScriptThread.note(for: "with C.temp_override(area=a):\n    " + infoLine) == ScriptThread.mainThreadNote)
check("a script that only sets a brush's size does not",
      !ScriptThread.needsMainThread("bpy.context.tool_settings.vertex_paint.brush.size = 40\n"))
if let text = try? String(contentsOfFile: contextModule, encoding: .utf8),
   let start = text.range(of: "BRUSH_PICKS = ("),
   let end = text.range(of: ")", range: start.upperBound..<text.endIndex) {
    let names = text[start.upperBound..<end.lowerBound]
        .split(separator: "'", omittingEmptySubsequences: false)
        .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
    check("the Swift list and _blenderkit_context.BRUSH_PICKS name the same operators",
          names == ScriptThread.brushPicks, "\(names) vs \(ScriptThread.brushPicks)")
} else {
    check("_blenderkit_context.py has BRUSH_PICKS", false, contextModule)
}

print("\n== which scripts have Blender's GPU module started on the main thread first ==")
// Whichever thread starts it keeps its context, and Knife Project needs it on
// the main thread; scripts/run-redo-blender-check.sh runs the order itself.
let render = RenderRequest(engine: .eevee, quality: .draft, width: 32, height: 32,
                           source: .sceneCamera, output: "/tmp/x.png").python
check("the Render panel's render", ScriptThread.mayStartGPU(render))
check("a Cycles render too, which is only a wasted call",
      ScriptThread.mayStartGPU(RenderRequest(engine: .cycles, output: "/tmp/x.png").python))
check("a script that uses the gpu module", ScriptThread.mayStartGPU("import gpu\noffscreen = gpu.types.GPUOffScreen(64, 64)\n"))
check("a viewport render", ScriptThread.mayStartGPU("bpy.ops.render.opengl()\n"))
check("not a plain modelling script",
      !ScriptThread.mayStartGPU("import bpy\nbpy.ops.mesh.primitive_cube_add()\n"))
/// `ScriptThread.gpuStart` run in the Mac's python3 after `prelude`, then one
/// more line: whether the script went on past the start. Nil without python3.
func scriptGoesOn(after prelude: String) -> Bool? {
    guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = ["-B", "-c", prelude + "\n" + ScriptThread.gpuStart + "\nprint('went on')\n"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return process.terminationStatus == 0 && text.contains("went on")
}
// Run, not read: the old check only looked for "except Exception" in the text.
let failingInit = """
    import sys, types
    gpu = types.ModuleType('gpu')
    def init():
        raise SystemError('the GPU backend did not start')
    gpu.init = init
    sys.modules['gpu'] = gpu
    """
if let raised = scriptGoesOn(after: failingInit), let missing = scriptGoesOn(after: "import sys\nsys.modules['gpu'] = None") {
    check("the start itself cannot raise into the session: a gpu.init() that raises is passed over", raised)
    check("and so is a build with no gpu module at all", missing)
} else {
    print("  SKIP  no python3 to run the GPU start in")
}

print("\n== which console lines run Python ==")
// A line that runs Python is mirrored into the viewport and gets an undo step
// (`BpySession.runConsole`). `time` and `watch` run the command after them
// (_blenderkit_shell's `_time_cmd` and `_watch`), so `time python -c …` runs
// Python as `python -c …` does; read by its first word alone it was taken for
// a command that touches nothing (round 4's review of group 7).
for line in ["python -c \"import bpy\"", "python3 script.py", "py", "time python -c \"x\"",
             "time time py", "watch python3 a.py", "watch -n 0.5 -c 3 python -c \"x\"",
             "watch --count 2 time python a.py"] {
    check("\(line) runs Python", ConsoleShell.touchesScene(line))
}
for line in ["ls", "time ls -la", "watch -n 1 ls", "echo python", "cat python.txt", "watch -n",
             "time", "pythonic", "grep python a.py"] {
    check("\(line) does not", !ConsoleShell.touchesScene(line))
}
// What the first-word rule answered, for the control: it missed every one
// that `time` or `watch` starts.
func firstWordRule(_ command: String) -> Bool {
    let word = command.prefix { $0 != " " && $0 != "\t" }
    return word == "python" || word == "python3" || word == "py"
}
check("control: the first word alone missed `time python -c …` and `watch … python`",
      !firstWordRule("time python -c \"x\"") && !firstWordRule("watch -n 0.5 -c 3 python -c \"x\""))
// And every console line seeds the history first, whatever it runs: ncdu's
// mini-shell runs `python` inside a line that reads as `ncdu`.
if let runtime = try? String(contentsOfFile: "Sources/BlenderLocalBridge/BpyRuntime.swift", encoding: .utf8),
   let start = runtime.range(of: "public func runConsole("),
   let end = runtime.range(of: "startGPUOnMainThread(before: source", range: start.upperBound..<runtime.endIndex) {
    let body = runtime[start.upperBound..<end.lowerBound]
    let unconditional = body.split(separator: "\n").contains {
        $0.trimmingCharacters(in: .whitespaces) == "prepareBackendChange()"
    }
    check("runConsole pushes the history's first step before any line, not only Python", unconditional)
} else {
    check("BpyRuntime.swift has runConsole", false)
}

print("\n== the DEBUG -eval64 hook leaves the reader's draft alone ==")
// The hook wrote its script into Scripts/.draft.py before any view existed,
// so the Scripting tab would show it; whatever the last hook ran became the
// reader's script. Round 4's final review found the container's draft was a
// fixture that deleted every object, one press of Run from wiping the scene.
// Now the hook's script is shown in memory (`ScriptDocument.restored`) and
// `saveDraft` writes nothing for it. Read from the sources, every file the
// app is built from: the in-app run (the draft's checksum before and after a
// launch with -eval64) is in docs/blender-local.md, October 20.
var swiftSources: [(path: String, text: String)] = []
if let walker = FileManager.default.enumerator(atPath: "Sources") {
    for case let path as String in walker where path.hasSuffix(".swift") {
        if let text = try? String(contentsOfFile: "Sources/" + path, encoding: .utf8) {
            swiftSources.append(("Sources/" + path, text))
        }
    }
}
check("the app's Swift sources were read (\(swiftSources.count) files)", swiftSources.count > 50)
// Every line that writes to the draft's file, in every source.
let draftWrites = swiftSources.flatMap { file in
    file.text.split(separator: "\n").filter { $0.contains("draftURL") && $0.contains("write(") }
        .map { "\(file.path): \($0.trimmingCharacters(in: .whitespaces))" }
}
check("one line writes the draft, ScriptDocument.saveDraft's: \(draftWrites.count)",
      draftWrites.count == 1 && draftWrites[0].hasPrefix("Sources/BlenderLocalUI/Workspaces/ScriptingWorkspace.swift"),
      draftWrites.joined(separator: " | "))
if let workspace = swiftSources.first(where: { $0.path.hasSuffix("Workspaces/ScriptingWorkspace.swift") })?.text,
   let start = workspace.range(of: "func saveDraft() {"),
   let write = workspace.range(of: "draftURL", range: start.upperBound..<workspace.endIndex),
   let restored = workspace.range(of: "static func restored() -> ScriptDocument {"),
   let restoredEnd = workspace.range(of: "\n    }\n", range: restored.upperBound..<workspace.endIndex) {
    let beforeWrite = workspace[start.upperBound..<write.lowerBound]
    check("saveDraft returns before that write for the hook's script",
          beforeWrite.contains("guard !isLaunchScript else { return }"), String(beforeWrite))
    let body = workspace[restored.upperBound..<restoredEnd.lowerBound]
    check("restored() marks the hook's script as the hook's, before it reads the draft",
          body.contains("document.isLaunchScript = true")
          && (body.range(of: "launchSource")?.lowerBound ?? body.endIndex)
             < (body.range(of: "draftURL")?.lowerBound ?? body.startIndex), String(body.prefix(300)))
} else {
    check("ScriptingWorkspace.swift has saveDraft and restored", false)
}
// And the flag lives in DEBUG code only, so a release build has neither the
// hook nor anything it reads (scripts/scan-app.py checks the binary).
var outsideDebug: [String] = []
for file in swiftSources {
    var stack: [String] = []
    for line in file.text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#if ") { stack.append(String(s.dropFirst(4))); continue }
        if s.hasPrefix("#else") || s.hasPrefix("#elseif") { if !stack.isEmpty { stack[stack.count - 1] = "!" + stack[stack.count - 1] }; continue }
        if s.hasPrefix("#endif") { if !stack.isEmpty { stack.removeLast() }; continue }
        if s.hasPrefix("//") { continue }
        if s.contains("\"-eval64\"") && !stack.contains("DEBUG") { outsideDebug.append("\(file.path): \(s)") }
    }
}
check("every \"-eval64\" in the sources is inside #if DEBUG", outsideDebug.isEmpty, outsideDebug.joined(separator: " | "))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
