import Foundation
import simd

/// What `_blenderkit_anim` hands the interface, applied to the display cache.
///
/// The `bk_anim_*` entry points in Python/EmbeddedBpyRuntime.swift unpack the
/// C buffers and call these. They are kept out of that file because it names
/// the C API and the host test suites cannot compile it; these are plain Swift
/// and tests/animation runs them.
///
/// Every assignment checks first. `BKScene` and `BKObject` are @Observable, so
/// writing a value that did not change still redraws whatever reads it — and a
/// frame change arrives up to sixty times a second.
public enum AnimationMirror {

    /// The scene state `anim_state` carries, in its order.
    public struct State: Equatable, Sendable {
        public var start: Int
        public var end: Int
        public var current: Int
        public var subframe: Float
        public var fps: Double
        public var usePreviewRange: Bool
        public var previewStart: Int
        public var previewEnd: Int
        public var autoKey: Bool
        public var autoKeyReplace: Bool
        public var onlyInsertAvailable: Bool
        public var onlySelectedKeys: Bool
        public var loopMode: PlaybackLoopMode

        public init(start: Int, end: Int, current: Int, subframe: Float, fps: Double,
                    usePreviewRange: Bool, previewStart: Int, previewEnd: Int,
                    autoKey: Bool, autoKeyReplace: Bool, onlyInsertAvailable: Bool,
                    onlySelectedKeys: Bool, loopMode: PlaybackLoopMode) {
            self.start = start; self.end = end; self.current = current
            self.subframe = subframe; self.fps = fps
            self.usePreviewRange = usePreviewRange
            self.previewStart = previewStart; self.previewEnd = previewEnd
            self.autoKey = autoKey; self.autoKeyReplace = autoKeyReplace
            self.onlyInsertAvailable = onlyInsertAvailable
            self.onlySelectedKeys = onlySelectedKeys
            self.loopMode = loopMode
        }
    }

    public static func state(of scene: BKScene) -> State {
        let a = scene.animation
        return State(start: scene.frameStart, end: scene.frameEnd, current: scene.frameCurrent,
                     subframe: a.subframe, fps: a.fps, usePreviewRange: a.usePreviewRange,
                     previewStart: a.previewStart, previewEnd: a.previewEnd,
                     autoKey: a.autoKey, autoKeyReplace: a.autoKeyReplace,
                     onlyInsertAvailable: a.onlyInsertAvailable,
                     onlySelectedKeys: a.onlySelectedKeys, loopMode: a.loopMode)
    }

    public static func apply(_ state: State, to scene: BKScene) {
        if scene.frameStart != state.start { scene.frameStart = state.start }
        if scene.frameEnd != state.end { scene.frameEnd = state.end }
        if scene.frameCurrent != state.current { scene.frameCurrent = state.current }
        var a = scene.animation
        a.subframe = state.subframe
        // A rate of zero would stop the playback clock dead.
        a.fps = state.fps > 0 ? state.fps : a.fps
        a.usePreviewRange = state.usePreviewRange
        a.previewStart = state.previewStart
        a.previewEnd = state.previewEnd
        a.autoKey = state.autoKey
        a.autoKeyReplace = state.autoKeyReplace
        a.onlyInsertAvailable = state.onlyInsertAvailable
        a.onlySelectedKeys = state.onlySelectedKeys
        a.loopMode = state.loopMode
        if a != scene.animation { scene.animation = a }
    }

