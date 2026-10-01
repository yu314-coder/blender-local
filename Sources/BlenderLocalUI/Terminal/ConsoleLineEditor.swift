import Foundation

/// The Scripting tab's Python prompt: a line editor that draws itself into a
/// terminal.
///
/// SwiftTerm is only the screen, as it is in BenchCode. What a key does — the
/// line, the cursor, history, completion, the `...` of a block still being
/// typed — is decided here and written back as escape sequences, the way a
/// shell's line discipline does it. Nothing in the editor knows UIKit or
/// SwiftTerm, so all of it runs on the Mac against a screen made of strings.
///
/// The prompt is always the last thing on the screen. The session's output is
/// printed *above* it: the prompt comes off, the output goes on, the prompt is
/// drawn again. That is what lets a line from the 3D View arrive while half a
/// statement is typed without breaking the statement.
final class ConsoleLineEditor {

    // MARK: - Wiring

    /// Text for the screen, escape sequences included.
    var write: (String) -> Void = { _ in }
    /// A statement, or a finished block, to run.
    var onSubmit: (String) -> Void = { _ in }
    /// ⌃C while a script runs.
    var onInterrupt: () -> Void = {}
    /// A key arrived: the terminal should be showing the prompt, not scrollback.
    var onKey: () -> Void = {}
    /// Completion candidates for the text so far, with the caret in UTF-16 units.
    var candidates: (_ text: String, _ caret: Int) -> [PythonCompletion.Candidate] = { _, _ in [] }
    /// The history changed and is worth keeping.
    var onHistoryChange: ([String]) -> Void = { _ in }
    /// The cursor's row on the screen, counted from the top. Only the terminal
    /// knows it: the editor knows where it put the cursor, not how far the
    /// screen has scrolled since.
    var cursorScreenRow: (() -> Int)?
    /// The prompt has scrolled partly off the top of the screen, where no
    /// escape sequence can reach to erase it. The host clears the screen and
    /// prints back everything that was above the prompt.
    var onOverflow: (() -> Void)?

    // MARK: - Prompts

    /// Bold, as BenchCode's shell prompt is.
    static let ps1 = "\u{1b}[1m>>>\u{1b}[0m "
    /// Dim, as BenchCode's continuation prompt is.
    static let ps2 = "\u{1b}[2m...\u{1b}[0m "
    static let promptCells = 4
    static let historyLimit = 1000

    // MARK: - State

    private(set) var columns = 80
    private(set) var rows = 24
    /// Lines of a block already accepted: shown, no longer editable.
    var block: [String] = []
    /// The line being edited, and the caret in it.
    var line: [Character] = []
    var cursor = 0
    /// Oldest first.
    var history: [String]
    /// Which entry ↑ and ↓ have reached; nil while editing a new line.
    var historyIndex: Int?
    /// What was being typed before ↑ replaced it.
    var draft: (block: [String], line: [Character])?
    /// The last text ⌃U, ⌃K or ⌃W took out, for ⌃Y.
    var killed: [Character] = []
    var search: Search?
    /// A second Tab in a row lists what the first could not choose between.
    var lastKeyWasTab = false
    /// A bracketed paste still arriving: SwiftTerm sends its start marker, the
    /// text and its end marker as three separate writes.
    var pasting: [UInt8]?
    /// While something runs the prompt is off the screen.
    var isRunning = false
    /// What keys do while something runs. See ConsoleLineEditor+Running.swift.
    var runInput: RunInput = .none
    /// A line being typed for a running command, not yet sent.
    var pendingInput: [Character] = []
    /// Keys for a running command, on their way to its standard input.
    var onForward: ([UInt8]) -> Void = { _ in }
    /// ⌃D on an empty line while a command runs: end of its input.
    var onEndOfInput: () -> Void = {}
    /// Completions for a shell line: where the word starts and whole
    /// replacements for it, or nil when the line is Python's to complete.
    var shellCompletions: (_ line: String, _ caret: Int) -> (start: Int, options: [String])? = { _, _ in nil }
    /// Whether the prompt is on the screen.
    private(set) var isShown = false
    /// How many rows below the top of the prompt the cursor sits.
    private(set) var cursorRow = 0
    /// How many rows below the top of the prompt the line being edited starts.
    private var lineStartRow = 0
    /// The block as it was last drawn. While it is unchanged an edit redraws
    /// only the line being edited: a pasted block can be taller than the
    /// screen, and redrawing all of it would repaint the console on every key.
    private var drawnBlock: [String]?

