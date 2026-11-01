import Foundation
import QuartzCore

/// The three clocks Test All Features reads a feature by: how long the main
/// thread went without answering (`MainThreadWatchdog`), when the 3D View
/// drew its frames (`FrameClock`), and how much memory the app holds
/// (`MemoryFootprint`). All three ship in Release — the build a user has from
/// TestFlight is the one whose smoothness the test is for — and cost nothing
/// while no test runs: the watchdog's thread sleeps, and the frame clock keeps
/// one timestamp per frame.

/// The longest the main thread took to answer, measured from beside it.
///
/// A background thread posts an empty block to the main queue every 16 ms,
/// one at a time, and notes how long each waited before it ran. While the
/// main thread is inside Blender — an operator, a mirror pass — the block
/// waits for all of it, so the longest wait is the longest the interface
/// could not move: what a finger on the glass feels, and what iOS calls a
/// hang past 250 ms. A run-loop pump inside a long call answers it, as it
/// answers a touch.
///
/// It samples the memory footprint on the same thread, so a feature's peak is
/// the highest the footprint stood while it ran, not only before and after.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    /// How often it asks: a 60 Hz display's frame.
    public static let interval: TimeInterval = 0.016

    private let lock = NSLock()
    private var thread: Thread?
    private var keepRunning = false
    private var open = false
    private var worst: TimeInterval = 0
    private var peak: UInt64 = 0
    /// When the window opened: a block posted before it counts only its wait
    /// from then, so work just before a feature is not taken for its own.
    private var opened: CFTimeInterval = 0
    /// When the block on the main queue now was posted; nil when none waits.
    private var sent: CFTimeInterval?

    public init() {}

    /// Starts the thread, if it is not running.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        keepRunning = true
        let made = Thread { [weak self] in self?.loop() }
        made.name = "bk.featuretest.watchdog"
        made.qualityOfService = .userInteractive
        thread = made
        made.start()
    }

    /// Stops it; the next `start` begins again.
    public func stop() {
        lock.lock()
        keepRunning = false
        thread = nil
        lock.unlock()
    }

    /// Opens a window: the worst wait and the peak footprint from now.
    public func begin() {
        let footprint = MemoryFootprint.now()?.current ?? 0
        lock.lock()
        worst = 0
        peak = footprint
        opened = CACurrentMediaTime()
        open = true
        lock.unlock()
    }

    /// Closes it: the longest the main thread took to answer in the window,
    /// in seconds, a block still waiting counted as far as it has waited, and
    /// the highest footprint seen in it.
    public func end() -> (stall: TimeInterval, peak: UInt64) {
        let now = CACurrentMediaTime()
        let current = MemoryFootprint.now()?.current ?? 0
        lock.lock()
        defer { lock.unlock() }
        if let sent { worst = max(worst, now - max(sent, opened)) }
        open = false
        return (worst, max(peak, current))
    }

    private func loop() {
        while true {
            lock.lock()
            guard keepRunning, thread === Thread.current else { lock.unlock(); return }
            if sent == nil {
                let posted = CACurrentMediaTime()
                sent = posted
                DispatchQueue.main.async { [weak self] in self?.answered(posted) }
            }
            let sampling = open
            lock.unlock()
            if sampling, let footprint = MemoryFootprint.now()?.current {
                lock.lock()
                if open { peak = max(peak, footprint) }
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: Self.interval)
        }
    }

    private func answered(_ posted: CFTimeInterval) {
        let now = CACurrentMediaTime()
        lock.lock()
        if open { worst = max(worst, now - max(posted, opened)) }
        if sent == posted { sent = nil }
        lock.unlock()
    }
}

/// When the 3D View drew: the time each frame began encoding and finished,
/// and the time the system says it reached the screen.
///
/// `ViewportRenderer.draw(in:)` reports every frame (`drew`), on the main
/// thread, and the drawable's presented time when it is known (`presented`).
/// A feature's time ends at the first frame begun after its call returned —
/// the frame that shows what it did — and a continuous interaction's frame
/// times are the gaps between the frames drawn while it ran.
public final class FrameClock: @unchecked Sendable {
    public static let shared = FrameClock()

