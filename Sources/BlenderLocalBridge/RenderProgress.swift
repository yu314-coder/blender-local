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

    /// "Sample 1/128" from Cycles, "Rendering 1 / 64 samples" from Eevee.
    static func samples(in line: String) -> (done: Int, total: Int)? {
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

    /// A stage line, short enough for one row under the image.
    static func shortened(_ line: String) -> String {
        let head = line.split(separator: "|").first.map(String.init) ?? line
        return head.trimmingCharacters(in: .whitespaces)
    }
}
