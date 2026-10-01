import Foundation
import simd

/// Blender's animation data, reduced to keyframed object transforms.
///
/// Blender stores F-curves per channel with per-keyframe handles; this keys the
/// whole vector at once, which covers `keyframe_insert("location")` and the
/// dope sheet, but not editing individual handles in a graph editor.
public struct AnimationData: Codable, Sendable {

    /// Blender's interpolation modes. Bezier is its default.
    public enum Interpolation: String, Codable, CaseIterable, Sendable {
        case constant, linear, bezier
        public var label: String { rawValue.capitalized }
        public var bpyValue: String { rawValue.uppercased() }
    }

    /// One keyed channel: `location`, `rotation_euler` or `scale`.
    public struct Channel: Codable, Sendable {
        public var path: String
        /// Frame → value. A dictionary keeps insertion idempotent, which is
        /// what re-keying the same frame should be.
        public var keys: [Int: [Float]] = [:]

        public var frames: [Int] { keys.keys.sorted() }
    }

    public var channels: [String: Channel] = [:]
    public var interpolation: Interpolation = .bezier

    public var isEmpty: Bool { channels.allSatisfy { $0.value.keys.isEmpty } }

    /// Every frame that carries a key on any channel — what the dope sheet
    /// draws as diamonds.
    public var keyedFrames: [Int] {
        Array(Set(channels.values.flatMap { $0.frames })).sorted()
    }

    public mutating func insert(path: String, frame: Int, value: SIMD3<Float>) {
        var channel = channels[path] ?? Channel(path: path)
        channel.keys[frame] = [value.x, value.y, value.z]
        channels[path] = channel
    }

    public mutating func remove(path: String, frame: Int) {
        channels[path]?.keys.removeValue(forKey: frame)
    }

    public mutating func removeAll(at frame: Int) {
        for key in channels.keys {
            channels[key]?.keys.removeValue(forKey: frame)
        }
    }

    /// The channel's value at a frame, interpolated between the surrounding
    /// keys. Before the first key it holds the first value and after the last
    /// it holds the last, which is Blender's default extrapolation.
    public func value(path: String, at frame: Int) -> SIMD3<Float>? {
        guard let channel = channels[path], !channel.keys.isEmpty else { return nil }
        let frames = channel.frames

        if let exact = channel.keys[frame] { return SIMD3(exact[0], exact[1], exact[2]) }
        guard let first = frames.first, let last = frames.last else { return nil }
        if frame <= first { return vector(channel.keys[first]!) }
        if frame >= last  { return vector(channel.keys[last]!) }

        // The keys either side of this frame.
        var lower = first, upper = last
        for f in frames {
            if f <= frame { lower = f }
            if f >= frame { upper = f; break }
        }
        guard upper > lower else { return vector(channel.keys[lower]!) }

        let a = vector(channel.keys[lower]!)
        let b = vector(channel.keys[upper]!)
        let raw = Float(frame - lower) / Float(upper - lower)

        switch interpolation {
        case .constant: return a
        case .linear:   return a + (b - a) * raw
        case .bezier:
            // Blender's default bezier eases in and out; with automatic
            // handles that is very close to smoothstep.
            let t = raw * raw * (3 - 2 * raw)
            return a + (b - a) * t
        }
    }

    private func vector(_ a: [Float]) -> SIMD3<Float> {
        a.count >= 3 ? SIMD3(a[0], a[1], a[2]) : .zero
    }
}

public extension BKScene {

    /// `bpy.ops.anim.keyframe_insert_menu` — keys the selection's transform at
    /// the current frame.
    @discardableResult
    func insertKeyframe(paths: [String] = ["location", "rotation_euler", "scale"]) -> Int {
        var keyed = 0
        for obj in objects where selection.contains(obj.id) {
            for path in paths {
                let value: SIMD3<Float>
                switch path {
                case "location":       value = obj.location
                case "rotation_euler": value = obj.rotation
                case "scale":          value = obj.scale
                default: continue
                }
                obj.animation.insert(path: path, frame: frameCurrent, value: value)
            }
            keyed += 1
        }
        return keyed
    }

    /// `bpy.ops.anim.keyframe_delete_v3d`.
    @discardableResult
    func deleteKeyframe() -> Int {
        var removed = 0
        for obj in objects where selection.contains(obj.id) {
            if !obj.animation.keyedFrames.contains(frameCurrent) { continue }
            obj.animation.removeAll(at: frameCurrent)
            removed += 1
        }
        return removed
    }

    /// Applies every object's animation at the current frame. Called whenever
    /// the frame changes, which is what makes the timeline drive the scene.
    func evaluateAnimation() {
        for obj in objects where !obj.animation.isEmpty {
            if let v = obj.animation.value(path: "location", at: frameCurrent) {
                obj.location = v
            }
            if let v = obj.animation.value(path: "rotation_euler", at: frameCurrent) {
                obj.rotation = v
            }
            if let v = obj.animation.value(path: "scale", at: frameCurrent) {
                obj.scale = v
            }
        }
    }

    /// Frames carrying a key on anything selected — the dope-sheet summary row.
    var selectedKeyedFrames: [Int] {
        let sets = objects.filter { selection.contains($0.id) }.map(\.animation.keyedFrames)
        return Array(Set(sets.flatMap { $0 })).sorted()
    }
}
