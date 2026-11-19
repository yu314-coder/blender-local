import Foundation

/// The launch, timed: milliseconds since the process started at each step,
/// printed with `-launch-trace` (Debug). What a change to the launch is
/// measured against.
public enum LaunchTrace {
    #if DEBUG || LAUNCH_TRACE
    static let enabled = ProcessInfo.processInfo.arguments.contains("-launch-trace")
    static let started: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()
    #endif

    /// The mark, the first time only (for a view's body or a frame).
    public static func once(_ what: String) {
        #if DEBUG || LAUNCH_TRACE
        guard enabled else { return }
        lock.lock(); let new = seen.insert(what).inserted; lock.unlock()
        if new { mark(what) }
        #endif
    }
    #if DEBUG || LAUNCH_TRACE
    nonisolated(unsafe) private static var seen = Set<String>()
    private static let lock = NSLock()
    #endif

    /// `-launch-wait <seconds>`: the launch held at its first line, for a
    /// profiler to attach before anything has run.
    public static func waitForProfiler() {
        #if DEBUG || LAUNCH_TRACE
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-launch-wait"), i + 1 < args.count, let s = Double(args[i + 1]) {
            Thread.sleep(forTimeInterval: s)
        }
        #endif
    }

    public static func mark(_ what: String) {
        #if DEBUG || LAUNCH_TRACE
        guard enabled else { return }
        // On the main thread, its processor time too: what the launch costs
        // however busy the machine is.
        let cpu = Thread.isMainThread
            ? " (main \(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1_000_000) ms)" : ""
        print("[bk-launch] \(Int(Date().timeIntervalSince(started) * 1000)) ms\(cpu): \(what)")
        fflush(stdout)
        #endif
    }
}

/// Blender's module is a 220 MB binary: half of `import bpy` is dyld mapping
/// it and binding its symbols. That needs neither Python nor the main
/// thread, so it starts as the app does, beside the interface being built;
/// the import that follows finds it loaded.
///
/// It is not free: dyld holds its lock for the whole load, and a profile
/// shows the main thread stopped at a new Swift class until the load ends.
/// Thirty paired launches on a busy Mac, with and without it, did not tell
/// the two apart, so it stays as first measured. `-no-prewarm` (a Debug or
/// LAUNCH_TRACE build) turns it off, to measure again on a quiet machine or
/// an iPad.
public enum BpyPrewarm {
    public static func start() {
        #if DEBUG || LAUNCH_TRACE
        if ProcessInfo.processInfo.arguments.contains("-no-prewarm") { return }
        #endif
        guard let frameworks = Bundle.main.privateFrameworksURL else { return }
        let binary = frameworks.appendingPathComponent("bpy.__init__.framework/bpy.__init__").path
        guard FileManager.default.fileExists(atPath: binary) else { return }
        Thread.detachNewThread {
            LaunchTrace.mark("prewarm: loading Blender's binary")
            _ = dlopen(binary, RTLD_NOW)
            LaunchTrace.mark("prewarm: loaded")
        }
    }
}
