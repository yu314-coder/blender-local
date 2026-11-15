import SwiftUI

/// The app's memory in the top bar: the last minute as a line, the footprint
/// now beside it — what iPadOS measures when it ends an app for its memory,
/// so a render climbing toward the limit shows before it gets there. Blender
/// shows the same in its status bar (System Memory); here it is on the top
/// bar, where it stays in view over the Render sheet's edge.
///
/// One `proc_pid_rusage` call a second (MemoryFootprint), drawn by this view
/// alone, so the rest of the top bar does not redraw with it.
struct MemoryGauge: View {
    var compact = false
    @State private var samples: [Double] = []
    @State private var peak: UInt64 = 0
    @State private var current: UInt64 = 0
    @State private var showsDetails = false
    /// The process's budget, read at launch (0 on a Mac, where nothing ends
    /// an app for its memory).
    private let budget = CyclesMemory.processBudget()

    static let window = 60

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 6) {
                MemorySparkline(samples: samples, ceiling: ceiling, colour: colour)
                    .frame(width: compact ? 34 : 56, height: 18)
                if !compact {
                    Text(MemoryGauge.short(current))
                        .font(BTheme.Font.mono(11))
                        .foregroundStyle(colour == BTheme.textDim ? BTheme.text : colour)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(BTheme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Memory \(MemoryGauge.short(current))")
        .help("Memory: what Blender Local is using now, over the last minute")
        .popover(isPresented: $showsDetails) { details }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in sample() }
        .onAppear { sample() }
    }

    /// The line's top: the budget where there is one, else the highest seen.
    private var ceiling: Double {
        budget > 0 ? Double(budget) : max(samples.max() ?? 1, 1) * 1.15
    }

    private var fraction: Double { budget > 0 ? Double(current) / Double(budget) : 0 }

    private var colour: Color {
        switch fraction {
        case 0.85...: return .red
        case 0.65...: return .orange
        default: return budget > 0 ? Color(red: 0.42, green: 0.75, blue: 0.45) : BTheme.textDim
        }
    }

    private func sample() {
        guard let now = MemoryFootprint.now() else { return }
        current = now.current
        peak = now.peak
        samples.append(Double(now.current))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory").font(BTheme.Font.ui(13, weight: .semibold)).foregroundStyle(BTheme.text)
            MemorySparkline(samples: samples, ceiling: ceiling, colour: colour)
                .frame(width: 240, height: 60)
            row("Now", MemoryFootprint.megabytes(current))
            row("Peak", MemoryFootprint.megabytes(peak))
            if budget > 0 {
                row("Limit", MemoryFootprint.megabytes(budget))
                Text("iPadOS closes an app that goes past its limit. Renders use the most: "
                     + "a lower Resolution %, fewer samples or Eevee use less.")
                    .font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(BTheme.menuBack)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(BTheme.textDim)
            Spacer()
            Text(value).foregroundStyle(BTheme.text).monospacedDigit()
        }
        .font(BTheme.Font.ui(12))
    }

    /// "812 MB", "2.8 GB".
    static func short(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

/// The samples as a filled line, oldest at the left, scaled to `ceiling`.
struct MemorySparkline: View {
    var samples: [Double]
    var ceiling: Double
    var colour: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, ceiling > 0 else { return }
            let step = size.width / CGFloat(MemoryGauge.window - 1)
            let start = size.width - step * CGFloat(samples.count - 1)
            func point(_ i: Int) -> CGPoint {
                let v = min(samples[i] / ceiling, 1)
                return CGPoint(x: start + step * CGFloat(i), y: size.height * (1 - v))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<samples.count { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: start, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(colour.opacity(0.25)))
            context.stroke(line, with: .color(colour), lineWidth: 1.2)
        }
    }
}
