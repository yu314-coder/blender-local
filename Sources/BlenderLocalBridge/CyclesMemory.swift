import Foundation
import Metal
import os

/// How much memory Cycles may take for its GPU path states, set before bpy
/// loads.
///
/// Cycles sizes its integrator states to the Metal device's
/// `recommendedMaxWorkingSetSize` (90 % of it), then doubles them twice when
/// that leaves half free (`MetalDeviceQueue::num_concurrent_states`). It never
/// asks how much the process may use, and on iPadOS that is far less than the
/// GPU's working set. Measured on an M4 Mac, 1920×1080, one cube, after Add
/// Camera: 7,866 MB at the peak, of which ~5.7 GB was path states. On the
/// user's 8 GB iPad Air the same render ended the app.
///
/// Blender reads `CYCLES_METAL_WORKING_SET_PERCENT` at every render, so the
/// share is set here from the budget iPadOS gives the app (what it can still
/// allocate plus what it already has). Measured on the same scene: a 3 %
/// share (570 MB of states) peaked at 2,655 MB and rendered in 15.1 s, the
/// default in 21.0 s — fewer states cost no speed. A scene that needs more
/// than the share gets Cycles' own "Out of memory" error, which the Render
/// panel shows, instead of the app being ended.
public enum CyclesMemory {
    public static let percentVariable = "CYCLES_METAL_WORKING_SET_PERCENT"

    /// The share of the process budget Cycles' device memory may take: the
    /// rest is Blender, the kernels, the film and OIDN (about 2.1 GB on that
    /// 1080p render, outside the states).
    public static let budgetShare = 0.25

    /// The percent of the working set that is `budgetShare` of `budget`,
    /// between 1 and Cycles' own 90; nil when there is no budget (macOS, where
    /// nothing ends an app for its memory).
    public static func workingSetPercent(budget: UInt64, workingSet: UInt64) -> Int? {
        guard budget > 0, workingSet > 0 else { return nil }
        let percent = Int((Double(budget) * budgetShare / Double(workingSet) * 100).rounded(.down))
        return max(1, min(90, percent))
    }

    /// The process's budget: what it can still allocate plus its footprint.
    /// `-memory-limit-mb <n>` (Debug) stands in for an iPad's on a Mac.
    public static func processBudget() -> UInt64 {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-memory-limit-mb"), i + 1 < args.count, let mb = UInt64(args[i + 1]) {
            return mb * 1_048_576
        }
        #endif
        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        #else
        let available: UInt64 = 0
        #endif
        guard available > 0 else { return 0 }
        return available + (MemoryFootprint.now()?.current ?? 0)
    }

    /// The lean share's ceiling: Cycles' device memory up to this, the scene
    /// included. Measured, one cube and a sphere at 1920×1080: 360 MB of states
    /// (2 % of the M4's working set) rendered as fast as 900 MB (5.25 s against
    /// 5.03 s) and peaked 560 MB lower; 180 MB took 2.4× as long.
    public static let leanBytes: UInt64 = 768 << 20

    /// The shares this launch uses: `lean` first, `full` (a quarter of the
    /// budget) once a scene has needed more.
    public static func shares(budget: UInt64, workingSet: UInt64) -> (lean: Int, full: Int)? {
        guard let full = workingSetPercent(budget: budget, workingSet: workingSet) else { return nil }
        let leanBudget = min(budget, UInt64(Double(leanBytes) / budgetShare))
        let lean = workingSetPercent(budget: leanBudget, workingSet: workingSet) ?? full
        return (min(lean, full), full)
    }

    nonisolated(unsafe) private static var current: (lean: Int, full: Int, widened: Bool)?

    /// Sets Cycles' lean share for this launch; returns what was set.
    @discardableResult
    public static func fit() -> Int? {
        guard getenv(percentVariable) == nil,
              let device = MTLCreateSystemDefaultDevice(),
              let shares = shares(budget: processBudget(), workingSet: device.recommendedMaxWorkingSetSize)
        else { return nil }
        current = (shares.lean, shares.full, false)
        setenv(percentVariable, String(shares.lean), 1)
        print("[bk] Cycles: \(shares.lean)% of the GPU working set "
              + "(\(MemoryFootprint.megabytes(device.recommendedMaxWorkingSetSize))), "
              + "\(shares.full)% for a scene that needs it; budget \(MemoryFootprint.megabytes(processBudget()))")
        return shares.lean
    }

    /// Whether a render failed for want of Cycles' memory.
    public static func isOutOfMemory(_ message: String?) -> Bool {
        message?.localizedCaseInsensitiveContains("out of memory") ?? false
    }

    /// After a render ran out: the full share for the rest of the launch.
    /// True when that is more than before, so the render is worth repeating.
    /// Called between renders, never during one (Cycles reads the variable
    /// as a render starts).
    public static func widen() -> Bool {
        guard let now = current, !now.widened, now.full > now.lean else { return false }
        current = (now.lean, now.full, true)
        setenv(percentVariable, String(now.full), 1)
        print("[bk] Cycles: the scene needed more; \(now.full)% from now on")
        return true
    }

    /// What the panel says when even the full share was not enough.
    public static let outOfMemoryMessage = "This scene needs more memory than iPadOS gives Blender Local "
        + "for Cycles on the GPU. A lower Resolution %, smaller textures, Cycles on the CPU, "
        + "or Eevee needs less."
}

/// A render that ended the app — iPadOS ends one that runs out of memory, and
/// Metal can abort inside Blender — leaves nothing the app can catch. So a
/// render leaves a note on disk as it starts and takes it away when it ends;
/// a note still there at the next launch means the last render never
/// finished, and the Render panel says so instead of saying nothing.
public enum RenderInterrupted {
    static var url: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("render-in-progress.txt")
    }

    /// What is rendering, as the message will name it ("Cycles on the GPU
    /// at 1920×1080").
    public static func begin(_ what: String) {
        _ = pending
        try? Data(what.utf8).write(to: url, options: .atomic)
    }

    public static func end() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The last launch's note, read before this launch's first render
    /// writes its own.
    nonisolated(unsafe) private static var pending: String? = {
        guard let what = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return message(what)
    }()

    /// The message for a render the last launch never finished, once.
    public static func take() -> String? {
        let message = pending
        pending = nil
        return message
    }

    public static func message(_ what: String) -> String {
        "Blender Local closed during the last render (\(what.isEmpty ? "unknown engine" : what)). "
            + "iPadOS closes an app that runs out of memory: a lower Resolution %, fewer samples, "
            + "Eevee, or Cycles on the CPU needs less."
    }
}
