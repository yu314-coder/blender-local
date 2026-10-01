import Foundation

/// What each key does to the line. The bytes that choose these are read in
/// ConsoleLineEditor+Keys.swift.
extension ConsoleLineEditor {

    // MARK: - Typing and deleting

    func insert(_ chars: [Character]) {
        guard !chars.isEmpty else { return }
        line.insert(contentsOf: chars, at: cursor)
        cursor += chars.count
        redraw()
    }

    func backspace() {
        guard cursor > 0 else { return }
        let before = line[..<cursor]
        if before.allSatisfy({ $0 == " " }) {
            // In the indentation one press takes out one level, the way the
            // script editor does — four presses per level is what a console
            // without this makes you type.
            let remove = before.count % 4 == 0 ? 4 : before.count % 4
            line.removeSubrange((cursor - remove)..<cursor)
            cursor -= remove
        } else {
            line.remove(at: cursor - 1)
            cursor -= 1
        }
        redraw()
    }

    func deleteForward() {
        guard cursor < line.count else { return }
        line.remove(at: cursor)
        redraw()
    }

    /// ⇧Tab: one level of indentation out.
    func dedent() {
        let leading = line.prefix { $0 == " " }.count
        guard leading > 0 else { return }
        let remove = leading % 4 == 0 ? 4 : leading % 4
        line.removeFirst(remove)
        cursor = max(0, cursor - remove)
        redraw()
    }

    // MARK: - Moving

    func moveLeft() {
        guard cursor > 0 else { return }
        cursor -= 1
        redraw()
    }

    func moveRight() {
        guard cursor < line.count else { return }
        cursor += 1
        redraw()
    }

    /// Home and ⌘← go to where the code starts, then to the start of the line;
    /// ⌃A goes straight to the start, as it does in every shell.
    func moveHome(smart: Bool) {
        let code = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.count
        let target = smart && cursor != code ? code : 0
        guard target != cursor else { return }
        cursor = target
        redraw()
    }

    func moveEnd() {
        guard cursor != line.count else { return }
        cursor = line.count
        redraw()
    }

    func moveWordLeft() {
        let target = wordStart(before: cursor)
        guard target != cursor else { return }
        cursor = target
        redraw()
    }

