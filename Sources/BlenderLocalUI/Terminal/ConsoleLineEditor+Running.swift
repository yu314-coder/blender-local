import Foundation

/// What the keyboard does while something runs.
///
/// A script from the editor hears nothing but ⌃C: there is no way to give it
/// input. A console command is a program in a terminal, and gets the keyboard
/// the way one does — a line at a time, echoed as it is typed and sent on
/// Return — until a full-screen command asks for every key as it is pressed.
extension ConsoleLineEditor {

    enum RunInput: Equatable {
        /// Nothing running, or a script: keys other than ⌃C are dropped.
        case none
        /// Lines: typed, echoed, sent on Return.
        case cooked
        /// Every key as it is pressed, for `top` and `ncdu`.
        case raw
    }

    /// A console command is starting.
    func beginConsoleRun() {
        erase()
        isRunning = true
        runInput = .cooked
        pendingInput = []
        pasting = nil
    }

    /// A full-screen command switched the keyboard to raw keys, or back.
    func setRawInput(_ raw: Bool) {
        guard isRunning, runInput != .none else { return }
        runInput = raw ? .raw : .cooked
        pendingInput = []
    }

    /// Whatever ran has finished: the prompt comes back, with what was typed.
    func endRun() {
        guard isRunning else { return }
        guard runInput != .none else {
            setRunning(false)
            return
        }
        runInput = .none
        pendingInput = []
        pasting = nil
        isRunning = false
        // A full-screen command that was stopped never restored what it
        // changed: colours and the cursor come back here.
        write("\u{1b}[0m\u{1b}[?25h")
        show()
    }

    /// Keys while something runs.
    func runningInput(_ bytes: [UInt8]) {
        switch runInput {
        case .none:
            pasting = nil
            if bytes.contains(0x03) { onInterrupt() }
        case .raw:
            onForward(bytes)
        case .cooked:
            cookedInput(bytes)
        }
    }

    private func cookedInput(_ bytes: [UInt8]) {
        var printable: [UInt8] = []
        func flushPrintable() {
            guard !printable.isEmpty else { return }
            let text = String(decoding: printable, as: UTF8.self)
            printable.removeAll()
            pendingInput.append(contentsOf: text)
            write(text)
        }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {
                flushPrintable()
                i = skipEscape(bytes, at: i)
                continue
            }
            if b >= 0x20 && b != 0x7F {
                printable.append(b)
                i += 1
                continue
            }
            flushPrintable()
            switch b {
            case 0x0D, 0x0A:
                write("\r\n")
                onForward(Array((String(pendingInput) + "\n").utf8))
                pendingInput = []
            case 0x7F, 0x08:
                if let last = pendingInput.popLast() {
                    write(String(repeating: "\u{8} \u{8}", count: max(Self.cells(last), 1)))
                }
            case 0x15:
                let width = pendingInput.reduce(0) { $0 + max(Self.cells($1), 1) }
                write(String(repeating: "\u{8} \u{8}", count: width))
                pendingInput = []
            case 0x03:
                write("^C\r\n")
                pendingInput = []
                onInterrupt()
            case 0x04:
                if pendingInput.isEmpty {
                    onEndOfInput()
                } else {
                    // As a terminal does: ⌃D sends what is typed, without a newline.
                    onForward(Array(String(pendingInput).utf8))
                    pendingInput = []
                }
            default:
                break
            }
            i += 1
        }
        flushPrintable()
    }

    /// An arrow or a paste marker means nothing to a line typed for a command.
    private func skipEscape(_ bytes: [UInt8], at start: Int) -> Int {
        var i = start + 1
        guard i < bytes.count else { return i }
        if bytes[i] == 0x5B || bytes[i] == 0x4F {
            i += 1
            while i < bytes.count, !(0x40...0x7E).contains(bytes[i]) { i += 1 }
            return min(i + 1, bytes.count)
        }
        return i + 1
    }

    /// Completes the word from `start` to the caret with one of `options`, each
    /// a whole replacement for it: one is typed out, several as far as they
    /// agree, and a second Tab lists them.
    func completeWord(from start: Int, options: [String], repeated: Bool) {
        guard start <= cursor else { return }
        let typed = String(line[start..<cursor])
        let usable = options.filter { $0.hasPrefix(typed) }
        guard let first = usable.first else { return }
        if usable.count == 1 {
            var rest = Array(first.dropFirst(typed.count))
            // A finished name gets its space; a directory keeps going.
            if !first.hasSuffix("/"), cursor == line.count { rest.append(" ") }
            insert(rest)
            return
        }
        let common = Self.commonPrefix(usable)
        if common.count > typed.count {
            insert(Array(common.dropFirst(typed.count)))
        } else if repeated {
            listCompletions(usable.map { option in
                let isDirectory = option.hasSuffix("/")
                let name = (isDirectory ? String(option.dropLast()) : option)
                    .split(separator: "/").last.map(String.init) ?? option
                return isDirectory ? name + "/" : name
            })
        }
    }
}
