import SwiftUI
import UIKit

/// Test All Features: Run, each feature's rating as it ends, then the
/// summary — Slow, Freeze and Failed first, then OK, then Smooth — and the
/// report to copy or share. Opened by its button in Preferences ▸ Testing
/// (`PreferencesSheet`).
struct FeatureTestSheet: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    @Binding var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var run = FeatureTestRun()
    @State private var copied = false
    @State private var cycles = false
    @State private var earlier = FeatureTest.latestReport()

    var body: some View {
        NavigationStack {
            List {
                if !run.running && run.report == nil && run.results.isEmpty {
                    Section {
                        Text(FeatureTest.notice)
                        Text(FeatureTest.undoNotice).foregroundStyle(BTheme.active)
                        Text("The report is saved in Files ▸ Blender Local ▸ Self-Test.")
                            .foregroundStyle(BTheme.textDim)
                        if !session.usesRealBlender {
                            Text("This build runs the stand-in for Blender's module, which Test All Features cannot run.")
                                .foregroundStyle(BTheme.error)
                        }
                    }
                    Section {
                        Toggle("Include Cycles", isOn: $cycles)
                        Text("Cycles' first GPU render builds its Metal kernels, which takes minutes. Off, the "
                             + "test renders with EEVEE only and lists Cycles as not tested.")
                            .font(BTheme.Font.ui(12))
                            .foregroundStyle(BTheme.textDim)
                    }
                    if let earlier, let stopped = earlier.stoppedDuring {
                        Section("The last Test All Features did not finish") {
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
                            ProgressView(value: Double(min(run.results.count + run.notTested.count, run.total)),
                                         total: Double(max(run.total, 1)))
                            Text(run.running
                                 ? (run.total > 0 ? "Feature \(run.index) of \(run.total): \(run.current)" : run.current)
                                 : (run.summary ?? ""))
                                .font(BTheme.Font.ui(13))
                            if let restored = run.restored, !run.running {
                                Text(restored).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let refusal = run.refusal {
                    Section { Text(refusal).foregroundStyle(BTheme.error) }
                }
                if run.running {
                    if !run.results.isEmpty {
                        Section("Features") {
                            ForEach(run.results.reversed()) { result in row(result) }
                        }
                    }
                } else if !run.results.isEmpty {
                    let ordered = FeatureTest.worstFirst(run.results)
                    let bad = ordered.filter { $0.rating.severity >= FeatureTest.Rating.slow.severity }
                    let ok = ordered.filter { $0.rating == .ok }
                    let smooth = ordered.filter { $0.rating == .smooth }
                    if !bad.isEmpty { Section("Slow, Freeze and Failed") { ForEach(bad) { row($0) } } }
                    if !ok.isEmpty { Section("OK") { ForEach(ok) { row($0) } } }
                    if !smooth.isEmpty { Section("Smooth") { ForEach(smooth) { row($0) } } }
                    if !run.notTested.isEmpty {
                        Section("Not tested") {
                            ForEach(run.notTested.indices, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.notTested[i].name).font(BTheme.Font.ui(13))
                                    Text(run.notTested[i].reason).font(BTheme.Font.ui(11))
                                        .foregroundStyle(BTheme.textDim)
                                }
                            }
                        }
                    }
                    Section { Text(FeatureTest.legend).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim) }
                }
                if let report = run.report, !run.running {
                    Section("Report") {
                        Text("Files ▸ Blender Local ▸ Self-Test ▸ \(report.lastPathComponent)")
                            .font(BTheme.Font.ui(12))
                    }
                }
            }
            .navigationTitle("Test All Features")
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
        // `-feature-test` (`FeatureTestLaunch`): Run, pressed once the sheet is up.
        .onAppear {
            guard FeatureTestLaunch.requested, !FeatureTestLaunch.ran else { return }
            FeatureTestLaunch.ran = true
            cycles = FeatureTestLaunch.cycles
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if canRun { start() } else {
                    print("[bk-featuretest] ended: could not run (a script or a stroke was running, or no Blender)")
                    fflush(stdout)
                }
            }
        }
        #endif
    }

    private var canRun: Bool {
        !run.running && !session.isRunning && session.gestureHold == nil && session.usesRealBlender && bridge != nil
    }

    private func start() {
        guard let bridge else { return }
        run.start()
        copied = false
        let runner = FeatureTestRunner(scene: scene, session: session, bridge: bridge,
                                       workspace: $workspace, cycles: cycles, run: run)
        // A turn for the sheet to be drawn as running before the first feature.
        DispatchQueue.main.async {
            Task { @MainActor in
                let report = await runner.runAll(about: SelfTestSheet.about())
                run.finish(report)
                earlier = FeatureTest.latestReport()
                #if DEBUG
                if FeatureTestLaunch.requested {
                    print("[bk-featuretest] ended: \(run.summary ?? run.refusal ?? "no summary") · "
                          + "\(run.restored ?? "") · \(report?.path ?? "no report")")
                    fflush(stdout)
                }
                #endif
            }
        }
    }

    private func colour(_ rating: FeatureTest.Rating) -> Color {
        switch rating {
        case .smooth: return .green
        case .ok: return BTheme.active
        case .slow: return .orange
        case .freeze, .failed: return BTheme.error
        }
    }

    @ViewBuilder
    private func row(_ result: FeatureTest.Result) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(result.rating.rawValue)
                .font(BTheme.Font.mono(11).weight(.bold))
                .foregroundStyle(colour(result.rating))
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name).font(BTheme.Font.ui(13))
                Text(result.detail).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.0f ms", result.stall * 1000))
                    .font(BTheme.Font.mono(11))
                Text(result.frames.map { String(format: "%.0f ms p95", $0.p95 * 1000) }
                     ?? String(format: "%.2f s", result.seconds))
                    .font(BTheme.Font.mono(11))
                    .foregroundStyle(BTheme.textDim)
            }
        }
        .padding(.vertical, 2)
    }
}