    /// ⌃R: a history search in progress.
    struct Search {
        var query = ""
        /// The entry that matches, when one does.
        var match: Int?
        var failed = false
        /// What was being edited when the search began, for ⌃G.
        var savedBlock: [String]
        var savedLine: [Character]
        var savedCursor: Int
    }

    init(history: [String] = []) {
        self.history = Array(history.suffix(Self.historyLimit))
    }

    /// Everything typed so far, as Python would receive it.
    var input: String { (block + [String(line)]).joined(separator: "\n") }

    // MARK: - What the host calls

    /// Puts the prompt on the screen if it is not there already.
    func show() {
        guard !isShown, !isRunning else { return }
        draw()
    }

    /// Output printed above the prompt. `text` ends in "\r\n".
    func printAbove(_ text: String) {
        let wasShown = isShown
        erase()
        write(text)
        if wasShown { draw() }
    }

    /// The host wiped the screen itself, so there is no prompt left to erase.
    func screenCleared() {
        isShown = false
        cursorRow = 0
        lineStartRow = 0
        drawnBlock = nil
    }

    /// The terminal's size. A change of width moves every wrap, so the host
    /// redraws everything after calling this.
    func resize(columns: Int, rows: Int) {
        self.columns = max(columns, 4)
        self.rows = max(rows, 1)
    }

