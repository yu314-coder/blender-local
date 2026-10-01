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
/// on the Python thread, which is why a script's run is fire-and-forget and why
/// the interface refuses a second one while it is in flight.
@inline(__always)
func onMain<T>(_ body: () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
}
