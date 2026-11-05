import Foundation

// MainWait (MainThread.swift) under the shape BpySession.evaluateKeepingResponsive
// gives it: the main thread waits for the script thread and serves its onMain
// calls meanwhile. Each call lends the caller's closure (withoutActuallyEscaping);
// if anything on the main side still holds it when the caller is woken, Swift
// stops the app. That happened on November 5, in Test All Features' Rewind
// with the Mac under load: the serving loop signalled the caller from inside
// the work it still held. A busy main thread after each call widens that
// window, so the old code fails here every run.

final class Flag: @unchecked Sendable {
    private var v = false
    private let l = NSLock()
    var value: Bool {
        get { l.lock(); defer { l.unlock() }; return v }
        set { l.lock(); v = newValue; l.unlock() }
    }
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures += 1 }
}

let rounds = 200, callsPerRound = 1_000
var answered = 0, rightAnswers = 0
for _ in 0..<rounds {
    let waiter = MainWait.begin()
    let done = Flag()
    let sums = Flag()
    DispatchQueue.global().async {
        var sum = 0
        for i in 0..<callsPerRound {
            let payload = [i, i + 1]      // a closure with a context to hold
            sum += onMain { payload.reduce(0, +) }
        }
        sums.value = sum == callsPerRound * callsPerRound
        done.value = true
        waiter.wake.signal()
    }
    while !done.value {
        _ = waiter.wake.wait(timeout: .now() + 0.016)
        waiter.serve()
        var x = 0
        for k in 0..<200 { x &+= k }      // the main thread busy a moment
        if x == -1 { print(x) }
    }
    waiter.end()
    answered += callsPerRound
    if sums.value { rightAnswers += 1 }
}
check(answered == rounds * callsPerRound, "\(answered) calls handed to the waiting main thread, none stopped the app")
check(rightAnswers == rounds, "every call's answer came back to the script thread (\(rightAnswers) of \(rounds) rounds)")
check(MainWait.current == nil, "no wait left active after end()")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
