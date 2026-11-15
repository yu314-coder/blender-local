import Foundation

/// Reading Blender's own progress line, which it hands to a `render_stats`
/// handler as the render goes.
///
/// The two engines word it differently, and both were taken from a running
/// render rather than from the manual:
///
///     Cycles: "Remaining: 03:15.18 | Mem: 5976M | Sample 1/128 (Using optimized kernels)"
///     Eevee:  "Rendering 1 / 64 samples"
///     last:   "Time: 00:09.62 (Saving: 00:00.21)"
///
/// Reading the first two numbers in the line, which is what this did first,
/// gives 3/15 from the clock in the Cycles one — a bar that fills to a fifth
/// on the first sample.
public enum RenderingWorkspaceProgress {

    /// What to show under the image, and how full the bar is.
    public static func read(_ line: String) -> (text: String, fraction: Double?) {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let samples = samples(in: raw) else {
            // No sample count: the closing time line, or a stage like
            // "Compositing" or "Loading render kernels".
            return (shortened(raw), nil)
        }
        var text = "Sample \(samples.done) of \(samples.total)"
        if let remaining = remaining(in: raw) { text += " · \(remaining) left" }
        return (text, min(max(Double(samples.done) / Double(samples.total), 0), 1))
    }

    /// Time left, from the rate the samples are actually coming at since
    /// `start` (the first line with a sample done): "0:42", or nil until a
    /// second of sampling has been seen.
    ///
    /// Cycles' own "Remaining" counts its setup — kernel loading, the scene
    /// sent to the GPU — as sampling time: in the app it said 57:42 after
    /// the first of 1024 samples and 0:48 at the 128th, with 6.6 s of
    /// sampling actually left (M4, November 15).
    public static func estimate(done: Int, total: Int, start: (done: Int, at: Date), now: Date) -> String? {
        let elapsed = now.timeIntervalSince(start.at)
        let made = done - start.done
        guard elapsed >= 1, made > 0, total > done else { return total == done && made > 0 ? "0:00" : nil }
        let left = Int((Double(total - done) * elapsed / Double(made)).rounded(.up))
        return left >= 3600 ? String(format: "%d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
                            : String(format: "%d:%02d", left / 60, left % 60)
    }

    /// What the panel says once Cycles has stopped sampling and is denoising.
    public static let denoisingText = "Denoising"

    /// Whether Cycles is denoising: it sends no line for it. Its stats go
    /// from the last sample batch straight to "Finished" — "Sample 1008/1024"
    /// then nothing for the 7–15 s OpenImageDenoise took on the CPU at
    /// 1280 × 720 in the app (M4, November 15), so the panel read
    /// "0:00 left" and looked hung. So: denoising is on, the last line had
    /// the samples all but done (its estimate at 0:00, or 98 % of them), and
    /// nothing new has come for `quiet` seconds.
    public static func denoising(after line: String, quiet: TimeInterval, denoises: Bool) -> Bool {
        guard denoises, quiet >= 0.8 else { return false }
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let samples = samples(in: raw) else { return false }
        if remaining(in: raw) == "0:00" { return true }
        return Double(samples.done) >= 0.98 * Double(samples.total)
    }

    /// "Sample 1/128" from Cycles, "Rendering 1 / 64 samples" from Eevee.
    public static func samples(in line: String) -> (done: Int, total: Int)? {
        for pattern in [#"Sample\s+(\d+)\s*/\s*(\d+)"#, #"Rendering\s+(\d+)\s*/\s*(\d+)\s+samples"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges == 3,
                  let first = Range(match.range(at: 1), in: line),
                  let second = Range(match.range(at: 2), in: line),
                  let done = Int(line[first]), let total = Int(line[second]), total > 0
            else { continue }
            return (done, total)
        }
        return nil
    }

    /// Cycles' own estimate, as "3:15" rather than "03:15.18".
    static func remaining(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"Remaining:\s*([\d:.]+)"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        var parts = line[range].split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        // Drop the fraction of a second, and a leading zero hour or minute.
        parts[parts.count - 1] = parts[parts.count - 1].split(separator: ".").first.map(String.init) ?? "0"
        while parts.count > 2, parts[0] == "00" { parts.removeFirst() }
        if parts.count > 1, parts[0].hasPrefix("0"), parts[0].count == 2 { parts[0].removeFirst() }
        return parts.joined(separator: ":")
    }

    /// A stage line, short enough for one row under the image: the part of
    /// it that says what Blender is doing. Cycles leads with its memory —
    /// "Mem:5825.27M, Peak:5825.27M | Loading render kernels (may take a few
    /// minutes the first time)" — and the panel used to show "Mem: 5825M"
    /// through the whole first kernel build (measured in the app, November 9).
    static func shortened(_ line: String) -> String {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let bookkeeping = ["Mem", "Peak", "Remaining", "Frame:", "Fra:", "Time:"]
        if let stage = parts.first(where: { part in !bookkeeping.contains { part.hasPrefix($0) } }) {
            return stage
        }
        return parts.first ?? line.trimmingCharacters(in: .whitespaces)
    }
}


/// Blender's render stats line, as its Image Editor draws it over a Render
/// Result: "Frame:1 | Time:00:13.02 | Remaining:00:05 | Mem:2841.00M, Peak:2969.00M |
/// Sample 65/128". Mem here is the app's footprint (what iPadOS measures),
/// where Blender's is the render's own allocations.
public enum RenderStatsLine {
    public static func text(frame: Int, seconds: Double, remaining: String?,
                            memory: (now: UInt64, peak: UInt64), progress: String) -> String {
        var parts = ["Frame:\(frame)", "Time:\(clock(seconds))"]
        if let remaining { parts.append("Remaining:\(remaining)") }
        if memory.now > 0 {
            parts.append(String(format: "Mem:%.2fM, Peak:%.2fM",
                                Double(memory.now) / 1_048_576, Double(memory.peak) / 1_048_576))
        }
        if !progress.isEmpty { parts.append(progress) }
        return parts.joined(separator: " | ")
    }

    /// Blender's "00:13.02": minutes, seconds and hundredths; hours first
    /// past an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        let hundredths = Int((s * 100).rounded(.down))
        let h = hundredths / 360_000, m = hundredths / 6000 % 60, sec = hundredths / 100 % 60, c = hundredths % 100
        return h > 0 ? String(format: "%02d:%02d:%02d.%02d", h, m, sec, c)
                     : String(format: "%02d:%02d.%02d", m, sec, c)
    }
}
