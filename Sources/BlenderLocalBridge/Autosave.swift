import Foundation

/// Keeps the scene on disk as the work happens, rather than when the app
/// happens to be put away.
///
/// It used to write only on a scene-phase change, which covers switching apps
/// and covers nothing else. This app holds a 400 MB Blender in memory on a
/// tablet; being killed for memory is not an edge case, and neither is a crash
/// in a script. Everything between the last time the user backgrounded the app
/// and the moment it died was simply gone.
///
/// Debounced rather than written on every change: dragging a slider is sixty
/// scene mutations a second, and sixty writes a second of the whole document
/// would be felt. Two seconds of quiet, or an immediate flush when the app is
/// going away.
public final class Autosave: @unchecked Sendable {

    /// How long to wait for the edits to stop before writing.
    public static let quiet: TimeInterval = 2.0

    private let url: URL
    private let queue = DispatchQueue(label: "bk.autosave", qos: .utility)
    private let lock = NSLock()
    private var pending: DispatchWorkItem?
    /// The last thing written, so an unchanged scene is not rewritten every
    /// two seconds for as long as the app is open.
    private var lastWritten: Data?

    public private(set) var lastSaved: Date?
    public private(set) var lastError: String?

    public init(url: URL) { self.url = url }

    /// Note that something changed. Writes once the edits stop.
    ///
    /// The snapshot is taken here, on the caller's thread, because that is the
    /// one allowed to read the scene; only the encoding and the write go to the
    /// background. Taking it later would race whatever the next edit is doing.
    public func schedule(_ scene: BKScene) {
        let snapshot = scene.snapshot()
        lock.lock()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(snapshot) }
        pending = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + Self.quiet, execute: work)
    }

    /// Write now — the app is going away, or the user asked.
    public func flush(_ scene: BKScene) {
        let snapshot = scene.snapshot()
        lock.lock(); pending?.cancel(); pending = nil; lock.unlock()
        write(snapshot)
    }

    private func write(_ snapshot: SceneSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            lock.lock()
            let unchanged = data == lastWritten
            if !unchanged { lastWritten = data }
            lock.unlock()
            guard !unchanged else { return }
            // Atomic, so a kill halfway through leaves the previous save intact
            // rather than a truncated file that will not open.
            try data.write(to: url, options: .atomic)
            lastSaved = Date()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }
}
