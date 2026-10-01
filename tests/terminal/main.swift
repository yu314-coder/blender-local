import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// Enough of a VT100 to hold the editor to account: printing with wrap —
/// including the wait at the last column — CR, LF with scrolling, the cursor
/// moves and the erases the editor writes. Colour draws nothing.
final class Screen {
    let columns: Int
    let rows: Int
    var grid: [[Character]]
    var scrollback: [[Character]] = []
    var x = 0
    var y = 0

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    func feed(_ s: String) {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1b}" {
                guard i + 1 < chars.count else { return }
                if chars[i + 1] == "[" {
                    var j = i + 2
                    var params = ""
                    while j < chars.count, let v = chars[j].unicodeScalars.first?.value, !(0x40...0x7E).contains(v) {
                        params.append(chars[j])
                        j += 1
                    }
                    guard j < chars.count else { return }
                    csi(chars[j], params)
                    i = j + 1
                } else {
                    i += 2
                }
                continue
            }
            switch c {
            case "\r": x = 0
            case "\n": lineFeed()
            case "\r\n": x = 0; lineFeed()   // one Character in Swift
            default: put(c)
            }
            i += 1
        }
    }

    private func lineFeed() {
        if y == rows - 1 {
            scrollback.append(grid.removeFirst())
            grid.append(Array(repeating: " ", count: columns))
        } else {
            y += 1
        }
    }

    private func put(_ c: Character) {
        let w = ConsoleLineEditor.cells(c)
        guard w > 0 else { return }
        if x + w > columns { x = 0; lineFeed() }
        grid[y][x] = c
        if w == 2 { grid[y][x + 1] = "\u{0}" }
        x += w
    }

    private func csi(_ final: Character, _ params: String) {
        // Colour moves nothing, not even a wrap that is waiting to happen.
        if params.hasPrefix("?") || final == "m" { return }
        let n = max(Int(params.split(separator: ";").first ?? "") ?? 1, 1)
        x = min(x, columns - 1)
        switch final {
        case "A": y = max(0, y - n)
        case "B": y = min(rows - 1, y + n)
        case "C": x = min(columns - 1, x + n)
        case "D": x = max(0, x - n)
        case "H": x = 0; y = 0
        case "J":
            if params == "2" {
                grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
            } else if params == "3" {
                scrollback = []
            } else if params.isEmpty || params == "0" {
                for cx in x..<columns { grid[y][cx] = " " }
                for r in (y + 1)..<rows { grid[r] = Array(repeating: " ", count: columns) }
            }
        case "K":
            for cx in x..<columns { grid[y][cx] = " " }
        default:
            break
        }
    }

    /// The rows with anything on them, trailing spaces trimmed.
    var visible: [String] {
        var lines = grid.map { row -> String in
            var s = String(row.filter { $0 != "\u{0}" })
            while s.last == " " { s.removeLast() }
            return s
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The scrollback and the screen together, as scrolling up would show them.
    var everything: [String] {
        var lines = (scrollback + grid).map { row -> String in
            var s = String(row.filter { $0 != "\u{0}" })
            while s.last == " " { s.removeLast() }
            return s
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}

func setup(columns: Int = 40, rows: Int = 10, history: [String] = [])
-> (ConsoleLineEditor, Screen, Box) {
    let screen = Screen(columns: columns, rows: rows)
    let editor = ConsoleLineEditor(history: history)
    let box = Box()
    editor.write = { screen.feed($0) }
    editor.cursorScreenRow = { screen.y }
    // What the host does when the prompt has scrolled out of reach: clear
    // everything and print back what was above the prompt.
    editor.onOverflow = {
        box.overflows += 1
        screen.feed("\u{1b}[H\u{1b}[2J\u{1b}[3J" + box.printed)
    }
    editor.onSubmit = { [unowned editor] source in
        box.submitted.append(source)
        // What the host does: the session echoes the statement above the prompt.
        let echo = source.components(separatedBy: "\n").enumerated()
            .map { ($0.offset == 0 ? ">>> " : "... ") + $0.element + "\r\n" }.joined()
        editor.printAbove(echo)
        box.printed += echo
    }
    editor.onInterrupt = { box.interrupted = true }
    editor.resize(columns: columns, rows: rows)
    editor.show()
    return (editor, screen, box)
}

final class Box {
    var submitted: [String] = []
    var interrupted = false
    /// Everything printed above the prompt, as the host's transcript holds it.
    var printed = ""
    var overflows = 0
}

func type(_ e: ConsoleLineEditor, _ s: String) { e.receive(Array(s.utf8)) }
func key(_ e: ConsoleLineEditor, _ bytes: UInt8...) { e.receive(bytes) }
func ret(_ e: ConsoleLineEditor) { key(e, 0x0d) }
let left = "\u{1b}[D", up = "\u{1b}[A", down = "\u{1b}[B"

print("== when a statement is complete ==")
for (lines, want) in [
    (["x = 1"], PythonConsoleInput.Verdict.complete),
    (["for i in range(3):"], .block),
    (["for i in range(3):", "    print(i)"], .block),
    (["for i in range(3):", "    print(i)", ""], .complete),
    (["for i in range(3):", "    print(i)", "    "], .complete),
    (["x = (1,"], .open),
    (["x = (1,", "2)"], .complete),
    (["s = \"\"\"abc"], .open),
    (["s = \"\"\"abc", "def\"\"\""], .complete),
    (["x = 1 + \\"], .open),
    (["d = {'a': 1,"], .open),
    (["d = {'a': 1,", "}"], .complete),
    (["print('a:')"], .complete),
    (["if x:  # a comment"], .block),
    (["@decorator"], .block),
    (["x = (a", "@ b)"], .complete),
    (["s = 'never closed"], .complete),
    (["if x:", ""], .complete),
    (["if (a and", "    b):"], .block),
] {
    let got = PythonConsoleInput.verdict(lines)
    check("\(lines) -> \(want)", got == want, "got \(got)")
}

print("\n== measuring ==")
check("ASCII is one cell", ConsoleLineEditor.cells(Character("a")) == 1)
check("CJK is two", ConsoleLineEditor.cells(Character("中")) == 2)
check("emoji is two", ConsoleLineEditor.cells(Character("😀")) == 2)
check("escapes take no cells", ConsoleLineEditor.cells(ConsoleLineEditor.ps1) == 4)
let filled = ConsoleLineEditor.layout(prefix: 4, text: Array("abcdef"), columns: 10)
check("a line that fills the width ends waiting to wrap",
      filled.endRow == 0 && filled.endCol == 10 && filled.position(of: 6) == (1, 0),
      "\(filled.endRow),\(filled.endCol)")
let wide = ConsoleLineEditor.layout(prefix: 4, text: Array("abcde中"), columns: 10)
check("a wide character that does not fit starts the next row",
      wide.starts[5] == (1, 0) && wide.endRow == 1 && wide.endCol == 2)

print("\n== typing ==")
do {
    let (e, s, _) = setup(columns: 20)
    check("the prompt", s.visible == [">>>"] && s.x == 4 && s.y == 0, "\(s.visible) \(s.x),\(s.y)")
    type(e, "print(1)")
    check("typed text", s.visible == [">>> print(1)"] && s.x == 12, "\(s.visible) \(s.x)")
    type(e, left + left)
    type(e, "x")
    check("inserting mid-line", s.visible == [">>> print(x1)"] && s.x == 11, "\(s.visible) \(s.x)")
}
do {
    let (e, s, _) = setup(columns: 20)
    type(e, String(repeating: "a", count: 30))
    check("a long line wraps", s.visible == [">>> " + String(repeating: "a", count: 16), String(repeating: "a", count: 14)]
          && s.x == 14 && s.y == 1, "\(s.visible) \(s.x),\(s.y)")
    key(e, 0x01)
    check("⌃A goes back across the wrap", s.x == 4 && s.y == 0, "\(s.x),\(s.y)")
    key(e, 0x05)
    check("⌃E comes back", s.x == 14 && s.y == 1, "\(s.x),\(s.y)")
}
do {
    let (e, s, _) = setup(columns: 20)
    type(e, String(repeating: "b", count: 16))
    check("exactly filling the width puts the caret on the next row",
          s.visible == [">>> " + String(repeating: "b", count: 16)] && s.x == 0 && s.y == 1,
          "\(s.visible) \(s.x),\(s.y)")
    key(e, 0x7f)
    check("and deleting brings it back without leaving a row behind",
          s.visible == [">>> " + String(repeating: "b", count: 15)] && s.x == 19 && s.y == 0,
          "\(s.visible) \(s.x),\(s.y)")
}
do {
    let (e, s, _) = setup(columns: 20)
    type(e, String(repeating: "c", count: 40))
    e.printAbove("out\r\n")
    check("output lands above a prompt three rows tall, with nothing left over",
          s.visible == ["out", ">>> " + String(repeating: "c", count: 16),
                        String(repeating: "c", count: 20), "cccc"] && s.x == 4 && s.y == 3,
          "\(s.visible) \(s.x),\(s.y)")
}

print("\n== running statements ==")
do {
    let (e, s, box) = setup()
    type(e, "x = 1")
    ret(e)
    check("Return runs a complete line", box.submitted == ["x = 1"])
    check("and the prompt comes back under the echo", s.visible == [">>> x = 1", ">>>"] && s.y == 1, "\(s.visible)")
}
do {
    let (e, s, box) = setup()
    type(e, "for i in range(3):")
    ret(e)
    check("a compound statement asks for more, indented",
          s.visible == [">>> for i in range(3):", "..."] && s.x == 8 && s.y == 1 && box.submitted.isEmpty,
          "\(s.visible) \(s.x),\(s.y)")
    type(e, "print(i)")
    ret(e)
    check("the indent carries on", String(e.line) == "    ", "'\(String(e.line))'")
    ret(e)
    check("a blank line runs the block", box.submitted == ["for i in range(3):\n    print(i)"], "\(box.submitted)")
    check("echoed as Python shows it", s.visible == [">>> for i in range(3):", "...     print(i)", ">>>"], "\(s.visible)")
}
do {
    let (e, _, _) = setup()
    type(e, "if x:")
    ret(e)
    key(e, 0x7f)
    check("Backspace in the indentation takes out a level", e.line.isEmpty && e.cursor == 0)
}
do {
    let (e, _, box) = setup()
    type(e, "x = (1,")
    ret(e)
    type(e, "2)")
    ret(e)
    check("an open bracket waits for its close", box.submitted == ["x = (1,\n2)"], "\(box.submitted)")
}
do {
    let (e, s, box) = setup()
    ret(e)
    check("Return on an empty prompt gives a fresh one", s.visible == [">>>", ">>>"] && box.submitted.isEmpty, "\(s.visible)")
}

print("\n== history ==")
do {
    let (e, s, _) = setup(history: ["a = 1", "for i in x:\n    pass"])
    type(e, up)
    check("↑ brings back a block as a block", s.visible == [">>> for i in x:", "...     pass"] && s.x == 12 && s.y == 1,
          "\(s.visible) \(s.x),\(s.y)")
    type(e, up)
    check("↑ again goes further back", s.visible == [">>> a = 1"], "\(s.visible)")
    type(e, down)
    type(e, down)
    check("↓ past the newest returns to what was being typed", s.visible == [">>>"] && e.block.isEmpty, "\(s.visible)")
}
do {
    let (e, _, _) = setup()
    var kept: [String] = []
    e.onHistoryChange = { kept = $0 }
    type(e, "x = 2")
    ret(e)
    type(e, "x = 2")
    ret(e)
    check("history keeps a statement once, not twice in a row", kept == ["x = 2"] && e.history == ["x = 2"], "\(kept)")
}

print("\n== ⌃R ==")
do {
    let (e, s, box) = setup(columns: 50, history: ["x = 1", "print(x)", "y = 2"])
    key(e, 0x12)
    check("the search prompt", s.visible == ["(reverse-i-search)`':"], "\(s.visible)")
    type(e, "pri")
    check("finds the match, caret on it", s.visible == ["(reverse-i-search)`pri': print(x)"] && s.x == 25,
          "\(s.visible) \(s.x)")
    ret(e)
    check("Return runs it", box.submitted == ["print(x)"], "\(box.submitted)")
}
do {
    let (e, s, _) = setup(columns: 50, history: ["x = 1"])
    type(e, "abc")
    key(e, 0x12)
    type(e, "zzz")
    check("a query with no match says so", s.visible.last == "(failed reverse-i-search)`zzz':", "\(s.visible)")
    key(e, 0x1b)
    check("Escape goes back to what was typed", s.visible == [">>> abc"] && e.search == nil, "\(s.visible)")
}

print("\n== ⌃C, paste ==")
do {
    let (e, s, _) = setup()
    type(e, "abc")
    key(e, 0x03)
    check("⌃C leaves the line on screen and starts afresh", s.visible == [">>> abc^C", ">>>"] && e.line.isEmpty, "\(s.visible)")
}
do {
    let (e, _, box) = setup()
    type(e, "\u{1b}[200~")
    type(e, "def f():\n    return 1\n\nprint(f())\n")
    type(e, "\u{1b}[201~")
    check("a bracketed paste arrives whole, blank line and all",
          e.block == ["def f():", "    return 1", "", "print(f())"] && e.line.isEmpty, "\(e.block) '\(String(e.line))'")
    ret(e)
    check("and one Return runs it", box.submitted == ["def f():\n    return 1\n\nprint(f())"], "\(box.submitted)")
}
do {
    let (e, _, _) = setup()
    type(e, "\u{1b}[200~abc\u{1b}[201~")
    check("paste markers in the same write as the text", String(e.line) == "abc", "'\(String(e.line))'")
}
do {
    let (e, _, box) = setup()
    type(e, "a = 1\nb = 2\n")
    ret(e)
    check("an unbracketed paste is still one statement", box.submitted == ["a = 1\nb = 2"], "\(box.submitted)")
}

print("\n== Tab ==")
do {
    let (e, s, _) = setup()
    e.candidates = { text, caret in
        PythonCompletion.candidates(text: text, caret: caret,
                                    operators: ["mesh.primitive_cube_add", "mesh.primitive_cone_add", "mesh.bevel"],
                                    limit: 50)
    }
    type(e, "bpy.ops.mesh.prim")
    key(e, 0x09)
    check("Tab types as far as the candidates agree", String(e.line) == "bpy.ops.mesh.primitive_c", "'\(String(e.line))'")
    key(e, 0x09)
    check("a second Tab lists them",
          s.visible == [">>> bpy.ops.mesh.primitive_c", "primitive_cone_add  primitive_cube_add",
                        ">>> bpy.ops.mesh.primitive_c"], "\(s.visible)")
    type(e, "u")
    key(e, 0x09)
    check("one candidate is typed out, with a bracket for a call",
          String(e.line) == "bpy.ops.mesh.primitive_cube_add(", "'\(String(e.line))'")
}
do {
    let (e, _, _) = setup()
    key(e, 0x09)
    check("Tab at the start of a line indents", String(e.line) == "    ")
}

print("\n== words, kill and yank ==")
do {
    let (e, _, _) = setup()
    type(e, "foo bar_baz")
    type(e, "\u{1b}b")
    check("⌥← to the start of the word", e.cursor == 4, "\(e.cursor)")
    type(e, "\u{1b}f")
    check("⌥→ to its end", e.cursor == 11, "\(e.cursor)")
    key(e, 0x17)
    check("⌃W takes back to the space", String(e.line) == "foo ", "'\(String(e.line))'")
    key(e, 0x19)
    check("⌃Y puts it back", String(e.line) == "foo bar_baz", "'\(String(e.line))'")
    key(e, 0x15)
    type(e, "foo.bar")
    key(e, 0x1b, 0x7f)
    check("⌥⌫ takes one word", String(e.line) == "foo.", "'\(String(e.line))'")
    type(e, "\u{1b}[H")
    check("Home goes to the start", e.cursor == 0)
}

print("\n== while a script runs ==")
do {
    let (e, s, box) = setup()
    type(e, "abc")
    e.setRunning(true)
    check("the prompt goes", s.visible.isEmpty, "\(s.visible)")
    type(e, "zzz")
    check("typing is ignored", String(e.line) == "abc")
    key(e, 0x03)
    check("⌃C stops the script", box.interrupted)
    e.setRunning(false)
    check("the prompt returns with what was typed", s.visible == [">>> abc"], "\(s.visible)")
}

print("\n== a prompt taller than the screen ==")
let tallPaste = "\u{1b}[200~" + (1...8).map { "l\($0)" }.joined(separator: "\n") + "\u{1b}[201~"
let tallLines = [">>> l1"] + (2...8).map { "... l\($0)" }
do {
    let (e, s, box) = setup(columns: 30, rows: 5)
    type(e, tallPaste)
    check("a paste taller than the screen scrolls, and is drawn once", s.everything == tallLines, "\(s.everything)")
    type(e, "x")
    check("typing redraws only the line, with no repaint",
          s.everything == Array(tallLines.dropLast()) + ["... l8x"] && box.overflows == 0,
          "\(s.everything) overflows \(box.overflows)")
    type(e, left)
    key(e, 0x7f)
    check("so does deleting", s.everything == Array(tallLines.dropLast()) + ["... lx"] && box.overflows == 0,
          "\(s.everything) overflows \(box.overflows)")
    key(e, 0x03)
    check("taking it off repaints, rather than leave half of it in the scrollback twice",
          s.everything == Array(tallLines.dropLast()) + ["... lx^C", ">>>"] && box.overflows == 1,
          "\(s.everything) overflows \(box.overflows)")
}
do {
    let (e, s, box) = setup(columns: 30, rows: 5)
    e.printAbove("old\r\n")
    box.printed += "old\r\n"
    type(e, tallPaste)
    e.printAbove("out\r\n")
    box.printed += "out\r\n"
    check("output arriving lands once, above the whole prompt",
          s.everything == ["old", "out"] + tallLines && box.overflows == 1,
          "\(s.everything) overflows \(box.overflows)")
    ret(e)
    check("and running it leaves one copy of each line",
          s.everything == ["old", "out"] + tallLines + [">>>"] && box.submitted.count == 1,
          "\(s.everything)")
}
do {
    let (e, s, _) = setup()
    e.printAbove("old\r\n")
    type(e, "abc")
    key(e, 0x0c)
    check("⌃L clears the screen and keeps the line", s.visible == [">>> abc"] && s.y == 0, "\(s.visible)")
}

print("\n== the transcript ==")
do {
    var t = ConsoleTranscript()
    let banner = [BpyLine(.info, "Python 3.13")]
    if case .repaint(let text) = t.update(to: banner) {
        check("the first update paints the banner, dim", text == "\u{1b}[2mPython 3.13\u{1b}[0m\r\n", text.debugDescription)
    } else { check("the first update paints", false) }
    check("no change, nothing to do", t.update(to: banner) == .none)
    var console = banner + [BpyLine(.input, ">>> x = 1"), BpyLine(.input, "... y"), BpyLine(.output, "1")]
    check("new lines are appended, prompts drawn like the live one",
          t.update(to: console) == .append(ConsoleLineEditor.ps1 + "x = 1\r\n" + ConsoleLineEditor.ps2 + "y\r\n" + "1\u{1b}[0m\r\n"))
    console[console.count - 1] = BpyLine(.output, "1")
    check("a streamed line replaced by the same line is left alone", t.update(to: console) == .none)
    console[console.count - 1] = BpyLine(.error, "1")
    if case .repaint = t.update(to: console) { check("a line that became an error repaints", true) }
    else { check("a line that became an error repaints", false) }
    if case .repaint = t.update(to: [BpyLine(.info, "Python 3.13")]) { check("Clear repaints even an identical banner", true) }
    else { check("Clear repaints even an identical banner", false) }
    check("output keeps its colour but cannot move the cursor",
          ConsoleTranscript.format(BpyLine(.output, "a\u{1b}[2Jb\u{1b}[32mc\u{07}")) == "ab\u{1b}[32mc\u{1b}[0m\r\n")
    check("Copy is plain text",
          ConsoleTranscript.plainText([BpyLine(.error, "\u{1b}[31mboom"), BpyLine(.output, "ok")]) == "boom\nok")
}

do {
    var t = ConsoleTranscript()
    let a = BpyLine(.output, "a"), b = BpyLine(.output, "b")
    _ = t.update(to: [a])
    check("a new line is a difference", t.differs(from: [a, b]))
    check("and is appended", t.update(to: [a, b]) == .append("b\u{1b}[0m\r\n"))
    check("the same console is not a difference", !t.differs(from: [a, b]))
    t.invalidate()
    check("after invalidating, anything is", t.differs(from: [a, b]))
    if case .repaint(let text) = t.update(to: [a, b]) {
        check("and it repaints all of it", text == "a\u{1b}[0m\r\nb\u{1b}[0m\r\n", text.debugDescription)
    } else { check("and it repaints all of it", false) }
    check("what is on screen can be printed back", t.renderShown() == "a\u{1b}[0m\r\nb\u{1b}[0m\r\n")
}

do {
    let editor = ConsoleLineEditor()
    var out = ""
    editor.write = { out += $0 }
    editor.resize(columns: 40, rows: 10)
    editor.show()
    out = ""
    editor.setRunning(true)
    check("a run hides the cursor", out.hasSuffix("\u{1b}[?25l"), out.debugDescription)
    out = ""
    editor.setRunning(false)
    check("and the prompt brings it back", out.hasPrefix("\u{1b}[?25h") && out.contains(">>>"), out.debugDescription)
}

print("\n== shell or Python ==")
for (input, want) in [
    ("ls", ConsoleShell.Route.shell("ls")),
    ("ls -la", .shell("ls -la")),
    ("  cd ..", .shell("cd ..")),
    ("ls ./scripts", .shell("ls ./scripts")),
    ("cat .hidden", .shell("cat .hidden")),
    ("top", .shell("top")),
    ("echo hi there", .shell("echo hi there")),
    ("pip install numpy", .shell("pip install numpy")),
    ("!pwd", .shell("pwd")),
    ("%ls", .python("ls")),
    ("id = 3", .python("id = 3")),
    ("id == 3", .python("id == 3")),
    ("time.sleep(1)", .python("time.sleep(1)")),
    ("help(bpy)", .python("help(bpy)")),
    ("time + 1", .python("time + 1")),
    ("print('x')", .python("print('x')")),
    ("bpy.ops.mesh.primitive_cube_add()", .python("bpy.ops.mesh.primitive_cube_add()")),
    ("for i in x:\n    ls", .python("for i in x:\n    ls")),
    ("md = 1", .python("md = 1")),
] {
    let got = ConsoleShell.route(input)
    check("\(input.debugDescription) goes to \(want)", got == want, "got \(got)")
}
do {
    let src = ConsoleShell.source(for: "echo 'a\"b' \\x", columns: 80, rows: 24)
    let encoded = src.components(separatedBy: "'")[1]
    check("a command travels as base64",
          Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) } == "echo 'a\"b' \\x", src)
    check("in two lines, so its status is not echoed", src.hasSuffix("\n") && src.components(separatedBy: "\n").count == 3)
    let raw = ConsoleShell.rawMarker, cooked = ConsoleShell.cookedMarker
    check("full-screen frames are left out of the record",
          ConsoleShell.recordable("before\n\(raw)frame1frame2\(cooked)after\n") == "before\nafter\n")
    check("a full-screen command that never switched back is left out to the end",
          ConsoleShell.recordable("x\n\(raw)frames") == "x\n")
}
do {
    let entries: [(name: String, isDirectory: Bool)] = [("scripts", true), ("scene.blend", false), (".hidden", false)]
    var asked = ""
    let list: (String) -> [(name: String, isDirectory: Bool)] = { asked = $0; return entries }
    let first = ConsoleShell.completions(line: "ca", caret: 2, cwd: "/w", home: "/h", list: list)
    check("the first word completes command names", first?.start == 0 && first?.options == ["cal", "cat"],
          "\(String(describing: first))")
    let path = ConsoleShell.completions(line: "ls sc", caret: 5, cwd: "/w", home: "/h", list: list)
    check("a later word completes paths from the working directory",
          path?.start == 3 && path?.options == ["scene.blend", "scripts/"] && asked == "/w/",
          "\(String(describing: path)) asked \(asked)")
    let home = ConsoleShell.completions(line: "cd ~/sc", caret: 7, cwd: "/w", home: "/h", list: list)
    check("~ is home", home?.options == ["~/scene.blend", "~/scripts/"] && asked == "/h/",
          "\(String(describing: home)) asked \(asked)")
    check("Python is left to Python", ConsoleShell.completions(line: "bpy.o", caret: 5, cwd: "/w", home: "/h", list: list) == nil)
    check("so is a word no command starts with",
          ConsoleShell.completions(line: "pri", caret: 3, cwd: "/w", home: "/h", list: list) == nil)
}

print("\n== a command's output on its way to the screen ==")
do {
    var s = ConsoleRawStream()
    check("a bare line feed gets its carriage return", s.take("a\nb\r\n") == [.text("a\r\nb\r\n")])
    check("a CR ending one chunk covers the LF that starts the next",
          s.take("x\r") == [.text("x\r")] && s.take("\ny") == [.text("\ny")])
    let raw = ConsoleShell.rawMarker, cooked = ConsoleShell.cookedMarker
    check("markers are taken out and reported",
          s.take("1\(raw)2\(cooked)3") == [.text("1"), .raw, .text("2"), .cooked, .text("3")])
    let split = raw.index(raw.startIndex, offsetBy: 5)
    let firstHalf = s.take("q" + String(raw[..<split]))
    let secondHalf = s.take(String(raw[split...]) + "w")
    check("a marker split across two chunks is still a marker",
          firstHalf == [.text("q")] && secondHalf == [.raw, .text("w")], "\(firstHalf) \(secondHalf)")
    check("an escape that is not a marker passes through", s.take("\u{1b}[2J") == [.text("\u{1b}[2J")])
    check("what is held back comes out at the end",
          s.take("\u{1b}]blend") == [] && s.finish() == [.text("\u{1b}]blend")])
}

print("\n== keys while a command runs ==")
do {
    let (e, s, box) = setup()
    var forwarded: [UInt8] = []
    var ended = false
    e.onForward = { forwarded += $0 }
    e.onEndOfInput = { ended = true }
    type(e, "ls")
    ret(e)
    e.beginConsoleRun()
    type(e, "abc")
    check("a line typed for a command is echoed as it is typed", s.visible.last == "abc", "\(s.visible)")
    key(e, 0x7f)
    ret(e)
    check("and sent on Return", String(decoding: forwarded, as: UTF8.self) == "ab\n",
          String(decoding: forwarded, as: UTF8.self).debugDescription)
    key(e, 0x04)
    check("⌃D on an empty line is end of input", ended)
    e.setRawInput(true)
    forwarded = []
    type(e, "q")
    key(e, 0x03)
    check("a full-screen command gets every key, ⌃C included", forwarded == [0x71, 0x03] && !box.interrupted,
          "\(forwarded)")
    e.setRawInput(false)
    key(e, 0x03)
    check("⌃C on a line stops the command", box.interrupted)
    e.endRun()
    check("the prompt comes back when it ends", s.visible.last == ">>>", "\(s.visible)")
}
do {
    let (e, _, box) = setup()
    var forwarded: [UInt8] = []
    e.onForward = { forwarded += $0 }
    e.setRunning(true)
    type(e, "zzz")
    key(e, 0x03)
    check("a script still hears only ⌃C", forwarded.isEmpty && box.interrupted)
    e.endRun()
    check("and ending it the usual way brings the prompt back", !e.isRunning)
}
do {
    let (e, _, _) = setup()
    e.shellCompletions = { line, caret in
        ConsoleShell.completions(line: line, caret: caret, cwd: "/w", home: "/h",
                                 list: { _ in [("scripts", true), ("scene.blend", false)] })
    }
    type(e, "ls scr")
    key(e, 0x09)
    check("Tab completes a directory and keeps going", String(e.line) == "ls scripts/", "'\(String(e.line))'")
    key(e, 0x15)
    type(e, "whoa")
    key(e, 0x09)
    check("a finished command name gets its space", String(e.line) == "whoami ", "'\(String(e.line))'")
}
do {
    var t = ConsoleTranscript()
    let banner = BpyLine(.info, "banner")
    _ = t.update(to: [banner])
    let echo = BpyLine(.input, ">>> ls")
    let outA = BpyLine(.output, "a.txt"), outB = BpyLine(.output, "b.txt")
    let update = t.update(to: [banner, echo, outA, outB], alreadyShown: 2..<4)
    check("output a command drew live is recorded, not printed again",
          update == .append(ConsoleLineEditor.ps1 + "ls\r\n"), "\(update)")
    check("and counts as shown afterwards", t.update(to: [banner, echo, outA, outB]) == .none)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
