import Foundation

/// A console command's output on its way to the screen.
///
/// Command output is drawn as it is written, so a full-screen command can draw
/// at all. Two things happen to it on the way. Bare line feeds become CR LF, as
/// a terminal's line discipline would make them: Python writes `\n`, and a
/// terminal given only `\n` moves down without going back to the left edge.
/// And the markers a full-screen command writes to switch the keyboard to raw
/// keys and back are taken out and reported, wherever the chunks split them.
struct ConsoleRawStream {

    enum Event: Equatable {
        case text(String)
        case raw
        case cooked
    }

    private static let raw = Array(ConsoleShell.rawMarker.utf8)
    private static let cooked = Array(ConsoleShell.cookedMarker.utf8)

    /// The end of the last chunk, when it could be the start of a marker.
    private var carry: [UInt8] = []
    /// The last byte sent was a CR, so a LF at the start of the next chunk
    /// already has one.
    private var afterCR = false

    mutating func take(_ chunk: String) -> [Event] {
        var bytes = carry + Array(chunk.utf8)
        carry = []
        var events: [Event] = []
        var text: [UInt8] = []

        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B {
                if Self.matches(Self.raw, in: bytes, at: i) {
                    flush(&text, into: &events)
                    events.append(.raw)
                    i += Self.raw.count
                    continue
                }
                if Self.matches(Self.cooked, in: bytes, at: i) {
                    flush(&text, into: &events)
                    events.append(.cooked)
                    i += Self.cooked.count
                    continue
                }
                // Too close to the end to tell: keep it for the next chunk.
                let tail = Array(bytes[i...])
                if Self.isPrefix(tail, of: Self.raw) || Self.isPrefix(tail, of: Self.cooked) {
                    carry = tail
                    bytes.removeSubrange(i...)
                    break
                }
            }
            text.append(bytes[i])
            i += 1
        }
        flush(&text, into: &events)
        return events
    }

    /// Whatever was held back when the run ends.
    mutating func finish() -> [Event] {
        guard !carry.isEmpty else { return [] }
        var text = carry
        carry = []
        var events: [Event] = []
        flush(&text, into: &events)
        return events
    }

    private mutating func flush(_ text: inout [UInt8], into events: inout [Event]) {
        guard !text.isEmpty else { return }
        var out: [UInt8] = []
        out.reserveCapacity(text.count + 8)
        for b in text {
            if b == 0x0A, !afterCR { out.append(0x0D) }
            out.append(b)
            afterCR = b == 0x0D
        }
        text.removeAll(keepingCapacity: true)
        events.append(.text(String(decoding: out, as: UTF8.self)))
    }

    private static func matches(_ marker: [UInt8], in bytes: [UInt8], at i: Int) -> Bool {
        guard i + marker.count <= bytes.count else { return false }
        for k in 0..<marker.count where bytes[i + k] != marker[k] { return false }
        return true
    }

    private static func isPrefix(_ tail: [UInt8], of marker: [UInt8]) -> Bool {
        tail.count < marker.count && Array(marker.prefix(tail.count)) == tail
    }
}
