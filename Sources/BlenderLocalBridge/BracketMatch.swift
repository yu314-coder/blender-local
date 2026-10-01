import Foundation

/// Monaco's `matchBrackets: 'always'` — the pair either side of the caret,
/// boxed, so a long call tells you where it ends without counting.
///
/// The scan has to know about strings and comments or it is worse than
/// nothing: `print("(")` would pair the bracket in the text with the one in
/// the code and box two characters that have no relationship. Python's string
/// rules are the awkward part — three quote styles, raw and f prefixes,
/// escapes — so they are handled rather than hoped about.
public enum BracketMatch {

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// The two offsets to highlight, or nil when the caret is not on a bracket.
    ///
    /// Monaco looks at the character *before* the caret first and then the one
    /// after it, so that typing a closing bracket highlights the pair it just
    /// completed. Same order here.
    public static func match(in text: String, caret: Int) -> (Int, Int)? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        let code = codePositions(chars)

        for index in [caret - 1, caret] where index >= 0 && index < chars.count {
            guard code.contains(index) else { continue }
            let c = chars[index]
            if pairs[c] != nil, let other = forward(chars, code, from: index) {
                return (index, other)
            }
            if closers[c] != nil, let other = backward(chars, code, from: index) {
                return (other, index)
            }
        }
        return nil
    }

    private static func forward(_ chars: [Character], _ code: Set<Int>, from: Int) -> Int? {
        guard let want = pairs[chars[from]] else { return nil }
        var depth = 0
        var i = from
        while i < chars.count {
            if code.contains(i) {
                let c = chars[i]
                if c == chars[from] { depth += 1 }
                else if c == want {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    private static func backward(_ chars: [Character], _ code: Set<Int>, from: Int) -> Int? {
        guard let want = closers[chars[from]] else { return nil }
        var depth = 0
        var i = from
        while i >= 0 {
            if code.contains(i) {
                let c = chars[i]
                if c == chars[from] { depth += 1 }
                else if c == want {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i -= 1
        }
        return nil
    }

    /// Which offsets are code rather than string or comment.
    ///
    /// One pass, because the alternative is asking "am I in a string?" at every
    /// bracket and rescanning the file each time.
    static func codePositions(_ chars: [Character]) -> Set<Int> {
        var out = Set<Int>()
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if c == "#" {                                   // to end of line
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }

            if c == "\"" || c == "'" {
                let quote = c
                // Triple-quoted runs to the matching triple; single runs to the
                // matching quote or the end of the line, since Python does not
                // let a plain string cross one.
                let triple = i + 2 < chars.count && chars[i + 1] == quote && chars[i + 2] == quote
                i += triple ? 3 : 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }   // an escaped anything
                    if triple {
                        if chars[i] == quote, i + 2 < chars.count,
                           chars[i + 1] == quote, chars[i + 2] == quote {
                            i += 3
                            break
                        }
                    } else {
                        if chars[i] == quote { i += 1; break }
                        if chars[i] == "\n" { break }
                    }
                    i += 1
                }
                continue
            }

            out.insert(i)
            i += 1
        }
        return out
    }

    /// The leading whitespace of the line containing `offset`, in columns —
    /// what Monaco draws its indent guides from and indents wrapped lines to.
    public static func indentColumns(of line: String, tabWidth: Int = 4) -> Int {
        var columns = 0
        for c in line {
            if c == " " { columns += 1 }
            else if c == "\t" { columns += tabWidth - (columns % tabWidth) }
            else { break }
        }
        return columns
    }
}
