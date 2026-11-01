import Foundation

// The Swift half of Test All Features that needs no interface: the rating
// and its thresholds, the frame times, the report's lines and their reading
// back, the report found again after a run that took the app down, and the
// inventory — every feature either run by a case of FeatureTestRunner's or
// listed with why it is not. The run itself is the app's
// (`-feature-test` in a DEBUG build, Preferences ▸ Testing in any).

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

typealias R = FeatureTest.Rating
func stats(_ p95: Double) -> FeatureTest.FrameStats {
    FeatureTest.FrameStats(count: 90, median: 0.0167, p95: p95, worst: max(p95, 0.05))
}
func rate(_ kind: FeatureTest.Kind, stall: Double, p95: Double? = nil, failed: Bool = false,
          seconds: Double = 0.1, progress: Bool = false) -> R {
    FeatureTest.rate(kind: kind, stall: stall, frames: p95.map(stats), failed: failed,
                     seconds: seconds, progressShown: progress)
}

print("The rating")
check("a 40 ms stall is Smooth", rate(.command, stall: 0.040) == .smooth)
check("99 ms is Smooth, 100 ms OK", rate(.command, stall: 0.099) == .smooth && rate(.command, stall: 0.100) == .ok)
check("249 ms is OK, 250 ms Slow (Apple's hang)", rate(.command, stall: 0.249) == .ok
      && rate(.command, stall: 0.250) == .slow)
check("a second is still Slow; past it, Freeze", rate(.command, stall: 1.0) == .slow
      && rate(.command, stall: 1.001) == .freeze)
check("an error is Failed whatever the times", rate(.command, stall: 0.01, failed: true) == .failed
      && rate(.continuous, stall: 3, p95: 0.1, failed: true) == .failed)
check("a drag with frames at 16.7 ms is Smooth", rate(.continuous, stall: 0.02, p95: 0.0167) == .smooth)
check("p95 of 17 ms is Smooth, 17.5 OK", rate(.continuous, stall: 0.02, p95: 0.017) == .smooth
      && rate(.continuous, stall: 0.02, p95: 0.0175) == .ok)
check("p95 of two 60 Hz frames (33.3 ms) is OK, three (50 ms) Slow",
      rate(.continuous, stall: 0.02, p95: 2.0 / 60) == .ok && rate(.continuous, stall: 0.02, p95: 0.033) == .ok
      && rate(.continuous, stall: 0.02, p95: 0.034) == .slow && rate(.continuous, stall: 0.02, p95: 3.0 / 60) == .slow)
check("a drag takes the worse of its stall and its frames",
      rate(.continuous, stall: 0.3, p95: 0.016) == .slow && rate(.continuous, stall: 0.05, p95: 0.05) == .slow
      && rate(.continuous, stall: 1.5, p95: 0.016) == .freeze)
check("a tap's frames are not held to 17 ms", rate(.command, stall: 0.02, p95: 0.05) == .smooth)
func play(p95: Double, fps: Double) -> R {
    FeatureTest.rate(kind: .continuous, stall: 0.02, frames: stats(p95), failed: false,
                     seconds: 2, progressShown: false, pace: 1 / fps)
}
check("24 fps playback drawn every 50 ms on a 60 Hz screen is Smooth",
      play(p95: 0.0502, fps: 24) == .smooth)
check("24 fps playback one refresh late is OK, two late Slow",
      play(p95: 0.0668, fps: 24) == .ok && play(p95: 0.084, fps: 24) == .slow)
check("60 fps playback is held to 17 ms like a drag",
      play(p95: 0.0167, fps: 60) == .smooth && play(p95: 0.034, fps: 60) == .slow)
check("a long job is held to its stall, not its time", rate(.long, stall: 0.03, seconds: 40, progress: true) == .smooth
      && rate(.long, stall: 0.3, seconds: 40, progress: true) == .slow)
check("a long job of a second or more that showed no progress is OK at best",
      rate(.long, stall: 0.03, seconds: 1.0) == .ok && rate(.long, stall: 0.03, seconds: 0.9) == .smooth
      && rate(.long, stall: 2, seconds: 3) == .freeze)
check("worse picks the worse", R.smooth.worse(.slow) == .slow && R.failed.worse(.ok) == .failed)

print("\nFrame times")
let even = (0...90).map { Double($0) / 60 }
let s = FeatureTest.frameStats(even)
check("90 even frames at 60 Hz: 90 gaps of 16.7 ms", s?.count == 90 && abs((s?.median ?? 0) - 1.0 / 60) < 1e-9
      && abs((s?.p95 ?? 0) - 1.0 / 60) < 1e-9, "\(String(describing: s))")
