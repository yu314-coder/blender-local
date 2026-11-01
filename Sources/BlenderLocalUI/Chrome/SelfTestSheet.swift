import SwiftUI
import UIKit

/// What the Self-Test sheet shows of a run, as its progress lines arrive.
@Observable
final class SelfTestRun {
    var running = false
    var index = 0
    var total = 0
    var current = ""
    var results: [SelfTest.Result] = []
    var summary: String?
    var report: URL?
    var text = ""
    var wroteNothing = false

    func start() {
        running = true
        index = 0
        total = 0
        current = "Saving your scene"
        results = []
        summary = nil
        report = nil
        text = ""
        wroteNothing = false
    }

    func apply(_ event: SelfTest.Event) {
        switch event {
        case .started(let index, let total, let name):
            self.index = index
            self.total = total
            current = name
        case .finished(let result, let total):
            self.total = total
            results.removeAll { $0.index == result.index }
            results.append(result)
        case .ended(let passed, let failed, let seconds, _):
            summary = "\(passed) of \(passed + failed) passed, \(failed) failed, in "
                + (seconds < 60 ? String(format: "%.1f s", seconds)
                                : String(format: "%d min %.0f s", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)))
        case .history:
            break
        }
    }

    func finish(_ url: URL?) {
        running = false
        report = url
        text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        wroteNothing = url == nil
    }
}

/// The Self-Test: Run, the checks as they pass or fail, and the report to copy
/// or share. Opened by its button in Preferences ▸ Testing (`PreferencesSheet`).
struct SelfTestSheet: View {
    var session: BpySession
    @Environment(\.dismiss) private var dismiss
    @State private var run = SelfTestRun()
    @State private var copied = false
    @State private var earlier = SelfTest.latestReport()

    var body: some View {
        NavigationStack {
            List {
                if !run.running && run.report == nil && run.results.isEmpty {
                    Section {
                        Text(SelfTest.notice)
                        Text(SelfTest.undoNotice).foregroundStyle(BTheme.active)
                        Text("The report is saved in Files ▸ Blender Local ▸ Self-Test.")
                            .foregroundStyle(BTheme.textDim)
                        if !session.usesRealBlender {
                            Text("This build runs the stand-in for Blender's module, which the Self-Test cannot check.")
                                .foregroundStyle(BTheme.error)
                        }
                    }
                    if let earlier, let stopped = earlier.stoppedDuring {
                        Section("The last Self-Test did not finish") {
                            Text("It stopped during: \(stopped)")
                            ShareLink(item: earlier.url) {
                                Label("Share Its Report", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
                if run.running || run.total > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(run.results.count), total: Double(max(run.total, 1)))
                            Text(run.running
                                 ? (run.total > 0 ? "Check \(run.index) of \(run.total): \(run.current)" : run.current)
                                 : (run.summary ?? ""))
                                .font(BTheme.Font.ui(13))
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !run.results.isEmpty {
                    Section("Checks") {
                        ForEach(run.results) { result in row(result) }
                    }
                }
                if let report = run.report, !run.running {
                    Section("Report") {
                        Text("Files ▸ Blender Local ▸ Self-Test ▸ \(report.lastPathComponent)")
                            .font(BTheme.Font.ui(12))
                    }
                }
                if run.wroteNothing {
                    Section {
                        Text("The Self-Test did not write a report. The console has what Blender said.")
                            .foregroundStyle(BTheme.error)
                    }
                }
            }
            .navigationTitle("Self-Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(run.running)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Run") { start() }.disabled(!canRun)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(copied ? "Copied" : "Copy Report") {
                        UIPasteboard.general.string = run.text
                        copied = true
                    }
                    .disabled(run.running || run.text.isEmpty)
                    Spacer()
                    if let report = run.report, !run.running {
                        ShareLink(item: report) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        .interactiveDismissDisabled(run.running)
        #if DEBUG
        // `-self-test` (`SelfTestLaunch`): Run, pressed once the sheet is up.
        .onAppear {
            guard SelfTestLaunch.requested, !SelfTestLaunch.ran else { return }
            SelfTestLaunch.ran = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if canRun { start() } }
        }
        #endif
    }

    private var canRun: Bool {
        !run.running && !session.isRunning && session.gestureHold == nil && session.usesRealBlender
    }

    private func start() {
        run.start()
        copied = false
        // A turn for the sheet to be drawn as running before the main thread
        // goes into Blender.
        DispatchQueue.main.async {
            let report = session.runSelfTest(about: Self.about()) { event in run.apply(event) }
            run.finish(report)
            earlier = SelfTest.latestReport()
            #if DEBUG
            if SelfTestLaunch.requested {
                print("[bk-selftest] ended: \(run.summary ?? "no summary") · \(report?.path ?? "no report")")
                fflush(stdout)
            }
            #endif
        }
    }

    @ViewBuilder
    private func row(_ result: SelfTest.Result) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(result.passed ? "PASS" : "FAIL")
                .font(BTheme.Font.mono(11).weight(.bold))
                .foregroundStyle(result.passed ? Color.green : BTheme.error)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name).font(BTheme.Font.ui(13))
                Text(result.detail).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
            Spacer(minLength: 8)
            Text(String(format: "%.2f s", result.seconds))
                .font(BTheme.Font.mono(11))
                .foregroundStyle(BTheme.textDim)
        }
        .padding(.vertical, 2)
    }

    /// The report's header: the device, iOS, RAM, and the app's version and
    /// build.
    static func about() -> [(String, String)] {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        let device = ProcessInfo.processInfo.isiOSAppOnMac
            ? "\(sysctl("hw.model") ?? "Mac") (the iPad app on a Mac)"
            : (sysctl("hw.machine") ?? UIDevice.current.model)
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return [("Device", device),
                ("iOS", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"),
                ("RAM", String(format: "%.1f GB", memory)),
                ("App", "Blender Local \(StatusBar.versionString)")]
    }
}
