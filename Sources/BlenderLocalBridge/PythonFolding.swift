import Foundation

/// Monaco's `folding: true`, for Python.
///
/// Python has no braces, so the only thing that says where a block ends is
/// where the indentation goes back — which is exactly how Monaco folds it, and
/// how this does. A line opens a region when the next line with anything on it
/// is indented further; the region runs to the last line before the
/// indentation returns to that level or above.
///
/// Blank lines and comment-only lines belong to whatever surrounds them rather
/// than ending a region, or every paragraph break inside a function would close
/// it.
public enum PythonFolding {

    public struct Region: Equatable, Sendable {
        /// 1-based, the line the chevron sits on and the one left visible.
        public let startLine: Int
        /// 1-based, the last line hidden when it is folded.
        public let endLine: Int
        /// How deep the opening line is, so nested regions can be told apart.
        public let indent: Int

        public init(startLine: Int, endLine: Int, indent: Int) {
            self.startLine = startLine; self.endLine = endLine; self.indent = indent
        }
    }

    public static func regions(in text: String) -> [Region] {
        let lines = text.components(separatedBy: "\n")
        // Nil for a line with nothing on it: it has no indentation of its own,
        // and treating its zero as real would close every block above a blank.
        let indents: [Int?] = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : BracketMatch.indentColumns(of: line)
        }
        // Where a comment sits says nothing about structure. Python's own
        // grammar ignores its indentation entirely, so a `#` line flush to the
        // left margin in the middle of a function is still inside it — and
        // treating its zero as real closed the function there and opened a
        // second, phantom region on the comment itself.
        let comment: [Bool] = lines.map {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }

        var out: [Region] = []
        for i in lines.indices {
            guard let mine = indents[i], !comment[i] else { continue }

            // The next line with anything on it. If it is deeper, this opens.
            var j = i + 1
            while j < lines.count, indents[j] == nil { j += 1 }
            guard j < lines.count, let next = indents[j], next > mine else { continue }

            // Run on until the indentation comes back to this level or above.
            var end = j
            var k = j
            while k < lines.count {
                if let here = indents[k] {
                    if !comment[k], here <= mine { break }
                    if here > mine { end = k }
                }
                k += 1
            }
            out.append(Region(startLine: i + 1, endLine: end + 1, indent: mine))
        }
        return out
    }

    /// The character range hidden when the region at `startLine` is folded:
    /// everything after that line's own text, through the end of `endLine`.
    ///
    /// The newline at the end of the opening line stays visible, otherwise the
    /// folded line runs into the one after it.
    public static func hiddenRange(for region: Region, in text: String) -> NSRange? {
        let ns = text as NSString
        guard let start = lineRange(ns, region.startLine),
              let end = lineRange(ns, region.endLine)
        else { return nil }
        let from = NSMaxRange(start)
        let to = NSMaxRange(end)
        guard to > from, to <= ns.length else { return nil }
        return NSRange(location: from, length: to - from)
    }

    /// The range of a 1-based line, newline included.
    public static func lineRange(_ ns: NSString, _ line: Int) -> NSRange? {
        guard line >= 1 else { return nil }
        var location = 0
        var current = 1
        while current < line {
            guard location < ns.length else { return nil }
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        guard location <= ns.length else { return nil }
        return ns.lineRange(for: NSRange(location: min(location, max(ns.length - 1, 0)), length: 0))
    }
}