var dropped = even
dropped.removeAll { [10, 20, 30, 40, 50, 60].map { Double($0) / 60 }.contains($0) }
let d = FeatureTest.frameStats(dropped.shuffled())
check("six dropped frames in 90: p95 at 33 ms, worst 33 ms, order not mattering",
      abs((d?.p95 ?? 0) - 2.0 / 60) < 1e-9 && abs((d?.worst ?? 0) - 2.0 / 60) < 1e-9, "\(String(describing: d))")
check("fewer than three frames say nothing", FeatureTest.frameStats([0, 0.016]) == nil)
check("the presented times when the system gave most of them, else the frames' starts",
      FeatureTest.frameTimes(began: [1, 2, 3, 4, 5], presented: [1.1, 2.1, 3.1, 4.1]) == [1.1, 2.1, 3.1, 4.1]
      && FeatureTest.frameTimes(began: [1, 2, 3, 4, 5], presented: [1.1, 2.1]) == [1, 2, 3, 4, 5])

print("\nThe report's lines")
let slow = FeatureTest.Result(index: 3, rating: .slow, stall: 0.412, seconds: 0.48, frames: nil,
                              peak: 612 * 1_048_576, name: "Edit Mode, on the large sphere",
                              detail: "Sphere, 64,226 vertices drawn")
let line = FeatureTest.line(slow)
check("rating, stall, time, frames, peak, name and detail on one line",
      line.hasPrefix("Slow    stall   412 ms  time    0.48 s  frames -")
      && line.contains("peak    612 MB  Edit Mode, on the large sphere — Sphere, 64,226 vertices drawn"), line)
check("and read back", FeatureTest.parse(line, index: 3) == slow, "\(String(describing: FeatureTest.parse(line, index: 3)))")
let drag = FeatureTest.Result(index: 9, rating: .smooth, stall: 0.018, seconds: 1.52,
                              frames: FeatureTest.FrameStats(count: 89, median: 0.0167, p95: 0.0171, worst: 0.0334),
                              peak: 1426 * 1_048_576, name: "Orbit (a one-finger drag)",
                              detail: "around Sphere — a dash\tand a tab")
let dragLine = FeatureTest.line(drag)
let back = FeatureTest.parse(dragLine, index: 9)
check("a drag's frame times read back to the tenth of a millisecond",
      dragLine.contains("frames 16.7/17.1/33.4 ms (89)") && back?.frames?.count == 89
      && abs((back?.frames?.p95 ?? 0) - 0.0171) < 1e-9 && back?.peak == 1426 * 1_048_576
      && back?.detail == "around Sphere — a dash and a tab", dragLine)
let failed = FeatureTest.Result(index: 1, rating: .failed, stall: 0.003, seconds: 0.02, frames: nil, peak: nil,
                                name: "Loop Cut (a tap shows the ring, a tap cuts)",
                                detail: "the second tap cut nothing:\nno edge")
let failedLine = FeatureTest.line(failed)
check("a failure with no memory read, its newline folded", failedLine.contains("peak      - MB")
      && !failedLine.contains("\n") && FeatureTest.parse(failedLine)?.rating == .failed
      && FeatureTest.parse(failedLine)?.peak == nil, failedLine)
check("other lines are not results", FeatureTest.parse("Summary:  1 run: 1 Smooth; 0 not tested; in 1.0 s") == nil
      && FeatureTest.parse("RUNNING  Orbit") == nil && FeatureTest.parse("Device:   iPad16,8") == nil)
check("counts worst first", FeatureTest.counts([slow, drag, failed, drag]) == "1 Failed, 1 Slow, 2 Smooth",
      FeatureTest.counts([slow, drag, failed, drag]))
check("the summary lists Failed, Freeze and Slow first, then OK, then Smooth",
      FeatureTest.worstFirst([drag, slow, failed]).map(\.rating) == [.failed, .slow, .smooth])
check("numbers and durations as the report writes them", FeatureTest.number(64226) == "64,226"
      && FeatureTest.number(999) == "999" && FeatureTest.duration(192.4) == "3 min 12.4 s"
      && FeatureTest.duration(4.25) == "4.2 s" || FeatureTest.duration(4.25) == "4.3 s")
check("megabytes with a thousands comma", MemoryFootprint.megabytes(1426 * 1_048_576) == "1,426 MB")

