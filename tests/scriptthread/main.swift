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

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
