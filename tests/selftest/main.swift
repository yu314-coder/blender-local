import Foundation

// The Swift half of the Self-Test: the Python the app sends, the progress
// lines it reads back, the report's name, and the newest report found again
// after a run that took the app down. The Blender half — the checks
// themselves, run with the app's modules — is
// scripts/run-selftest-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

print("The Python the app sends")

let python = SelfTest.python(report: "/var/Documents/Self-Test/self-test-2026-10-30-14.03.12.txt",
                             historyRoot: "/var/Documents/.blender-history",
                             renderOutput: "/var/tmp/self-test-render.png",
                             about: [("Device", "iPad16,8"), ("iOS", "iPadOS 26.1"), ("RAM", "8.0 GB"),
                                     ("App", "Blender Local 1.0 (43)")])
check("it calls the module's run with the console's progress",
      python.hasPrefix("import _blenderkit_selftest as _bk_selftest\n_bk_selftest.run(")
      && python.contains("progress=_bk_selftest.console_progress"), python)
check("the report, the history's folder and the render's file go in as quoted paths",
      python.contains("\"/var/Documents/Self-Test/self-test-2026-10-30-14.03.12.txt\"")
      && python.contains("history_root=\"/var/Documents/.blender-history\"")
      && python.contains("render_output=\"/var/tmp/self-test-render.png\""), python)
check("the header's pairs, in order, as a list of [key, value]",
      python.contains("about=[[\"Device\", \"iPad16,8\"], [\"iOS\", \"iPadOS 26.1\"], [\"RAM\", \"8.0 GB\"], "
                      + "[\"App\", \"Blender Local 1.0 (43)\"]]"), python)
let odd = SelfTest.python(report: "/a \"b\"\\c.txt", historyRoot: "/h", renderOutput: "/r.png", about: [])
check("a quote or a backslash in a path is escaped, not ended on",
      odd.contains(#""/a \"b\"\\c.txt""#) && odd.contains("about=[]"), odd)

let render = SelfTest.render(output: "/var/tmp/x.png")
check("the render is the Render panel's own request: EEVEE, Draft, 64 x 64, through the scene camera",
      render.engine == .eevee && render.quality == .draft && render.width == 64 && render.height == 64
      && render.source == .sceneCamera)
check("and its script, as the panel sends it, goes in whole",
      python.contains("render_source=") && render.python.contains("scene.render.engine = \"BLENDER_EEVEE\"")
      && render.python.contains("scene.render.resolution_x = 64")
      && render.python.contains("scene.eevee.taa_render_samples = 8")
      && render.python.contains("bpy.ops.render.render(write_still=True)")
      && python.contains(Bpy.quote(SelfTest.render(output: "/var/tmp/self-test-render.png").python)))

print("\nThe progress lines")

let start = SelfTest.event("[self-test] start\t3\t40\tLeave Edit Mode under Geometry Nodes after Extrude")
check("a check that starts", start == .started(index: 3, total: 40,
                                              name: "Leave Edit Mode under Geometry Nodes after Extrude"),
      "\(String(describing: start))")
let done = SelfTest.event("[self-test] done\t3\t40\tPASS\t1.24\tLeave Edit Mode\t6 rounds survived; 3,721 -> 29,768")
check("a check that passed, with its time and detail",
      done == .finished(SelfTest.Result(index: 3, passed: true, seconds: 1.24, name: "Leave Edit Mode",
                                        detail: "6 rounds survived; 3,721 -> 29,768"), total: 40),
      "\(String(describing: done))")
let failed = SelfTest.event("[self-test] done\t40\t40\tFAIL\t0.05\tYour scene, opened again\tdiffers")
if case .finished(let result, _)? = failed {
    check("one that failed", !result.passed && result.name == "Your scene, opened again" && result.detail == "differs")
} else {
    check("one that failed", false, "\(String(describing: failed))")
}
check("the end, with the report's path",
      SelfTest.event("[self-test] end\t39\t1\t40\t62.3\t/var/Documents/Self-Test/r.txt")
      == .ended(passed: 39, failed: 1, seconds: 62.3, report: "/var/Documents/Self-Test/r.txt"))
check("the history's state, as JSON",
      SelfTest.event("[self-test] history\t{\"undo\": true, \"redo\": false}") == .history("{\"undo\": true, \"redo\": false}"))
check("a check's own output, Blender's reports and a malformed line are not events",
      SelfTest.event("Info: Saved copy as \"x.blend\"") == nil
      && SelfTest.event("[Blender Local] Run Script: Adding H would give ...") == nil
      && SelfTest.event("[self-test] done\t3\tforty\tPASS\t1\tx\ty") == nil
      && SelfTest.event("[self-test] done\t3\t40\tMAYBE\t1\tx\ty") == nil
      && SelfTest.event("[self-test] start\t3") == nil
      && SelfTest.event("self-test start\t1\t2\tx") == nil)

print("\nThe report's name, and the newest report found again")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone.current
let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 3, second: 12))!
check("self-test-<date-time>.txt, which sorts by time",
      SelfTest.reportName(at: date) == "self-test-2026-10-30-14.03.12.txt", SelfTest.reportName(at: date))
check("in Documents/Self-Test", SelfTest.folder.lastPathComponent == "Self-Test"
      && SelfTest.folder.deletingLastPathComponent() == SceneDocument.documentsURL)

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-host-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
check("no report yet: nothing", SelfTest.latestReport(in: folder) == nil)
try! "Blender Local Self-Test\n\nPASS  1.00 s  a — b\n\nSummary:  1 of 1 passed, 0 failed, in 1.0 s\n"
    .write(to: folder.appendingPathComponent("self-test-2026-10-30-14.03.12.txt"), atomically: true, encoding: .utf8)
let finished = SelfTest.latestReport(in: folder)
check("a finished run: found, and not said to have stopped",
      finished?.url.lastPathComponent == "self-test-2026-10-30-14.03.12.txt" && finished?.stoppedDuring == nil)
try! "Blender Local Self-Test\n\nPASS  1.00 s  a — b\nRUNNING  The window's own scene removed\n"
    .write(to: folder.appendingPathComponent("self-test-2026-10-30-15.00.00.txt"), atomically: true, encoding: .utf8)
try! "not a report".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
let stopped = SelfTest.latestReport(in: folder)
check("a newer run that took the app down: found, with the check it was running",
      stopped?.url.lastPathComponent == "self-test-2026-10-30-15.00.00.txt"
      && stopped?.stoppedDuring == "The window's own scene removed", "\(String(describing: stopped))")

print("\nWhat the sheet says before Run")
check("that the scene is saved, opened again, and the undo history ends there",
      SelfTest.undoNotice.contains("saved first and opened again")
      && SelfTest.undoNotice.contains("Undo cannot go back past the Self-Test"))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