print("\nThe report, written as it goes")
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone.current
let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 14, minute: 3, second: 12))!
check("feature-test-<date-time>.txt, beside the Self-Test's",
      FeatureTest.reportName(at: date) == "feature-test-2026-11-01-14.03.12.txt"
      && SelfTest.reportName(at: date) == "self-test-2026-11-01-14.03.12.txt"
      && FeatureTest.folder == SelfTest.folder, FeatureTest.reportName(at: date))
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("featuretest-host-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let report = FeatureTest.Report(url: folder.appendingPathComponent("feature-test-2026-11-01-14.03.12.txt"),
                                about: [("Device", "iPad16,8"), ("iOS", "iPadOS 26.1"), ("RAM", "8.0 GB"),
                                        ("App", "Blender Local 1.0 (44)"), ("Blender", "5.2.1")])
report.running = "Orbit (a one-finger drag)"
report.record(slow)
check("the first write", report.write())
let stopped = FeatureTest.latestReport(in: folder)
check("a run that took the app down: found, with the feature it was running",
      stopped?.stoppedDuring == "Orbit (a one-finger drag)", "\(String(describing: stopped))")
let partial = (try? String(contentsOf: report.url, encoding: .utf8)) ?? ""
check("its header: device, iOS, RAM, app, Blender, and no total yet",
      partial.hasPrefix("Blender Local: Test All Features\n\nDevice:   iPad16,8\niOS:      iPadOS 26.1\nRAM:      8.0 GB\n"
                        + "App:      Blender Local 1.0 (44)\nBlender:  5.2.1\n")
      && partial.contains("Total:    did not finish (the last feature started is the last line)")
      && partial.contains("\nRUNNING  Orbit (a one-finger drag)\n"), partial)
report.running = nil
report.record(drag)
report.notTested = [("Add ▸ Image to 3D Model (Full 3D)", "it needs TripoSG's 7.95 GB download")]
report.total = 192.4
report.memory = "peak 1,426 MB over the app's life; 410 MB before the test, 520 MB after"
report.summary = FeatureTest.summary(report.results, notTested: 1, seconds: 192.4)
check("the last write", report.write())
let finished = FeatureTest.latestReport(in: folder)
let whole = (try? String(contentsOf: report.url, encoding: .utf8)) ?? ""
check("a finished run: found, and not said to have stopped; nothing left beside it",
      finished?.url.lastPathComponent == report.url.lastPathComponent && finished?.stoppedDuring == nil
      && (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == [report.url.lastPathComponent],
      "\(String(describing: finished)) \(String(describing: try? FileManager.default.contentsOfDirectory(atPath: folder.path)))")
check("its lines in the order run, what was not tested, and the summary last",
      whole.contains("Features: 2 run: 1 Slow, 1 Smooth; 1 not tested")
      && whole.contains("Total:    3 min 12.4 s")
      && whole.range(of: "Edit Mode, on the large sphere")!.lowerBound < whole.range(of: "Orbit (a one-finger")!.lowerBound
      && whole.contains("Not tested:\n  Add ▸ Image to 3D Model (Full 3D): it needs TripoSG's 7.95 GB download")
      && whole.hasSuffix("Summary:  2 run: 1 Slow, 1 Smooth; 1 not tested; in 3 min 12.4 s\n")
      && !whole.contains("RUNNING"), whole)
let lines = whole.split(separator: "\n").map(String.init).compactMap { FeatureTest.parse($0) }
check("every result line reads back", lines.map(\.name) == [slow.name, drag.name])
try! "Blender Local Self-Test\n\nPASS  1.00 s  a — b\nRUNNING  x\n"
    .write(to: folder.appendingPathComponent("self-test-2026-11-02-00.00.00.txt"), atomically: true, encoding: .utf8)
check("a newer Self-Test report is not taken for one of these",
      FeatureTest.latestReport(in: folder)?.url.lastPathComponent == report.url.lastPathComponent
      && SelfTest.latestReport(in: folder)?.stoppedDuring == "x")

print("\nThe Python sent, and what it answers")
let begin = FeatureTest.beginPython(saved: "/var/tmp/a \"b\".blend", historyRoot: "/var/Documents/.blender-history")
check("begin calls the module with quoted paths",
      begin == "import _blenderkit_featuretest as _bk_ft\n_bk_ft.begin(\"/var/tmp/a \\\"b\\\".blend\", "
      + "\"/var/Documents/.blender-history\")", begin)
check("end calls its end", FeatureTest.endPython.hasSuffix("_bk_ft.end()"))
let answer = FeatureTest.answer(in: ["Info: Saved \"x.blend\"",
                                     "[feature-test] {\"ok\": true, \"objects\": 3, \"blender\": \"5.2.1\"}"])
check("the answer is the last [feature-test] line's JSON", answer?["ok"] as? Bool == true
      && answer?["objects"] as? Int == 3 && answer?["blender"] as? String == "5.2.1")
check("no line, no answer", FeatureTest.answer(in: ["[self-test] start\t1\t2\tx"]) == nil)

print("\nThe inventory")
let inventory = FeatureTest.inventory
check("every key once", Set(inventory.map(\.key)).count == inventory.count)
check("every entry is run, or switched on, or says why not",
      inventory.allSatisfy { entry in
          switch entry.coverage {
          case .run: return true
          case .optIn(_, let reason), .notTested(let reason): return reason.count > 20
          }
      })
check("every name is one line, with no ' — ' (the report's separator)",
      inventory.allSatisfy { !$0.name.contains(" — ") && !$0.name.contains("\n") && !$0.name.isEmpty })
check("Cycles and Full 3D are not run by default, and say why",
      !FeatureTest.planned(cycles: false).contains { $0.key == "render.cycles" }
      && FeatureTest.planned(cycles: true).contains { $0.key == "render.cycles" }
      && FeatureTest.notPlanned(cycles: false).contains { $0.name.contains("Cycles") && $0.reason.contains("Metal kernels") }
      && FeatureTest.notPlanned(cycles: true).allSatisfy { !$0.name.contains("Cycles") }
      && FeatureTest.notPlanned(cycles: false).contains { $0.name.contains("Full 3D") && $0.reason.contains("7.95 GB") })
let areas = ["Workspaces", "File", "Add", "Adjust Last Operation", "View", "Select", "Tools", "Object", "Undo",
             "Outliner", "Properties", "Edit Mode", "Mesh", "Paint", "Sculpt", "Timeline", "Scripting", "Render",
             "Image to 3D", "Editors", "Input"]
check("every area of the app has entries", areas.allSatisfy { a in inventory.contains { $0.area == a } },
      areas.filter { a in !inventory.contains { $0.area == a } }.joined(separator: ", "))
check("every mode is entered: Edit, Sculpt, Vertex, Weight and Texture Paint, and Object Mode back",
      ["mode.edit_large", "mode.object_large", "mode.sculpt", "mode.vertex_paint", "mode.weight_paint",
       "mode.texture_paint", "mode.object_from_sculpt"].allSatisfy { k in FeatureTest.planned(cycles: false).contains { $0.key == k } })
check("the continuous interactions are drags, strokes and playback",
      Set(inventory.filter { $0.kind == .continuous }.map(\.key)) == ["view.orbit", "view.pan", "view.zoom",
          "tool.move", "tool.rotate", "tool.scale", "tool.measure", "select.box", "paint.vertex", "paint.weight",
          "paint.texture", "sculpt.draw", "anim.play", "anim.scrub"])

// The runner is the interface's (it drives the 3D View), so it is read as
// source: a `case "key"` for every key that runs, and no case for a key the
// inventory does not have.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let runner = (try? String(contentsOf: root.appendingPathComponent("Sources/BlenderLocalUI/Chrome/FeatureTestRunner.swift"),
                          encoding: .utf8)) ?? ""
