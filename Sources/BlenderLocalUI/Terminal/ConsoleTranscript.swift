import Foundation

/// The session's console, as text for a terminal.
///
/// The console is the record and the terminal a view of it. Lines already on
/// the screen are left alone and new ones are printed above the prompt. What
/// rewrites lines already shown — Clear, or a failed run replacing the output
/// it streamed with the same lines marked as errors — repaints from the record.
struct ConsoleTranscript {

    struct Entry: Equatable {
        var id: UUID
        var kind: BpyLine.Kind
        var text: String

        init(_ line: BpyLine) {
            id = line.id
            kind = line.kind
            text = line.text
        }
    }

    enum Update: Equatable {
        case none
        /// Print this above the prompt.
        case append(String)
        /// Clear the screen and print this.
        case repaint(String)
    }

    /// How much of a long console a repaint brings back.
    static let repaintLimit = 2000

    /// Every console line on the screen, in step with the console's indices.
    private var shown: [Entry] = []
    /// The screen no longer matches `shown`, and the next update repaints.
    private var stale = true

    /// Forget what is on screen, so the next update repaints.
    mutating func invalidate() { stale = true }

    /// Whether the console has changed since it was last shown.
    ///
    /// Cheap enough to ask on every SwiftUI update, and enough to answer: the
    /// console only ever grows, has its end replaced, or is replaced whole, and
    /// each of those moves its length or its first or last line.
    func differs(from console: [BpyLine]) -> Bool {
        stale || shown.count != console.count
            || shown.first?.id != console.first?.id || shown.last?.id != console.last?.id
    }

    /// - Parameter alreadyShown: lines of `console` that are on the screen
    ///   already although this never printed them — a console command's
    ///   output, drawn as it was written. They count as shown and are not
    ///   printed again.
    mutating func update(to console: [BpyLine], alreadyShown: Range<Int>? = nil) -> Update {
        // A new first line means the console was replaced — Clear — even when
        // the banner that replaced it reads the same.
        guard !stale, let first = console.first, let firstShown = shown.first, first.id == firstShown.id else {
            return repaint(console)
        }
        // Nothing already shown has changed: print what is new.
        let last = shown.count - 1
        if console.count >= shown.count, console[last].id == shown[last].id {
            guard console.count > shown.count else { return .none }
            let added = console[shown.count...]
            shown.append(contentsOf: added.map(Entry.init))
            return Self.appending(added, skipping: alreadyShown)
        }
        // A run's streamed lines come back with new identities when it
        // finishes. Where they still say the same thing, nothing on screen is
        // wrong and nothing needs redrawing.
        var same = 0
        while same < shown.count, same < console.count,
              shown[same].id == console[same].id
                || (shown[same].kind == console[same].kind && shown[same].text == console[same].text) {
            same += 1
        }
        guard same == shown.count else { return repaint(console) }
        shown = console.map(Entry.init)
        return same < console.count ? Self.appending(console[same...], skipping: alreadyShown) : .none
    }

    /// The new lines to print, less the ones already on the screen.
    private static func appending(_ lines: ArraySlice<BpyLine>, skipping: Range<Int>?) -> Update {
        let unshown = lines.indices.filter { !(skipping?.contains($0) ?? false) }.map { lines[$0] }
        return unshown.isEmpty ? .none : .append(render(unshown))
    }

    private mutating func repaint(_ console: [BpyLine]) -> Update {
        stale = false
        shown = console.map(Entry.init)
        return .repaint(Self.render(console.suffix(Self.repaintLimit)))
    }

    /// What is on the screen above the prompt, to print back after a clear.
    func renderShown() -> String {
        shown.suffix(Self.repaintLimit).map { Self.format(kind: $0.kind, text: $0.text) }.joined()
    }

    static func render<Lines: Sequence>(_ lines: Lines) -> String where Lines.Element == BpyLine {
        lines.map(format).joined()
    }

    static func format(_ line: BpyLine) -> String { format(kind: line.kind, text: line.text) }

    /// One line, coloured the way BenchCode's terminal colours it: errors red,
    /// the interface's own notes dim, prompts as the live prompt draws them.
    static func format(kind: BpyLine.Kind, text raw: String) -> String {
        let text = raw.components(separatedBy: "\n")
            .map { sanitize($0, keepColour: true) }
            .joined(separator: "\r\n")
        switch kind {
        case .input:
            if text.hasPrefix(">>> ") { return "\(ConsoleLineEditor.ps1)\(text.dropFirst(4))\r\n" }
            if text.hasPrefix("... ") { return "\(ConsoleLineEditor.ps2)\(text.dropFirst(4))\r\n" }
            return text + "\r\n"
        case .output:
            return text + "\u{1b}[0m\r\n"
        case .error:
            return "\u{1b}[31m" + text + "\u{1b}[0m\r\n"
        case .info:
            return "\u{1b}[2m" + text + "\u{1b}[0m\r\n"
        }
    }

    /// The console as plain text, for Copy.
    static func plainText(_ console: [BpyLine]) -> String {
        console.map { sanitize($0.text, keepColour: false) }.joined(separator: "\n")
    }

    /// Output may colour itself, but nothing it prints may move the cursor:
    /// the prompt is drawn on the assumption that output only ever adds lines
    /// above it.
    static func sanitize(_ text: String, keepColour: Bool) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\u{1b}" {
                if i + 1 < scalars.count, scalars[i + 1] == "[" {
                    var j = i + 2
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) { j += 1 }
                    if keepColour, j < scalars.count, scalars[j] == "m" {
                        out.append(contentsOf: scalars[i...j])
                    }
                    i = j + 1
                } else if i + 1 < scalars.count, scalars[i + 1] == "]" {
                    // An operating-system command runs to BEL or ESC \.
                    var j = i + 2
                    while j < scalars.count, scalars[j] != "\u{07}", scalars[j] != "\u{1b}" { j += 1 }
                    i = j < scalars.count && scalars[j] == "\u{1b}" ? j + 2 : j + 1
                } else {
                    i += 2
                }
                continue
            }
            if (s.value < 0x20 && s != "\t") || s.value == 0x7F {
                i += 1
                continue
            }
            out.append(s)
            i += 1
        }
        return String(out)
    }
}
