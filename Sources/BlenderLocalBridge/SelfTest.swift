import Foundation

/// The Self-Test: every check in `Resources/python/site/_blenderkit_selftest.py`
/// run in the app, one after another, with a plain-text report.
///
/// An app-only feature, so it keeps its own name. Preferences ▸ Testing has
/// its button (Preferences is the top bar's gear, and File ▸ Preferences…).
/// It ships in Release, because the build a user installs from TestFlight is
/// the one it has to hold to the desktop Blender checks.
///
/// The Python is built here, and run by `BpySession.runSelfTest` on the main
/// thread, where Blender's window is: the checks call `temp_override`, Undo,
/// file loads and a render, which the script thread cannot. Its progress comes
/// back as console lines (`_blenderkit_selftest.console_progress`), read by
/// `event(_:)`.
public enum SelfTest {
    /// Documents/Self-Test, which the Files app shows. `SceneDocument.listSaved`
    /// lists only the top of Documents, so no report reaches Open Recent.
    public static var folder: URL {
        SceneDocument.documentsURL.appendingPathComponent("Self-Test", isDirectory: true)
    }

    /// `self-test-2026-10-30-14.03.12.txt`: the date, so the folder reads in
    /// order and nothing is overwritten. Test All Features names its reports
    /// the same way with its own prefix (`FeatureTest.reportName`).
    public static func reportName(at date: Date = Date(), prefix: String = "self-test-") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return "\(prefix)\(f.string(from: date)).txt"
    }

    /// The last check's render: the Render panel's own script, EEVEE at Draft,
    /// 64 × 64, through the scene camera of Blender's startup file.
    public static func render(output: String) -> RenderRequest {
        RenderRequest(engine: .eevee, quality: .draft, width: 64, height: 64,
                      source: .sceneCamera, output: output)
    }

    /// The Python the app runs: `_blenderkit_selftest.run`, the report written
    /// to `report`, the header's `about` pairs (device, iOS, RAM, the app's
    /// version and build), the history's folder, and the render's script.
    public static func python(report: String, historyRoot: String, renderOutput: String,
                              about: [(String, String)]) -> String {
        let pairs = about.map { "[\(Bpy.quote($0.0)), \(Bpy.quote($0.1))]" }.joined(separator: ", ")
        return [
            "import _blenderkit_selftest as _bk_selftest",
            "_bk_selftest.run(\(Bpy.quote(report)), progress=_bk_selftest.console_progress,",
            "                 about=[\(pairs)],",
            "                 history_root=\(Bpy.quote(historyRoot)),",
            "                 render_source=\(Bpy.quote(render(output: renderOutput).python)),",
            "                 render_output=\(Bpy.quote(renderOutput)))",
        ].joined(separator: "\n")
    }

    /// One check's outcome, as the report has it.
    public struct Result: Equatable, Identifiable, Sendable {
        public let index: Int
        public let passed: Bool
        public let seconds: Double
        public let name: String
        public let detail: String
        public var id: Int { index }

        public init(index: Int, passed: Bool, seconds: Double, name: String, detail: String) {
            self.index = index
            self.passed = passed
            self.seconds = seconds
            self.name = name
            self.detail = detail
        }
    }

    /// What a progress line says.
    public enum Event: Equatable, Sendable {
        /// Check `index` of `total` has started.
        case started(index: Int, total: Int, name: String)
        /// And has ended.
        case finished(Result, total: Int)
        /// The run has ended, the report written.
        case ended(passed: Int, failed: Int, seconds: Double, report: String)
        /// The history's state after the run (`_blenderkit_undo.state()`, JSON),
        /// for the interface's Undo and Redo.
        case history(String)
    }

    static let prefix = "[self-test] "

    /// The event a console line carries, or nil for any other line: the
    /// checks' own output (Blender's reports, the gate's words) is not shown.
    public static func event(_ line: String) -> Event? {
        guard line.hasPrefix(prefix) else { return nil }
        let fields = line.dropFirst(prefix.count)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case "start":
            guard fields.count >= 4, let index = Int(fields[1]), let total = Int(fields[2]) else { return nil }
            return .started(index: index, total: total, name: fields[3])
        case "done":
            guard fields.count >= 7, let index = Int(fields[1]), let total = Int(fields[2]),
                  fields[3] == "PASS" || fields[3] == "FAIL", let seconds = Double(fields[4]) else { return nil }
            return .finished(Result(index: index, passed: fields[3] == "PASS", seconds: seconds,
                                    name: fields[5], detail: fields[6...].joined(separator: " ")), total: total)
        case "end":
            guard fields.count >= 6, let passed = Int(fields[1]), let failed = Int(fields[2]),
                  let seconds = Double(fields[4]) else { return nil }
            return .ended(passed: passed, failed: failed, seconds: seconds,
                          report: fields[5...].joined(separator: "\t"))
        case "history":
            guard fields.count >= 2 else { return nil }
            return .history(fields[1...].joined(separator: "\t"))
        default:
            return nil
        }
    }

    /// The newest report in the folder whose name starts with `prefix`, and
    /// the check it was running when it stopped if it has no summary line: a
    /// run that took the app down. Test All Features' reports are read the
    /// same way (`FeatureTest.latestReport`).
    public static func latestReport(in folder: URL = folder,
                                    prefix: String = "self-test-") -> (url: URL, stoppedDuring: String?)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let newest = files.filter({ $0.lastPathComponent.hasPrefix(prefix)
                                          && $0.pathExtension == "txt" })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return nil }
        let text = (try? String(contentsOf: newest, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(where: { $0.hasPrefix("Summary:  ") }) { return (newest, nil) }
        let running = lines.last(where: { $0.hasPrefix("RUNNING  ") })
            .map { String($0.dropFirst("RUNNING  ".count)) }
        return (newest, running ?? "its first check")
    }

    /// Said on the sheet before Run.
    public static let notice = """
        Runs the app's own checks on this device, one after another: the crash paths fixed in fix round 3, \
        the operators the app refuses, one vertex-budget refusal of each kind, ordinary edits and their \
        times, the viewport's mirror pass and a small EEVEE render. About a minute; keep Blender Local open \
        until it ends.
        """

    /// Said beside it: what Run does to the open scene.
    public static let undoNotice = """
        Your scene is saved first and opened again when the test ends, and the report says whether it came \
        back exactly. Opening it ends Blender's undo history: afterwards Undo cannot go back past the Self-Test.
        """
}

/// The history's state the run printed last, kept by the console sink until
/// the run ends (`BpySession.runSelfTest`).
final class SelfTestHistory: @unchecked Sendable {
    var state: String?
}
