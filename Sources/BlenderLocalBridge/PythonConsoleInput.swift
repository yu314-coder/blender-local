import Foundation

/// Whether a console prompt has read enough to run.
///
/// Python's own REPL asks `codeop.compile_command`, which needs the
/// interpreter — and the prompt has to decide on every Return, including on
/// the command subset, where there is no interpreter to ask. So the console
/// asks the questions the compiler would have answered: is a bracket still
/// open, is a triple-quoted string, does the line end in a backslash, and did a
/// compound statement start — which, as at Python's own prompt, runs only once
/// a blank line ends it.
///
/// Pure over its input, so the rules run on the Mac.
public enum PythonConsoleInput {

    public enum Verdict: Equatable, Sendable {
        /// Run what has been typed.
        case complete
        /// Keep reading: a bracket, a string or a backslash is still open.
        case open
        /// Keep reading until a blank line: a compound statement started.
        case block
    }

    /// `lines` are the lines typed so far, newest last.
    public static func verdict(_ lines: [String]) -> Verdict {
        var depth = 0
        var triple: Character?      // the quote of an open """ or '''
        var single: Character?      // the quote of an open ' or " string
        var compound = false
        var continues = false       // the last line ended in a backslash

        for line in lines {
            let chars = Array(line)
            // A decorator only opens a block where a statement can begin, not
            // as the `@` operator on a line inside a bracket.
            let startsStatement = depth == 0 && triple == nil && single == nil && !continues
            continues = false
            var first: Character?
            var last: Character?
            var i = 0
            while i < chars.count {
                let c = chars[i]
                let atEnd = i == chars.count - 1
                if let q = triple {
                    if c == "\\" { i += 2; continue }
                    if c == q, i + 2 < chars.count, chars[i + 1] == q, chars[i + 2] == q {
                        triple = nil
                        last = q
                        i += 3
                    } else {
                        i += 1
                    }
                    continue
                }
                if let q = single {
                    if c == "\\" {
                        if atEnd { continues = true }
                        i += 2
                        continue
                    }
                    if c == q { single = nil; last = q }
                    i += 1
                    continue
                }
                if c == "#" { break }
                if c == " " || c == "\t" { i += 1; continue }
                if first == nil { first = c }
                switch c {
                case "\"", "'":
                    last = c
                    if i + 2 < chars.count, chars[i + 1] == c, chars[i + 2] == c {
                        triple = c
                        i += 3
                    } else {
                        single = c
                        i += 1
                    }
                    continue
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    depth = max(0, depth - 1)
                case "\\" where atEnd:
                    continues = true
                    i += 1
                    continue
                default:
                    break
                }
                last = c
                i += 1
            }
            // A one-line string cannot cross a newline that was not escaped.
            // At Python's prompt that is a syntax error, so let Python say so
            // rather than wait for a closing quote that is never coming.
            if single != nil && !continues { single = nil }
            if depth == 0 && triple == nil && single == nil {
                if last == ":" { compound = true }
                if startsStatement && first == "@" { compound = true }
            }
        }

        if triple != nil || single != nil || depth > 0 || continues { return .open }
        if compound {
            let closed = lines.count > 1
                && (lines.last ?? "").allSatisfy { $0 == " " || $0 == "\t" }
            return closed ? .complete : .block
        }
        return .complete
    }
}