    private let lock = NSLock()
    private var recording = false
    private var began: [CFTimeInterval] = []
    private var encoding: [CFTimeInterval] = []
    private var shown: [CFTimeInterval] = []
    private var waiters: [(id: Int, after: CFTimeInterval, resume: (CFTimeInterval?) -> Void)] = []
    private var nextWaiter = 0
    /// The last frame's start, for a caller that only wants to know one came.
    public private(set) var lastBegan: CFTimeInterval = 0

    public init() {}

    /// Whether the renderer should ask the drawable for its presented time.
    public var wantsPresentedTimes: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    /// A frame was encoded and committed: begun at `began`, done at `ended`.
    public func drew(began start: CFTimeInterval, ended: CFTimeInterval) {
        lock.lock()
        lastBegan = start
        if recording {
            began.append(start)
            encoding.append(ended - start)
        }
        let ready = waiters.filter { start >= $0.after }
        waiters.removeAll { start >= $0.after }
        lock.unlock()
        for waiter in ready { waiter.resume(ended) }
    }

    /// The drawable of a recorded frame reached the screen at `time`; zero
    /// when the system dropped it.
    public func presented(_ time: CFTimeInterval) {
        guard time > 0 else { return }
        lock.lock()
        if recording { shown.append(time) }
        lock.unlock()
    }

    /// When the first frame begun at or after `time` finished, or nil when
    /// none came within `timeout` (no 3D View on screen).
    public func frame(after time: CFTimeInterval, timeout: TimeInterval = 1.5) async -> CFTimeInterval? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CFTimeInterval?, Never>) in
            lock.lock()
            let id = nextWaiter
            nextWaiter += 1
            waiters.append((id, time, { continuation.resume(returning: $0) }))
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let index = self.waiters.firstIndex { $0.id == id }
                let waiter = index.map { self.waiters.remove(at: $0) }
                self.lock.unlock()
                waiter?.resume(nil)
            }
        }
    }

    /// Keeps every frame's times from now until `stopRecording`.
    public func startRecording() {
        lock.lock()
        recording = true
        began = []
        encoding = []
        shown = []
        lock.unlock()
    }

    /// The frames since `startRecording`: when each began, how long the main
    /// thread spent encoding each, and when each that the system reported
    /// reached the screen.
    public func stopRecording() -> (began: [CFTimeInterval], encoding: [CFTimeInterval],
                                    presented: [CFTimeInterval]) {
        lock.lock()
        defer { lock.unlock() }
        recording = false
        return (began, encoding, shown.sorted())
    }
}

/// The app's memory footprint: what iOS holds against it, the number Xcode's
/// gauge and `footprint` show, and what the system ends an app for.
public enum MemoryFootprint {
    /// The footprint now and its highest over the process's life, in bytes,
    /// from `proc_pid_rusage` (RUSAGE_INFO_V4), as the Self-Test reads them;
    /// nil where it cannot be read.
    public static func now() -> (current: UInt64, peak: UInt64)? {
        guard let call = procPidRusage else { return nil }
        // rusage_info_v4 is 37 64-bit words after a 16-byte UUID; read into
        // a larger buffer, as the fields are counted from its start.
        var words = [UInt64](repeating: 0, count: 64)
        let status = words.withUnsafeMutableBytes { call(getpid(), 4, $0.baseAddress) }
        guard status == 0 else { return nil }
        // ri_phys_footprint is the eighth field, ri_lifetime_max_phys_footprint
        // the twenty-ninth.
        return (words[2 + 7], words[2 + 28])
    }

    private typealias Rusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32

    /// Looked up rather than declared: libproc's header is not in the iOS SDK,
    /// while the function is in every iOS and macOS libSystem.
    private static let procPidRusage: Rusage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        return unsafeBitCast(symbol, to: Rusage.self)
    }()

    /// Bytes as the report writes them: "1,426 MB".
    public static func megabytes(_ bytes: UInt64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        let mb = Int((Double(bytes) / 1_048_576).rounded())
        return (f.string(from: NSNumber(value: mb)) ?? "\(mb)") + " MB"
    }
}
