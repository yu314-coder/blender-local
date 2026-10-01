import Foundation

/// Reading the bytes SwiftTerm sends for a key.
///
/// A hardware key arrives as one write: a character's UTF-8, a control byte,
/// or a whole escape sequence — `ESC [ D` for ←, `ESC b` for ⌥←, `ESC [ 1 ; 5 D`
/// for ⌃←. So a write that is a lone escape is the Escape key itself, not the
/// start of a sequence still to come. The one thing that spans writes is a
/// bracketed paste, which is held in `pasting` until its end marker arrives.
extension ConsoleLineEditor {

    static let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]   // ESC [ 201 ~

    func receive(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if isRunning {
            // A script hears only ⌃C; a console command gets the keyboard.
            runningInput(bytes)
            return
        }
        onKey()

        var b = bytes
        if var pending = pasting {
            pending += b
            guard let end = Self.find(Self.pasteEnd, in: pending) else {
                pasting = pending
                return
            }
            pasting = nil
            lastKeyWasTab = false
            paste(String(decoding: pending[..<end], as: UTF8.self))
            b = Array(pending[(end + Self.pasteEnd.count)...])
            guard !b.isEmpty else { return }
        }

        // Text with a line break in it and no escape is a paste that was not
        // bracketed — dictation, or a keyboard that does not bracket — and is
        // handled as one, rather than run a line at a time.
        if b.count > 1, !b.contains(0x1b), b.contains(where: { $0 == 0x0a || $0 == 0x0d }),
           b.contains(where: { $0 >= 0x20 && $0 != 0x7f }) {
            lastKeyWasTab = false
            paste(String(decoding: b, as: UTF8.self))
            return
        }

        var text: [UInt8] = []
        var i = 0
        while i < b.count {
            let c = b[i]
            if c >= 0x20 && c != 0x7f {
                text.append(c)
                i += 1
                continue
            }
            typeText(&text)
            if c == 0x1b {
                i = escape(b, at: i)
                if pasting != nil {
                    // The rest of this write belongs to the paste.
                    let rest = Array(b[i...])
                    if !rest.isEmpty { receive(rest) }
                    return
                }
            } else {
                control(c)
                i += 1
            }
        }
        typeText(&text)
    }

    private func typeText(_ text: inout [UInt8]) {
        guard !text.isEmpty else { return }
        let chars = Array(String(decoding: text, as: UTF8.self))
        text.removeAll()
        lastKeyWasTab = false
        if search != nil { searchType(chars) } else { insert(chars) }
    }

    private func control(_ c: UInt8) {
        let repeatedTab = lastKeyWasTab
        lastKeyWasTab = c == 0x09
        if search != nil {
            switch c {
            case 0x7f, 0x08: searchBackspace(); return
            case 0x12: searchOlder(); return
            case 0x13: searchNewer(); return
            case 0x07: cancelSearch(); return
            case 0x03: interrupt(); return
            case 0x0d, 0x0a: returnKey(); return
            default: acceptSearch()
            }
        }
        switch c {
        case 0x01: moveHome(smart: false)           // ⌃A
        case 0x02: moveLeft()                       // ⌃B
        case 0x03: interrupt()                      // ⌃C
        case 0x04: endOfInput()                     // ⌃D
        case 0x05: moveEnd()                        // ⌃E
        case 0x06: moveRight()                      // ⌃F
        case 0x08, 0x7f: backspace()                // ⌫
        case 0x09: tab(repeated: repeatedTab)       // Tab
        case 0x0a, 0x0d: returnKey()                // Return
        case 0x0b: killToEnd()                      // ⌃K
        case 0x0c: clearScreen()                    // ⌃L
        case 0x0e: historyNewer()                   // ⌃N
        case 0x10: historyOlder()                   // ⌃P
        case 0x12: searchOlder()                    // ⌃R
        case 0x15: killToStart()                    // ⌃U
        case 0x17: killWordBack(toSpace: true)      // ⌃W
        case 0x19: yank()                           // ⌃Y
        default: break
        }
    }

    /// The escape sequence starting at `start`. Returns the index after it.
    private func escape(_ b: [UInt8], at start: Int) -> Int {
        lastKeyWasTab = false
        var i = start + 1
        guard i < b.count else {
            escapeKey()
            return i
        }
        switch b[i] {
        case 0x5b:                                  // CSI: ESC [ params final
            i += 1
            var params: [UInt8] = []
            while i < b.count, !(0x40...0x7e).contains(b[i]) {
                params.append(b[i])
                i += 1
            }
            guard i < b.count else { return i }     // unfinished: drop it
            csi(final: b[i], params: String(decoding: params, as: UTF8.self))
            return i + 1
        case 0x4f:                                  // SS3: ESC O final
            i += 1
            guard i < b.count else { return i }
            csi(final: b[i], params: "")
            return i + 1
        default:                                    // ⌥ with a key
            meta(b[i])
            return i + 1
        }
    }

    private func csi(final: UInt8, params: String) {
        let parts = params.split(separator: ";").map(String.init)
        if final == 0x7e, parts.first == "200" {
            pasting = []
            return
        }
        if search != nil { acceptSearch() }
        // The second parameter is the modifier: 3 ⌥, 5 ⌃ — both move by word.
        let modifier = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let byWord = modifier == 3 || modifier == 5
        switch final {
        case 0x41: historyOlder()                            // ↑
        case 0x42: historyNewer()                            // ↓
        case 0x43: byWord ? moveWordRight() : moveRight()    // →
        case 0x44: byWord ? moveWordLeft() : moveLeft()      // ←
        case 0x48: moveHome(smart: true)                     // Home, ⌘←
        case 0x46: moveEnd()                                 // End, ⌘→
        case 0x5a: dedent()                                  // ⇧Tab
        case 0x7e:
            switch parts.first {
            case "1", "7": moveHome(smart: true)
            case "4", "8": moveEnd()
            case "3": byWord ? killWordForward() : deleteForward()   // ⌦
            default: break
            }
        default:
            break
        }
    }

    private func meta(_ key: UInt8) {
        if search != nil { acceptSearch() }
        switch key {
        case 0x62: moveWordLeft()                   // ⌥← arrives as ESC b
        case 0x66: moveWordRight()                  // ⌥→ arrives as ESC f
        case 0x64: killWordForward()                // ⌥D
        case 0x7f, 0x08: killWordBack(toSpace: false)   // ⌥⌫
        default: break
        }
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start] == needle[0] && Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }
}
