import Foundation

/// Run a bridge callback on the main thread.
///
/// Every one of these is entered from Python, and since scripts moved off the
/// main thread that means from a thread SwiftUI knows nothing about. They all
/// touch `BKScene`, which is `@Observable` and read by the interface while it
/// draws — mutating it from another thread is not a race that shows up as a
/// wrong number, it is one that shows up as a crash inside SwiftUI's diffing,
/// a frame later, somewhere else entirely.
///
/// `sync`, not `async`: half of these read the scene back to Python and have to
/// return an answer. It cannot deadlock as long as the main thread never waits
/// on the Python thread without serving these: a script's run is
/// fire-and-forget, and the interface refuses a second one while it is in
/// flight. The one place the main thread does wait, an operation run with the
/// window kept turning (`BpySession.evaluateKeepingResponsive`), serves them
/// itself through `MainWait` — not through the main queue, which does not run
/// a block while the main thread is inside another, as it is in a main-actor
/// task.
@inline(__always)
func onMain<T>(_ body: () -> T) -> T {
    if Thread.isMainThread { return body() }
    if let waiter = MainWait.current { return waiter.run(body) }
    return DispatchQueue.main.sync(execute: body)
}

/// The main thread waiting for the script thread, and serving its `onMain`
/// calls meanwhile: each is handed over here and run by the waiting loop
/// (`serve`), which a semaphore wakes the moment one arrives.
final class MainWait: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: MainWait?
    static var current: MainWait? {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Signalled for each call handed over, and once when the work is done.
    let wake = DispatchSemaphore(value: 0)
    private let queueLock = NSLock()
    private var queue: [Handoff] = []

    /// One call handed over: the work, and the signal that it is done.
    ///
    /// The work holds the caller's closure, which `run` may only lend
    /// (`withoutActuallyEscaping`): by the time the caller is woken, nothing
    /// on the main thread may still hold it, or Swift stops the app ("closure
    /// argument was escaped in withoutActuallyEscaping block"). It did, in
    /// Test All Features' Rewind with the Mac under load: `done` was signalled
    /// from inside the work while the serving loop still held it. Now the
    /// loop drops the work first (`perform`) and signals after.
    private final class Handoff: @unchecked Sendable {
        var work: (() -> Void)?
        let done = DispatchSemaphore(value: 0)
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    /// Begins a wait; nothing is handed over before this.
    static func begin() -> MainWait {
        let waiter = MainWait()
        lock.lock(); active = waiter; lock.unlock()
        return waiter
    }

    /// Ends it, once the work is done and nothing more can be handed over.
    func end() {
        serve()
        Self.lock.lock(); if Self.active === self { Self.active = nil }; Self.lock.unlock()
    }

    /// From the script thread: runs `body` on the main thread, through the
    /// waiting loop, and returns its answer.
    func run<T>(_ body: () -> T) -> T {
        withoutActuallyEscaping(body) { body in
            var result: T?
            let handoff = Handoff { result = body() }
            queueLock.lock()
            queue.append(handoff)
            queueLock.unlock()
            wake.signal()
            handoff.done.wait()
            return result!
        }
    }

    /// On the main thread: runs what has been handed over.
    func serve() {
        while true {
            queueLock.lock()
            let next = queue.isEmpty ? nil : queue.removeFirst()
            queueLock.unlock()
            guard let next else { return }
            Self.perform(next)
            next.done.signal()
        }
    }

    /// Runs the work and lets go of it before returning, so that nothing here
    /// holds the caller's closure once `done` is signalled.
    @inline(never)
    private static func perform(_ handoff: Handoff) {
        guard let work = handoff.work else { return }
        handoff.work = nil
        work()
    }
}