check("the runner's source was read", runner.contains("func perform(_ entry: FeatureTest.Entry)"))
let regex = try! NSRegularExpression(pattern: #"case ((?:"[a-z0-9_.]+"(?:, )?)+):"#)
var cased = Set<String>()
for m in regex.matches(in: runner, range: NSRange(runner.startIndex..., in: runner)) {
    let text = String(runner[Range(m.range(at: 1), in: runner)!])
    for key in text.split(separator: ",") {
        cased.insert(key.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }
}
// The Add menu's mesh rows share one case, by PrimitiveKind.
if runner.contains(#"key.hasPrefix("add.") && PrimitiveKind(rawValue:"#) {
    for kind in PrimitiveKind.allCases { cased.insert("add.\(kind.rawValue)") }
}
let runs = Set(inventory.filter { $0.kind != nil }.map(\.key))
check("every feature that runs has its case in the runner", runs.subtracting(cased).isEmpty,
      runs.subtracting(cased).sorted().joined(separator: ", "))
check("and the runner has no case the inventory lacks", cased.subtracting(runs).isEmpty,
      cased.subtracting(runs).sorted().joined(separator: ", "))
check("not-tested entries have no case (they would never run)",
      Set(inventory.filter { $0.kind == nil }.map(\.key)).isDisjoint(with: cased))

print("\nWhat the sheet says before Run")
check("that the scene is saved, opened again, and the undo history ends there",
      FeatureTest.undoNotice.contains("saved first and opened again")
      && FeatureTest.undoNotice.contains("Undo cannot go back past the test"))
check("how many vertices the large sphere has, as the run makes it",
      FeatureTest.sphereVertices == 64_226 && FeatureTest.notice.contains("64,226"))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
