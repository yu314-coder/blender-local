import Foundation

// ---------------------------------------------------------------------------
// Live output
//
// A script prints as it goes, and the console used to receive all of it at
// once when the run ended — which for a long bpy build is exactly when the
// progress stops being worth having.
//
// The awkward part is that the script runs on the main thread. That is not an
// oversight: every `_blenderkit` bridge call mutates the scene, which is
// @Observable and read by SwiftUI, so moving Python to a background thread
// means marshalling forty-odd entry points rather than one. Until that is
// done, output can be *delivered* live but cannot be *drawn* live, because
// the thread that would draw it is the one running the script.
//
// So the run loop is pumped from inside the run: often enough to look
// continuous, rarely enough not to dominate a tight print loop. Pumping runs
// the risk of re-entrancy, which is why the session refuses a second run while
// one is in flight.
//
// Two things trigger a pump. Output is the obvious one. The other is a
// heartbeat, because output alone is not enough: a script that computes for a
// second without printing produced no pumps at all, so the interface froze
// with the Run Script header still undrawn — 1.2s into a 3s run the console
// showed nothing but the startup banner. Blender behaves the same way, and
// gives scripts `wm.progress_update` to break the silence; this does not wait
// to be asked.
// ---------------------------------------------------------------------------

enum ConsoleStream {

    /// Where live output goes. Set for the duration of a run.
    nonisolated(unsafe) static var sink: ((String) -> Void)?
    /// When the run loop was last given a turn.
    nonisolated(unsafe) static var lastPump = Date.distantPast
    /// Roughly 20 redraws a second: below this the pumping costs more than the
    /// feedback is worth, above it a print-heavy loop stutters visibly.
    static let pumpInterval: TimeInterval = 0.05

    /// When the run in flight started, so the interface can say how long it has
    /// been going. Nil when nothing is running.
    nonisolated(unsafe) static var runStarted: Date?

    /// Called on the main thread each time the interface is given a turn, so
    /// something observable changes and SwiftUI has a reason to redraw. A run
    /// loop turn on its own draws nothing if no state moved.
    nonisolated(unsafe) static var tick: (() -> Void)?

    /// Give the main run loop a turn.
    ///
    /// `before: Date()` rather than a future date: this drains what is already
    /// pending and returns, instead of waiting for something new to arrive.
    static func pump() {
        guard Thread.isMainThread else { return }
        lastPump = Date()
        tick?()
        RunLoop.current.run(mode: .default, before: Date())
    }

    /// A pump, but no more often than `pumpInterval`.
    static func pumpIfDue() {
        guard Thread.isMainThread,
              Date().timeIntervalSince(lastPump) >= pumpInterval
        else { return }
        pump()
    }

    /// Asks CPython for a turn. Installed by the embedded runtime, which is
    /// the only part of the app that may touch the C API — the bridge is
    /// compiled on its own by the host test suites, where there is no
    /// interpreter to ask and this is correctly nil.
    nonisolated(unsafe) static var requestPump: (() -> Void)?

    /// Asks CPython for a turn on a timer, for as long as it is running.
    ///
    /// The thread does not touch Python state and does not need the GIL — it
    /// only queues a pending call, which CPython later runs on the main thread
    /// between two bytecodes. A script stuck inside one long C call (a bpy
    /// operator, a big numpy multiply) still will not yield, because there is
    /// no bytecode boundary to run it at. Blender has the same limit.
    final class Heartbeat {
        private let stopped = Atomic()
        private let interval: TimeInterval

        init(interval: TimeInterval) {
            self.interval = interval
            let thread = Thread { [stopped, interval] in
                while !stopped.value {
                    ConsoleStream.requestPump?()
                    Thread.sleep(forTimeInterval: interval)
                }
            }
            thread.name = "bk.console.heartbeat"
            thread.stackSize = 64 * 1024
            thread.start()
        }

        func cancel() { stopped.value = true }
    }

    static func startHeartbeat() -> Heartbeat {
        Heartbeat(interval: pumpInterval)
    }

    /// A boolean two threads can share without tearing.
    final class Atomic: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
            set { lock.lock(); flag = newValue; lock.unlock() }
        }
    }
}

/// The pending call CPython runs for us, on the main thread, between two
/// bytecodes. Declared in PythonBootstrap.h and called from C.
@_cdecl("bk_pump_runloop")
func bk_pump_runloop() {
    ConsoleStream.pumpIfDue()
}

/// Joins the chunks Python writes into whole lines.
///
/// `print` writes the text and the newline as two separate calls, so a chunk
/// is not a line: a partial one has to wait for the rest rather than appear as
/// its own row. Locked because the chunks arrive on the script's thread and the
/// leftover is read again on the next chunk.
final class LineCarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = ""

    /// The complete lines this chunk finished, keeping any remainder.
    func take(_ chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        carry += chunk
        var out: [String] = []
        while let newline = carry.firstIndex(of: "\n") {
            out.append(String(carry[carry.startIndex..<newline]))
            carry = String(carry[carry.index(after: newline)...])
        }
        return out
    }

    /// Whatever is left when the run ends, if it never got its newline.
    func drain() -> String {
        lock.lock(); defer { lock.unlock() }
        let rest = carry
        carry = ""
        return rest
    }
}