    /// Object names joined by NUL bytes, as `'\0'.join(names).encode()` writes
    /// them. No object name can contain one.
    public static func names(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        guard !bytes.isEmpty else { return [] }
        return bytes.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every object's keys, replacing what was mirrored before: an object the
    /// report does not name has no keys now.
    ///
    /// False, and nothing changed, when the buffers do not agree with each
    /// other.
    @discardableResult
    public static func applyKeys(names: [String], counts: UnsafeBufferPointer<UInt32>,
                                 frames: UnsafeBufferPointer<Float>,
                                 selected: UnsafeBufferPointer<UInt8>,
                                 sceneFrames: UnsafeBufferPointer<Float>,
                                 sceneSelected: UnsafeBufferPointer<UInt8>,
                                 to scene: BKScene) -> Bool {
        guard counts.count == names.count, frames.count == selected.count,
              sceneFrames.count == sceneSelected.count,
              counts.reduce(0, { $0 + Int($1) }) == frames.count
        else { return false }

        var byName: [String: [TimelineKey]] = [:]
        var offset = 0
        for (i, name) in names.enumerated() {
            let n = Int(counts[i])
            byName[name] = (0..<n).map {
                TimelineKey(frame: frames[offset + $0], selected: selected[offset + $0] != 0)
            }
            offset += n
        }
        for object in scene.objects {
            let keys = byName[object.name] ?? []
            if object.mirroredKeys != keys { object.mirroredKeys = keys }
        }
        let sceneKeys = (0..<sceneFrames.count).map {
            TimelineKey(frame: sceneFrames[$0], selected: sceneSelected[$0] != 0)
        }
        if scene.animation.sceneKeys != sceneKeys { scene.animation.sceneKeys = sceneKeys }
        return true
    }

    /// A frame change: the frame, then the world matrix of each object it
    /// moved, 16 doubles each and row-major as Blender writes `matrix_world`.
    ///
    /// Returns how many objects actually moved, or -1 for a malformed buffer.
    @discardableResult
    public static func applyFrame(_ frame: Int, subframe: Float, names: [String],
                                  matrices: UnsafeBufferPointer<Double>, to scene: BKScene) -> Int {
        guard matrices.count == names.count * 16 else { return -1 }
        if scene.frameCurrent != frame { scene.frameCurrent = frame }
        if scene.animation.subframe != subframe { scene.animation.subframe = subframe }
        guard !names.isEmpty else { return 0 }

        var byName: [String: BKObject] = [:]
        for object in scene.objects where byName[object.name] == nil {
            byName[object.name] = object
        }
        var moved = 0
        for (i, name) in names.enumerated() {
            guard let object = byName[name] else { continue }
            let b = i * 16
            // Row-major in, columns out, as bk_sync_push reads the same matrix.
            var m = simd_float4x4()
            for c in 0..<4 {
                m[c] = SIMD4(Float(matrices[b + c]), Float(matrices[b + 4 + c]),
                             Float(matrices[b + 8 + c]), Float(matrices[b + 12 + c]))
            }
            if object.mirroredTransform != m {
                object.setMirroredTransform(m)
                moved += 1
            }
        }
        return moved
    }

    /// One deformed mesh, from a frame change.
    ///
    /// A deformation keeps its topology — a shape key, an armature, a wave —
    /// so when the triangles are the ones already on screen only the vertices
    /// move, and the edge list the overlays draw is kept rather than hashed
    /// again. Returns 1 when the mesh changed, 0 when it came back identical,
    /// and -1 when there is no such object or the buffers are malformed.
    ///
    /// `edges` is sent for a mesh with no faces — a wire circle, a curve, an
    /// edge-only mesh — whose lines are all there is to draw; nil for one with
    /// faces, whose edges come from its triangles. `push_mesh` used to skip a
    /// mesh with no triangles, so a deforming wire stood still through
    /// playback and moved only at the next whole mirror: measured in 5.2.1, a
    /// wire circle with a Wave was drawn 0.126 from where Blender had it at
    /// frame 9 (tests/mirror/blender).
    ///
    /// The mesh is `_blenderkit_anim.push_mesh`'s `evaluated_get().to_mesh()`,
    /// the same evaluated mesh a mirroring pass sends, so it is installed with
    /// `setEvaluatedMesh` as the pass installs it. It went in through
    /// `setMirroredMesh`, which runs the Swift stack over it: measured, a
    /// Screw of 16 drew 384 vertices after a pass and 6,144 after one frame
    /// change of the same mesh; and in Blender 5.2.1 a grid with a Wave reports
    /// `is_updated_geometry` on every `frame_set`, so playing it drew Blender's
    /// ripple with this file's Wave rippled over it.
    @discardableResult
    public static func applyMesh(named name: String, positions: UnsafeBufferPointer<Float>,
                                 normals: UnsafeBufferPointer<Float>,
                                 triangles: UnsafeBufferPointer<UInt32>,
                                 edges: UnsafeBufferPointer<UInt32>? = nil,
                                 to scene: BKScene,
                                 index: ObjectNameIndex = ObjectNameIndex()) -> Int {
        // By the frame's shared index on device (SceneMirror.frameIndex), as
        // sync_local looks its names up, not a walk of the scene per mesh.
        guard let object = index.object(named: name, in: scene.objects),
              !positions.isEmpty, positions.count % 3 == 0, normals.count == positions.count,
              triangles.count % 3 == 0
        else { return -1 }
        let vertexCount = positions.count / 3
        guard !triangles.contains(where: { Int($0) >= vertexCount }) else { return -1 }
        // A mesh with faces draws the edges of its triangles; one without
        // draws the edges Blender sent, none if it sent none.
        var wire: [UInt32]?
        if triangles.isEmpty {
            guard let checked = SceneMirror.edges(edges ?? UnsafeBufferPointer(start: nil, count: 0),
                                                  vertexCount: vertexCount)
            else { return -1 }
            wire = checked
        }

        let base = object.evaluatedBase
        let sameTopology = object.isMirrored && base.vertices.count == vertexCount
            && base.indices.elementsEqual(triangles) && (wire == nil || base.edges == wire!)
        if sameTopology, base.matches(positions: positions, normals: normals, triangles: triangles) {
            return 0
        }
        var mesh: MeshData
        if sameTopology {
            mesh = base
            for i in 0..<vertexCount {
                let p = i * 3
                mesh.vertices[i].position = SIMD3(positions[p], positions[p + 1], positions[p + 2])
                mesh.vertices[i].normal = SIMD3(normals[p], normals[p + 1], normals[p + 2])
            }
        } else {
            var vertices: [MeshVertex] = []
            vertices.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                let p = i * 3
                vertices.append(MeshVertex(SIMD3(positions[p], positions[p + 1], positions[p + 2]),
                                           SIMD3(normals[p], normals[p + 1], normals[p + 2])))
            }
            mesh = wire.map { MeshData(vertices: vertices, wireEdges: $0) }
                ?? MeshData(vertices: vertices, indices: Array(triangles))
        }
        object.setEvaluatedMesh(mesh)
        object.editTopology = nil
        return 1
    }

    /// A report Blender would put in its status bar.
    public static func notice(_ text: String, on scene: BKScene) {
        let id = (scene.animation.notice?.id ?? 0) + 1
        scene.animation.notice = AnimationNotice(id: id, text: text)
    }

    /// The shim's keyed channels on one object, one per line as
    /// `path:frame,frame`, for `_blenderkit_anim` to read back.
    public static func channels(of object: BKObject) -> String {
        object.animation.channels.values
            .filter { !$0.keys.isEmpty }
            .sorted { $0.path < $1.path }
            .map { "\($0.path):" + $0.frames.map(String.init).joined(separator: ",") }
            .joined(separator: "\n")
    }
}