    func moveWordRight() {
        let target = wordEnd(after: cursor)
        guard target != cursor else { return }
        cursor = target
        redraw()
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private func wordStart(before index: Int) -> Int {
        var i = index
        while i > 0, !Self.isWord(line[i - 1]) { i -= 1 }
        while i > 0, Self.isWord(line[i - 1]) { i -= 1 }
        return i
    }

    private func wordEnd(after index: Int) -> Int {
        var i = index
        while i < line.count, !Self.isWord(line[i]) { i += 1 }
        while i < line.count, Self.isWord(line[i]) { i += 1 }
        return i
    }

    // MARK: - Killing and yanking

    func killToStart() {
        guard cursor > 0 else { return }
        killed = Array(line[..<cursor])
        line.removeSubrange(..<cursor)
        cursor = 0
        redraw()
    }

    func killToEnd() {
        guard cursor < line.count else { return }
        killed = Array(line[cursor...])
        line.removeSubrange(cursor...)
        redraw()
    }

    /// ⌃W takes back to the last space, which in `bpy.ops.mesh` is all of it;
    /// ⌥⌫ takes one word, which is `mesh`. Both as the shells have them.
    func killWordBack(toSpace: Bool) {
        var i = cursor
        if toSpace {
            while i > 0, line[i - 1] == " " { i -= 1 }
            while i > 0, line[i - 1] != " " { i -= 1 }
        } else {
            i = wordStart(before: cursor)
        }
        guard i < cursor else { return }
        killed = Array(line[i..<cursor])
        line.removeSubrange(i..<cursor)
        cursor = i
        redraw()
    }

    func killWordForward() {
        let end = wordEnd(after: cursor)
        guard end > cursor else { return }
        killed = Array(line[cursor..<end])
        line.removeSubrange(cursor..<end)
        redraw()
    }

    func yank() { insert(killed) }

    // MARK: - Return

    func returnKey() {
        if search != nil { acceptSearch() }
        let text = String(line)
        let blank = text.allSatisfy { $0 == " " || $0 == "\t" }
        if block.isEmpty && blank {
            // Python answers an empty line with a fresh prompt, and so does this.
            freeze()
            resetInput()
            draw()
            return
        }
        let lines = block + [text]
        switch PythonConsoleInput.verdict(lines) {
        case .complete:
            var source = lines
            // The blank line that closed a block is how it was typed, not
            // part of what runs.
            while source.count > 1, source[source.count - 1].allSatisfy({ $0 == " " || $0 == "\t" }) {
                source.removeLast()
            }
            let statement = source.joined(separator: "\n")
            erase()
            resetInput()
            remember(statement)
            onSubmit(statement)
            show()
        case .open, .block:
            block.append(text)
            // The next line starts indented where Python needs it.
            line = Array(PythonIndent.afterNewline(in: text))
            cursor = line.count
            redraw()
        }
    }

    /// ⌃D deletes forward, and on an empty line ends a block the way a blank
    /// Return does. It never closes the console: there is nothing to exit to.
    func endOfInput() {
        if !line.isEmpty { deleteForward() } else if !block.isEmpty { returnKey() }
    }

    /// ⌃C with nothing running: abandon what was typed, leaving it on screen.
    func interrupt() {
        freeze(suffix: "^C")
        search = nil
        resetInput()
        draw()
    }

    /// ⌃L: a clean screen with the prompt at the top.
    func clearScreen() {
        erase()
        write("\u{1b}[H\u{1b}[2J")
        draw()
    }

    func escapeKey() {
        if search != nil { cancelSearch() }
    }

    private func resetInput() {
        block = []
        line = []
        cursor = 0
        historyIndex = nil
        draft = nil
    }

    // MARK: - Paste

    /// Pasted text goes in as typed lines that have not run yet: every line
    /// but the last joins the block, and Return runs it — so a pasted
    /// function with a blank line inside it arrives whole, rather than being
    /// cut off at the blank line the way a line-at-a-time prompt would.
    func paste(_ raw: String) {
        if search != nil { acceptSearch() }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .filter { ch in
                ch == "\n" || !(ch.unicodeScalars.first.map { $0.value < 0x20 || $0.value == 0x7F } ?? true)
            }
        let segments = text.components(separatedBy: "\n")
        let tail = Array(line[cursor...])
        line = Array(line[..<cursor]) + Array(segments[0])
        for segment in segments.dropFirst() {
            block.append(String(line))
            line = Array(segment)
        }
        cursor = line.count
        line += tail
        redraw()
    }

    // MARK: - History

    func historyOlder() {
        let next = (historyIndex ?? history.count) - 1
        guard next >= 0, next < history.count else { return }
        if historyIndex == nil { draft = (block, line) }
        historyIndex = next
        load(history[next])
    }

    func historyNewer() {
        guard let index = historyIndex else { return }
        if index + 1 < history.count {
            historyIndex = index + 1
            load(history[index + 1])
        } else {
            historyIndex = nil
            block = draft?.block ?? []
            line = draft?.line ?? []
            cursor = line.count
            draft = nil
            redraw()
        }
    }

    /// A block comes back as a block: its last line editable, the rest above.
    private func load(_ entry: String) {
        var lines = entry.components(separatedBy: "\n")
        let last = lines.removeLast()
        block = lines
        line = Array(last)
        cursor = line.count
        redraw()
    }

    func remember(_ entry: String) {
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              history.last != entry else { return }
        history.append(entry)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        onHistoryChange(history)
    }

    // MARK: - ⌃R

    /// Starts a search, or — already searching — finds the next older match.
    func searchOlder() {
        guard var s = search else {
            search = Search(savedBlock: block, savedLine: line, savedCursor: cursor)
            redraw()
            return
        }
        guard !s.query.isEmpty else { return }
        if let found = find(s.query, from: (s.match ?? history.count) - 1, step: -1) {
            s.match = found
            s.failed = false
        } else {
            s.failed = true
        }
        search = s
        redraw()
    }

    /// ⌃S: the next newer match.
    func searchNewer() {
        guard var s = search, !s.query.isEmpty, let current = s.match else { return }
        if let found = find(s.query, from: current + 1, step: 1) {
            s.match = found
            s.failed = false
        } else {
            s.failed = true
        }
        search = s
        redraw()
    }

    func searchType(_ chars: [Character]) {
        guard var s = search else { return }
        s.query += String(chars)
        // From the current match, inclusive: a longer query that still
        // matches it keeps it.
        if let found = find(s.query, from: s.match ?? history.count - 1, step: -1) {
            s.match = found
            s.failed = false
        } else {
            s.failed = true
        }
        search = s
        redraw()
    }

    func searchBackspace() {
        guard var s = search, !s.query.isEmpty else { return }
        s.query.removeLast()
        s.match = s.query.isEmpty ? nil : find(s.query, from: history.count - 1, step: -1)
        s.failed = !s.query.isEmpty && s.match == nil
        search = s
        redraw()
    }

    /// ⌃G or Escape: back to what was being typed.
    func cancelSearch() {
        guard let s = search else { return }
        search = nil
        block = s.savedBlock
        line = s.savedLine
        cursor = s.savedCursor
        redraw()
    }

    /// Leaves the search with the match in the editor, ready to run or edit.
    func acceptSearch() {
        guard let s = search else { return }
        search = nil
        if let match = s.match {
            draft = (s.savedBlock, s.savedLine)
            historyIndex = match
            var lines = history[match].components(separatedBy: "\n")
            let last = lines.removeLast()
            block = lines
            line = Array(last)
            cursor = line.count
        } else {
            block = s.savedBlock
            line = s.savedLine
            cursor = s.savedCursor
        }
        redraw()
    }

    private func find(_ query: String, from start: Int, step: Int) -> Int? {
        var i = start
        while i >= 0 && i < history.count {
            if history[i].contains(query) { return i }
            i += step
        }
        return nil
    }

    // MARK: - Tab

    /// In the indentation, Tab indents. Anywhere else it completes: one
    /// candidate is typed out, several are typed as far as they agree, and a
    /// second Tab lists them — the readline way, with the script editor's
    /// completion behind it.
    func tab(repeated: Bool) {
        let before = line[..<cursor]
        if before.allSatisfy({ $0 == " " || $0 == "\t" }) {
            insert(Array(repeating: " ", count: 4 - before.count % 4))
            return
        }
        // A shell line completes commands and paths, as BenchCode's does.
        if block.isEmpty, let shell = shellCompletions(String(line), cursor) {
            completeWord(from: shell.start, options: shell.options, repeated: repeated)
            return
        }
        let text = input
        let caret = block.reduce(0) { $0 + $1.utf16.count + 1 } + String(before).utf16.count
        let found = candidates(text, caret)
        let partial = PythonCompletion.context(in: text, caret: caret).partial
        let usable = found.filter { $0.insert.hasPrefix(partial) }
        guard let first = usable.first else { return }
        if usable.count == 1 {
            var rest = Array(first.insert.dropFirst(partial.count))
            if first.callable, cursor == line.count || line[cursor] != "(" { rest.append("(") }
            insert(rest)
            return
        }
        let common = Self.commonPrefix(usable.map(\.insert))
        if common.count > partial.count {
            insert(Array(common.dropFirst(partial.count)))
        } else if repeated {
            listCompletions(usable.map(\.label))
        }
    }

    /// Candidates in columns under the prompt, and the prompt again below.
    func listCompletions(_ labels: [String]) {
        guard isShown, !labels.isEmpty else { return }
        let width = (labels.map { Self.cells($0) }.max() ?? 0) + 2
        let perRow = max(1, columns / width)
        var out = ""
        var row = ""
        for (i, label) in labels.enumerated() {
            row += label
            if (i + 1) % perRow == 0 || i == labels.count - 1 {
                out += row + "\r\n"
                row = ""
            } else {
                row += String(repeating: " ", count: width - Self.cells(label))
            }
        }
        freeze()
        write(out)
        draw()
    }

    static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) { prefix.removeLast() }
        }
        return prefix
    }
}
