import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Colouring for Python source, in Blender's Text Editor palette.
///
/// A single left-to-right pass rather than a set of regular expressions run
/// over each other. That ordering is the whole problem with highlighting: a
/// `#` inside a string is not a comment, a `"` inside a comment does not open
/// a string, and a keyword inside either is just letters. Scanning once, with
/// the scanner knowing what it is inside of, gets all three right by
/// construction — where independent passes have to be patched against each
/// other forever.
enum PythonSyntax {

    /// What the scanner found. Kept free of UIKit so the scanning — the part
    /// that can silently mis-colour — is testable without a simulator.
    enum Token: Equatable {
        case plain, keyword, builtin, string, number, comment, decorator
    }

    /// The token runs, as UTF-16 ranges so they can be applied directly.
    static func spans(_ source: String) -> [(NSRange, Token)] {
        var spans: [(NSRange, Token)] = []
        let chars = Array(source.unicodeScalars)
        // UTF-16 offsets, because NSRange counts UTF-16 units and a scalar
        // outside the BMP counts as two. A comment with an emoji in it would
        // otherwise shift every colour after it.
        var utf16Index = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(chars.count + 1)
        for scalar in chars {
            offsets.append(utf16Index)
            utf16Index += UTF16.width(scalar)
        }
        offsets.append(utf16Index)

        func range(_ from: Int, _ to: Int) -> NSRange {
            NSRange(location: offsets[from], length: offsets[to] - offsets[from])
        }
        func isIdentifierStart(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.letters.contains(s) || s == "_"
        }
        func isIdentifier(_ s: Unicode.Scalar) -> Bool {
            isIdentifierStart(s) || CharacterSet.decimalDigits.contains(s)
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]

            // Comment: to end of line.
            if c == "#" {
                var j = i
                while j < chars.count && chars[j] != "\n" { j += 1 }
                spans.append((range(i, j), .comment))
                i = j
                continue
            }

            // String, single or triple quoted, with escapes.
            if c == "\"" || c == "'" {
                let quote = c
                let triple = i + 2 < chars.count && chars[i + 1] == quote && chars[i + 2] == quote
                var j = i + (triple ? 3 : 1)
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if triple {
                        if chars[j] == quote, j + 2 < chars.count,
                           chars[j + 1] == quote, chars[j + 2] == quote {
                            j += 3
                            break
                        }
                    } else {
                        if chars[j] == quote { j += 1; break }
                        // An unterminated single-quoted string ends at the
                        // newline, the way Python's own parser gives up.
                        if chars[j] == "\n" { break }
                    }
                    j += 1
                }
                spans.append((range(i, min(j, chars.count)), .string))
                i = min(j, chars.count)
                continue
            }

            // Decorator.
            if c == "@", i + 1 < chars.count, isIdentifierStart(chars[i + 1]) {
                var j = i + 1
                while j < chars.count && isIdentifier(chars[j]) { j += 1 }
                spans.append((range(i, j), .decorator))
                i = j
                continue
            }

            // Number: digits, and a leading dot only when a digit follows.
            if CharacterSet.decimalDigits.contains(c)
                || (c == "." && i + 1 < chars.count && CharacterSet.decimalDigits.contains(chars[i + 1])) {
                var j = i
                while j < chars.count,
                      CharacterSet.decimalDigits.contains(chars[j]) || chars[j] == "."
                        || chars[j] == "e" || chars[j] == "E" || chars[j] == "x"
                        || chars[j] == "_"
                        || ((chars[j] == "+" || chars[j] == "-") && j > i
                            && (chars[j - 1] == "e" || chars[j - 1] == "E")) {
                    j += 1
                }
                spans.append((range(i, j), .number))
                i = j
                continue
            }

            // Word: keyword, known name, or plain.
            if isIdentifierStart(c) {
                var j = i
                while j < chars.count && isIdentifier(chars[j]) { j += 1 }
                let word = String(String.UnicodeScalarView(chars[i..<j]))
                if PythonWords.keywords.contains(word) {
                    spans.append((range(i, j), .keyword))
                } else if PythonWords.builtins.contains(word) {
                    spans.append((range(i, j), .builtin))
                }
                i = j
                continue
            }

            i += 1
        }
        return spans
    }
}

#if canImport(UIKit)
extension PythonSyntax.Token {
    /// Blender's own Text Editor palette, which a reader of this app has
    /// probably already learned somewhere else.
    var colour: UIColor {
        switch self {
        case .plain:     return UIColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
        case .keyword:   return UIColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1)
        case .builtin:   return UIColor(red: 0.55, green: 0.78, blue: 0.98, alpha: 1)
        case .string:    return UIColor(red: 0.56, green: 0.82, blue: 0.55, alpha: 1)
        case .number:    return UIColor(red: 0.85, green: 0.72, blue: 0.98, alpha: 1)
        case .comment:   return UIColor(red: 0.45, green: 0.47, blue: 0.45, alpha: 1)
        case .decorator: return UIColor(red: 0.98, green: 0.80, blue: 0.45, alpha: 1)
        }
    }
}

extension PythonSyntax {
    /// Attributed source, ready for a `UITextView`.
    static func highlight(_ source: String, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: source,
            attributes: [.font: font, .foregroundColor: Token.plain.colour])
        for (range, token) in spans(source) {
            out.addAttribute(.foregroundColor, value: token.colour, range: range)
        }
        return out
    }
}
#endif