    /// A script started or finished. What was typed survives the run.
    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if running {
            erase()
            // Nothing typed reaches a running script, so no cursor offers to
            // take it.
            write("\u{1b}[?25l")
        } else {
            write("\u{1b}[?25h")
            show()
        }
    }

    // MARK: - Drawing

    struct DisplayLine {
        var prompt: String
        var promptCells: Int
        var text: [Character]
    }

    /// What the prompt shows now, and which character the caret is before.
    func display() -> (lines: [DisplayLine], caretLine: Int, caret: Int) {
        if let search {
            let label = "(\(search.failed ? "failed " : "")reverse-i-search)`\(search.query)': "
            let entry = search.match.map { history[$0] } ?? ""
            let parts = entry.components(separatedBy: "\n")
            let lines = parts.enumerated().map { k, part in
                k == 0 ? DisplayLine(prompt: label, promptCells: Self.cells(label), text: Array(part))
                       : DisplayLine(prompt: Self.ps2, promptCells: Self.promptCells, text: Array(part))
            }
            // The caret sits on the match, as it does in a shell.
            if !search.query.isEmpty {
                for (k, part) in parts.enumerated() {
                    if let range = part.range(of: search.query) {
                        return (lines, k, part.distance(from: part.startIndex, to: range.lowerBound))
                    }
                }
            }
            return (lines, 0, 0)
        }
        var lines = block.enumerated().map { k, text in
            DisplayLine(prompt: k == 0 ? Self.ps1 : Self.ps2, promptCells: Self.promptCells, text: Array(text))
        }
        lines.append(DisplayLine(prompt: block.isEmpty ? Self.ps1 : Self.ps2,
                                 promptCells: Self.promptCells, text: line))
        return (lines, lines.count - 1, cursor)
    }

    /// Draws the prompt with the caret in place, starting from the beginning
    /// of an empty line — which is where `erase` and every printer leave it.
    func draw() { draw(from: 0, startRow: 0) }

    /// Draws the prompt's lines from `first` on, starting at the beginning of
    /// the row where line `first` goes, `startRow` rows below the top.
    private func draw(from first: Int, startRow: Int) {
        let shown = display()
        var out = ""
        var row = startRow
        var caretStart = startRow
        var caretLayout = Self.layout(prefix: 0, text: [], columns: columns)
        for k in first..<shown.lines.count {
            let l = shown.lines[k]
            let layout = Self.layout(prefix: l.promptCells, text: l.text, columns: columns)
            if k == shown.caretLine {
                caretStart = row
                caretLayout = layout
            }
            out += l.prompt + String(l.text)
            if k < shown.lines.count - 1 {
                out += "\r\n"
                row += layout.endRow + 1
            } else if layout.endCol >= columns {
                // A line that exactly fills the width leaves the cursor waiting
                // to wrap. A space makes the wrap happen, so the row the caret
                // belongs on really exists to come back to.
                out += " \r"
                row += layout.endRow + 1
            } else {
                row += layout.endRow
            }
        }
        var target = caretLayout.position(of: shown.caret)
        if shown.caretLine < shown.lines.count - 1, target.row > caretLayout.endRow {
            target = (caretLayout.endRow, columns - 1)
        }
        let targetRow = caretStart + target.row
        if row > targetRow { out += "\u{1b}[\(row - targetRow)A" }
        out += "\r"
        if target.col > 0 { out += "\u{1b}[\(target.col)C" }
        write(out)
        cursorRow = targetRow
        lineStartRow = caretStart
        drawnBlock = search == nil ? block : nil
        isShown = true
    }

    /// Takes the prompt off the screen, leaving the cursor where it began.
    func erase() {
        guard isShown else { return }
        let overflowed = reachesAboveScreen(cursorRow)
        isShown = false
        drawnBlock = nil
        let up = cursorRow
        cursorRow = 0
        lineStartRow = 0
        if overflowed, let onOverflow {
            onOverflow()
            return
        }
        write((up > 0 ? "\u{1b}[\(up)A" : "") + "\r\u{1b}[J")
    }

    /// Draws the prompt again after an edit.
    func redraw() {
        guard isShown else { return }
        let lineRows = cursorRow - lineStartRow
        if search == nil, drawnBlock == block, !reachesAboveScreen(lineRows) {
            // Only the line being edited changed.
            write((lineRows > 0 ? "\u{1b}[\(lineRows)A" : "") + "\r\u{1b}[J")
            draw(from: block.count, startRow: lineStartRow)
        } else {
            erase()
            draw()
        }
    }

    /// Whether the row `rowsAbove` rows above the cursor has scrolled off the
    /// top of the screen.
    private func reachesAboveScreen(_ rowsAbove: Int) -> Bool {
        rowsAbove > (cursorScreenRow?() ?? rows - 1)
    }

    /// Leaves the prompt on the screen as a line of history — Return on an
    /// empty prompt, ⌃C, a list of completions — and moves below it.
    func freeze(suffix: String = "") {
        guard isShown else { return }
        erase()
        let text = display().lines.map { $0.prompt + String($0.text) }.joined(separator: "\r\n")
        write(text + suffix + "\r\n")
    }

    // MARK: - Measuring

    struct Layout {
        /// Where each character starts.
        var starts: [(row: Int, col: Int)]
        /// Where the next character would start, before any wrap.
        var endRow: Int
        var endCol: Int
        var columns: Int

        /// Where the caret goes when it is before character `index`.
        func position(of index: Int) -> (row: Int, col: Int) {
            if index < starts.count { return starts[index] }
            return endCol >= columns ? (endRow + 1, 0) : (endRow, endCol)
        }
    }

    /// Where text lands on a terminal `columns` wide after `prefix` cells of
    /// prompt, wrapping as the terminal wraps: a character that does not fit
    /// in what is left of a row starts the next one.
    static func layout(prefix: Int, text: [Character], columns: Int) -> Layout {
        var row = 0
        var col = 0
        func place(_ width: Int) -> (row: Int, col: Int) {
            if width > 0, col + width > columns {
                row += 1
                col = 0
            }
            let start = (row: row, col: col)
            col += width
            return start
        }
        for _ in 0..<prefix { _ = place(1) }
        var starts: [(row: Int, col: Int)] = []
        starts.reserveCapacity(text.count)
        for ch in text { starts.append(place(cells(ch))) }
        return Layout(starts: starts, endRow: row, endCol: col, columns: columns)
    }

    /// Columns a character takes: two for East Asian wide characters and
    /// emoji, none for marks that attach to the character before, one
    /// otherwise.
    static func cells(_ ch: Character) -> Int {
        guard let scalar = ch.unicodeScalars.first else { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        if scalar.properties.isEmoji, ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Columns a string takes, ignoring the escape sequences in it.
    static func cells(_ s: String) -> Int {
        var total = 0
        var inEscape = false
        for ch in s {
            if inEscape {
                if let v = ch.unicodeScalars.first?.value, (0x40...0x7E).contains(v), ch != "[" {
                    inEscape = false
                }
                continue
            }
            if ch == "\u{1b}" { inEscape = true; continue }
            total += cells(ch)
        }
        return total
    }
}
